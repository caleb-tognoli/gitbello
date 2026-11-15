//! Web pages of a remote (M7.17): "Open on GitHub" for a commit, a pushed
//! branch or tag and a file at a commit. Hosts are recognised by name only
//! (github.com, gitlab.com, bitbucket.org, Azure DevOps, codeberg.org and
//! gitea.com): a self-hosted server gets no link rather than a wrong one.

/// A web host that has pages for commits, branches, tags and files.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WebHost {
    GitHub,
    GitLab,
    Bitbucket,
    AzureDevOps,
    Codeberg,
    Gitea,
}

impl WebHost {
    /// The name shown in "Open on <name>".
    pub fn name(self) -> &'static str {
        match self {
            WebHost::GitHub => "GitHub",
            WebHost::GitLab => "GitLab",
            WebHost::Bitbucket => "Bitbucket",
            WebHost::AzureDevOps => "Azure DevOps",
            WebHost::Codeberg => "Codeberg",
            WebHost::Gitea => "Gitea",
        }
    }
}

/// What a link points at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WebTarget<'a> {
    Commit(&'a str),
    Branch(&'a str),
    Tag(&'a str),
    /// A file as it is at a commit.
    File {
        commit: &'a str,
        path: &'a str,
    },
}

/// A repository's home page on a known host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebRepo {
    pub host: WebHost,
    /// `https://github.com/owner/repo`, without a trailing slash or `.git`.
    pub base: String,
}

impl WebRepo {
    /// The repository behind `remote_url` (https, ssh or scp-like), or
    /// `None` for an unknown host or a local path.
    pub fn from_remote_url(remote_url: &str) -> Option<WebRepo> {
        let (_, authority, path) = split_remote_url(remote_url)?;
        let host = authority.split(':').next().unwrap_or(&authority).to_owned();
        let path = path.trim_matches('/');
        let path = path
            .strip_suffix(".git")
            .unwrap_or(path)
            .trim_end_matches('/');
        if path.is_empty() {
            return None;
        }
        let (kind, web_host) = match host.as_str() {
            "github.com" | "www.github.com" | "ssh.github.com" => (WebHost::GitHub, "github.com"),
            "gitlab.com" | "www.gitlab.com" | "altssh.gitlab.com" => {
                (WebHost::GitLab, "gitlab.com")
            }
            "bitbucket.org" | "www.bitbucket.org" | "altssh.bitbucket.org" => {
                (WebHost::Bitbucket, "bitbucket.org")
            }
            "codeberg.org" => (WebHost::Codeberg, "codeberg.org"),
            "gitea.com" => (WebHost::Gitea, "gitea.com"),
            _ => return azure(&host, path),
        };
        let segments = path.split('/').filter(|s| !s.is_empty()).count();
        // GitLab has groups and subgroups; the others are owner/repo.
        let enough = if kind == WebHost::GitLab {
            segments >= 2
        } else {
            segments == 2
        };
        enough.then(|| WebRepo {
            host: kind,
            base: format!("https://{web_host}/{path}"),
        })
    }

    /// The page of `target`.
    pub fn url(&self, target: WebTarget) -> String {
        let base = &self.base;
        match (self.host, target) {
            (WebHost::GitHub, WebTarget::Commit(oid)) => format!("{base}/commit/{oid}"),
            (WebHost::GitHub, WebTarget::Branch(name)) => {
                format!("{base}/tree/{}", encode_path(name))
            }
            (WebHost::GitHub, WebTarget::Tag(name)) => {
                format!("{base}/releases/tag/{}", encode_path(name))
            }
            (WebHost::GitHub, WebTarget::File { commit, path }) => {
                format!("{base}/blob/{commit}/{}", encode_path(path))
            }
            (WebHost::GitLab, WebTarget::Commit(oid)) => format!("{base}/-/commit/{oid}"),
            (WebHost::GitLab, WebTarget::Branch(name)) => {
                format!("{base}/-/tree/{}", encode_path(name))
            }
            (WebHost::GitLab, WebTarget::Tag(name)) => {
                format!("{base}/-/tags/{}", encode_path(name))
            }
            (WebHost::GitLab, WebTarget::File { commit, path }) => {
                format!("{base}/-/blob/{commit}/{}", encode_path(path))
            }
            (WebHost::Bitbucket, WebTarget::Commit(oid)) => format!("{base}/commits/{oid}"),
            (WebHost::Bitbucket, WebTarget::Branch(name) | WebTarget::Tag(name)) => {
                format!("{base}/src/{}", encode_path(name))
            }
            (WebHost::Bitbucket, WebTarget::File { commit, path }) => {
                format!("{base}/src/{commit}/{}", encode_path(path))
            }
            (WebHost::AzureDevOps, WebTarget::Commit(oid)) => format!("{base}/commit/{oid}"),
            (WebHost::AzureDevOps, WebTarget::Branch(name)) => {
                format!("{base}?version=GB{}", encode_component(name))
            }
            (WebHost::AzureDevOps, WebTarget::Tag(name)) => {
                format!("{base}?version=GT{}", encode_component(name))
            }
            (WebHost::AzureDevOps, WebTarget::File { commit, path }) => format!(
                "{base}?path={}&version=GC{commit}",
                encode_component(&format!("/{path}"))
            ),
            (WebHost::Codeberg | WebHost::Gitea, WebTarget::Commit(oid)) => {
                format!("{base}/commit/{oid}")
            }
            (WebHost::Codeberg | WebHost::Gitea, WebTarget::Branch(name)) => {
                format!("{base}/src/branch/{}", encode_path(name))
            }
            (WebHost::Codeberg | WebHost::Gitea, WebTarget::Tag(name)) => {
                format!("{base}/src/tag/{}", encode_path(name))
            }
            (WebHost::Codeberg | WebHost::Gitea, WebTarget::File { commit, path }) => {
                format!("{base}/src/commit/{commit}/{}", encode_path(path))
            }
        }
    }
}

/// Azure DevOps: `https://[user@]dev.azure.com/org/project/_git/repo`,
/// `git@ssh.dev.azure.com:v3/org/project/repo`,
/// `https://org.visualstudio.com/[DefaultCollection/]project/_git/repo` and
/// `org@vs-ssh.visualstudio.com:v3/org/project/repo`.
fn azure(host: &str, path: &str) -> Option<WebRepo> {
    let parts: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    let base = match host {
        "dev.azure.com" => match parts.as_slice() {
            [org, project, "_git", repo] => {
                format!("https://dev.azure.com/{org}/{project}/_git/{repo}")
            }
            _ => return None,
        },
        "ssh.dev.azure.com" | "vs-ssh.visualstudio.com" => match parts.as_slice() {
            ["v3", org, project, repo] => {
                format!("https://dev.azure.com/{org}/{project}/_git/{repo}")
            }
            _ => return None,
        },
        _ if host.ends_with(".visualstudio.com") => match parts.as_slice() {
            [project, "_git", repo] | ["DefaultCollection", project, "_git", repo] => {
                format!("https://{host}/{project}/_git/{repo}")
            }
            _ => return None,
        },
        _ => return None,
    };
    Some(WebRepo {
        host: WebHost::AzureDevOps,
        base,
    })
}

/// `(scheme, host[:port], path)` of a remote URL: `scheme://[user@]host/path`
/// or scp-like `[user@]host:path` (scheme `ssh`). Local paths give `None`.
pub(crate) fn split_remote_url(url: &str) -> Option<(String, String, String)> {
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

/// Percent-encodes `text` for a URL path, keeping `/`.
fn encode_path(text: &str) -> String {
    encode(text, true)
}

/// Percent-encodes `text` for a query value.
fn encode_component(text: &str) -> String {
    encode(text, false)
}

fn encode(text: &str, keep_slash: bool) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        let plain = byte.is_ascii_alphanumeric()
            || matches!(byte, b'-' | b'_' | b'.' | b'~')
            || (keep_slash && byte == b'/');
        if plain {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base(url: &str) -> Option<(WebHost, String)> {
        WebRepo::from_remote_url(url).map(|r| (r.host, r.base))
    }

    #[test]
    fn recognises_known_hosts_in_every_url_form() {
        let github = Some((WebHost::GitHub, "https://github.com/owner/repo".to_owned()));
        assert_eq!(base("https://github.com/owner/repo.git"), github);
        assert_eq!(base("https://user@github.com/owner/repo"), github);
        assert_eq!(base("git@github.com:owner/repo.git"), github);
        assert_eq!(base("ssh://git@ssh.github.com:443/owner/repo.git"), github);
        assert_eq!(base("https://GitHub.com/owner/repo/"), github);
        assert_eq!(
            base("git@gitlab.com:group/sub/project.git"),
            Some((
                WebHost::GitLab,
                "https://gitlab.com/group/sub/project".to_owned()
            ))
        );
        assert_eq!(
            base("https://bitbucket.org/team/repo.git"),
            Some((
                WebHost::Bitbucket,
                "https://bitbucket.org/team/repo".to_owned()
            ))
        );
        assert_eq!(
            base("https://codeberg.org/me/thing.git"),
            Some((
                WebHost::Codeberg,
                "https://codeberg.org/me/thing".to_owned()
            ))
        );
        assert_eq!(
            base("git@gitea.com:me/thing.git"),
            Some((WebHost::Gitea, "https://gitea.com/me/thing".to_owned()))
        );
    }

    #[test]
    fn maps_azure_devops_remotes_to_their_web_page() {
        let page = Some((
            WebHost::AzureDevOps,
            "https://dev.azure.com/org/Project/_git/repo".to_owned(),
        ));
        assert_eq!(
            base("https://org@dev.azure.com/org/Project/_git/repo"),
            page
        );
        assert_eq!(base("git@ssh.dev.azure.com:v3/org/Project/repo"), page);
        assert_eq!(
            base("org@vs-ssh.visualstudio.com:v3/org/Project/repo"),
            page
        );
        assert_eq!(
            base("https://org.visualstudio.com/DefaultCollection/Project/_git/repo"),
            Some((
                WebHost::AzureDevOps,
                "https://org.visualstudio.com/Project/_git/repo".to_owned()
            ))
        );
        assert_eq!(base("https://dev.azure.com/org/Project"), None);
    }

    #[test]
    fn unknown_hosts_and_local_paths_have_no_page() {
        assert_eq!(base("https://git.example.com/owner/repo.git"), None);
        assert_eq!(base("git@gitlab.example.com:owner/repo.git"), None);
        assert_eq!(base("C:\\repos\\origin.git"), None);
        assert_eq!(base("/srv/git/repo.git"), None);
        assert_eq!(base("file:///srv/git/repo.git"), None);
        assert_eq!(base("../origin.git"), None);
        assert_eq!(base("https://github.com/owner"), None);
        assert_eq!(base("https://github.com/owner/repo/extra"), None);
    }

    #[test]
    fn builds_each_hosts_pages() {
        let oid = "0123456789abcdef0123456789abcdef01234567";
        let file = WebTarget::File {
            commit: oid,
            path: "src/my file.rs",
        };
        let page = |url: &str, target: WebTarget| {
            WebRepo::from_remote_url(url)
                .map(|r| r.url(target))
                .unwrap_or_default()
        };
        let gh = "git@github.com:o/r.git";
        assert_eq!(
            page(gh, WebTarget::Commit(oid)),
            format!("https://github.com/o/r/commit/{oid}")
        );
        assert_eq!(
            page(gh, WebTarget::Branch("feature/login")),
            "https://github.com/o/r/tree/feature/login"
        );
        assert_eq!(
            page(gh, WebTarget::Tag("v1.0")),
            "https://github.com/o/r/releases/tag/v1.0"
        );
        assert_eq!(
            page(gh, file),
            format!("https://github.com/o/r/blob/{oid}/src/my%20file.rs")
        );
        let gl = "https://gitlab.com/g/s/p.git";
        assert_eq!(
            page(gl, WebTarget::Commit(oid)),
            format!("https://gitlab.com/g/s/p/-/commit/{oid}")
        );
        assert_eq!(
            page(gl, WebTarget::Branch("a#b")),
            "https://gitlab.com/g/s/p/-/tree/a%23b"
        );
        assert_eq!(
            page(gl, WebTarget::Tag("v1")),
            "https://gitlab.com/g/s/p/-/tags/v1"
        );
        let bb = "https://bitbucket.org/t/r.git";
        assert_eq!(
            page(bb, WebTarget::Commit(oid)),
            format!("https://bitbucket.org/t/r/commits/{oid}")
        );
        assert_eq!(
            page(bb, WebTarget::Branch("main")),
            "https://bitbucket.org/t/r/src/main"
        );
        assert_eq!(
            page(bb, file),
            format!("https://bitbucket.org/t/r/src/{oid}/src/my%20file.rs")
        );
        let az = "https://dev.azure.com/o/P/_git/r";
        assert_eq!(
            page(az, WebTarget::Commit(oid)),
            format!("{az}/commit/{oid}")
        );
        assert_eq!(
            page(az, WebTarget::Branch("feature/x")),
            format!("{az}?version=GBfeature%2Fx")
        );
        assert_eq!(page(az, WebTarget::Tag("v2")), format!("{az}?version=GTv2"));
        assert_eq!(
            page(az, file),
            format!("{az}?path=%2Fsrc%2Fmy%20file.rs&version=GC{oid}")
        );
        let cb = "https://codeberg.org/me/t.git";
        assert_eq!(
            page(cb, WebTarget::Branch("dev")),
            "https://codeberg.org/me/t/src/branch/dev"
        );
        assert_eq!(
            page(cb, WebTarget::Tag("v3")),
            "https://codeberg.org/me/t/src/tag/v3"
        );
        assert_eq!(
            page(cb, file),
            format!("https://codeberg.org/me/t/src/commit/{oid}/src/my%20file.rs")
        );
    }
}
