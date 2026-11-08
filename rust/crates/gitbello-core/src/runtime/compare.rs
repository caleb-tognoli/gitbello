//! Compare (PLAN M7.12): the comparison a worktree shows, the commit it is
//! narrowed to, its file filter and the diff of the selected file
//! ([`DiffSlot::Compare`]). A working-copy side follows the status and ref
//! sides follow the refs; Restore writes a side's files into the worktree.

use super::*;
use crate::compare::{
    filter_files, CompareCommit, CompareFile, CompareMode, CompareRequest, CompareSide, Comparison,
    OnlyOn, SideKind,
};

pub const COMPARE_JOB_LABEL: &str = "compare";
pub const COMPARE_COMMIT_JOB_LABEL: &str = "load compare commit";
pub const COMPARE_DIFF_JOB_LABEL: &str = "load compare diff";
pub const RESTORE_FROM_JOB_LABEL: &str = "restore from revision";

/// One commit of the comparison whose own files are shown instead of the
/// whole comparison's.
#[derive(Debug, Clone)]
struct Focus {
    oid: String,
    generation: u64,
    loading: bool,
    result: Option<Comparison>,
    /// The commit's summary, people, message and refs, for its details.
    details: Option<CommitDetails>,
    error: Option<GitError>,
}

/// A comparison and its loading state.
#[derive(Debug, Clone)]
pub struct CompareState {
    request: CompareRequest,
    generation: u64,
    loading: bool,
    /// The last loaded result (kept while a reload runs).
    result: Option<Comparison>,
    error: Option<GitError>,
    filter: String,
    /// Indices into the shown comparison's files that the filter shows.
    shown: Vec<usize>,
    focus: Option<Focus>,
}

impl CompareState {
    fn new(request: CompareRequest) -> Self {
        Self {
            request,
            generation: 0,
            loading: false,
            result: None,
            error: None,
            filter: String::new(),
            shown: Vec::new(),
            focus: None,
        }
    }

    pub fn request(&self) -> &CompareRequest {
        &self.request
    }

    /// The whole comparison.
    pub fn comparison(&self) -> Option<&Comparison> {
        self.result.as_ref()
    }

    pub fn is_loading(&self) -> bool {
        self.loading
    }

    pub fn error(&self) -> Option<&GitError> {
        self.error.as_ref()
    }

    pub fn filter(&self) -> &str {
        &self.filter
    }

    /// The commit the files are narrowed to.
    pub fn focus(&self) -> Option<&str> {
        self.focus.as_ref().map(|f| f.oid.as_str())
    }

    pub fn focus_loading(&self) -> bool {
        self.focus.as_ref().is_some_and(|f| f.loading)
    }

    pub fn focus_error(&self) -> Option<&GitError> {
        self.focus.as_ref().and_then(|f| f.error.as_ref())
    }

    /// The focused commit's details, once loaded.
    pub fn focus_details(&self) -> Option<&CommitDetails> {
        self.focus.as_ref().and_then(|f| f.details.as_ref())
    }

    /// What the file list shows: the focused commit's files, else the
    /// whole comparison's.
    pub fn shown_comparison(&self) -> Option<&Comparison> {
        match &self.focus {
            Some(focus) => focus.result.as_ref(),
            None => self.result.as_ref(),
        }
    }

    /// The files the filter shows.
    pub fn shown_count(&self) -> usize {
        self.shown.len()
    }

    pub fn shown_file(&self, index: usize) -> Option<&CompareFile> {
        self.shown_comparison()?.files.get(*self.shown.get(index)?)
    }

    /// Where `path` is among the shown files.
    pub fn shown_index(&self, path: &Path) -> Option<usize> {
        let result = self.shown_comparison()?;
        self.shown
            .iter()
            .position(|&i| result.files.get(i).is_some_and(|f| f.path == path))
    }

    /// Commits only on one side (right side first).
    pub fn commit_count(&self) -> usize {
        self.result.as_ref().map_or(0, |r| r.commits.len())
    }

    pub fn commit(&self, index: usize) -> Option<&CompareCommit> {
        self.result.as_ref()?.commits.get(index)
    }

    pub fn commit_index(&self, oid: &str) -> Option<usize> {
        self.result
            .as_ref()?
            .commits
            .iter()
            .position(|c| c.oid == oid)
    }

    fn refilter(&mut self) {
        self.shown = match self.shown_comparison() {
            Some(result) => filter_files(&result.files, &self.filter),
            None => Vec::new(),
        };
    }
}

impl RepoState {
    /// The comparison opened with [`Runtime::open_compare`].
    pub fn compare(&self) -> Option<&CompareState> {
        self.compare.as_ref()
    }

    /// The diff of the selected file of the comparison.
    pub fn compare_diff(&self) -> Option<&DiffState> {
        self.compare_diff.as_ref()
    }
}

