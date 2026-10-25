//! Repository read models and the parsers that build them from git output
//! (PLAN §3.3). Parsers are pure functions over captured bytes.

mod commit;
mod operation;
mod refs;
mod stash;
mod status;
mod worktree;

use std::path::PathBuf;

use thiserror::Error;

pub use commit::{
    parse_commit_header, parse_name_status, CommitDetails, CommitFile, COMMIT_SHOW_FORMAT,
};
pub use operation::{detect_operation, parse_repo_paths, Operation, RepoPaths, REPO_PATHS_ARGS};
pub use refs::{
    parse_refs, parse_remote_urls, parse_remotes, Ref, RefKind, Remote, Tracking, REFS_ARGS,
};
pub use stash::{parse_stash_list, StashEntry, STASH_LIST_ARGS};
pub use status::{
    parse_status, Change, Conflict, FileChange, FileState, Head, RepoStatus, STATUS_ARGS,
};
pub use worktree::{parse_worktrees, Worktree, WORKTREES_ARGS};

/// Output that does not match the documented format.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("cannot parse {what}: {detail}")]
pub struct ParseError {
    pub what: &'static str,
    pub detail: String,
}

impl ParseError {
    pub(crate) fn new(what: &'static str, detail: impl Into<String>) -> Self {
        Self {
            what,
            detail: detail.into(),
        }
    }
}

/// A path as printed by git. With `core.quotepath=false` and `-z`, git prints
/// raw bytes: UTF-8 on Windows, arbitrary bytes on Unix.
pub(crate) fn git_path(bytes: &[u8]) -> PathBuf {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        PathBuf::from(std::ffi::OsStr::from_bytes(bytes))
    }
    #[cfg(not(unix))]
    {
        PathBuf::from(String::from_utf8_lossy(bytes).into_owned())
    }
}

pub(crate) fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}
