//! Split a stash without checking it out or touching the user's index.

use std::fs::{self, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use super::{pathspec_input, stale_shelf, CliBackend, GitBackend, ShelfChange};
use crate::git::{CancelToken, GitError, GitErrorKind};
use crate::repo::{parse_name_status, Shelf};

static NEXT_INDEX: AtomicUsize = AtomicUsize::new(0);

struct ScratchIndex(PathBuf);

impl Drop for ScratchIndex {
    fn drop(&mut self) {
        let _ = fs::remove_file(self.0.join("index"));
        let _ = fs::remove_file(self.0.join("index.lock"));
        let _ = fs::remove_dir(&self.0);
    }
}

/// Worktrees share their stash ref. Refuse overlapping file edits in another
/// process/worktree rather than racing a multi-command replacement.
pub(super) struct ShelfLock(PathBuf);

impl Drop for ShelfLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn error(message: impl Into<String>) -> GitError {
    GitError::new("shelf file", GitErrorKind::Other, message)
}

fn backup_ref(oid: &str) -> String {
    format!("refs/gitbello/shelf-backup/{oid}")
}

impl CliBackend {
    pub(super) fn shelf_lock(
        &self,
        repo: &Path,
        cancel: &CancelToken,
    ) -> Result<ShelfLock, GitError> {
        let file = self
            .repo_paths(repo, cancel)?
            .common_dir
            .join("gitbello-shelf-edit.lock");
        OpenOptions::new().write(true).create_new(true).open(&file)
            .map_err(|e| GitError::new("shelf", GitErrorKind::LockExists, format!("Cannot lock the shelf for editing: {e}. If another shelf edit is running, wait for it to finish.")))?;
        Ok(ShelfLock(file))
    }

    pub(super) fn edit_shelf_file(
        &self,
        repo: &Path,
        oid: &str,
        path: &Path,
        restore: bool,
        cancel: &CancelToken,
    ) -> Result<ShelfChange, GitError> {
        let _lock = self.shelf_lock(repo, cancel)?;
        let original = crate::repo::shelves(&self.stashes(repo, cancel)?)
            .into_iter()
            .find(|s| s.oid == oid)
            .ok_or_else(|| stale_shelf(oid))?;
        let files = self.shelf_files(repo, oid, cancel)?;
        let file = files
            .iter()
            .find(|f| f.path == path)
            .ok_or_else(|| error("The file is no longer present in this shelf."))?;
        let mut paths = vec![file.path.clone()];
        if let Some(old) = &file.original_path {
            paths.push(old.clone());
        }
        if !file.untracked {
            // An index rename and a worktree rename may have different
            // destinations. Treat their shared source and both destinations
            // as one file operation rather than losing half a rename.
            let staged = self.read(
                repo,
                &[
                    "diff",
                    "--no-ext-diff",
                    "--no-textconv",
                    "--name-status",
                    "-z",
                    "-M",
                    &format!("{oid}^1"),
                    &format!("{oid}^2"),
                    "--",
                ],
                cancel,
            )?;
            let staged = parse_name_status(&staged.stdout).map_err(|e| error(e.to_string()))?;
            loop {
                let before = paths.len();
                for change in &staged {
                    if paths.contains(&change.path)
                        || change
                            .original_path
                            .as_ref()
                            .is_some_and(|p| paths.contains(p))
                    {
                        for path in std::iter::once(&change.path).chain(change.original_path.iter())
                        {
                            if !paths.contains(path) {
                                paths.push(path.clone());
                            }
                        }
                    }
                }
                if paths.len() == before {
                    break;
                }
            }
        }
        if restore {
            let status = self.status(repo, cancel)?;
            let tracked = self
                .runner
                .read(repo)
                .args([
                    "--literal-pathspecs",
                    "ls-tree",
                    "-r",
                    "-z",
                    "--full-tree",
                    "HEAD",
                    "--",
                ])
                .args(&paths)
                .cancel_token(cancel)
                .run()?;
            let tracked: Vec<PathBuf> = tracked
                .stdout
                .split(|b| *b == 0)
                .filter_map(|entry| entry.splitn(2, |b| *b == b'\t').nth(1))
                .map(crate::repo::git_path)
                .collect();
            // Ignored files do not appear in ordinary status. Protect them
            // too when a shelf adds a path absent from the current HEAD.
            let collides = paths.iter().any(|path| {
                !tracked.contains(path) && fs::symlink_metadata(repo.join(path)).is_ok()
            });
            if status.has_conflicts()
                || collides
                || status.changes.iter().any(|c| {
                    paths.contains(&c.path)
                        || c.original_path.as_ref().is_some_and(|p| paths.contains(p))
                })
            {
                return Err(GitError::new("restore shelf file", GitErrorKind::LocalChanges,
                    "This file has local changes, or the worktree has unresolved conflicts. Commit or shelve them before restoring this file."));
            }
        }
        let git_dir = self.repo_paths(repo, cancel)?.git_dir;
        let scratch_path = git_dir.join(format!(
            "gitbello-shelf-index-{}-{}",
            std::process::id(),
            NEXT_INDEX.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&scratch_path)
            .map_err(|e| error(format!("Cannot create temporary shelf index: {e}")))?;
        let scratch = ScratchIndex(scratch_path);
        let index = scratch.0.join("index");
        let base = self
            .resolve(repo, &format!("{oid}^1"), cancel)?
            .ok_or_else(|| error("The shelf has no base commit."))?;
        let staged = format!("{oid}^2");
        let untracked = self.resolve(repo, &format!("{oid}^3"), cancel)?;
        // Write the empty tree before using it in read-tree, including repos
        // that have never stored an empty tree before.
        let empty = self
            .runner
            .write(repo)
            .args(["mktree", "-z"])
            .stdin(Vec::new())
            .cancel_token(cancel)
            .run()?
            .stdout_text()
            .trim()
            .to_owned();
        let remainder_work = if file.untracked {
            self.tree_id(repo, oid, cancel)?
        } else {
            self.overlay_paths(repo, &index, oid, &base, &paths, cancel)?
        };
        let remainder_index = if file.untracked {
            self.tree_id(repo, &staged, cancel)?
        } else {
            self.overlay_paths(repo, &index, &staged, &base, &paths, cancel)?
        };
        let remainder_untracked = match untracked.as_deref() {
            Some(tree) if file.untracked => {
                self.overlay_paths(repo, &index, tree, &empty, &paths, cancel)?
            }
            Some(tree) => self.tree_id(repo, tree, cancel)?,
            None => empty.clone(),
        };
        let base_tree = self.tree_id(repo, &base, cancel)?;
        // Index-only changes can remain even when the worktree equals base.
        let has_remainder = remainder_work != base_tree
            || remainder_index != base_tree
            || remainder_untracked != empty;
        let remainder = if has_remainder {
            Some(self.make_stash(
                repo,
                &base,
                [
                    &remainder_index,
                    &remainder_work,
                    &remainder_untracked,
                    &empty,
                ],
                &original,
                cancel,
            )?)
        } else {
            None
        };
        let selected = if restore {
            let work = if file.untracked {
                base_tree.clone()
            } else {
                self.overlay_paths(repo, &index, &base, oid, &paths, cancel)?
            };
            let staged_tree = if file.untracked {
                base_tree
            } else {
                self.overlay_paths(repo, &index, &base, &staged, &paths, cancel)?
            };
            let untracked_tree = if file.untracked {
                self.overlay_paths(
                    repo,
                    &index,
                    &empty,
                    untracked
                        .as_deref()
                        .ok_or_else(|| error("Missing untracked tree."))?,
                    &paths,
                    cancel,
                )?
            } else {
                empty.clone()
            };
            Some(self.make_stash(
                repo,
                &base,
                [&staged_tree, &work, &untracked_tree, &empty],
                &original,
                cancel,
            )?)
        } else {
            None
        };

        // Protect the original before applying or replacing anything. From
        // here, completion/recovery must not be interrupted by cancellation.
        self.runner
            .write(repo)
            .args(["update-ref", &backup_ref(oid), oid])
            .cancel_token(cancel)
            .run()?;
        let finish = CancelToken::new();
        if let Some(selected) = selected {
            if let Err(e) = self.apply_shelf_part(repo, &index, &selected, &paths, &finish) {
                // The original is still listed, so the backup is redundant.
                let _ = self.remove_shelf_backup(repo, oid, &finish);
                return Err(e);
            }
        }
        // Store first. If dropping the original fails, both remain reachable.
        if let Some(new) = &remainder {
            self.store_shelf_unlocked(repo, new, &original.subject, &finish)?;
        }
        self.drop_shelf_unlocked(repo, oid, &finish)?;
        if restore {
            self.remove_shelf_backup(repo, oid, &finish)?;
        }
        Ok(ShelfChange {
            old_oid: oid.to_owned(),
            new_oid: remainder,
            subject: original.subject,
        })
    }

    fn apply_shelf_part(
        &self,
        repo: &Path,
        index: &Path,
        oid: &str,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        // A temporary HEAD index makes unrelated staged changes look like
        // ordinary untouched working files to stash apply. Afterwards copy
        // only the selected paths back, preserving all other real entries.
        self.runner
            .write(repo)
            .env("GIT_INDEX_FILE", index)
            .args(["read-tree", "HEAD"])
            .cancel_token(cancel)
            .run()?;
        let apply = |staged: bool| {
            let mut cmd = self
                .runner
                .write(repo)
                .env("GIT_INDEX_FILE", index)
                .args(["stash", "apply"]);
            if staged {
                cmd = cmd.arg("--index");
            }
            cmd.arg(oid).cancel_token(cancel).run().map(drop)
        };
        let applied = match apply(true) {
            Err(e) if e.stderr.contains("--index") => apply(false),
            result => result,
        };
        // Carry conflict stages back too, so a branch/base conflict can be
        // resolved normally while the complete original shelf remains safe.
        let entries = self
            .runner
            .read(repo)
            .env("GIT_INDEX_FILE", index)
            .args(["--literal-pathspecs", "ls-files", "--stage", "-z", "--"])
            .args(paths)
            .cancel_token(cancel)
            .run()?;
        let mut input = Vec::new();
        for path in paths {
            input.extend_from_slice(format!("0 {}\t", "0".repeat(oid.len())).as_bytes());
            input.extend_from_slice(path.to_string_lossy().as_bytes());
            input.push(0);
        }
        input.extend(entries.stdout);
        self.runner
            .write(repo)
            .args(["update-index", "-z", "--index-info"])
            .stdin(input)
            .cancel_token(cancel)
            .run()?;
        applied
    }

    fn tree_id(&self, repo: &Path, rev: &str, cancel: &CancelToken) -> Result<String, GitError> {
        Ok(self
            .read(
                repo,
                &["rev-parse", "--verify", &format!("{rev}^{{tree}}")],
                cancel,
            )?
            .stdout_text()
            .trim()
            .to_owned())
    }

    fn overlay_paths(
        &self,
        repo: &Path,
        index: &Path,
        start: &str,
        source: &str,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<String, GitError> {
        let git = || {
            self.runner
                .write(repo)
                .env("GIT_INDEX_FILE", index)
                .cancel_token(cancel)
        };
        git().args(["read-tree", start]).run()?;
        git()
            .args(["update-index", "--force-remove", "-z", "--stdin"])
            .stdin(pathspec_input(paths))
            .run()?;
        let entries = self
            .runner
            .read(repo)
            .args([
                "--literal-pathspecs",
                "ls-tree",
                "-r",
                "-z",
                "--full-tree",
                source,
                "--",
            ])
            .args(paths)
            .cancel_token(cancel)
            .run()?;
        // --index-info accepts ls-tree's mode/type/oid format verbatim.
        git()
            .args(["update-index", "-z", "--index-info"])
            .stdin(entries.stdout)
            .run()?;
        Ok(git()
            .arg("write-tree")
            .run()?
            .stdout_text()
            .trim()
            .to_owned())
    }

    fn make_stash(
        &self,
        repo: &Path,
        base: &str,
        trees: [&str; 4],
        original: &Shelf,
        cancel: &CancelToken,
    ) -> Result<String, GitError> {
        let [staged, work, untracked, empty] = trees;
        let index =
            self.shelf_commit(repo, staged, &[base], "Shelf index", original.time, cancel)?;
        let mut parents = vec![base.to_owned(), index];
        if untracked != empty {
            parents.push(self.shelf_commit(
                repo,
                untracked,
                &[],
                "Untracked shelf files",
                original.time,
                cancel,
            )?);
        }
        let parents: Vec<&str> = parents.iter().map(String::as_str).collect();
        self.shelf_commit(
            repo,
            work,
            &parents,
            &original.subject,
            original.time,
            cancel,
        )
    }

    fn shelf_commit(
        &self,
        repo: &Path,
        tree: &str,
        parents: &[&str],
        subject: &str,
        time: i64,
        cancel: &CancelToken,
    ) -> Result<String, GitError> {
        // These are internal stash objects, not user commits. No hooks,
        // signing, or configured identity is required.
        let mut git = self
            .runner
            .write(repo)
            .args(["-c", "commit.gpgsign=false", "commit-tree", tree])
            .env("GIT_AUTHOR_NAME", "gitbello")
            .env("GIT_AUTHOR_EMAIL", "shelf@gitbello.local")
            .env("GIT_COMMITTER_NAME", "gitbello")
            .env("GIT_COMMITTER_EMAIL", "shelf@gitbello.local")
            .env("GIT_AUTHOR_DATE", format!("@{time} +0000"))
            .env("GIT_COMMITTER_DATE", format!("@{time} +0000"))
            .cancel_token(cancel);
        for parent in parents {
            git = git.args(["-p", parent]);
        }
        Ok(git
            .stdin(subject.as_bytes().to_vec())
            .run()?
            .stdout_text()
            .trim()
            .to_owned())
    }

    pub(super) fn undo_shelf_file_change(
        &self,
        repo: &Path,
        change: &ShelfChange,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let _lock = self.shelf_lock(repo, cancel)?;
        let shelves = crate::repo::shelves(&self.stashes(repo, cancel)?);
        if shelves.iter().any(|s| s.oid == change.old_oid) {
            return Err(error(
                "The original shelf already exists; nothing was replaced.",
            ));
        }
        if let Some(remainder) = &change.new_oid {
            if !shelves
                .iter()
                .any(|s| &s.oid == remainder && s.subject == change.subject)
            {
                return Err(error(
                    "The remaining shelf has changed or disappeared; Undo was not applied.",
                ));
            }
        }
        // Check cancellation before starting the non-interruptible swap.
        if cancel.is_cancelled() {
            return Err(GitError::new(
                "undo shelf file",
                GitErrorKind::Cancelled,
                "",
            ));
        }
        let finish = CancelToken::new();
        self.store_shelf_unlocked(repo, &change.old_oid, &change.subject, &finish)?;
        if let Some(remainder) = &change.new_oid {
            self.drop_shelf_unlocked(repo, remainder, &finish)?;
        }
        self.remove_shelf_backup(repo, &change.old_oid, &finish)
    }

    pub(super) fn remove_shelf_backup(
        &self,
        repo: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let reference = backup_ref(oid);
        if self.resolve(repo, &reference, cancel)?.as_deref() == Some(oid) {
            self.runner
                .write(repo)
                .args(["update-ref", "-d", &reference, oid])
                .cancel_token(cancel)
                .run()?;
        }
        Ok(())
    }
}
