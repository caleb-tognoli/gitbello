//! Background jobs (PLAN §3.4).
//!
//! - A small pool of worker threads runs jobs; results go out as [`Event`]s on
//!   one channel that the UI drains without blocking.
//! - Writes to the same repository run one at a time, in submission order.
//! - A read waits while a write to the same repository is running or queued
//!   ahead of it, so it never races a write. Reads otherwise run concurrently.
//! - After a successful write, the refreshes it declared are queued.
//! - Refresh requests coalesce: a refresh that is already queued (not yet
//!   started) for the same repository and kind is reused.

use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;
use std::panic::{self, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};

use crate::backend::GitBackend;
use crate::diff::FileDiff;
use crate::git::{CancelToken, GitError, GitErrorKind, Progress};
use crate::repo::{Operation, Ref, RepoPaths, RepoStatus, StashEntry, Worktree};
use crate::sidebar::Badge;

pub type JobId = u64;

/// What a refresh job reads. Combine with [`RefreshSet`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RefreshKind {
    Status,
    Refs,
    Worktrees,
    Operation,
    Stashes,
    /// Status of every linked worktree, reduced to badges.
    WorktreeBadges,
}

impl RefreshKind {
    pub const ALL: [RefreshKind; 6] = [
        Self::Status,
        Self::Refs,
        Self::Worktrees,
        Self::Operation,
        Self::Stashes,
        Self::WorktreeBadges,
    ];

    fn bit(self) -> u8 {
        1 << (self as u8)
    }

    /// The kind whose refresh jobs carry `label`.
    pub fn from_label(label: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.label() == label)
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Status => "refresh status",
            Self::Refs => "refresh refs",
            Self::Worktrees => "refresh worktrees",
            Self::Operation => "refresh operation",
            Self::Stashes => "refresh stashes",
            Self::WorktreeBadges => "refresh worktree badges",
        }
    }
}

/// A set of [`RefreshKind`]s.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct RefreshSet(u8);

impl RefreshSet {
    pub const EMPTY: Self = Self(0);

    pub fn all() -> Self {
        RefreshKind::ALL.iter().copied().collect()
    }

    /// The cheap refresh to run for the active tab when the window regains
    /// focus, as a fallback for missed file events (PLAN §3.6).
    pub fn on_focus() -> Self {
        [
            RefreshKind::Status,
            RefreshKind::Refs,
            RefreshKind::Operation,
            RefreshKind::WorktreeBadges,
        ]
        .into_iter()
        .collect()
    }

    pub fn with(self, kind: RefreshKind) -> Self {
        Self(self.0 | kind.bit())
    }

    pub fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    pub fn contains(self, kind: RefreshKind) -> bool {
        self.0 & kind.bit() != 0
    }

    pub fn is_empty(self) -> bool {
        self.0 == 0
    }

    pub fn iter(self) -> impl Iterator<Item = RefreshKind> {
        RefreshKind::ALL
            .into_iter()
            .filter(move |k| self.contains(*k))
    }
}

impl FromIterator<RefreshKind> for RefreshSet {
    fn from_iter<I: IntoIterator<Item = RefreshKind>>(iter: I) -> Self {
        iter.into_iter().fold(Self::EMPTY, Self::with)
    }
}

impl fmt::Debug for RefreshSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_set().entries(self.iter()).finish()
    }
}

/// Result payload of a finished job.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobOutput {
    Status(RepoStatus),
    Refs(Vec<Ref>),
    Worktrees(Vec<Worktree>),
    Operation(Option<Operation>),
    Stashes(Vec<StashEntry>),
    /// Badge per linked worktree path.
    WorktreeBadges(Vec<(PathBuf, Badge)>),
    /// A diff load; `generation` tells a stale result from the current one.
    Diff {
        generation: u64,
        diff: FileDiff,
    },
    /// The HEAD commit's message.
    HeadMessage(String),
    /// A repository was opened: its worktree root and git directories.
    Opened {
        toplevel: PathBuf,
        paths: RepoPaths,
    },
    /// Jobs whose effect is elsewhere (writes, graph loads).
    Done,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EventKind {
    Started,
    Progress(Progress),
    Finished(Result<JobOutput, GitError>),
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    pub job: JobId,
    pub repo: PathBuf,
    pub label: String,
    pub kind: EventKind,
}

