//! A file's history (PLAN M8a): the commits that changed one file, under
//! every name it had, each with what it did to the file.
//!
//! `git log --follow` is not used: it tracks one name at a time while it
//! walks, so it loses commits made under an old name on a branch merged
//! after the rename. Instead the path log ([`crate::path_log`]) is limited
//! to every name the file is known to have had. The first pass takes the
//! given name; when a commit added a name, the tree diff of that commit
//! with rename detection ([`GitBackend::rename_source`]) says whether it
//! was a rename, and if so the old name joins the set and one more pass
//! runs. Passes stop when no new name turns up, at [`MAX_NAMES`] names.
//!
//! A [`FileHistoryLoader`] fills its rows on a job while readers take short
//! read locks: the first pass shows its rows as they arrive, a later pass
//! replaces them at once when it ends (it lists the same commits and more).

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock, RwLockReadGuard};
use std::time::{Duration, Instant};

use crate::backend::GitBackend;
use crate::diff::{CommitSide, DiffKind, DiffTarget};
use crate::git::{CancelToken, GitError, GitErrorKind};
use crate::jobs::{JobId, JobOutput, JobScheduler, JobSpec};
use crate::path_log::PathCommit;
use crate::repo::Change;

/// Label of file-history jobs on the scheduler.
pub const FILE_HISTORY_JOB_LABEL: &str = "file history";

/// Names followed per file (the given one included).
pub const MAX_NAMES: usize = 8;

/// One commit of a file's history: the commit, and the file in it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileVersion {
    pub oid: String,
    pub parents: Vec<String>,
    pub author: String,
    pub email: String,
    /// `Co-authored-by` identities (name, email), without the author.
    pub coauthors: Vec<(String, String)>,
    /// Author time, unix seconds.
    pub time: i64,
    pub subject: String,
    /// What the commit did to the file, against its first parent.
    pub change: Change,
    /// The file's name in this commit (before it, for a deletion).
    pub path: PathBuf,
    /// The name it was renamed from in this commit.
    pub original_path: Option<PathBuf>,
    /// Lines added and removed; `None` for a binary file.
    pub stats: Option<(u32, u32)>,
}

impl FileVersion {
    /// The version `commit` holds of the file known as `names`: its first
    /// entry under one of them. `None` when it lists none.
    pub fn from_commit(commit: PathCommit, names: &[PathBuf]) -> Option<Self> {
        let file = commit.files.into_iter().find(|f| {
            names.contains(&f.path) || f.original_path.as_ref().is_some_and(|p| names.contains(p))
        })?;
        Some(Self {
            oid: commit.oid,
            parents: commit.parents,
            author: commit.author,
            email: commit.email,
            coauthors: commit.coauthors,
            time: commit.time,
            subject: commit.subject,
            change: file.change,
            path: file.path,
            original_path: file.original_path,
            stats: file.stats,
        })
    }

    /// Whether the file exists in this commit (it does not after a deletion).
    pub fn exists(&self) -> bool {
        self.change != Change::Deleted
    }

    /// The diff of the file in this commit, against its first parent.
    pub fn target(&self) -> DiffTarget {
        DiffTarget {
            kind: DiffKind::Commit,
            path: self.path.clone(),
            original_path: self.original_path.clone(),
            commit: Some(CommitSide {
                oid: self.oid.clone(),
                parent: self.parents.first().cloned(),
            }),
        }
    }
}

/// Where a load stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HistoryLoad {
    Loading,
    Done,
    Cancelled,
    Failed(GitError),
}

/// Timings and counts of a load, for the CLI and `docs/perf.md`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryProgress {
    pub rows: usize,
    pub state: HistoryLoad,
    /// Log passes run so far (one more per rename found).
    pub passes: u32,
    /// Time from the start until the first row showed.
    pub first_row: Option<Duration>,
    /// Time from the start until loading ended.
    pub total: Option<Duration>,
}

#[derive(Debug)]
struct Status {
    state: HistoryLoad,
    passes: u32,
    first_row: Option<Duration>,
    total: Option<Duration>,
}

#[derive(Debug)]
struct Shared {
    rows: RwLock<Vec<FileVersion>>,
    /// Every name the file had, the given one first.
    names: Mutex<Vec<PathBuf>>,
    /// Bumped whenever the rows, the names or the state change.
    version: AtomicU64,
    status: Mutex<Status>,
    cancel: CancelToken,
    started: Instant,
}

impl Shared {
    fn status(&self) -> std::sync::MutexGuard<'_, Status> {
        self.status.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn rows_mut(&self) -> std::sync::RwLockWriteGuard<'_, Vec<FileVersion>> {
        self.rows.write().unwrap_or_else(PoisonError::into_inner)
    }

    fn bump(&self) {
        self.version.fetch_add(1, Ordering::AcqRel);
    }
}

/// Handle to a running or finished load of a file's history. Dropping it
/// cancels the load.
#[derive(Debug)]
pub struct FileHistoryLoader {
    shared: Arc<Shared>,
}

impl FileHistoryLoader {
    /// Loads the history of `path` as reachable from `start` (a revision;
    /// an unborn `HEAD` has none) as a read job on `scheduler`.
    pub fn submit(
        scheduler: &JobScheduler,
        key: &Path,
        toplevel: PathBuf,
        start: String,
        path: PathBuf,
    ) -> (Self, JobId) {
        let loader = Self::unstarted(&path);
        let shared = Arc::clone(&loader.shared);
        let spec = JobSpec::read(key, FILE_HISTORY_JOB_LABEL, move |ctx| {
            run(ctx.backend(), &toplevel, &start, &path, &shared);
            Ok(JobOutput::Done)
        })
        .with_cancel(loader.shared.cancel.clone());
        let id = scheduler.submit(spec);
        (loader, id)
    }

