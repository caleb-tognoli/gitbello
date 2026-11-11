//! Blame (PLAN M8b): who last changed each line of the file a worktree's
//! file history shows, as one of its versions has it.
//!
//! The blamed version is one of the history's ([`Runtime::blame_file_version`]);
//! a commit of the blame can be focused, which loads its details. The
//! working copy's blame runs again after a status refresh when the file or
//! HEAD changed; a commit's never does.

use std::time::SystemTime;

use super::*;
use crate::blame::{BlameLoad, BlameLoader, BlameOptions, BlameRequest, BlameTable};

pub use crate::blame::BLAME_JOB_LABEL;

pub const BLAME_COMMIT_JOB_LABEL: &str = "load blame commit";
pub const BLAME_VERSION_JOB_LABEL: &str = "find blamed version";

/// What the working copy's blame read, cheap to compare: HEAD and the
/// file's size and modification time.
type WorkingStamp = (Option<String>, Option<(u64, Option<SystemTime>)>);

/// A blame and what is focused in it.
#[derive(Debug)]
pub struct BlameState {
    request: BlameRequest,
    loader: BlameLoader,
    /// The loader's version when last reported.
    reported: u64,
    /// The commit whose lines are highlighted and whose details show.
    focus: Option<String>,
    /// The focused commit, once read.
    details: Option<CommitDetails>,
    /// What a working copy's blame read (`None` for a commit's).
    stamp: Option<WorkingStamp>,
}

impl BlameState {
    pub fn request(&self) -> &BlameRequest {
        &self.request
    }

    /// The lines and their blocks. Keep the guard short-lived.
    pub fn table(&self) -> std::sync::RwLockReadGuard<'_, BlameTable> {
        self.loader.table()
    }

    pub fn load(&self) -> BlameLoad {
        self.loader.state()
    }

    /// The focused commit's hash.
    pub fn focus(&self) -> Option<&str> {
        self.focus.as_deref()
    }

    /// The focused commit (its message, people and parents), once it
    /// loaded. Lines not committed yet have none.
    pub fn details(&self) -> Option<&CommitDetails> {
        let focus = self.focus.as_deref()?;
        self.details.as_ref().filter(|d| d.oid == focus)
    }
}

impl RepoState {
    /// The blame started with [`Runtime::blame_file_version`].
    pub fn blame(&self) -> Option<&BlameState> {
        self.blame.as_ref()
    }
}

fn working_stamp(state: &RepoState, path: &Path) -> WorkingStamp {
    let head = state.status.as_ref().and_then(|s| s.oid.clone());
    let file = state.toplevel.as_ref().and_then(|toplevel| {
        fs::metadata(toplevel.join(path))
            .ok()
            .map(|m| (m.len(), m.modified().ok()))
    });
    (head, file)
}

impl Runtime {
    /// Blames the file of the open file history as `selection` has it: a
    /// version's commit, under the name the file had there, or the working
    /// copy. Lines arrive as [`RuntimeEvent::BlameChanged`]. The same
    /// blame is kept; a version without the file (its deleting commit)
    /// closes the blame.
    pub fn blame_file_version(
        &mut self,
        key: &Path,
        selection: &FileSelection,
        options: BlameOptions,
    ) {
        let Some(state) = self.repos.get_mut(key).filter(|s| s.is_ready()) else {
            return;
        };
        let Some(toplevel) = state.toplevel.clone() else {
            return;
        };
        let request = state.file_history.as_ref().and_then(|history| {
            let (rev, path) = match selection {
                FileSelection::Working => {
                    if history.request().start.is_some() {
                        return None;
                    }
                    (None, history.request().path.clone())
                }
                FileSelection::Version(oid) => {
                    let version = history.version_of(oid).filter(|v| v.exists())?;
                    (Some(version.oid), version.path)
                }
            };
            Some(BlameRequest { rev, path, options })
        });
        let Some(request) = request else {
            if state.blame.take().is_some() {
                self.pending.push(RuntimeEvent::BlameChanged {
                    repo: key.to_path_buf(),
                });
            }
            return;
        };
        let kept = state.blame.as_ref().is_some_and(|blame| {
            blame.request == request
                && !matches!(blame.load(), BlameLoad::Failed(_) | BlameLoad::Cancelled)
        });
        if kept {
            return;
        }
        let stamp = request
            .rev
            .is_none()
            .then(|| working_stamp(state, &request.path));
        let (loader, _) = BlameLoader::submit(&self.scheduler, key, toplevel, request.clone());
        // The focus stays across blames of one file: the commit may be in
        // the next one too.
        let (focus, details) = match state.blame.take() {
            Some(old) => (old.focus, old.details),
            None => (None, None),
        };
        state.blame = Some(BlameState {
            request,
            loader,
            reported: 0,
            focus,
            details,
            stamp,
        });
        self.pending.push(RuntimeEvent::BlameChanged {
            repo: key.to_path_buf(),
        });
    }

