//! Profile pictures (PLAN M7.10): the one network access besides git.
//!
//! An email's picture is looked up from these sources, the first hit
//! winning: a GitHub noreply address (its user id or login gives the URL);
//! the GitHub commit API when a remote is on github.com, for the newest
//! commit on that remote the email authored or committed
//! ([`AvatarRequest::find_commit`]); GitLab's avatar API on the remotes'
//! GitLab hosts, then on gitlab.com; Gravatar, then Libravatar, by the
//! email's SHA-256; last, GitHub's commit search by the email (public
//! commits anywhere on GitHub; last because its rate limit is the
//! tightest). Each [`Provider`] can be turned off (`AvatarRequest::providers`). The GitHub API gets the
//! user's own token from `GH_TOKEN`/`GITHUB_TOKEN` or `gh auth token`, or
//! goes unauthenticated. Pictures and misses are kept in an [`AvatarCache`]. Without curl, without a network or while
//! a source is unavailable, the UI keeps drawing initials.

pub mod cache;
pub mod curl;
mod json;

use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

pub use cache::{AvatarCache, Cached};
pub use curl::{CurlRunner, HttpError, HttpResponse};
use json::Json;

use crate::backend::GitBackend;
use crate::git::CancelToken;
use crate::repo::Remote;

/// The size asked of every source, in pixels: the largest avatar (the
/// commit details' 30 px) on a 2x screen, with room to spare.
pub const PICTURE_SIZE: u32 = 80;

/// How long the GitHub API is left alone after it refuses (rate limit).
const GITHUB_BLOCK: Duration = Duration::from_secs(30 * 60);
/// How long GitHub's search is left alone after it refuses (its limit is
/// counted per minute).
const SEARCH_BLOCK: Duration = Duration::from_secs(60);
/// How long lookups wait after one got no answer from any source.
const OFFLINE_BLOCK: Duration = Duration::from_secs(2 * 60);
/// How long `gh auth token` may take.
const GH_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ImageFormat {
    Png,
    Jpeg,
    Webp,
}

impl ImageFormat {
    pub const ALL: [ImageFormat; 3] = [Self::Png, Self::Jpeg, Self::Webp];

    pub fn extension(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpg",
            Self::Webp => "webp",
        }
    }

    /// The format of an image the UI can show, from its first bytes.
    pub fn sniff(bytes: &[u8]) -> Option<Self> {
        if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            Some(Self::Png)
        } else if bytes.starts_with(b"\xff\xd8\xff") {
            Some(Self::Jpeg)
        } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
            Some(Self::Webp)
        } else {
            None
        }
    }
}

/// Who a picture is asked of: each one a setting (Settings → Interface →
/// Picture sources).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Provider {
    Github,
    Gitlab,
    Gravatar,
    Libravatar,
}

impl Provider {
    pub const ALL: [Provider; 4] = [Self::Github, Self::Gitlab, Self::Gravatar, Self::Libravatar];

    /// The name the config, the UI and cache files use.
    pub fn name(self) -> &'static str {
        match self {
            Self::Github => "github",
            Self::Gitlab => "gitlab",
            Self::Gravatar => "gravatar",
            Self::Libravatar => "libravatar",
        }
    }

    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.name() == name.trim())
    }

    fn bit(self) -> u8 {
        1 << self as u8
    }
}

/// A set of providers; every one by default.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Providers(u8);

impl Default for Providers {
    fn default() -> Self {
        Self::ALL
    }
}

impl Providers {
    pub const ALL: Providers = Providers(0b1111);
    pub const NONE: Providers = Providers(0);

    pub fn has(self, provider: Provider) -> bool {
        self.0 & provider.bit() != 0
    }

    pub fn with(self, provider: Provider, on: bool) -> Self {
        if on {
            Self(self.0 | provider.bit())
        } else {
            Self(self.0 & !provider.bit())
        }
    }

    pub fn is_empty(self) -> bool {
        self.0 == 0
    }

    /// Whether every provider of `other` is in this set.
    pub fn covers(self, other: Providers) -> bool {
        other.0 & !self.0 == 0
    }

