use super::*;
use crate::backend::AmendSnapshot;
use crate::changes::CommitPlan;

pub(super) const AMEND_JOB_LABEL: &str = "prepare amend";
const AMEND_REFRESH_JOB_LABEL: &str = "refresh amend";

pub(super) struct AmendSession {
    job: JobId,
    branch: Head,
    pub(super) saved_selection: Selection,
    pub(super) snapshot: Option<AmendSnapshot>,
    generation: u64,
    refresh_job: Option<JobId>,
    loading: bool,
    error: Option<GitError>,
}

impl RepoState {
    pub fn changes_status(&self) -> Option<&RepoStatus> {
        self.amend
            .as_ref()
            .and_then(|a| a.snapshot.as_ref())
            .map(|a| &a.status)
            .or(self.listed.as_ref())
            .or(self.status.as_ref())
    }

    pub fn is_amending(&self) -> bool {
        self.amend.is_some()
    }

    pub fn amend_requires_force_push(&self) -> bool {
        let Some(head) = self.status.as_ref().and_then(|s| s.oid.as_deref()) else {
            return false;
        };
        self.refs.as_ref().is_some_and(|refs| {
            refs.iter()
                .any(|r| matches!(r.kind, RefKind::RemoteBranch { .. }) && r.target == head)
        }) || self.history_tracking().is_some_and(|info| {
            info.upstream.is_some() && !info.upstream_gone && !info.outgoing.contains(head)
        })
    }

    pub fn in_amended_commit(&self, path: &Path) -> bool {
        self.amend
            .as_ref()
            .and_then(|a| a.snapshot.as_ref())
            .is_some_and(|a| a.original_paths.iter().any(|p| p == path))
    }

    pub(super) fn change_target(&self, path: &Path) -> Option<DiffTarget> {
        let mut target = changes::diff_target(self.changes_status()?, path);
        if let Some(snapshot) = self.amend.as_ref().and_then(|a| a.snapshot.as_ref()) {
            // A rename keeps its source (from `diff_target`).
            target.kind = DiffKind::Amend;
            target.commit = Some(CommitSide {
                oid: snapshot.tree.clone(),
                parent: Some(snapshot.base.clone()),
            });
        }
        Some(target)
    }

    pub(super) fn end_amend(&mut self) {
        if let Some(amend) = self.amend.take() {
            self.selection = amend.saved_selection;
            if let Some(status) = &self.status {
                self.selection.reconcile(status);
            }
            self.diff = None;
            self.diff_picks.clear();
            self.rebuild_changes();
        }
    }

    pub(super) fn amend_block_reason(&self, amend: bool) -> Option<&'static str> {
        let session = self.amend.as_ref()?;
        if !amend {
            return Some("Finish or cancel amend first");
        }
        if session.error.is_some() {
            return Some("Could not refresh amend. Cancel and try again.");
        }
        if session.loading || session.snapshot.is_none() {
            return Some("Reading the changes");
        }
        let snapshot = session.snapshot.as_ref()?;
        if self.status.as_ref().is_none_or(|status| {
            status.oid.as_deref() != Some(snapshot.head.as_str()) || status.head != session.branch
        }) {
            return Some("The last commit changed. Start amend again.");
        }
        None
    }
}

impl Runtime {
    pub fn begin_amend(&mut self, key: &Path, expected_head: &str) -> Option<JobId> {
        let state = self.repos.get(key)?;
        let status = state.status()?;
        if state.amend.is_some()
            || state.operation.is_some()
            || status.has_conflicts()
            || status.oid.as_deref() != Some(expected_head)
        {
            return None;
        }
        let toplevel = state.toplevel.clone()?;
        let head = expected_head.to_owned();
        let plan = state.selection.plan(status);
        let branch = status.head.clone();
        let saved_selection = state.selection.clone();
        let job = self.scheduler.submit(JobSpec::write(
            key,
            AMEND_JOB_LABEL,
            RefreshSet::EMPTY,
            move |ctx| {
                let (backend, cancel) = (ctx.backend(), ctx.cancel_token());
                let write = selection_write(backend, &toplevel, plan, cancel)?;
                backend
                    .prepare_amend(&toplevel, &head, &write, cancel)
                    .map(|snapshot| JobOutput::Amend(Box::new(snapshot)))
            },
        ));
        self.repos.get_mut(key)?.amend = Some(AmendSession {
            job,
            branch,
            saved_selection,
            snapshot: None,
            generation: 0,
            refresh_job: None,
            loading: true,
            error: None,
        });
        Some(job)
    }