    /// Loads on the calling thread. For the CLI and tests, never the UI.
    pub fn load(backend: &dyn GitBackend, toplevel: &Path, start: &str, path: &Path) -> Self {
        let loader = Self::unstarted(path);
        run(backend, toplevel, start, path, &loader.shared);
        loader
    }

    fn unstarted(path: &Path) -> Self {
        Self {
            shared: Arc::new(Shared {
                rows: RwLock::new(Vec::new()),
                names: Mutex::new(vec![path.to_path_buf()]),
                version: AtomicU64::new(0),
                status: Mutex::new(Status {
                    state: HistoryLoad::Loading,
                    passes: 0,
                    first_row: None,
                    total: None,
                }),
                cancel: CancelToken::new(),
                started: Instant::now(),
            }),
        }
    }

    /// Read access to the rows, newest first. Keep the guard short-lived:
    /// loading waits on it.
    pub fn rows(&self) -> RwLockReadGuard<'_, Vec<FileVersion>> {
        self.shared
            .rows
            .read()
            .unwrap_or_else(PoisonError::into_inner)
    }

    pub fn row_count(&self) -> usize {
        self.rows().len()
    }

    /// The version of commit `oid` (a full hash).
    pub fn version_of(&self, oid: &str) -> Option<FileVersion> {
        self.rows().iter().find(|v| v.oid == oid).cloned()
    }

    /// Where commit `oid` is among the rows.
    pub fn index_of(&self, oid: &str) -> Option<usize> {
        self.rows().iter().position(|v| v.oid == oid)
    }

    /// Every name the file had (as found so far), the given one first.
    pub fn names(&self) -> Vec<PathBuf> {
        self.shared
            .names
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Changes whenever the rows, the names or the state do.
    pub fn version(&self) -> u64 {
        self.shared.version.load(Ordering::Acquire)
    }

    pub fn state(&self) -> HistoryLoad {
        self.shared.status().state.clone()
    }

    pub fn is_loading(&self) -> bool {
        self.state() == HistoryLoad::Loading
    }

    pub fn is_done(&self) -> bool {
        self.state() == HistoryLoad::Done
    }

    pub fn error(&self) -> Option<GitError> {
        match self.state() {
            HistoryLoad::Failed(error) => Some(error),
            _ => None,
        }
    }

    pub fn progress(&self) -> HistoryProgress {
        let rows = self.row_count();
        let status = self.shared.status();
        HistoryProgress {
            rows,
            state: status.state.clone(),
            passes: status.passes,
            first_row: status.first_row,
            total: status.total,
        }
    }

    pub fn cancel(&self) {
        self.shared.cancel.cancel();
    }
}

impl Drop for FileHistoryLoader {
    fn drop(&mut self) {
        self.cancel();
    }
}

fn run(backend: &dyn GitBackend, toplevel: &Path, start: &str, path: &Path, shared: &Shared) {
    let state = match load(backend, toplevel, start, path, shared) {
        Ok(()) if shared.cancel.is_cancelled() => HistoryLoad::Cancelled,
        Ok(()) => HistoryLoad::Done,
        Err(err) if err.kind == GitErrorKind::Cancelled => HistoryLoad::Cancelled,
        Err(err) => HistoryLoad::Failed(err),
    };
    let mut status = shared.status();
    status.state = state;
    status.total = Some(shared.started.elapsed());
    drop(status);
    shared.bump();
}

fn load(
    backend: &dyn GitBackend,
    toplevel: &Path,
    start: &str,
    path: &Path,
    shared: &Shared,
) -> Result<(), GitError> {
    let cancel = &shared.cancel;
    let mut names = vec![path.to_path_buf()];
    // Commits whose added name was looked up already.
    let mut checked: HashSet<(String, PathBuf)> = HashSet::new();
    let mut first_pass = true;
    loop {
        shared.status().passes += 1;
        let mut rows: Vec<FileVersion> = Vec::new();
        // Commits that added one of the names: (commit, first parent, name).
        let mut added: Vec<(String, String, PathBuf)> = Vec::new();
        backend.path_log(toplevel, start, &names, cancel, &mut |commit| {
            let Some(version) = FileVersion::from_commit(commit, &names) else {
                return;
            };
            if version.change == Change::Added {
                if let [parent] = version.parents.as_slice() {
                    added.push((version.oid.clone(), parent.clone(), version.path.clone()));
                }
            }
            if first_pass {
                shared.rows_mut().push(version);
                let mut status = shared.status();
                if status.first_row.is_none() {
                    status.first_row = Some(shared.started.elapsed());
                }
                drop(status);
                shared.bump();
            } else {
                rows.push(version);
            }
        })?;
        if cancel.is_cancelled() {
            return Ok(());
        }
        if !first_pass {
            *shared.rows_mut() = rows;
            shared.bump();
        }
        first_pass = false;
        let mut found = false;
        for (oid, parent, name) in added {
            if names.len() >= MAX_NAMES {
                break;
            }
            if !checked.insert((oid.clone(), name.clone())) {
                continue;
            }
            let source = backend.rename_source(toplevel, &oid, &parent, &name, cancel)?;
            if let Some(old) = source.filter(|old| !names.contains(old)) {
                names.push(old);
                found = true;
            }
        }
        if !found {
            return Ok(());
        }
        *shared.names.lock().unwrap_or_else(PoisonError::into_inner) = names.clone();
        shared.bump();
    }
}
