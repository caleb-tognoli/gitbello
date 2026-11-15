//! The new-worktree flow (UX.md New task): creating a worktree for a new,
//! existing or remote branch, its setup, and undoing a create.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use super::{normalize, remove_worktree, worktree_refresh, RemoteBranch, RepoState, Runtime};
use crate::backend::{GitBackend, ProgressSink};
use crate::git::{CancelToken, GitError, GitErrorKind};
use crate::jobs::{EventKind, JobId, JobOutput, JobSpec, RefreshKind, RefreshSet};
use crate::library::{library_root, path_key};
use crate::ops::{
    NewWorktree, RefOp, SyncOp, WorktreeOp, WorktreeStart, NEW_TASK_JOB_LABEL,
    UNDO_NEW_WORKTREE_JOB_LABEL, WORKTREE_SETUP_JOB_LABEL,
};
use crate::repo::FileState;
use crate::worktree_setup::{copy_entries, run_command, SetupOutcome, WorktreeSetup};
use crate::worktrees::free_worktree_path;

/// How long a create waits for its base's fetch before using the remote
/// branch as last fetched.
pub const FETCH_TIMEOUT: Duration = Duration::from_secs(5);

/// Creates remembered for undo, per repository.
const MAX_CREATED: usize = 20;

/// A base the create could not fetch: it started from the remote branch
/// as last fetched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StaleBase {
    /// `origin/main`.
    pub base: String,
    /// When it was last fetched (Unix seconds), when its reflog says.
    pub fetched_at: Option<i64>,
    /// The fetch took longer than [`FETCH_TIMEOUT`].
    pub timed_out: bool,
    /// git's error, when it failed.
    pub error: String,
}

/// A worktree [`Runtime::create_worktree`] made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreatedWorktree {
    /// Where it went (the folder asked for, or `-2`, `-3`… when taken).
    pub path: PathBuf,
    pub branch: String,
    /// The create made the branch, so undo deletes it.
    pub created_branch: bool,
    /// The branch's commit once created, to tell whether it moved since.
    pub tip: String,
    pub stale: Option<StaleBase>,
}

#[derive(Debug, Default)]
pub(super) struct NewWorktreeState {
    /// Finished creates, newest last, with their job.
    created: Vec<(JobId, CreatedWorktree)>,
    /// Running setups by [`path_key`] of their worktree.
    setups: HashMap<String, JobId>,
}

impl RepoState {
    /// What create job `job` made, once it finished.
    pub fn created_worktree(&self, job: JobId) -> Option<&CreatedWorktree> {
        self.new_worktree
            .created
            .iter()
            .find(|(id, _)| *id == job)
            .map(|(_, c)| c)
    }

    /// Whether the worktree at `path` came from a create that can be undone.
    pub fn can_undo_create(&self, path: &Path) -> bool {
        self.created_at(path).is_some()
    }

    /// Whether a setup runs in the worktree at `path`.
    pub fn setup_running(&self, path: &Path) -> bool {
        self.new_worktree.setups.contains_key(&path_key(path))
    }

    fn created_at(&self, path: &Path) -> Option<&CreatedWorktree> {
        let key = path_key(&normalize(path));
        self.new_worktree
            .created
            .iter()
            .rev()
            .map(|(_, c)| c)
            .find(|c| path_key(&normalize(&c.path)) == key)
    }

    /// `origin/topic` as a remote and a branch, when it names a
    /// remote-tracking branch of a configured remote (the longest remote
    /// name wins) and no local branch has that name.
    fn remote_branch(&self, short: &str) -> Option<RemoteBranch> {
        if self.branch(short).is_some() {
            return None;
        }
        let remote = self
            .remotes()
            .iter()
            .filter(|r| short.len() > r.len() + 1)
            .filter(|r| short.starts_with(r.as_str()) && short[r.len()..].starts_with('/'))
            .max_by_key(|r| r.len())?;
        Some(RemoteBranch {
            remote: remote.clone(),
            branch: short[remote.len() + 1..].to_owned(),
        })
    }

