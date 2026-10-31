//! The merge workflows' git calls (PLAN §4, M7): merge preview and merge,
//! the operation in progress, conflicted files, and undoing a commit.

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use super::{run_with_paths, unexpected, CliBackend};
use crate::git::{CancelToken, GitError, GitErrorKind};
use crate::merge::{
    default_merge_message, parse_merge_tree, parse_preview_commits, parse_undoable,
    read_operation_details, ConflictFile, ConflictKind, ConflictOp, HeadInfo, MergeMode,
    MergePreview, OperationDetails, UndoMode, PREVIEW_COMMITS, PREVIEW_LOG_FORMAT,
    UNDOABLE_LOG_FORMAT,
};
use crate::repo::{detect_operation, git_path, Operation};

/// Name of the merge message file under the worktree's git dir.
const MERGE_MESSAGE_FILE: &str = "gitbello-merge-msg";

/// Commits outside HEAD read for the graph's `in_head`; more are not read.
const NOT_IN_HEAD_LIMIT: usize = 200_000;

fn io_error(what: impl std::fmt::Display, err: std::io::Error) -> GitError {
    GitError::new(what.to_string(), GitErrorKind::Io, err.to_string())
}

fn stale_conflict(path: &Path) -> GitError {
    GitError::new(
        format!("resolve {}", path.display()),
        GitErrorKind::Stale,
        format!(
            "{} changed since its conflicts were shown; check them and try again",
            path.display()
        ),
    )
}

impl CliBackend {
    /// Whether `ancestor` is an ancestor of (or the same as) `of`.
    fn is_ancestor(
        &self,
        repo: &Path,
        ancestor: &str,
        of: &str,
        cancel: &CancelToken,
    ) -> Result<bool, GitError> {
        match self.read(repo, &["merge-base", "--is-ancestor", ancestor, of], cancel) {
            Ok(_) => Ok(true),
            Err(err) if err.exit_code == Some(1) => Ok(false),
            Err(err) => Err(err),
        }
    }

