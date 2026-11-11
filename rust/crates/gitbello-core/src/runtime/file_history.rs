//! File history (PLAN M8a): the history a worktree shows of one file, the
//! version selected in it and that version's diff ([`DiffSlot::File`]).
//!
//! A history read from HEAD follows it: when HEAD moves, the history loads
//! again behind the rows shown and replaces them once it is done; its
//! Uncommitted changes row follows the status. A history read from a fixed
//! commit never reloads.
//!
//! A filter ([`Runtime::set_file_history_filter`]) narrows the rows to the
//! commits whose subject, people or hash match its text; the Uncommitted
//! changes row hides meanwhile.

use std::borrow::Cow;

use super::*;
use crate::changes;
use crate::file_history::{FileHistoryLoader, FileVersion};
use crate::graph::{contains_folded, MIN_HASH_DIGITS};

pub use crate::file_history::FILE_HISTORY_JOB_LABEL;

pub const FILE_DIFF_JOB_LABEL: &str = "load file history diff";
pub const FILE_COMMIT_JOB_LABEL: &str = "load file history commit";
pub const FILE_STATS_JOB_LABEL: &str = "count file history changes";

/// Which file's history, read from where.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileHistoryRequest {
    /// The file as it is named where the history starts (in the working
    /// copy, for a history read from HEAD).
    pub path: PathBuf,
    /// The revision the history is read from; `None` for HEAD, which the
    /// history then follows.
    pub start: Option<String>,
    /// What the view calls a fixed start (a branch, a tag, a commit's
    /// subject); empty for HEAD.
    pub start_name: String,
}

/// What is selected in a file's history.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileSelection {
    /// The Uncommitted changes row.
    Working,
    /// The version of this commit.
    Version(String),
}

/// The Uncommitted changes row of a file history: what the working copy
/// does to the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkingVersion {
    /// As [`changes::change_code`]: `M`, `A`, `D`, `R`, `?`, `U`…
    pub code: &'static str,
    /// The name a rename that is not committed yet comes from.
    pub original_path: Option<PathBuf>,
    /// Lines added and removed, once counted; `None` also for a binary or
    /// conflicted file.
    pub stats: Option<(u32, u32)>,
}

/// The rows a filter keeps.
#[derive(Debug)]
struct VersionFilter {
    /// The text as typed, trimmed.
    query: String,
    /// The text lowercased.
    needle: String,
    /// Where the matching versions are among the loader's rows, as of
    /// `stamp`.
    shown: Vec<u32>,
    /// `(swaps, loader version)` when `shown` was computed.
    stamp: (u64, u64),
}

impl VersionFilter {
    fn matches(&self, version: &FileVersion) -> bool {
        let needle = self.needle.as_str();
        contains_folded(&version.subject, needle)
            || contains_folded(&version.author, needle)
            || contains_folded(&version.email, needle)
            || version.coauthors.iter().any(|(name, email)| {
                contains_folded(name, needle) || contains_folded(email, needle)
            })
            || (needle.len() >= MIN_HASH_DIGITS
                && needle.bytes().all(|b| b.is_ascii_hexdigit())
                && version.oid.starts_with(needle))
    }

    fn positions(&self, rows: &[FileVersion]) -> Vec<u32> {
        rows.iter()
            .enumerate()
            .filter(|(_, version)| self.matches(version))
            .filter_map(|(i, _)| u32::try_from(i).ok())
            .collect()
    }
}

/// A file's history and its loading state.
#[derive(Debug)]
pub struct FileHistoryState {
    request: FileHistoryRequest,
    /// The name the log starts from: the request's, or the source of a
    /// rename that is not committed yet.
    log_path: PathBuf,
    loader: FileHistoryLoader,
    /// A reload running behind `loader`; it replaces it once it ended.
    next: Option<FileHistoryLoader>,
    /// HEAD when the newest load started (histories read from HEAD).
    head: Option<String>,
    /// Bumped when a reload replaces the rows.
    swaps: u64,
    /// `(swaps, loader version, loading)` when last reported.
    reported: (u64, u64, bool),
    selected: Option<FileSelection>,
    /// The selected version's commit, once read.
    details: Option<CommitDetails>,
    /// Lines of the uncommitted changes, once counted.
    working_stats: Option<(u32, u32)>,
    filter: Option<VersionFilter>,
}