    /// The library entry this repository is listed under.
    fn library_key(&self) -> Option<PathBuf> {
        Some(library_root(
            self.toplevel.as_deref()?,
            self.paths.as_ref()?,
        ))
    }
}

impl Runtime {
    /// The new-worktree flow (UX.md New task) as one job: fetch the
    /// remote branch it starts from (falling back to the one last fetched
    /// when that fails or takes over [`FETCH_TIMEOUT`]), then add the
    /// worktree in the first free folder. A failure rolls back what was
    /// created. The result is [`RepoState::created_worktree`]; the caller
    /// shows the worktree and starts its setup. Label [`NEW_TASK_JOB_LABEL`].
    pub fn create_worktree(&self, key: &Path, request: NewWorktree) -> Option<JobId> {
        let state = self.repos.get(key).filter(|s| s.is_ready())?;
        let fetch = match &request.start {
            WorktreeStart::NewBranch { base } => state.remote_branch(base),
            WorktreeStart::Remote { upstream } => state.remote_branch(upstream),
            WorktreeStart::Existing => None,
        };
        let timeout = self.fetch_timeout;
        Some(self.scheduler.submit(JobSpec::write(
            key,
            NEW_TASK_JOB_LABEL,
            worktree_refresh(),
            move |ctx| {
                let progress = Box::new(ctx.progress_sink());
                let fetch = fetch.map(|f| (f, timeout));
                create_job(
                    ctx.backend(),
                    ctx.repo(),
                    &request,
                    fetch,
                    progress,
                    ctx.cancel_token(),
                )
                .map(|created| JobOutput::WorktreeCreated(Box::new(created)))
            },
        )))
    }

    /// How long creates wait for their base's fetch ([`FETCH_TIMEOUT`]).
    pub fn set_fetch_timeout(&mut self, timeout: Duration) {
        self.fetch_timeout = timeout;
    }

    /// What new worktrees of the repository at `key` get (empty when it
    /// has no setup or is not in the library).
    pub fn worktree_setup(&self, key: &Path) -> WorktreeSetup {
        self.repos
            .get(key)
            .and_then(RepoState::library_key)
            .and_then(|root| self.library.get(&root))
            .map(|entry| entry.setup.clone())
            .unwrap_or_default()
    }

    /// Sets what new worktrees of the repository at `key` get, adding it to
    /// the library if needed. Returns whether it changed.
    pub fn set_worktree_setup(&mut self, key: &Path, setup: WorktreeSetup) -> bool {
        let Some(root) = self.repos.get(key).and_then(RepoState::library_key) else {
            return false;
        };
        let added = self.library.add(&root, crate::library::now());
        let changed = self.library.set_setup(&root, setup) || added;
        self.library_changed(changed)
    }

    /// Runs the repository's setup in new worktree `path`: the main
    /// worktree's untracked files its patterns match are copied (keeping
    /// files already there), then its command runs there. It runs beside
    /// other jobs, so a long install never holds up the repository, and
    /// [`Runtime::undo_new_worktree`] cancels it. `None` when there is no
    /// setup. Label [`WORKTREE_SETUP_JOB_LABEL`]; a failed command's error
    /// holds its output.
    pub fn run_worktree_setup(&mut self, key: &Path, path: &Path) -> Option<JobId> {
        let setup = self.worktree_setup(key);
        if setup.is_empty() {
            return None;
        }
        let state = self.repos.get_mut(key).filter(|s| s.is_ready())?;
        let main = state.main_worktree()?.to_path_buf();
        // Never copy a worktree (`.worktrees/` matched) into another.
        let worktrees: Vec<PathBuf> = state
            .worktrees
            .iter()
            .flatten()
            .filter(|wt| !wt.is_main)
            .map(|wt| normalize(&wt.path))
            .chain([normalize(path)])
            .collect();
        let target = path.to_path_buf();
        let job = self.scheduler.submit(
            JobSpec::read(key, WORKTREE_SETUP_JOB_LABEL, move |ctx| {
                let (backend, cancel) = (ctx.backend(), ctx.cancel_token());
                setup_job(backend, &main, &target, &worktrees, &setup, cancel)
                    .map(|outcome| JobOutput::WorktreeSetupDone(Box::new(outcome)))
            })
            .refreshing(RefreshSet::EMPTY.with(RefreshKind::WorktreeBadges)),
        );
        state.new_worktree.setups.insert(path_key(path), job);
        Some(job)
    }

