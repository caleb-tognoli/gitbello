//! A person's commit on a remote (PLAN M7.10): one the remote's host
//! knows, so its commit API can give that person's profile picture.

use std::path::Path;

use super::CliBackend;
use crate::git::{CancelToken, GitError};

impl CliBackend {
    pub(super) fn find_published_commit(
        &self,
        repo: &Path,
        remote: &str,
        email: &str,
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError> {
        let email = email.trim();
        // A remote name never reaches git as a flag or a glob.
        let plain = |s: &str| !s.is_empty() && !s.starts_with('-') && !s.contains(['*', '?', '[']);
        if !plain(remote) || !email.contains('@') {
            return Ok(None);
        }
        let remotes = format!("--remotes={remote}");
        // `Name <email>`: the brackets match the whole address, not a part
        // of a longer one. Author and committer patterns together must both
        // match, so the committer is a second read.
        for field in ["--author", "--committer"] {
            let pattern = format!("{field}=<{email}>");
            let args = [
                "log",
                "-1",
                "--format=%H",
                "--regexp-ignore-case",
                "--fixed-strings",
                &pattern,
                &remotes,
                "--",
            ];
            let out = self.read(repo, &args, cancel)?;
            let oid = out.stdout_text().trim().to_string();
            if !oid.is_empty() {
                return Ok(Some(oid));
            }
        }
        Ok(None)
    }
}
