//! Streams `git log` into a [`GraphIndex`] on a background thread.
//!
//! Readers (the UI) take short read locks to query slices while loading goes
//! on. M2 moves this onto the job scheduler; the API stays the same.

use std::io::Read;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock, RwLockReadGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use thiserror::Error;

use super::index::GraphIndex;
use super::log::{LogParseError, LogRecord, RecordSplitter, LOG_ARGS};
use crate::git::{GitError, GitRunner};

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
    cancel: AtomicBool,
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
    pub fn start(runner: GitRunner, repo: PathBuf) -> Self {
        let shared = Arc::new(Shared {
            index: RwLock::new(GraphIndex::new()),
            rows: AtomicUsize::new(0),
            cancel: AtomicBool::new(false),
            status: Mutex::new(Status {
                state: LoadState::Loading,
                first_page: None,
                total: None,
            }),
            started: Instant::now(),
        });
        let worker = Arc::clone(&shared);
        let handle = thread::Builder::new()
            .name("gitbello-graph".into())
            .spawn(move || {
                let state = match load(&runner, repo, &worker) {
                    Ok(true) => LoadState::Done,
                    Ok(false) => LoadState::Cancelled,
                    Err(err) => LoadState::Failed(err),
                };
                let mut status = worker.status.lock().unwrap_or_else(PoisonError::into_inner);
                let elapsed = worker.started.elapsed();
                status.first_page.get_or_insert(elapsed);
                status.total = Some(elapsed);
                status.state = state;
            })
            .ok();
        if handle.is_none() {
            let mut status = shared.status.lock().unwrap_or_else(PoisonError::into_inner);
            status.state = LoadState::Cancelled;
        }
        Self { shared, handle }
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
        self.shared.cancel.store(true, Ordering::Release);
    }

    /// Blocks until loading ends. For the CLI and tests, never the UI thread.
    pub fn wait(mut self) -> LoadProgress {
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
        self.progress()
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
        if shared.cancel.load(Ordering::Acquire) {
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