    /// The providers in [`Provider::ALL`]'s order.
    pub fn iter(self) -> impl Iterator<Item = Provider> {
        Provider::ALL.into_iter().filter(move |p| self.has(*p))
    }

    /// The providers named in `names` (unknown names are left out).
    pub fn from_names<'a>(names: impl IntoIterator<Item = &'a str>) -> Self {
        names
            .into_iter()
            .filter_map(Provider::parse)
            .fold(Self::NONE, |set, p| set.with(p, true))
    }
}

/// Where a picture came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    GithubNoreply,
    GithubCommit,
    Gitlab,
    Gravatar,
    Libravatar,
    GithubSearch,
}

impl Source {
    pub fn provider(self) -> Provider {
        match self {
            Self::GithubNoreply | Self::GithubCommit | Self::GithubSearch => Provider::Github,
            Self::Gitlab => Provider::Gitlab,
            Self::Gravatar => Provider::Gravatar,
            Self::Libravatar => Provider::Libravatar,
        }
    }
}

/// The email as sources and the cache key it: trimmed, lowercase.
pub fn normalize_email(email: &str) -> String {
    email.trim().to_lowercase()
}

/// The hex SHA-256 of the normalized email: the cache key, and the hash
/// Gravatar and Libravatar take.
pub fn email_hash(email: &str) -> String {
    let digest = Sha256::digest(normalize_email(email).as_bytes());
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

/// Base URLs of the sources (tests point them at a local stub).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoints {
    pub github_avatars: String,
    pub github_web: String,
    pub github_api: String,
    /// GitLab asked for every email (the remotes' GitLab hosts come first).
    pub gitlab: String,
    pub gravatar: String,
    pub libravatar: String,
}

impl Default for Endpoints {
    fn default() -> Self {
        Self {
            github_avatars: "https://avatars.githubusercontent.com".into(),
            github_web: "https://github.com".into(),
            github_api: "https://api.github.com".into(),
            gitlab: "https://gitlab.com".into(),
            gravatar: "https://gravatar.com/avatar".into(),
            libravatar: "https://seccdn.libravatar.org/avatar".into(),
        }
    }
}

impl Endpoints {
    /// Every source under `base` (`<base>/github-avatars`, `<base>/github`,
    /// `<base>/github-api`, `<base>/gitlab`, `<base>/gravatar`,
    /// `<base>/libravatar`), for stubs (`GITBELLO_AVATAR_ENDPOINT`).
    pub fn under(base: &str) -> Self {
        let base = base.trim_end_matches('/');
        Self {
            github_avatars: format!("{base}/github-avatars"),
            github_web: format!("{base}/github"),
            github_api: format!("{base}/github-api"),
            gitlab: format!("{base}/gitlab"),
            gravatar: format!("{base}/gravatar"),
            libravatar: format!("{base}/libravatar"),
        }
    }
}

/// A remote on github.com.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GithubRemote {
    /// The remote's name (`origin`), whose branches GitHub has.
    pub remote: String,
    /// `owner/name`.
    pub repo: String,
}

/// The hosting a repository's remotes point at, for the sources that need it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RemoteHosts {
    /// The first github.com remote (`origin` first).
    pub github: Option<GithubRemote>,
    /// Base URLs of the GitLab hosts among the remotes, each once.
    pub gitlab: Vec<String>,
}

impl RemoteHosts {
    pub fn from_remotes(remotes: &[Remote]) -> Self {
        let mut ordered: Vec<&Remote> = remotes.iter().collect();
        ordered.sort_by_key(|r| r.name != "origin");
        let mut hosts = Self::default();
        for remote in ordered {
            let Some((scheme, host, path)) = split_remote_url(&remote.fetch_url) else {
                continue;
            };
            let bare = host.split(':').next().unwrap_or(&host).to_string();
            if matches!(
                bare.as_str(),
                "github.com" | "www.github.com" | "ssh.github.com"
            ) {
                let repo = path.trim_matches('/').trim_end_matches(".git").to_string();
                if hosts.github.is_none() && repo.split('/').count() == 2 {
                    hosts.github = Some(GithubRemote {
                        remote: remote.name.clone(),
                        repo,
                    });
                }
            } else if is_gitlab_host(&bare) {
                // ssh remotes name the host's web address without their port.
                let base = match scheme.as_str() {
                    "http" | "https" => format!("{scheme}://{host}"),
                    _ => format!("https://{bare}"),
                };
                if !hosts.gitlab.contains(&base) {
                    hosts.gitlab.push(base);
                }
            }
        }
        hosts
    }
}

