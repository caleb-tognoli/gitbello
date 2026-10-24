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

use crate::backend::{CliBackend, GitBackend};
use crate::config::{Config, ConfigError};
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
    /// Progress of jobs other than refreshes (graph loads; writes later).
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
        Ok(Self {
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
        })
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
        if let Some(refresh) = RefreshKind::from_label(&label) {
            match kind {
                EventKind::Finished(Ok(output)) => {
                    apply_refresh(state, output);
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
        JobOutput::Opened { .. } | JobOutput::Done => {}
    }
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
