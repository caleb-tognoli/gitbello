//! The app's core runtime (PLAN §3.5): config, git, jobs, the watcher and the
//! cached state of every open repository.
//!
//! The UI owns one `Runtime`, calls [`Runtime::poll`] once per frame (cheap
//! when idle) and reads repository state between polls. Nothing here blocks:
//! opening and refreshing run as jobs.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use crate::backend::{CliBackend, GitBackend, IndexWrite, PatchGuard, ShelfChange};
use crate::changes::{self, ChangeFilter, ChangeList, FilePick, PickState, Selection};
use crate::config::{Config, ConfigError};
use crate::diff::{
    build_patch, CommitSide, DiffContent, DiffKind, DiffLayout, DiffTarget, Expand, Expansion,
    FileDiff, OldFile, PatchMode, LARGE_DIFF_BYTES,
};
use crate::git::{
    CancelToken, CommandLog, GitError, GitErrorKind, GitRunner, GitVersion, Progress,
};
use crate::graph::{CommitSearch, GraphLoader, GRAPH_JOB_LABEL, SEARCH_JOB_LABEL};
use crate::jobs::{
    Event, EventKind, JobId, JobOutput, JobScheduler, JobSpec, RefreshKind, RefreshSet,
};
use crate::merge::{
    self as merge, BlockChoice, ConflictFile, ConflictKind, ConflictLayout, ConflictOp, FileChoice,
    HeadInfo, MergeMode, MergePreview, OperationDetails, UndoMode, UndoableCommit,
};
use crate::ops::{
    CheckoutChanges, CheckoutTarget, NewTask, PullMode, PushSpec, RefOp, SyncOp, WorktreeOp,
    AUTO_FETCH_JOB_LABEL, CHECKOUT_JOB_LABEL, CLEANUP_JOB_LABEL, FETCH_JOB_LABEL,
    NEW_TASK_JOB_LABEL, PULL_JOB_LABEL, PUSH_JOB_LABEL,
};
use crate::repo::{
    shelf_message, shelves, CommitDetails, FileState, Head, Operation, Ref, RefKind, Remote,
    RepoPaths, RepoStatus, Shelf, ShelfFile, StashEntry, Worktree,
};
use crate::sidebar::{labels_by_commit, Badge, RefLabel};
use crate::watch::{RepoWatcher, WatchTarget, DEFAULT_DEBOUNCE};
use crate::worktrees::{cleanup_candidates, default_base, CleanupCandidate};

/// Label of the job that resolves a repository when it is opened.
pub const OPEN_JOB_LABEL: &str = "open repository";
pub const CREATE_REPOSITORY_JOB_LABEL: &str = "create repository";
pub const CLONE_REPOSITORY_JOB_LABEL: &str = "clone repository";

/// Labels of the jobs the changes panel runs.
pub const DIFF_JOB_LABEL: &str = "load diff";
pub const COMMIT_DIFF_JOB_LABEL: &str = "load commit diff";
/// Reads the old side of a diff to show the lines between its hunks.
pub const OLD_FILE_JOB_LABEL: &str = "read old file";
/// Old files larger than this are not read: their gaps stay closed.
pub const OLD_FILE_LIMIT: usize = 16 * 1024 * 1024;
pub const COMMIT_DETAILS_JOB_LABEL: &str = "read commit";
pub const HEAD_MESSAGE_JOB_LABEL: &str = "read HEAD message";
pub const STAGE_JOB_LABEL: &str = "stage";
pub const UNSTAGE_JOB_LABEL: &str = "unstage";
pub const COMMIT_JOB_LABEL: &str = "commit";
pub const DISCARD_JOB_LABEL: &str = "discard";
pub const UNDO_DISCARD_JOB_LABEL: &str = "undo discard";

/// Labels of the shelf jobs (PLAN §4 Shelves).
pub const SHELVE_JOB_LABEL: &str = "shelve";
pub const RESTORE_SHELF_JOB_LABEL: &str = "restore shelf";
pub const RESTORE_SHELF_FILE_JOB_LABEL: &str = "restore shelf file";
pub const DISCARD_SHELF_FILE_JOB_LABEL: &str = "discard shelf file";
pub const RENAME_SHELF_JOB_LABEL: &str = "rename shelf";
pub const DISCARD_SHELF_JOB_LABEL: &str = "discard shelf";
pub const UNDO_SHELF_DISCARD_JOB_LABEL: &str = "undo shelf discard";
pub const SHELF_FILES_JOB_LABEL: &str = "read shelf";

/// Labels of the merge workflow jobs (PLAN §4, M7).
pub const MERGE_PREVIEW_JOB_LABEL: &str = "preview merge";
pub const MERGE_JOB_LABEL: &str = "merge";
pub const CONTINUE_JOB_LABEL: &str = "continue";
pub const SKIP_JOB_LABEL: &str = "skip";
pub const CONFLICT_JOB_LABEL: &str = "load conflict";
pub const CONFLICT_SCAN_JOB_LABEL: &str = "scan conflicts";
pub const RESOLVE_JOB_LABEL: &str = "resolve conflict";
pub const UNDO_RESOLVE_JOB_LABEL: &str = "undo conflict choice";
pub const MARK_RESOLVED_JOB_LABEL: &str = "mark resolved";
pub const REOPEN_JOB_LABEL: &str = "reopen conflicts";
pub const HEAD_INFO_JOB_LABEL: &str = "read HEAD";
pub const UNDO_COMMIT_JOB_LABEL: &str = "undo commit";

/// Block choices remembered for undo, per repository.
pub const MAX_CONFLICT_UNDO: usize = 50;

/// Shelf discards remembered for undo, per repository.
pub const MAX_SHELF_UNDO: usize = 20;

/// Discards remembered for undo, per repository.
pub const MAX_DISCARD_UNDO: usize = 20;

/// Repositories remembered for the "recent" list.
pub const MAX_KNOWN_REPOS: usize = 20;

/// Label of the read that finds worktrees to clean up.
pub const CLEANUP_SCAN_JOB_LABEL: &str = "find merged worktrees";

/// Label of tag pushes (branch pushes use [`PUSH_JOB_LABEL`]).
pub const PUSH_TAG_JOB_LABEL: &str = "push tag";

/// The first auto-fetch of a repository waits this long after it opened
/// (or the interval, if shorter), so opening many tabs does not stampede.
const AUTO_FETCH_FIRST_DELAY: Duration = Duration::from_secs(5);

/// Jobs that can leave the repository changed even when they fail (a
/// conflicted pull, a checkout whose stashed changes did not re-apply).
const REFRESH_ON_FAILURE: &[&str] = &[
    CHECKOUT_JOB_LABEL,
    PULL_JOB_LABEL,
    "cherry-pick",
    "abort",
    MERGE_JOB_LABEL,
    CONTINUE_JOB_LABEL,
    SKIP_JOB_LABEL,
    RESOLVE_JOB_LABEL,
    UNDO_RESOLVE_JOB_LABEL,
    REOPEN_JOB_LABEL,
    UNDO_COMMIT_JOB_LABEL,
    RESTORE_SHELF_JOB_LABEL,
    RESTORE_SHELF_FILE_JOB_LABEL,
    DISCARD_SHELF_FILE_JOB_LABEL,
    UNDO_SHELF_DISCARD_JOB_LABEL,
];

/// A graph reload waits this long after the last ref or HEAD change, so a
/// commit (which changes both) reloads once.
const GRAPH_RELOAD_DELAY: Duration = Duration::from_millis(150);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobState {
    Started,
    Progress(Progress),
    Finished(Option<GitError>),
    Cancelled,
}

/// What changed since the last [`Runtime::poll`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuntimeEvent {
    Opened {
        repo: PathBuf,
    },
    OpenFailed {
        repo: PathBuf,
        error: GitError,
    },
    Updated {
        repo: PathBuf,
        kind: RefreshKind,
    },
    RefreshFailed {
        repo: PathBuf,
        kind: RefreshKind,
        error: GitError,
    },
    /// A new graph load replaced the previous one (refs or HEAD moved).
    GraphReset {
        repo: PathBuf,
    },
    /// The history search found more matches, progressed, finished, or
    /// was replaced (a new query or a graph reload).
    SearchChanged {
        repo: PathBuf,
    },
    /// The commit selection changed (picks, or reseeding after a status).
    SelectionChanged {
        repo: PathBuf,
    },
    /// A selected diff loaded or failed.
    DiffChanged {
        repo: PathBuf,
        slot: DiffSlot,
    },
    /// The commit requested with [`Runtime::load_commit`] loaded.
    CommitLoaded {
        repo: PathBuf,
    },
    /// The worktree folder of this repository is gone; refreshes stop.
    Missing {
        repo: PathBuf,
    },
    /// The candidates requested with [`Runtime::load_cleanup`] arrived.
    CleanupLoaded {
        repo: PathBuf,
    },
    /// The files of a shelf, requested with [`Runtime::load_shelf_files`].
    ShelfLoaded {
        repo: PathBuf,
        oid: String,
    },
    ShelfReplaced {
        repo: PathBuf,
        old_oid: String,
        new_oid: Option<String>,
    },
    /// The HEAD commit's message, requested with [`Runtime::load_head_message`].
    HeadMessage {
        repo: PathBuf,
        message: String,
    },
    /// Progress of jobs other than refreshes and diff loads (graph loads, writes).
    Job {
        repo: PathBuf,
        job: JobId,
        label: String,
        state: JobState,
    },
    /// The merge preview requested with [`Runtime::load_merge_preview`].
    MergePreviewLoaded {
        repo: PathBuf,
        target: String,
    },
    /// The undo strip's commit or the commits HEAD lacks changed.
    HeadInfoChanged {
        repo: PathBuf,
    },
    /// A commit was undone; its message goes back into the commit box.
    CommitUndone {
        repo: PathBuf,
        message: String,
    },
    /// New entries in the git command log.
    CommandsLogged,
}

/// What the commit box does, after the operation in progress.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommitMode {
    Normal,
    /// Commits the merge: the index as it is, checkboxes locked.
    Merge,
    /// Commits the cherry-pick (or revert) the same way.
    CherryPick,
    /// A rebase goes on from the banner; the commit box waits.
    Rebase,
}

impl CommitMode {
    pub fn id(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::Merge => "merge",
            Self::CherryPick => "cherry_pick",
            Self::Rebase => "rebase",
        }
    }

    /// The checkboxes show the index and cannot change.
    pub fn locks_picks(self) -> bool {
        matches!(self, Self::Merge | Self::CherryPick)
    }
}

/// A conflicted file shown in the Changes view (instead of a diff).
#[derive(Debug, Clone)]
pub struct ConflictState {
    path: PathBuf,
    kind: ConflictKind,
    generation: u64,
    loading: bool,
    file: Option<ConflictFile>,
    layout: ConflictLayout,
    error: Option<GitError>,
}