/// `gitlab.com`, or a host whose name says GitLab (`gitlab.example.com`,
/// `code.gitlab.example.org`).
fn is_gitlab_host(host: &str) -> bool {
    let host = host.to_ascii_lowercase();
    host.split('.').next() == Some("gitlab") || host.contains(".gitlab.")
}

/// `(scheme, host[:port], path)` of a remote URL: `scheme://[user@]host/path`
/// or scp-like `[user@]host:path` (scheme `ssh`). Local paths give `None`.
fn split_remote_url(url: &str) -> Option<(String, String, String)> {
    let url = url.trim();
    if let Some((scheme, rest)) = url.split_once("://") {
        let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
        let host = authority.rsplit('@').next().unwrap_or(authority);
        if host.is_empty() || scheme == "file" {
            return None;
        }
        return Some((
            scheme.to_ascii_lowercase(),
            host.to_ascii_lowercase(),
            path.into(),
        ));
    }
    let (authority, path) = url.split_once(':')?;
    if authority.contains('/') || authority.len() < 2 {
        // `./x:y` or a Windows drive (`C:\repo`).
        return None;
    }
    let host = authority.rsplit('@').next().unwrap_or(authority);
    Some(("ssh".into(), host.to_ascii_lowercase(), path.into()))
}

/// One email to find a picture for.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AvatarRequest {
    pub email: String,
    /// A commit `email` authored or committed, for the GitHub commit API
    /// ([`Self::find_commit`] looks for one in `repo`).
    pub commit: Option<String>,
    /// The repository whose remotes `hosts` are.
    pub repo: Option<PathBuf>,
    pub hosts: RemoteHosts,
    /// The providers to ask (the others are skipped).
    pub providers: Providers,
}

impl AvatarRequest {
    /// Fills `commit` with the newest commit on the GitHub remote's branches
    /// that `email` authored, or else committed (whatever role the person
    /// had where they were drawn): one GitHub knows. Read-only; a failed
    /// read leaves `commit` empty.
    pub fn find_commit(&mut self, backend: &dyn GitBackend, cancel: &CancelToken) {
        let (None, Some(repo), Some(github)) = (&self.commit, &self.repo, &self.hosts.github)
        else {
            return;
        };
        self.commit = backend
            .published_commit_by(repo, &github.remote, &self.email, cancel)
            .ok()
            .flatten();
    }
}

/// How a lookup ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Lookup {
    Found {
        bytes: Vec<u8>,
        format: ImageFormat,
        source: Source,
    },
    /// Every source answered and none has a picture.
    Missing,
    /// A source could not answer (offline, rate limit, no curl): ask again later.
    Unavailable,
}

/// What an avatar job found: the cache's entry, or a lookup's result
/// (already written to the cache).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AvatarAnswer {
    Cached(Cached),
    /// `github`: the request had a GitHub remote to ask.
    Looked {
        lookup: Lookup,
        github: bool,
    },
}

/// What one source said.
enum Step {
    Found(Vec<u8>, ImageFormat),
    No,
    /// The source answered but cannot say now (rate limit, server error).
    Busy,
    /// No answer at all.
    Unreachable,
    Cancelled,
}

/// Why the GitHub API gave nothing to read.
enum Refused {
    /// A rate limit: leave that API alone for a while.
    Limited,
    Step(Step),
}

#[derive(Debug, Default)]
enum Token {
    #[default]
    Unknown,
    Known(Option<String>),
}

#[derive(Debug, Default)]
struct Limits {
    github_until: Option<Instant>,
    search_until: Option<Instant>,
    offline_until: Option<Instant>,
}

/// The sources and what they said lately (rate limits, being offline),
/// shared by every lookup.
#[derive(Debug)]
pub struct AvatarSources {
    curl: Option<CurlRunner>,
    endpoints: Endpoints,
    token: Mutex<Token>,
    limits: Mutex<Limits>,
}

