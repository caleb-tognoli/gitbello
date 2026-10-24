//! Scheduler ordering, coalescing and cancellation, with a fake backend.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::thread::sleep;
use std::time::{Duration, Instant};

use gitbello_core::backend::{GitBackend, PatchGuard, ProgressSink};
use gitbello_core::diff::{DiffTarget, FileDiff, PatchMode};
use gitbello_core::git::{CancelToken, GitError, GitErrorKind};
use gitbello_core::jobs::{
    Event, EventKind, JobId, JobOutput, JobScheduler, JobSpec, RefreshKind, RefreshSet,
};
use gitbello_core::ops::{RefOp, SyncOp};
use gitbello_core::repo::{Operation, Ref, RepoPaths, RepoStatus, StashEntry, Worktree};

#[derive(Default)]
struct FakeBackend {
    status_calls: AtomicUsize,
    refs_calls: AtomicUsize,
}

impl GitBackend for FakeBackend {
    fn repo_paths(&self, repo: &Path, _: &CancelToken) -> Result<RepoPaths, GitError> {
        Ok(RepoPaths {
            git_dir: repo.join(".git"),
            common_dir: repo.join(".git"),
            bare: false,
        })
    }
    fn toplevel(&self, repo: &Path, _: &CancelToken) -> Result<PathBuf, GitError> {
        Ok(repo.to_path_buf())
    }
    fn status(&self, _: &Path, _: &CancelToken) -> Result<RepoStatus, GitError> {
        self.status_calls.fetch_add(1, Ordering::SeqCst);
        Ok(RepoStatus::default())
    }
    fn refs(&self, _: &Path, _: &CancelToken) -> Result<Vec<Ref>, GitError> {
        self.refs_calls.fetch_add(1, Ordering::SeqCst);
        Ok(Vec::new())
    }
    fn worktrees(&self, _: &Path, _: &CancelToken) -> Result<Vec<Worktree>, GitError> {
        Ok(Vec::new())
    }
    fn operation(&self, _: &Path, _: &CancelToken) -> Result<Option<Operation>, GitError> {
        Ok(None)
    }
    fn stashes(&self, _: &Path, _: &CancelToken) -> Result<Vec<StashEntry>, GitError> {
        Ok(Vec::new())
    }
    fn ignored(&self, _: &Path, _: &[PathBuf], _: &CancelToken) -> Result<Vec<PathBuf>, GitError> {
        Ok(Vec::new())
    }
    fn diff(
        &self,
        _: &Path,
        _: &DiffTarget,
        _: Option<usize>,
        _: &CancelToken,
    ) -> Result<FileDiff, GitError> {
        Ok(FileDiff::default())
    }
    fn head_message(&self, _: &Path, _: &CancelToken) -> Result<String, GitError> {
        Ok(String::new())
    }
    fn stage(&self, _: &Path, _: Option<&[PathBuf]>, _: &CancelToken) -> Result<(), GitError> {
        Ok(())
    }
    fn unstage(&self, _: &Path, _: Option<&[PathBuf]>, _: &CancelToken) -> Result<(), GitError> {
        Ok(())
    }
    fn commit(&self, _: &Path, _: &str, _: bool, _: &CancelToken) -> Result<(), GitError> {
        Ok(())
    }
    fn commit_details(
        &self,
        _: &Path,
        _: &str,
        _: &CancelToken,
    ) -> Result<gitbello_core::repo::CommitDetails, GitError> {
        Ok(Default::default())
    }
    fn apply_patch(
        &self,
        _: &Path,
        _: &[u8],
        _: PatchMode,
        _: &PatchGuard,
        _: &CancelToken,
    ) -> Result<(), GitError> {
        Ok(())
    }
    fn backup(
        &self,
        _: &Path,
        _: &[PathBuf],
        _: &CancelToken,
    ) -> Result<Vec<(PathBuf, String)>, GitError> {
        Ok(Vec::new())
    }
    fn discard(&self, _: &Path, _: &[PathBuf], _: &CancelToken) -> Result<(), GitError> {
        Ok(())
    }
    fn restore_backup(
        &self,
        _: &Path,
        _: &[(PathBuf, String)],
        _: &CancelToken,
    ) -> Result<(), GitError> {
        Ok(())
    }
    fn remotes(&self, _: &Path, _: &CancelToken) -> Result<Vec<String>, GitError> {
        Ok(Vec::new())
    }
    fn sync(&self, _: &Path, _: &SyncOp, _: ProgressSink, _: &CancelToken) -> Result<(), GitError> {
        Ok(())
    }
    fn ref_op(&self, _: &Path, _: &RefOp, _: &CancelToken) -> Result<(), GitError> {
        Ok(())
    }
    fn stash_push(&self, _: &Path, _: &str, _: &CancelToken) -> Result<Option<String>, GitError> {
        Ok(None)
    }
    fn stash_pop(&self, _: &Path, _: &str, _: bool, _: &CancelToken) -> Result<(), GitError> {
        Ok(())
    }
}

