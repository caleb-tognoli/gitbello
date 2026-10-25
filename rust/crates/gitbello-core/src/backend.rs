//! The `GitBackend` trait and its git CLI implementation (PLAN §3.3).
//!
//! Reads, plus the writes of the milestones so far (staging, commits,
//! discards, sync, branches, tags and cherry-picks).
//! Commands that take paths run in the worktree root with literal pathspecs,
//! so status paths can be passed back unchanged.

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::changes::IndexEntry;
use crate::diff::{
    parse_diff, untracked_diff, DiffContent, DiffKind, DiffTarget, FileDiff, PatchMode,
};
use crate::git::{CancelToken, GitCommand, GitError, GitErrorKind, GitOutput, GitRunner, Progress};
use crate::ops::{CheckoutTarget, PullMode, RefOp, SyncOp, WorktreeOp};
use crate::repo::{
    detect_operation, parse_commit_header, parse_name_status, parse_refs, parse_remote_urls,
    parse_repo_paths, parse_stash_list, parse_status, parse_worktrees, CommitDetails, Operation,
    ParseError, Ref, Remote, RepoPaths, RepoStatus, ShelfFile, StashEntry, Worktree,
    COMMIT_SHOW_FORMAT, REFS_ARGS, REPO_PATHS_ARGS, STASH_LIST_ARGS, STATUS_ARGS, WORKTREES_ARGS,
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
    /// Commits `write` (or amends HEAD with it) through a temporary index
    /// that starts as HEAD's tree, so a failure or a rejecting hook leaves
    /// the real index untouched. After the commit, `write.paths` are reset
    /// to it in the real index.
    fn commit_selection(
        &self,
        toplevel: &Path,
        write: &IndexWrite,
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
    /// Restores `tracked` to HEAD in the index and the working tree (files
    /// HEAD lacks go away) and deletes the `untracked` files.
    fn discard(
        &self,
        toplevel: &Path,
        tracked: &[PathBuf],
        untracked: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// Writes backed-up blobs back to their paths.
    fn restore_backup(
        &self,
        toplevel: &Path,
        files: &[(PathBuf, String)],
        cancel: &CancelToken,
    ) -> Result<(), GitError>;

    /// The configured remotes with their URLs.
    fn remotes(&self, repo: &Path, cancel: &CancelToken) -> Result<Vec<Remote>, GitError>;
    /// Fetch, pull or push; `--progress` lines go to `progress` as they arrive.
    fn sync(
        &self,
        toplevel: &Path,
        op: &SyncOp,
        progress: ProgressSink,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// Checkout, branch, tag and cherry-pick operations.
    fn ref_op(&self, toplevel: &Path, op: &RefOp, cancel: &CancelToken) -> Result<(), GitError>;
    /// Stashes every local change, untracked files included. Returns the new
    /// stash's commit id, or `None` when there was nothing to stash.
    fn stash_push(
        &self,
        toplevel: &Path,
        message: &str,
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError>;
    /// Pops the newest stash after checking that it is `expected`; `index`
    /// also restores what was staged.
    fn stash_pop(
        &self,
        toplevel: &Path,
        expected: &str,
        index: bool,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;

    /// Shelves `paths` (untracked files included) as a stash with `message`.
    /// Returns its commit, or `None` when there was nothing to shelve.
    fn shelve(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        message: &str,
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError>;
    /// Applies shelf `oid` (with what was staged when that applies), then
    /// drops it. A failed or conflicting apply keeps the shelf.
    fn restore_shelf(
        &self,
        toplevel: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// Drops the stash entry of commit `oid`.
    fn drop_shelf(&self, repo: &Path, oid: &str, cancel: &CancelToken) -> Result<(), GitError>;
    /// Stores commit `oid` as the newest stash with `message`.
    fn store_shelf(
        &self,
        repo: &Path,
        oid: &str,
        message: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// Stores shelf `oid` again with `message`, then drops the old entry.
    fn rename_shelf(
        &self,
        repo: &Path,
        oid: &str,
        message: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// The files of shelf `oid`, tracked then untracked.
    fn shelf_files(
        &self,
        repo: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<Vec<ShelfFile>, GitError>;

    fn worktree_op(
        &self,
        repo: &Path,
        op: &WorktreeOp,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// Full names of the local branches merged into `base`.
    fn merged_branches(
        &self,
        repo: &Path,
        base: &str,
        cancel: &CancelToken,
    ) -> Result<Vec<String>, GitError>;
    /// The commit `rev` names, or `None` when it names nothing.
    fn resolve(
        &self,
        repo: &Path,
        rev: &str,
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError>;
}

/// Receives `--progress` updates of a running fetch, pull or push.
pub type ProgressSink = Box<dyn FnMut(Progress) + Send>;

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

/// What [`GitBackend::commit_selection`] writes into its temporary index,
/// in this order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct IndexWrite {
    /// Taken whole from the working tree (`git add -A`).
    pub whole: Vec<PathBuf>,
    /// Index entries copied as they are (mode `0` removes the path).
    pub staged: Vec<IndexEntry>,
    /// Patches applied with `git apply --cached --recount`.
    pub patches: Vec<Vec<u8>>,
    /// Every path the commit writes, reset in the real index afterwards.
    pub paths: Vec<PathBuf>,
}

/// Name of the temporary index under the worktree's git dir.
const COMMIT_INDEX: &str = "gitbello-commit-index";

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
        let remotes: Vec<String> = self
            .remotes(repo, cancel)?
            .into_iter()
            .map(|r| r.name)
            .collect();
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
        if target.kind == DiffKind::Head {
            let base = match self.resolve(toplevel, "HEAD", cancel)? {
                Some(head) => head,
                None => self.empty_tree(toplevel, cancel)?,
            };
            cmd = cmd.args(["-M", &base]);
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

    fn commit_selection(
        &self,
        toplevel: &Path,
        write: &IndexWrite,
        message: &str,
        amend: bool,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let args = [
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            COMMIT_INDEX,
        ];
        let index = PathBuf::from(self.read(toplevel, &args, cancel)?.stdout_text().trim());
        let remove = |index: &Path| {
            let _ = fs::remove_file(index);
            let _ = fs::remove_file(index.with_extension("lock"));
        };
        remove(&index);
        let committed = self.commit_with_index(toplevel, &index, write, message, amend, cancel);
        remove(&index);
        committed?;
        // The commit exists: bring the real index along, whatever happens.
        self.unstage(toplevel, Some(&write.paths), &CancelToken::new())
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
        tracked: &[PathBuf],
        untracked: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let has_head = self.resolve(toplevel, "HEAD", cancel)?.is_some();
        let delete = |paths: &[PathBuf]| -> Result<(), GitError> {
            for path in paths {
                let target = toplevel.join(path);
                match fs::remove_file(&target) {
                    Ok(()) => {}
                    Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
                    Err(err) => {
                        return Err(GitError::new(
                            format!("delete {}", target.display()),
                            GitErrorKind::Io,
                            err.to_string(),
                        ))
                    }
                }
            }
            Ok(())
        };
        if has_head {
            let cmd = self.runner.write(toplevel).args([
                "restore",
                "--source=HEAD",
                "--staged",
                "--worktree",
            ]);
            run_with_paths(cmd, Some(tracked), cancel)?;
        } else if !tracked.is_empty() {
            // Before the first commit everything tracked is new.
            self.unstage(toplevel, Some(tracked), cancel)?;
            delete(tracked)?;
        }
        delete(untracked)
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

    fn remotes(&self, repo: &Path, cancel: &CancelToken) -> Result<Vec<Remote>, GitError> {
        Ok(parse_remote_urls(
            &self.read(repo, &["remote", "-v"], cancel)?.stdout,
        ))
    }

    fn sync(
        &self,
        toplevel: &Path,
        op: &SyncOp,
        progress: ProgressSink,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let cmd = self.runner.write(toplevel);
        let cmd = match op {
            SyncOp::Fetch { remote } => {
                let cmd = cmd.args(["fetch", "--progress", "--prune"]);
                match remote {
                    Some(remote) => cmd.arg(remote),
                    None => cmd.arg("--all"),
                }
            }
            SyncOp::Pull { mode } => {
                // Explicit flags win over the user's pull.rebase / pull.ff config.
                let flags: &[&str] = match mode {
                    PullMode::FastForwardOnly => &["--ff-only", "--no-rebase"],
                    PullMode::Merge => &["--no-rebase", "--ff", "--no-edit"],
                    PullMode::Rebase => &["--rebase"],
                };
                cmd.args(["pull", "--progress", "--autostash"]).args(flags)
            }
            SyncOp::Push(spec) => {
                let mut cmd = cmd.args(["push", "--progress"]);
                if spec.set_upstream {
                    cmd = cmd.arg("--set-upstream");
                }
                if spec.force_with_lease {
                    cmd = cmd.arg("--force-with-lease");
                }
                cmd.arg(&spec.remote).args(&spec.refspecs)
            }
        };
        cmd.on_progress(progress)
            .cancel_token(cancel)
            .run()
            .map(drop)
    }

    fn ref_op(&self, toplevel: &Path, op: &RefOp, cancel: &CancelToken) -> Result<(), GitError> {
        let git = |args: &[&str]| {
            self.runner
                .write(toplevel)
                .args(args)
                .cancel_token(cancel)
                .run()
                .map(drop)
        };
        match op {
            RefOp::Checkout(CheckoutTarget::Branch(name)) => git(&["switch", "--no-guess", name]),
            RefOp::Checkout(CheckoutTarget::Track { remote_ref, local }) => {
                git(&["switch", "--create", local, "--track", remote_ref])
            }
            RefOp::Checkout(CheckoutTarget::Detach(oid)) => git(&["switch", "--detach", oid]),
            RefOp::CreateBranch {
                name,
                start,
                checkout: true,
            } => git(&["switch", "--create", name, start]),
            RefOp::CreateBranch {
                name,
                start,
                checkout: false,
            } => git(&["branch", name, start]),
            RefOp::RenameBranch { old, new } => git(&["branch", "--move", old, new]),
            RefOp::DeleteBranch { name, force } => {
                git(&["branch", if *force { "-D" } else { "-d" }, name])
            }
            RefOp::SetUpstream {
                branch,
                upstream: Some(upstream),
            } => git(&["branch", &format!("--set-upstream-to={upstream}"), branch]),
            RefOp::SetUpstream {
                branch,
                upstream: None,
            } => git(&["branch", "--unset-upstream", branch]),
            RefOp::CreateTag {
                name,
                target,
                message: None,
            } => git(&["tag", name, target]),
            RefOp::CreateTag {
                name,
                target,
                message: Some(message),
            } => self
                .runner
                .write(toplevel)
                .args(["tag", "--annotate", name, "-F", "-", target])
                .stdin(message.as_bytes().to_vec())
                .cancel_token(cancel)
                .run()
                .map(drop),
            RefOp::DeleteTag { name } => git(&["tag", "--delete", name]),
            RefOp::AddRemote { name, url } => git(&["remote", "add", "--", name, url]),
            RefOp::RenameRemote { old, new } => git(&["remote", "rename", "--", old, new]),
            RefOp::RemoveRemote { name } => git(&["remote", "remove", "--", name]),
            RefOp::SetRemoteUrl { name, url } => git(&["remote", "set-url", "--", name, url]),
            RefOp::CherryPick { commit } => {
                let parents = ["rev-list", "--parents", "-n", "1", commit, "--"];
                let out = self.read(toplevel, &parents, cancel)?;
                // The commit itself plus more than one parent: a merge.
                if out.stdout_text().split_whitespace().count() > 2 {
                    git(&["cherry-pick", "--mainline", "1", commit])
                } else {
                    git(&["cherry-pick", commit])
                }
            }
            RefOp::Abort(operation) => git(abort_args(*operation)),
        }
    }

    fn stash_push(
        &self,
        toplevel: &Path,
        message: &str,
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError> {
        let before = self.stash_top(toplevel, cancel)?;
        self.runner
            .write(toplevel)
            .args(["stash", "push", "--include-untracked", "-m", message])
            .cancel_token(cancel)
            .run()?;
        let after = self.stash_top(toplevel, cancel)?;
        Ok(after.filter(|top| Some(top) != before.as_ref()))
    }

    fn stash_pop(
        &self,
        toplevel: &Path,
        expected: &str,
        index: bool,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        if self.stash_top(toplevel, cancel)?.as_deref() != Some(expected) {
            return Err(GitError::new(
                "stash pop",
                GitErrorKind::Stale,
                format!("the newest stash is no longer {expected}; apply it from the stash list"),
            ));
        }
        let mut cmd = self.runner.write(toplevel).args(["stash", "pop"]);
        if index {
            cmd = cmd.arg("--index");
        }
        cmd.cancel_token(cancel).run().map(drop)
    }

    fn shelve(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        message: &str,
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError> {
        let before = self.stash_top(toplevel, cancel)?;
        let cmd = self.runner.write(toplevel).args([
            "stash",
            "push",
            "--include-untracked",
            "-m",
            message,
        ]);
        let paths = (!paths.is_empty()).then_some(paths);
        run_with_paths(cmd, paths, cancel)?;
        let after = self.stash_top(toplevel, cancel)?;
        Ok(after.filter(|top| Some(top) != before.as_ref()))
    }

    fn restore_shelf(
        &self,
        toplevel: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        self.stash_index(toplevel, oid, cancel)?;
        let apply = |index: bool| {
            let mut cmd = self.runner.write(toplevel).args(["stash", "apply"]);
            if index {
                cmd = cmd.arg("--index");
            }
            cmd.arg(oid).cancel_token(cancel).run().map(drop)
        };
        match apply(true) {
            Ok(()) => {}
            // `--index` refuses, touching nothing, when the staged part does
            // not apply: the changes come back unstaged instead.
            Err(err) if err.stderr.contains("--index") => apply(false)?,
            Err(err) => return Err(err),
        }
        // Applied: dropping must not be cut short by a cancel.
        self.drop_shelf(toplevel, oid, &CancelToken::new())
    }

    fn drop_shelf(&self, repo: &Path, oid: &str, cancel: &CancelToken) -> Result<(), GitError> {
        let index = self.stash_index(repo, oid, cancel)?;
        let selector = format!("stash@{{{index}}}");
        self.runner
            .write(repo)
            .args(["stash", "drop", "-q", &selector])
            .cancel_token(cancel)
            .run()
            .map(drop)
    }

    fn store_shelf(
        &self,
        repo: &Path,
        oid: &str,
        message: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        self.runner
            .write(repo)
            .args(["stash", "store", "-q", "-m", message, oid])
            .cancel_token(cancel)
            .run()
            .map(drop)
    }

    fn rename_shelf(
        &self,
        repo: &Path,
        oid: &str,
        message: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let index = self.stash_index(repo, oid, cancel)?;
        self.store_shelf(repo, oid, message, cancel)?;
        // The old entry moved one down; check it is still this shelf.
        let old = index + 1;
        let restore = CancelToken::new();
        let list = self.stashes(repo, &restore)?;
        if list.get(old).map(|e| e.oid.as_str()) != Some(oid) {
            return Err(stale_shelf(oid));
        }
        let selector = format!("stash@{{{old}}}");
        self.runner
            .write(repo)
            .args(["stash", "drop", "-q", &selector])
            .cancel_token(&restore)
            .run()
            .map(drop)
    }

    fn shelf_files(
        &self,
        repo: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<Vec<ShelfFile>, GitError> {
        let tracked_args = ["stash", "show", "-z", "-M", "--name-status", oid];
        let out = self.read(repo, &tracked_args, cancel)?;
        let mut files: Vec<ShelfFile> = parse_name_status(&out.stdout)
            .map_err(|e| unexpected(&tracked_args, e))?
            .into_iter()
            .map(|f| ShelfFile {
                change: f.change,
                path: f.path,
                original_path: f.original_path,
                untracked: false,
            })
            .collect();
        let untracked_args = [
            "stash",
            "show",
            "-z",
            "--name-only",
            "--only-untracked",
            oid,
        ];
        let out = self.read(repo, &untracked_args, cancel)?;
        files.extend(
            out.stdout
                .split(|&b| b == 0)
                .filter(|p| !p.is_empty())
                .map(|p| ShelfFile {
                    change: crate::repo::Change::Added,
                    path: crate::repo::git_path(p),
                    original_path: None,
                    untracked: true,
                }),
        );
        Ok(files)
    }

    fn worktree_op(
        &self,
        repo: &Path,
        op: &WorktreeOp,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let mut cmd = self.runner.write(repo).arg("worktree");
        cmd = match op {
            WorktreeOp::Add {
                path,
                branch,
                start: Some(start),
            } => cmd
                .args(["add", "--no-track", "-b", branch])
                .arg(worktree_arg(path))
                .arg(start),
            WorktreeOp::Add {
                path,
                branch,
                start: None,
            } => cmd.arg("add").arg(worktree_arg(path)).arg(branch),
            // A locked worktree needs the force flag twice.
            WorktreeOp::Remove { path, force } => {
                let cmd = cmd.arg("remove");
                let cmd = if *force { cmd.args(["-f", "-f"]) } else { cmd };
                cmd.arg(worktree_arg(path))
            }
            WorktreeOp::Lock { path, reason } => {
                let cmd = cmd.arg("lock");
                let cmd = if reason.is_empty() {
                    cmd
                } else {
                    cmd.args(["--reason", reason])
                };
                cmd.arg(worktree_arg(path))
            }
            WorktreeOp::Unlock { path } => cmd.arg("unlock").arg(worktree_arg(path)),
            WorktreeOp::Prune => cmd.arg("prune"),
        };
        cmd.cancel_token(cancel).run().map(drop)
    }

    fn merged_branches(
        &self,
        repo: &Path,
        base: &str,
        cancel: &CancelToken,
    ) -> Result<Vec<String>, GitError> {
        let merged = format!("--merged={base}");
        let args = [
            "for-each-ref",
            "--format=%(refname)",
            &merged,
            "refs/heads/",
        ];
        let out = self.read(repo, &args, cancel)?;
        Ok(out
            .stdout_text()
            .lines()
            .filter(|l| !l.is_empty())
            .map(str::to_owned)
            .collect())
    }

    fn resolve(
        &self,
        repo: &Path,
        rev: &str,
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError> {
        let rev = format!("{rev}^{{commit}}");
        match self.read(repo, &["rev-parse", "-q", "--verify", &rev], cancel) {
            Ok(out) => Ok(Some(out.stdout_text().trim().to_owned())),
            Err(err) if err.exit_code == Some(1) => Ok(None),
            Err(err) => Err(err),
        }
    }
}

/// Paths for `git worktree` arguments, with forward slashes.
fn worktree_arg(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

/// `git <args>` that aborts `operation`.
fn abort_args(operation: Operation) -> &'static [&'static str] {
    match operation {
        Operation::Merge => &["merge", "--abort"],
        Operation::CherryPick => &["cherry-pick", "--abort"],
        Operation::Revert => &["revert", "--abort"],
        Operation::Rebase { .. } => &["rebase", "--abort"],
        Operation::ApplyMailbox => &["am", "--abort"],
        Operation::Bisect => &["bisect", "reset"],
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

/// The error of a shelf that is no longer in the stash list.
fn stale_shelf(oid: &str) -> GitError {
    GitError::new(
        "stash",
        GitErrorKind::Stale,
        format!(
            "the shelf {} is no longer in the stash list",
            oid.get(..7).unwrap_or(oid)
        ),
    )
}

impl CliBackend {
    /// `n` in `stash@{n}` of the stash whose commit is `oid` (indices shift
    /// as stashes are pushed and dropped, from any worktree).
    fn stash_index(&self, repo: &Path, oid: &str, cancel: &CancelToken) -> Result<usize, GitError> {
        self.stashes(repo, cancel)?
            .iter()
            .find(|e| e.oid == oid)
            .map(|e| e.index)
            .ok_or_else(|| stale_shelf(oid))
    }

    /// The steps of [`GitBackend::commit_selection`] that use the temporary
    /// index at `index`.
    fn commit_with_index(
        &self,
        toplevel: &Path,
        index: &Path,
        write: &IndexWrite,
        message: &str,
        amend: bool,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let git = || {
            self.runner
                .write(toplevel)
                .env("GIT_INDEX_FILE", index)
                .cancel_token(cancel)
        };
        let base = if self.resolve(toplevel, "HEAD", cancel)?.is_some() {
            "HEAD"
        } else {
            "--empty"
        };
        git().args(["read-tree", base]).run()?;
        run_with_paths(git().args(["add", "-A"]), Some(&write.whole), cancel)?;
        if !write.staged.is_empty() {
            let mut input = Vec::new();
            for entry in &write.staged {
                let path = entry.path.to_string_lossy().replace('\\', "/");
                input.extend_from_slice(format!("{} {}\t{path}", entry.mode, entry.oid).as_bytes());
                input.push(0);
            }
            git()
                .args(["update-index", "-z", "--index-info"])
                .stdin(input)
                .run()?;
        }
        for patch in &write.patches {
            git()
                .args(["apply", "--cached", "--recount", "--whitespace=nowarn", "-"])
                .stdin(patch.clone())
                .run()?;
        }
        let mut commit = git().args(["commit", "-F", "-"]);
        if amend {
            commit = commit.arg("--amend");
        }
        commit.stdin(message.as_bytes().to_vec()).run().map(drop)
    }

    /// Id of the empty tree in this repository's hash format (not written).
    fn empty_tree(&self, repo: &Path, cancel: &CancelToken) -> Result<String, GitError> {
        let out = self
            .runner
            .read(repo)
            .args(["hash-object", "-t", "tree", "--stdin"])
            .stdin(Vec::new())
            .cancel_token(cancel)
            .run()?;
        Ok(out.stdout_text().trim().to_owned())
    }

    /// Commit id of the newest stash, if any.
    fn stash_top(&self, toplevel: &Path, cancel: &CancelToken) -> Result<Option<String>, GitError> {
        let verify = ["rev-parse", "-q", "--verify", "refs/stash"];
        match self.read(toplevel, &verify, cancel) {
            Ok(out) => Ok(Some(out.stdout_text().trim().to_owned())),
            // Exit code 1: there is no stash.
            Err(err) if err.exit_code == Some(1) => Ok(None),
            Err(err) => Err(err),
        }
    }

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
            DiffKind::Head => (format!("HEAD:{old_path}"), None),
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