impl AvatarSources {
    /// The real sources through `curl` (`None`: lookups always come back
    /// [`Lookup::Unavailable`]).
    pub fn new(curl: Option<CurlRunner>, endpoints: Endpoints) -> Self {
        Self {
            curl,
            endpoints,
            token: Mutex::default(),
            limits: Mutex::default(),
        }
    }

    /// Uses `token` for the GitHub API instead of looking for one.
    pub fn with_github_token(self, token: Option<String>) -> Self {
        *lock(&self.token) = Token::Known(token);
        self
    }

    pub fn has_curl(&self) -> bool {
        self.curl.is_some()
    }

    /// Finds `request.email`'s picture, trying each source in turn.
    pub fn lookup(&self, request: &AvatarRequest, cancel: &CancelToken) -> Lookup {
        let Some(curl) = &self.curl else {
            return Lookup::Unavailable;
        };
        let now = Instant::now();
        if lock(&self.limits)
            .offline_until
            .is_some_and(|until| now < until)
        {
            return Lookup::Unavailable;
        }
        let email = normalize_email(&request.email);
        let hash = email_hash(&email);
        let providers = request.providers;
        let github = providers.has(Provider::Github);
        let mut answered = false;
        let mut incomplete = false;
        let mut sources: Vec<(Source, Box<dyn Fn() -> Step + '_>)> = Vec::new();
        if let Some(url) = self.noreply_url(&email).filter(|_| github) {
            sources.push((
                Source::GithubNoreply,
                Box::new(move || image(curl, &url, &[], cancel)),
            ));
        }
        if let (true, Some(remote), Some(commit)) = (github, &request.hosts.github, &request.commit)
        {
            if lock(&self.limits)
                .github_until
                .is_some_and(|until| now < until)
            {
                incomplete = true;
            } else {
                let email = &email;
                sources.push((
                    Source::GithubCommit,
                    Box::new(move || self.github_commit(curl, &remote.repo, commit, email, cancel)),
                ));
            }
        }
        let mut gitlab_hosts: Vec<&str> = request.hosts.gitlab.iter().map(String::as_str).collect();
        let public = self.endpoints.gitlab.trim_end_matches('/');
        if !gitlab_hosts
            .iter()
            .any(|host| host.trim_end_matches('/').eq_ignore_ascii_case(public))
        {
            gitlab_hosts.push(public);
        }
        for base in gitlab_hosts
            .into_iter()
            .filter(|_| providers.has(Provider::Gitlab))
        {
            let email = &email;
            sources.push((
                Source::Gitlab,
                Box::new(move || gitlab(curl, base, email, cancel)),
            ));
        }
        for (source, base) in [
            (Source::Gravatar, &self.endpoints.gravatar),
            (Source::Libravatar, &self.endpoints.libravatar),
        ] {
            if !providers.has(source.provider()) {
                continue;
            }
            let url = format!("{base}/{hash}?s={PICTURE_SIZE}&d=404");
            sources.push((source, Box::new(move || image(curl, &url, &[], cancel))));
        }
        let search_blocked = lock(&self.limits)
            .search_until
            .is_some_and(|until| now < until);
        if github && search_blocked {
            incomplete = true;
        } else if github {
            let email = &email;
            sources.push((
                Source::GithubSearch,
                Box::new(move || self.github_search(curl, email, cancel)),
            ));
        }
        for (source, ask) in sources {
            match ask() {
                Step::Found(bytes, format) => {
                    return Lookup::Found {
                        bytes,
                        format,
                        source,
                    }
                }
                Step::No => answered = true,
                Step::Busy => {
                    answered = true;
                    incomplete = true;
                }
                Step::Unreachable => incomplete = true,
                Step::Cancelled => return Lookup::Unavailable,
            }
        }
        // With every provider off nothing was asked: no sign of being offline.
        if !answered && !providers.is_empty() {
            lock(&self.limits).offline_until = Some(Instant::now() + OFFLINE_BLOCK);
        }
        if incomplete {
            Lookup::Unavailable
        } else {
            Lookup::Missing
        }
    }

    /// The picture URL of a GitHub noreply address: `<id>+<login>@` gives
    /// the user id, an older `<login>@` the login.
    fn noreply_url(&self, email: &str) -> Option<String> {
        let local = email.strip_suffix("@users.noreply.github.com")?;
        if let Some((id, _login)) = local.split_once('+') {
            if !id.is_empty() && id.bytes().all(|b| b.is_ascii_digit()) {
                return Some(format!(
                    "{}/u/{id}?s={PICTURE_SIZE}&v=4",
                    self.endpoints.github_avatars
                ));
            }
            return None;
        }
        let valid = !local.is_empty()
            && local
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-');
        valid.then(|| {
            format!(
                "{}/{local}.png?size={PICTURE_SIZE}",
                self.endpoints.github_web
            )
        })
    }

    /// The picture GitHub has for `email` as `commit`'s author, or else its
    /// committer (a co-author is neither), when GitHub knows the commit.
    fn github_commit(
        &self,
        curl: &CurlRunner,
        repo: &str,
        commit: &str,
        email: &str,
        cancel: &CancelToken,
    ) -> Step {
        if !commit.bytes().all(|b| b.is_ascii_hexdigit()) || commit.is_empty() {
            return Step::No;
        }
        let url = format!(
            "{}/repos/{repo}/commits/{commit}",
            self.endpoints.github_api
        );
        let json = match self.github_get(curl, &url, cancel) {
            Ok(Some(json)) => json,
            Ok(None) => return Step::No,
            Err(Refused::Limited) => {
                lock(&self.limits).github_until = Some(Instant::now() + GITHUB_BLOCK);
                return Step::Busy;
            }
            Err(Refused::Step(step)) => return step,
        };
        match github_person(&json, email) {
            Some(picture) => image(curl, &picture, &[], cancel),
            None => Step::No,
        }
    }

    /// GitHub's commit search by `email` as an author: public commits in
    /// any repository, for people this repository's remote does not know.
    fn github_search(&self, curl: &CurlRunner, email: &str, cancel: &CancelToken) -> Step {
        let url = format!(
            "{}/search/commits?q=author-email:{}&per_page=5",
            self.endpoints.github_api,
            percent_encode(email)
        );
        let json = match self.github_get(curl, &url, cancel) {
            Ok(Some(json)) => json,
            Ok(None) => return Step::No,
            Err(Refused::Limited) => {
                lock(&self.limits).search_until = Some(Instant::now() + SEARCH_BLOCK);
                return Step::Busy;
            }
            Err(Refused::Step(step)) => return step,
        };
        let items = json.get("items").and_then(Json::as_array).unwrap_or(&[]);
        match items.iter().find_map(|item| github_person(item, email)) {
            Some(picture) => image(curl, &picture, &[], cancel),
            None => Step::No,
        }
    }

    /// A GitHub API answer: `Ok(None)` for a refusal that means "no" (not
    /// found, private, a bad query), `Err` for a rate limit, a server error
    /// or no answer. A token GitHub refuses is dropped and the request made
    /// again without it.
    fn github_get(
        &self,
        curl: &CurlRunner,
        url: &str,
        cancel: &CancelToken,
    ) -> Result<Option<Json>, Refused> {
        let mut retried = false;
        loop {
            let token = self.github_token(cancel);
            let mut headers = vec![
                "Accept: application/vnd.github+json".to_string(),
                "X-GitHub-Api-Version: 2022-11-28".to_string(),
                "User-Agent: gitbello".to_string(),
            ];
            if let Some(token) = &token {
                headers.push(format!("Authorization: Bearer {token}"));
            }
            let response = curl
                .get(url, &headers, cancel)
                .map_err(|e| Refused::Step(failed(&e)))?;
            return match response.status {
                200 => Ok(Json::parse(&String::from_utf8_lossy(&response.body))),
                // A token that no longer works: go on without it.
                401 if token.is_some() && !retried => {
                    *lock(&self.token) = Token::Known(None);
                    retried = true;
                    continue;
                }
                403 | 429 => Err(Refused::Limited),
                500..=599 => Err(Refused::Step(Step::Busy)),
                _ => Ok(None),
            };
        }
    }

    /// `GH_TOKEN`, `GITHUB_TOKEN` or `gh auth token`, looked for once.
    fn github_token(&self, cancel: &CancelToken) -> Option<String> {
        let mut token = lock(&self.token);
        if let Token::Known(known) = &*token {
            return known.clone();
        }
        let found = ["GH_TOKEN", "GITHUB_TOKEN"]
            .iter()
            .filter_map(|var| std::env::var(var).ok())
            .map(|value| value.trim().to_string())
            .find(|value| !value.is_empty())
            .or_else(|| gh_token(cancel));
        *token = Token::Known(found.clone());
        found
    }
}

/// The picture URL of `email` in a GitHub commit object (the commit API's
/// answer or a search result): its author's, or else its committer's, when
/// that person's git email is `email` and GitHub knows their account.
fn github_person(commit: &Json, email: &str) -> Option<String> {
    ["author", "committer"].into_iter().find_map(|role| {
        let git_email = commit
            .at(&["commit", role, "email"])
            .and_then(Json::as_str)?;
        if normalize_email(git_email) != email {
            return None;
        }
        let avatar = commit.at(&[role, "avatar_url"]).and_then(Json::as_str)?;
        let separator = if avatar.contains('?') { '&' } else { '?' };
        Some(format!("{avatar}{separator}s={PICTURE_SIZE}"))
    })
}

/// `gh auth token` for github.com, when gh is installed and signed in.
fn gh_token(cancel: &CancelToken) -> Option<String> {
    let gh = curl::find_on_path("gh")?;
    let mut cmd = std::process::Command::new(gh);
    cmd.args(["auth", "token", "--hostname", "github.com"]);
    let output = curl::run(cmd, None, cancel, GH_TIMEOUT).ok()?;
    let token = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (output.success && !token.is_empty() && !token.contains(char::is_whitespace)).then_some(token)
}

/// GitLab's avatar API on `base`. It answers Gravatar's URL for unknown
/// emails, which the Gravatar step asks anyway (and without the plain email).
fn gitlab(curl: &CurlRunner, base: &str, email: &str, cancel: &CancelToken) -> Step {
    let base = base.trim_end_matches('/');
    let url = format!(
        "{base}/api/v4/avatar?email={}&size={PICTURE_SIZE}",
        percent_encode(email)
    );
    let response = match curl.get(&url, &["User-Agent: gitbello".to_string()], cancel) {
        Ok(response) => response,
        Err(err) => return failed(&err),
    };
    match response.status {
        200 => {}
        429 | 500..=599 => return Step::Busy,
        _ => return Step::No,
    }
    let Some(json) = Json::parse(&String::from_utf8_lossy(&response.body)) else {
        return Step::No;
    };
    let Some(avatar) = json.get("avatar_url").and_then(Json::as_str) else {
        return Step::No;
    };
    let lower = avatar.to_ascii_lowercase();
    if ["gravatar.com", "libravatar", "no_avatar"]
        .iter()
        .any(|skip| lower.contains(skip))
    {
        return Step::No;
    }
    let avatar = if avatar.starts_with('/') {
        format!("{base}{avatar}")
    } else {
        avatar.to_string()
    };
    image(curl, &avatar, &[], cancel)
}

/// A picture at `url`: found when it answers with an image the UI shows.
fn image(curl: &CurlRunner, url: &str, headers: &[String], cancel: &CancelToken) -> Step {
    match curl.get(url, headers, cancel) {
        Ok(response) => match response.status {
            200 => match ImageFormat::sniff(&response.body) {
                Some(format) => Step::Found(response.body, format),
                None => Step::No,
            },
            429 | 500..=599 => Step::Busy,
            _ => Step::No,
        },
        Err(err) => failed(&err),
    }
}

fn failed(err: &HttpError) -> Step {
    match err {
        HttpError::Cancelled => Step::Cancelled,
        HttpError::NoCurl(_) | HttpError::Network(_) => Step::Unreachable,
    }
}

fn percent_encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn remote(name: &str, url: &str) -> Remote {
        Remote {
            name: name.into(),
            fetch_url: url.into(),
            push_url: url.into(),
        }
    }

