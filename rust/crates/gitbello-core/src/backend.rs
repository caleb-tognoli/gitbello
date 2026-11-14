//! The `GitBackend` trait and its git CLI implementation (PLAN §3.3).
//!
//! Reads, plus the writes of the milestones so far (staging, commits,
//! discards, sync, branches, tags, cherry-picks and merges).
//! Commands that take paths run in the worktree root with literal pathspecs,
//! so status paths can be passed back unchanged.

use std::collections::HashSet;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use crate::blame::{BlameBlock, BlameOptions, BlameSource};
use crate::changes::IndexEntry;
use crate::compare::{CompareRequest, Comparison};
use crate::diff::{
    parse_diff, untracked_diff, DiffContent, DiffKind, DiffTarget, FileDiff, PatchMode,
};
use crate::git::{
    CancelToken, GitCommand, GitError, GitErrorKind, GitOutput, GitRunner, GitStream, Progress,
};
use crate::ignore::IgnoreMatch;
use crate::merge::{
    ConflictFile, ConflictKind, ConflictOp, HeadInfo, MergeMode, MergePreview, OperationDetails,
    RebaseCheck, UndoMode,
};
use crate::new_repo::{init_folder_error, CloneOptions};
use crate::ops::{CheckoutTarget, PullMode, RefOp, SyncOp, WorktreeOp};
use crate::path_log::PathCommit;
use crate::repo::{
    detect_operation, parse_commit_header, parse_name_status, parse_refs, parse_remote_urls,
    parse_repo_paths, parse_shortstat, parse_stash_list, parse_status, parse_worktrees,
    CommitDetails, Operation, ParseError, Ref, Remote, RepoPaths, RepoStatus, ShelfFile,
    StashEntry, Worktree, COMMIT_SHOW_FORMAT, REFS_ARGS, REPO_PATHS_ARGS, STASH_LIST_ARGS,
    STATUS_ARGS, WORKTREES_ARGS,
};
use crate::worktrees::new_worktree_path_error;

mod amend;
mod blame;
mod compare;
mod ignore;
mod merge;
mod path_log;
mod people;
mod shelf_files;

pub use amend::AmendSnapshot;

