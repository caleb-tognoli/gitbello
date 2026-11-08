//! Streams `git log` into a [`GraphIndex`] on a background thread.
//!
//! Readers (the UI) take short read locks to query slices while loading goes
//! on. M2 moves this onto the job scheduler; the API stays the same.
//!
//! A load first lists the tips it shows (`rev-list --no-walk`). A reload
//! given the previous finished load ([`GraphLoader::submit_reload`]) does
//! less when it can: nothing when the tips are the same, and when no commit
//! was dropped (only added), `git log` of the new commits alone, placed above
//! the previous rows (a valid topological order: no older commit has a newer
//! one as parent). Rewritten or deleted history loads in full.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock, RwLockReadGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use thiserror::Error;

use super::index::GraphIndex;
use super::log::{LogParseError, LogRecord, RecordSplitter, LOG_ARGS};
use super::HistoryScope;
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
    scope: HistoryScope,
    /// The commits the load starts from, sorted (set once listed).
    tips: Mutex<Vec<String>>,
    /// A reload found the same tips as the previous load: nothing to show.
    unchanged: AtomicBool,
    /// A reload loaded only the new commits.
    incremental: AtomicBool,
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
        Self::start_scoped(runner, repo, HistoryScope::AllBranches)
    }

    pub fn start_scoped(runner: GitRunner, repo: PathBuf, scope: HistoryScope) -> Self {
        let (mut loader, task) = Self::unstarted(scope);
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
        Self::submit_scoped(scheduler, runner, repo, HistoryScope::AllBranches)
    }

    pub fn submit_scoped(
        scheduler: &JobScheduler,
        runner: GitRunner,
        repo: PathBuf,
        scope: HistoryScope,
    ) -> (Self, JobId) {
        Self::submit_reload(scheduler, runner, repo, scope, None)
    }

    /// Loads again, reusing `previous` (a finished load of the same scope)
    /// where it can; see the module docs and [`GraphLoader::is_unchanged`].
    pub fn submit_reload(
        scheduler: &JobScheduler,
        runner: GitRunner,
        repo: PathBuf,
        scope: HistoryScope,
        previous: Option<GraphReader>,
    ) -> (Self, JobId) {
        let (loader, mut task) = Self::unstarted(scope);
        task.previous = previous.filter(|p| p.shared.scope == scope && p.is_done());
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
        .with_cancel(loader.shared.cancel.clone())
        .with_priority(crate::jobs::JobPriority::Background);
        let id = scheduler.submit(spec);
        (loader, id)
    }

    /// A loader handle and the task that fills it, to run wherever the caller likes.
    fn unstarted(scope: super::HistoryScope) -> (Self, GraphLoadTask) {
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
            scope,
            tips: Mutex::new(Vec::new()),
            unchanged: AtomicBool::new(false),
            incremental: AtomicBool::new(false),
        });
        let task = GraphLoadTask {
            shared: Arc::clone(&shared),
            scope,
            previous: None,
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

    pub fn scope(&self) -> HistoryScope {
        self.shared.scope
    }

    /// A finished reload found nothing new: keep showing the previous load.
    pub fn is_unchanged(&self) -> bool {
        self.shared.unchanged.load(Ordering::Acquire)
    }

    /// A finished reload read only the commits added since the previous load.
    pub fn is_incremental(&self) -> bool {
        self.shared.incremental.load(Ordering::Acquire)
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

    /// Whether loading finished without error or cancel.
    pub fn is_done(&self) -> bool {
        self.shared
            .status
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .state
            == LoadState::Done
    }

    fn tips(&self) -> Vec<String> {
        self.shared
            .tips
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
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
    scope: super::HistoryScope,
    previous: Option<GraphReader>,
}

impl GraphLoadTask {
    fn run(self, runner: &GitRunner, repo: PathBuf) -> LoadState {
        let result = load(runner, repo, &self.shared, self.scope, self.previous);
        let state = match result {
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
fn load(
    runner: &GitRunner,
    repo: PathBuf,
    shared: &Shared,
    scope: super::HistoryScope,
    previous: Option<GraphReader>,
) -> Result<bool, GraphLoadError> {
    let tips = list_tips(runner, &repo, shared, scope)?;
    *shared.tips.lock().unwrap_or_else(PoisonError::into_inner) = tips.clone();
    if tips.is_empty() {
        return Ok(true);
    }
    if let Some(previous) = previous {
        let old = previous.tips();
        if old == tips {
            shared.unchanged.store(true, Ordering::Release);
            return Ok(true);
        }
        if !old.is_empty() && !drops_commits(runner, &repo, shared, &old, &tips)? {
            let mut input = String::new();
            for tip in &tips {
                input.push_str(tip);
                input.push('\n');
            }
            for tip in &old {
                input.push('^');
                input.push_str(tip);
                input.push('\n');
            }
            // Fill a separate index: nobody reads this one until it is done.
            if !stream_log(runner, &repo, shared, input, false)? {
                return Ok(false);
            }
            let mut index = shared.index.write().unwrap_or_else(PoisonError::into_inner);
            index.extend_from(&previous.index())?;
            index.shrink_to_fit();
            let rows = index.row_count();
            drop(index);
            shared.incremental.store(true, Ordering::Release);
            publish_rows(shared, rows);
            return Ok(true);
        }
    }
    let mut input = tips.join("\n");
    input.push('\n');
    if !stream_log(runner, &repo, shared, input, true)? {
        return Ok(false);
    }
    let mut index = shared.index.write().unwrap_or_else(PoisonError::into_inner);
    index.shrink_to_fit();
    Ok(true)
}

/// The commits the history starts from, sorted: HEAD, or every ref (but the
/// stash) and HEAD as `log --all` takes them.
fn list_tips(
    runner: &GitRunner,
    repo: &Path,
    shared: &Shared,
    scope: super::HistoryScope,
) -> Result<Vec<String>, GraphLoadError> {
    let args: &[&str] = match scope {
        super::HistoryScope::CurrentBranch => {
            &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]
        }
        super::HistoryScope::AllBranches => &[
            "rev-list",
            "--no-walk=unsorted",
            "--exclude=refs/stash",
            "--all",
        ],
    };
    let output = match runner
        .read(repo)
        .args(args)
        .cancel_token(&shared.cancel)
        .run()
    {
        Ok(output) => output,
        // No HEAD yet (an unborn branch): nothing to show.
        Err(error) if error.exit_code == Some(1) => return Ok(Vec::new()),
        Err(error) => return Err(error.into()),
    };
    let mut tips: Vec<String> = output
        .stdout_text()
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_owned)
        .collect();
    tips.sort();
    tips.dedup();
    Ok(tips)
}

/// Whether some commit reachable from `old` is not reachable from `new`
/// (history was rewritten or a branch with its own commits deleted).
fn drops_commits(
    runner: &GitRunner,
    repo: &Path,
    shared: &Shared,
    old: &[String],
    new: &[String],
) -> Result<bool, GraphLoadError> {
    let mut input = String::new();
    for tip in old {
        input.push_str(tip);
        input.push('\n');
    }
    for tip in new {
        input.push('^');
        input.push_str(tip);
        input.push('\n');
    }
    let output = runner
        .read(repo)
        .args(["rev-list", "--count", "--stdin"])
        .stdin(input)
        .cancel_token(&shared.cancel)
        .run()?;
    Ok(output.stdout_text().trim() != "0")
}

/// Streams `git log` of the revisions in `input` into the index. `publish`
/// shows rows as they arrive (a first load); otherwise they appear when the
/// caller publishes them. Returns `Ok(false)` when cancelled.
fn stream_log(
    runner: &GitRunner,
    repo: &Path,
    shared: &Shared,
    input: String,
    publish: bool,
) -> Result<bool, GraphLoadError> {
    let mut args: Vec<&str> = LOG_ARGS
        .iter()
        .copied()
        .filter(|arg| *arg != "--all" && *arg != "--exclude=refs/stash")
        .collect();
    args.extend(["--stdin", "--"]);
    let mut stream = runner.read(repo).args(args).stdin(input).stream()?;
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
        if publish {
            publish_rows(shared, rows);
        }
    }
    let mut index = shared.index.write().unwrap_or_else(PoisonError::into_inner);
    splitter.finish(|record| index.push(&LogRecord::parse(record)?))?;
    let rows = index.row_count();
    drop(index);
    stream.finish()?;
    if publish {
        publish_rows(shared, rows);
    }
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