impl ConflictState {
    fn new(path: PathBuf, kind: ConflictKind) -> Self {
        Self {
            path,
            kind,
            generation: 0,
            loading: false,
            file: None,
            layout: ConflictLayout::default(),
            error: None,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn kind(&self) -> ConflictKind {
        self.file.as_ref().map_or(self.kind, |f| f.kind)
    }

    pub fn is_loading(&self) -> bool {
        self.loading
    }

    pub fn file(&self) -> Option<&ConflictFile> {
        self.file.as_ref()
    }

    pub fn layout(&self) -> &ConflictLayout {
        &self.layout
    }

    pub fn error(&self) -> Option<&GitError> {
        self.error.as_ref()
    }

    fn relayout(&mut self, show_base: bool) {
        self.layout = self
            .file
            .as_ref()
            .map(|f| ConflictLayout::build(f, show_base))
            .unwrap_or_default();
    }
}

/// A block choice that can be undone: the file before and after it.
#[derive(Debug, Clone)]
struct ConflictUndo {
    path: PathBuf,
    before: Vec<u8>,
    after: Vec<u8>,
}

/// Cached state of one open repository.
pub struct RepoState {
    key: PathBuf,
    toplevel: Option<PathBuf>,
    paths: Option<RepoPaths>,
    status: Option<RepoStatus>,
    refs: Option<Vec<Ref>>,
    remotes: Option<Vec<String>>,
    remote_list: Option<Vec<Remote>>,
    worktrees: Option<Vec<Worktree>>,
    stashes: Option<Vec<StashEntry>>,
    shelves: Vec<Shelf>,
    /// Files of shelves, by commit (a shelf's content never changes).
    shelf_files: HashMap<String, Vec<ShelfFile>>,
    /// Discarded shelves `(commit, subject)`, newest last, for undo.
    dropped_shelves: Vec<ShelfChange>,
    operation: Option<Operation>,
    operation_details: Option<OperationDetails>,
    /// The conflicted file selected in the Changes view.
    conflict: Option<ConflictState>,
    conflict_show_base: bool,
    /// Files whose conflicts were resolved (resolve-undo).
    resolved: Vec<PathBuf>,
    /// Block choices, newest last, for undo.
    conflict_undo: Vec<ConflictUndo>,
    merge_preview: Option<MergePreview>,
    merge_preview_requested: Option<String>,
    head_info: HeadInfo,
    labels: HashMap<String, Vec<RefLabel>>,
    changes: ChangeList,
    change_filter: ChangeFilter,
    selection: Selection,
    /// [`Selection::line_states`] of the Changes diff, per line.
    diff_picks: Vec<PickState>,
    worktree_badges: HashMap<PathBuf, Badge>,
    diff: Option<DiffState>,
    commit: Option<CommitDetails>,
    commit_requested: Option<String>,
    commit_diff: Option<DiffState>,
    /// Backups of recent discards, newest last.
    discards: Vec<Vec<(PathBuf, String)>>,
    graph: Option<GraphLoader>,
    graph_dirty_since: Option<Instant>,
    /// The history search's query ("" for none) and its search of `graph`.
    search_query: String,
    search: Option<CommitSearch>,
    /// `(version, done)` of the search when last reported.
    search_reported: (u64, bool),
    open_error: Option<GitError>,
    /// The fetch running or queued (manual or automatic), if any.
    fetch_job: Option<JobId>,
    next_auto_fetch: Option<Instant>,
    /// The last auto-fetch failed; further failures are not reported again.
    auto_fetch_failed: bool,
    /// The worktree folder disappeared.
    missing: bool,
    cleanup: Option<Vec<CleanupCandidate>>,
}

impl RepoState {
    fn new(key: PathBuf) -> Self {
        Self {
            key,
            toplevel: None,
            paths: None,
            status: None,
            refs: None,
            remotes: None,
            remote_list: None,
            worktrees: None,
            stashes: None,
            shelves: Vec::new(),
            shelf_files: HashMap::new(),
            dropped_shelves: Vec::new(),
            operation: None,
            operation_details: None,
            conflict: None,
            conflict_show_base: false,
            resolved: Vec::new(),
            conflict_undo: Vec::new(),
            merge_preview: None,
            merge_preview_requested: None,
            head_info: HeadInfo::default(),
            labels: HashMap::new(),
            changes: ChangeList::default(),
            change_filter: ChangeFilter::default(),
            selection: Selection::default(),
            diff_picks: Vec::new(),
            worktree_badges: HashMap::new(),
            diff: None,
            commit: None,
            commit_requested: None,
            commit_diff: None,
            discards: Vec::new(),
            graph: None,
            graph_dirty_since: None,
            search_query: String::new(),
            search: None,
            search_reported: (0, false),
            open_error: None,
            fetch_job: None,
            next_auto_fetch: None,
            auto_fetch_failed: false,
            missing: false,
            cleanup: None,
        }
    }

    /// The path the repository was opened with (normalized); the key for all calls.
    pub fn key(&self) -> &Path {
        &self.key
    }

    /// Worktree root, once resolved.
    pub fn toplevel(&self) -> Option<&Path> {
        self.toplevel.as_deref()
    }

    pub fn paths(&self) -> Option<&RepoPaths> {
        self.paths.as_ref()
    }

    /// Folder name of the worktree root (or of the key until resolved); a
    /// linked worktree's is prefixed with its repository's (`repo/task`).
    pub fn display_name(&self) -> String {
        let name = |path: &Path| {
            path.file_name().map_or_else(
                || path.display().to_string(),
                |n| n.to_string_lossy().into_owned(),
            )
        };
        let own = name(self.toplevel.as_deref().unwrap_or(&self.key));
        let Some(paths) = self.paths.as_ref().filter(|p| p.git_dir != p.common_dir) else {
            return own;
        };
        // The common dir is `<repo>/.git`, or the bare repository itself.
        let common = &paths.common_dir;
        let repo = if common.file_name().is_some_and(|n| n == ".git") {
            common.parent().map(name)
        } else {
            Some(name(common))
        };
        match repo {
            Some(repo) => format!("{}/{own}", repo.strip_suffix(".git").unwrap_or(&repo)),
            None => own,
        }
    }

    /// Whether the worktree folder disappeared (see [`RuntimeEvent::Missing`]).
    pub fn is_missing(&self) -> bool {
        self.missing
    }

    /// The main worktree (or bare repository) folder, once worktrees are read.
    pub fn main_worktree(&self) -> Option<&Path> {
        self.worktrees
            .as_ref()?
            .iter()
            .find(|wt| wt.is_main)
            .map(|wt| wt.path.as_path())
    }

    /// Where new tasks start and what cleanup compares against (short ref
    /// name, such as `origin/main`).
    pub fn default_base(&self) -> Option<String> {
        default_base(self.refs.as_deref()?, self.default_remote().as_deref())
    }

    /// Worktrees the cleanup flow offers, once [`Runtime::load_cleanup`] answered.
    pub fn cleanup(&self) -> Option<&[CleanupCandidate]> {
        self.cleanup.as_deref()
    }

    pub fn is_ready(&self) -> bool {
        self.paths.is_some()
    }

    pub fn open_error(&self) -> Option<&GitError> {
        self.open_error.as_ref()
    }

    pub fn status(&self) -> Option<&RepoStatus> {
        self.status.as_ref()
    }

    pub fn refs(&self) -> Option<&[Ref]> {
        self.refs.as_deref()
    }

    pub fn worktrees(&self) -> Option<&[Worktree]> {
        self.worktrees.as_deref()
    }

    pub fn stashes(&self) -> Option<&[StashEntry]> {
        self.stashes.as_deref()
    }

    /// The stash list as shelves, newest first (PLAN §4 Shelves).
    pub fn shelves(&self) -> &[Shelf] {
        &self.shelves
    }

    /// Files of shelf `oid`, once [`Runtime::load_shelf_files`] answered.
    pub fn shelf_files(&self, oid: &str) -> Option<&[ShelfFile]> {
        self.shelf_files.get(oid).map(Vec::as_slice)
    }

    /// Whether there is a shelf discard to undo.
    pub fn can_undo_shelf_discard(&self) -> bool {
        !self.dropped_shelves.is_empty()
    }

    pub fn operation(&self) -> Option<Operation> {
        self.operation
    }

    /// The operation in progress with the banner's details.
    pub fn operation_details(&self) -> Option<&OperationDetails> {
        self.operation_details.as_ref()
    }

    pub fn commit_mode(&self) -> CommitMode {
        match self.operation {
            Some(Operation::Merge) => CommitMode::Merge,
            Some(Operation::CherryPick | Operation::Revert) => CommitMode::CherryPick,
            Some(Operation::Rebase { .. } | Operation::ApplyMailbox) => CommitMode::Rebase,
            Some(Operation::Bisect) | None => CommitMode::Normal,
        }
    }

    /// The conflicted file selected in the Changes view, if any.
    pub fn conflict(&self) -> Option<&ConflictState> {
        self.conflict.as_ref()
    }

    pub fn conflict_shows_base(&self) -> bool {
        self.conflict_show_base
    }

    /// Whether a block choice can be undone.
    pub fn can_undo_block_choice(&self) -> bool {
        !self.conflict_undo.is_empty()
    }

    fn is_unmerged(&self, path: &Path) -> bool {
        self.status.as_ref().is_some_and(|s| {
            s.changes
                .iter()
                .any(|c| c.path == path && changes::is_conflicted(c))
        })
    }

    /// Whether `path` had conflicts that are resolved now (only while an
    /// operation or other conflicts are in progress).
    pub fn is_resolved(&self, path: &Path) -> bool {
        let in_flow =
            self.operation.is_some() || self.status.as_ref().is_some_and(RepoStatus::has_conflicts);
        // A file resolved to HEAD's content is no longer a change at all.
        in_flow && self.resolved.iter().any(|p| p == path) && !self.is_unmerged(path)
    }

    /// Conflicted files left, and resolved ones.
    pub fn conflict_counts(&self) -> (usize, usize) {
        let Some(status) = &self.status else {
            return (0, 0);
        };
        let left = status
            .changes
            .iter()
            .filter(|c| changes::is_conflicted(c))
            .count();
        let resolved = self.resolved.iter().filter(|p| self.is_resolved(p)).count();
        (left, resolved)
    }

    /// The conflict kind of `path`, when it is conflicted.
    fn conflict_kind(&self, path: &Path) -> Option<ConflictKind> {
        let change = self
            .status
            .as_ref()?
            .changes
            .iter()
            .find(|c| c.path == path)?;
        match change.state {
            FileState::Unmerged(conflict) => Some(ConflictKind::from_status(conflict)),
            _ => None,
        }
    }

    /// The full name of a ref given by full or short name (local branches
    /// first, then remote branches and tags); anything else as it is.
    fn full_ref_name(&self, target: &str) -> String {
        let refs = self.refs.as_deref().unwrap_or(&[]);
        if refs.iter().any(|r| r.name == target) {
            return target.to_owned();
        }
        let rank = |r: &Ref| match r.kind {
            RefKind::Branch => 0,
            RefKind::RemoteBranch { .. } => 1,
            RefKind::Tag => 2,
            RefKind::Stash | RefKind::Other => 3,
        };
        refs.iter()
            .filter(|r| r.short_name == target && rank(r) < 3)
            .min_by_key(|r| rank(r))
            .map_or_else(|| target.to_owned(), |r| r.name.clone())
    }

    /// The short name of full ref `full` when no other ref shares it.
    fn unique_short_name(&self, full: &str) -> Option<String> {
        let refs = self.refs.as_deref()?;
        let short = &refs.iter().find(|r| r.name == full)?.short_name;
        (refs.iter().filter(|r| &r.short_name == short).count() == 1).then(|| short.clone())
    }

    /// The merge preview last loaded, once it arrived.
    pub fn merge_preview(&self) -> Option<&MergePreview> {
        self.merge_preview.as_ref()
    }

    /// The commit the undo strip offers (HEAD, unpushed, on a branch, with
    /// no operation in progress).
    pub fn undoable_commit(&self) -> Option<&UndoableCommit> {
        let commit = self.head_info.undoable.as_ref()?;
        let head = self.status.as_ref()?.oid.as_deref()?;
        (self.operation.is_none() && self.current_branch().is_some() && commit.oid == head)
            .then_some(commit)
    }

    /// Whether commit `oid` is in HEAD (unknown commits count as in it).
    pub fn in_head(&self, oid: &str) -> bool {
        !self.head_info.not_in_head.contains(oid)
    }

    /// The checkbox of `path`. While a merge or cherry-pick is committed it
    /// shows the index (a resolved file counts as included).
    pub fn pick_state(&self, path: &Path) -> PickState {
        if !self.commit_mode().locks_picks() {
            return self.selection.state(path);
        }
        if self.is_resolved(path) {
            return PickState::All;
        }
        let change = self
            .status
            .as_ref()
            .and_then(|s| s.changes.iter().find(|c| c.path == path));
        match change {
            Some(c) if c.is_staged() && c.is_unstaged() => PickState::Partial,
            Some(c) if c.is_staged() => PickState::All,
            _ => PickState::None,
        }
    }

    /// Files the next commit takes something of.
    pub fn picked_count(&self) -> usize {
        if !self.commit_mode().locks_picks() {
            return self.selection.picked_count();
        }
        self.status.as_ref().map_or(0, |s| {
            s.changes
                .iter()
                .filter(|c| {
                    c.state != FileState::Ignored && self.pick_state(&c.path) != PickState::None
                })
                .count()
        })
    }

    pub fn badge(&self) -> Badge {
        Badge::new(self.status.as_ref(), self.operation)
    }

    /// Ref labels for a commit (hex hash).
    pub fn labels(&self, commit: &str) -> &[RefLabel] {
        self.labels.get(commit).map_or(&[], Vec::as_slice)
    }

    pub fn graph(&self) -> Option<&GraphLoader> {
        self.graph.as_ref()
    }

    /// The history search of the current graph, if there is a query.
    pub fn search(&self) -> Option<&CommitSearch> {
        self.search.as_ref()
    }

    /// The history search's query, or "".
    pub fn search_query(&self) -> &str {
        &self.search_query
    }

    /// Starts the search over (new query or new graph); the next poll
    /// submits its first job and reports it.
    fn restart_search(&mut self) {
        self.search = self
            .graph
            .as_ref()
            .and_then(|graph| CommitSearch::new(&self.search_query, graph.reader()));
        self.search_reported = (u64::MAX, false);
    }

    /// The Changes view's list (indices into the status's changes), as
    /// filtered by [`Runtime::set_change_filter`].
    pub fn changes(&self) -> &ChangeList {
        &self.changes
    }

    pub fn change_filter(&self) -> &ChangeFilter {
        &self.change_filter
    }

    /// The check-all box over the files shown.
    pub fn shown_selection_state(&self) -> PickState {
        if self.commit_mode().locks_picks() {
            let paths: Vec<PathBuf> = self
                .shown_paths()
                .into_iter()
                .filter(|p| !self.is_unmerged(p))
                .collect();
            let mut states = paths.iter().map(|p| self.pick_state(p));
            let Some(first) = states.next() else {
                return PickState::None;
            };
            return if states.all(|s| s == first) {
                first
            } else {
                PickState::Partial
            };
        }
        match (&self.status, self.change_filter.is_active()) {
            (Some(status), true) => self.selection.state_of(
                self.changes
                    .indices()
                    .iter()
                    .map(|&i| status.changes[i].path.as_path()),
            ),
            _ => self.selection.overall_state(),
        }
    }

    /// Paths of the files shown.
    fn shown_paths(&self) -> Vec<PathBuf> {
        self.status.as_ref().map_or_else(Vec::new, |status| {
            self.changes
                .indices()
                .iter()
                .map(|&i| status.changes[i].path.clone())
                .collect()
        })
    }

    fn rebuild_changes(&mut self) {
        let Some(status) = &self.status else {
            return;
        };
        // Resolved files stay among the conflicts while the operation lasts.
        let in_flow = self.operation.is_some() || status.has_conflicts();
        let resolved: &[PathBuf] = if in_flow { &self.resolved } else { &[] };
        self.changes = ChangeList::grouped(status, &self.selection, &self.change_filter, resolved);
    }

    /// The commit selection (PLAN §3.10).
    pub fn selection(&self) -> &Selection {
        &self.selection
    }

    /// Per line of the Changes diff: whether it is picked (a hunk header
    /// may be partial). Empty when its lines cannot be picked.
    pub fn diff_picks(&self) -> &[PickState] {
        &self.diff_picks
    }

    /// Whether lines of the Changes diff can be picked: a loaded text diff
    /// against HEAD (or of an untracked file), not a rename or copy.
    pub fn can_pick_lines(&self) -> bool {
        let Some(state) = &self.diff else {
            return false;
        };
        let Some(diff) = &state.diff else {
            return false;
        };
        matches!(state.target.kind, DiffKind::Head | DiffKind::Untracked)
            && !self.commit_mode().locks_picks()
            && self.selection.pick(&state.target.path).is_some()
            && diff.content == DiffContent::Text
            && !diff.hunks.is_empty()
            && diff.header.renamed_from.is_none()
            && diff.header.copied_from.is_none()
    }

    /// Whether the Changes file is committed exactly as staged (staged in
    /// part outside gitbello in a way line picks cannot express).
    pub fn diff_as_staged(&self) -> bool {
        self.diff
            .as_ref()
            .is_some_and(|d| self.selection.pick(&d.target.path) == Some(&FilePick::AsStaged))
    }

    /// Badge of a worktree, by the path `git worktree list` prints.
    pub fn worktree_badge(&self, path: &Path) -> Option<&Badge> {
        self.worktree_badges.get(path)
    }

    pub fn diff(&self) -> Option<&DiffState> {
        self.diff.as_ref()
    }

    /// The commit last loaded with [`Runtime::load_commit`] (once it arrived).
    pub fn commit(&self) -> Option<&CommitDetails> {
        self.commit.as_ref()
    }

    /// The diff of a file of the loaded commit.
    pub fn commit_diff(&self) -> Option<&DiffState> {
        self.commit_diff.as_ref()
    }

    fn slot_mut(&mut self, slot: DiffSlot) -> &mut Option<DiffState> {
        match slot {
            DiffSlot::Changes => &mut self.diff,
            DiffSlot::Commit => &mut self.commit_diff,
        }
    }

    /// Whether the selected diff's lines can be used with `mode`: a loaded
    /// text diff of the matching kind (unstaged for stage and discard,
    /// staged for unstage), not a rename or copy.
    pub fn can_apply_lines(&self, mode: PatchMode) -> bool {
        let Some(state) = &self.diff else {
            return false;
        };
        let kind_ok = match mode {
            PatchMode::Stage => state.target.kind == DiffKind::Unstaged,
            PatchMode::Unstage => state.target.kind == DiffKind::Staged,
            PatchMode::Discard => {
                matches!(state.target.kind, DiffKind::Unstaged | DiffKind::Head)
            }
        };
        let Some(diff) = &state.diff else {
            return false;
        };
        kind_ok
            && diff.content == DiffContent::Text
            && !diff.hunks.is_empty()
            && diff.header.renamed_from.is_none()
            && diff.header.copied_from.is_none()
    }

    /// Whether there is a discard to undo.
    pub fn can_undo_discard(&self) -> bool {
        !self.discards.is_empty()
    }

    /// Names of the configured remotes (empty until refs are read).
    pub fn remotes(&self) -> &[String] {
        self.remotes.as_deref().unwrap_or(&[])
    }

    /// The configured remotes with their URLs (empty until refs are read).
    pub fn remote_list(&self) -> &[Remote] {
        self.remote_list.as_deref().unwrap_or(&[])
    }

    /// The checked-out branch (`None` when detached or not yet known).
    pub fn current_branch(&self) -> Option<&str> {
        match &self.status.as_ref()?.head {
            Head::Branch(name) => Some(name),
            Head::Detached | Head::Unknown => None,
        }
    }

    /// A local branch by short name.
    pub fn branch(&self, name: &str) -> Option<&Ref> {
        self.refs
            .as_ref()?
            .iter()
            .find(|r| r.kind == RefKind::Branch && r.short_name == name)
    }

    /// `(remote, branch name on the remote)` that local branch `name` tracks.
    pub fn upstream_of(&self, name: &str) -> Option<(String, String)> {
        let upstream = self.branch(name)?.upstream.as_deref()?;
        let short = upstream.strip_prefix("refs/remotes/")?;
        // Longest matching remote wins (`team/x` over `team`).
        let remote = self
            .remotes()
            .iter()
            .filter(|r| short.starts_with(r.as_str()) && short[r.len()..].starts_with('/'))
            .max_by_key(|r| r.len())?;
        Some((remote.clone(), short[remote.len() + 1..].to_owned()))
    }

    /// How to check out remote-tracking branch `remote_ref`
    /// (`refs/remotes/origin/x`): the local branch that already tracks it,
    /// else a new local branch of the same name tracking it.
    pub fn remote_checkout_target(&self, remote_ref: &str) -> Option<CheckoutTarget> {
        let refs = self.refs.as_ref()?;
        let remote = refs.iter().find(|r| r.name == remote_ref)?;
        let tracking = refs
            .iter()
            .find(|r| r.kind == RefKind::Branch && r.upstream.as_deref() == Some(remote_ref));
        if let Some(local) = tracking {
            return Some(CheckoutTarget::Branch(local.short_name.clone()));
        }
        Some(CheckoutTarget::Track {
            remote_ref: remote_ref.to_owned(),
            local: remote.remote_branch_name()?.to_owned(),
        })
    }

    /// Where pushes go: the current branch's upstream remote, else `origin`,
    /// else the first remote.
    pub fn default_remote(&self) -> Option<String> {
        if let Some((remote, _)) = self.current_branch().and_then(|b| self.upstream_of(b)) {
            return Some(remote);
        }
        let remotes = self.remotes();
        remotes
            .iter()
            .find(|r| *r == "origin")
            .or_else(|| remotes.first())
            .cloned()
    }

    pub fn can_fetch(&self) -> bool {
        self.is_ready() && !self.remotes().is_empty()
    }

    /// Whether a fetch (manual or automatic) is running or queued.
    pub fn is_fetching(&self) -> bool {
        self.fetch_job.is_some()
    }

    /// Pulling needs the current branch to track a remote branch that still
    /// exists, and no operation in progress.
    pub fn can_pull(&self) -> bool {
        self.operation.is_none()
            && self
                .current_branch()
                .and_then(|b| self.branch(b))
                .is_some_and(|r| r.upstream.is_some() && !r.tracking.gone)
    }

    /// Pushing needs a checked-out branch with commits and a remote.
    pub fn can_push(&self) -> bool {
        self.operation.is_none()
            && self.current_branch().and_then(|b| self.branch(b)).is_some()
            && self.default_remote().is_some()
    }

    /// Whether the selection can be committed (see [`Self::commit_block_reason`]).
    pub fn can_commit(&self, amend: bool) -> bool {
        self.commit_block_reason(amend).is_none()
    }

    /// Why the selection cannot be committed now, or `None`. Amending
    /// needs a commit but may take nothing new.
    pub fn commit_block_reason(&self, amend: bool) -> Option<&'static str> {
        let Some(status) = &self.status else {
            return Some("Reading the changes");
        };
        let mode = self.commit_mode();
        if mode == CommitMode::Rebase {
            return Some("Use Continue in the banner");
        }
        if status.has_conflicts() {
            return Some("Resolve conflicts first");
        }
        if mode.locks_picks() {
            return amend.then_some(if mode == CommitMode::Merge {
                "Commit the merge first"
            } else {
                "Commit the cherry-pick first"
            });
        }
        if amend {
            return status
                .oid
                .is_none()
                .then_some("There is no commit to amend");
        }
        (self.selection.picked_count() == 0).then_some("Nothing included")
    }
}

/// Which of a repository's two diffs: the changes panel's or the commit
/// details panel's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DiffSlot {
    Changes,
    Commit,
}