    /// Ends the blame; its load is cancelled.
    pub fn close_blame(&mut self, key: &Path) {
        if let Some(state) = self.repos.get_mut(key) {
            state.blame = None;
        }
    }

    /// Focuses commit `oid` of the blame (`None` for none) and reads its
    /// details; [`RuntimeEvent::BlameChanged`] follows.
    pub fn focus_blame_commit(&mut self, key: &Path, oid: Option<&str>) {
        let Some(blame) = self.repos.get_mut(key).and_then(|s| s.blame.as_mut()) else {
            return;
        };
        if blame.focus.as_deref() == oid {
            return;
        }
        blame.focus = oid.map(str::to_owned);
        let committed = oid.filter(|oid| !oid.bytes().all(|b| b == b'0'));
        if let Some(oid) = committed.filter(|_| blame.details().is_none()) {
            let oid = oid.to_owned();
            self.scheduler
                .submit(JobSpec::read(key, BLAME_COMMIT_JOB_LABEL, move |ctx| {
                    ctx.backend()
                        .commit_details(ctx.repo(), &oid, ctx.cancel_token())
                        .map(|details| JobOutput::Commit(Box::new(details)))
                }));
        }
        self.pending.push(RuntimeEvent::BlameChanged {
            repo: key.to_path_buf(),
        });
    }

    /// Finds the version of the file that line `line` (0-based) of the
    /// blame came from: the newest commit of the file's history reached by
    /// the commit the line's block names as previous.
    /// [`RuntimeEvent::BlameVersionFound`] carries it. `None` when the
    /// line's commit added it with the file.
    pub fn blame_before(&mut self, key: &Path, line: usize) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get(key)?;
        let (rev, path) = state
            .blame
            .as_ref()?
            .table()
            .block_of(line)?
            .previous
            .clone()?;
        let mut paths = state
            .file_history
            .as_ref()
            .map(|h| h.names())
            .unwrap_or_default();
        if !paths.contains(&path) {
            paths.push(path);
        }
        Some(
            self.scheduler
                .submit(JobSpec::read(key, BLAME_VERSION_JOB_LABEL, move |ctx| {
                    ctx.backend()
                        .last_change(&toplevel, &rev, &paths, ctx.cancel_token())
                        .map(JobOutput::BlamedVersion)
                })),
        )
    }

    /// Reports the blames that have more lines or ended.
    pub(super) fn advance_blames(&mut self, out: &mut Vec<RuntimeEvent>) {
        for state in self.repos.values_mut() {
            let Some(blame) = state.blame.as_mut() else {
                continue;
            };
            let version = blame.loader.version();
            if version != blame.reported {
                blame.reported = version;
                out.push(RuntimeEvent::BlameChanged {
                    repo: state.key.clone(),
                });
            }
        }
    }
}

/// After a status refresh: the working copy's blame runs again when HEAD
/// or the file changed since it was read.
pub(super) fn blame_after_status(
    scheduler: &JobScheduler,
    state: &mut RepoState,
    out: &mut Vec<RuntimeEvent>,
) {
    let Some(request) = state
        .blame
        .as_ref()
        .filter(|b| b.stamp.is_some())
        .map(|b| b.request.clone())
    else {
        return;
    };
    let stamp = working_stamp(state, &request.path);
    let Some(toplevel) = state.toplevel.clone() else {
        return;
    };
    let key = state.key.clone();
    let Some(blame) = state.blame.as_mut() else {
        return;
    };
    if blame.stamp.as_ref() == Some(&stamp) {
        return;
    }
    let (loader, _) = BlameLoader::submit(scheduler, &key, toplevel, request);
    blame.loader = loader;
    blame.reported = 0;
    blame.stamp = Some(stamp);
    out.push(RuntimeEvent::BlameChanged { repo: key });
}

/// Stores the focused commit when it is still the focused one.
pub(super) fn apply_blame_commit(
    state: &mut RepoState,
    kind: EventKind,
    repo: &Path,
    out: &mut Vec<RuntimeEvent>,
) {
    let EventKind::Finished(Ok(JobOutput::Commit(details))) = kind else {
        return;
    };
    let Some(blame) = state.blame.as_mut() else {
        return;
    };
    if blame.focus.as_deref() == Some(details.oid.as_str()) {
        blame.details = Some(*details);
        out.push(RuntimeEvent::BlameChanged {
            repo: repo.to_path_buf(),
        });
    }
}

/// Reports the version [`Runtime::blame_before`] looked for.
pub(super) fn apply_blamed_version(kind: EventKind, repo: &Path, out: &mut Vec<RuntimeEvent>) {
    let oid = match kind {
        EventKind::Finished(Ok(JobOutput::BlamedVersion(oid))) => oid,
        EventKind::Finished(_) => None,
        _ => return,
    };
    out.push(RuntimeEvent::BlameVersionFound {
        repo: repo.to_path_buf(),
        oid,
    });
}
