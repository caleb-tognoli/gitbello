use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use super::{CliBackend, GitBackend, IndexWrite};
use crate::git::{CancelToken, GitError, GitErrorKind};
use crate::repo::{git_path, Change, FileChange, FileState, RepoStatus};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AmendSnapshot {
    pub head: String,
    pub base: String,
    pub tree: String,
    pub message: String,
    pub original_paths: Vec<PathBuf>,
    pub status: RepoStatus,
}

pub(super) struct AmendIndex(pub(super) PathBuf);

impl Drop for AmendIndex {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
        let _ = std::fs::remove_file(self.0.with_extension("lock"));
    }
}

impl CliBackend {
    pub(super) fn amend_read_index(
        &self,
        repo: &Path,
        tree: &str,
        cancel: &CancelToken,
    ) -> Result<AmendIndex, GitError> {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let id = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let name = format!("gitbello-amend-read-{}-{id}", std::process::id());
        let path = PathBuf::from(
            self.read(
                repo,
                &["rev-parse", "--path-format=absolute", "--git-path", &name],
                cancel,
            )?
            .stdout_text()
            .trim(),
        );
        let index = AmendIndex(path);
        self.runner
            .write(repo)
            .env("GIT_INDEX_FILE", &index.0)
            .args(["read-tree", tree])
            .cancel_token(cancel)
            .run()?;
        Ok(index)
    }

    pub(super) fn prepare_amend_snapshot(
        &self,
        repo: &Path,
        head: &str,
        write: &IndexWrite,
        cancel: &CancelToken,
    ) -> Result<AmendSnapshot, GitError> {
        self.check_amend_head(repo, head, cancel)?;
        let details = self.commit_details(repo, head, cancel)?;
        let base = match details.parents.first() {
            Some(parent) => parent.clone(),
            None => self.empty_tree(repo, cancel)?,
        };
        let index = PathBuf::from(
            self.read(
                repo,
                &[
                    "rev-parse",
                    "--path-format=absolute",
                    "--git-path",
                    "gitbello-amend-index",
                ],
                cancel,
            )?
            .stdout_text()
            .trim(),
        );
        let result = (|| {
            self.write_selection_index(repo, &index, head, write, cancel)?;
            let tree = self
                .runner
                .write(repo)
                .env("GIT_INDEX_FILE", &index)
                .args(["write-tree"])
                .cancel_token(cancel)
                .run()?
                .stdout_text()
                .trim()
                .to_owned();
            let mut original_paths = Vec::new();
            for file in &details.files {
                original_paths.push(file.path.clone());
                original_paths.extend(file.original_path.clone());
            }
            let mut snapshot = AmendSnapshot {
                head: head.to_owned(),
                base,
                tree,
                message: self.head_message(repo, cancel)?,
                original_paths,
                status: RepoStatus::default(),
            };
            snapshot.status = self.read_amend_changes(repo, &snapshot, cancel)?;
            self.check_amend_head(repo, head, cancel)?;
            Ok(snapshot)
        })();
        let _ = std::fs::remove_file(&index);
        let _ = std::fs::remove_file(index.with_extension("lock"));
        result
    }

    pub(super) fn check_amend_head(
        &self,
        repo: &Path,
        head: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        if self.resolve(repo, "HEAD", cancel)?.as_deref() != Some(head) {
            return Err(GitError::new(
                "amend",
                GitErrorKind::Stale,
                "The last commit changed. Start amend again.",
            ));
        }
        if self.operation(repo, cancel)?.is_some() {
            return Err(GitError::new(
                "amend",
                GitErrorKind::Stale,
                "Finish the operation in progress first",
            ));
        }
        Ok(())
    }