impl DiffSlot {
    fn label(self) -> &'static str {
        match self {
            Self::Changes => DIFF_JOB_LABEL,
            Self::Commit => COMMIT_DIFF_JOB_LABEL,
        }
    }
}

/// A selected diff and its loading state.
#[derive(Debug, Clone)]
pub struct DiffState {
    target: DiffTarget,
    /// Load even when larger than [`LARGE_DIFF_BYTES`].
    full: bool,
    generation: u64,
    loading: bool,
    diff: Option<FileDiff>,
    error: Option<GitError>,
    /// Which gaps between hunks the user opened.
    expansion: Expansion,
    /// The old side, read once a gap is opened or to learn what follows
    /// the last hunk.
    old: Option<Arc<OldFile>>,
    old_loading: bool,
    /// Blob whose read failed (or was too large): not read again.
    old_failed: Option<String>,
    /// Rows to show: the diff and the open gaps.
    layout: DiffLayout,
}

impl DiffState {
    fn new(target: DiffTarget, full: bool) -> Self {
        Self {
            target,
            full,
            generation: 0,
            loading: false,
            diff: None,
            error: None,
            expansion: Expansion::default(),
            old: None,
            old_loading: false,
            old_failed: None,
            layout: DiffLayout::default(),
        }
    }

    pub fn target(&self) -> &DiffTarget {
        &self.target
    }

    /// The rows to show (empty until the diff loaded).
    pub fn layout(&self) -> &DiffLayout {
        &self.layout
    }

    pub fn expansion(&self) -> &Expansion {
        &self.expansion
    }

    /// The old side, once read (see [`Runtime::expand_diff`]).
    pub fn old_file(&self) -> Option<&OldFile> {
        self.old.as_deref()
    }

    /// Blob id of the diff's old side, when it has one.
    fn old_oid(&self) -> Option<&str> {
        let diff = self.diff.as_ref()?;
        if diff.content != DiffContent::Text || diff.hunks.is_empty() {
            return None;
        }
        diff.header
            .old_oid
            .as_deref()
            .filter(|oid| !oid.chars().all(|c| c == '0'))
    }

    /// The old file has to be read: gaps are open, or the end of the file
    /// is unknown.
    fn needs_old_file(&self) -> bool {
        let Some(oid) = self.old_oid() else {
            return false;
        };
        (!self.expansion.is_empty() || !self.layout.end_known())
            && self.old.is_none()
            && !self.old_loading
            && self.old_failed.as_deref() != Some(oid)
    }

    /// Drops an old file of another blob, then rebuilds the layout.
    fn relayout(&mut self) {
        let stale = self
            .old
            .as_ref()
            .is_some_and(|old| self.old_oid() != Some(old.oid()));
        if stale {
            self.old = None;
        }
        self.layout = match &self.diff {
            Some(diff) => DiffLayout::build(diff, &self.expansion, self.old.as_deref()),
            None => DiffLayout::default(),
        };
    }

    pub fn is_loading(&self) -> bool {
        self.loading
    }

    /// The last loaded diff (kept while a reload runs).
    pub fn diff(&self) -> Option<&FileDiff> {
        self.diff.as_ref()
    }

    pub fn error(&self) -> Option<&GitError> {
        self.error.as_ref()
    }
}

/// Owns everything the UI needs from the core. See the module docs.
pub struct Runtime {
    // Field order is drop order: the watcher stops before the scheduler.
    watcher: Option<RepoWatcher>,
    watch_error: Option<String>,
    scheduler: Arc<JobScheduler>,
    events: Receiver<Event>,
    backend: Arc<CliBackend>,
    runner: GitRunner,
    config: Config,
    config_path: Option<PathBuf>,
    repos: HashMap<PathBuf, RepoState>,
    log_seq: u64,
    diff_generation: u64,
    auto_fetch_override: Option<Duration>,
    /// Events of synchronous calls, returned by the next poll.
    pending: Vec<RuntimeEvent>,
}

impl Runtime {
    /// Loads the config at `path`; a broken file falls back to the defaults
    /// and its error is returned alongside.
    pub fn load_config(path: Option<&Path>) -> (Config, Option<ConfigError>) {
        match path.map(Config::load) {
            None => (Config::default(), None),
            Some(Ok(config)) => (config, None),
            Some(Err(err)) => (Config::default(), Some(err)),
        }
    }

    /// Starts the runtime. Fails only when git is missing or too old.
    pub fn new(config: Config, config_path: Option<PathBuf>) -> Result<Self, GitError> {
        let runner = GitRunner::from_override(config.git_path.as_deref())?;
        Ok(Self::with_runner(config, config_path, runner))
    }

    /// Starts the runtime on an existing runner (tests pass one with a fixed
    /// identity); `config.git_path` is not consulted.
    pub fn with_runner(config: Config, config_path: Option<PathBuf>, runner: GitRunner) -> Self {
        let backend = Arc::new(CliBackend::new(runner.clone()));
        let (scheduler, events) =
            JobScheduler::new(backend.clone(), JobScheduler::default_workers());
        let scheduler = Arc::new(scheduler);
        let weak: Weak<JobScheduler> = Arc::downgrade(&scheduler);
        let (watcher, watch_error) =
            match RepoWatcher::new(backend.clone(), DEFAULT_DEBOUNCE, move |repo, set| {
                if let Some(scheduler) = weak.upgrade() {
                    scheduler.request_refresh(repo, set);
                }
            }) {
                Ok(watcher) => (Some(watcher), None),
                Err(err) => (None, Some(err.to_string())),
            };
        Self {
            watcher,
            watch_error,
            scheduler,
            events,
            backend,
            runner,
            config,
            config_path,
            repos: HashMap::new(),
            log_seq: 0,
            diff_generation: 0,
            auto_fetch_override: None,
            pending: Vec::new(),
        }
    }

    pub fn git_version(&self) -> GitVersion {
        self.runner.version()
    }

    pub fn command_log(&self) -> &CommandLog {
        self.runner.log()
    }

