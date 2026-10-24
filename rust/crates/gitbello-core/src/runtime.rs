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

use crate::backend::{CliBackend, GitBackend, PatchGuard};
use crate::changes::{self, ChangeGroup, ChangeLists};
use crate::config::{Config, ConfigError};
use crate::diff::{
    build_patch, DiffContent, DiffKind, DiffTarget, FileDiff, PatchMode, LARGE_DIFF_BYTES,
};
use crate::git::{CommandLog, GitError, GitErrorKind, GitRunner, GitVersion, Progress};
use crate::graph::{GraphLoader, GRAPH_JOB_LABEL};
use crate::jobs::{
    Event, EventKind, JobId, JobOutput, JobScheduler, JobSpec, RefreshKind, RefreshSet,
};
use crate::repo::{Operation, Ref, RepoPaths, RepoStatus, StashEntry, Worktree};
use crate::sidebar::{labels_by_commit, Badge, RefLabel};
use crate::watch::{RepoWatcher, WatchTarget, DEFAULT_DEBOUNCE};

/// Label of the job that resolves a repository when it is opened.
pub const OPEN_JOB_LABEL: &str = "open repository";

/// Labels of the jobs the changes panel runs.
pub const DIFF_JOB_LABEL: &str = "load diff";
pub const HEAD_MESSAGE_JOB_LABEL: &str = "read HEAD message";
pub const STAGE_JOB_LABEL: &str = "stage";
pub const UNSTAGE_JOB_LABEL: &str = "unstage";
pub const COMMIT_JOB_LABEL: &str = "commit";
pub const DISCARD_JOB_LABEL: &str = "discard";
pub const UNDO_DISCARD_JOB_LABEL: &str = "undo discard";

/// Discards remembered for undo, per repository.
pub const MAX_DISCARD_UNDO: usize = 20;

/// Repositories remembered for the "recent" list.
pub const MAX_KNOWN_REPOS: usize = 20;

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
    /// The selected diff loaded, failed or was cleared.
    DiffChanged {
        repo: PathBuf,
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
    /// New entries in the git command log.
    CommandsLogged,
}

/// Cached state of one open repository.
pub struct RepoState {
    key: PathBuf,
    toplevel: Option<PathBuf>,
    paths: Option<RepoPaths>,
    status: Option<RepoStatus>,
    refs: Option<Vec<Ref>>,
    worktrees: Option<Vec<Worktree>>,
    stashes: Option<Vec<StashEntry>>,
    operation: Option<Operation>,
    labels: HashMap<String, Vec<RefLabel>>,
    changes: ChangeLists,
    worktree_badges: HashMap<PathBuf, Badge>,
    diff: Option<DiffState>,
    /// Backups of recent discards, newest last.
    discards: Vec<Vec<(PathBuf, String)>>,
    graph: Option<GraphLoader>,
    graph_dirty_since: Option<Instant>,
    open_error: Option<GitError>,
}