/// A shelf replacement, retained to undo a per-file discard.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShelfChange {
    pub old_oid: String,
    pub new_oid: Option<String>,
    pub subject: String,
}

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
    /// The content of blob `oid`, or `None` when it is larger than `limit`
    /// bytes (the old side of a diff, for showing the lines between hunks).
    fn blob(
        &self,
        repo: &Path,
        oid: &str,
        limit: usize,
        cancel: &CancelToken,
    ) -> Result<Option<Vec<u8>>, GitError>;
    /// The first `bytes` bytes of blob `oid` (all of it when shorter), for
    /// a file's first line; `None` when the read was cancelled.
    fn blob_head(
        &self,
        _repo: &Path,
        _oid: &str,
        _bytes: usize,
        _cancel: &CancelToken,
    ) -> Result<Option<Vec<u8>>, GitError> {
        Ok(None)
    }
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
    /// that starts as `write.base` or HEAD's tree, so a failure or a rejecting
    /// hook leaves the real index untouched. After the commit, `write.paths`
    /// are reset to it in the real index.
    fn commit_selection(
        &self,
        toplevel: &Path,
        write: &IndexWrite,
        message: &str,
        amend: bool,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;

    fn prepare_amend(
        &self,
        _repo: &Path,
        _head: &str,
        _write: &IndexWrite,
        _cancel: &CancelToken,
    ) -> Result<AmendSnapshot, GitError> {
        Err(GitError::new(
            "amend",
            GitErrorKind::Other,
            "amend is not supported by this backend",
        ))
    }

    fn amend_changes(
        &self,
        _repo: &Path,
        _snapshot: &AmendSnapshot,
        _cancel: &CancelToken,
    ) -> Result<RepoStatus, GitError> {
        Err(GitError::new(
            "amend",
            GitErrorKind::Other,
            "amend is not supported by this backend",
        ))
    }

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
    /// Lines added and removed per file by the unstaged changes (`git diff
    /// --numstat`, no renames); binary files are left out.
    fn unstaged_numstat(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<(PathBuf, u32, u32)>, GitError>;

    /// Initializes a repository at `path`, which must be missing or empty,
    /// or with `existing`, a folder that is not a repository yet.
    fn init(
        &self,
        path: &Path,
        initial_branch: &str,
        existing: bool,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// Clones `url` to `path`, which must be missing or empty.
    fn clone(
        &self,
        url: &str,
        path: &Path,
        options: &CloneOptions,
        progress: ProgressSink,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// The first of HEAD's root commits (in name order), or `None` on an
    /// unborn branch.
    fn root_commit(&self, repo: &Path, cancel: &CancelToken) -> Result<Option<String>, GitError>;

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
    fn restore_shelf_file(
        &self,
        repo: &Path,
        oid: &str,
        path: &Path,
        cancel: &CancelToken,
    ) -> Result<ShelfChange, GitError>;
    fn discard_shelf_file(
        &self,
        repo: &Path,
        oid: &str,
        path: &Path,
        cancel: &CancelToken,
    ) -> Result<ShelfChange, GitError>;
    /// Restores the original shelf, refusing a stale or renamed remainder.
    fn undo_shelf_change(
        &self,
        repo: &Path,
        change: &ShelfChange,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    fn forget_shelf_change(
        &self,
        repo: &Path,
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
    /// How many commits `tip` has that none of `bases` has.
    fn count_commits(
        &self,
        repo: &Path,
        bases: &[String],
        tip: &str,
        cancel: &CancelToken,
    ) -> Result<u32, GitError>;

    /// What merging `target` (a full ref name or a commit) into HEAD would
    /// do, without touching the working tree. `branch` is the current branch
    /// (for the default message); the overlap with local changes is left empty.
    fn merge_preview(
        &self,
        toplevel: &Path,
        target: &str,
        branch: Option<&str>,
        cancel: &CancelToken,
    ) -> Result<MergePreview, GitError>;
    /// Merges `target` into HEAD, with `message` where `mode` takes one and
    /// the base in the conflict markers (zdiff3). Conflicts fail with
    /// [`GitErrorKind::Conflict`] and leave the merge in progress.
    fn merge(
        &self,
        toplevel: &Path,
        target: &str,
        mode: MergeMode,
        message: Option<&str>,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// What rebasing HEAD onto `target` would do, commit by commit, without
    /// touching the working tree.
    fn rebase_check(
        &self,
        toplevel: &Path,
        target: &str,
        cancel: &CancelToken,
    ) -> Result<RebaseCheck, GitError>;
    /// Rebases HEAD onto `target`, the base in the conflict markers
    /// (zdiff3). Conflicts fail with [`GitErrorKind::Conflict`] and leave
    /// the rebase in progress.
    fn rebase(&self, toplevel: &Path, target: &str, cancel: &CancelToken) -> Result<(), GitError>;
    /// Moves the branch back to `before` (`reset --keep`), if HEAD is still
    /// `after`.
    fn undo_rebase(
        &self,
        toplevel: &Path,
        after: &str,
        before: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// The operation in progress with the banner's details, if any.
    fn operation_details(
        &self,
        repo: &Path,
        cancel: &CancelToken,
    ) -> Result<Option<OperationDetails>, GitError>;
    /// A conflicted file's working-tree content and conflict blocks.
    fn conflict_file(
        &self,
        toplevel: &Path,
        path: &Path,
        kind: ConflictKind,
        cancel: &CancelToken,
    ) -> Result<ConflictFile, GitError>;
    /// Files whose conflicts were resolved (git's resolve-undo record).
    fn resolved_paths(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError>;
    fn conflict_op(
        &self,
        toplevel: &Path,
        op: &ConflictOp,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// Finishes `operation` after its conflicts were resolved: restages the
    /// resolved files, then commits with `message` (git's when `None`) for a
    /// merge or cherry-pick, or continues a rebase.
    fn continue_operation(
        &self,
        toplevel: &Path,
        operation: Operation,
        message: Option<&str>,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// Skips the commit a rebase (or cherry-pick) stopped at.
    fn skip_operation(
        &self,
        toplevel: &Path,
        operation: Operation,
        cancel: &CancelToken,
    ) -> Result<(), GitError>;
    /// The commit the undo strip offers and the commits HEAD lacks.
    fn head_info(&self, repo: &Path, cancel: &CancelToken) -> Result<HeadInfo, GitError>;
    /// Undoes HEAD, which must still be `oid`; returns its message.
    fn undo_commit(
        &self,
        toplevel: &Path,
        oid: &str,
        mode: UndoMode,
        cancel: &CancelToken,
    ) -> Result<String, GitError>;

    /// The untracked files among `paths` that `patterns` (in the
    /// `ls-files -x` form of [`crate::ignore::match_form`]) match.
    fn untracked_matching(
        &self,
        _toplevel: &Path,
        _paths: &[PathBuf],
        _patterns: &[String],
        _cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        Err(unsupported("ignore rules"))
    }
    /// The tracked files that `patterns` match.
    fn tracked_matching(
        &self,
        _toplevel: &Path,
        _patterns: &[String],
        _cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        Err(unsupported("ignore rules"))
    }
    /// The stage-0 index entries of `paths`, to put back after [`Self::untrack`].
    fn index_entries(
        &self,
        _toplevel: &Path,
        _paths: &[PathBuf],
        _cancel: &CancelToken,
    ) -> Result<Vec<IndexEntry>, GitError> {
        Err(unsupported("ignore rules"))
    }
    /// Stops tracking `paths` (`git rm --cached`), leaving them on disk.
    fn untrack(
        &self,
        _toplevel: &Path,
        _paths: &[PathBuf],
        _cancel: &CancelToken,
    ) -> Result<(), GitError> {
        Err(unsupported("ignore rules"))
    }
    /// Writes `entries` into the index as they are.
    fn restore_index_entries(
        &self,
        _toplevel: &Path,
        _entries: &[IndexEntry],
        _cancel: &CancelToken,
    ) -> Result<(), GitError> {
        Err(unsupported("ignore rules"))
    }
    /// Untracked paths git ignores; a folder whose contents are all ignored
    /// is listed once, with a trailing `/` (`ls-files --directory`).
    fn ignored_entries(
        &self,
        _toplevel: &Path,
        _cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        Err(unsupported("ignore rules"))
    }
    /// Tracked files an ignore rule matches.
    fn tracked_ignored(
        &self,
        _toplevel: &Path,
        _cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        Err(unsupported("ignore rules"))
    }
    /// The line that decides each of `paths` (`check-ignore -v`), negations
    /// included; `tracked` for tracked files.
    fn ignore_matches(
        &self,
        _toplevel: &Path,
        _paths: &[PathBuf],
        _tracked: bool,
        _cancel: &CancelToken,
    ) -> Result<Vec<IgnoreMatch>, GitError> {
        Err(unsupported("ignore rules"))
    }
    /// The `.gitignore` files git reads (tracked, or untracked and not
    /// ignored), sorted.
    fn ignore_files(
        &self,
        _toplevel: &Path,
        _cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        Err(unsupported("ignore rules"))
    }
    /// The user's excludes file: `core.excludesFile`, or git's default
    /// (which may not exist yet).
    fn global_excludes_file(
        &self,
        _toplevel: &Path,
        _cancel: &CancelToken,
    ) -> Result<Option<PathBuf>, GitError> {
        Err(unsupported("ignore rules"))
    }

    /// Compare (PLAN M7.12): resolves both sides of `request` in the
    /// worktree `toplevel`, their merge base and commit counts, and the
    /// files that differ (with line counts). An unknown revision fails with
    /// [`GitErrorKind::NotFound`].
    fn compare(
        &self,
        _toplevel: &Path,
        _request: &CompareRequest,
        _cancel: &CancelToken,
    ) -> Result<Comparison, GitError> {
        Err(unsupported("compare"))
    }
    /// The files commit `oid` changed against its first parent (the empty
    /// tree for a root commit), as an exact comparison of the two.
    fn compare_commit(
        &self,
        _toplevel: &Path,
        _oid: &str,
        _cancel: &CancelToken,
    ) -> Result<Comparison, GitError> {
        Err(unsupported("compare commit"))
    }
    /// Writes `paths` as commit `oid` has them into the working tree (not
    /// the index); a path `oid` lacks is deleted. Returns the backup: the
    /// bytes of each path that existed, and an empty id for each that did
    /// not (undo deletes it, see [`GitBackend::restore_backup`]).
    fn restore_from(
        &self,
        _toplevel: &Path,
        _oid: &str,
        _paths: &[PathBuf],
        _cancel: &CancelToken,
    ) -> Result<Vec<(PathBuf, String)>, GitError> {
        Err(unsupported("restore from a revision"))
    }

    /// The path log (PLAN M8a): the commits reachable from `start` that
    /// changed any of `paths` (literal, relative to `toplevel`), newest
    /// first, each handed to `sink` as it is read with what it did to them
    /// against its first parent. An unborn `start` has none. A cancel ends
    /// it with [`GitErrorKind::Cancelled`].
    fn path_log(
        &self,
        _toplevel: &Path,
        _start: &str,
        _paths: &[PathBuf],
        _cancel: &CancelToken,
        _sink: &mut dyn FnMut(PathCommit),
    ) -> Result<(), GitError> {
        Err(unsupported("path logs"))
    }
    /// The name `path` had before `commit` when that commit renamed it
    /// (its tree diff against `parent`, with rename detection).
    fn rename_source(
        &self,
        _toplevel: &Path,
        _commit: &str,
        _parent: &str,
        _path: &Path,
        _cancel: &CancelToken,
    ) -> Result<Option<PathBuf>, GitError> {
        Err(unsupported("rename lookups"))
    }
    /// Writes the file `source` of commit `oid` into the working tree as
    /// `dest` (not the index), as a checkout would write it there. Returns
    /// the backup, as [`GitBackend::restore_from`].
    fn restore_file_as(
        &self,
        _toplevel: &Path,
        _oid: &str,
        _source: &Path,
        _dest: &Path,
        _cancel: &CancelToken,
    ) -> Result<Vec<(PathBuf, String)>, GitError> {
        Err(unsupported("restore under another name"))
    }
    /// The text blame reads (PLAN M8b): the file `path` of commit `rev`,
    /// or of the working tree without one. Larger than `limit` bytes and a
    /// working tree without the file are answers, not errors.
    fn blame_source(
        &self,
        _toplevel: &Path,
        _rev: Option<&str>,
        _path: &Path,
        _limit: usize,
        _cancel: &CancelToken,
    ) -> Result<BlameSource, GitError> {
        Err(unsupported("blame"))
    }
    /// Blames `path` as commit `rev` has it (the working tree without
    /// one): each run of lines goes to `sink` as git finds it, newest
    /// commits first. A cancel ends it with [`GitErrorKind::Cancelled`].
    fn blame(
        &self,
        _toplevel: &Path,
        _rev: Option<&str>,
        _path: &Path,
        _options: BlameOptions,
        _cancel: &CancelToken,
        _sink: &mut dyn FnMut(BlameBlock),
    ) -> Result<(), GitError> {
        Err(unsupported("blame"))
    }
    /// The newest commit `rev` reaches that changed any of `paths`
    /// (literal), by git's history simplification: the files are in `rev`
    /// as that commit left them.
    fn last_change(
        &self,
        _toplevel: &Path,
        _rev: &str,
        _paths: &[PathBuf],
        _cancel: &CancelToken,
    ) -> Result<Option<String>, GitError> {
        Err(unsupported("last-change lookups"))
    }
    /// Lines the working tree adds to and removes from the file of `target`
    /// (a Changes diff: against HEAD, or an untracked file in full). `None`
    /// for a binary file, a conflicted one and an untracked one too large
    /// to count.
    fn working_line_stats(
        &self,
        _toplevel: &Path,
        _target: &DiffTarget,
        _cancel: &CancelToken,
    ) -> Result<Option<(u32, u32)>, GitError> {
        Err(unsupported("working line counts"))
    }
    /// The newest commit on `remote`'s branches that `email` authored, or
    /// else committed: one the remote's host knows (for profile pictures).
    fn published_commit_by(
        &self,
        _repo: &Path,
        _remote: &str,
        _email: &str,
        _cancel: &CancelToken,
    ) -> Result<Option<String>, GitError> {
        Err(unsupported("commit lookups by person"))
    }
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
    /// Tree to start from instead of HEAD, for an amend session.
    pub base: Option<String>,
    /// Commit and branch that an amend must still be on when it commits.
    pub expected_head: Option<(String, crate::repo::Head)>,
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

    /// Whether the repository has any remote-tracking branch (without one,
    /// `--not --remotes` would count the whole history as unpublished).
    fn has_remote_branches(&self, repo: &Path, cancel: &CancelToken) -> Result<bool, GitError> {
        let out = self.read(
            repo,
            &["for-each-ref", "--count=1", "--format=x", "refs/remotes/"],
            cancel,
        )?;
        Ok(!out.stdout_text().trim().is_empty())
    }

    /// Commits of `oid` on no remote branch: what publishing its branch
    /// sends. 0 when the repository has no remote branches.
    fn unpublished_count(
        &self,
        repo: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<u32, GitError> {
        if !self.has_remote_branches(repo, cancel)? {
            return Ok(0);
        }
        let args = ["rev-list", "--count", oid, "--not", "--remotes", "--"];
        let out = self.read(repo, &args, cancel)?;
        out.stdout_text().trim().parse().map_err(|_| {
            GitError::new(
                "rev-list --count",
                GitErrorKind::UnexpectedOutput,
                out.stdout_text().trim(),
            )
        })
    }

    /// The commits [`Self::unpublished_count`] counts.
    pub(crate) fn unpublished_commits(
        &self,
        repo: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<HashSet<String>, GitError> {
        if !self.has_remote_branches(repo, cancel)? {
            return Ok(HashSet::new());
        }
        let out = self.read(repo, &["rev-list", oid, "--not", "--remotes", "--"], cancel)?;
        Ok(out.stdout_text().lines().map(str::to_owned).collect())
    }

    /// Keeps nested worktrees out of status without changing a tracked `.gitignore`.
    fn exclude_default_worktrees(
        &self,
        repo: &Path,
        path: &Path,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let main = self
            .worktrees(repo, cancel)?
            .into_iter()
            .find(|wt| wt.is_main);
        let Some(main) = main else {
            return Ok(());
        };
        if !path.starts_with(main.path.join(".worktrees")) {
            return Ok(());
        }
        let exclude = self
            .repo_paths(repo, cancel)?
            .common_dir
            .join("info/exclude");
        let io = |err: std::io::Error| {
            GitError::new(
                format!("write {}", exclude.display()),
                GitErrorKind::Io,
                err.to_string(),
            )
        };
        let contents = match fs::read(&exclude) {
            Ok(contents) => contents,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(err) => return Err(io(err)),
        };
        if String::from_utf8_lossy(&contents)
            .lines()
            .any(|line| line == "/.worktrees/")
        {
            return Ok(());
        }
        if let Some(parent) = exclude.parent() {
            fs::create_dir_all(parent).map_err(io)?;
        }
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&exclude)
            .map_err(io)?;
        if contents.last().is_some_and(|b| *b != b'\n') {
            writeln!(file).map_err(io)?;
        }
        writeln!(file, "/.worktrees/").map_err(io)
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
    "--unified=3",
    "--src-prefix=a/",
    "--dst-prefix=b/",
];

/// `(path, added, removed)` from `git diff --numstat -z --no-renames`
/// output (`added<TAB>removed<TAB>path<NUL>`); binary files (`-`) are left out.
fn parse_numstat(output: &[u8]) -> Vec<(PathBuf, u32, u32)> {
    let mut stats = Vec::new();
    for record in output.split(|&b| b == 0).filter(|r| !r.is_empty()) {
        let mut fields = record.splitn(3, |&b| b == b'\t');
        let (Some(added), Some(removed), Some(path)) =
            (fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        let number = |field: &[u8]| std::str::from_utf8(field).ok()?.parse::<u32>().ok();
        if let (Some(added), Some(removed)) = (number(added), number(removed)) {
            stats.push((
                PathBuf::from(String::from_utf8_lossy(path).into_owned()),
                added,
                removed,
            ));
        }
    }
    stats
}

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
    "--unified=3",
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
        let mut status = parse_status(&out.stdout).map_err(|e| unexpected(STATUS_ARGS, e))?;
        if status.unpublished {
            if let Some(oid) = status.oid.clone() {
                status.ahead = self.unpublished_count(repo, &oid, cancel)?;
            }
        }
        Ok(status)
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
        let amend_index = if target.kind == DiffKind::Amend {
            let base = target
                .commit
                .as_ref()
                .and_then(|s| s.parent.as_deref())
                .ok_or_else(|| {
                    GitError::new(
                        "diff",
                        GitErrorKind::UnexpectedOutput,
                        "missing amend baseline",
                    )
                })?;
            let entry = self
                .runner
                .read(toplevel)
                .env("GIT_LITERAL_PATHSPECS", "1")
                .args(["ls-tree", "-z", base, "--"])
                .arg(&target.path)
                .cancel_token(cancel)
                .run()?;
            if entry.stdout.is_empty() && toplevel.join(&target.path).is_file() {
                return read_untracked(&toplevel.join(&target.path), limit);
            }
            Some(self.amend_read_index(toplevel, base, cancel)?)
        } else {
            None
        };
        let mut cmd = self.runner.read(toplevel).env("GIT_LITERAL_PATHSPECS", "1");
        if let Some(index) = &amend_index {
            cmd = cmd.env("GIT_INDEX_FILE", &index.0);
        }
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
        if matches!(target.kind, DiffKind::Amend | DiffKind::AmendStaged) {
            let side = target.commit.as_ref().ok_or_else(|| {
                GitError::new(
                    "diff",
                    GitErrorKind::UnexpectedOutput,
                    "missing amend baseline",
                )
            })?;
            let base = side.parent.as_deref().ok_or_else(|| {
                GitError::new(
                    "diff",
                    GitErrorKind::UnexpectedOutput,
                    "missing amend parent",
                )
            })?;
            cmd = cmd.args(["--no-renames", base]);
            if target.kind == DiffKind::AmendStaged {
                cmd = cmd.arg(&side.oid);
            }
        }
        if target.kind == DiffKind::Working {
            let base = target
                .commit
                .as_ref()
                .and_then(|s| s.parent.as_deref())
                .ok_or_else(|| {
                    GitError::new(
                        "diff",
                        GitErrorKind::UnexpectedOutput,
                        "missing compare base",
                    )
                })?;
            cmd = cmd.args(["-M", base]);
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
        let stream = cmd.arg(&target.path).stream()?;
        let command = stream.command().to_owned();
        let output = match read_limited(stream, limit.unwrap_or(usize::MAX), cancel)? {
            Limited::Read(output) => output,
            Limited::TooLarge(bytes) => return Ok(FileDiff::too_large(bytes)),
            Limited::Cancelled => return Ok(FileDiff::default()),
        };
        let mut diff = parse_diff(&output).map_err(|e| unexpected(&[command.as_str()], e))?;
        if let DiffContent::Binary { .. } = diff.content {
            diff.content = self.binary_sizes(toplevel, target, cancel);
        }
        Ok(diff)
    }

    fn blob(
        &self,
        repo: &Path,
        oid: &str,
        limit: usize,
        cancel: &CancelToken,
    ) -> Result<Option<Vec<u8>>, GitError> {
        let stream = self
            .runner
            .read(repo)
            .args(["cat-file", "blob", oid])
            .stream()?;
        Ok(match read_limited(stream, limit, cancel)? {
            Limited::Read(text) => Some(text),
            Limited::TooLarge(_) | Limited::Cancelled => None,
        })
    }

    fn blob_head(
        &self,
        repo: &Path,
        oid: &str,
        bytes: usize,
        cancel: &CancelToken,
    ) -> Result<Option<Vec<u8>>, GitError> {
        let stream = self
            .runner
            .read(repo)
            .args(["cat-file", "blob", oid])
            .stream()?;
        read_head(stream, bytes, cancel)
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

    fn prepare_amend(
        &self,
        repo: &Path,
        head: &str,
        write: &IndexWrite,
        cancel: &CancelToken,
    ) -> Result<AmendSnapshot, GitError> {
        self.prepare_amend_snapshot(repo, head, write, cancel)
    }

    fn amend_changes(
        &self,
        repo: &Path,
        snapshot: &AmendSnapshot,
        cancel: &CancelToken,
    ) -> Result<RepoStatus, GitError> {
        self.read_amend_changes(repo, snapshot, cancel)
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
        let range: Vec<&str> = match details.parents.first() {
            Some(parent) => vec![parent, &details.oid],
            None => vec!["--root", &details.oid],
        };
        args.extend(&range);
        let out = self.read(repo, &args, cancel)?;
        let files = parse_name_status(&out.stdout).map_err(|e| unexpected(&args, e))?;
        let mut stat_args = vec!["diff-tree", "-r", "-M", "--shortstat", "--no-commit-id"];
        stat_args.extend(&range);
        let stat = self.read(repo, &stat_args, cancel)?;
        (details.additions, details.deletions) = parse_shortstat(&stat.stdout);
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
            let target = toplevel.join(path);
            if oid.is_empty() {
                // The file did not exist before: undo removes it.
                match fs::remove_file(&target) {
                    Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
                        return Err(GitError::new(
                            format!("delete {}", target.display()),
                            GitErrorKind::Io,
                            err.to_string(),
                        ));
                    }
                    _ => continue,
                }
            }
            let out = self
                .runner
                .read(toplevel)
                .args(["cat-file", "blob", oid])
                .cancel_token(cancel)
                .run()?;
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

    fn unstaged_numstat(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<(PathBuf, u32, u32)>, GitError> {
        let out = self
            .runner
            .read(toplevel)
            .args([
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--no-relative",
                "--no-renames",
                "--numstat",
                "-z",
            ])
            .cancel_token(cancel)
            .run()?;
        Ok(parse_numstat(&out.stdout))
    }

    fn init(
        &self,
        path: &Path,
        initial_branch: &str,
        existing: bool,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let error = if existing {
            init_folder_error(path)
        } else {
            new_worktree_path_error(path)
        };
        if let Some(error) = error {
            return Err(GitError::new("init", GitErrorKind::AlreadyExists, error));
        }
        fs::create_dir_all(path).map_err(|err| {
            GitError::new(
                format!("create {}", path.display()),
                GitErrorKind::Io,
                err.to_string(),
            )
        })?;
        self.runner
            .write(path)
            .args(["init", "--initial-branch"])
            .arg(initial_branch)
            .cancel_token(cancel)
            .run()
            .map(drop)
    }

    fn clone(
        &self,
        url: &str,
        path: &Path,
        options: &CloneOptions,
        progress: ProgressSink,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        if let Some(error) = new_worktree_path_error(path) {
            return Err(GitError::new("clone", GitErrorKind::AlreadyExists, error));
        }
        let parent = path.parent().unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(parent).map_err(|err| {
            GitError::new(
                format!("create {}", parent.display()),
                GitErrorKind::Io,
                err.to_string(),
            )
        })?;
        let mut cmd = self
            .runner
            .write(parent)
            .args(["clone", "--progress", "--no-local"]);
        if let Some(branch) = &options.branch {
            cmd = cmd.arg("--branch").arg(branch);
        }
        if options.submodules {
            cmd = cmd.arg("--recurse-submodules");
        }
        cmd.arg("--")
            .arg(url)
            .arg(path)
            .on_progress(progress)
            .cancel_token(cancel)
            .run()
            .map(drop)
    }

    fn root_commit(&self, repo: &Path, cancel: &CancelToken) -> Result<Option<String>, GitError> {
        // An unborn branch has no commits.
        if self
            .read(repo, &["rev-parse", "--verify", "-q", "HEAD"], cancel)
            .is_err()
        {
            return Ok(None);
        }
        let out = self.read(repo, &["rev-list", "--max-parents=0", "HEAD", "--"], cancel)?;
        Ok(String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .min()
            .map(str::to_owned))
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
                if let Some(lease) = spec.lease_arg() {
                    cmd = cmd.arg(lease);
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
            RefOp::DeleteRef { name } => git(&["update-ref", "-d", name]),
            RefOp::AddRemote { name, url } => git(&["remote", "add", "--", name, url]),
            RefOp::RenameRemote { old, new } => git(&["remote", "rename", "--", old, new]),
            RefOp::RemoveRemote { name } => git(&["remote", "remove", "--", name]),
            RefOp::SetRemoteUrl { name, url } => git(&["remote", "set-url", "--", name, url]),
            RefOp::CherryPick { commits } => match commits.as_slice() {
                [] => Ok(()),
                [commit] => {
                    let parents = ["rev-list", "--parents", "-n", "1", commit, "--"];
                    let out = self.read(toplevel, &parents, cancel)?;
                    // The commit itself plus more than one parent: a merge.
                    if out.stdout_text().split_whitespace().count() > 2 {
                        git(&["cherry-pick", "--mainline", "1", commit])
                    } else {
                        git(&["cherry-pick", commit])
                    }
                }
                many => {
                    let mut args = vec!["cherry-pick"];
                    args.extend(many.iter().map(String::as_str));
                    git(&args)
                }
            },
            RefOp::Abort(operation) => git(abort_args(*operation)),
        }
    }

    fn stash_push(
        &self,
        toplevel: &Path,
        message: &str,
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError> {
        let _lock = self.shelf_lock(toplevel, cancel)?;
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
        let _lock = self.shelf_lock(toplevel, cancel)?;
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
        let _lock = self.shelf_lock(toplevel, cancel)?;
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
        let _lock = self.shelf_lock(toplevel, cancel)?;
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
        self.drop_shelf_unlocked(toplevel, oid, &CancelToken::new())
    }

    fn drop_shelf(&self, repo: &Path, oid: &str, cancel: &CancelToken) -> Result<(), GitError> {
        let _lock = self.shelf_lock(repo, cancel)?;
        self.drop_shelf_unlocked(repo, oid, cancel)
    }

    fn restore_shelf_file(
        &self,
        repo: &Path,
        oid: &str,
        path: &Path,
        cancel: &CancelToken,
    ) -> Result<ShelfChange, GitError> {
        self.edit_shelf_file(repo, oid, path, true, cancel)
    }

    fn discard_shelf_file(
        &self,
        repo: &Path,
        oid: &str,
        path: &Path,
        cancel: &CancelToken,
    ) -> Result<ShelfChange, GitError> {
        self.edit_shelf_file(repo, oid, path, false, cancel)
    }

    fn undo_shelf_change(
        &self,
        repo: &Path,
        change: &ShelfChange,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        self.undo_shelf_file_change(repo, change, cancel)
    }

    fn forget_shelf_change(
        &self,
        repo: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        self.remove_shelf_backup(repo, oid, cancel)
    }

    fn store_shelf(
        &self,
        repo: &Path,
        oid: &str,
        message: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let _lock = self.shelf_lock(repo, cancel)?;
        self.store_shelf_unlocked(repo, oid, message, cancel)
    }

    fn rename_shelf(
        &self,
        repo: &Path,
        oid: &str,
        message: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let _lock = self.shelf_lock(repo, cancel)?;
        let index = self.stash_index(repo, oid, cancel)?;
        if index == 0 {
            // `stash store` does nothing when refs/stash already points at
            // this commit. Keep it reachable while replacing the top entry,
            // and put the original back if storing its new name fails.
            let entries = self.stashes(repo, cancel)?;
            let original = crate::repo::shelves(&entries)
                .into_iter()
                .find(|s| s.oid == oid)
                .ok_or_else(|| stale_shelf(oid))?;
            let backup = format!("refs/gitbello/rename-shelf/{oid}");
            self.runner
                .write(repo)
                .args(["update-ref", &backup, oid, ""])
                .cancel_token(cancel)
                .run()?;
            let finish = CancelToken::new();
            let remove_backup = || {
                self.runner
                    .write(repo)
                    .args(["update-ref", "-d", &backup, oid])
                    .cancel_token(&finish)
                    .run()
                    .map(drop)
            };
            if let Err(error) = self.drop_shelf_unlocked(repo, oid, &finish) {
                remove_backup()?;
                return Err(error);
            }
            if let Err(error) = self.store_shelf_unlocked(repo, oid, message, &finish) {
                // Leave the backup ref in place if recovery itself fails.
                self.store_shelf_unlocked(repo, oid, &original.subject, &finish)?;
                remove_backup()?;
                return Err(error);
            }
            return remove_backup();
        }
        self.store_shelf_unlocked(repo, oid, message, cancel)?;
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
                index_only: false,
            })
            .collect();
        // A stash can contain staged edits whose working-copy content equals
        // the base. Include these so partial edits never leave an invisible
        // index-only remainder behind.
        let staged_args = [
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "-z",
            "-M",
            "--name-status",
            &format!("{oid}^1"),
            &format!("{oid}^2"),
            "--",
        ];
        let staged = self.read(repo, &staged_args, cancel)?;
        for f in parse_name_status(&staged.stdout).map_err(|e| unexpected(&staged_args, e))? {
            let represented = files.iter().any(|known| {
                known.path == f.path
                    || (f.original_path.is_some() && known.original_path == f.original_path)
            });
            if !represented {
                files.push(ShelfFile {
                    change: f.change,
                    path: f.path,
                    original_path: f.original_path,
                    untracked: false,
                    index_only: true,
                });
            }
        }
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
                    index_only: false,
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
        if let WorktreeOp::Add { path, .. } = op {
            self.exclude_default_worktrees(repo, path, cancel)?;
        }
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

    fn count_commits(
        &self,
        repo: &Path,
        bases: &[String],
        tip: &str,
        cancel: &CancelToken,
    ) -> Result<u32, GitError> {
        let excluded: Vec<String> = bases.iter().map(|b| format!("^{b}")).collect();
        let mut args = vec!["rev-list", "--count", tip];
        args.extend(excluded.iter().map(String::as_str));
        args.push("--");
        let out = self.read(repo, &args, cancel)?;
        out.stdout_text().trim().parse().map_err(|_| {
            GitError::new(
                format!("rev-list --count {tip}"),
                GitErrorKind::UnexpectedOutput,
                out.stdout_text(),
            )
        })
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

    fn merge_preview(
        &self,
        toplevel: &Path,
        target: &str,
        branch: Option<&str>,
        cancel: &CancelToken,
    ) -> Result<MergePreview, GitError> {
        self.merge_preview_impl(toplevel, target, branch, cancel)
    }

    fn merge(
        &self,
        toplevel: &Path,
        target: &str,
        mode: MergeMode,
        message: Option<&str>,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        self.merge_impl(toplevel, target, mode, message, cancel)
    }

    fn rebase_check(
        &self,
        toplevel: &Path,
        target: &str,
        cancel: &CancelToken,
    ) -> Result<RebaseCheck, GitError> {
        self.rebase_check_impl(toplevel, target, cancel)
    }

    fn rebase(&self, toplevel: &Path, target: &str, cancel: &CancelToken) -> Result<(), GitError> {
        self.rebase_impl(toplevel, target, cancel)
    }

    fn undo_rebase(
        &self,
        toplevel: &Path,
        after: &str,
        before: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        self.undo_rebase_impl(toplevel, after, before, cancel)
    }

    fn operation_details(
        &self,
        repo: &Path,
        cancel: &CancelToken,
    ) -> Result<Option<OperationDetails>, GitError> {
        self.operation_details_impl(repo, cancel)
    }

    fn conflict_file(
        &self,
        toplevel: &Path,
        path: &Path,
        kind: ConflictKind,
        cancel: &CancelToken,
    ) -> Result<ConflictFile, GitError> {
        self.conflict_file_impl(toplevel, path, kind, cancel)
    }

    fn resolved_paths(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        self.resolved_paths_impl(toplevel, cancel)
    }

    fn conflict_op(
        &self,
        toplevel: &Path,
        op: &ConflictOp,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        self.conflict_op_impl(toplevel, op, cancel)
    }

    fn continue_operation(
        &self,
        toplevel: &Path,
        operation: Operation,
        message: Option<&str>,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        self.continue_operation_impl(toplevel, operation, message, cancel)
    }

    fn skip_operation(
        &self,
        toplevel: &Path,
        operation: Operation,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        self.skip_operation_impl(toplevel, operation, cancel)
    }

    fn compare(
        &self,
        toplevel: &Path,
        request: &CompareRequest,
        cancel: &CancelToken,
    ) -> Result<Comparison, GitError> {
        self.compare_sides(toplevel, request, cancel)
    }

    fn compare_commit(
        &self,
        toplevel: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<Comparison, GitError> {
        self.compare_one_commit(toplevel, oid, cancel)
    }

    fn restore_from(
        &self,
        toplevel: &Path,
        oid: &str,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<Vec<(PathBuf, String)>, GitError> {
        self.restore_paths_from(toplevel, oid, paths, cancel)
    }

    fn path_log(
        &self,
        toplevel: &Path,
        start: &str,
        paths: &[PathBuf],
        cancel: &CancelToken,
        sink: &mut dyn FnMut(PathCommit),
    ) -> Result<(), GitError> {
        self.stream_path_log(toplevel, start, paths, cancel, sink)
    }

    fn rename_source(
        &self,
        toplevel: &Path,
        commit: &str,
        parent: &str,
        path: &Path,
        cancel: &CancelToken,
    ) -> Result<Option<PathBuf>, GitError> {
        self.find_rename_source(toplevel, commit, parent, path, cancel)
    }

    fn restore_file_as(
        &self,
        toplevel: &Path,
        oid: &str,
        source: &Path,
        dest: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<(PathBuf, String)>, GitError> {
        self.restore_file_to(toplevel, oid, source, dest, cancel)
    }

    fn working_line_stats(
        &self,
        toplevel: &Path,
        target: &DiffTarget,
        cancel: &CancelToken,
    ) -> Result<Option<(u32, u32)>, GitError> {
        self.count_working_lines(toplevel, target, cancel)
    }

    fn published_commit_by(
        &self,
        repo: &Path,
        remote: &str,
        email: &str,
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError> {
        self.find_published_commit(repo, remote, email, cancel)
    }

    fn blame_source(
        &self,
        toplevel: &Path,
        rev: Option<&str>,
        path: &Path,
        limit: usize,
        cancel: &CancelToken,
    ) -> Result<BlameSource, GitError> {
        self.read_blame_source(toplevel, rev, path, limit, cancel)
    }

    fn blame(
        &self,
        toplevel: &Path,
        rev: Option<&str>,
        path: &Path,
        options: BlameOptions,
        cancel: &CancelToken,
        sink: &mut dyn FnMut(BlameBlock),
    ) -> Result<(), GitError> {
        self.stream_blame(toplevel, rev, path, options, cancel, sink)
    }

    fn last_change(
        &self,
        toplevel: &Path,
        rev: &str,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError> {
        self.find_last_change(toplevel, rev, paths, cancel)
    }

    fn head_info(&self, repo: &Path, cancel: &CancelToken) -> Result<HeadInfo, GitError> {
        self.head_info_impl(repo, cancel)
    }

    fn undo_commit(
        &self,
        toplevel: &Path,
        oid: &str,
        mode: UndoMode,
        cancel: &CancelToken,
    ) -> Result<String, GitError> {
        self.undo_commit_impl(toplevel, oid, mode, cancel)
    }

    fn untracked_matching(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        patterns: &[String],
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        self.untracked_matching_impl(toplevel, paths, patterns, cancel)
    }

    fn tracked_matching(
        &self,
        toplevel: &Path,
        patterns: &[String],
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        self.tracked_matching_impl(toplevel, patterns, cancel)
    }

    fn index_entries(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<Vec<IndexEntry>, GitError> {
        self.index_entries_impl(toplevel, paths, cancel)
    }

    fn untrack(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        self.untrack_impl(toplevel, paths, cancel)
    }

    fn restore_index_entries(
        &self,
        toplevel: &Path,
        entries: &[IndexEntry],
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        self.restore_index_entries_impl(toplevel, entries, cancel)
    }
    fn ignored_entries(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        self.ignored_entries_impl(toplevel, cancel)
    }

    fn tracked_ignored(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        self.tracked_ignored_impl(toplevel, cancel)
    }

    fn ignore_matches(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        tracked: bool,
        cancel: &CancelToken,
    ) -> Result<Vec<IgnoreMatch>, GitError> {
        self.ignore_matches_impl(toplevel, paths, tracked, cancel)
    }

    fn ignore_files(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        self.ignore_files_impl(toplevel, cancel)
    }

    fn global_excludes_file(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Option<PathBuf>, GitError> {
        self.global_excludes_file_impl(toplevel, cancel)
    }
}

/// The error of an operation a backend does not support.
fn unsupported(what: &str) -> GitError {
    GitError::new(
        what,
        GitErrorKind::Other,
        format!("{what} are not supported by this backend"),
    )
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
    fn drop_shelf_unlocked(
        &self,
        repo: &Path,
        oid: &str,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let index = self.stash_index(repo, oid, cancel)?;
        let selector = format!("stash@{{{index}}}");
        self.runner
            .write(repo)
            .args(["stash", "drop", "-q", &selector])
            .cancel_token(cancel)
            .run()
            .map(drop)
    }

    fn store_shelf_unlocked(
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
        if let Some((head, branch)) = &write.expected_head {
            self.check_amend_head(toplevel, head, cancel)?;
            if self.status(toplevel, cancel)?.head != *branch {
                return Err(GitError::new(
                    "amend",
                    GitErrorKind::Stale,
                    "The last commit changed. Start amend again.",
                ));
            }
        }
        let base = match &write.base {
            Some(base) => base.as_str(),
            None if self.resolve(toplevel, "HEAD", cancel)?.is_some() => "HEAD",
            None => "--empty",
        };
        self.write_selection_index(toplevel, index, base, write, cancel)?;
        if let Some((head, branch)) = &write.expected_head {
            self.check_amend_head(toplevel, head, cancel)?;
            if self.status(toplevel, cancel)?.head != *branch {
                return Err(GitError::new(
                    "amend",
                    GitErrorKind::Stale,
                    "The last commit changed. Start amend again.",
                ));
            }
        }
        let mut commit = self
            .runner
            .write(toplevel)
            .env("GIT_INDEX_FILE", index)
            .cancel_token(cancel)
            .args(["commit", "-F", "-"]);
        if amend {
            commit = commit.arg("--amend");
            if write.base.is_some() {
                commit = commit.arg("--allow-empty");
            }
        }
        commit.stdin(message.as_bytes().to_vec()).run().map(drop)
    }

    fn write_selection_index(
        &self,
        toplevel: &Path,
        index: &Path,
        base: &str,
        write: &IndexWrite,
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let git = || {
            self.runner
                .write(toplevel)
                .env("GIT_INDEX_FILE", index)
                .cancel_token(cancel)
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
        Ok(())
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
            DiffKind::Amend | DiffKind::AmendStaged => {
                let side = target.commit.as_ref();
                let base = side.and_then(|s| s.parent.as_deref()).unwrap_or("HEAD");
                (
                    format!("{base}:{old_path}"),
                    if target.kind == DiffKind::AmendStaged {
                        side.map(|s| format!("{}:{path}", s.oid))
                    } else {
                        None
                    },
                )
            }
            DiffKind::Unstaged | DiffKind::Untracked => (format!(":{path}"), None),
            DiffKind::Commit => {
                let side = target.commit.as_ref();
                let oid = side.map_or("HEAD", |c| c.oid.as_str());
                // `<oid>^` is missing for a root commit, which reads as "no old side".
                let old = side
                    .and_then(|c| c.parent.clone())
                    .unwrap_or_else(|| format!("{oid}^"));
                (format!("{old}:{old_path}"), Some(format!("{oid}:{path}")))
            }
            DiffKind::Working => {
                let base = target
                    .commit
                    .as_ref()
                    .and_then(|c| c.parent.as_deref())
                    .unwrap_or("HEAD");
                (format!("{base}:{old_path}"), None)
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
/// What [`read_limited`] read.
enum Limited {
    Read(Vec<u8>),
    /// Stopped past the limit, after this many bytes.
    TooLarge(usize),
    Cancelled,
}

/// Reads `stream` to the end, or stops once it passes `limit` bytes or is
/// cancelled (git is stopped; the log records it as cancelled).
fn read_limited(
    mut stream: GitStream,
    limit: usize,
    cancel: &CancelToken,
) -> Result<Limited, GitError> {
    let mut output = Vec::new();
    let mut chunk = vec![0u8; 64 * 1024];
    loop {
        if cancel.is_cancelled() {
            stream.kill();
            return stream.finish().map(|()| Limited::Cancelled);
        }
        let n = stream
            .read(&mut chunk)
            .map_err(|err| GitError::new(stream.command(), GitErrorKind::Io, err.to_string()))?;
        if n == 0 {
            break;
        }
        output.extend_from_slice(&chunk[..n]);
        if output.len() > limit {
            return Ok(Limited::TooLarge(output.len()));
        }
    }
    stream.finish()?;
    Ok(Limited::Read(output))
}

/// The first `bytes` bytes of `stream`, then git is stopped; `None` when
/// cancelled.
fn read_head(
    mut stream: GitStream,
    bytes: usize,
    cancel: &CancelToken,
) -> Result<Option<Vec<u8>>, GitError> {
    let mut output = Vec::with_capacity(bytes);
    let mut chunk = vec![0u8; bytes.clamp(1, 64 * 1024)];
    while output.len() < bytes {
        if cancel.is_cancelled() {
            stream.kill();
            return stream.finish().map(|()| None);
        }
        let n = stream
            .read(&mut chunk)
            .map_err(|err| GitError::new(stream.command(), GitErrorKind::Io, err.to_string()))?;
        if n == 0 {
            stream.finish()?;
            return Ok(Some(output));
        }
        output.extend_from_slice(&chunk[..n]);
    }
    output.truncate(bytes);
    stream.kill();
    Ok(Some(output))
}

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
