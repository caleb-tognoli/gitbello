//! Streams `git log` into a [`GraphIndex`] on a background thread.
//!
//! Readers (the UI) take short read locks to query slices while loading goes
//! on. M2 moves this onto the job scheduler; the API stays the same.

use std::io::Read;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock, RwLockReadGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use thiserror::Error;

use super::index::GraphIndex;
use super::log::{LogParseError, LogRecord, RecordSplitter, LOG_ARGS};
use crate::git::{CancelToken, GitError, GitErrorKind, GitRunner};
use crate::jobs::{JobId, JobOutput, JobScheduler, JobSpec};

/// Label of graph-load jobs on the scheduler.
pub const GRAPH_JOB_LABEL: &str = "load graph";

/// Rows that count as "the first screen" for the first-page timing.
pub const FIRST_PAGE_ROWS: usize = 100;

const READ_CHUNK: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum GraphLoadError {
    #[error(transparent)]
    Git(#[from] GitError),
    #[error("unexpected git log output: {0}")]
    Parse(#[from] LogParseError),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoadState {
    Loading,
    Done,
    Cancelled,
    Failed(GraphLoadError),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoadProgress {
    pub rows: usize,
    pub state: LoadState,
    /// Time from start until [`FIRST_PAGE_ROWS`] rows (or all rows) were indexed.
    pub first_page: Option<Duration>,
    /// Time from start until loading ended.
    pub total: Option<Duration>,
}

impl LoadProgress {
    pub fn is_finished(&self) -> bool {
        self.state != LoadState::Loading
    }
}

#[derive(Debug)]
struct Shared {
    index: RwLock<GraphIndex>,
    rows: AtomicUsize,
    cancel: CancelToken,
    status: Mutex<Status>,
    started: Instant,
}

#[derive(Debug)]
struct Status {
    state: LoadState,
    first_page: Option<Duration>,
    total: Option<Duration>,
}

/// Handle to a running or finished graph load. Dropping it cancels the load.
#[derive(Debug)]
pub struct GraphLoader {
    shared: Arc<Shared>,
    handle: Option<JoinHandle<()>>,
}

impl GraphLoader {
    /// Loads on a dedicated thread. Prefer [`GraphLoader::submit`] inside the app.
    pub fn start(runner: GitRunner, repo: PathBuf) -> Self {
        let (mut loader, task) = Self::unstarted();
        loader.handle = thread::Builder::new()
            .name("gitbello-graph".into())
            .spawn(move || {
                task.run(&runner, repo);
            })
            .ok();
        if loader.handle.is_none() {
            loader.set_state(LoadState::Cancelled);
        }
        loader
    }

    /// Loads as a read job on `scheduler`; cancelling the loader cancels the job.
    pub fn submit(scheduler: &JobScheduler, runner: GitRunner, repo: PathBuf) -> (Self, JobId) {
        let (loader, task) = Self::unstarted();
        let spec = JobSpec::read(repo.clone(), GRAPH_JOB_LABEL, move |_| {
            match task.run(&runner, repo) {
                LoadState::Done | LoadState::Loading => Ok(JobOutput::Done),
                LoadState::Cancelled => Err(GitError::new("log", GitErrorKind::Cancelled, "")),
                LoadState::Failed(GraphLoadError::Git(err)) => Err(err),
                LoadState::Failed(GraphLoadError::Parse(err)) => Err(GitError::new(
                    "log",
                    GitErrorKind::UnexpectedOutput,
                    err.to_string(),
                )),
            }
        })
        .with_cancel(loader.shared.cancel.clone());
        let id = scheduler.submit(spec);
        (loader, id)
    }

    /// A loader handle and the task that fills it, to run wherever the caller likes.
    fn unstarted() -> (Self, GraphLoadTask) {
        let shared = Arc::new(Shared {
            index: RwLock::new(GraphIndex::new()),
            rows: AtomicUsize::new(0),
            cancel: CancelToken::new(),
            status: Mutex::new(Status {
                state: LoadState::Loading,
                first_page: None,
                total: None,
            }),
            started: Instant::now(),
        });
        let task = GraphLoadTask {
            shared: Arc::clone(&shared),
        };
        (
            Self {
                shared,
                handle: None,
            },
            task,
        )
    }

    fn set_state(&self, state: LoadState) {
        let mut status = self
            .shared
            .status
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        status.state = state;
    }

    /// Rows indexed so far. Cheap: one atomic load.
    pub fn row_count(&self) -> usize {
        self.shared.rows.load(Ordering::Acquire)
    }

    pub fn progress(&self) -> LoadProgress {
        let status = self
            .shared
            .status
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        LoadProgress {
            rows: self.row_count(),
            state: status.state.clone(),
            first_page: status.first_page,
            total: status.total,
        }
    }

    /// Read access to the index. Keep the guard short-lived: loading waits on it.
    pub fn index(&self) -> RwLockReadGuard<'_, GraphIndex> {
        self.shared
            .index
            .read()
            .unwrap_or_else(PoisonError::into_inner)
    }

    pub fn cancel(&self) {
        self.shared.cancel.cancel();
    }

    /// A handle on the index for other threads (searches). It does not keep
    /// the load alive: dropping the loader still cancels it.
    pub fn reader(&self) -> GraphReader {
        GraphReader {
            shared: Arc::clone(&self.shared),
        }
    }

    /// Blocks until loading ends. For the CLI and tests, never the UI thread.
    pub fn wait(mut self) -> LoadProgress {
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
        loop {
            let progress = self.progress();
            if progress.is_finished() {
                return progress;
            }
            thread::sleep(Duration::from_millis(2));
        }
    }
}

/// Read access to a loader's index from another thread; see [`GraphLoader::reader`].
#[derive(Debug, Clone)]
pub struct GraphReader {
    shared: Arc<Shared>,
}

impl GraphReader {
    /// Rows indexed so far.
    pub fn row_count(&self) -> usize {
        self.shared.rows.load(Ordering::Acquire)
    }

    /// Whether loading ended (done, cancelled or failed): no more rows come.
    pub fn is_finished(&self) -> bool {
        self.shared
            .status
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .state
            != LoadState::Loading
    }

    /// Read access to the index. Keep the guard short-lived: loading waits on it.
    pub fn index(&self) -> RwLockReadGuard<'_, GraphIndex> {
        self.shared
            .index
            .read()
            .unwrap_or_else(PoisonError::into_inner)
    }
}

/// The work of one graph load; see [`GraphLoader::submit`].
struct GraphLoadTask {
    shared: Arc<Shared>,
}

impl GraphLoadTask {
    fn run(self, runner: &GitRunner, repo: PathBuf) -> LoadState {
        let state = match load(runner, repo, &self.shared) {
            Ok(true) => LoadState::Done,
            Ok(false) => LoadState::Cancelled,
            Err(err) => LoadState::Failed(err),
        };
        let mut status = self
            .shared
            .status
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let elapsed = self.shared.started.elapsed();
        status.first_page.get_or_insert(elapsed);
        status.total = Some(elapsed);
        status.state = state.clone();
        state
    }
}

impl Drop for GraphLoader {
    fn drop(&mut self) {
        // The worker notices within one chunk and kills git; no need to join.
        self.cancel();
    }
}

/// Returns `Ok(false)` when cancelled.
fn load(runner: &GitRunner, repo: PathBuf, shared: &Shared) -> Result<bool, GraphLoadError> {
    let mut stream = runner.read(&repo).args(LOG_ARGS).stream()?;
    let mut splitter = RecordSplitter::new();
    let mut buf = vec![0u8; READ_CHUNK];
    loop {
        if shared.cancel.is_cancelled() {
            stream.kill();
            return Ok(false);
        }
        let n = match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(err) => {
                return Err(GitError::new(
                    stream.command(),
                    crate::git::GitErrorKind::Io,
                    err.to_string(),
                )
                .into())
            }
        };
        let mut index = shared.index.write().unwrap_or_else(PoisonError::into_inner);
        let fed = splitter.feed(&buf[..n], |record| index.push(&LogRecord::parse(record)?));
        let rows = index.row_count();
        drop(index);
        if let Err(err) = fed {
            stream.kill();
            return Err(err.into());
        }
        publish_rows(shared, rows);
    }
    let mut index = shared.index.write().unwrap_or_else(PoisonError::into_inner);
    splitter.finish(|record| index.push(&LogRecord::parse(record)?))?;
    index.shrink_to_fit();
    let rows = index.row_count();
    drop(index);
    stream.finish()?;
    publish_rows(shared, rows);
    Ok(true)
}

fn publish_rows(shared: &Shared, rows: usize) {
    shared.rows.store(rows, Ordering::Release);
    if rows >= FIRST_PAGE_ROWS {
        let mut status = shared.status.lock().unwrap_or_else(PoisonError::into_inner);
        if status.first_page.is_none() {
            status.first_page = Some(shared.started.elapsed());
        }
    }
}