/// Whether a job only reads or also changes the repository.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobAccess {
    Read,
    Write,
}

/// What a running job can use.
pub struct JobContext {
    job: JobId,
    repo: PathBuf,
    label: String,
    cancel: CancelToken,
    backend: Arc<dyn GitBackend>,
    events: Sender<Event>,
}

impl JobContext {
    pub fn id(&self) -> JobId {
        self.job
    }

    pub fn repo(&self) -> &Path {
        &self.repo
    }

    pub fn cancel_token(&self) -> &CancelToken {
        &self.cancel
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.is_cancelled()
    }

    pub fn backend(&self) -> &dyn GitBackend {
        self.backend.as_ref()
    }

    /// A callback that forwards progress updates as events, for
    /// [`crate::git::GitCommand::on_progress`].
    pub fn progress_sink(&self) -> impl FnMut(Progress) + Send + 'static {
        let events = self.events.clone();
        let (job, repo, label) = (self.job, self.repo.clone(), self.label.clone());
        move |progress| {
            let _ = events.send(Event {
                job,
                repo: repo.clone(),
                label: label.clone(),
                kind: EventKind::Progress(progress),
            });
        }
    }
}

type JobFn = Box<dyn FnOnce(&JobContext) -> Result<JobOutput, GitError> + Send>;

/// A job to submit.
pub struct JobSpec {
    pub repo: PathBuf,
    pub access: JobAccess,
    pub label: String,
    /// Refreshes to queue after a successful write.
    pub refresh_after: RefreshSet,
    /// Use an existing token (for handles that cancel on their own, like the
    /// graph loader); a new one is made otherwise.
    pub cancel: Option<CancelToken>,
    pub run: JobFn,
}

impl JobSpec {
    pub fn read(
        repo: impl Into<PathBuf>,
        label: impl Into<String>,
        run: impl FnOnce(&JobContext) -> Result<JobOutput, GitError> + Send + 'static,
    ) -> Self {
        Self {
            repo: repo.into(),
            access: JobAccess::Read,
            label: label.into(),
            refresh_after: RefreshSet::EMPTY,
            cancel: None,
            run: Box::new(run),
        }
    }

    pub fn write(
        repo: impl Into<PathBuf>,
        label: impl Into<String>,
        refresh_after: RefreshSet,
        run: impl FnOnce(&JobContext) -> Result<JobOutput, GitError> + Send + 'static,
    ) -> Self {
        Self {
            access: JobAccess::Write,
            refresh_after,
            ..Self::read(repo, label, run)
        }
    }

    pub fn with_cancel(mut self, token: CancelToken) -> Self {
        self.cancel = Some(token);
        self
    }
}

struct Queued {
    id: JobId,
    spec: JobSpec,
    cancel: CancelToken,
    refresh: Option<RefreshKind>,
}

struct Running {
    repo: PathBuf,
    cancel: CancelToken,
}

#[derive(Default)]
struct State {
    next_id: JobId,
    queue: VecDeque<Queued>,
    running: HashMap<JobId, Running>,
    writing: HashSet<PathBuf>,
    shutdown: bool,
}

struct Inner {
    backend: Arc<dyn GitBackend>,
    state: Mutex<State>,
    wake: Condvar,
    events: Sender<Event>,
}

impl Inner {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn send(&self, job: JobId, repo: &Path, label: &str, kind: EventKind) {
        let _ = self.events.send(Event {
            job,
            repo: repo.to_path_buf(),
            label: label.to_owned(),
            kind,
        });
    }