    /// Why file watching is unavailable, if it is (refreshes then rely on focus).
    pub fn watch_error(&self) -> Option<&str> {
        self.watch_error.as_deref()
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn config_mut(&mut self) -> &mut Config {
        &mut self.config
    }

    /// Writes the config back to where it was loaded from (no-op without a path).
    pub fn save_config(&self) -> Result<(), ConfigError> {
        match &self.config_path {
            Some(path) => self.config.save(path),
            None => Ok(()),
        }
    }

    /// Initializes a repository in the background. Open it after the job ends.
    pub fn create_repository(&mut self, path: &Path, initial_branch: &str) -> JobId {
        let path = normalize(path);
        let branch = initial_branch.to_owned();
        self.scheduler.submit(JobSpec::write(
            path,
            CREATE_REPOSITORY_JOB_LABEL,
            RefreshSet::EMPTY,
            move |ctx| {
                ctx.backend()
                    .init(ctx.repo(), &branch, ctx.cancel_token())
                    .map(|()| JobOutput::Done)
            },
        ))
    }

    /// Clones a repository in the background. Open it after the job ends.
    pub fn clone_repository(&mut self, url: &str, path: &Path) -> JobId {
        let path = normalize(path);
        let url = url.to_owned();
        self.scheduler.submit(JobSpec::write(
            path,
            CLONE_REPOSITORY_JOB_LABEL,
            RefreshSet::EMPTY,
            move |ctx| {
                let progress = Box::new(ctx.progress_sink());
                ctx.backend()
                    .clone(&url, ctx.repo(), progress, ctx.cancel_token())
                    .map(|()| JobOutput::Done)
            },
        ))
    }

    /// Opens `path` (any folder inside a worktree). Returns the key used for
    /// every other call; opening an already open repository returns its key.
    pub fn open(&mut self, path: &Path) -> PathBuf {
        let key = normalize(path);
        if self.repos.contains_key(&key) {
            return key;
        }
        self.repos.insert(key.clone(), RepoState::new(key.clone()));
        self.scheduler
            .submit(JobSpec::read(&key, OPEN_JOB_LABEL, |ctx| {
                let (repo, cancel, backend) = (ctx.repo(), ctx.cancel_token(), ctx.backend());
                let paths = backend.repo_paths(repo, cancel)?;
                let toplevel = if paths.bare {
                    repo.to_path_buf()
                } else {
                    backend.toplevel(repo, cancel)?
                };
                Ok(JobOutput::Opened { toplevel, paths })
            }));
        self.config.remember_repo(&key, MAX_KNOWN_REPOS);
        key
    }

    /// Closes a repository: cancels its jobs, stops watching, drops its state.
    pub fn close(&mut self, key: &Path) {
        self.scheduler.cancel_repo(key);
        if let Some(watcher) = &self.watcher {
            watcher.unwatch(key);
        }
        self.repos.remove(key);
    }

    pub fn refresh(&self, key: &Path, kinds: RefreshSet) {
        if self
            .repos
            .get(key)
            .is_some_and(|s| s.is_ready() && !s.missing)
        {
            self.scheduler.request_refresh(key, kinds);
        }
    }

    /// The window regained focus: refresh `key` in case file events were missed.
    pub fn on_focus(&self, key: &Path) {
        self.refresh(key, RefreshSet::on_focus());
    }

    /// Shows the diff of `target` (or nothing). A diff over the size limit
    /// loads only with `full`. The diff reloads after every status refresh.
    pub fn select_diff(&mut self, key: &Path, target: Option<DiffTarget>, full: bool) {
        if let Some(state) = self.repos.get_mut(key) {
            state.conflict = None;
        }
        self.select_slot(key, DiffSlot::Changes, target, full);
    }

    /// Loads the details of commit `oid` (a full or unique hash); they arrive
    /// as [`RuntimeEvent::CommitLoaded`]. Clears the commit file diff.
    pub fn load_commit(&mut self, key: &Path, oid: &str) {
        let Some(state) = self.repos.get_mut(key).filter(|s| s.is_ready()) else {
            return;
        };
        if state.commit_requested.as_deref() == Some(oid) {
            return;
        }
        state.commit_requested = Some(oid.to_owned());
        state.commit_diff = None;
        let oid = oid.to_owned();
        self.scheduler
            .submit(JobSpec::read(key, COMMIT_DETAILS_JOB_LABEL, move |ctx| {
                ctx.backend()
                    .commit_details(ctx.repo(), &oid, ctx.cancel_token())
                    .map(|details| JobOutput::Commit(Box::new(details)))
            }));
    }

    /// Shows the diff of `path` in the loaded commit (or nothing).
    pub fn select_commit_file(&mut self, key: &Path, path: Option<&Path>, full: bool) {
        let target = path.and_then(|path| {
            let commit = self.repos.get(key)?.commit.as_ref()?;
            let file = commit.files.iter().find(|f| f.path == path)?;
            Some(DiffTarget {
                kind: DiffKind::Commit,
                path: file.path.clone(),
                original_path: file.original_path.clone(),
                commit: Some(CommitSide {
                    oid: commit.oid.clone(),
                    parent: commit.parents.first().cloned(),
                }),
            })
        });
        self.select_slot(key, DiffSlot::Commit, target, full);
    }

    fn select_slot(&mut self, key: &Path, slot: DiffSlot, target: Option<DiffTarget>, full: bool) {
        let Some(state) = self.repos.get_mut(key) else {
            return;
        };
        let Some(target) = target else {
            *state.slot_mut(slot) = None;
            return;
        };
        let current = state.slot_mut(slot);
        let same = current.as_ref().is_some_and(|d| d.target == target);
        if same && current.as_ref().is_some_and(|d| d.full || !full) {
            return;
        }
        let keep = current.take().filter(|_| same);
        let mut next = DiffState::new(target, full);
        if let Some(keep) = keep {
            next.diff = keep.diff;
            next.expansion = keep.expansion;
            next.old = keep.old;
            next.old_failed = keep.old_failed;
            next.layout = keep.layout;
        }
        *current = Some(next);
        self.diff_generation += 1;
        submit_diff(&self.scheduler, state, slot, self.diff_generation);
    }

    /// Opens part of a gap between the hunks of a diff (see
    /// [`DiffLayout::expanders`]). The old file is read first if needed;
    /// [`RuntimeEvent::DiffChanged`] follows either way.
    pub fn expand_diff(&mut self, key: &Path, slot: DiffSlot, gap: usize, how: Expand) {
        self.change_expansion(key, slot, |e| e.expand(gap, how));
    }

    /// Shows every line of the file in a diff, or only the hunks again.
    pub fn show_whole_diff(&mut self, key: &Path, slot: DiffSlot, whole: bool) {
        self.change_expansion(key, slot, |e| e.set_whole(whole));
    }

    fn change_expansion(
        &mut self,
        key: &Path,
        slot: DiffSlot,
        change: impl FnOnce(&mut Expansion),
    ) {
        let Some(state) = self.repos.get_mut(key) else {
            return;
        };
        let Some(diff) = state.slot_mut(slot).as_mut() else {
            return;
        };
        change(&mut diff.expansion);
        if submit_old_file(&self.scheduler, state, slot) {
            return;
        }
        if let Some(diff) = state.slot_mut(slot).as_mut() {
            diff.relayout();
        }
        self.pending.push(RuntimeEvent::DiffChanged {
            repo: key.to_path_buf(),
            slot,
        });
    }

    /// Shows the Changes view's diff of `path` (see [`changes::diff_target`]),
    /// or its conflicts when it is conflicted (see [`RepoState::conflict`]).
    pub fn select_change(&mut self, key: &Path, path: &Path, full: bool) {
        let Some(state) = self.repos.get(key) else {
            return;
        };
        if let Some(kind) = state.conflict_kind(path) {
            if state.conflict.as_ref().is_some_and(|c| c.path == path) {
                return;
            }
            self.select_diff(key, None, false);
            let Some(state) = self.repos.get_mut(key) else {
                return;
            };
            state.conflict = Some(ConflictState::new(path.to_path_buf(), kind));
            self.diff_generation += 1;
            submit_conflict(&self.scheduler, state, self.diff_generation);
            return;
        }
        let target = state
            .status()
            .map(|status| changes::diff_target(status, path));
        if let Some(target) = target {
            self.select_diff(key, Some(target), full);
        }
    }

    /// Includes or excludes whole files in the commit selection.
    pub fn pick_files(&mut self, key: &Path, paths: &[PathBuf], include: bool) -> bool {
        let Some(state) = self.repos.get_mut(key) else {
            return false;
        };
        if state.commit_mode().locks_picks() {
            return false;
        }
        let changed = state.selection.pick_files(paths, include);
        self.selection_changed(key, changed)
    }

    /// Includes or excludes every file shown (every file without a filter).
    pub fn pick_all(&mut self, key: &Path, include: bool) -> bool {
        let Some(state) = self.repos.get_mut(key) else {
            return false;
        };
        if state.commit_mode().locks_picks() {
            return false;
        }
        if state.change_filter.is_active() {
            let paths = state.shown_paths();
            state.selection.pick_files(&paths, include);
        } else {
            state.selection.pick_all(include);
        }
        self.selection_changed(key, true)
    }

    /// Shows only the changed files `filter` lets through.
    pub fn set_change_filter(&mut self, key: &Path, filter: ChangeFilter) {
        if let Some(state) = self.repos.get_mut(key) {
            state.change_filter = filter;
            state.rebuild_changes();
        }
    }

    /// Picks or unpicks lines of the Changes diff (a hunk header takes its
    /// hunk). False when its lines cannot be picked.
    pub fn pick_lines(&mut self, key: &Path, lines: &[usize], include: bool) -> bool {
        let Some(state) = self
            .repos
            .get_mut(key)
            .filter(|s| s.can_pick_lines() && !s.commit_mode().locks_picks())
        else {
            return false;
        };
        let changed = match &state.diff {
            Some(DiffState {
                target,
                diff: Some(diff),
                ..
            }) => state
                .selection
                .pick_lines(&target.path, diff, lines, include),
            _ => false,
        };
        self.selection_changed(key, changed)
    }

    fn selection_changed(&mut self, key: &Path, changed: bool) -> bool {
        if changed {
            if let Some(state) = self.repos.get_mut(key) {
                refresh_diff_picks(state);
                if state.change_filter.uses_picks() {
                    state.rebuild_changes();
                }
            }
            self.pending.push(RuntimeEvent::SelectionChanged {
                repo: key.to_path_buf(),
            });
        }
        changed
    }

    /// Stages `paths` (worktree-root relative, as in status), or everything.
    pub fn stage(&self, key: &Path, paths: Option<Vec<PathBuf>>) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        Some(self.scheduler.submit(JobSpec::write(
            key,
            STAGE_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                ctx.backend()
                    .stage(&toplevel, paths.as_deref(), ctx.cancel_token())
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    /// Unstages `paths`, or everything. Staged renames take their source along.
    pub fn unstage(&self, key: &Path, paths: Option<Vec<PathBuf>>) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let status = self.repos.get(key).and_then(RepoState::status);
        let paths = match (paths, status) {
            (Some(paths), Some(status)) => Some(changes::with_rename_sources(status, &paths)),
            (paths, _) => paths,
        };
        Some(self.scheduler.submit(JobSpec::write(
            key,
            UNSTAGE_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                ctx.backend()
                    .unstage(&toplevel, paths.as_deref(), ctx.cancel_token())
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    /// Stages, unstages or discards the selected lines (indices into the
    /// selected diff; a hunk header takes its whole hunk). `None` when the
    /// diff does not allow it or no change is selected.
    pub fn apply_lines(&self, key: &Path, lines: &[usize], mode: PatchMode) -> Option<JobId> {
        let state = self.repos.get(key)?;
        if !state.can_apply_lines(mode) {
            return None;
        }
        let toplevel = self.toplevel_of(key)?;
        let diff_state = state.diff.as_ref()?;
        let diff = diff_state.diff.as_ref()?;
        let path = diff_state.target.path.clone();
        let git_path = path.to_string_lossy().replace('\\', "/");
        let patch = build_patch(diff, &git_path, lines, mode)?;
        let real = |oid: &Option<String>| {
            oid.as_ref()
                .filter(|o| !o.chars().all(|c| c == '0'))
                .cloned()
        };
        let (old, new) = (&diff.header.old_oid, &diff.header.new_oid);
        let against_head = diff_state.target.kind == DiffKind::Head;
        let guard = match mode {
            // Against HEAD only the working tree matters.
            PatchMode::Discard if against_head => PatchGuard {
                path: path.clone(),
                index_oid: None,
                worktree_oid: real(new),
            },
            PatchMode::Stage => PatchGuard {
                path: path.clone(),
                index_oid: real(old),
                worktree_oid: None,
            },
            PatchMode::Unstage => PatchGuard {
                path: path.clone(),
                index_oid: real(new),
                worktree_oid: None,
            },
            PatchMode::Discard => PatchGuard {
                path: path.clone(),
                index_oid: real(old),
                worktree_oid: real(new),
            },
        };
        let label = match mode {
            PatchMode::Stage => STAGE_JOB_LABEL,
            PatchMode::Unstage => UNSTAGE_JOB_LABEL,
            PatchMode::Discard => DISCARD_JOB_LABEL,
        };
        Some(self.scheduler.submit(JobSpec::write(
            key,
            label,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                let (backend, cancel) = (ctx.backend(), ctx.cancel_token());
                let backups = if mode == PatchMode::Discard {
                    backend.backup(&toplevel, std::slice::from_ref(&path), cancel)?
                } else {
                    Vec::new()
                };
                backend.apply_patch(&toplevel, &patch, mode, &guard, cancel)?;
                Ok(if mode == PatchMode::Discard {
                    JobOutput::Discarded(backups)
                } else {
                    JobOutput::Done
                })
            },
        )))
    }

    /// Restores `paths` to HEAD (index and working tree; untracked files
    /// are deleted, a staged rename takes its source along), after backing
    /// up their current content for [`Runtime::undo_discard`].
    pub fn discard_files(&self, key: &Path, paths: Vec<PathBuf>) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let status = self.repos.get(key)?.status()?;
        if paths.is_empty() {
            return None;
        }
        let (untracked, tracked): (Vec<PathBuf>, Vec<PathBuf>) =
            changes::with_rename_sources(status, &paths)
                .into_iter()
                .partition(|path| {
                    status
                        .changes
                        .iter()
                        .any(|c| c.path == *path && c.state == FileState::Untracked)
                });
        Some(self.scheduler.submit(JobSpec::write(
            key,
            DISCARD_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                let (backend, cancel) = (ctx.backend(), ctx.cancel_token());
                let backups = backend.backup(&toplevel, &paths, cancel)?;
                backend.discard(&toplevel, &tracked, &untracked, cancel)?;
                Ok(JobOutput::Discarded(backups))
            },
        )))
    }

    /// Writes back the files of the most recent discard.
    pub fn undo_discard(&mut self, key: &Path) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let files = self.repos.get_mut(key)?.discards.pop()?;
        Some(self.scheduler.submit(JobSpec::write(
            key,
            UNDO_DISCARD_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                ctx.backend()
                    .restore_backup(&toplevel, &files, ctx.cancel_token())
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    /// Commits the selection (or amends HEAD with it) with `message`, through
    /// a temporary index (PLAN §3.10). `None` when it cannot be committed.
    pub fn commit(&self, key: &Path, message: String, amend: bool) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get(key).filter(|s| s.can_commit(amend))?;
        if state.commit_mode().locks_picks() {
            // A merge or cherry-pick commits the index as it is.
            let operation = state.operation?;
            return Some(self.scheduler.submit(JobSpec::write(
                key,
                COMMIT_JOB_LABEL,
                RefreshSet::all(),
                move |ctx| {
                    ctx.backend()
                        .continue_operation(
                            &toplevel,
                            operation,
                            Some(&message),
                            ctx.cancel_token(),
                        )
                        .map(|()| JobOutput::Done)
                },
            )));
        }
        let plan = state.selection.plan(state.status()?);
        let refresh = RefreshSet::EMPTY
            .with(RefreshKind::Status)
            .with(RefreshKind::Refs);
        Some(
            self.scheduler
                .submit(JobSpec::write(key, COMMIT_JOB_LABEL, refresh, move |ctx| {
                    let (backend, cancel) = (ctx.backend(), ctx.cancel_token());
                    let paths = plan.paths();
                    let mut patches = Vec::with_capacity(plan.lines.len());
                    for (target, keys) in &plan.lines {
                        let diff = backend.diff(&toplevel, target, None, cancel)?;
                        let git_path = target.path.to_string_lossy().replace('\\', "/");
                        let patch = changes::lines_patch(&diff, &git_path, keys)
                            .ok_or_else(|| picks_stale(&target.path))?;
                        patches.push(patch);
                    }
                    let write = IndexWrite {
                        whole: plan.whole,
                        staged: plan.staged,
                        patches,
                        paths,
                    };
                    backend
                        .commit_selection(&toplevel, &write, &message, amend, cancel)
                        .map(|()| JobOutput::Done)
                })),
        )
    }

    /// Reads the HEAD commit's message; it arrives as [`RuntimeEvent::HeadMessage`].
    pub fn load_head_message(&self, key: &Path) -> Option<JobId> {
        self.repos.get(key).filter(|s| s.is_ready())?;
        Some(
            self.scheduler
                .submit(JobSpec::read(key, HEAD_MESSAGE_JOB_LABEL, |ctx| {
                    ctx.backend()
                        .head_message(ctx.repo(), ctx.cancel_token())
                        .map(JobOutput::HeadMessage)
                })),
        )
    }

    /// Fetches every remote (with `--prune`); refs, status and worktree
    /// badges refresh afterwards. Returns the fetch already under way, if any.
    pub fn fetch(&mut self, key: &Path) -> Option<JobId> {
        self.submit_fetch(key, FETCH_JOB_LABEL)
    }

    fn submit_fetch(&mut self, key: &Path, label: &'static str) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get_mut(key).filter(|s| s.can_fetch())?;
        if let Some(job) = state.fetch_job {
            return Some(job);
        }
        let refresh = [
            RefreshKind::Refs,
            RefreshKind::Status,
            RefreshKind::WorktreeBadges,
        ]
        .into_iter()
        .collect();
        // A read for the scheduler: it only moves remote-tracking refs, so
        // commits and staging need not wait for the network.
        let spec = JobSpec::read(key, label, move |ctx| {
            let op = SyncOp::Fetch { remote: None };
            ctx.backend()
                .sync(
                    &toplevel,
                    &op,
                    Box::new(ctx.progress_sink()),
                    ctx.cancel_token(),
                )
                .map(|()| JobOutput::Done)
        })
        .refreshing(refresh);
        let job = self.scheduler.submit(spec);
        state.fetch_job = Some(job);
        Some(job)
    }

    /// Pulls the current branch's upstream (`mode`, or the configured one).
    pub fn pull(&self, key: &Path, mode: Option<PullMode>) -> Option<JobId> {
        self.repos.get(key).filter(|s| s.can_pull())?;
        let op = SyncOp::Pull {
            mode: mode.unwrap_or(self.config.pull_mode),
        };
        self.submit_sync(key, PULL_JOB_LABEL, op, RefreshSet::all())
    }

    /// Pushes the current branch to its upstream, or (setting the upstream)
    /// to the same name on the default remote.
    pub fn push(&self, key: &Path, force_with_lease: bool) -> Option<JobId> {
        let state = self.repos.get(key).filter(|s| s.can_push())?;
        let branch = state.current_branch()?;
        let spec = match state.upstream_of(branch) {
            Some((remote, upstream)) => {
                PushSpec::branch(&remote, branch, Some(&upstream), force_with_lease)
            }
            None => PushSpec::branch(&state.default_remote()?, branch, None, force_with_lease),
        };
        let refresh = RefreshSet::EMPTY
            .with(RefreshKind::Refs)
            .with(RefreshKind::Status);
        self.submit_sync(key, PUSH_JOB_LABEL, SyncOp::Push(spec), refresh)
    }

    /// Pushes tag `name` to the default remote.
    pub fn push_tag(&self, key: &Path, name: &str) -> Option<JobId> {
        let remote = self.repos.get(key)?.default_remote()?;
        let op = SyncOp::Push(PushSpec::tag(&remote, name));
        let refresh = RefreshSet::EMPTY.with(RefreshKind::Refs);
        self.submit_sync(key, PUSH_TAG_JOB_LABEL, op, refresh)
    }

    fn submit_sync(
        &self,
        key: &Path,
        label: &str,
        op: SyncOp,
        refresh: RefreshSet,
    ) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        Some(
            self.scheduler
                .submit(JobSpec::write(key, label, refresh, move |ctx| {
                    ctx.backend()
                        .sync(
                            &toplevel,
                            &op,
                            Box::new(ctx.progress_sink()),
                            ctx.cancel_token(),
                        )
                        .map(|()| JobOutput::Done)
                })),
        )
    }

    /// Checks out `target`, doing `changes` with local changes: keep them,
    /// bring them along (stash, switch, re-apply) or leave them on the
    /// current branch as an automatic shelf (PLAN §4 Shelves).
    pub fn checkout(
        &self,
        key: &Path,
        target: CheckoutTarget,
        changes: CheckoutChanges,
    ) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let branch = self
            .repos
            .get(key)
            .and_then(RepoState::current_branch)
            .unwrap_or("HEAD")
            .to_owned();
        Some(self.scheduler.submit(JobSpec::write(
            key,
            CHECKOUT_JOB_LABEL,
            RefreshSet::all(),
            move |ctx| {
                let (backend, cancel) = (ctx.backend(), ctx.cancel_token());
                checkout_job(backend, &toplevel, &target, changes, &branch, cancel)
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    /// Shelves `paths` (all changes when empty) on the current branch as
    /// `name`. Label [`SHELVE_JOB_LABEL`].
    pub fn shelve(&self, key: &Path, paths: Vec<PathBuf>, name: &str) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let branch = self.repos.get(key)?.current_branch().unwrap_or("HEAD");
        let message = shelf_message(branch, name, false);
        Some(self.scheduler.submit(JobSpec::write(
            key,
            SHELVE_JOB_LABEL,
            shelf_refresh(),
            move |ctx| {
                let shelved =
                    ctx.backend()
                        .shelve(&toplevel, &paths, &message, ctx.cancel_token())?;
                match shelved {
                    Some(_) => Ok(JobOutput::Done),
                    None => Err(GitError::new(
                        "stash push",
                        GitErrorKind::Other,
                        "there was nothing to shelve",
                    )),
                }
            },
        )))
    }

    /// Applies shelf `oid` and drops it on success. Label [`RESTORE_SHELF_JOB_LABEL`].
    pub fn restore_shelf(&self, key: &Path, oid: &str) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let oid = oid.to_owned();
        Some(self.scheduler.submit(JobSpec::write(
            key,
            RESTORE_SHELF_JOB_LABEL,
            shelf_refresh(),
            move |ctx| {
                ctx.backend()
                    .restore_shelf(&toplevel, &oid, ctx.cancel_token())
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    /// Renames shelf `oid` (it keeps its commit and branch).
    pub fn rename_shelf(&self, key: &Path, oid: &str, name: &str) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let shelf = self.repos.get(key)?.shelves.iter().find(|s| s.oid == oid)?;
        let branch = shelf.branch.clone().unwrap_or_else(|| "HEAD".to_owned());
        let message = shelf_message(&branch, name, shelf.auto);
        let oid = oid.to_owned();
        Some(self.scheduler.submit(JobSpec::write(
            key,
            RENAME_SHELF_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Stashes),
            move |ctx| {
                ctx.backend()
                    .rename_shelf(&toplevel, &oid, &message, ctx.cancel_token())
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    pub fn restore_shelf_file(&self, key: &Path, oid: &str, path: &Path) -> Option<JobId> {
        self.edit_shelf_file(key, oid, path, true)
    }

    pub fn discard_shelf_file(&self, key: &Path, oid: &str, path: &Path) -> Option<JobId> {
        self.edit_shelf_file(key, oid, path, false)
    }

    fn edit_shelf_file(&self, key: &Path, oid: &str, path: &Path, restore: bool) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let (oid, path) = (oid.to_owned(), path.to_owned());
        let label = if restore {
            RESTORE_SHELF_FILE_JOB_LABEL
        } else {
            DISCARD_SHELF_FILE_JOB_LABEL
        };
        Some(
            self.scheduler
                .submit(JobSpec::write(key, label, shelf_refresh(), move |ctx| {
                    let change = if restore {
                        ctx.backend().restore_shelf_file(
                            &toplevel,
                            &oid,
                            &path,
                            ctx.cancel_token(),
                        )?
                    } else {
                        ctx.backend().discard_shelf_file(
                            &toplevel,
                            &oid,
                            &path,
                            ctx.cancel_token(),
                        )?
                    };
                    Ok(JobOutput::ShelfChanged {
                        change,
                        remember: !restore,
                    })
                })),
        )
    }

    /// Drops shelf `oid`; [`Runtime::undo_shelf_discard`] stores it again.
    pub fn discard_shelf(&self, key: &Path, oid: &str) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let shelf = self.repos.get(key)?.shelves.iter().find(|s| s.oid == oid)?;
        let (oid, subject) = (shelf.oid.clone(), shelf.subject.clone());
        Some(self.scheduler.submit(JobSpec::write(
            key,
            DISCARD_SHELF_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Stashes),
            move |ctx| {
                ctx.backend()
                    .drop_shelf(&toplevel, &oid, ctx.cancel_token())
                    .map(|()| JobOutput::ShelfDropped { oid, subject })
            },
        )))
    }

    /// Stores the most recently discarded shelf again.
    pub fn undo_shelf_discard(&mut self, key: &Path) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        // Keep a failed/stale Undo available; only remove it after success.
        let change = self.repos.get(key)?.dropped_shelves.last()?.clone();
        Some(self.scheduler.submit(JobSpec::write(
            key,
            UNDO_SHELF_DISCARD_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Stashes),
            move |ctx| {
                ctx.backend()
                    .undo_shelf_change(&toplevel, &change, ctx.cancel_token())
                    .map(|()| JobOutput::ShelfUndone(change))
            },
        )))
    }

    /// Reads the files of shelf `oid`; they arrive as [`RuntimeEvent::ShelfLoaded`].
    pub fn load_shelf_files(&self, key: &Path, oid: &str) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let oid = oid.to_owned();
        Some(
            self.scheduler
                .submit(JobSpec::read(key, SHELF_FILES_JOB_LABEL, move |ctx| {
                    let files = ctx
                        .backend()
                        .shelf_files(&toplevel, &oid, ctx.cancel_token())?;
                    Ok(JobOutput::ShelfFiles(oid, files))
                })),
        )
    }

    /// Shows the diff of `path` in shelf `oid` in the Changes view (needs
    /// its files loaded): tracked files against the shelf's base, untracked
    /// ones in full. Lines cannot be picked.
    pub fn select_shelf_file(&mut self, key: &Path, oid: &str, path: &Path, full: bool) {
        let target = self.repos.get(key).and_then(|s| {
            let file = s.shelf_files(oid)?.iter().find(|f| f.path == path)?;
            let commit = if file.untracked {
                CommitSide {
                    oid: format!("{oid}^3"),
                    parent: None,
                }
            } else {
                CommitSide {
                    oid: if file.index_only {
                        format!("{oid}^2")
                    } else {
                        oid.to_owned()
                    },
                    parent: Some(format!("{oid}^1")),
                }
            };
            Some(DiffTarget {
                kind: DiffKind::Commit,
                path: file.path.clone(),
                original_path: file.original_path.clone(),
                commit: Some(commit),
            })
        });
        if target.is_some() {
            self.select_diff(key, target, full);
        }
    }

    /// Runs a branch, tag, cherry-pick or abort operation (job label
    /// [`RefOp::label`]). Checkouts go through [`Runtime::checkout`].
    pub fn ref_op(&self, key: &Path, op: RefOp) -> Option<JobId> {
        let refresh = match &op {
            RefOp::Checkout(target) => {
                return self.checkout(key, target.clone(), CheckoutChanges::Keep)
            }
            RefOp::CreateBranch {
                checkout: false, ..
            }
            | RefOp::DeleteBranch { .. }
            | RefOp::CreateTag { .. }
            | RefOp::DeleteTag { .. }
            | RefOp::AddRemote { .. }
            | RefOp::SetRemoteUrl { .. } => RefreshSet::EMPTY.with(RefreshKind::Refs),
            // Upstreams of local branches name the remote.
            RefOp::RenameRemote { .. } | RefOp::RemoveRemote { .. } => RefreshSet::EMPTY
                .with(RefreshKind::Refs)
                .with(RefreshKind::Status),
            RefOp::SetUpstream { .. } => RefreshSet::EMPTY
                .with(RefreshKind::Refs)
                .with(RefreshKind::Status),
            RefOp::CreateBranch { checkout: true, .. }
            | RefOp::RenameBranch { .. }
            | RefOp::CherryPick { .. }
            | RefOp::Abort(_) => RefreshSet::all(),
        };
        let toplevel = self.toplevel_of(key)?;
        let label = op.label();
        Some(
            self.scheduler
                .submit(JobSpec::write(key, label, refresh, move |ctx| {
                    ctx.backend()
                        .ref_op(&toplevel, &op, ctx.cancel_token())
                        .map(|()| JobOutput::Done)
                })),
        )
    }

    /// Works out what merging `target` (a branch, remote branch, tag or
    /// commit) into HEAD would do; it arrives as
    /// [`RuntimeEvent::MergePreviewLoaded`] with the overlap with local
    /// changes filled in.
    pub fn load_merge_preview(&mut self, key: &Path, target: &str) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get_mut(key)?;
        let full = state.full_ref_name(target);
        let branch = state.current_branch().map(str::to_owned);
        state.merge_preview = None;
        state.merge_preview_requested = Some(target.to_owned());
        let target = target.to_owned();
        Some(
            self.scheduler
                .submit(JobSpec::read(key, MERGE_PREVIEW_JOB_LABEL, move |ctx| {
                    let mut preview = ctx.backend().merge_preview(
                        &toplevel,
                        &full,
                        branch.as_deref(),
                        ctx.cancel_token(),
                    )?;
                    preview.target = target;
                    Ok(JobOutput::MergePreview(Box::new(preview)))
                })),
        )
    }

    /// Merges `target` into HEAD as `mode` says, with `message` (git's
    /// default when empty). With `shelve`, local changes are left as an
    /// automatic shelf first and restored after a clean merge (a
    /// conflicting merge keeps the shelf). Label [`MERGE_JOB_LABEL`].
    pub fn merge(
        &self,
        key: &Path,
        target: &str,
        mode: MergeMode,
        message: Option<String>,
        shelve: bool,
    ) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get(key).filter(|s| s.operation.is_none())?;
        let full = state.full_ref_name(target);
        let branch = state.current_branch().unwrap_or("HEAD");
        let shelf = shelf_message(branch, &format!("Left when merging {target}"), true);
        // git labels the conflict markers with the name it is given.
        let name = state
            .unique_short_name(&full)
            .unwrap_or_else(|| full.clone());
        // git would name the full ref; say it as git does for a short name.
        let message = message
            .filter(|m| !m.trim().is_empty())
            .unwrap_or_else(|| merge::default_merge_message(&full, state.current_branch()));
        let message = Some(message);
        Some(self.scheduler.submit(JobSpec::write(
            key,
            MERGE_JOB_LABEL,
            RefreshSet::all(),
            move |ctx| {
                let (backend, cancel) = (ctx.backend(), ctx.cancel_token());
                let stashed = if shelve {
                    backend.stash_push(&toplevel, &shelf, cancel)?
                } else {
                    None
                };
                let merged = backend.merge(&toplevel, &name, mode, message.as_deref(), cancel);
                // Putting the changes back must not be cut short by a cancel.
                let restore = CancelToken::new();
                match (&merged, &stashed) {
                    // A conflicting merge keeps the shelf until it is finished.
                    (Err(err), Some(_)) if err.kind == GitErrorKind::Conflict => {}
                    (_, Some(oid)) => backend.restore_shelf(&toplevel, oid, &restore)?,
                    (_, None) => {}
                }
                merged.map(|()| JobOutput::Done)
            },
        )))
    }

    /// Finishes the operation in progress after its conflicts were resolved:
    /// commits a merge or cherry-pick with `message` (git's when `None`),
    /// or continues a rebase. Label [`CONTINUE_JOB_LABEL`].
    pub fn continue_operation(&self, key: &Path, message: Option<String>) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get(key)?;
        let operation = state.operation?;
        if state.status().is_some_and(RepoStatus::has_conflicts) {
            return None;
        }
        Some(self.scheduler.submit(JobSpec::write(
            key,
            CONTINUE_JOB_LABEL,
            RefreshSet::all(),
            move |ctx| {
                ctx.backend()
                    .continue_operation(
                        &toplevel,
                        operation,
                        message.as_deref(),
                        ctx.cancel_token(),
                    )
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    /// Skips the commit a rebase stopped at. Label [`SKIP_JOB_LABEL`].
    pub fn skip_operation(&self, key: &Path) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let operation = self.repos.get(key)?.operation?;
        Some(self.scheduler.submit(JobSpec::write(
            key,
            SKIP_JOB_LABEL,
            RefreshSet::all(),
            move |ctx| {
                ctx.backend()
                    .skip_operation(&toplevel, operation, ctx.cancel_token())
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    /// Resolves conflict block `block` of the selected conflicted file
    /// `path` with `choice`. The file is staged once no block is left.
    pub fn resolve_block(
        &mut self,
        key: &Path,
        path: &Path,
        block: usize,
        choice: BlockChoice,
    ) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get_mut(key)?;
        let show_base = state.conflict_show_base;
        let conflict = state.conflict.as_mut().filter(|c| c.path == path)?;
        let file = conflict.file.as_ref()?;
        let (kind, sizes) = (file.kind, (file.ours_size, file.theirs_size));
        let before = file.content.clone();
        let after = merge::resolve_block(&before, block, choice)?;
        let stage = merge::parse_blocks(&merge::split_lines(&after)).is_empty();
        // Show the result at once; the reload after the write confirms it.
        let mut next = ConflictFile::new(path.to_path_buf(), kind, Some(after.clone()));
        (next.ours_size, next.theirs_size) = sizes;
        conflict.file = Some(next);
        conflict.relayout(show_base);
        self.pending.push(RuntimeEvent::DiffChanged {
            repo: key.to_path_buf(),
            slot: DiffSlot::Changes,
        });
        let path = path.to_path_buf();
        let op = ConflictOp::Write {
            path: path.clone(),
            expected: before.clone(),
            content: after.clone(),
            stage,
        };
        Some(self.scheduler.submit(JobSpec::write(
            key,
            RESOLVE_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                ctx.backend()
                    .conflict_op(&toplevel, &op, ctx.cancel_token())?;
                Ok(JobOutput::ConflictWritten(Box::new((
                    path, before, after, stage,
                ))))
            },
        )))
    }

    /// Undoes the last block choice (bringing the conflict back when the
    /// choice had resolved the file). Label [`UNDO_RESOLVE_JOB_LABEL`].
    pub fn undo_block_choice(&mut self, key: &Path) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get_mut(key)?;
        let undo = state.conflict_undo.pop()?;
        let reopen = !state.is_unmerged(&undo.path);
        let shown = state.conflict.as_ref().map(|c| c.path.as_path()) == Some(&undo.path)
            || state.diff.as_ref().map(|d| d.target.path.as_path()) == Some(&undo.path);
        if shown && reopen {
            // Keep showing the file: as its conflicts once they are back.
            state.diff = None;
            state.conflict = Some(ConflictState::new(undo.path.clone(), ConflictKind::Content));
        }
        let op = ConflictOp::Restore {
            path: undo.path,
            expected: undo.after,
            content: undo.before,
            reopen,
        };
        Some(self.scheduler.submit(JobSpec::write(
            key,
            UNDO_RESOLVE_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                ctx.backend()
                    .conflict_op(&toplevel, &op, ctx.cancel_token())
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    /// Resolves conflicted file `path` whole: our or their version, keeping
    /// the file (the side that has it) or deleting it.
    pub fn resolve_file(&self, key: &Path, path: &Path, choice: FileChoice) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let kind = self.repos.get(key)?.conflict_kind(path)?;
        let path = path.to_path_buf();
        let remove = ConflictOp::Remove { path: path.clone() };
        let side = |ours: bool| ConflictOp::TakeSide {
            path: path.clone(),
            ours,
        };
        let op = match (choice, kind) {
            (FileChoice::Delete, _) | (_, ConflictKind::BothDeleted) => remove,
            (
                FileChoice::Ours,
                ConflictKind::ModifyDelete {
                    deleted_by_us: true,
                },
            )
            | (FileChoice::Ours, ConflictKind::AddedByOne { by_us: false })
            | (
                FileChoice::Theirs,
                ConflictKind::ModifyDelete {
                    deleted_by_us: false,
                },
            )
            | (FileChoice::Theirs, ConflictKind::AddedByOne { by_us: true }) => remove,
            (FileChoice::Ours, _) => side(true),
            (FileChoice::Theirs, _) => side(false),
            (FileChoice::Keep, ConflictKind::ModifyDelete { deleted_by_us }) => {
                side(!deleted_by_us)
            }
            (FileChoice::Keep, ConflictKind::AddedByOne { by_us }) => side(by_us),
            (FileChoice::Keep, _) => return None,
        };
        Some(self.scheduler.submit(JobSpec::write(
            key,
            RESOLVE_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                ctx.backend()
                    .conflict_op(&toplevel, &op, ctx.cancel_token())
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    /// Brings the conflicts of `path` back (after it was resolved), or with
    /// `base`, recreates them with the base in the markers. Label
    /// [`REOPEN_JOB_LABEL`].
    pub fn reopen_conflicts(&mut self, key: &Path, path: &Path, base: bool) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get_mut(key)?;
        if base {
            state.conflict_show_base = true;
        }
        state.conflict_undo.retain(|u| u.path != path);
        let op = ConflictOp::Reopen {
            path: path.to_path_buf(),
            base,
        };
        Some(self.scheduler.submit(JobSpec::write(
            key,
            REOPEN_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                ctx.backend()
                    .conflict_op(&toplevel, &op, ctx.cancel_token())
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    /// Shows the base of each conflict block in the resolver, or hides it.
    pub fn show_conflict_base(&mut self, key: &Path, show: bool) {
        let Some(state) = self.repos.get_mut(key) else {
            return;
        };
        state.conflict_show_base = show;
        if let Some(conflict) = state.conflict.as_mut() {
            conflict.relayout(show);
            self.pending.push(RuntimeEvent::DiffChanged {
                repo: key.to_path_buf(),
                slot: DiffSlot::Changes,
            });
        }
    }

    /// Undoes HEAD commit `oid` (see [`UndoMode`]); its message arrives as
    /// [`RuntimeEvent::CommitUndone`] (empty after removing a merge). Label [`UNDO_COMMIT_JOB_LABEL`].
    pub fn undo_commit(&self, key: &Path, oid: &str, mode: UndoMode) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        self.repos.get(key)?.undoable_commit()?;
        let oid = oid.to_owned();
        Some(self.scheduler.submit(JobSpec::write(
            key,
            UNDO_COMMIT_JOB_LABEL,
            RefreshSet::all(),
            move |ctx| {
                let message =
                    ctx.backend()
                        .undo_commit(&toplevel, &oid, mode, ctx.cancel_token())?;
                // A removed merge leaves nothing to commit again.
                Ok(JobOutput::CommitUndone(match mode {
                    UndoMode::KeepChanges => message,
                    UndoMode::RemoveMerge => String::new(),
                }))
            },
        )))
    }

    /// Adds, removes, locks, unlocks or prunes worktrees (job label
    /// [`WorktreeOp::label`]).
    pub fn worktree_op(&self, key: &Path, op: WorktreeOp) -> Option<JobId> {
        self.repos.get(key).filter(|s| s.is_ready())?;
        Some(self.scheduler.submit(JobSpec::write(
            key,
            op.label(),
            worktree_refresh(),
            move |ctx| {
                ctx.backend()
                    .worktree_op(ctx.repo(), &op, ctx.cancel_token())
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    /// The new-task flow (PLAN §4) as one job: fetch the base's remote, then
    /// create the branch in a new worktree. A failure rolls back what was
    /// created. The caller opens the worktree afterwards.
    pub fn new_task(&self, key: &Path, task: NewTask) -> Option<JobId> {
        self.repos.get(key).filter(|s| s.is_ready())?;
        Some(self.scheduler.submit(JobSpec::write(
            key,
            NEW_TASK_JOB_LABEL,
            worktree_refresh(),
            move |ctx| {
                let progress = Box::new(ctx.progress_sink());
                new_task_job(
                    ctx.backend(),
                    ctx.repo(),
                    &task,
                    progress,
                    ctx.cancel_token(),
                )
                .map(|()| JobOutput::Done)
            },
        )))
    }

    /// Finds the worktrees whose branch is merged into the default base or
    /// whose upstream is gone; they arrive as [`RuntimeEvent::CleanupLoaded`].
    pub fn load_cleanup(&mut self, key: &Path) -> Option<JobId> {
        let state = self.repos.get_mut(key).filter(|s| s.is_ready())?;
        let base = state.default_base()?;
        let current = state.toplevel.clone()?;
        let badges = state.worktree_badges.clone();
        state.cleanup = None;
        Some(
            self.scheduler
                .submit(JobSpec::read(key, CLEANUP_SCAN_JOB_LABEL, move |ctx| {
                    let (backend, repo, cancel) = (ctx.backend(), ctx.repo(), ctx.cancel_token());
                    let worktrees = backend.worktrees(repo, cancel)?;
                    let refs = backend.refs(repo, cancel)?;
                    let merged = backend.merged_branches(repo, &base, cancel)?;
                    Ok(JobOutput::Cleanup(cleanup_candidates(
                        &worktrees, &refs, &merged, &base, &badges, &current,
                    )))
                })),
        )
    }

    /// Removes worktrees (`(path, branch, force)`; force discards local
    /// changes) and, with `delete_branches`, their branches. Goes on past a
    /// failure and reports the first one.
    pub fn cleanup(
        &self,
        key: &Path,
        items: Vec<(PathBuf, String, bool)>,
        delete_branches: bool,
    ) -> Option<JobId> {
        self.repos.get(key).filter(|s| s.is_ready())?;
        Some(self.scheduler.submit(JobSpec::write(
            key,
            CLEANUP_JOB_LABEL,
            worktree_refresh(),
            move |ctx| {
                let (backend, repo, cancel) = (ctx.backend(), ctx.repo(), ctx.cancel_token());
                let mut first_error = None;
                for (path, branch, force) in items {
                    let remove = WorktreeOp::Remove { path, force };
                    let mut result = backend.worktree_op(repo, &remove, cancel);
                    if result.is_ok() && delete_branches {
                        let delete = RefOp::DeleteBranch {
                            name: branch,
                            force: true,
                        };
                        result = backend.ref_op(repo, &delete, cancel);
                    }
                    if let Err(err) = result {
                        first_error.get_or_insert(err);
                    }
                }
                first_error.map_or(Ok(JobOutput::Done), Err)
            },
        )))
    }

    /// Cancels a queued or running job (a fetch, pull or push, say).
    pub fn cancel_job(&self, job: JobId) -> bool {
        self.scheduler.cancel(job)
    }

    /// Overrides the configured auto-fetch interval (tests use short ones);
    /// `None` goes back to `auto_fetch_minutes`.
    pub fn set_auto_fetch_interval(&mut self, interval: Option<Duration>) {
        self.auto_fetch_override = interval;
    }

    fn auto_fetch_interval(&self) -> Option<Duration> {
        self.auto_fetch_override.or_else(|| {
            let minutes = self.config.auto_fetch_minutes;
            (minutes > 0).then(|| Duration::from_secs(60 * u64::from(minutes)))
        })
    }

    /// Starts the next due auto-fetch (PLAN §3.6): one repository at a
    /// time, never while a write to it is queued or running.
    fn run_auto_fetch(&mut self) {
        let Some(interval) = self.auto_fetch_interval() else {
            return;
        };
        if self.repos.values().any(RepoState::is_fetching) {
            return;
        }
        let now = Instant::now();
        let due = self.repos.values_mut().find_map(|state| {
            if !state.can_fetch() {
                return None;
            }
            let first = now + interval.min(AUTO_FETCH_FIRST_DELAY);
            let next = *state.next_auto_fetch.get_or_insert(first);
            (next <= now).then(|| state.key.clone())
        });
        let Some(key) = due else {
            return;
        };
        if self.scheduler.has_write(&key) {
            return;
        }
        self.submit_fetch(&key, AUTO_FETCH_JOB_LABEL);
    }

    fn toplevel_of(&self, key: &Path) -> Option<PathBuf> {
        let state = self.repos.get(key).filter(|s| s.is_ready())?;
        state.toplevel.clone()
    }

    /// Jobs queued or running, for tests and diagnostics.
    pub fn pending_jobs(&self) -> usize {
        self.scheduler.pending()
    }

    pub fn repo(&self, key: &Path) -> Option<&RepoState> {
        self.repos.get(key)
    }

    pub fn repos(&self) -> impl Iterator<Item = &RepoState> {
        self.repos.values()
    }

    /// Finds the loaded commits matching `query` (subject, author, hash
    /// prefix; see [`crate::graph::CommitMatcher`]) in the background;
    /// `SearchChanged` reports progress. A blank query ends the search. The
    /// search follows the graph as it loads and reruns when it reloads.
    pub fn search_commits(&mut self, key: &Path, query: &str) {
        if let Some(state) = self.repos.get_mut(key) {
            state.search_query = query.to_owned();
            state.restart_search();
        }
    }

    /// Applies finished jobs and returns what changed. Call once per frame.
    pub fn poll(&mut self) -> Vec<RuntimeEvent> {
        let mut out = std::mem::take(&mut self.pending);
        while let Ok(event) = self.events.try_recv() {
            self.apply(event, &mut out);
        }
        self.reload_dirty_graphs(&mut out);
        self.advance_searches(&mut out);
        self.run_auto_fetch();
        let latest = self.runner.log().latest_seq();
        if latest != self.log_seq {
            self.log_seq = latest;
            out.push(RuntimeEvent::CommandsLogged);
        }
        out
    }

    fn apply(&mut self, event: Event, out: &mut Vec<RuntimeEvent>) {
        let Event {
            job,
            repo,
            label,
            kind,
        } = event;
        if [CREATE_REPOSITORY_JOB_LABEL, CLONE_REPOSITORY_JOB_LABEL].contains(&label.as_str()) {
            let state = match kind {
                EventKind::Started => JobState::Started,
                EventKind::Progress(progress) => JobState::Progress(progress),
                EventKind::Finished(result) => JobState::Finished(result.err()),
                EventKind::Cancelled => JobState::Cancelled,
            };
            out.push(RuntimeEvent::Job {
                repo,
                job,
                label,
                state,
            });
            return;
        }
        let auto_fetch_interval = self.auto_fetch_interval();
        let Some(state) = self.repos.get_mut(&repo) else {
            return; // closed meanwhile
        };
        // Searches report through `SearchChanged`, not as jobs.
        if label == SEARCH_JOB_LABEL {
            return;
        }
        if label == OPEN_JOB_LABEL {
            match kind {
                EventKind::Finished(Ok(JobOutput::Opened { toplevel, paths })) => {
                    if let Some(watcher) = &self.watcher {
                        let target = WatchTarget::new(&repo, &toplevel, &paths);
                        if let Err(err) = watcher.watch(&target) {
                            self.watch_error = Some(err.to_string());
                        }
                    }
                    state.toplevel = Some(toplevel);
                    state.paths = Some(paths);
                    self.scheduler.request_refresh(&repo, RefreshSet::all());
                    submit_head_info(&self.scheduler, &repo);
                    state.graph = Some(
                        GraphLoader::submit(&self.scheduler, self.runner.clone(), repo.clone()).0,
                    );
                    state.restart_search();
                    out.push(RuntimeEvent::Opened { repo });
                }
                EventKind::Finished(Err(error)) => {
                    state.open_error = Some(error.clone());
                    out.push(RuntimeEvent::OpenFailed { repo, error });
                }
                EventKind::Finished(Ok(_)) | EventKind::Started | EventKind::Progress(_) => {}
                EventKind::Cancelled => {}
            }
            return;
        }
        if label == DIFF_JOB_LABEL {
            apply_diff(state, DiffSlot::Changes, kind, &repo, out);
            refresh_diff_picks(state);
            submit_old_file(&self.scheduler, state, DiffSlot::Changes);
            return;
        }
        if label == COMMIT_DIFF_JOB_LABEL {
            apply_diff(state, DiffSlot::Commit, kind, &repo, out);
            submit_old_file(&self.scheduler, state, DiffSlot::Commit);
            return;
        }
        if label == OLD_FILE_JOB_LABEL {
            if let EventKind::Finished(result) = kind {
                apply_old_file(state, result.ok(), &repo, out);
            }
            return;
        }
        if label == COMMIT_DETAILS_JOB_LABEL {
            match kind {
                EventKind::Finished(Ok(JobOutput::Commit(details)))
                    if state.commit_requested.as_deref() == Some(details.oid.as_str())
                        || state
                            .commit_requested
                            .as_deref()
                            .is_some_and(|r| details.oid.starts_with(r)) =>
                {
                    state.commit = Some(*details);
                    out.push(RuntimeEvent::CommitLoaded { repo });
                }
                EventKind::Finished(Err(error)) if error.kind != GitErrorKind::Cancelled => {
                    out.push(RuntimeEvent::Job {
                        repo,
                        job,
                        label,
                        state: JobState::Finished(Some(error)),
                    });
                }
                _ => {}
            }
            return;
        }
        if label == CLEANUP_SCAN_JOB_LABEL {
            if let EventKind::Finished(Ok(JobOutput::Cleanup(list))) = kind {
                state.cleanup = Some(list);
                out.push(RuntimeEvent::CleanupLoaded { repo });
                return;
            }
        }
        if label == SHELF_FILES_JOB_LABEL {
            if let EventKind::Finished(Ok(JobOutput::ShelfFiles(oid, files))) = kind {
                state.shelf_files.insert(oid.clone(), files);
                out.push(RuntimeEvent::ShelfLoaded { repo, oid });
                return;
            }
        }
        if label == CONFLICT_JOB_LABEL {
            apply_conflict(&self.scheduler, state, kind, &repo, out);
            return;
        }
        if label == CONFLICT_SCAN_JOB_LABEL {
            if let EventKind::Finished(Ok(JobOutput::ConflictScan { resolved, unmarked })) = kind {
                let changed = state.resolved != resolved;
                state.resolved = resolved;
                if changed {
                    state.rebuild_changes();
                }
                let unmarked: Vec<PathBuf> = unmarked
                    .into_iter()
                    .filter(|p| state.is_unmerged(p))
                    .collect();
                submit_mark_resolved(&self.scheduler, state, unmarked);
                if changed {
                    out.push(RuntimeEvent::SelectionChanged { repo });
                }
            }
            return;
        }
        if label == HEAD_INFO_JOB_LABEL {
            if let EventKind::Finished(Ok(JobOutput::HeadInfo(info))) = kind {
                state.head_info = *info;
                out.push(RuntimeEvent::HeadInfoChanged { repo });
            }
            return;
        }
        if label == MERGE_PREVIEW_JOB_LABEL {
            if let EventKind::Finished(Ok(JobOutput::MergePreview(mut preview))) = kind {
                if state.merge_preview_requested.as_deref() != Some(preview.target.as_str()) {
                    return;
                }
                if let Some(status) = &state.status {
                    preview.overlap = status
                        .changes
                        .iter()
                        .filter(|c| {
                            c.state != FileState::Ignored && preview.files.contains(&c.path)
                        })
                        .map(|c| c.path.clone())
                        .collect();
                }
                let target = preview.target.clone();
                state.merge_preview = Some(*preview);
                out.push(RuntimeEvent::MergePreviewLoaded { repo, target });
                return;
            }
        }
        if let EventKind::Finished(Ok(JobOutput::ConflictWritten(written))) = &kind {
            let (path, before, after, _) = written.as_ref();
            state.conflict_undo.push(ConflictUndo {
                path: path.clone(),
                before: before.clone(),
                after: after.clone(),
            });
            let excess = state.conflict_undo.len().saturating_sub(MAX_CONFLICT_UNDO);
            state.conflict_undo.drain(..excess);
        }
        if let EventKind::Finished(Ok(JobOutput::CommitUndone(message))) = &kind {
            out.push(RuntimeEvent::CommitUndone {
                repo: repo.clone(),
                message: message.clone(),
            });
        }
        if label == HEAD_MESSAGE_JOB_LABEL {
            if let EventKind::Finished(Ok(JobOutput::HeadMessage(message))) = kind {
                out.push(RuntimeEvent::HeadMessage { repo, message });
                return;
            }
        }
        if let Some(refresh) = RefreshKind::from_label(&label) {
            match kind {
                EventKind::Finished(Ok(output)) => {
                    apply_refresh(state, output);
                    if refresh == RefreshKind::Status {
                        out.push(RuntimeEvent::SelectionChanged { repo: repo.clone() });
                    }
                    // Staging, edits and commits all show up as a status change.
                    if refresh == RefreshKind::Status && state.diff.is_some() {
                        self.diff_generation += 1;
                        submit_diff(
                            &self.scheduler,
                            state,
                            DiffSlot::Changes,
                            self.diff_generation,
                        );
                    }
                    if refresh == RefreshKind::Status {
                        self.diff_generation += 1;
                        after_status_conflicts(&self.scheduler, state, self.diff_generation);
                    }
                    let common = state.paths.as_ref().map(|p| p.common_dir.clone());
                    // Other open worktrees of this repository show this one's badge.
                    if refresh == RefreshKind::Status {
                        for (key, other) in &self.repos {
                            let sibling = *key != repo
                                && other.paths.as_ref().map(|p| &p.common_dir) == common.as_ref()
                                && other.worktrees.as_ref().is_some_and(|w| w.len() > 1);
                            if sibling {
                                let badges = RefreshSet::EMPTY.with(RefreshKind::WorktreeBadges);
                                self.scheduler.request_refresh(key, badges);
                            }
                        }
                    }
                    out.push(RuntimeEvent::Updated {
                        repo,
                        kind: refresh,
                    });
                }
                EventKind::Finished(Err(error)) if error.kind != GitErrorKind::Cancelled => {
                    // The worktree folder was deleted: say so once and stop.
                    if state.toplevel.as_ref().is_some_and(|t| !t.is_dir()) {
                        if !state.missing {
                            state.missing = true;
                            if let Some(watcher) = &self.watcher {
                                watcher.unwatch(&repo);
                            }
                            out.push(RuntimeEvent::Missing { repo });
                        }
                        return;
                    }
                    out.push(RuntimeEvent::RefreshFailed {
                        repo,
                        kind: refresh,
                        error,
                    });
                }
                _ => {}
            }
            return;
        }
        if label == FETCH_JOB_LABEL || label == AUTO_FETCH_JOB_LABEL {
            let finished = matches!(kind, EventKind::Finished(_) | EventKind::Cancelled);
            if finished && state.fetch_job == Some(job) {
                state.fetch_job = None;
                state.next_auto_fetch = auto_fetch_interval.map(|i| Instant::now() + i);
            }
            match &kind {
                EventKind::Finished(Ok(_)) => state.auto_fetch_failed = false,
                // Report a failing auto-fetch once, not every interval.
                EventKind::Finished(Err(err))
                    if label == AUTO_FETCH_JOB_LABEL && err.kind != GitErrorKind::Cancelled =>
                {
                    if state.auto_fetch_failed {
                        return;
                    }
                    state.auto_fetch_failed = true;
                }
                _ => {}
            }
        }
        if matches!(kind, EventKind::Finished(Err(_)))
            && REFRESH_ON_FAILURE.contains(&label.as_str())
        {
            self.scheduler.request_refresh(&repo, RefreshSet::all());
        }
        if let EventKind::Finished(Ok(JobOutput::ShelfDropped { oid, subject })) = &kind {
            state.dropped_shelves.push(ShelfChange {
                old_oid: oid.clone(),
                new_oid: None,
                subject: subject.clone(),
            });
        }
        if let EventKind::Finished(Ok(JobOutput::ShelfChanged { change, remember })) = &kind {
            if *remember {
                state.dropped_shelves.push(change.clone());
            }
        }
        if let EventKind::Finished(Ok(JobOutput::ShelfUndone(change))) = &kind {
            if state.dropped_shelves.last() == Some(change) {
                state.dropped_shelves.pop();
            }
        }
        let common = state.paths.as_ref().map(|p| p.common_dir.clone());
        let replacement = match &kind {
            EventKind::Finished(Ok(JobOutput::ShelfChanged { change, .. })) => {
                Some((change.old_oid.clone(), change.new_oid.clone()))
            }
            EventKind::Finished(Ok(JobOutput::ShelfUndone(change))) => Some((
                change.new_oid.clone().unwrap_or_default(),
                Some(change.old_oid.clone()),
            )),
            _ => None,
        };
        // Bound the Undo history and release its old protection refs on a
        // worker. A failed/crashed edit keeps its recovery reference.
        let excess = state.dropped_shelves.len().saturating_sub(MAX_SHELF_UNDO);
        let expired: Vec<ShelfChange> = state.dropped_shelves.drain(..excess).collect();
        if let Some(toplevel) = state.toplevel.clone() {
            for change in expired {
                self.scheduler.submit(JobSpec::write(
                    &repo,
                    "forget shelf undo",
                    RefreshSet::EMPTY,
                    {
                        let toplevel = toplevel.clone();
                        move |ctx| {
                            ctx.backend()
                                .forget_shelf_change(&toplevel, &change.old_oid, ctx.cancel_token())
                                .map(|()| JobOutput::Done)
                        }
                    },
                ));
            }
        }
        if let Some((old_oid, new_oid)) = replacement {
            for (key, sibling) in &self.repos {
                if key == &repo
                    || (common.is_some()
                        && sibling.paths.as_ref().map(|p| &p.common_dir) == common.as_ref())
                {
                    out.push(RuntimeEvent::ShelfReplaced {
                        repo: key.clone(),
                        old_oid: old_oid.clone(),
                        new_oid: new_oid.clone(),
                    });
                }
            }
        }
        // The stash list is shared by every worktree of the repository.
        let shelf_job = [
            SHELVE_JOB_LABEL,
            RESTORE_SHELF_JOB_LABEL,
            RESTORE_SHELF_FILE_JOB_LABEL,
            DISCARD_SHELF_FILE_JOB_LABEL,
            RENAME_SHELF_JOB_LABEL,
            DISCARD_SHELF_JOB_LABEL,
            UNDO_SHELF_DISCARD_JOB_LABEL,
            CHECKOUT_JOB_LABEL,
        ]
        .contains(&label.as_str());
        if shelf_job && matches!(kind, EventKind::Finished(_)) {
            for (other, sibling) in &self.repos {
                if *other != repo
                    && sibling.paths.as_ref().map(|p| &p.common_dir) == common.as_ref()
                {
                    let stashes = RefreshSet::EMPTY.with(RefreshKind::Stashes);
                    self.scheduler.request_refresh(other, stashes);
                }
            }
        }
        let Some(state) = self.repos.get_mut(&repo) else {
            return;
        };
        if let EventKind::Finished(Ok(JobOutput::Discarded(backups))) = &kind {
            if !backups.is_empty() {
                state.discards.push(backups.clone());
                let excess = state.discards.len().saturating_sub(MAX_DISCARD_UNDO);
                state.discards.drain(..excess);
            }
        }
        let state = match kind {
            EventKind::Started => JobState::Started,
            EventKind::Progress(progress) => JobState::Progress(progress),
            EventKind::Finished(result) => JobState::Finished(result.err()),
            EventKind::Cancelled => JobState::Cancelled,
        };
        // A superseded graph load reports itself cancelled; nobody needs that.
        if label == GRAPH_JOB_LABEL && state == JobState::Cancelled {
            return;
        }
        out.push(RuntimeEvent::Job {
            repo,
            job,
            label,
            state,
        });
    }

    /// Searches rows that loaded since the last job, and reports searches
    /// that changed.
    fn advance_searches(&mut self, out: &mut Vec<RuntimeEvent>) {
        for state in self.repos.values_mut() {
            let reported = match &state.search {
                Some(search) => {
                    search.submit_if_behind(&self.scheduler, state.key.clone());
                    (search.version(), search.is_done())
                }
                None => (0, false),
            };
            if reported != state.search_reported {
                state.search_reported = reported;
                out.push(RuntimeEvent::SearchChanged {
                    repo: state.key.clone(),
                });
            }
        }
    }

    fn reload_dirty_graphs(&mut self, out: &mut Vec<RuntimeEvent>) {
        for state in self.repos.values_mut() {
            let due = state
                .graph_dirty_since
                .is_some_and(|since| since.elapsed() >= GRAPH_RELOAD_DELAY);
            if !due {
                continue;
            }
            state.graph_dirty_since = None;
            // Dropping the old loader cancels it if it is still running.
            state.graph = Some(
                GraphLoader::submit(&self.scheduler, self.runner.clone(), state.key.clone()).0,
            );
            state.restart_search();
            submit_head_info(&self.scheduler, &state.key);
            out.push(RuntimeEvent::GraphReset {
                repo: state.key.clone(),
            });
        }
    }

    /// The backend, for one-off reads outside the job system (CLI, tests).
    pub fn backend(&self) -> &dyn GitBackend {
        self.backend.as_ref()
    }
}

fn apply_refresh(state: &mut RepoState, output: JobOutput) {
    match output {
        JobOutput::Status(status) => {
            let moved = state
                .status
                .as_ref()
                .is_some_and(|old| old.oid != status.oid || old.head != status.head);
            if moved {
                state.graph_dirty_since = Some(Instant::now());
            }
            state.selection.reconcile(&status);
            state.status = Some(status);
            state.rebuild_changes();
            refresh_diff_picks(state);
        }
        JobOutput::Refs(refs, remotes) => {
            if state.refs.as_ref().is_some_and(|old| *old != refs) {
                state.graph_dirty_since = Some(Instant::now());
            }
            state.labels = labels_by_commit(&refs);
            state.refs = Some(refs);
            state.remotes = Some(remotes.iter().map(|r| r.name.clone()).collect());
            state.remote_list = Some(remotes);
        }
        JobOutput::Worktrees(worktrees) => state.worktrees = Some(worktrees),
        JobOutput::Operation(details) => {
            state.operation = details.as_ref().map(|d| d.kind);
            state.operation_details = details;
            // Resolved files are grouped with the conflicts only during one.
            state.rebuild_changes();
        }
        JobOutput::Stashes(stashes) => {
            state.shelves = shelves(&stashes);
            let live: std::collections::HashSet<&str> =
                state.shelves.iter().map(|s| s.oid.as_str()).collect();
            state
                .shelf_files
                .retain(|oid, _| live.contains(oid.as_str()));
            state.stashes = Some(stashes);
        }
        JobOutput::WorktreeBadges(badges) => {
            state.worktree_badges = badges.into_iter().collect();
        }
        JobOutput::Opened { .. }
        | JobOutput::Cleanup(_)
        | JobOutput::Done
        | JobOutput::Diff { .. }
        | JobOutput::OldFile { .. }
        | JobOutput::HeadMessage(_)
        | JobOutput::Commit(_)
        | JobOutput::Discarded(_)
        | JobOutput::ShelfFiles(..)
        | JobOutput::ShelfDropped { .. }
        | JobOutput::MergePreview(_)
        | JobOutput::Conflict { .. }
        | JobOutput::ConflictScan { .. }
        | JobOutput::ConflictWritten(_)
        | JobOutput::HeadInfo(_)
        | JobOutput::CommitUndone(_) => {}
        JobOutput::ShelfChanged { .. } | JobOutput::ShelfUndone(_) => {}
    }
}

/// What worktree jobs refresh: the list, its badges, and refs (branches
/// show which worktree has them).
fn worktree_refresh() -> RefreshSet {
    [
        RefreshKind::Worktrees,
        RefreshKind::WorktreeBadges,
        RefreshKind::Refs,
    ]
    .into_iter()
    .collect()
}

/// Fetches `task`'s remote, then adds the worktree with its new branch. On
/// failure, removes what `git worktree add` left behind (it may have
/// created the branch before refusing the folder).
fn new_task_job(
    backend: &dyn GitBackend,
    repo: &Path,
    task: &NewTask,
    progress: crate::backend::ProgressSink,
    cancel: &CancelToken,
) -> Result<(), GitError> {
    if let Some(remote) = &task.fetch_remote {
        let fetch = SyncOp::Fetch {
            remote: Some(remote.clone()),
        };
        backend.sync(repo, &fetch, progress, cancel)?;
    }
    let branch_ref = format!("refs/heads/{}", task.branch);
    if backend.resolve(repo, &branch_ref, cancel)?.is_some() {
        return Err(GitError::new(
            "worktree add",
            GitErrorKind::AlreadyExists,
            format!("a branch named '{}' already exists", task.branch),
        ));
    }
    let add = WorktreeOp::Add {
        path: task.path.clone(),
        branch: task.branch.clone(),
        start: Some(task.base.clone()),
    };
    let added = backend.worktree_op(repo, &add, cancel).and_then(|()| {
        if !task.track_base {
            return Ok(());
        }
        let track = RefOp::SetUpstream {
            branch: task.branch.clone(),
            upstream: Some(task.base.clone()),
        };
        backend.ref_op(repo, &track, cancel)
    });
    let Err(err) = added else {
        return Ok(());
    };
    // Rolling back must not be cut short by a cancel.
    let restore = CancelToken::new();
    // git reports resolved paths (no symlinks or short names): compare those.
    let target = normalize(&task.path);
    let registered = backend
        .worktrees(repo, &restore)
        .is_ok_and(|list| list.iter().any(|wt| normalize(&wt.path) == target));
    if registered {
        let remove = WorktreeOp::Remove {
            path: task.path.clone(),
            force: true,
        };
        let _ = backend.worktree_op(repo, &remove, &restore);
    }
    if backend
        .resolve(repo, &branch_ref, &restore)
        .is_ok_and(|b| b.is_some())
    {
        let delete = RefOp::DeleteBranch {
            name: task.branch.clone(),
            force: true,
        };
        let _ = backend.ref_op(repo, &delete, &restore);
    }
    Err(err)
}

/// Reads what the undo strip and the graph's `in_head` need.
fn submit_head_info(scheduler: &JobScheduler, key: &Path) {
    scheduler.submit(JobSpec::read(key, HEAD_INFO_JOB_LABEL, |ctx| {
        ctx.backend()
            .head_info(ctx.repo(), ctx.cancel_token())
            .map(|info| JobOutput::HeadInfo(Box::new(info)))
    }));
}

/// Starts loading the selected conflicted file as `generation`.
fn submit_conflict(scheduler: &JobScheduler, state: &mut RepoState, generation: u64) {
    let key = state.key.clone();
    let (Some(conflict), Some(toplevel)) = (state.conflict.as_mut(), state.toplevel.clone()) else {
        return;
    };
    conflict.generation = generation;
    conflict.loading = true;
    let (path, kind) = (conflict.path.clone(), conflict.kind);
    scheduler.submit(JobSpec::read(&key, CONFLICT_JOB_LABEL, move |ctx| {
        let file = ctx
            .backend()
            .conflict_file(&toplevel, &path, kind, ctx.cancel_token())?;
        Ok(JobOutput::Conflict {
            generation,
            file: Box::new(file),
        })
    }));
}

/// Stores a loaded conflicted file if it is still the current one; a text
/// file without conflict blocks left is staged as resolved.
fn apply_conflict(
    scheduler: &JobScheduler,
    state: &mut RepoState,
    kind: EventKind,
    repo: &Path,
    out: &mut Vec<RuntimeEvent>,
) {
    let mut resolved = None;
    let show_base = state.conflict_show_base;
    let Some(conflict) = state.conflict.as_mut() else {
        return;
    };
    match kind {
        EventKind::Finished(Ok(JobOutput::Conflict { generation, file }))
            if generation == conflict.generation && file.path == conflict.path =>
        {
            conflict.loading = false;
            conflict.error = None;
            if file.is_resolved_text() {
                resolved = Some(file.path.clone());
            }
            conflict.kind = file.kind;
            conflict.file = Some(*file);
            conflict.relayout(show_base);
        }
        EventKind::Finished(Err(error))
            if error.kind != GitErrorKind::Cancelled && conflict.loading =>
        {
            conflict.loading = false;
            conflict.error = Some(error);
        }
        _ => return,
    }
    if let Some(path) = resolved.filter(|p| state.is_unmerged(p)) {
        submit_mark_resolved(scheduler, state, vec![path]);
    }
    out.push(RuntimeEvent::DiffChanged {
        repo: repo.to_path_buf(),
        slot: DiffSlot::Changes,
    });
}

/// Stages conflicted files whose markers are gone.
fn submit_mark_resolved(scheduler: &JobScheduler, state: &RepoState, paths: Vec<PathBuf>) {
    let Some(toplevel) = state.toplevel.clone().filter(|_| !paths.is_empty()) else {
        return;
    };
    scheduler.submit(JobSpec::write(
        &state.key,
        MARK_RESOLVED_JOB_LABEL,
        RefreshSet::EMPTY.with(RefreshKind::Status),
        move |ctx| {
            ctx.backend()
                .conflict_op(&toplevel, &ConflictOp::Stage { paths }, ctx.cancel_token())
                .map(|()| JobOutput::Done)
        },
    ));
}

/// After a status refresh: the selected conflicted file reloads, or shows
/// as a diff once resolved (and a diff of a file that became conflicted
/// shows its conflicts); while conflicts are around, the resolved files are
/// read and files whose markers went away are found.
fn after_status_conflicts(scheduler: &JobScheduler, state: &mut RepoState, generation: u64) {
    let diff_path = state.diff.as_ref().map(|d| d.target.path.clone());
    if let Some(kind) = diff_path.as_deref().and_then(|p| state.conflict_kind(p)) {
        if let Some(path) = diff_path {
            state.diff = None;
            state.conflict = Some(ConflictState::new(path, kind));
        }
    }
    if let Some(path) = state.conflict.as_ref().map(|c| c.path.clone()) {
        if state.is_unmerged(&path) {
            submit_conflict(scheduler, state, generation);
        } else {
            state.conflict = None;
            let target = state
                .status
                .as_ref()
                .filter(|s| s.changes.iter().any(|c| c.path == path))
                .map(|s| changes::diff_target(s, &path));
            if let Some(target) = target {
                state.diff = Some(DiffState::new(target, false));
                submit_diff(scheduler, state, DiffSlot::Changes, generation);
            }
        }
    }
    let Some(status) = &state.status else {
        return;
    };
    if !status.has_conflicts() && state.operation.is_none() && state.resolved.is_empty() {
        return;
    }
    let (Some(toplevel), key) = (state.toplevel.clone(), state.key.clone()) else {
        return;
    };
    let text: Vec<PathBuf> = status
        .changes
        .iter()
        .filter(|c| {
            matches!(
                c.state,
                FileState::Unmerged(conflict) if ConflictKind::from_status(conflict).is_text()
            )
        })
        .map(|c| c.path.clone())
        .collect();
    scheduler.submit(JobSpec::read(&key, CONFLICT_SCAN_JOB_LABEL, move |ctx| {
        let resolved = ctx
            .backend()
            .resolved_paths(&toplevel, ctx.cancel_token())?;
        let unmarked = text
            .into_iter()
            .filter(|path| match fs::read(toplevel.join(path)) {
                Ok(bytes) => {
                    !crate::diff::looks_binary(&bytes)
                        && merge::parse_blocks(&merge::split_lines(&bytes)).is_empty()
                }
                Err(_) => false,
            })
            .collect();
        Ok(JobOutput::ConflictScan { resolved, unmarked })
    }));
}

/// What the shelve and restore jobs refresh: the files and the stash list.
fn shelf_refresh() -> RefreshSet {
    RefreshSet::EMPTY
        .with(RefreshKind::Status)
        .with(RefreshKind::Stashes)
}

/// Checks out `target` from `branch`. `Bring` stashes every local change
/// first and re-applies it after switching; `Leave` shelves it on `branch`
/// (an automatic shelf) and switches. Either way a failed switch puts the
/// changes back.
fn checkout_job(
    backend: &dyn GitBackend,
    toplevel: &Path,
    target: &CheckoutTarget,
    changes: CheckoutChanges,
    branch: &str,
    cancel: &CancelToken,
) -> Result<(), GitError> {
    let op = RefOp::Checkout(target.clone());
    let message = match changes {
        CheckoutChanges::Keep => return backend.ref_op(toplevel, &op, cancel),
        CheckoutChanges::Bring => format!("gitbello: switching to {}", target.display_name()),
        CheckoutChanges::Leave => shelf_message(
            branch,
            &format!("Left when switching to {}", target.display_name()),
            true,
        ),
    };
    let stashed = backend.stash_push(toplevel, &message, cancel)?;
    // Putting the changes back must not be cut short by a cancel.
    let restore = CancelToken::new();
    if let Err(err) = backend.ref_op(toplevel, &op, cancel) {
        if let Some(oid) = &stashed {
            pop_stash(backend, toplevel, oid, &restore)?;
        }
        return Err(err);
    }
    match (&stashed, changes) {
        (Some(oid), CheckoutChanges::Bring) => pop_stash(backend, toplevel, oid, &restore),
        _ => Ok(()),
    }
}

/// Pops stash `oid`, restoring what was staged when that applies cleanly.
fn pop_stash(
    backend: &dyn GitBackend,
    toplevel: &Path,
    oid: &str,
    cancel: &CancelToken,
) -> Result<(), GitError> {
    match backend.stash_pop(toplevel, oid, true, cancel) {
        Ok(()) => Ok(()),
        // `--index` refuses without touching anything when the staged
        // changes do not apply; the changes then come back unstaged.
        Err(err) if err.kind != GitErrorKind::Stale => {
            let clean = backend
                .status(toplevel, cancel)
                .is_ok_and(|status| status.changes.iter().all(|c| c.state == FileState::Ignored));
            if clean {
                backend.stash_pop(toplevel, oid, false, cancel)
            } else {
                Err(err)
            }
        }
        Err(err) => Err(err),
    }
}

/// Starts loading `state`'s selected diff in `slot` as `generation`. A file
/// committed as staged also loads its staged diff, to try picking its lines.
fn submit_diff(scheduler: &JobScheduler, state: &mut RepoState, slot: DiffSlot, generation: u64) {
    let key = state.key.clone();
    let toplevel = state.toplevel.clone();
    let as_staged = slot == DiffSlot::Changes && state.diff_as_staged();
    let (Some(diff), Some(toplevel)) = (state.slot_mut(slot).as_mut(), toplevel) else {
        return;
    };
    diff.generation = generation;
    diff.loading = true;
    let target = diff.target.clone();
    let limit = (!diff.full).then_some(LARGE_DIFF_BYTES);
    scheduler.submit(JobSpec::read(&key, slot.label(), move |ctx| {
        let (backend, cancel) = (ctx.backend(), ctx.cancel_token());
        let diff = backend.diff(&toplevel, &target, limit, cancel)?;
        let staged = if as_staged {
            let staged = DiffTarget {
                kind: DiffKind::Staged,
                ..target.clone()
            };
            Some(Box::new(backend.diff(&toplevel, &staged, limit, cancel)?))
        } else {
            None
        };
        Ok(JobOutput::Diff {
            generation,
            diff: Box::new(diff),
            staged,
        })
    }));
}

/// Reads the old side of the diff in `slot` when its open gaps need it.
/// Returns whether a read started.
fn submit_old_file(scheduler: &JobScheduler, state: &mut RepoState, slot: DiffSlot) -> bool {
    let key = state.key.clone();
    let Some(diff) = state.slot_mut(slot).as_mut() else {
        return false;
    };
    let oid = match diff.old_oid() {
        Some(oid) if diff.needs_old_file() => oid.to_owned(),
        _ => return false,
    };
    diff.old_loading = true;
    scheduler.submit(JobSpec::read(&key, OLD_FILE_JOB_LABEL, move |ctx| {
        let text = ctx
            .backend()
            .blob(ctx.repo(), &oid, OLD_FILE_LIMIT, ctx.cancel_token())?;
        Ok(JobOutput::OldFile { oid, text })
    }));
    true
}

/// Stores a read old file in the diffs waiting for it. When the read failed
/// or the file was too large, their gaps close again.
fn apply_old_file(
    state: &mut RepoState,
    result: Option<JobOutput>,
    repo: &Path,
    out: &mut Vec<RuntimeEvent>,
) {
    let (old, failed) = match result {
        Some(JobOutput::OldFile {
            oid,
            text: Some(text),
        }) => (Some(Arc::new(OldFile::new(oid, text))), None),
        Some(JobOutput::OldFile { oid, text: None }) => (None, Some(oid)),
        _ => (None, None),
    };
    for slot in [DiffSlot::Changes, DiffSlot::Commit] {
        let Some(diff) = state.slot_mut(slot).as_mut().filter(|d| d.old_loading) else {
            continue;
        };
        diff.old_loading = false;
        match &old {
            Some(old) if diff.old_oid() == Some(old.oid()) => diff.old = Some(Arc::clone(old)),
            _ => {
                diff.expansion = Expansion::default();
                diff.old_failed = failed.clone().or_else(|| diff.old_oid().map(str::to_owned));
            }
        }
        diff.relayout();
        out.push(RuntimeEvent::DiffChanged {
            repo: repo.to_path_buf(),
            slot,
        });
    }
}

/// Recomputes [`RepoState::diff_picks`] after the diff or the selection changed.
fn refresh_diff_picks(state: &mut RepoState) {
    state.diff_picks = if state.can_pick_lines() {
        match &state.diff {
            Some(DiffState {
                target,
                diff: Some(diff),
                ..
            }) => state.selection.line_states(&target.path, diff),
            _ => Vec::new(),
        }
    } else {
        Vec::new()
    };
}

/// The commit job's error when picked lines no longer match their file.
fn picks_stale(path: &Path) -> GitError {
    GitError::new(
        format!("commit {}", path.display()),
        GitErrorKind::Stale,
        format!(
            "{} changed since its lines were picked; check them and commit again",
            path.display()
        ),
    )
}

/// Stores a finished diff load if it is still the current one.
fn apply_diff(
    state: &mut RepoState,
    slot: DiffSlot,
    kind: EventKind,
    repo: &Path,
    out: &mut Vec<RuntimeEvent>,
) {
    let mut resolve: Option<Box<FileDiff>> = None;
    let Some(current) = state.slot_mut(slot).as_mut() else {
        return;
    };
    match kind {
        EventKind::Finished(Ok(JobOutput::Diff {
            generation,
            diff,
            staged,
        })) if generation == current.generation => {
            current.loading = false;
            current.diff = Some(*diff);
            current.error = None;
            current.relayout();
            resolve = staged;
        }
        EventKind::Finished(Err(error))
            if error.kind != GitErrorKind::Cancelled && current.loading =>
        {
            current.loading = false;
            current.error = Some(error);
        }
        _ => return,
    }
    if let (
        Some(staged),
        Some(DiffState {
            target,
            diff: Some(diff),
            ..
        }),
    ) = (resolve, &state.diff)
    {
        state
            .selection
            .resolve_as_staged(&target.path, diff, &staged);
    }
    out.push(RuntimeEvent::DiffChanged {
        repo: repo.to_path_buf(),
        slot,
    });
}

/// Absolute, symlink-resolved path without Windows' `\\?\` prefix (git and
/// users expect `C:\...`). Falls back to the input when it does not exist.
pub fn normalize(path: &Path) -> PathBuf {
    let Ok(canonical) = fs::canonicalize(path) else {
        return path.to_path_buf();
    };
    #[cfg(windows)]
    {
        let text = canonical.to_string_lossy();
        if let Some(rest) = text.strip_prefix(r"\\?\") {
            // Only plain drive paths; leave `\\?\UNC\...` alone.
            if rest.as_bytes().get(1) == Some(&b':') {
                return PathBuf::from(rest);
            }
        }
    }
    canonical
}