impl FileHistoryState {
    pub fn request(&self) -> &FileHistoryRequest {
        &self.request
    }

    /// Every name the file had (as found so far), the given one first.
    pub fn names(&self) -> Vec<PathBuf> {
        self.loader.names()
    }

    /// Commits listed so far, whatever the filter.
    pub fn total_count(&self) -> usize {
        self.loader.row_count()
    }

    /// Rows shown: the commits listed so far, or those of them the filter
    /// keeps.
    pub fn row_count(&self) -> usize {
        match self.shown() {
            Some(shown) => shown.len(),
            None => self.loader.row_count(),
        }
    }

    /// The shown versions `start..start + count`, newest first.
    pub fn rows(&self, start: usize, count: usize) -> Vec<FileVersion> {
        let shown = self.shown();
        let rows = self.loader.rows();
        match shown {
            Some(shown) => shown
                .iter()
                .skip(start)
                .take(count)
                .filter_map(|&at| rows.get(at as usize).cloned())
                .collect(),
            None => {
                let end = start.saturating_add(count).min(rows.len());
                rows.get(start..end).map(<[_]>::to_vec).unwrap_or_default()
            }
        }
    }

    /// The version of commit `oid`, shown or not.
    pub fn version_of(&self, oid: &str) -> Option<FileVersion> {
        self.loader.version_of(oid)
    }

    /// Where commit `oid` is among the shown rows.
    pub fn index_of(&self, oid: &str) -> Option<usize> {
        let at = self.loader.index_of(oid)?;
        match self.shown() {
            Some(shown) => shown.binary_search(&u32::try_from(at).ok()?).ok(),
            None => Some(at),
        }
    }

    /// The filter's text as typed (trimmed); empty without a filter.
    pub fn filter(&self) -> &str {
        self.filter.as_ref().map_or("", |f| f.query.as_str())
    }

    /// Lines the uncommitted changes add and remove, once counted.
    pub fn working_stats(&self) -> Option<(u32, u32)> {
        self.working_stats
    }

    fn stamp(&self) -> (u64, u64) {
        (self.swaps, self.loader.version())
    }

    /// Where the filter's matches are among the loader's rows; `None`
    /// without a filter. Computed again when rows arrived since
    /// [`Self::refresh_filter`].
    fn shown(&self) -> Option<Cow<'_, [u32]>> {
        let filter = self.filter.as_ref()?;
        Some(if filter.stamp == self.stamp() {
            Cow::Borrowed(filter.shown.as_slice())
        } else {
            Cow::Owned(filter.positions(&self.loader.rows()))
        })
    }

    fn refresh_filter(&mut self) {
        let stamp = self.stamp();
        if let Some(filter) = self.filter.as_mut().filter(|f| f.stamp != stamp) {
            filter.shown = filter.positions(&self.loader.rows());
            filter.stamp = stamp;
        }
    }

    /// Whether more rows may come (a first load or a reload).
    pub fn is_loading(&self) -> bool {
        self.loader.is_loading() || self.next.is_some()
    }

    pub fn error(&self) -> Option<GitError> {
        self.loader.error()
    }

    pub fn selected(&self) -> Option<&FileSelection> {
        self.selected.as_ref()
    }

    /// The selected version's commit (its message, people and parents),
    /// once it loaded.
    pub fn details(&self) -> Option<&CommitDetails> {
        let Some(FileSelection::Version(oid)) = &self.selected else {
            return None;
        };
        self.details.as_ref().filter(|d| &d.oid == oid)
    }

    fn follows_head(&self) -> bool {
        self.request.start.is_none()
    }
}