impl Runtime {
    /// Opens a comparison, replacing any other; it arrives as
    /// [`RuntimeEvent::CompareChanged`]. Clears the compare diff.
    pub fn open_compare(&mut self, key: &Path, request: CompareRequest) {
        let Some(state) = self.repos.get_mut(key).filter(|s| s.is_ready()) else {
            return;
        };
        state.compare = Some(CompareState::new(request));
        state.compare_diff = None;
        self.diff_generation += 1;
        submit_compare(&self.scheduler, state, self.diff_generation);
    }

    /// Changes the mode of the open comparison (`None`: its default),
    /// keeping its filter and the old result until the new one arrives.
    pub fn set_compare_mode(&mut self, key: &Path, mode: Option<CompareMode>) {
        let Some(state) = self.repos.get_mut(key) else {
            return;
        };
        let Some(compare) = state.compare.as_mut() else {
            return;
        };
        if compare.request.mode == mode {
            return;
        }
        compare.request.mode = mode;
        self.diff_generation += 1;
        submit_compare(&self.scheduler, state, self.diff_generation);
    }

    /// Reads the open comparison again (after an error, or when the sides moved).
    pub fn reload_compare(&mut self, key: &Path) {
        let Some(state) = self.repos.get_mut(key).filter(|s| s.compare.is_some()) else {
            return;
        };
        self.diff_generation += 1;
        submit_compare(&self.scheduler, state, self.diff_generation);
    }

    pub fn close_compare(&mut self, key: &Path) {
        if let Some(state) = self.repos.get_mut(key) {
            state.compare = None;
            state.compare_diff = None;
        }
    }

    /// Shows the files whose path contains `text` (any case).
    pub fn set_compare_filter(&mut self, key: &Path, text: &str) {
        let Some(compare) = self.repos.get_mut(key).and_then(|s| s.compare.as_mut()) else {
            return;
        };
        if compare.filter != text {
            compare.filter = text.to_owned();
            compare.refilter();
        }
    }

    /// Narrows the files to those commit `oid` changed (against its first
    /// parent), or back to the whole comparison with `None`; the commit's
    /// files arrive as [`RuntimeEvent::CompareChanged`].
    pub fn focus_compare_commit(&mut self, key: &Path, oid: Option<&str>) {
        let Some(state) = self.repos.get_mut(key) else {
            return;
        };
        let Some(compare) = state.compare.as_mut() else {
            return;
        };
        if compare.focus() == oid {
            return;
        }
        let Some(oid) = oid else {
            compare.focus = None;
            compare.refilter();
            drop_stale_diff(state);
            return;
        };
        self.diff_generation += 1;
        let generation = self.diff_generation;
        compare.focus = Some(Focus {
            oid: oid.to_owned(),
            generation,
            loading: true,
            result: None,
            details: None,
            error: None,
        });
        compare.refilter();
        let (key, oid) = (state.key.clone(), oid.to_owned());
        let Some(toplevel) = state.toplevel.clone() else {
            return;
        };
        self.scheduler
            .submit(JobSpec::read(&key, COMPARE_COMMIT_JOB_LABEL, move |ctx| {
                let backend = ctx.backend();
                let comparison = backend.compare_commit(&toplevel, &oid, ctx.cancel_token())?;
                let details = backend.commit_details(ctx.repo(), &oid, ctx.cancel_token())?;
                Ok(JobOutput::Compare {
                    generation,
                    comparison: Box::new(comparison),
                    details: Some(Box::new(details)),
                })
            }));
    }

    /// Shows the diff of `path` among the shown files (or nothing).
    pub fn select_compare_file(&mut self, key: &Path, path: Option<&Path>, full: bool) {
        let target = path.and_then(|path| {
            let result = self.repos.get(key)?.compare.as_ref()?.shown_comparison()?;
            Some(result.target(result.file(path)?))
        });
        self.select_slot(key, DiffSlot::Compare, target, full);
    }

    /// Writes `paths` as the `side` of the comparison has them into the
    /// working copy (a path that side lacks is deleted; a rename restores
    /// both names). The files are backed up first: [`Runtime::undo_discard`]
    /// puts them back. `None` when that side is the working copy.
    pub fn restore_compare_files(
        &mut self,
        key: &Path,
        paths: &[PathBuf],
        side: OnlyOn,
    ) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let compare = self.repos.get(key)?.compare.as_ref()?;
        let shown = compare.shown_comparison()?;
        let oid = match side {
            // A narrowed commit's left side is its parent.
            OnlyOn::Left => shown.left.oid.clone()?,
            OnlyOn::Right if shown.right.kind == SideKind::WorkingCopy => return None,
            OnlyOn::Right => shown.right.oid.clone()?,
        };
        let mut restore: Vec<PathBuf> = Vec::new();
        for path in paths {
            let original = shown.file(path).and_then(|f| f.original_path.clone());
            for p in std::iter::once(path.clone()).chain(original) {
                if !restore.contains(&p) {
                    restore.push(p);
                }
            }
        }
        if restore.is_empty() {
            return None;
        }
        Some(self.scheduler.submit(JobSpec::write(
            key,
            RESTORE_FROM_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                let backups =
                    ctx.backend()
                        .restore_from(&toplevel, &oid, &restore, ctx.cancel_token())?;
                Ok(JobOutput::Discarded(backups))
            },
        )))
    }
}

