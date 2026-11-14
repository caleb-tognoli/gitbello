//! Finding uncommitted moves (see [`crate::moves`]): the untracked files are
//! added intent-to-add to a scratch copy of the index, where git's rename
//! detection pairs them with the deleted files.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use super::{pathspec_input, CliBackend, GitBackend, DIFF_ARGS, PATHSPEC_STDIN};
use crate::git::{CancelToken, GitError, GitErrorKind};
use crate::moves::{self, Candidates, Move};
use crate::repo::RepoStatus;

/// The moves found in one worktree and the fingerprint of their candidates.
type Found = (u64, Vec<Move>);

/// Moves found per worktree, keyed by the fingerprint of their candidates.
#[derive(Debug, Clone, Default)]
pub(super) struct MoveCache(Arc<Mutex<HashMap<PathBuf, Found>>>);

/// A scratch index under the git dir (which the watcher ignores), removed
/// when dropped.
pub(super) struct ScratchIndex(pub(super) PathBuf);

impl Drop for ScratchIndex {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
        let _ = fs::remove_file(self.0.with_extension("lock"));
    }
}

impl CliBackend {
    pub(super) fn find_moves(
        &self,
        repo: &Path,
        status: &mut RepoStatus,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let Some(candidates) = Candidates::of(status) else {
            return Ok(());
        };
        let toplevel = self.toplevel(repo, cancel)?;
        let fingerprint = candidates.fingerprint(status, &toplevel);
        let cached = {
            let cache = self.moves.0.lock().unwrap_or_else(PoisonError::into_inner);
            cache
                .get(&toplevel)
                .filter(|(print, _)| *print == fingerprint)
                .map(|(_, found)| found.clone())
        };
        let found = match cached {
            Some(found) => found,
            None => {
                let index = self.intent_to_add_index(&toplevel, &candidates.untracked, cancel)?;
                let mut args = DIFF_ARGS.to_vec();
                args.extend(["-z", "-M", "--name-status", "--diff-filter=R"]);
                let out = self
                    .runner
                    .read(&toplevel)
                    .env("GIT_INDEX_FILE", &index.0)
                    .args(args)
                    .cancel_token(cancel)
                    .run()?;
                let found =
                    moves::parse_renames(&out.stdout, &candidates.deleted, &candidates.untracked);
                self.moves
                    .0
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .insert(toplevel, (fingerprint, found.clone()));
                found
            }
        };
        moves::apply(status, &found);
        Ok(())
    }

    /// Whether the index has an entry for `path`.
    pub(super) fn in_index(
        &self,
        toplevel: &Path,
        path: &Path,
        cancel: &CancelToken,
    ) -> Result<bool, GitError> {
        let out = self
            .runner
            .read(toplevel)
            .env("GIT_LITERAL_PATHSPECS", "1")
            .args(["ls-files", "-z", "--"])
            .arg(path)
            .cancel_token(cancel)
            .run()?;
        Ok(!out.stdout.is_empty())
    }

    /// A copy of `toplevel`'s index with `paths` (untracked files) added
    /// intent-to-add, so diffs against it see them as new files.
    pub(super) fn intent_to_add_index(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<ScratchIndex, GitError> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let name = format!(
            "gitbello-moves-index-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let git_path = |name: &str| -> Result<PathBuf, GitError> {
            let out = self.read(
                toplevel,
                &["rev-parse", "--path-format=absolute", "--git-path", name],
                cancel,
            )?;
            Ok(PathBuf::from(out.stdout_text().trim()))
        };
        let index = ScratchIndex(git_path(&name)?);
        let real = git_path("index")?;
        if real.is_file() {
            fs::copy(&real, &index.0).map_err(|err| {
                GitError::new(
                    format!("copy {}", real.display()),
                    GitErrorKind::Io,
                    err.to_string(),
                )
            })?;
        }
        self.mark_intent_to_add(toplevel, &index.0, paths, cancel)?;
        Ok(index)
    }

    /// Adds `paths` intent-to-add to the index file `index`.
    pub(super) fn mark_intent_to_add(
        &self,
        toplevel: &Path,
        index: &Path,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        self.runner
            .write(toplevel)
            .env("GIT_INDEX_FILE", index)
            .env("GIT_LITERAL_PATHSPECS", "1")
            .args(["add", "--intent-to-add"])
            .args(PATHSPEC_STDIN)
            .stdin(pathspec_input(paths))
            .cancel_token(cancel)
            .run()
            .map(drop)
    }
}
