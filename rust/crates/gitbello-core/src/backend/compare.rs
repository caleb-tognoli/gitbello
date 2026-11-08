//! Compare's git reads (PLAN M7.12): resolving the sides, their merge base
//! and counts, and the files that differ with their line counts.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use std::collections::HashSet;

use super::{run_with_paths, unexpected, CliBackend, GitBackend};
use crate::compare::{
    count_untracked_lines, default_mode, parse_numstat, parse_side_log, CompareCommit, CompareFile,
    CompareMode, CompareRequest, CompareSide, Comparison, ResolvedSide, SideKind,
    COMMIT_LIST_LIMIT, SIDE_LOG_FORMAT, UNTRACKED_COUNT_LIMIT,
};
use crate::git::{CancelToken, GitError, GitErrorKind};
use crate::repo::{parse_name_status, Change, FileState};

/// `git diff` flags for the working-copy side's file list, stable whatever
/// the user's config.
const WORKING_DIFF_ARGS: &[&str] = &[
    "diff",
    "--no-ext-diff",
    "--no-textconv",
    "--no-relative",
    "--no-color",
    "-z",
    "-M",
];

const TREE_DIFF_ARGS: &[&str] = &["diff-tree", "-r", "-z", "-M", "--no-commit-id"];

fn unknown_revision(spec: &str) -> GitError {
    GitError::new(
        format!("rev-parse {spec}"),
        GitErrorKind::UnknownRevision,
        format!("unknown revision `{spec}`"),
    )
}

impl CliBackend {
    pub(super) fn compare_sides(
        &self,
        toplevel: &Path,
        request: &CompareRequest,
        cancel: &CancelToken,
    ) -> Result<Comparison, GitError> {
        let left = self.resolve_side(toplevel, &request.left, cancel)?;
        let right = match &request.right {
            CompareSide::Rev(spec) => self.resolve_side(toplevel, spec, cancel)?,
            CompareSide::WorkingCopy => ResolvedSide {
                spec: String::new(),
                kind: SideKind::WorkingCopy,
                full_name: None,
                oid: self.resolve(toplevel, "HEAD", cancel)?,
                subject: None,
            },
        };
        let left_oid = left.oid.clone().unwrap_or_default();
        let merge_base = match &right.oid {
            Some(right_oid) => self.merge_base(toplevel, &left_oid, right_oid, cancel)?,
            None => None,
        };
        let default_mode = default_mode(left.kind, right.kind);
        let mut mode = request.mode.unwrap_or(default_mode);
        if merge_base.is_none() {
            mode = CompareMode::Exact;
        }
        let base = match (mode, &merge_base) {
            (CompareMode::SinceFork, Some(fork)) => fork.clone(),
            _ => left_oid.clone(),
        };
        let (only_left, only_right) = match &right.oid {
            Some(right_oid) => self.left_right_counts(toplevel, &left_oid, right_oid, cancel)?,
            None => (self.count_commits(toplevel, &[], &left_oid, cancel)?, 0),
        };
        let files = match (&right.kind, &right.oid) {
            (SideKind::WorkingCopy, _) => self.working_files(toplevel, &base, cancel)?,
            (_, Some(right_oid)) => self.tree_files(toplevel, &base, right_oid, cancel)?,
            (_, None) => Vec::new(),
        };
        let (commits, commits_truncated) = match &right.oid {
            Some(right_oid) => self.side_commits(toplevel, &left_oid, right_oid, cancel)?,
            None => (Vec::new(), false),
        };
        let mut comparison = Comparison {
            left,
            right,
            mode,
            default_mode,
            merge_base,
            base,
            only_right,
            only_left,
            files,
            additions: 0,
            deletions: 0,
            commits,
            commits_truncated,
        };
        comparison.count_lines();
        Ok(comparison)
    }