type Timeline = Arc<Mutex<Vec<(String, Instant, Instant)>>>;

/// A job that records when it ran and sleeps for `ms`.
fn timed(
    name: &str,
    timeline: &Timeline,
    ms: u64,
) -> impl FnOnce(&gitbello_core::jobs::JobContext) -> Result<JobOutput, GitError> + Send + 'static {
    let (name, timeline) = (name.to_owned(), Arc::clone(timeline));
    move |_| {
        let start = Instant::now();
        sleep(Duration::from_millis(ms));
        timeline
            .lock()
            .expect("timeline")
            .push((name, start, Instant::now()));
        Ok(JobOutput::Done)
    }
}

fn span(timeline: &Timeline, name: &str) -> (Instant, Instant) {
    let t = timeline.lock().expect("timeline");
    let (_, s, e) = t
        .iter()
        .find(|(n, _, _)| n == name)
        .unwrap_or_else(|| panic!("{name} did not run"));
    (*s, *e)
}

fn scheduler(workers: usize) -> (JobScheduler, Receiver<Event>, Arc<FakeBackend>) {
    let backend = Arc::new(FakeBackend::default());
    let (scheduler, events) = JobScheduler::new(backend.clone(), workers);
    (scheduler, events, backend)
}

/// Collects events until every id in `ids` has a final event.
fn wait_final(events: &Receiver<Event>, ids: &[JobId]) -> Vec<Event> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut seen = Vec::new();
    let is_final = |e: &Event| matches!(e.kind, EventKind::Finished(_) | EventKind::Cancelled);
    while ids
        .iter()
        .any(|id| !seen.iter().any(|e: &Event| e.job == *id && is_final(e)))
    {
        let left = deadline.saturating_duration_since(Instant::now());
        match events.recv_timeout(left) {
            Ok(event) => seen.push(event),
            Err(_) => panic!("timed out waiting for {ids:?}; got {seen:#?}"),
        }
    }
    seen
}

#[test]
fn writes_to_one_repository_run_one_at_a_time_in_order() {
    let (scheduler, events, _) = scheduler(4);
    let timeline = Timeline::default();
    let ids: Vec<JobId> = ["w1", "w2", "w3"]
        .iter()
        .map(|n| {
            scheduler.submit(JobSpec::write(
                "/repo/a",
                *n,
                RefreshSet::EMPTY,
                timed(n, &timeline, 40),
            ))
        })
        .collect();
    wait_final(&events, &ids);
    let (w1, w2, w3) = (
        span(&timeline, "w1"),
        span(&timeline, "w2"),
        span(&timeline, "w3"),
    );
    assert!(
        w1.1 <= w2.0 && w2.1 <= w3.0,
        "writes overlapped or reordered"
    );
}

#[test]
fn writes_to_different_repositories_run_concurrently() {
    let (scheduler, events, _) = scheduler(4);
    let timeline = Timeline::default();
    let a = scheduler.submit(JobSpec::write(
        "/repo/a",
        "a",
        RefreshSet::EMPTY,
        timed("a", &timeline, 150),
    ));
    let b = scheduler.submit(JobSpec::write(
        "/repo/b",
        "b",
        RefreshSet::EMPTY,
        timed("b", &timeline, 150),
    ));
    wait_final(&events, &[a, b]);
    let (a, b) = (span(&timeline, "a"), span(&timeline, "b"));
    assert!(
        b.0 < a.1 && a.0 < b.1,
        "writes on different repos did not overlap"
    );
}

#[test]
fn reads_wait_for_a_queued_or_running_write_on_the_same_repository() {
    let (scheduler, events, _) = scheduler(4);
    let timeline = Timeline::default();
    let write = scheduler.submit(JobSpec::write(
        "/repo/a",
        "write",
        RefreshSet::EMPTY,
        timed("write", &timeline, 120),
    ));
    let read_same = scheduler.submit(JobSpec::read(
        "/repo/a",
        "read a",
        timed("read a", &timeline, 1),
    ));
    let read_other = scheduler.submit(JobSpec::read(
        "/repo/b",
        "read b",
        timed("read b", &timeline, 1),
    ));
    wait_final(&events, &[write, read_same, read_other]);
    let write = span(&timeline, "write");
    assert!(
        span(&timeline, "read a").0 >= write.1,
        "read raced the write"
    );
    assert!(
        span(&timeline, "read b").0 < write.1,
        "other repo was blocked"
    );
}

