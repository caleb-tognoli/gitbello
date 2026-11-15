//! "Open on GitHub": the web pages of a commit, a pushed branch, a
//! tag and a file at a commit, on the host of the remote they are on.

use super::*;
use crate::web_links::{WebHost, WebRepo, WebTarget};

impl RepoState {
    /// The page of ref `full_name` (`refs/heads/x` with a live upstream,
    /// `refs/remotes/origin/x` or `refs/tags/v1`) and its host, `None` when
    /// the ref is on no remote of a known host.
    pub fn ref_web_page(&self, full_name: &str) -> Option<(WebHost, String)> {
        if let Some(branch) = full_name.strip_prefix("refs/heads/") {
            let upstream = self.live_upstream(branch)?;
            let repo = self.web_repo(&upstream.remote)?;
            return Some((repo.host, repo.url(WebTarget::Branch(&upstream.branch))));
        }
        if full_name.starts_with("refs/remotes/") {
            let found = self.refs.as_deref()?.iter().find(|r| r.name == full_name)?;
            let RefKind::RemoteBranch { remote } = &found.kind else {
                return None;
            };
            let branch = found.remote_branch_name()?;
            if branch == "HEAD" {
                return None;
            }
            let repo = self.web_repo(remote)?;
            return Some((repo.host, repo.url(WebTarget::Branch(branch))));
        }
        let tag = full_name.strip_prefix("refs/tags/")?;
        let repo = self.web_repo(&self.default_remote()?)?;
        Some((repo.host, repo.url(WebTarget::Tag(tag))))
    }

    /// The page of commit `oid`, or of file `path` as it is at `oid`, on the
    /// default remote's host.
    pub fn commit_web_page(&self, oid: &str, path: Option<&str>) -> Option<(WebHost, String)> {
        let repo = self.web_repo(&self.default_remote()?)?;
        let target = match path {
            Some(path) => WebTarget::File { commit: oid, path },
            None => WebTarget::Commit(oid),
        };
        Some((repo.host, repo.url(target)))
    }

    fn web_repo(&self, remote: &str) -> Option<WebRepo> {
        let remote = self.remote_list().iter().find(|r| r.name == remote)?;
        WebRepo::from_remote_url(&remote.fetch_url)
    }
}