    /// The commits only on each side (right first), each marked whether
    /// HEAD already has it; at most [`COMMIT_LIST_LIMIT`].
    fn side_commits(
        &self,
        toplevel: &Path,
        left: &str,
        right: &str,
        cancel: &CancelToken,
    ) -> Result<(Vec<CompareCommit>, bool), GitError> {
        let range = format!("{left}...{right}");
        let limit = format!("--max-count={}", COMMIT_LIST_LIMIT + 1);
        let args = [
            "log",
            "-z",
            "--left-right",
            "--no-color",
            "--no-show-signature",
            "--encoding=UTF-8",
            &limit,
            SIDE_LOG_FORMAT,
            &range,
            "--",
        ];
        let out = self.read(toplevel, &args, cancel)?;
        let mut commits = parse_side_log(&out.stdout);
        let truncated = commits.len() > COMMIT_LIST_LIMIT;
        commits.truncate(COMMIT_LIST_LIMIT);
        if commits.is_empty() {
            return Ok((commits, truncated));
        }
        // What HEAD lacks: the range without HEAD's history (HEAD may be
        // unborn or detached elsewhere).
        let missing: HashSet<String> = match self.resolve(toplevel, "HEAD", cancel)? {
            Some(head) => {
                let not_head = format!("^{head}");
                let args = ["rev-list", &range, &not_head, "--"];
                let out = self.read(toplevel, &args, cancel)?;
                out.stdout_text().lines().map(str::to_owned).collect()
            }
            None => commits.iter().map(|c| c.oid.clone()).collect(),
        };
        for commit in &mut commits {
            commit.in_head = !missing.contains(&commit.oid);
        }
        Ok((commits, truncated))
    }