#[test]
fn reads_run_concurrently() {
    let (scheduler, events, _) = scheduler(4);
    let timeline = Timeline::default();
    let ids: Vec<JobId> = ["r1", "r2", "r3"]
        .iter()
        .map(|n| scheduler.submit(JobSpec::read("/repo/a", *n, timed(n, &timeline, 120))))
        .collect();
    wait_final(&events, &ids);
    let (r1, r3) = (span(&timeline, "r1"), span(&timeline, "r3"));
    assert!(r3.0 < r1.1, "reads were serialized");
}

#[test]
fn duplicate_refreshes_coalesce_while_queued() {
    let (scheduler, events, backend) = scheduler(2);
    let timeline = Timeline::default();
    // Hold the repository with a write so the refreshes stay queued.
    let write = scheduler.submit(JobSpec::write(
        "/repo/a",
        "hold",
        RefreshSet::EMPTY,
        timed("hold", &timeline, 100),
    ));
    let status = RefreshSet::EMPTY.with(RefreshKind::Status);
    let first = scheduler.request_refresh(Path::new("/repo/a"), status);
    let second = scheduler.request_refresh(Path::new("/repo/a"), status);
    let both = scheduler.request_refresh(Path::new("/repo/a"), status.with(RefreshKind::Refs));
    assert_eq!(first, second);
    assert_eq!(both[0], first[0]);
    // Another repository gets its own refresh.
    let other = scheduler.request_refresh(Path::new("/repo/b"), status);
    assert_ne!(other, first);

    let events = wait_final(&events, &[write, first[0], both[1], other[0]]);
    assert_eq!(
        backend.status_calls.load(Ordering::SeqCst),
        2,
        "a and b once each"
    );
    assert_eq!(backend.refs_calls.load(Ordering::SeqCst), 1);
    let finished_status = events
        .iter()
        .filter(|e| {
            e.job == first[0] && matches!(e.kind, EventKind::Finished(Ok(JobOutput::Status(_))))
        })
        .count();
    assert_eq!(finished_status, 1);
}

#[test]
fn successful_writes_queue_their_refreshes_after_finishing() {
    let (scheduler, events, backend) = scheduler(2);
    let refresh = RefreshSet::EMPTY
        .with(RefreshKind::Status)
        .with(RefreshKind::Refs);
    let write = scheduler.submit(JobSpec::write("/repo/a", "commit", refresh, |_| {
        Ok(JobOutput::Done)
    }));
    let failing = scheduler.submit(JobSpec::write("/repo/b", "fails", refresh, |_| {
        Err(GitError::new("x", GitErrorKind::Other, "boom"))
    }));
    let mut seen = wait_final(&events, &[write, failing]);
    // Wait for the two follow-up refreshes of the successful write.
    let deadline = Instant::now() + Duration::from_secs(5);
    while seen
        .iter()
        .filter(|e| e.label.starts_with("refresh") && matches!(e.kind, EventKind::Finished(_)))
        .count()
        < 2
    {
        let left = deadline.saturating_duration_since(Instant::now());
        seen.push(events.recv_timeout(left).expect("refreshes after write"));
    }
    let write_done = seen
        .iter()
        .position(|e| e.job == write && matches!(e.kind, EventKind::Finished(_)))
        .unwrap();
    let first_refresh = seen
        .iter()
        .position(|e| e.label.starts_with("refresh"))
        .unwrap();
    assert!(
        write_done < first_refresh,
        "refresh started before the write finished"
    );
    assert!(seen
        .iter()
        .filter(|e| e.label.starts_with("refresh"))
        .all(|e| e.repo == Path::new("/repo/a")));
    assert_eq!(backend.status_calls.load(Ordering::SeqCst), 1);
    assert_eq!(backend.refs_calls.load(Ordering::SeqCst), 1);
}

#[test]
fn every_job_reports_started_then_one_final_event() {
    let (scheduler, events, _) = scheduler(3);
    let ids: Vec<JobId> = (0..10)
        .map(|i| {
            scheduler.submit(JobSpec::read(
                format!("/repo/{}", i % 3),
                format!("r{i}"),
                |_| Ok(JobOutput::Done),
            ))
        })
        .collect();
    let seen = wait_final(&events, &ids);
    for id in ids {
        let kinds: Vec<&EventKind> = seen
            .iter()
            .filter(|e| e.job == id)
            .map(|e| &e.kind)
            .collect();
        assert_eq!(kinds.len(), 2, "{kinds:?}");
        assert_eq!(kinds[0], &EventKind::Started);
        assert!(matches!(kinds[1], EventKind::Finished(Ok(JobOutput::Done))));
    }
}