    /// Queues a refresh unless the same one is already queued; returns its id.
    fn queue_refresh(&self, state: &mut State, repo: &Path, kind: RefreshKind) -> JobId {
        if let Some(existing) = state
            .queue
            .iter()
            .find(|q| q.refresh == Some(kind) && q.spec.repo == repo)
        {
            return existing.id;
        }
        let spec = JobSpec::read(repo, kind.label(), move |ctx: &JobContext| {
            let (repo, cancel, backend) = (ctx.repo(), ctx.cancel_token(), ctx.backend());
            match kind {
                RefreshKind::Status => backend.status(repo, cancel).map(JobOutput::Status),
                RefreshKind::Refs => backend.refs(repo, cancel).map(JobOutput::Refs),
                RefreshKind::Worktrees => backend.worktrees(repo, cancel).map(JobOutput::Worktrees),
                RefreshKind::Operation => backend.operation(repo, cancel).map(JobOutput::Operation),
                RefreshKind::Stashes => backend.stashes(repo, cancel).map(JobOutput::Stashes),
                RefreshKind::WorktreeBadges => {
                    worktree_badges(backend, repo, cancel).map(JobOutput::WorktreeBadges)
                }
            }
        });
        Self::enqueue(state, spec, Some(kind))
    }

    fn enqueue(state: &mut State, spec: JobSpec, refresh: Option<RefreshKind>) -> JobId {
        state.next_id += 1;
        let id = state.next_id;
        let cancel = spec.cancel.clone().unwrap_or_default();
        state.queue.push_back(Queued {
            id,
            spec,
            cancel,
            refresh,
        });
        id
    }
}

/// Status of each worktree of `repo` that is present on disk.
fn worktree_badges(
    backend: &dyn GitBackend,
    repo: &Path,
    cancel: &CancelToken,
) -> Result<Vec<(PathBuf, Badge)>, GitError> {
    let mut badges = Vec::new();
    for worktree in backend.worktrees(repo, cancel)? {
        if worktree.bare || worktree.prunable.is_some() || !worktree.path.is_dir() {
            continue;
        }
        // A worktree that cannot be read just has no badge.
        if let Ok(status) = backend.status(&worktree.path, cancel) {
            badges.push((worktree.path, Badge::new(Some(&status), None)));
        }
    }
    Ok(badges)
}

/// Index of the first job allowed to start now.
fn next_runnable(state: &State) -> Option<usize> {
    // Repositories with a write queued ahead of the current position.
    let mut write_ahead: HashSet<&Path> = HashSet::new();
    for (i, job) in state.queue.iter().enumerate() {
        let repo = job.spec.repo.as_path();
        let free = !state.writing.contains(repo) && !write_ahead.contains(repo);
        if free {
            return Some(i);
        }
        if job.spec.access == JobAccess::Write {
            write_ahead.insert(repo);
        }
    }
    None
}

/// Runs jobs on a fixed pool of worker threads. Dropping it cancels running
/// jobs, drops queued ones and joins the workers.
pub struct JobScheduler {
    inner: Arc<Inner>,
    workers: Vec<JoinHandle<()>>,
}

impl JobScheduler {
    /// Starts `workers` threads (at least one). Events arrive on the receiver.
    pub fn new(backend: Arc<dyn GitBackend>, workers: usize) -> (Self, Receiver<Event>) {
        let (events, receiver) = mpsc::channel();
        let inner = Arc::new(Inner {
            backend,
            state: Mutex::new(State::default()),
            wake: Condvar::new(),
            events,
        });
        let workers = (0..workers.max(1))
            .filter_map(|n| {
                let inner = Arc::clone(&inner);
                thread::Builder::new()
                    .name(format!("gitbello-job-{n}"))
                    .spawn(move || worker(&inner))
                    .ok()
            })
            .collect();
        (Self { inner, workers }, receiver)
    }

    /// A pool sized for git work: up to 4 threads.
    pub fn default_workers() -> usize {
        thread::available_parallelism().map_or(2, |n| n.get().min(4))
    }

    pub fn submit(&self, spec: JobSpec) -> JobId {
        let mut state = self.inner.lock();
        let id = Inner::enqueue(&mut state, spec, None);
        drop(state);
        self.inner.wake.notify_all();
        id
    }

    /// Queues refreshes of `kinds` for `repo`, reusing identical queued ones.
    /// Returns the job id per kind, in [`RefreshKind::ALL`] order.
    pub fn request_refresh(&self, repo: &Path, kinds: RefreshSet) -> Vec<JobId> {
        let mut state = self.inner.lock();
        let ids = kinds
            .iter()
            .map(|kind| self.inner.queue_refresh(&mut state, repo, kind))
            .collect();
        drop(state);
        self.inner.wake.notify_all();
        ids
    }