    /// The files commit `oid` changed against its first parent.
    pub(super) fn compare_one_commit(
        &self,
        toplevel: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<Comparison, GitError> {
        let commit = self.resolve_side(toplevel, oid, cancel)?;
        let commit_oid = commit.oid.clone().unwrap_or_default();
        let first_parent = format!("{commit_oid}^1");
        let parent = self.resolve(toplevel, &first_parent, cancel)?;
        let base = match &parent {
            Some(parent) => parent.clone(),
            None => self.empty_tree(toplevel, cancel)?,
        };
        let files = self.tree_files(toplevel, &base, &commit_oid, cancel)?;
        let left = ResolvedSide {
            spec: base.clone(),
            kind: SideKind::Commit,
            full_name: None,
            oid: parent,
            subject: None,
        };
        let mut comparison = Comparison {
            left,
            right: commit,
            mode: CompareMode::Exact,
            default_mode: CompareMode::Exact,
            merge_base: None,
            base,
            only_right: 1,
            only_left: 0,
            files,
            additions: 0,
            deletions: 0,
            commits: Vec::new(),
            commits_truncated: false,
        };
        comparison.count_lines();
        Ok(comparison)
    }

    pub(super) fn restore_paths_from(
        &self,
        toplevel: &Path,
        oid: &str,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<Vec<(PathBuf, String)>, GitError> {
        let mut present = Vec::new();
        let mut absent = Vec::new();
        for path in paths {
            let spec = format!("{oid}:{}", path.to_string_lossy().replace('\\', "/"));
            match self.read(toplevel, &["cat-file", "-e", &spec], cancel) {
                Ok(_) => present.push(path.clone()),
                Err(err) if err.kind == GitErrorKind::Cancelled => return Err(err),
                Err(_) => absent.push(path.clone()),
            }
        }
        let mut backups = self.backup(toplevel, paths, cancel)?;
        for path in paths {
            if !backups.iter().any(|(p, _)| p == path) {
                backups.push((path.clone(), String::new()));
            }
        }
        let source = format!("--source={oid}");
        let cmd = self
            .runner
            .write(toplevel)
            .args(["restore", &source, "--worktree"]);
        run_with_paths(cmd, Some(&present), cancel)?;
        for path in &absent {
            let target = toplevel.join(path);
            match fs::remove_file(&target) {
                Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
                    return Err(GitError::new(
                        format!("delete {}", target.display()),
                        GitErrorKind::Io,
                        err.to_string(),
                    ));
                }
                _ => {}
            }
        }
        Ok(backups)
    }

    /// The commit `spec` names and what kind of revision it is. Options are
    /// refused: a spec never reaches git as a flag.
    fn resolve_side(
        &self,
        toplevel: &Path,
        spec: &str,
        cancel: &CancelToken,
    ) -> Result<ResolvedSide, GitError> {
        let trimmed = spec.trim();
        if trimmed.is_empty() || trimmed.starts_with('-') {
            return Err(unknown_revision(trimmed));
        }
        let oid = self
            .resolve(toplevel, trimmed, cancel)?
            .ok_or_else(|| unknown_revision(trimmed))?;
        let args = [
            "rev-parse",
            "--verify",
            "-q",
            "--symbolic-full-name",
            "--end-of-options",
            trimmed,
        ];
        let full = match self.read(toplevel, &args, cancel) {
            Ok(out) => out.stdout_text().trim().to_owned(),
            Err(err) if err.kind == GitErrorKind::Cancelled => return Err(err),
            Err(_) => String::new(),
        };
        let kind = SideKind::from_full_name(&full);
        let subject = if kind == SideKind::Commit {
            let args = [
                "log",
                "-1",
                "--no-color",
                "--encoding=UTF-8",
                "--format=%s",
                &oid,
                "--",
            ];
            Some(
                self.read(toplevel, &args, cancel)?
                    .stdout_text()
                    .trim()
                    .to_owned(),
            )
        } else {
            None
        };
        Ok(ResolvedSide {
            spec: trimmed.to_owned(),
            kind,
            full_name: (kind != SideKind::Commit).then_some(full),
            oid: Some(oid),
            subject,
        })
    }

    fn merge_base(
        &self,
        toplevel: &Path,
        a: &str,
        b: &str,
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError> {
        match self.read(toplevel, &["merge-base", a, b], cancel) {
            Ok(out) => Ok(Some(out.stdout_text().trim().to_owned()).filter(|s| !s.is_empty())),
            Err(err) if err.exit_code == Some(1) => Ok(None),
            Err(err) => Err(err),
        }
    }

    /// Commits only on `left` and only on `right`.
    fn left_right_counts(
        &self,
        toplevel: &Path,
        left: &str,
        right: &str,
        cancel: &CancelToken,
    ) -> Result<(u32, u32), GitError> {
        let range = format!("{left}...{right}");
        let args = ["rev-list", "--left-right", "--count", &range, "--"];
        let out = self.read(toplevel, &args, cancel)?;
        let text = out.stdout_text();
        let mut counts = text.split_whitespace().map(str::parse::<u32>);
        match (counts.next(), counts.next()) {
            (Some(Ok(l)), Some(Ok(r))) => Ok((l, r)),
            _ => Err(GitError::new(
                args.join(" "),
                GitErrorKind::UnexpectedOutput,
                text.trim(),
            )),
        }
    }

    /// Files that differ between two commits.
    fn tree_files(
        &self,
        toplevel: &Path,
        base: &str,
        right: &str,
        cancel: &CancelToken,
    ) -> Result<Vec<CompareFile>, GitError> {
        let mut status_args = TREE_DIFF_ARGS.to_vec();
        status_args.extend(["--name-status", base, right]);
        let mut stat_args = TREE_DIFF_ARGS.to_vec();
        stat_args.extend(["--numstat", base, right]);
        self.files_from(toplevel, &status_args, &stat_args, cancel)
    }

    /// Tracked files that differ between `base` and the working tree, then
    /// the untracked files.
    fn working_files(
        &self,
        toplevel: &Path,
        base: &str,
        cancel: &CancelToken,
    ) -> Result<Vec<CompareFile>, GitError> {
        let mut status_args = WORKING_DIFF_ARGS.to_vec();
        status_args.extend(["--name-status", base, "--"]);
        let mut stat_args = WORKING_DIFF_ARGS.to_vec();
        stat_args.extend(["--numstat", base, "--"]);
        let mut files = self.files_from(toplevel, &status_args, &stat_args, cancel)?;
        let status = self.status(toplevel, cancel)?;
        for change in status
            .changes
            .iter()
            .filter(|c| c.state == FileState::Untracked)
        {
            files.push(CompareFile {
                change: Change::Added,
                path: change.path.clone(),
                original_path: None,
                stats: untracked_stats(&toplevel.join(&change.path)),
                untracked: true,
            });
        }
        files.sort_by(|a, b| a.path.cmp(&b.path));
        files.dedup_by(|a, b| a.path == b.path);
        Ok(files)
    }

    fn files_from(
        &self,
        toplevel: &Path,
        status_args: &[&str],
        stat_args: &[&str],
        cancel: &CancelToken,
    ) -> Result<Vec<CompareFile>, GitError> {
        let out = self.read(toplevel, status_args, cancel)?;
        let listed = parse_name_status(&out.stdout).map_err(|e| unexpected(status_args, e))?;
        let out = self.read(toplevel, stat_args, cancel)?;
        let stats: HashMap<PathBuf, Option<(u32, u32)>> =
            parse_numstat(&out.stdout).into_iter().collect();
        let mut files: Vec<CompareFile> = listed
            .into_iter()
            .map(|file| CompareFile {
                stats: stats.get(&file.path).copied().flatten(),
                change: file.change,
                path: file.path,
                original_path: file.original_path,
                untracked: false,
            })
            .collect();
        files.sort_by(|a, b| a.path.cmp(&b.path));
        Ok(files)
    }
}

/// Lines of an untracked file as added lines; `None` when binary, too large
/// or unreadable.
fn untracked_stats(path: &Path) -> Option<(u32, u32)> {
    let size = fs::metadata(path).ok()?.len();
    if size > UNTRACKED_COUNT_LIMIT {
        return None;
    }
    count_untracked_lines(&fs::read(path).ok()?).map(|lines| (lines, 0))
}
