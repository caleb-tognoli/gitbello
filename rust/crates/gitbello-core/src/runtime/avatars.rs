//! Profile pictures (PLAN M7.10): what the UI asked for, read from the
//! cache first and looked up when the cache has nothing (or something old),
//! a few lookups at a time, as background jobs.

use std::time::SystemTime;

use super::*;
use crate::avatars::{
    email_hash, normalize_email, AvatarAnswer, AvatarCache, AvatarRequest, AvatarSources, Cached,
    CurlRunner, Endpoints, ImageFormat, Lookup, Provider, Providers, RemoteHosts,
};

pub const AVATAR_CACHE_JOB_LABEL: &str = "read avatar";
pub const AVATAR_JOB_LABEL: &str = "look up avatar";

/// Lookups running at once.
const AVATAR_JOBS: usize = 3;
/// An email whose lookup could not finish is asked again after this.
const RETRY_AFTER: Duration = Duration::from_secs(5 * 60);

/// A picture to show: the image file's bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Picture {
    pub bytes: Arc<[u8]>,
    pub format: ImageFormat,
}

#[derive(Debug)]
enum Known {
    Pending,
    Picture(Picture),
    /// `github`: a GitHub remote was asked; a request from a repository
    /// with one looks again when none was.
    Missing {
        github: bool,
    },
    /// The lookup could not finish at this time.
    Failed(Instant),
}

#[derive(Debug)]
pub(super) struct AvatarBook {
    sources: Arc<AvatarSources>,
    cache: Option<AvatarCache>,
    /// By normalized email.
    known: HashMap<String, Known>,
    /// Requests whose cache entry is being read, for the lookup that may follow.
    reading: HashMap<String, AvatarRequest>,
    queue: VecDeque<AvatarRequest>,
    looking: usize,
}

impl AvatarBook {
    /// The real sources (`GITBELLO_AVATAR_ENDPOINT` puts them all under one
    /// URL, for stubs), cached in the cache folder.
    pub(super) fn from_env() -> Self {
        let endpoints = std::env::var("GITBELLO_AVATAR_ENDPOINT")
            .ok()
            .filter(|base| !base.trim().is_empty())
            .map_or_else(Endpoints::default, |base| Endpoints::under(&base));
        let cache = crate::paths::cache_dir().map(|dir| AvatarCache::new(dir.join("avatars")));
        Self::new(AvatarSources::new(CurlRunner::discover(), endpoints), cache)
    }

    fn new(sources: AvatarSources, cache: Option<AvatarCache>) -> Self {
        Self {
            sources: Arc::new(sources),
            cache,
            known: HashMap::new(),
            reading: HashMap::new(),
            queue: VecDeque::new(),
            looking: 0,
        }
    }

    /// The folder jobs name as their repository (they touch none).
    fn job_path(&self) -> PathBuf {
        self.cache
            .as_ref()
            .map_or_else(|| PathBuf::from("avatars"), |c| c.dir().to_path_buf())
    }
}

impl Runtime {
    /// Uses `sources` and the cache in `cache_dir` (tests), forgetting what
    /// was found so far.
    pub fn set_avatar_sources(&mut self, sources: AvatarSources, cache_dir: Option<PathBuf>) {
        self.avatars = AvatarBook::new(sources, cache_dir.map(AvatarCache::new));
    }

    /// Turns profile pictures on or off (saved with the config). Off forgets
    /// the pictures found and stops queued lookups.
    pub fn set_avatars_enabled(&mut self, enabled: bool) {
        self.config.avatars = enabled;
        if !enabled {
            self.forget_avatars();
        }
    }

    /// The providers pictures are asked of (saved with the config). What
    /// was found so far is forgotten: asked again, the cache hides pictures
    /// from a provider now off and looks again where one now on was not
    /// asked.
    pub fn set_avatar_providers(&mut self, providers: Providers) {
        if self.config.avatar_providers != providers {
            self.config.avatar_providers = providers;
            self.forget_avatars();
        }
    }

    fn forget_avatars(&mut self) {
        self.avatars.known.clear();
        self.avatars.reading.clear();
        self.avatars.queue.clear();
    }

    /// Asks for `email`'s picture, once per email (again from a repository
    /// with a GitHub remote when none was asked): [`RuntimeEvent::AvatarChanged`]
    /// says when one is there ([`Runtime::avatar`]). `repo` (a tab's key)
    /// gives the remotes to ask, and on a GitHub remote the commit whose
    /// picture GitHub knows. Nothing happens while pictures are off.
    pub fn request_avatar(&mut self, repo: Option<&Path>, email: &str) {
        let providers = self.config.avatar_providers;
        if !self.config.avatars || providers.is_empty() {
            return;
        }
        let email = normalize_email(email);
        if !email.contains('@') {
            return;
        }
        let state = repo.and_then(|key| self.repos.get(key).map(|state| (key, state)));
        let hosts = state
            .map(|(_, state)| RemoteHosts::from_remotes(state.remote_list()))
            .unwrap_or_default();
        match self.avatars.known.get(&email) {
            Some(Known::Failed(at)) if at.elapsed() >= RETRY_AFTER => {}
            Some(Known::Missing { github: false })
                if hosts.github.is_some() && providers.has(Provider::Github) => {}
            Some(_) => return,
            None => {}
        }
        self.avatars.known.insert(email.clone(), Known::Pending);
        let request = AvatarRequest {
            email,
            commit: None,
            repo: state.map(|(key, _)| key.to_path_buf()),
            hosts,
            providers,
        };
        match self.avatars.cache.clone() {
            Some(cache) => {
                let email = request.email.clone();
                self.avatars.reading.insert(email.clone(), request);
                let path = self.avatars.job_path();
                self.scheduler.submit(
                    JobSpec::read(path, AVATAR_CACHE_JOB_LABEL, move |_| {
                        let cached = cache.read(&email_hash(&email), SystemTime::now());
                        Ok(JobOutput::Avatar(Box::new((
                            email,
                            AvatarAnswer::Cached(cached),
                        ))))
                    })
                    .with_priority(JobPriority::Background),
                );
            }
            None => {
                self.avatars.queue.push_back(request);
                self.submit_avatar_lookups();
            }
        }
    }