    pub fn cancel_amend(&mut self, key: &Path) {
        if let Some(state) = self.repos.get_mut(key) {
            state.end_amend();
            self.pending.push(RuntimeEvent::SelectionChanged {
                repo: key.to_path_buf(),
            });
            self.pending.push(RuntimeEvent::Updated {
                repo: key.to_path_buf(),
                kind: RefreshKind::Status,
            });
            self.pending.push(RuntimeEvent::DiffChanged {
                repo: key.to_path_buf(),
                slot: DiffSlot::Changes,
            });
        }
    }
}

pub(super) fn selection_write(
    backend: &dyn GitBackend,
    repo: &Path,
    plan: CommitPlan,
    cancel: &CancelToken,
) -> Result<IndexWrite, GitError> {
    let paths = plan.paths();
    let mut patches = Vec::with_capacity(plan.lines.len());
    for (target, keys) in &plan.lines {
        let diff = backend.diff(repo, target, None, cancel)?;
        let git_path = target.path.to_string_lossy().replace('\\', "/");
        patches.push(
            changes::lines_patch(&diff, &git_path, keys)
                .ok_or_else(|| picks_stale(&target.path))?,
        );
    }
    Ok(IndexWrite {
        whole: plan.whole,
        staged: plan.staged,
        patches,
        paths,
        ..IndexWrite::default()
    })
}

pub(super) fn refresh_amend(scheduler: &JobScheduler, state: &mut RepoState) {
    let Some(session) = &mut state.amend else {
        return;
    };
    let Some(snapshot) = &session.snapshot else {
        return;
    };
    let Some(repo) = state.toplevel.clone() else {
        return;
    };
    let mut snapshot = snapshot.clone();
    snapshot.status.changes.clear();
    session.generation += 1;
    session.loading = true;
    let generation = session.generation;
    session.refresh_job = Some(scheduler.submit(JobSpec::read(
        &state.key,
        AMEND_REFRESH_JOB_LABEL,
        move |ctx| {
            ctx.backend()
                .amend_changes(&repo, &snapshot, ctx.cancel_token())
                .map(|status| JobOutput::AmendChanges { generation, status })
        },
    )));
}

pub(super) fn apply_amend(
    state: &mut RepoState,
    label: &str,
    job: JobId,
    kind: &EventKind,
    repo: &Path,
    out: &mut Vec<RuntimeEvent>,
) -> bool {
    if label != AMEND_JOB_LABEL && label != AMEND_REFRESH_JOB_LABEL {
        return false;
    }
    let Some(session) = &mut state.amend else {
        return label == AMEND_REFRESH_JOB_LABEL;
    };
    if (label == AMEND_JOB_LABEL && session.job != job)
        || (label == AMEND_REFRESH_JOB_LABEL && session.refresh_job != Some(job))
    {
        return true;
    }
    match kind {
        EventKind::Finished(Ok(JobOutput::Amend(snapshot))) => {
            if state.status.as_ref().is_none_or(|s| {
                s.oid.as_deref() != Some(snapshot.head.as_str()) || s.head != session.branch
            }) {
                state.end_amend();
                return false;
            }
            let snapshot = snapshot.as_ref().clone();
            state.selection = Selection::default();
            state.selection.reconcile(&snapshot.status);
            let excluded: Vec<PathBuf> = snapshot
                .status
                .changes
                .iter()
                .filter(|c| !c.is_staged())
                .map(|c| c.path.clone())
                .collect();
            state.selection.pick_files(&excluded, false);
            let message = snapshot.message.clone();
            session.snapshot = Some(snapshot);
            session.loading = false;
            state.diff = None;
            state.rebuild_changes();
            out.push(RuntimeEvent::HeadMessage {
                repo: repo.to_path_buf(),
                message,
            });
        }
        EventKind::Finished(Ok(JobOutput::AmendChanges { generation, status })) => {
            if *generation != session.generation {
                return true;
            }
            session.loading = false;
            session.error = None;
            if let Some(snapshot) = &mut session.snapshot {
                state.selection.reconcile(status);
                snapshot.status = status.clone();
            }
            state.rebuild_changes();
        }
        EventKind::Finished(Err(error)) => {
            session.loading = false;
            session.error = Some(error.clone());
            if label == AMEND_REFRESH_JOB_LABEL {
                out.push(RuntimeEvent::RefreshFailed {
                    repo: repo.to_path_buf(),
                    kind: RefreshKind::Status,
                    error: error.clone(),
                });
            }
            return false;
        }
        _ => return false,
    }
    refresh_diff_picks(state);
    out.push(RuntimeEvent::SelectionChanged {
        repo: repo.to_path_buf(),
    });
    out.push(RuntimeEvent::Updated {
        repo: repo.to_path_buf(),
        kind: RefreshKind::Status,
    });
    false
}