    /// Cancels a queued or running job. Returns whether it was found.
    pub fn cancel(&self, id: JobId) -> bool {
        let mut state = self.inner.lock();
        if let Some(pos) = state.queue.iter().position(|q| q.id == id) {
            if let Some(job) = state.queue.remove(pos) {
                drop(state);
                job.cancel.cancel();
                self.inner.send(
                    job.id,
                    &job.spec.repo,
                    &job.spec.label,
                    EventKind::Cancelled,
                );
                self.inner.wake.notify_all();
            }
            return true;
        }
        match state.running.get(&id) {
            Some(running) => {
                running.cancel.cancel();
                true
            }
            None => false,
        }
    }

    /// Cancels every queued and running job for `repo` (closing its tab).
    pub fn cancel_repo(&self, repo: &Path) {
        let ids: Vec<JobId> = {
            let state = self.inner.lock();
            state
                .queue
                .iter()
                .filter(|q| q.spec.repo == repo)
                .map(|q| q.id)
                .chain(
                    state
                        .running
                        .iter()
                        .filter(|(_, r)| r.repo == repo)
                        .map(|(id, _)| *id),
                )
                .collect()
        };
        for id in ids {
            self.cancel(id);
        }
    }

    /// Jobs queued or running, for tests and diagnostics.
    pub fn pending(&self) -> usize {
        let state = self.inner.lock();
        state.queue.len() + state.running.len()
    }
}

impl Drop for JobScheduler {
    fn drop(&mut self) {
        {
            let mut state = self.inner.lock();
            state.shutdown = true;
            for running in state.running.values() {
                running.cancel.cancel();
            }
            for queued in state.queue.drain(..) {
                queued.cancel.cancel();
            }
        }
        self.inner.wake.notify_all();
        for handle in self.workers.drain(..) {
            let _ = handle.join();
        }
    }
}

fn worker(inner: &Inner) {
    loop {
        let job = {
            let mut state = inner.lock();
            loop {
                if state.shutdown {
                    return;
                }
                if let Some(job) = next_runnable(&state).and_then(|i| state.queue.remove(i)) {
                    state.running.insert(
                        job.id,
                        Running {
                            repo: job.spec.repo.clone(),
                            cancel: job.cancel.clone(),
                        },
                    );
                    if job.spec.access == JobAccess::Write {
                        state.writing.insert(job.spec.repo.clone());
                    }
                    break job;
                }
                state = inner
                    .wake
                    .wait(state)
                    .unwrap_or_else(PoisonError::into_inner);
            }
        };

        let Queued {
            id, spec, cancel, ..
        } = job;
        let JobSpec {
            repo,
            access,
            label,
            refresh_after,
            run,
            ..
        } = spec;
        inner.send(id, &repo, &label, EventKind::Started);
        let ctx = JobContext {
            job: id,
            repo: repo.clone(),
            label: label.clone(),
            cancel: cancel.clone(),
            backend: Arc::clone(&inner.backend),
            events: inner.events.clone(),
        };
        let result = if cancel.is_cancelled() {
            Err(GitError::new(label.as_str(), GitErrorKind::Cancelled, ""))
        } else {
            // A panicking job must not take the worker (and its repository's
            // write slot) down with it.
            panic::catch_unwind(AssertUnwindSafe(|| run(&ctx))).unwrap_or_else(|_| {
                Err(GitError::new(
                    label.as_str(),
                    GitErrorKind::Other,
                    "internal error: job panicked",
                ))
            })
        };
        let succeeded = result.is_ok();
        let cancelled = cancel.is_cancelled()
            || matches!(&result, Err(err) if err.kind == GitErrorKind::Cancelled);
        let kind = if cancelled {
            EventKind::Cancelled
        } else {
            EventKind::Finished(result)
        };

        // The final event goes out before the refreshes this job triggers can
        // start, so listeners see a write finish before its follow-up reads.
        inner.send(id, &repo, &label, kind);
        {
            let mut state = inner.lock();
            state.running.remove(&id);
            if access == JobAccess::Write {
                state.writing.remove(&repo);
                if succeeded && !cancelled && !state.shutdown {
                    for refresh in refresh_after.iter() {
                        inner.queue_refresh(&mut state, &repo, refresh);
                    }
                }
            }
        }
        inner.wake.notify_all();
    }
}