impl RepoState {
    /// The file history opened with [`Runtime::open_file_history`].
    pub fn file_history(&self) -> Option<&FileHistoryState> {
        self.file_history.as_ref()
    }

    /// The diff of the selected version of the file history.
    pub fn file_diff(&self) -> Option<&DiffState> {
        self.file_diff.as_ref()
    }

    /// Whether the file history has an Uncommitted changes row: it is read
    /// from HEAD, the file has local changes and no filter is on.
    pub fn file_history_has_working(&self) -> bool {
        self.file_history_working().is_some()
    }

    /// The file history's Uncommitted changes row, while it shows.
    pub fn file_history_working(&self) -> Option<WorkingVersion> {
        let history = self.file_history.as_ref().filter(|h| h.filter.is_none())?;
        let target = self.working_target()?;
        let change = self
            .status
            .as_ref()?
            .changes
            .iter()
            .find(|c| c.path == history.request.path)?;
        Some(WorkingVersion {
            code: changes::change_code(change),
            original_path: target.original_path,
            stats: history.working_stats,
        })
    }

    /// The diff of the Uncommitted changes row: what Changes shows for the
    /// file.
    fn working_target(&self) -> Option<DiffTarget> {
        let history = self.file_history.as_ref().filter(|h| h.follows_head())?;
        let status = self.status.as_ref()?;
        let path = &history.request.path;
        status
            .changes
            .iter()
            .any(|c| &c.path == path && c.state != FileState::Ignored)
            .then(|| changes::diff_target(status, path))
    }
}

impl Runtime {
    /// Opens the history of `request.path`, replacing any other; its rows
    /// arrive as [`RuntimeEvent::FileHistoryChanged`]. Clears the file diff.
    pub fn open_file_history(&mut self, key: &Path, request: FileHistoryRequest) {
        let Some(state) = self.repos.get_mut(key).filter(|s| s.is_ready()) else {
            return;
        };
        let Some(toplevel) = state.toplevel.clone() else {
            return;
        };
        // A rename that is not committed yet: HEAD knows the file by its
        // old name.
        let log_path = match (&request.start, &state.status) {
            (None, Some(status)) => changes::diff_target(status, &request.path)
                .original_path
                .unwrap_or_else(|| request.path.clone()),
            _ => request.path.clone(),
        };
        let head = state.status.as_ref().and_then(|s| s.oid.clone());
        let start = request.start.clone().unwrap_or_else(|| "HEAD".to_owned());
        let (loader, _) =
            FileHistoryLoader::submit(&self.scheduler, key, toplevel, start, log_path.clone());
        state.file_history = Some(FileHistoryState {
            request,
            log_path,
            loader,
            next: None,
            head,
            swaps: 0,
            reported: (0, 0, true),
            selected: None,
            details: None,
            working_stats: None,
            filter: None,
        });
        state.file_diff = None;
        state.blame = None;
        submit_working_stats(&self.scheduler, state);
        self.pending.push(RuntimeEvent::FileHistoryChanged {
            repo: key.to_path_buf(),
        });
    }

    /// Closes the file history; its load is cancelled.
    pub fn close_file_history(&mut self, key: &Path) {
        if let Some(state) = self.repos.get_mut(key) {
            state.file_history = None;
            state.file_diff = None;
            state.blame = None;
        }
    }

    /// Narrows the file history to the commits whose subject, author,
    /// co-authors or hash (from its start) contain `query`; a blank one
    /// shows them all again. The Uncommitted changes row hides while a
    /// filter is on.
    pub fn set_file_history_filter(&mut self, key: &Path, query: &str) {
        let Some(history) = self
            .repos
            .get_mut(key)
            .and_then(|s| s.file_history.as_mut())
        else {
            return;
        };
        let query = query.trim();
        if history.filter() == query {
            return;
        }
        history.filter = (!query.is_empty()).then(|| VersionFilter {
            query: query.to_owned(),
            needle: query.to_lowercase(),
            shown: Vec::new(),
            // Never a loader's: the first refresh computes the rows.
            stamp: (u64::MAX, u64::MAX),
        });
        history.refresh_filter();
        self.pending.push(RuntimeEvent::FileHistoryChanged {
            repo: key.to_path_buf(),
        });
    }

