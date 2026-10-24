//! The `GitBackend` trait and its git CLI implementation (PLAN §3.3).
//!
//! Reads, plus the writes of the milestones so far (staging and commits).
//! Commands that take paths run in the worktree root with literal pathspecs,
//! so status paths can be passed back unchanged.

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::diff::{
    parse_diff, untracked_diff, DiffContent, DiffKind, DiffTarget, FileDiff, PatchMode,
};
use crate::git::{CancelToken, GitCommand, GitError, GitErrorKind, GitOutput, GitRunner};
use crate::repo::{
    detect_operation, parse_commit_header, parse_name_status, parse_refs, parse_remotes,
    parse_repo_paths, parse_stash_list, parse_status, parse_worktrees, CommitDetails, Operation,
    ParseError, Ref, RepoPaths, RepoStatus, StashEntry, Worktree, COMMIT_SHOW_FORMAT, REFS_ARGS,
    REPO_PATHS_ARGS, STASH_LIST_ARGS, STATUS_ARGS, WORKTREES_ARGS,
};

/// Read access to a repository. `repo` is any directory inside a worktree (or
/// a bare repository). Implementations must be usable from worker threads.
pub trait GitBackend: Send + Sync {
    fn repo_paths(&self, repo: &Path, cancel: &CancelToken) -> Result<RepoPaths, GitError>;
    /// Root of the worktree containing `repo` (fails in a bare repository).
    fn toplevel(&self, repo: &Path, cancel: &CancelToken) -> Result<PathBuf, GitError>;
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

    /// Diff of one file. `toplevel` is the worktree root. Output larger than
    /// `limit` bytes is not parsed and comes back as [`DiffContent::TooLarge`].
    fn diff(
        &self,
        toplevel: &Path,
        target: &DiffTarget,
        limit: Option<usize>,
        cancel: &CancelToken,
    ) -> Result<FileDiff, GitError>;
    /// Full message of the HEAD commit (for amending).
    fn head_message(&self, repo: &Path, cancel: &CancelToken) -> Result<String, GitError>;