/// After a status refresh (changed or not: a file can change without its
/// status changing): a working-copy side is read again, and so is its diff.
pub(super) fn compare_after_status(
    scheduler: &JobScheduler,
    state: &mut RepoState,
    generation: &mut u64,
) {
    let working = state
        .compare
        .as_ref()
        .is_some_and(|c| c.request.right == CompareSide::WorkingCopy);
    if !working {
        return;
    }
    *generation += 1;
    submit_compare(scheduler, state, *generation);
    let working_diff = state
        .compare_diff
        .as_ref()
        .is_some_and(|d| matches!(d.target.kind, DiffKind::Working | DiffKind::Untracked));
    if working_diff {
        reload_slot_diff(scheduler, state, DiffSlot::Compare, generation);
    }
}

/// After the refs changed: ref sides may point elsewhere now.
pub(super) fn compare_after_refs(
    scheduler: &JobScheduler,
    state: &mut RepoState,
    generation: &mut u64,
) {
    if state.compare.is_some() {
        *generation += 1;
        submit_compare(scheduler, state, *generation);
    }
}

fn submit_compare(scheduler: &JobScheduler, state: &mut RepoState, generation: u64) {
    let key = state.key.clone();
    let (Some(toplevel), Some(compare)) = (state.toplevel.clone(), state.compare.as_mut()) else {
        return;
    };
    compare.generation = generation;
    compare.loading = true;
    let request = compare.request.clone();
    scheduler.submit(JobSpec::read(&key, COMPARE_JOB_LABEL, move |ctx| {
        let comparison = ctx
            .backend()
            .compare(&toplevel, &request, ctx.cancel_token())?;
        Ok(JobOutput::Compare {
            generation,
            comparison: Box::new(comparison),
            details: None,
        })
    }));
}

/// Stores a finished comparison (`label` [`COMPARE_JOB_LABEL`]) or a
/// focused commit's files ([`COMPARE_COMMIT_JOB_LABEL`]) if it is still the
/// current one. A selected file that is no longer shown loses its diff. A
/// focused commit that left the comparison is dropped.
pub(super) fn apply_compare(
    state: &mut RepoState,
    label: &str,
    kind: EventKind,
    repo: &Path,
    out: &mut Vec<RuntimeEvent>,
) {
    let Some(compare) = state.compare.as_mut() else {
        return;
    };
    if label == COMPARE_COMMIT_JOB_LABEL {
        let Some(focus) = compare.focus.as_mut() else {
            return;
        };
        match kind {
            EventKind::Finished(Ok(JobOutput::Compare {
                generation,
                comparison,
                details,
            })) if generation == focus.generation => {
                focus.loading = false;
                focus.error = None;
                focus.result = Some(*comparison);
                focus.details = details.map(|d| *d);
            }
            EventKind::Finished(Err(error))
                if error.kind != GitErrorKind::Cancelled && focus.loading =>
            {
                focus.loading = false;
                focus.error = Some(error);
            }
            _ => return,
        }
    } else {
        match kind {
            EventKind::Finished(Ok(JobOutput::Compare {
                generation,
                comparison,
                ..
            })) if generation == compare.generation => {
                compare.loading = false;
                compare.error = None;
                compare.result = Some(*comparison);
                let gone = compare
                    .focus()
                    .is_some_and(|oid| compare.commit_index(oid).is_none());
                if gone {
                    compare.focus = None;
                }
            }
            EventKind::Finished(Err(error))
                if error.kind != GitErrorKind::Cancelled && compare.loading =>
            {
                compare.loading = false;
                compare.error = Some(error);
            }
            _ => return,
        }
    }
    compare.refilter();
    drop_stale_diff(state);
    out.push(RuntimeEvent::CompareChanged {
        repo: repo.to_path_buf(),
    });
}

/// Clears the compare diff when its file is no longer shown, or shows it
/// against other sides now.
fn drop_stale_diff(state: &mut RepoState) {
    let stale = state.compare_diff.as_ref().is_some_and(|diff| {
        let target = diff.target();
        state
            .compare
            .as_ref()
            .and_then(CompareState::shown_comparison)
            .and_then(|r| r.file(&target.path).map(|f| r.target(f)))
            .is_none_or(|current| &current != target)
    });
    if stale {
        state.compare_diff = None;
    }
}