    pub(super) fn read_amend_changes(
        &self,
        repo: &Path,
        snapshot: &AmendSnapshot,
        cancel: &CancelToken,
    ) -> Result<RepoStatus, GitError> {
        self.check_amend_head(repo, &snapshot.head, cancel)?;
        let mut status = self.status(repo, cancel)?;
        let base_index = self.amend_read_index(repo, &snapshot.base, cancel)?;
        let tree_index = self.amend_read_index(repo, &snapshot.tree, cancel)?;
        let raw = |index: &Path, range: &[&str]| {
            let mut args = vec![
                "diff",
                "--raw",
                "--no-abbrev",
                "-z",
                "--no-renames",
                "--no-ext-diff",
                "--no-textconv",
            ];
            args.extend_from_slice(range);
            args.push("--");
            self.runner
                .read(repo)
                .env("GIT_INDEX_FILE", index)
                .args(&args)
                .cancel_token(cancel)
                .run()
                .and_then(|out| raw_changes(&out.stdout))
        };
        let mut working = raw(&base_index.0, &[&snapshot.base])?;
        let selected = raw(&base_index.0, &[&snapshot.base, &snapshot.tree])?;
        let mut changed = raw(&tree_index.0, &[&snapshot.tree])?;
        let untracked = |index: &Path| -> Result<Vec<PathBuf>, GitError> {
            let out = self
                .runner
                .read(repo)
                .env("GIT_INDEX_FILE", index)
                .args(["ls-files", "--others", "--exclude-standard", "-z"])
                .cancel_token(cancel)
                .run()?;
            Ok(out
                .stdout
                .split(|&b| b == 0)
                .filter(|p| !p.is_empty())
                .map(git_path)
                .collect())
        };
        for (paths, changes) in [
            (untracked(&base_index.0)?, &mut working),
            (untracked(&tree_index.0)?, &mut changed),
        ] {
            for path in paths {
                changes.entry(path.clone()).or_insert(FileChange {
                    path,
                    original_path: None,
                    state: FileState::Untracked,
                    score: None,
                    submodule: false,
                    index_mode: None,
                    index_oid: None,
                });
            }
        }
        for (path, selected) in &selected {
            working
                .entry(path.clone())
                .or_insert_with(|| selected.clone());
        }
        for (path, change) in &mut working {
            let staged = selected.get(path);
            let code = staged.map_or(Change::Unmodified, |c| match c.state {
                FileState::Tracked { index, .. } => index,
                _ => Change::Unmodified,
            });
            change.index_mode = staged.and_then(|c| c.index_mode.clone());
            change.index_oid = staged.and_then(|c| c.index_oid.clone());
            change.state = FileState::Tracked {
                index: code,
                worktree: if changed.contains_key(path)
                    || (staged.is_none() && change.state == FileState::Untracked)
                {
                    Change::Modified
                } else {
                    Change::Unmodified
                },
            };
        }
        status.changes = working.into_values().collect();
        Ok(status)
    }
}

fn raw_changes(bytes: &[u8]) -> Result<BTreeMap<PathBuf, FileChange>, GitError> {
    let invalid = || {
        GitError::new(
            "diff --raw",
            GitErrorKind::UnexpectedOutput,
            "invalid raw diff record",
        )
    };
    let mut records = bytes.split(|&b| b == 0).filter(|r| !r.is_empty());
    let mut changes = BTreeMap::new();
    while let Some(header) = records.next() {
        let header = std::str::from_utf8(header).map_err(|_| invalid())?;
        let fields: Vec<&str> = header.split(' ').collect();
        if fields.len() != 5 || !fields[0].starts_with(':') {
            return Err(invalid());
        }
        let code = match fields[4] {
            "A" => Change::Added,
            "D" => Change::Deleted,
            "M" => Change::Modified,
            "T" => Change::TypeChanged,
            _ => return Err(invalid()),
        };
        let path = git_path(records.next().ok_or_else(invalid)?);
        changes.insert(
            path.clone(),
            FileChange {
                path,
                original_path: None,
                state: FileState::Tracked {
                    index: code,
                    worktree: Change::Unmodified,
                },
                score: None,
                submodule: fields[1] == "160000",
                index_mode: Some(
                    if code == Change::Deleted {
                        "0"
                    } else {
                        fields[1]
                    }
                    .to_owned(),
                ),
                index_oid: Some(fields[3].to_owned()),
            },
        );
    }
    Ok(changes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_diff_keeps_paths_modes_and_deletions() {
        let changes = raw_changes(
            b":100644 100755 aaaa bbbb M\0a file\n.txt\0:100644 000000 cccc 0000 D\0deleted\0",
        )
        .unwrap();
        assert_eq!(
            changes[Path::new("a file\n.txt")].index_mode.as_deref(),
            Some("100755")
        );
        assert_eq!(
            changes[Path::new("deleted")].index_mode.as_deref(),
            Some("0")
        );
        assert!(raw_changes(b":bad\0path\0").is_err());
    }
}