impl RepoState {
    fn new(key: PathBuf) -> Self {
        Self {
            key,
            toplevel: None,
            paths: None,
            status: None,
            refs: None,
            worktrees: None,
            stashes: None,
            operation: None,
            labels: HashMap::new(),
            changes: ChangeLists::default(),
            worktree_badges: HashMap::new(),
            diff: None,
            discards: Vec::new(),
            graph: None,
            graph_dirty_since: None,
            open_error: None,
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

    /// Folder name of the worktree root (or of the key until resolved).
    pub fn display_name(&self) -> String {
        let path = self.toplevel.as_deref().unwrap_or(&self.key);
        path.file_name().map_or_else(
            || path.display().to_string(),
            |n| n.to_string_lossy().into_owned(),
        )
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

    pub fn operation(&self) -> Option<Operation> {
        self.operation
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

    /// The changes panel's lists (indices into the status's changes).
    pub fn changes(&self) -> &ChangeLists {
        &self.changes
    }

    /// Badge of a worktree, by the path `git worktree list` prints.
    pub fn worktree_badge(&self, path: &Path) -> Option<&Badge> {
        self.worktree_badges.get(path)
    }

    pub fn diff(&self) -> Option<&DiffState> {
        self.diff.as_ref()
    }

    /// Whether the selected diff's lines can be used with `mode`: a loaded
    /// text diff of the matching kind (unstaged for stage and discard,
    /// staged for unstage), not a rename or copy.
    pub fn can_apply_lines(&self, mode: PatchMode) -> bool {
        let Some(state) = &self.diff else {
            return false;
        };
        let kind_ok = match mode {
            PatchMode::Stage | PatchMode::Discard => state.target.kind == DiffKind::Unstaged,
            PatchMode::Unstage => state.target.kind == DiffKind::Staged,
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

    /// Whether a commit can be made: no conflicts, and something staged (or
    /// amending an existing commit).
    pub fn can_commit(&self, amend: bool) -> bool {
        let Some(status) = &self.status else {
            return false;
        };
        if status.has_conflicts() {
            return false;
        }
        if amend {
            return status.oid.is_some();
        }
        !self.changes.is_empty(ChangeGroup::Staged)
    }
}

/// The diff selected in the changes panel.
#[derive(Debug, Clone)]
pub struct DiffState {
    target: DiffTarget,
    /// Load even when larger than [`LARGE_DIFF_BYTES`].
    full: bool,
    generation: u64,
    loading: bool,
    diff: Option<FileDiff>,
    error: Option<GitError>,
}

impl DiffState {
    pub fn target(&self) -> &DiffTarget {
        &self.target
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
        if self.repos.get(key).is_some_and(RepoState::is_ready) {
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
        let Some(state) = self.repos.get_mut(key) else {
            return;
        };
        let Some(target) = target else {
            state.diff = None;
            return;
        };
        let same = state.diff.as_ref().is_some_and(|d| d.target == target);
        if same && state.diff.as_ref().is_some_and(|d| d.full || !full) {
            return;
        }
        let keep = state.diff.take().filter(|_| same);
        state.diff = Some(DiffState {
            target,
            full,
            generation: 0,
            loading: false,
            diff: keep.and_then(|d| d.diff),
            error: None,
        });
        self.diff_generation += 1;
        submit_diff(&self.scheduler, state, self.diff_generation);
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
            (Some(paths), Some(status)) => Some(changes::unstage_paths(status, &paths)),
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
        let guard = match mode {
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

    /// Restores `paths` in the working tree from the index, after backing
    /// up their current content for [`Runtime::undo_discard`].
    pub fn discard_files(&self, key: &Path, paths: Vec<PathBuf>) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        if paths.is_empty() {
            return None;
        }
        Some(self.scheduler.submit(JobSpec::write(
            key,
            DISCARD_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                let (backend, cancel) = (ctx.backend(), ctx.cancel_token());
                let backups = backend.backup(&toplevel, &paths, cancel)?;
                backend.discard(&toplevel, &paths, cancel)?;
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

    /// Commits the index (or amends HEAD) with `message`.
    pub fn commit(&self, key: &Path, message: String, amend: bool) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let refresh = RefreshSet::EMPTY
            .with(RefreshKind::Status)
            .with(RefreshKind::Refs);
        Some(
            self.scheduler
                .submit(JobSpec::write(key, COMMIT_JOB_LABEL, refresh, move |ctx| {
                    ctx.backend()
                        .commit(&toplevel, &message, amend, ctx.cancel_token())
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

    fn toplevel_of(&self, key: &Path) -> Option<PathBuf> {
        let state = self.repos.get(key).filter(|s| s.is_ready())?;
        state.toplevel.clone()
    }

    pub fn repo(&self, key: &Path) -> Option<&RepoState> {
        self.repos.get(key)
    }

    pub fn repos(&self) -> impl Iterator<Item = &RepoState> {
        self.repos.values()
    }

    /// Applies finished jobs and returns what changed. Call once per frame.
    pub fn poll(&mut self) -> Vec<RuntimeEvent> {
        let mut out = Vec::new();
        while let Ok(event) = self.events.try_recv() {
            self.apply(event, &mut out);
        }
        self.reload_dirty_graphs(&mut out);
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
        let Some(state) = self.repos.get_mut(&repo) else {
            return; // closed meanwhile
        };
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
                    state.graph = Some(
                        GraphLoader::submit(&self.scheduler, self.runner.clone(), repo.clone()).0,
                    );
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
            apply_diff(state, kind, &repo, out);
            return;
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
                    // Staging, edits and commits all show up as a status change.
                    if refresh == RefreshKind::Status && state.diff.is_some() {
                        self.diff_generation += 1;
                        submit_diff(&self.scheduler, state, self.diff_generation);
                    }
                    out.push(RuntimeEvent::Updated {
                        repo,
                        kind: refresh,
                    });
                }
                EventKind::Finished(Err(error)) if error.kind != GitErrorKind::Cancelled => {
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
            state.changes = ChangeLists::new(&status);
            state.status = Some(status);
        }
        JobOutput::Refs(refs) => {
            if state.refs.as_ref().is_some_and(|old| *old != refs) {
                state.graph_dirty_since = Some(Instant::now());
            }
            state.labels = labels_by_commit(&refs);
            state.refs = Some(refs);
        }
        JobOutput::Worktrees(worktrees) => state.worktrees = Some(worktrees),
        JobOutput::Operation(operation) => state.operation = operation,
        JobOutput::Stashes(stashes) => state.stashes = Some(stashes),
        JobOutput::WorktreeBadges(badges) => {
            state.worktree_badges = badges.into_iter().collect();
        }
        JobOutput::Opened { .. }
        | JobOutput::Done
        | JobOutput::Diff { .. }
        | JobOutput::HeadMessage(_)
        | JobOutput::Discarded(_) => {}
    }
}

/// Starts loading `state`'s selected diff as `generation`.
fn submit_diff(scheduler: &JobScheduler, state: &mut RepoState, generation: u64) {
    let (Some(diff), Some(toplevel)) = (state.diff.as_mut(), state.toplevel.clone()) else {
        return;
    };
    diff.generation = generation;
    diff.loading = true;
    let target = diff.target.clone();
    let limit = (!diff.full).then_some(LARGE_DIFF_BYTES);
    scheduler.submit(JobSpec::read(&state.key, DIFF_JOB_LABEL, move |ctx| {
        ctx.backend()
            .diff(&toplevel, &target, limit, ctx.cancel_token())
            .map(|diff| JobOutput::Diff { generation, diff })
    }));
}

/// Stores a finished diff load if it is still the current one.
fn apply_diff(state: &mut RepoState, kind: EventKind, repo: &Path, out: &mut Vec<RuntimeEvent>) {
    let Some(current) = state.diff.as_mut() else {
        return;
    };
    match kind {
        EventKind::Finished(Ok(JobOutput::Diff { generation, diff }))
            if generation == current.generation =>
        {
            current.loading = false;
            current.diff = Some(diff);
            current.error = None;
        }
        EventKind::Finished(Err(error))
            if error.kind != GitErrorKind::Cancelled && current.loading =>
        {
            current.loading = false;
            current.error = Some(error);
        }
        _ => return,
    }
    out.push(RuntimeEvent::DiffChanged {
        repo: repo.to_path_buf(),
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