    /// Shows the diff of a version of the file (against its first parent),
    /// of the uncommitted changes, or nothing.
    pub fn select_file_version(
        &mut self,
        key: &Path,
        selection: Option<FileSelection>,
        full: bool,
    ) {
        let Some(state) = self.repos.get_mut(key) else {
            return;
        };
        let target = match &selection {
            Some(FileSelection::Working) => state.working_target(),
            Some(FileSelection::Version(oid)) => state
                .file_history
                .as_ref()
                .and_then(|h| h.version_of(oid))
                .map(|v| v.target()),
            None => None,
        };
        let selection = selection.filter(|_| target.is_some());
        if let Some(history) = state.file_history.as_mut() {
            let load = match &selection {
                Some(FileSelection::Version(oid)) if history.details().is_none() => {
                    Some(oid.clone())
                }
                _ => None,
            };
            if history.selected != selection {
                history.selected = selection;
                history.details = history
                    .details
                    .take()
                    .filter(|d| history.selected == Some(FileSelection::Version(d.oid.clone())));
            }
            if let Some(oid) = load {
                self.scheduler
                    .submit(JobSpec::read(key, FILE_COMMIT_JOB_LABEL, move |ctx| {
                        ctx.backend()
                            .commit_details(ctx.repo(), &oid, ctx.cancel_token())
                            .map(|details| JobOutput::Commit(Box::new(details)))
                    }));
            }
        }
        self.select_slot(key, DiffSlot::File, target, full);
    }

    /// Writes the file as commit `oid` has it into the working copy, under
    /// the name the history was opened with. The file is backed up first:
    /// [`Runtime::undo_discard`] puts it back. `None` when that commit
    /// deleted the file.
    pub fn restore_file_version(&mut self, key: &Path, oid: &str) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let history = self.repos.get(key)?.file_history.as_ref()?;
        let version = history.version_of(oid).filter(FileVersion::exists)?;
        let dest = history.request.path.clone();
        Some(self.scheduler.submit(JobSpec::write(
            key,
            RESTORE_FROM_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                let backups = ctx.backend().restore_file_as(
                    &toplevel,
                    &version.oid,
                    &version.path,
                    &dest,
                    ctx.cancel_token(),
                )?;
                Ok(JobOutput::Discarded(backups))
            },
        )))
    }

    /// Swaps finished reloads in and reports the histories that changed.
    pub(super) fn advance_file_histories(&mut self, out: &mut Vec<RuntimeEvent>) {
        for state in self.repos.values_mut() {
            let Some(history) = state.file_history.as_mut() else {
                continue;
            };
            if history.next.as_ref().is_some_and(|n| !n.is_loading()) {
                if let Some(next) = history.next.take() {
                    history.loader = next;
                    history.swaps += 1;
                }
                drop_stale_version(state);
            }
            let Some(history) = state.file_history.as_mut() else {
                continue;
            };
            history.refresh_filter();
            let reported = (
                history.swaps,
                history.loader.version(),
                history.is_loading(),
            );
            if reported != history.reported {
                history.reported = reported;
                out.push(RuntimeEvent::FileHistoryChanged {
                    repo: state.key.clone(),
                });
            }
        }
    }
}

