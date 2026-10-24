//! The `GitBackend` trait and its git CLI implementation (PLAN §3.3).
//!
//! M2 covers reads. Writes are added by the milestones that need them.

use std::path::{Path, PathBuf};

use crate::git::{CancelToken, GitError, GitErrorKind, GitOutput, GitRunner};
use crate::repo::{
    detect_operation, parse_refs, parse_remotes, parse_repo_paths, parse_stash_list, parse_status,
    parse_worktrees, Operation, ParseError, Ref, RepoPaths, RepoStatus, StashEntry, Worktree,
    REFS_ARGS, REPO_PATHS_ARGS, STASH_LIST_ARGS, STATUS_ARGS, WORKTREES_ARGS,
};

/// Read access to a repository. `repo` is any directory inside a worktree (or
/// a bare repository). Implementations must be usable from worker threads.
pub trait GitBackend: Send + Sync {
    fn repo_paths(&self, repo: &Path, cancel: &CancelToken) -> Result<RepoPaths, GitError>;
    fn status(&self, repo: &Path, cancel: &CancelToken) -> Result<RepoStatus, GitError>;
    fn refs(&self, repo: &Path, cancel: &CancelToken) -> Result<Vec<Ref>, GitError>;
    fn worktrees(&self, repo: &Path, cancel: &CancelToken) -> Result<Vec<Worktree>, GitError>;
    fn operation(&self, repo: &Path, cancel: &CancelToken) -> Result<Option<Operation>, GitError>;
    fn stashes(&self, repo: &Path, cancel: &CancelToken) -> Result<Vec<StashEntry>, GitError>;
    /// The subset of `paths` that git ignores (used by the watcher to skip
    /// changes in build output and similar).
    fn ignored(
        &self,
        repo: &Path,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError>;
}

/// [`GitBackend`] over the system git executable.
#[derive(Debug, Clone)]
pub struct CliBackend {
    runner: GitRunner,
}

impl CliBackend {
    pub fn new(runner: GitRunner) -> Self {
        Self { runner }
    }

    pub fn runner(&self) -> &GitRunner {
        &self.runner
    }

    fn read(
        &self,
        repo: &Path,
        args: &[&str],
        cancel: &CancelToken,
    ) -> Result<GitOutput, GitError> {
        self.runner.read(repo).args(args).cancel_token(cancel).run()
    }
}

fn unexpected(args: &[&str], err: ParseError) -> GitError {
    GitError::new(
        args.join(" "),
        GitErrorKind::UnexpectedOutput,
        err.to_string(),
    )
}

impl GitBackend for CliBackend {
    fn repo_paths(&self, repo: &Path, cancel: &CancelToken) -> Result<RepoPaths, GitError> {
        let out = self.read(repo, REPO_PATHS_ARGS, cancel)?;
        parse_repo_paths(&out.stdout).map_err(|e| unexpected(REPO_PATHS_ARGS, e))
    }

    fn status(&self, repo: &Path, cancel: &CancelToken) -> Result<RepoStatus, GitError> {
        let out = self.read(repo, STATUS_ARGS, cancel)?;
        parse_status(&out.stdout).map_err(|e| unexpected(STATUS_ARGS, e))
    }

    fn refs(&self, repo: &Path, cancel: &CancelToken) -> Result<Vec<Ref>, GitError> {
        let remotes = parse_remotes(&self.read(repo, &["remote"], cancel)?.stdout);
        let out = self.read(repo, REFS_ARGS, cancel)?;
        parse_refs(&out.stdout, &remotes).map_err(|e| unexpected(REFS_ARGS, e))
    }

    fn worktrees(&self, repo: &Path, cancel: &CancelToken) -> Result<Vec<Worktree>, GitError> {
        let out = self.read(repo, WORKTREES_ARGS, cancel)?;
        parse_worktrees(&out.stdout).map_err(|e| unexpected(WORKTREES_ARGS, e))
    }

    fn operation(&self, repo: &Path, cancel: &CancelToken) -> Result<Option<Operation>, GitError> {
        let paths = self.repo_paths(repo, cancel)?;
        Ok(detect_operation(&paths.git_dir))
    }

    fn stashes(&self, repo: &Path, cancel: &CancelToken) -> Result<Vec<StashEntry>, GitError> {
        let out = self.read(repo, STASH_LIST_ARGS, cancel)?;
        parse_stash_list(&out.stdout).map_err(|e| unexpected(STASH_LIST_ARGS, e))
    }

    fn ignored(
        &self,
        repo: &Path,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        if paths.is_empty() {
            return Ok(Vec::new());
        }
        let mut input = Vec::new();
        for path in paths {
            input.extend_from_slice(path.to_string_lossy().as_bytes());
            input.push(0);
        }
        let result = self
            .runner
            .read(repo)
            .args(["check-ignore", "-z", "--stdin"])
            .stdin(input)
            .cancel_token(cancel)
            .run();
        match result {
            Ok(out) => Ok(out
                .stdout
                .split(|&b| b == 0)
                .filter(|p| !p.is_empty())
                .map(crate::repo::git_path)
                .collect()),
            // Exit code 1 means "none of the paths are ignored".
            Err(err) if err.exit_code == Some(1) => Ok(Vec::new()),
            Err(err) => Err(err),
        }
    }
}