    /// Undoes the create of the worktree at `path`: stops its setup, then
    /// deletes the worktree (setup's untracked files included) and the
    /// branch if the create made it. Refused, with nothing deleted, once the
    /// worktree has changes to tracked files or its branch moved. Label
    /// [`UNDO_NEW_WORKTREE_JOB_LABEL`].
    pub fn undo_new_worktree(&mut self, key: &Path, path: &Path) -> Option<JobId> {
        let state = self.repos.get(key).filter(|s| s.is_ready())?;
        let created = state.created_at(path)?.clone();
        if let Some(setup) = state.new_worktree.setups.get(&path_key(path)) {
            self.scheduler.cancel(*setup);
        }
        let leftovers = self.leftover_worktrees.clone();
        Some(self.scheduler.submit(JobSpec::write(
            key,
            UNDO_NEW_WORKTREE_JOB_LABEL,
            worktree_refresh(),
            move |ctx| {
                let (backend, repo, cancel) = (ctx.backend(), ctx.repo(), ctx.cancel_token());
                undo_job(backend, repo, &created, &leftovers, cancel)
                    .map(|()| JobOutput::WorktreeUndone(created.path.clone()))
            },
        )))
    }

    /// Handles the create, setup and undo jobs' results; the job events
    /// themselves still go out.
    pub(super) fn apply_new_worktree_event(
        state: &mut RepoState,
        job: JobId,
        label: &str,
        kind: &EventKind,
    ) {
        let finished = matches!(kind, EventKind::Finished(_) | EventKind::Cancelled);
        match label {
            NEW_TASK_JOB_LABEL => {
                if let EventKind::Finished(Ok(JobOutput::WorktreeCreated(created))) = kind {
                    let list = &mut state.new_worktree.created;
                    list.push((job, created.as_ref().clone()));
                    let excess = list.len().saturating_sub(MAX_CREATED);
                    list.drain(..excess);
                }
            }
            WORKTREE_SETUP_JOB_LABEL if finished => {
                state.new_worktree.setups.retain(|_, id| *id != job);
            }
            UNDO_NEW_WORKTREE_JOB_LABEL => {
                if let EventKind::Finished(Ok(JobOutput::WorktreeUndone(path))) = kind {
                    let key = path_key(&normalize(path));
                    state
                        .new_worktree
                        .created
                        .retain(|(_, c)| path_key(&normalize(&c.path)) != key);
                }
            }
            _ => {}
        }
    }
}