    #[test]
    fn email_hash_is_the_sha256_of_the_trimmed_lowercase_email() {
        // Gravatar's documented example.
        assert_eq!(
            email_hash("  MyEmailAddress@example.com "),
            "84059b07d4be67b806386c0aad8070a23f18836bbaae342275dc0a83414c32ee"
        );
    }

    #[test]
    fn images_are_recognised_by_their_first_bytes() {
        assert_eq!(
            ImageFormat::sniff(b"\x89PNG\r\n\x1a\n...."),
            Some(ImageFormat::Png)
        );
        assert_eq!(
            ImageFormat::sniff(b"\xff\xd8\xff\xe0"),
            Some(ImageFormat::Jpeg)
        );
        assert_eq!(
            ImageFormat::sniff(b"RIFF\0\0\0\0WEBPVP8 "),
            Some(ImageFormat::Webp)
        );
        assert_eq!(ImageFormat::sniff(b"GIF89a"), None);
        assert_eq!(ImageFormat::sniff(b"<html>"), None);
    }

    #[test]
    fn noreply_addresses_give_the_picture_url() {
        let sources = AvatarSources::new(None, Endpoints::default());
        assert_eq!(
            sources
                .noreply_url("123456+octo-cat@users.noreply.github.com")
                .as_deref(),
            Some("https://avatars.githubusercontent.com/u/123456?s=80&v=4")
        );
        assert_eq!(
            sources
                .noreply_url("octo-cat@users.noreply.github.com")
                .as_deref(),
            Some("https://github.com/octo-cat.png?size=80")
        );
        assert_eq!(sources.noreply_url("x+y@users.noreply.github.com"), None);
        assert_eq!(sources.noreply_url("a/b@users.noreply.github.com"), None);
        assert_eq!(sources.noreply_url("octo@example.com"), None);
    }