    /// `git merge-tree --write-tree` of HEAD and `oid` (exit code 1 means
    /// conflicts, with the same output).
    fn merge_tree(
        &self,
        toplevel: &Path,
        head: &str,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<crate::merge::MergeTree, GitError> {
        let args = [
            "merge-tree",
            "--write-tree",
            "-z",
            "--name-only",
            "--messages",
            head,
            oid,
        ];
        let mut stream = self.runner.read(toplevel).args(args).stream()?;
        let mut output = Vec::new();
        loop {
            if cancel.is_cancelled() {
                stream.kill();
                stream.finish()?;
                return Err(GitError::new("merge-tree", GitErrorKind::Cancelled, ""));
            }
            let mut chunk = [0u8; 64 * 1024];
            let n = stream
                .read(&mut chunk)
                .map_err(|err| io_error("merge-tree", err))?;
            if n == 0 {
                break;
            }
            output.extend_from_slice(&chunk[..n]);
        }
        match stream.finish() {
            Ok(()) => {}
            Err(err) if err.exit_code == Some(1) => {}
            Err(err) => return Err(err),
        }
        parse_merge_tree(&output).map_err(|e| unexpected(&args, e))
    }

    pub(super) fn merge_preview_impl(
        &self,
        toplevel: &Path,
        target: &str,
        branch: Option<&str>,
        cancel: &CancelToken,
    ) -> Result<MergePreview, GitError> {
        use super::GitBackend;
        let head = self.resolve(toplevel, "HEAD", cancel)?.ok_or_else(|| {
            GitError::new(
                "merge",
                GitErrorKind::Other,
                "there is no commit to merge into yet",
            )
        })?;
        let oid = self.resolve(toplevel, target, cancel)?.ok_or_else(|| {
            GitError::new(
                "merge",
                GitErrorKind::Other,
                format!("{target} does not name a commit"),
            )
        })?;
        let mut preview = MergePreview {
            target: target.to_owned(),
            oid: oid.clone(),
            message: default_merge_message(target, branch),
            ..MergePreview::default()
        };
        preview.up_to_date = self.is_ancestor(toplevel, &oid, &head, cancel)?;
        if preview.up_to_date {
            return Ok(preview);
        }
        preview.can_ff = self.is_ancestor(toplevel, &head, &oid, cancel)?;
        let range = format!("{head}..{oid}");
        let count = self.read(toplevel, &["rev-list", "--count", &range], cancel)?;
        preview.commit_count = count.stdout_text().trim().parse().unwrap_or(0);
        let limit = format!("-n{PREVIEW_COMMITS}");
        let log = self.read(
            toplevel,
            &["log", PREVIEW_LOG_FORMAT, &limit, &range, "--"],
            cancel,
        )?;
        preview.commits = parse_preview_commits(&log.stdout);
        let tree = self.merge_tree(toplevel, &head, &oid, cancel)?;
        let changed = self.read(
            toplevel,
            &["diff-tree", "-r", "-z", "--name-only", &head, &tree.tree],
            cancel,
        )?;
        preview.files = changed
            .stdout
            .split(|&b| b == 0)
            .filter(|p| !p.is_empty())
            .map(git_path)
            .collect();
        preview.conflicts = tree.conflicts;
        Ok(preview)
    }

    pub(super) fn merge_impl(
        &self,
        toplevel: &Path,
        target: &str,
        mode: MergeMode,
        message: Option<&str>,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let mut cmd = self.runner.write(toplevel).args([
            "-c",
            "merge.conflictStyle=zdiff3",
            "merge",
            mode.flag(),
            "--no-edit",
        ]);
        // `git merge -F -` does not read stdin: the message goes through a file.
        let file = match message.filter(|m| mode.takes_message() && !m.trim().is_empty()) {
            Some(message) => {
                let args = [
                    "rev-parse",
                    "--path-format=absolute",
                    "--git-path",
                    MERGE_MESSAGE_FILE,
                ];
                let path = PathBuf::from(self.read(toplevel, &args, cancel)?.stdout_text().trim());
                fs::write(&path, message).map_err(|err| io_error(path.display(), err))?;
                cmd = cmd.arg("-F").arg(&path);
                Some(path)
            }
            None => None,
        };
        let result = cmd.arg(target).cancel_token(cancel).run().map(drop);
        if let Some(path) = file {
            let _ = fs::remove_file(path);
        }
        result
    }

    pub(super) fn operation_details_impl(
        &self,
        repo: &Path,
        cancel: &CancelToken,
    ) -> Result<Option<OperationDetails>, GitError> {
        use super::GitBackend;
        let paths = self.repo_paths(repo, cancel)?;
        let Some(kind) = detect_operation(&paths.git_dir) else {
            return Ok(None);
        };
        let subject = |oid: &str| {
            self.read(repo, &["log", "-1", "--format=%s", oid, "--"], cancel)
                .ok()
                .map(|out| out.stdout_text().trim().to_owned())
        };
        Ok(Some(read_operation_details(&paths.git_dir, kind, subject)))
    }

    pub(super) fn conflict_file_impl(
        &self,
        toplevel: &Path,
        path: &Path,
        kind: ConflictKind,
        cancel: &CancelToken,
    ) -> Result<ConflictFile, GitError> {
        let target = toplevel.join(path);
        let content = match fs::read(&target) {
            Ok(bytes) => Some(bytes),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => None,
            Err(err) => return Err(io_error(target.display(), err)),
        };
        let mut file = ConflictFile::new(path.to_path_buf(), kind, content);
        let slashed = path.to_string_lossy().replace('\\', "/");
        let input = format!(":2:{slashed}\n:3:{slashed}\n");
        let sizes: Vec<Option<u64>> = self
            .runner
            .read(toplevel)
            .args(["cat-file", "--batch-check=%(objectsize)"])
            .stdin(input)
            .cancel_token(cancel)
            .run()?
            .stdout_text()
            .lines()
            .map(|line| line.trim().parse().ok())
            .collect();
        file.ours_size = sizes.first().copied().flatten();
        file.theirs_size = sizes.get(1).copied().flatten();
        Ok(file)
    }

    pub(super) fn resolved_paths_impl(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        let out = self.read(toplevel, &["ls-files", "--resolve-undo", "-z"], cancel)?;
        let mut paths: Vec<PathBuf> = Vec::new();
        for entry in out.stdout.split(|&b| b == 0).filter(|e| !e.is_empty()) {
            let Some(tab) = entry.iter().position(|&b| b == b'\t') else {
                continue;
            };
            let path = git_path(&entry[tab + 1..]);
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
        Ok(paths)
    }

    pub(super) fn conflict_op_impl(
        &self,
        toplevel: &Path,
        op: &ConflictOp,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let git = |args: &[&str], path: &Path| {
            self.runner
                .write(toplevel)
                .env("GIT_LITERAL_PATHSPECS", "1")
                .args(args)
                .arg("--")
                .arg(path)
                .cancel_token(cancel)
                .run()
                .map(drop)
        };
        let write = |path: &Path, expected: &[u8], content: &[u8]| {
            let target = toplevel.join(path);
            let current = fs::read(&target).unwrap_or_default();
            if current != expected {
                return Err(stale_conflict(path));
            }
            fs::write(&target, content).map_err(|err| io_error(target.display(), err))
        };
        match op {
            ConflictOp::Write {
                path,
                expected,
                content,
                stage,
            } => {
                write(path, expected, content)?;
                if *stage {
                    git(&["add"], path)?;
                }
                Ok(())
            }
            ConflictOp::Restore {
                path,
                expected,
                content,
                reopen,
            } => {
                if *reopen {
                    // Brings the unmerged stages back (from the resolve-undo record).
                    git(&["checkout", "-m"], path)?;
                    let target = toplevel.join(path);
                    return fs::write(&target, content)
                        .map_err(|err| io_error(target.display(), err));
                }
                write(path, expected, content)
            }
            ConflictOp::TakeSide { path, ours } => {
                git(
                    &["checkout", if *ours { "--ours" } else { "--theirs" }],
                    path,
                )?;
                git(&["add"], path)
            }
            ConflictOp::Remove { path } => git(&["rm", "-q", "--cached", "--ignore-unmatch"], path)
                .and_then(|()| {
                    let target = toplevel.join(path);
                    match fs::remove_file(&target) {
                        Ok(()) => Ok(()),
                        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
                        Err(err) => Err(io_error(target.display(), err)),
                    }
                }),
            ConflictOp::Stage { paths } => {
                let cmd = self.runner.write(toplevel).args(["add", "-A"]);
                run_with_paths(cmd, Some(paths), cancel)
            }
            ConflictOp::Reopen { path, base } => {
                // The unmerged stages come back from the resolve-undo record
                // (a file still conflicted keeps its own).
                git(&["update-index", "--unresolve"], path)?;
                let style = if *base { "--conflict=zdiff3" } else { "-m" };
                match git(&["checkout", style], path) {
                    // Only one side has the file (modify/delete): no markers to write.
                    Err(err) if err.stderr.contains("does not have all necessary versions") => {
                        Ok(())
                    }
                    result => result,
                }
            }
        }
    }

    pub(super) fn continue_operation_impl(
        &self,
        toplevel: &Path,
        operation: Operation,
        message: Option<&str>,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        // Resolved files may have been edited after they were staged.
        let resolved: Vec<PathBuf> = self
            .resolved_paths_impl(toplevel, cancel)?
            .into_iter()
            .filter(|p| toplevel.join(p).exists())
            .collect();
        if !resolved.is_empty() {
            let cmd = self.runner.write(toplevel).args(["add", "-A"]);
            run_with_paths(cmd, Some(&resolved), cancel)?;
        }
        let git = || self.runner.write(toplevel).cancel_token(cancel);
        match operation {
            Operation::Rebase { .. } => git().args(["rebase", "--continue"]).run().map(drop),
            Operation::ApplyMailbox => git().args(["am", "--continue"]).run().map(drop),
            _ => match message.filter(|m| !m.trim().is_empty()) {
                Some(message) => git()
                    .args(["commit", "-F", "-"])
                    .stdin(message.as_bytes().to_vec())
                    .run()
                    .map(drop),
                None => git().args(["commit", "--no-edit"]).run().map(drop),
            },
        }
    }

    pub(super) fn skip_operation_impl(
        &self,
        toplevel: &Path,
        operation: Operation,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let args: &[&str] = match operation {
            Operation::Rebase { .. } => &["rebase", "--skip"],
            Operation::CherryPick => &["cherry-pick", "--skip"],
            Operation::Revert => &["revert", "--skip"],
            Operation::ApplyMailbox => &["am", "--skip"],
            Operation::Merge | Operation::Bisect => {
                return Err(GitError::new(
                    "skip",
                    GitErrorKind::Other,
                    "this operation cannot skip a commit",
                ))
            }
        };
        self.runner
            .write(toplevel)
            .args(args)
            .cancel_token(cancel)
            .run()
            .map(drop)
    }

    pub(super) fn head_info_impl(
        &self,
        repo: &Path,
        cancel: &CancelToken,
    ) -> Result<HeadInfo, GitError> {
        use super::GitBackend;
        let Some(head) = self.resolve(repo, "HEAD", cancel)? else {
            return Ok(HeadInfo::default());
        };
        let unpushed = self.read(
            repo,
            &["rev-list", "-n1", "HEAD", "--not", "--remotes"],
            cancel,
        )?;
        let undoable = if unpushed.stdout_text().trim() == head {
            let log = self.read(
                repo,
                &["log", "-1", UNDOABLE_LOG_FORMAT, "HEAD", "--"],
                cancel,
            )?;
            parse_undoable(&log.stdout)
        } else {
            None
        };
        let mut stream = self
            .runner
            .read(repo)
            .args([
                "rev-list",
                "--branches",
                "--remotes",
                "--tags",
                "--not",
                "HEAD",
            ])
            .stream()?;
        let mut output = Vec::new();
        (&mut stream)
            .take((NOT_IN_HEAD_LIMIT * 42) as u64)
            .read_to_end(&mut output)
            .map_err(|err| io_error("rev-list", err))?;
        stream.kill();
        let _ = stream.finish();
        let not_in_head = String::from_utf8_lossy(&output)
            .lines()
            .filter(|l| l.len() >= 40)
            .map(str::to_owned)
            .collect();
        Ok(HeadInfo {
            undoable,
            not_in_head,
        })
    }

    pub(super) fn undo_commit_impl(
        &self,
        toplevel: &Path,
        oid: &str,
        mode: UndoMode,
        cancel: &CancelToken,
    ) -> Result<String, GitError> {
        use super::GitBackend;
        if self.resolve(toplevel, "HEAD", cancel)?.as_deref() != Some(oid) {
            return Err(GitError::new(
                "undo commit",
                GitErrorKind::Stale,
                "HEAD moved since the commit was shown; refresh and try again",
            ));
        }
        let message = self.read(toplevel, &["log", "-1", "--format=%B", oid, "--"], cancel)?;
        let parents = self.read(
            toplevel,
            &["rev-list", "--parents", "-n1", oid, "--"],
            cancel,
        )?;
        let first_parent = parents
            .stdout_text()
            .split_whitespace()
            .nth(1)
            .map(str::to_owned);
        let git = |args: &[&str]| {
            self.runner
                .write(toplevel)
                .args(args)
                .cancel_token(cancel)
                .run()
                .map(drop)
        };
        match (first_parent, mode) {
            (Some(parent), UndoMode::KeepChanges) => git(&["reset", "-q", "--mixed", &parent])?,
            (Some(parent), UndoMode::RemoveMerge) => git(&["reset", "-q", "--keep", &parent])?,
            (None, _) => {
                // The first commit: the branch becomes unborn again, the
                // files stay in the index as new files.
                let branch = self.read(toplevel, &["symbolic-ref", "-q", "HEAD"], cancel)?;
                git(&["update-ref", "-d", branch.stdout_text().trim(), oid])?;
            }
        }
        Ok(message.stdout_text())
    }
}