    /// `email`'s picture, once found.
    pub fn avatar(&self, email: &str) -> Option<&Picture> {
        match self.avatars.known.get(&normalize_email(email))? {
            Known::Picture(picture) => Some(picture),
            _ => None,
        }
    }

    fn submit_avatar_lookups(&mut self) {
        while self.avatars.looking < AVATAR_JOBS {
            let Some(request) = self.avatars.queue.pop_front() else {
                return;
            };
            self.avatars.looking += 1;
            let sources = Arc::clone(&self.avatars.sources);
            let cache = self.avatars.cache.clone();
            self.scheduler.submit(
                JobSpec::read(self.avatars.job_path(), AVATAR_JOB_LABEL, move |ctx| {
                    let mut request = request;
                    request.find_commit(ctx.backend(), ctx.cancel_token());
                    let lookup = sources.lookup(&request, ctx.cancel_token());
                    let github =
                        request.hosts.github.is_some() && request.providers.has(Provider::Github);
                    if let Some(cache) = &cache {
                        let key = email_hash(&request.email);
                        // A cache that cannot be written only costs a lookup next time.
                        let _ = match &lookup {
                            Lookup::Found {
                                bytes,
                                format,
                                source,
                            } => cache.store_picture(&key, bytes, *format, source.provider()),
                            Lookup::Missing => cache.store_miss(&key, request.providers, github),
                            Lookup::Unavailable => Ok(()),
                        };
                    }
                    Ok(JobOutput::Avatar(Box::new((
                        request.email,
                        AvatarAnswer::Looked { lookup, github },
                    ))))
                })
                .with_priority(JobPriority::Background),
            );
        }
    }
}

/// Takes the events of avatar jobs; other jobs' come back.
pub(super) fn apply_avatar(
    rt: &mut Runtime,
    label: &str,
    kind: EventKind,
    out: &mut Vec<RuntimeEvent>,
) -> Option<EventKind> {
    let lookup = label == AVATAR_JOB_LABEL;
    if !lookup && label != AVATAR_CACHE_JOB_LABEL {
        return Some(kind);
    }
    let result = match kind {
        EventKind::Finished(result) => result,
        EventKind::Cancelled => Err(GitError::new(label, GitErrorKind::Cancelled, "")),
        _ => return None,
    };
    if lookup {
        rt.avatars.looking = rt.avatars.looking.saturating_sub(1);
    }
    if let Ok(JobOutput::Avatar(answer)) = result {
        let (email, answer) = *answer;
        let request = rt.avatars.reading.remove(&email);
        // Turned off meanwhile: forget it.
        if rt.config.avatars && rt.avatars.known.contains_key(&email) {
            take_answer(rt, email, answer, request, out);
        }
    }
    rt.submit_avatar_lookups();
    None
}

fn take_answer(
    rt: &mut Runtime,
    email: String,
    answer: AvatarAnswer,
    request: Option<AvatarRequest>,
    out: &mut Vec<RuntimeEvent>,
) {
    let providers = rt.config.avatar_providers;
    // A request whose GitHub remote a cached miss did not ask.
    let github_unasked = request
        .as_ref()
        .is_some_and(|r| r.hosts.github.is_some() && providers.has(Provider::Github));
    let book = &mut rt.avatars;
    let mut look_up = false;
    let had_picture = matches!(book.known.get(&email), Some(Known::Picture(_)));
    match answer {
        AvatarAnswer::Cached(Cached::Picture {
            bytes,
            format,
            provider,
            stale,
        }) if providers.has(provider) => {
            let picture = Picture {
                bytes: bytes.into(),
                format,
            };
            book.known.insert(email.clone(), Known::Picture(picture));
            out.push(RuntimeEvent::AvatarChanged {
                email: email.clone(),
            });
            look_up = stale;
        }
        // A miss stands when every provider now on was asked, and the GitHub
        // remote when this repository has one.
        AvatarAnswer::Cached(Cached::Miss {
            stale: false,
            asked,
            github_remote,
        }) if asked.covers(providers) && (github_remote || !github_unasked) => {
            book.known.insert(
                email.clone(),
                Known::Missing {
                    github: github_remote,
                },
            );
        }
        // Nothing, an old miss, or a picture from a provider now off.
        AvatarAnswer::Cached(_) => look_up = true,
        AvatarAnswer::Looked {
            lookup: Lookup::Found { bytes, format, .. },
            ..
        } => {
            let picture = Picture {
                bytes: bytes.into(),
                format,
            };
            book.known.insert(email.clone(), Known::Picture(picture));
            out.push(RuntimeEvent::AvatarChanged { email });
        }
        AvatarAnswer::Looked {
            lookup: Lookup::Missing,
            github,
        } => {
            book.known.insert(email.clone(), Known::Missing { github });
            if had_picture {
                out.push(RuntimeEvent::AvatarChanged { email });
            }
        }
        // A picture being refreshed stays.
        AvatarAnswer::Looked {
            lookup: Lookup::Unavailable,
            ..
        } => {
            if !had_picture {
                book.known.insert(email, Known::Failed(Instant::now()));
            }
        }
    }
    if look_up {
        if let Some(request) = request {
            book.queue.push_back(request);
        }
    }
}