/// The work of [`Runtime::create_worktree`].
fn create_job(
    backend: &dyn GitBackend,
    repo: &Path,
    request: &NewWorktree,
    fetch: Option<(RemoteBranch, Duration)>,
    progress: ProgressSink,
    cancel: &CancelToken,
) -> Result<CreatedWorktree, GitError> {
    let branch = request.branch.clone();
    let branch_ref = format!("refs/heads/{branch}");
    let exists = backend.resolve(repo, &branch_ref, cancel)?.is_some();
    match (&request.start, exists) {
        (WorktreeStart::Existing, false) => {
            return Err(GitError::new(
                "worktree add",
                GitErrorKind::Other,
                format!("error: branch '{branch}' not found"),
            ))
        }
        (WorktreeStart::NewBranch { .. } | WorktreeStart::Remote { .. }, true) => {
            return Err(GitError::new(
                "worktree add",
                GitErrorKind::AlreadyExists,
                format!("a branch named '{branch}' already exists"),
            ))
        }
        _ => {}
    }
    let stale = match &fetch {
        Some((remote, timeout)) => fetch_base(backend, repo, remote, *timeout, progress, cancel)?,
        None => None,
    };
    // Never fetched and the fetch failed: nothing to start from.
    if let (Some(stale), Some((remote, _))) = (&stale, &fetch) {
        if backend
            .resolve(repo, &remote.tracking_ref(), cancel)?
            .is_none()
        {
            let error = if stale.timed_out {
                format!("error: fetching {} took too long", stale.base)
            } else {
                stale.error.clone()
            };
            return Err(GitError::new(
                "fetch",
                GitErrorKind::classify("", &error),
                error,
            ));
        }
    }
    let path = free_worktree_path(&request.path);
    let (start, upstream) = match &request.start {
        WorktreeStart::NewBranch { base } => (Some(base.clone()), None),
        WorktreeStart::Existing => (None, None),
        WorktreeStart::Remote { upstream } => (Some(upstream.clone()), Some(upstream.clone())),
    };
    let created_branch = start.is_some();
    let add = WorktreeOp::Add {
        path: path.clone(),
        branch: branch.clone(),
        start,
    };
    let added = backend.worktree_op(repo, &add, cancel).and_then(|()| {
        let Some(upstream) = upstream else {
            return Ok(());
        };
        let track = RefOp::SetUpstream {
            branch: branch.clone(),
            upstream: Some(upstream),
        };
        backend.ref_op(repo, &track, cancel)
    });
    if let Err(err) = added {
        roll_back(backend, repo, &path, &branch, created_branch);
        return Err(err);
    }
    let tip = backend
        .resolve(repo, &branch_ref, cancel)?
        .unwrap_or_default();
    Ok(CreatedWorktree {
        path,
        branch,
        created_branch,
        tip,
        stale,
    })
}

/// Removes what a failed create made: the worktree if git registered it,
/// and the branch if the create made it.
fn roll_back(backend: &dyn GitBackend, repo: &Path, path: &Path, branch: &str, created: bool) {
    // Rolling back must not be cut short by a cancel.
    let restore = CancelToken::new();
    // git reports resolved paths (no symlinks or short names): compare those.
    let target = normalize(path);
    let registered = backend
        .worktrees(repo, &restore)
        .is_ok_and(|list| list.iter().any(|wt| normalize(&wt.path) == target));
    if registered {
        let remove = WorktreeOp::Remove {
            path: path.to_path_buf(),
            force: true,
        };
        let _ = backend.worktree_op(repo, &remove, &restore);
    }
    let branch_ref = format!("refs/heads/{branch}");
    if created
        && backend
            .resolve(repo, &branch_ref, &restore)
            .is_ok_and(|b| b.is_some())
    {
        let delete = RefOp::DeleteBranch {
            name: branch.to_owned(),
            force: true,
        };
        let _ = backend.ref_op(repo, &delete, &restore);
    }
}