    /// `git add -A` of `paths` (worktree-root relative), or of everything.
    fn stage(
        &self,
        toplevel: &Path,
        paths: Option<&[PathBuf]>,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// Resets `paths` (or the whole index) to HEAD; works on an unborn branch.
    fn unstage(
        &self,
        toplevel: &Path,
        paths: Option<&[PathBuf]>,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// Commits the index with `message` (passed on stdin). Hooks run; their
    /// output is in the error's stderr when they reject the commit.
    fn commit(
        &self,
        toplevel: &Path,
        message: &str,
        amend: bool,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;

    /// A commit's header and changed files (against its first parent).
    fn commit_details(
        &self,
        repo: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<CommitDetails, GitError>;

    /// Applies a patch from [`crate::diff::build_patch`] as `mode` says,
    /// after checking `guard` (the file still matches the diff) and
    /// `git apply --check`.
    fn apply_patch(
        &self,
        toplevel: &Path,
        patch: &[u8],
        mode: PatchMode,
        guard: &PatchGuard,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// Stores the working-tree bytes of `paths` (those that exist) as blobs,
    /// unfiltered, so a discard can be undone. Returns `(path, blob id)`.
    fn backup(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<Vec<(PathBuf, String)>, GitError>;
    /// Restores the working tree of `paths` from the index.
    fn discard(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// Writes backed-up blobs back to their paths.
    fn restore_backup(
        &self,
        toplevel: &Path,
        files: &[(PathBuf, String)],
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
}

/// What a file must still look like for a patch built from its diff to apply.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PatchGuard {
    /// Worktree-root relative path.
    pub path: PathBuf,
    /// Expected index blob id (full), if checked.
    pub index_oid: Option<String>,
    /// Expected working-tree content id (full), if checked.
    pub worktree_oid: Option<String>,
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

/// NUL-separated paths for `--pathspec-from-file=- --pathspec-file-nul`.
fn pathspec_input(paths: &[PathBuf]) -> Vec<u8> {
    let mut input = Vec::new();
    for path in paths {
        input.extend_from_slice(path.to_string_lossy().as_bytes());
        input.push(0);
    }
    input
}

const PATHSPEC_STDIN: [&str; 2] = ["--pathspec-from-file=-", "--pathspec-file-nul"];

/// `git diff` arguments that keep the output stable whatever the user's
/// config: no external diff or textconv, standard prefixes, full-tree paths.
const DIFF_ARGS: &[&str] = &[
    "diff",
    "--no-ext-diff",
    "--no-textconv",
    "--no-relative",
    "--no-color",
    "--full-index",
    "--src-prefix=a/",
    "--dst-prefix=b/",
];

/// The stage-0 index blob id of `path`, from `git ls-files -s -z` output.
fn parse_index_oid(output: &[u8]) -> Option<String> {
    let entry = output.split(|&b| b == 0).next()?;
    let mut fields = entry.splitn(3, |&b| b == b' ');
    fields.next()?;
    let oid = fields.next()?;
    Some(String::from_utf8_lossy(oid).into_owned())
}

fn stale(path: &Path) -> GitError {
    GitError::new(
        format!("apply {}", path.display()),
        GitErrorKind::Stale,
        "the file changed since its diff was shown; refresh and try again",
    )
}

/// `git diff-tree` arguments for one commit's file, with the same stable
/// output as [`DIFF_ARGS`].
const DIFF_TREE_ARGS: &[&str] = &[
    "diff-tree",
    "-p",
    "-M",
    "--no-commit-id",
    "--no-ext-diff",
    "--no-textconv",
    "--no-color",
    "--full-index",
    "--src-prefix=a/",
    "--dst-prefix=b/",
];

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

    fn toplevel(&self, repo: &Path, cancel: &CancelToken) -> Result<PathBuf, GitError> {
        let out = self.read(repo, &["rev-parse", "--show-toplevel"], cancel)?;
        let line = out.stdout.split(|&b| b == b'\n').next().unwrap_or_default();
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.is_empty() {
            return Err(GitError::new(
                "rev-parse --show-toplevel",
                GitErrorKind::UnexpectedOutput,
                "empty output",
            ));
        }
        Ok(crate::repo::git_path(line))
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
        let input = pathspec_input(paths);
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

    fn diff(
        &self,
        toplevel: &Path,
        target: &DiffTarget,
        limit: Option<usize>,
        cancel: &CancelToken,
    ) -> Result<FileDiff, GitError> {
        if target.kind == DiffKind::Untracked {
            return read_untracked(&toplevel.join(&target.path), limit);
        }
        let mut cmd = self.runner.read(toplevel).env("GIT_LITERAL_PATHSPECS", "1");
        if let (DiffKind::Commit, Some(commit)) = (target.kind, &target.commit) {
            cmd = cmd.args(DIFF_TREE_ARGS);
            cmd = match &commit.parent {
                Some(parent) => cmd.args([parent, &commit.oid]),
                None => cmd.args(["--root", &commit.oid]),
            };
        } else {
            cmd = cmd.args(DIFF_ARGS);
        }
        if target.kind == DiffKind::Staged {
            cmd = cmd.args(["--cached", "-M"]);
        }
        cmd = cmd.arg("--");
        if let Some(original) = &target.original_path {
            cmd = cmd.arg(original);
        }
        let mut stream = cmd.arg(&target.path).stream()?;
        let limit = limit.unwrap_or(usize::MAX);
        let mut output = Vec::new();
        let mut chunk = vec![0u8; 64 * 1024];
        loop {
            if cancel.is_cancelled() {
                stream.kill();
                return stream.finish().map(|()| FileDiff::default());
            }
            let n = stream.read(&mut chunk).map_err(|err| {
                GitError::new(stream.command(), GitErrorKind::Io, err.to_string())
            })?;
            if n == 0 {
                break;
            }
            output.extend_from_slice(&chunk[..n]);
            if output.len() > limit {
                // Dropping the stream stops git; the log records it as cancelled.
                return Ok(FileDiff::too_large(output.len()));
            }
        }
        let command = stream.command().to_owned();
        stream.finish()?;
        let mut diff = parse_diff(&output).map_err(|e| unexpected(&[command.as_str()], e))?;
        if let DiffContent::Binary { .. } = diff.content {
            diff.content = self.binary_sizes(toplevel, target, cancel);
        }
        Ok(diff)
    }

    fn head_message(&self, repo: &Path, cancel: &CancelToken) -> Result<String, GitError> {
        let out = self.read(repo, &["log", "-1", "--format=%B", "HEAD"], cancel)?;
        Ok(out.stdout_text())
    }

    fn stage(
        &self,
        toplevel: &Path,
        paths: Option<&[PathBuf]>,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let cmd = self.runner.write(toplevel).args(["add", "-A"]);
        run_with_paths(cmd, paths, cancel)
    }

    fn unstage(
        &self,
        toplevel: &Path,
        paths: Option<&[PathBuf]>,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let has_head = self
            .read(toplevel, &["rev-parse", "-q", "--verify", "HEAD"], cancel)
            .is_ok();
        if has_head {
            let cmd = self.runner.write(toplevel).args(["reset", "-q"]);
            return run_with_paths(cmd, paths, cancel);
        }
        // `git reset` needs a HEAD; on an unborn branch, drop index entries.
        let cmd =
            self.runner
                .write(toplevel)
                .args(["rm", "--cached", "-r", "-q", "--ignore-unmatch"]);
        match paths {
            Some(paths) => run_with_paths(cmd, Some(paths), cancel),
            None => run_with_paths(cmd.args(["--", "."]), None, cancel),
        }
    }

    fn commit(
        &self,
        toplevel: &Path,
        message: &str,
        amend: bool,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let mut cmd = self.runner.write(toplevel).args(["commit", "-F", "-"]);
        if amend {
            cmd = cmd.arg("--amend");
        }
        cmd.stdin(message.as_bytes().to_vec())
            .cancel_token(cancel)
            .run()
            .map(drop)
    }

    fn commit_details(
        &self,
        repo: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<CommitDetails, GitError> {
        let show = ["show", "-s", COMMIT_SHOW_FORMAT, oid, "--"];
        let out = self.read(repo, &show, cancel)?;
        let mut details = parse_commit_header(&out.stdout).map_err(|e| unexpected(&show, e))?;
        let mut args = vec![
            "diff-tree",
            "-r",
            "-z",
            "-M",
            "--name-status",
            "--no-commit-id",
        ];
        match details.parents.first() {
            Some(parent) => args.push(parent),
            None => args.push("--root"),
        }
        args.push(&details.oid);
        let out = self.read(repo, &args, cancel)?;
        let files = parse_name_status(&out.stdout).map_err(|e| unexpected(&args, e))?;
        details.files = files;
        Ok(details)
    }

    fn apply_patch(
        &self,
        toplevel: &Path,
        patch: &[u8],
        mode: PatchMode,
        guard: &PatchGuard,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        if let Some(expected) = &guard.index_oid {
            let out = self
                .runner
                .read(toplevel)
                .env("GIT_LITERAL_PATHSPECS", "1")
                .args(["ls-files", "-s", "-z", "--"])
                .arg(&guard.path)
                .cancel_token(cancel)
                .run()?;
            if parse_index_oid(&out.stdout).as_deref() != Some(expected.as_str()) {
                return Err(stale(&guard.path));
            }
        }
        if let Some(expected) = &guard.worktree_oid {
            let out = self
                .runner
                .read(toplevel)
                .args(["hash-object", "--"])
                .arg(&guard.path)
                .cancel_token(cancel)
                .run()?;
            if out.stdout_text().trim() != expected {
                return Err(stale(&guard.path));
            }
        }
        let mut args = vec!["apply", "--recount", "--whitespace=nowarn"];
        if mode.is_cached() {
            args.push("--cached");
        }
        if mode.is_reverse() {
            args.push("-R");
        }
        let run = |check: bool| {
            let mut cmd = self.runner.write(toplevel).args(&args);
            if check {
                cmd = cmd.arg("--check");
            }
            cmd.arg("-")
                .stdin(patch.to_vec())
                .cancel_token(cancel)
                .run()
                .map(drop)
        };
        run(true)?;
        run(false)
    }

    fn backup(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<Vec<(PathBuf, String)>, GitError> {
        let existing: Vec<&PathBuf> = paths
            .iter()
            .filter(|p| toplevel.join(p).is_file())
            .collect();
        if existing.is_empty() {
            return Ok(Vec::new());
        }
        let mut input = String::new();
        for path in &existing {
            input.push_str(&path.to_string_lossy());
            input.push('\n');
        }
        let out = self
            .runner
            .write(toplevel)
            .args(["hash-object", "-w", "--no-filters", "--stdin-paths"])
            .stdin(input)
            .cancel_token(cancel)
            .run()?;
        let oids: Vec<String> = out.stdout_text().lines().map(str::to_owned).collect();
        if oids.len() != existing.len() {
            return Err(GitError::new(
                "hash-object --stdin-paths",
                GitErrorKind::UnexpectedOutput,
                format!("{} ids for {} files", oids.len(), existing.len()),
            ));
        }
        Ok(existing.into_iter().cloned().zip(oids).collect())
    }

    fn discard(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let cmd = self.runner.write(toplevel).args(["restore", "--worktree"]);
        run_with_paths(cmd, Some(paths), cancel)
    }

    fn restore_backup(
        &self,
        toplevel: &Path,
        files: &[(PathBuf, String)],
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        for (path, oid) in files {
            let out = self
                .runner
                .read(toplevel)
                .args(["cat-file", "blob", oid])
                .cancel_token(cancel)
                .run()?;
            let target = toplevel.join(path);
            let io = |err: std::io::Error| {
                GitError::new(
                    format!("write {}", target.display()),
                    GitErrorKind::Io,
                    err.to_string(),
                )
            };
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent).map_err(io)?;
            }
            fs::write(&target, &out.stdout).map_err(io)?;
        }
        Ok(())
    }
}

/// Runs a path-taking write. `paths` go through stdin (no length limit) and
/// are literal (no pathspec magic); `None` means the whole worktree.
fn run_with_paths(
    cmd: GitCommand,
    paths: Option<&[PathBuf]>,
    cancel: &CancelToken,
) -> Result<(), GitError> {
    let cmd = cmd.env("GIT_LITERAL_PATHSPECS", "1").cancel_token(cancel);
    let cmd = match paths {
        Some([]) => return Ok(()),
        Some(paths) => cmd.args(PATHSPEC_STDIN).stdin(pathspec_input(paths)),
        None => cmd,
    };
    cmd.run().map(drop)
}

impl CliBackend {
    /// Old and new sizes of a binary file, from the object database and the
    /// working tree. A side that does not exist stays `None`.
    fn binary_sizes(
        &self,
        toplevel: &Path,
        target: &DiffTarget,
        cancel: &CancelToken,
    ) -> DiffContent {
        let slashed = |p: &Path| p.to_string_lossy().replace('\\', "/");
        let path = slashed(&target.path);
        let old_path = target
            .original_path
            .as_deref()
            .map_or_else(|| path.clone(), slashed);
        let (old_spec, new_spec) = match target.kind {
            DiffKind::Staged => (format!("HEAD:{old_path}"), Some(format!(":{path}"))),
            DiffKind::Unstaged | DiffKind::Untracked => (format!(":{path}"), None),
            DiffKind::Commit => {
                let oid = target.commit.as_ref().map_or("HEAD", |c| c.oid.as_str());
                // `<oid>^` is missing for a root commit, which reads as "no old side".
                (format!("{oid}^:{old_path}"), Some(format!("{oid}:{path}")))
            }
        };
        let mut input = format!("{old_spec}\n");
        if let Some(spec) = &new_spec {
            input.push_str(spec);
            input.push('\n');
        }
        let sizes: Vec<Option<u64>> = self
            .runner
            .read(toplevel)
            .args(["cat-file", "--batch-check=%(objectsize)"])
            .stdin(input)
            .cancel_token(cancel)
            .run()
            .map(|out| {
                out.stdout_text()
                    .lines()
                    .map(|line| line.trim().parse().ok())
                    .collect()
            })
            .unwrap_or_default();
        let old_size = sizes.first().copied().flatten();
        let new_size = match new_spec {
            Some(_) => sizes.get(1).copied().flatten(),
            None => fs::metadata(toplevel.join(&target.path))
                .ok()
                .map(|m| m.len()),
        };
        DiffContent::Binary { old_size, new_size }
    }
}

/// The diff of an untracked file, read from disk.
fn read_untracked(path: &Path, limit: Option<usize>) -> Result<FileDiff, GitError> {
    let io_error = |err: std::io::Error| {
        GitError::new(
            format!("read {}", path.display()),
            GitErrorKind::Io,
            err.to_string(),
        )
    };
    let size = fs::metadata(path).map_err(io_error)?.len();
    if limit.is_some_and(|limit| size > limit as u64) {
        return Ok(FileDiff::too_large(
            usize::try_from(size).unwrap_or(usize::MAX),
        ));
    }
    Ok(untracked_diff(&fs::read(path).map_err(io_error)?))
}