    #[test]
    fn remote_hosts_find_github_and_gitlab() {
        let hosts = RemoteHosts::from_remotes(&[
            remote("fork", "git@github.com:me/fork.git"),
            remote("origin", "https://github.com/owner/repo.git"),
            remote(
                "lab",
                "ssh://git@gitlab.example.com:2222/group/sub/repo.git",
            ),
            remote("lab2", "https://user@gitlab.com:8443/group/repo"),
            remote("mirror", "git@gitlab.example.com:group/other.git"),
            remote("local", "C:\\repos\\thing"),
            remote("path", "/srv/git/thing.git"),
            remote("other", "https://example.com/gitlabish/repo.git"),
        ]);
        let github = hosts.github.clone().expect("a github remote");
        assert_eq!(
            (github.remote.as_str(), github.repo.as_str()),
            ("origin", "owner/repo")
        );
        assert_eq!(
            hosts.gitlab,
            vec![
                "https://gitlab.example.com".to_string(),
                "https://gitlab.com:8443".to_string(),
            ]
        );
        let ssh = RemoteHosts::from_remotes(&[remote("origin", "git@github.com:o/r")]);
        assert_eq!(ssh.github.map(|g| g.repo).as_deref(), Some("o/r"));
        assert_eq!(RemoteHosts::from_remotes(&[]), RemoteHosts::default());
    }

    #[test]
    fn gitlab_hosts_are_named_so() {
        for host in [
            "gitlab.com",
            "gitlab.example.org",
            "code.gitlab.example.org",
        ] {
            assert!(is_gitlab_host(host), "{host}");
        }
        for host in ["github.com", "mygitlab.com", "example.com"] {
            assert!(!is_gitlab_host(host), "{host}");
        }
    }

    #[test]
    fn emails_are_percent_encoded() {
        assert_eq!(percent_encode("a.b+c@x.io"), "a.b%2Bc%40x.io");
        assert_eq!(percent_encode("ü"), "%C3%BC");
    }

    #[test]
    fn without_curl_every_lookup_is_unavailable() {
        let sources = AvatarSources::new(None, Endpoints::default());
        let request = AvatarRequest {
            email: "a@b.c".into(),
            ..AvatarRequest::default()
        };
        assert_eq!(
            sources.lookup(&request, &CancelToken::new()),
            Lookup::Unavailable
        );
    }
}