#[test]
fn cancelling_a_queued_job_skips_it() {
    let (scheduler, events, _) = scheduler(1);
    let timeline = Timeline::default();
    let hold = scheduler.submit(JobSpec::write(
        "/repo/a",
        "hold",
        RefreshSet::EMPTY,
        timed("hold", &timeline, 100),
    ));
    let ran = Arc::new(AtomicUsize::new(0));
    let flag = Arc::clone(&ran);
    let queued = scheduler.submit(JobSpec::read("/repo/a", "queued", move |_| {
        flag.fetch_add(1, Ordering::SeqCst);
        Ok(JobOutput::Done)
    }));
    assert!(scheduler.cancel(queued));
    let seen = wait_final(&events, &[hold, queued]);
    assert_eq!(ran.load(Ordering::SeqCst), 0);
    let kinds: Vec<&EventKind> = seen
        .iter()
        .filter(|e| e.job == queued)
        .map(|e| &e.kind)
        .collect();
    assert_eq!(kinds, [&EventKind::Cancelled]);
}

#[test]
fn cancelling_a_running_job_sets_its_token() {
    let (scheduler, events, _) = scheduler(2);
    let started = Arc::new(AtomicUsize::new(0));
    let flag = Arc::clone(&started);
    let job = scheduler.submit(JobSpec::read("/repo/a", "long", move |ctx| {
        flag.store(1, Ordering::SeqCst);
        let deadline = Instant::now() + Duration::from_secs(5);
        while !ctx.is_cancelled() && Instant::now() < deadline {
            sleep(Duration::from_millis(5));
        }
        Err(GitError::new("long", GitErrorKind::Cancelled, ""))
    }));
    while started.load(Ordering::SeqCst) == 0 {
        sleep(Duration::from_millis(1));
    }
    assert!(scheduler.cancel(job));
    let seen = wait_final(&events, &[job]);
    assert_eq!(seen.last().map(|e| &e.kind), Some(&EventKind::Cancelled));
    assert!(!scheduler.cancel(job), "finished jobs are unknown");
}

#[test]
fn cancel_repo_cancels_queued_and_running_jobs_for_that_repo_only() {
    let (scheduler, events, _) = scheduler(2);
    let long = |ctx: &gitbello_core::jobs::JobContext| {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !ctx.is_cancelled() && Instant::now() < deadline {
            sleep(Duration::from_millis(5));
        }
        if ctx.is_cancelled() {
            Err(GitError::new("w", GitErrorKind::Cancelled, ""))
        } else {
            Ok(JobOutput::Done)
        }
    };
    let running = scheduler.submit(JobSpec::write("/repo/a", "w", RefreshSet::EMPTY, long));
    let queued = scheduler.submit(JobSpec::read("/repo/a", "r", |_| Ok(JobOutput::Done)));
    let other = scheduler.submit(JobSpec::read("/repo/b", "other", |_| Ok(JobOutput::Done)));
    sleep(Duration::from_millis(50));
    scheduler.cancel_repo(Path::new("/repo/a"));
    let seen = wait_final(&events, &[running, queued, other]);
    let last = |id: JobId| {
        seen.iter()
            .rev()
            .find(|e| e.job == id)
            .map(|e| e.kind.clone())
    };
    assert_eq!(last(running), Some(EventKind::Cancelled));
    assert_eq!(last(queued), Some(EventKind::Cancelled));
    assert!(matches!(last(other), Some(EventKind::Finished(Ok(_)))));
}

#[test]
fn a_panicking_job_reports_an_error_and_frees_its_repository() {
    let (scheduler, events, _) = scheduler(1);
    let bad = scheduler.submit(JobSpec::write(
        "/repo/a",
        "bad",
        RefreshSet::EMPTY,
        |_| -> Result<JobOutput, GitError> { panic!("bug in a job") },
    ));
    let next = scheduler.submit(JobSpec::write("/repo/a", "next", RefreshSet::EMPTY, |_| {
        Ok(JobOutput::Done)
    }));
    let seen = wait_final(&events, &[bad, next]);
    assert!(seen.iter().any(|e| e.job == bad
        && matches!(&e.kind, EventKind::Finished(Err(err)) if err.stderr.contains("panicked"))));
    assert!(seen
        .iter()
        .any(|e| e.job == next && matches!(e.kind, EventKind::Finished(Ok(_)))));
}

#[test]
fn dropping_the_scheduler_cancels_running_jobs_and_joins() {
    let (scheduler, _events, _) = scheduler(2);
    let observed = Arc::new(AtomicUsize::new(0));
    let flag = Arc::clone(&observed);
    scheduler.submit(JobSpec::read("/repo/a", "long", move |ctx| {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !ctx.is_cancelled() && Instant::now() < deadline {
            sleep(Duration::from_millis(5));
        }
        flag.store(usize::from(ctx.is_cancelled()), Ordering::SeqCst);
        Ok(JobOutput::Done)
    }));
    sleep(Duration::from_millis(50));
    let started = Instant::now();
    drop(scheduler);
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_eq!(observed.load(Ordering::SeqCst), 1);
}