/// After a status refresh (`changed`: it differs from the last one): a
/// history read from HEAD loads again when HEAD moved, and its uncommitted
/// changes are read again.
pub(super) fn file_history_after_status(
    scheduler: &JobScheduler,
    state: &mut RepoState,
    generation: &mut u64,
    changed: bool,
    out: &mut Vec<RuntimeEvent>,
) {
    let head = state.status.as_ref().and_then(|s| s.oid.clone());
    let toplevel = state.toplevel.clone();
    let Some(history) = state.file_history.as_mut().filter(|h| h.follows_head()) else {
        return;
    };
    if history.head != head {
        history.head = head;
        if let Some(toplevel) = toplevel {
            let (next, _) = FileHistoryLoader::submit(
                scheduler,
                &state.key,
                toplevel,
                "HEAD".to_owned(),
                history.log_path.clone(),
            );
            history.next = Some(next);
        }
    }
    let working = history.selected == Some(FileSelection::Working);
    // The file may have changed without its status changing.
    submit_working_stats(scheduler, state);
    if working {
        match state.working_target() {
            // The same file, read again; a rename shows against its source.
            Some(target) if state.file_diff.as_ref().is_some_and(|d| d.target == target) => {
                reload_slot_diff(scheduler, state, DiffSlot::File, generation);
            }
            Some(target) => {
                state.file_diff = Some(DiffState::new(target, false));
                *generation += 1;
                submit_diff(scheduler, state, DiffSlot::File, *generation);
            }
            None => {
                state.file_diff = None;
                if let Some(history) = state.file_history.as_mut() {
                    history.selected = None;
                }
                out.push(RuntimeEvent::DiffChanged {
                    repo: state.key.clone(),
                    slot: DiffSlot::File,
                });
            }
        }
    }
    if changed {
        // The Uncommitted changes row may have come or gone.
        out.push(RuntimeEvent::FileHistoryChanged {
            repo: state.key.clone(),
        });
    }
}

/// Counts the lines of the file's uncommitted changes (a history read from
/// HEAD of a file with local changes), for the Uncommitted changes row.
fn submit_working_stats(scheduler: &JobScheduler, state: &mut RepoState) {
    let Some(target) = state.working_target() else {
        if let Some(history) = state.file_history.as_mut() {
            history.working_stats = None;
        }
        return;
    };
    let Some(toplevel) = state.toplevel.clone() else {
        return;
    };
    scheduler.submit(JobSpec::read(
        &state.key,
        FILE_STATS_JOB_LABEL,
        move |ctx| {
            let stats = ctx
                .backend()
                .working_line_stats(&toplevel, &target, ctx.cancel_token())?;
            Ok(JobOutput::WorkingStats {
                path: target.path,
                stats,
            })
        },
    ));
}

/// Stores the counted lines of the uncommitted changes when the history is
/// still that file's.
pub(super) fn apply_working_stats(
    state: &mut RepoState,
    kind: EventKind,
    repo: &Path,
    out: &mut Vec<RuntimeEvent>,
) {
    let EventKind::Finished(Ok(JobOutput::WorkingStats { path, stats })) = kind else {
        return;
    };
    let Some(history) = state
        .file_history
        .as_mut()
        .filter(|h| h.request.path == path)
    else {
        return;
    };
    if history.working_stats != stats {
        history.working_stats = stats;
        out.push(RuntimeEvent::FileHistoryChanged {
            repo: repo.to_path_buf(),
        });
    }
}

/// Stores the selected version's commit when it is still the selected one.
pub(super) fn apply_file_commit(
    state: &mut RepoState,
    kind: EventKind,
    repo: &Path,
    out: &mut Vec<RuntimeEvent>,
) {
    let EventKind::Finished(Ok(JobOutput::Commit(details))) = kind else {
        return;
    };
    let Some(history) = state.file_history.as_mut() else {
        return;
    };
    if history.selected == Some(FileSelection::Version(details.oid.clone())) {
        history.details = Some(*details);
        out.push(RuntimeEvent::FileHistoryChanged {
            repo: repo.to_path_buf(),
        });
    }
}

/// Clears the file diff when its commit left the history (a reload).
fn drop_stale_version(state: &mut RepoState) {
    let Some(history) = state.file_history.as_mut() else {
        return;
    };
    let gone = match &history.selected {
        Some(FileSelection::Version(oid)) => history.loader.index_of(oid).is_none(),
        _ => false,
    };
    if gone {
        history.selected = None;
        history.details = None;
        state.file_diff = None;
    }
}