/// Fetches the branch a create starts from. A failure, or a fetch that
/// takes longer than `timeout`, leaves the remote branch as last fetched
/// and says so; only a cancel stops the create.
fn fetch_base(
    backend: &dyn GitBackend,
    repo: &Path,
    remote: &RemoteBranch,
    timeout: Duration,
    progress: ProgressSink,
    cancel: &CancelToken,
) -> Result<Option<StaleBase>, GitError> {
    let token = CancelToken::new();
    let done = AtomicBool::new(false);
    let timed_out = AtomicBool::new(false);
    let fetch = SyncOp::FetchBranch {
        remote: remote.remote.clone(),
        branch: remote.branch.clone(),
    };
    let result = thread::scope(|scope| {
        scope.spawn(|| {
            let start = Instant::now();
            while !done.load(Ordering::Acquire) {
                if cancel.is_cancelled() {
                    token.cancel();
                    return;
                }
                if start.elapsed() >= timeout {
                    timed_out.store(true, Ordering::Release);
                    token.cancel();
                    return;
                }
                thread::sleep(Duration::from_millis(20));
            }
        });
        let result = backend.sync(repo, &fetch, progress, &token);
        done.store(true, Ordering::Release);
        result
    });
    let error = match result {
        Ok(()) => return Ok(None),
        Err(err) if cancel.is_cancelled() => return Err(err),
        Err(err) => err,
    };
    let timed_out = timed_out.load(Ordering::Acquire);
    let fetched_at = backend
        .ref_updated_at(repo, &remote.tracking_ref(), cancel)
        .ok()
        .flatten();
    Ok(Some(StaleBase {
        base: remote.short_name(),
        fetched_at,
        timed_out,
        error: if timed_out {
            String::new()
        } else {
            error.stderr.trim().to_owned()
        },
    }))
}

/// The work of [`Runtime::run_worktree_setup`].
fn setup_job(
    backend: &dyn GitBackend,
    main: &Path,
    target: &Path,
    worktrees: &[PathBuf],
    setup: &WorktreeSetup,
    cancel: &CancelToken,
) -> Result<SetupOutcome, GitError> {
    let mut outcome = SetupOutcome::default();
    if !setup.copy.is_empty() {
        let entries: Vec<PathBuf> = backend
            .untracked_by_patterns(main, &setup.copy, cancel)?
            .into_iter()
            .filter(|entry| {
                let full = normalize(&main.join(entry));
                !worktrees
                    .iter()
                    .any(|wt| wt.starts_with(&full) || full.starts_with(wt))
            })
            .collect();
        outcome.copied = copy_entries(main, target, &entries, cancel)?;
    }
    if !setup.command.is_empty() {
        outcome.output = run_command(target, &setup.command, cancel)?;
    }
    Ok(outcome)
}

/// The work of [`Runtime::undo_new_worktree`].
fn undo_job(
    backend: &dyn GitBackend,
    repo: &Path,
    created: &CreatedWorktree,
    leftovers: &Mutex<HashSet<PathBuf>>,
    cancel: &CancelToken,
) -> Result<(), GitError> {
    let refuse = |kind, message: &str| GitError::new("undo new worktree", kind, message);
    if created.path.join(".git").exists() {
        let status = backend.status(&created.path, cancel)?;
        let edited = status
            .changes
            .iter()
            .any(|c| !matches!(c.state, FileState::Untracked | FileState::Ignored));
        if edited {
            return Err(refuse(
                GitErrorKind::LocalChanges,
                "error: the worktree has changes to tracked files",
            ));
        }
    }
    let branch_ref = format!("refs/heads/{}", created.branch);
    let tip = backend.resolve(repo, &branch_ref, cancel)?;
    if created.created_branch && tip.as_deref().is_some_and(|t| t != created.tip) {
        return Err(refuse(
            GitErrorKind::Other,
            &format!("error: branch '{}' has new commits", created.branch),
        ));
    }
    // A setup just stopped may still hold files for a moment (Windows).
    let mut tries = 0;
    loop {
        match remove_worktree(backend, repo, &created.path, true, leftovers, cancel) {
            Ok(()) => break,
            Err(err) if err.kind == GitErrorKind::InUse && tries < 20 => {
                tries += 1;
                thread::sleep(Duration::from_millis(100));
            }
            // Already gone (deleted by hand): the branch can still go.
            Err(err) if err.stderr.contains("is not a working tree") => break,
            Err(err) => return Err(err),
        }
    }
    if created.created_branch && tip.is_some() {
        let delete = RefOp::DeleteBranch {
            name: created.branch.clone(),
            force: true,
        };
        backend.ref_op(repo, &delete, cancel)?;
    }
    Ok(())
}
