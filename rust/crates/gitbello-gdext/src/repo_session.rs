use std::path::{Path, PathBuf};

use gitbello_core::changes::{commit_message, diff_target, ChangeGroup};
use gitbello_core::diff::PatchMode;
use gitbello_core::graph::{to_hex, LoadState};
use gitbello_core::jobs::{JobId, RefreshSet};
use gitbello_core::ops::{CheckoutTarget, PullMode, RefOp};
use gitbello_core::runtime::RepoState;
use gitbello_core::sidebar::{local_branch_tree, remote_branch_tree};
use godot::prelude::*;

use crate::convert::{self, gstr, path_str, to_i64};
use crate::runtime_cell;

/// One open repository or worktree tab (PLAN §3.5). Created by
/// `Core.open_session(path)`; the `Core` autoload delivers its signals.
///
/// Queries return small data; the graph is read in slices.
#[derive(GodotClass)]
#[class(base = Node)]
pub struct RepoSession {
    base: Base<Node>,
    key: PathBuf,
    reported_rows: usize,
    graph_done: bool,
}

#[godot_api]
impl INode for RepoSession {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            key: PathBuf::new(),
            reported_rows: 0,
            graph_done: false,
        }
    }
}

#[godot_api]
impl RepoSession {
    /// The repository resolved and its first refresh is under way.
    #[signal]
    fn opened();
    /// Opening failed; `error` as in `Core.git_error`.
    #[signal]
    fn open_failed(error: VarDictionary);
    #[signal]
    fn status_changed();
    #[signal]
    fn refs_changed();
    #[signal]
    fn worktrees_changed();
    #[signal]
    fn stashes_changed();
    #[signal]
    fn operation_changed();
    /// Changed-file count, ahead/behind or operation may have changed.
    #[signal]
    fn badge_changed();
    /// A new graph load replaced the previous one; row data must be refetched.
    #[signal]
    fn graph_reset();
    /// Rows `start..start + count` were appended to the graph.
    #[signal]
    fn graph_changed(start: i64, count: i64);
    /// Graph loading ended; `error` is empty on success.
    #[signal]
    fn graph_loaded(row_count: i64, error: GString);
    /// A job other than a refresh or diff load started (fetch, push, ...).
    #[signal]
    fn job_started(job: i64, label: GString);
    #[signal]
    fn job_progress(job: i64, label: GString, percent: i64, text: GString);
    #[signal]
    fn job_finished(job: i64, label: GString, ok: bool, error: VarDictionary);
    /// A job was cancelled before it finished (no `job_finished` follows).
    #[signal]
    fn job_cancelled(job: i64, label: GString);
    /// The selected diff loaded, reloaded or failed (see `diff_info`).
    #[signal]
    fn diff_changed();
    /// HEAD's message, split into summary and body (`load_head_message`).
    #[signal]
    fn head_message_loaded(summary: GString, body: GString);
    /// The commit requested with `load_commit` arrived (`commit_info`).
    #[signal]
    fn commit_loaded();
    /// The commit file diff loaded or failed (`commit_diff_info`).
    #[signal]
    fn commit_diff_changed();

    /// The key passed to every core call (the opened path, normalized).
    #[func]
    fn repo_path(&self) -> GString {
        path_str(&self.key)
    }

    /// Worktree root once resolved, else the opened path.
    #[func]
    fn toplevel(&self) -> GString {
        self.read(|s| s.toplevel().map(path_str))
            .flatten()
            .unwrap_or_else(|| path_str(&self.key))
    }

    #[func]
    fn display_name(&self) -> GString {
        self.read(|s| gstr(&s.display_name()))
            .unwrap_or_else(|| path_str(&self.key))
    }

    #[func]
    fn is_ready(&self) -> bool {
        self.read(RepoState::is_ready).unwrap_or(false)
    }

    /// Error from opening, or an empty dictionary.
    #[func]
    fn open_error(&self) -> VarDictionary {
        self.read(|s| s.open_error().map(convert::error_dict))
            .flatten()
            .unwrap_or_default()
    }

    /// `{head, detached, oid, upstream, ahead, behind, stash_count, changes}`;
    /// empty until the first status refresh.
    #[func]
    fn status(&self) -> VarDictionary {
        self.read(|s| s.status().map(convert::status_dict))
            .flatten()
            .unwrap_or_default()
    }

    /// `{changed, conflicts, ahead, behind, operation, head, summary}`.
    #[func]
    fn badge(&self) -> VarDictionary {
        self.read(|s| convert::badge_dict(&s.badge()))
            .unwrap_or_default()
    }

    /// Local branches grouped by prefix: nested `{name, ref, children}`.
    #[func]
    fn local_branches(&self) -> Array<VarDictionary> {
        self.read(|s| {
            s.refs()
                .map(|refs| convert::branch_tree(&local_branch_tree(refs), refs))
        })
        .flatten()
        .unwrap_or_default()
    }

    /// Remote branches: one folder per remote, grouped by prefix inside.
    #[func]
    fn remote_branches(&self) -> Array<VarDictionary> {
        self.read(|s| {
            s.refs()
                .map(|refs| convert::branch_tree(&remote_branch_tree(refs), refs))
        })
        .flatten()
        .unwrap_or_default()
    }

    /// `{name, commit, annotated}`, newest name first.
    #[func]
    fn tags(&self) -> Array<VarDictionary> {
        self.read(|s| s.refs().map(convert::tags))
            .flatten()
            .unwrap_or_default()
    }

    /// `{index, message, branch, time, oid}`.
    #[func]
    fn stashes(&self) -> Array<VarDictionary> {
        self.read(|s| s.stashes().map(convert::stashes))
            .flatten()
            .unwrap_or_default()
    }

    /// `{path, name, branch, head, detached, bare, locked, prunable, is_main,
    /// is_current, badge, changed}`; `badge` is the summary text (`3 ↑1`) and
    /// `changed` is -1 until the worktree's status is known.
    #[func]
    fn worktrees(&self) -> Array<VarDictionary> {
        self.read(|s| {
            s.worktrees().map(|list| {
                convert::worktrees(list, s.toplevel(), |wt, current| {
                    if current {
                        s.status().map(|_| s.badge())
                    } else {
                        s.worktree_badge(&wt.path).cloned()
                    }
                })
            })
        })
        .flatten()
        .unwrap_or_default()
    }

    /// In-progress operation id (`merge`, `rebase`, ...) or empty.
    #[func]
    fn operation(&self) -> GString {
        self.read(|s| gstr(convert::operation_id(s.operation())))
            .unwrap_or_default()
    }

    /// Re-reads everything (status, refs, worktrees, operation, stashes).
    #[func]
    fn refresh(&self) {
        runtime_cell::with(|rt| rt.refresh(&self.key, RefreshSet::all()));
    }

    // --- Sync, branches and tags -----------------------------------------------

    /// Configured remote names.
    #[func]
    fn remotes(&self) -> PackedStringArray {
        self.read(|s| s.remotes().iter().map(|r| gstr(r)).collect())
            .unwrap_or_default()
    }

    /// The checked-out branch, or empty when detached.
    #[func]
    fn current_branch(&self) -> GString {
        self.read(|s| s.current_branch().map(gstr))
            .flatten()
            .unwrap_or_default()
    }

    /// Where pushes go (see `RepoState::default_remote`), or empty.
    #[func]
    fn default_remote(&self) -> GString {
        self.read(|s| s.default_remote().map(|r| gstr(&r)))
            .flatten()
            .unwrap_or_default()
    }

    /// Local then remote branches: `{name, short_name, commit, is_head,
    /// upstream, ahead, behind, gone, worktree, kind}` (kind `branch` or `remote`).
    #[func]
    fn branch_refs(&self) -> Array<VarDictionary> {
        self.read(|s| s.refs().map(convert::branch_refs))
            .flatten()
            .unwrap_or_default()
    }

    #[func]
    fn can_fetch(&self) -> bool {
        self.read(RepoState::can_fetch).unwrap_or(false)
    }

    #[func]
    fn can_pull(&self) -> bool {
        self.read(RepoState::can_pull).unwrap_or(false)
    }

    #[func]
    fn can_push(&self) -> bool {
        self.read(RepoState::can_push).unwrap_or(false)
    }

    /// Whether a fetch (manual or automatic) is running or queued.
    #[func]
    fn is_fetching(&self) -> bool {
        self.read(RepoState::is_fetching).unwrap_or(false)
    }

    /// Fetches all remotes. Job label `fetch` (`auto-fetch` for automatic
    /// ones); returns the running fetch's id if one is under way, else -1.
    #[func]
    fn fetch(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.fetch(&self.key)).flatten())
    }

    /// Pulls with `mode` (`ff-only`, `merge`, `rebase`, or empty for the
    /// configured one). Label `pull`.
    #[func]
    fn pull(&self, mode: GString) -> i64 {
        let mode = PullMode::parse(&mode.to_string());
        job_id(runtime_cell::with(|rt| rt.pull(&self.key, mode)).flatten())
    }

    /// Pushes the current branch (setting its upstream if it has none).
    /// Label `push`.
    #[func]
    fn push(&self, force_with_lease: bool) -> i64 {
        job_id(runtime_cell::with(|rt| rt.push(&self.key, force_with_lease)).flatten())
    }

    /// Pushes a tag to the default remote. Label `push tag`.
    #[func]
    fn push_tag(&self, name: GString) -> i64 {
        job_id(runtime_cell::with(|rt| rt.push_tag(&self.key, &name.to_string())).flatten())
    }

    /// Checks out local branch `name`; with `stash`, local changes are
    /// stashed and re-applied afterwards. Label `checkout`.
    #[func]
    fn checkout_branch(&self, name: GString, stash: bool) -> i64 {
        self.checkout(Some(CheckoutTarget::Branch(name.to_string())), stash)
    }

    /// Checks out remote-tracking branch `remote_ref` (`refs/remotes/...`):
    /// the local branch tracking it, or a new one. Label `checkout`.
    #[func]
    fn checkout_remote(&self, remote_ref: GString, stash: bool) -> i64 {
        let target = self
            .read(|s| s.remote_checkout_target(&remote_ref.to_string()))
            .flatten();
        self.checkout(target, stash)
    }

    /// Checks out a commit, detaching HEAD. Label `checkout`.
    #[func]
    fn checkout_commit(&self, oid: GString, stash: bool) -> i64 {
        self.checkout(Some(CheckoutTarget::Detach(oid.to_string())), stash)
    }

    /// Creates branch `name` at `start` (a branch, ref or hash), optionally
    /// switching to it. Label `create branch` (`checkout` errors as well).
    #[func]
    fn create_branch(&self, name: GString, start: GString, checkout: bool) -> i64 {
        self.ref_op(RefOp::CreateBranch {
            name: name.to_string(),
            start: start.to_string(),
            checkout,
        })
    }

    /// Label `rename branch`.
    #[func]
    fn rename_branch(&self, old: GString, new: GString) -> i64 {
        self.ref_op(RefOp::RenameBranch {
            old: old.to_string(),
            new: new.to_string(),
        })
    }

    /// `force` deletes an unmerged branch. Label `delete branch`.
    #[func]
    fn delete_branch(&self, name: GString, force: bool) -> i64 {
        self.ref_op(RefOp::DeleteBranch {
            name: name.to_string(),
            force,
        })
    }

    /// Makes `branch` track `upstream` (`origin/x`); empty unsets it.
    /// Label `set upstream`.
    #[func]
    fn set_upstream(&self, branch: GString, upstream: GString) -> i64 {
        let upstream = upstream.to_string();
        self.ref_op(RefOp::SetUpstream {
            branch: branch.to_string(),
            upstream: (!upstream.is_empty()).then_some(upstream),
        })
    }

    /// Tags `target`; a non-empty `message` makes an annotated tag. Label
    /// `create tag`.
    #[func]
    fn create_tag(&self, name: GString, target: GString, message: GString) -> i64 {
        let message = message.to_string();
        self.ref_op(RefOp::CreateTag {
            name: name.to_string(),
            target: target.to_string(),
            message: (!message.trim().is_empty()).then_some(message),
        })
    }

    /// Label `delete tag`.
    #[func]
    fn delete_tag(&self, name: GString) -> i64 {
        self.ref_op(RefOp::DeleteTag {
            name: name.to_string(),
        })
    }

    /// Applies commit `oid` on top of HEAD. Label `cherry-pick`.
    #[func]
    fn cherry_pick(&self, oid: GString) -> i64 {
        self.ref_op(RefOp::CherryPick {
            commit: oid.to_string(),
        })
    }

    /// Aborts the operation in progress (merge, cherry-pick, rebase, ...).
    /// Label `abort`; -1 when there is none.
    #[func]
    fn abort_operation(&self) -> i64 {
        match self.read(RepoState::operation).flatten() {
            Some(operation) => self.ref_op(RefOp::Abort(operation)),
            None => -1,
        }
    }

    /// Cancels a running or queued job; returns whether it was found.
    #[func]
    fn cancel_job(&self, job: i64) -> bool {
        let Ok(job) = u64::try_from(job) else {
            return false;
        };
        runtime_cell::with(|rt| rt.cancel_job(job)).unwrap_or(false)
    }

    // --- Changes panel ------------------------------------------------------

    /// Files in a change list: `conflicted`, `unstaged`, `staged` or `untracked`.
    #[func]
    fn change_count(&self, group: GString) -> i64 {
        let Some(group) = parse_group(&group) else {
            return 0;
        };
        self.read(|s| to_i64(s.changes().len(group))).unwrap_or(0)
    }

    /// Rows `start..start + count` of a change list, sorted by path:
    /// `{path, original_path, code, group}` (code is `M`, `A`, `D`, `R`, `?`, ...).
    #[func]
    fn change_rows(&self, group: GString, start: i64, count: i64) -> Array<VarDictionary> {
        let Some(group) = parse_group(&group) else {
            return Array::new();
        };
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| {
            let mut rows = Array::new();
            let Some(status) = s.status() else {
                return rows;
            };
            for &i in s.changes().indices(group).iter().skip(start).take(count) {
                rows.push(&convert::change_row(&status.changes[i], group));
            }
            rows
        })
        .unwrap_or_default()
    }

    /// Paths of rows `start..start + count` of a change list.
    #[func]
    fn change_paths(&self, group: GString, start: i64, count: i64) -> PackedStringArray {
        let Some(group) = parse_group(&group) else {
            return PackedStringArray::new();
        };
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| {
            let Some(status) = s.status() else {
                return PackedStringArray::new();
            };
            s.changes()
                .indices(group)
                .iter()
                .skip(start)
                .take(count)
                .map(|&i| path_str(&status.changes[i].path))
                .collect()
        })
        .unwrap_or_default()
    }

    /// Row of `path` in a change list, or -1.
    #[func]
    fn change_index(&self, group: GString, path: GString) -> i64 {
        let Some(group) = parse_group(&group) else {
            return -1;
        };
        let path = PathBuf::from(path.to_string());
        self.read(|s| {
            let status = s.status()?;
            let indices = s.changes().indices(group);
            indices
                .binary_search_by(|&i| status.changes[i].path.cmp(&path))
                .ok()
                .map(to_i64)
        })
        .flatten()
        .unwrap_or(-1)
    }

    /// Stages (or, for the `staged` list, unstages) `paths` from `group`.
    /// Returns the job id, or -1 when the repository is not ready.
    #[func]
    fn stage_paths(&self, group: GString, paths: PackedStringArray) -> i64 {
        let Some(group) = parse_group(&group) else {
            return -1;
        };
        let paths: Vec<PathBuf> = paths
            .as_slice()
            .iter()
            .map(|p| PathBuf::from(p.to_string()))
            .collect();
        let job = runtime_cell::with(|rt| {
            if group.stages() {
                rt.stage(&self.key, Some(paths))
            } else {
                rt.unstage(&self.key, Some(paths))
            }
        });
        job_id(job.flatten())
    }

    /// `git add -A` of the whole worktree.
    #[func]
    fn stage_all(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.stage(&self.key, None)).flatten())
    }

    /// Unstages everything.
    #[func]
    fn unstage_all(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.unstage(&self.key, None)).flatten())
    }

    /// Shows the diff of `path` from `group`; `full` loads it past the size
    /// limit. `diff_changed` fires when it is loaded and after every reload.
    #[func]
    fn select_diff(&self, group: GString, path: GString, full: bool) {
        let Some(group) = parse_group(&group) else {
            return;
        };
        let path = PathBuf::from(path.to_string());
        runtime_cell::with(|rt| {
            let target = rt
                .repo(&self.key)
                .and_then(RepoState::status)
                .map(|status| diff_target(status, group, &path));
            if let Some(target) = target {
                rt.select_diff(&self.key, Some(target), full);
            }
        });
    }

    #[func]
    fn clear_diff(&self) {
        runtime_cell::with(|rt| rt.select_diff(&self.key, None, false));
    }

    /// See `convert::diff_info`: `{state, path, kind, content, notes, ...}`.
    #[func]
    fn diff_info(&self) -> VarDictionary {
        self.read(|s| convert::diff_info(s.diff()))
            .unwrap_or_default()
    }

    /// Visible slice of the selected diff: `{kind, old, new, text, no_newline}`
    /// (kind 0 = hunk header, 1 = context, 2 = added, 3 = removed).
    #[func]
    fn diff_lines(&self, start: i64, count: i64) -> Array<VarDictionary> {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| {
            let state = s.diff()?;
            let language = convert::diff_language(&state.target().path);
            state
                .diff()
                .map(|diff| convert::diff_lines(diff, start, count, language))
        })
        .flatten()
        .unwrap_or_default()
    }

    /// Side-by-side rows of a diff (`slot` is `changes` or `commit`):
    /// `{left, right}` with `diff_lines`-style lines or empty dictionaries.
    /// `diff_info().split_count` gives the number of rows.
    #[func]
    fn diff_split_rows(&self, slot: GString, start: i64, count: i64) -> Array<VarDictionary> {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        let commit = slot == "commit";
        self.read(|s| {
            let state = if commit { s.commit_diff() } else { s.diff() }?;
            let language = convert::diff_language(&state.target().path);
            state
                .diff()
                .map(|diff| convert::split_rows(diff, start, count, language))
        })
        .flatten()
        .unwrap_or_default()
    }

    // --- Commit details -----------------------------------------------------

    /// Loads a commit's details (full or unique hash); `commit_loaded` follows.
    #[func]
    fn load_commit(&self, oid: GString) {
        runtime_cell::with(|rt| rt.load_commit(&self.key, &oid.to_string()));
    }

    /// See `convert::commit_info`; empty until a commit loaded.
    #[func]
    fn commit_info(&self) -> VarDictionary {
        self.read(|s| s.commit().map(convert::commit_info))
            .flatten()
            .unwrap_or_default()
    }

    /// Files of the loaded commit, rows `start..start + count`:
    /// `{path, original_path, code}`.
    #[func]
    fn commit_files(&self, start: i64, count: i64) -> Array<VarDictionary> {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| {
            let mut rows = Array::new();
            if let Some(commit) = s.commit() {
                for file in commit.files.iter().skip(start).take(count) {
                    rows.push(&convert::commit_file_row(file));
                }
            }
            rows
        })
        .unwrap_or_default()
    }

    /// Shows the diff of `path` in the loaded commit; `commit_diff_changed` follows.
    #[func]
    fn select_commit_file(&self, path: GString, full: bool) {
        let path = PathBuf::from(path.to_string());
        runtime_cell::with(|rt| rt.select_commit_file(&self.key, Some(&path), full));
    }

    #[func]
    fn clear_commit_diff(&self) {
        runtime_cell::with(|rt| rt.select_commit_file(&self.key, None, false));
    }

    /// Like `diff_info`, for the commit file diff.
    #[func]
    fn commit_diff_info(&self) -> VarDictionary {
        self.read(|s| convert::diff_info(s.commit_diff()))
            .unwrap_or_default()
    }

    /// Like `diff_lines`, for the commit file diff.
    #[func]
    fn commit_diff_lines(&self, start: i64, count: i64) -> Array<VarDictionary> {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| {
            let state = s.commit_diff()?;
            let language = convert::diff_language(&state.target().path);
            state
                .diff()
                .map(|diff| convert::diff_lines(diff, start, count, language))
        })
        .flatten()
        .unwrap_or_default()
    }

    /// Whether the selected diff's lines can be used with `mode` (`stage`,
    /// `unstage` or `discard`).
    #[func]
    fn can_apply_lines(&self, mode: GString) -> bool {
        let Some(mode) = parse_mode(&mode) else {
            return false;
        };
        self.read(|s| s.can_apply_lines(mode)).unwrap_or(false)
    }

    /// Stages, unstages or discards the selected diff lines (`diff_lines`
    /// indices; a hunk header row takes its whole hunk). Returns the job id
    /// (label `stage`, `unstage` or `discard`), or -1 when nothing applies.
    #[func]
    fn apply_lines(&self, mode: GString, lines: PackedInt32Array) -> i64 {
        let Some(mode) = parse_mode(&mode) else {
            return -1;
        };
        let lines: Vec<usize> = lines
            .as_slice()
            .iter()
            .filter_map(|&l| usize::try_from(l).ok())
            .collect();
        job_id(runtime_cell::with(|rt| rt.apply_lines(&self.key, &lines, mode)).flatten())
    }

    /// Restores `paths` from the index in the working tree (backed up first).
    #[func]
    fn discard_paths(&self, paths: PackedStringArray) -> i64 {
        let paths: Vec<PathBuf> = paths
            .as_slice()
            .iter()
            .map(|p| PathBuf::from(p.to_string()))
            .collect();
        job_id(runtime_cell::with(|rt| rt.discard_files(&self.key, paths)).flatten())
    }

    #[func]
    fn can_undo_discard(&self) -> bool {
        self.read(RepoState::can_undo_discard).unwrap_or(false)
    }

    /// Writes back the most recent discard. Label `undo discard`.
    #[func]
    fn undo_discard(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.undo_discard(&self.key)).flatten())
    }

    /// Whether `commit(…, amend)` can run now.
    #[func]
    fn can_commit(&self, amend: bool) -> bool {
        self.read(|s| s.can_commit(amend)).unwrap_or(false)
    }

    /// Commits the index (or amends HEAD). Returns the job id, or -1 when the
    /// summary is empty or the repository is not ready. The result arrives as
    /// `job_finished` with label `commit`; hook output is in the error's stderr.
    #[func]
    fn commit(&self, summary: GString, body: GString, amend: bool) -> i64 {
        let Some(message) = commit_message(&summary.to_string(), &body.to_string()) else {
            return -1;
        };
        job_id(runtime_cell::with(|rt| rt.commit(&self.key, message, amend)).flatten())
    }

    /// Reads HEAD's message for amending; arrives as `head_message_loaded`.
    #[func]
    fn load_head_message(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.load_head_message(&self.key)).flatten())
    }

    /// Rows reported through `graph_changed` so far.
    #[func]
    fn graph_row_count(&self) -> i64 {
        to_i64(self.reported_rows)
    }

    /// Visible slice of the graph. Each row is a Dictionary with `row`, `hash`,
    /// `subject`, `author`, `email`, `time` (unix seconds), `column`, `color`,
    /// `width` (columns used), `segments` (PackedInt32Array of
    /// `kind, from, to, color` quadruples; kind 0 = pass, 1 = in, 2 = out) and
    /// `refs` (`{name, kind, is_head}` labels; kind is branch, remote or tag).
    #[func]
    fn graph_rows(&self, start: i64, count: i64) -> Array<VarDictionary> {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count)
            .unwrap_or(0)
            .min(self.reported_rows.saturating_sub(start));
        self.read(|state| {
            let mut rows = Array::new();
            let Some(loader) = state.graph() else {
                return rows;
            };
            let index = loader.index();
            for (offset, layout) in index.layouts(start, count).iter().enumerate() {
                let row = start + offset;
                let Some(commit) = index.commit(row) else {
                    break;
                };
                let hash = to_hex(commit.hash);
                let mut segments = PackedInt32Array::new();
                for segment in &layout.segments {
                    segments.push(segment.kind as i32);
                    segments.push(i32::from(segment.from));
                    segments.push(i32::from(segment.to));
                    segments.push(i32::from(segment.color));
                }
                rows.push(&vdict! {
                    "row" => to_i64(row),
                    "hash" => &gstr(&hash),
                    "subject" => &gstr(commit.subject),
                    "author" => &gstr(commit.author_name),
                    "email" => &gstr(commit.author_email),
                    "time" => commit.author_time,
                    "column" => i64::from(layout.column),
                    "color" => i64::from(layout.color),
                    "width" => i64::from(layout.width()),
                    "segments" => &segments,
                    "refs" => &convert::labels(state.labels(&hash)),
                });
            }
            rows
        })
        .unwrap_or_default()
    }

    /// Load timings and index size, for the status bar and benchmarks.
    #[func]
    fn load_stats(&self) -> VarDictionary {
        self.read(|state| {
            let Some(loader) = state.graph() else {
                return VarDictionary::new();
            };
            let progress = loader.progress();
            let index = loader.index();
            let memory = index.memory();
            let ms = |d: Option<std::time::Duration>| d.map_or(-1.0, |d| d.as_secs_f64() * 1e3);
            vdict! {
                "rows" => to_i64(progress.rows),
                "first_page_ms" => ms(progress.first_page),
                "total_ms" => ms(progress.total),
                "max_lanes" => to_i64(index.max_width()),
                "index_bytes" => to_i64(memory.index_bytes),
                "string_bytes" => to_i64(memory.string_bytes),
            }
        })
        .unwrap_or_default()
    }
}

fn parse_group(id: &GString) -> Option<ChangeGroup> {
    ChangeGroup::from_id(&id.to_string())
}

fn parse_mode(id: &GString) -> Option<PatchMode> {
    match id.to_string().as_str() {
        "stage" => Some(PatchMode::Stage),
        "unstage" => Some(PatchMode::Unstage),
        "discard" => Some(PatchMode::Discard),
        _ => None,
    }
}

fn job_id(job: Option<JobId>) -> i64 {
    job.map_or(-1, |id| i64::try_from(id).unwrap_or(i64::MAX))
}

impl RepoSession {
    pub(crate) fn set_key(&mut self, key: PathBuf) {
        self.key = key;
    }

    pub(crate) fn key(&self) -> &Path {
        &self.key
    }

    fn read<R>(&self, f: impl FnOnce(&RepoState) -> R) -> Option<R> {
        runtime_cell::with(|rt| rt.repo(&self.key).map(f)).flatten()
    }

    fn checkout(&self, target: Option<CheckoutTarget>, stash: bool) -> i64 {
        let Some(target) = target else {
            return -1;
        };
        job_id(runtime_cell::with(|rt| rt.checkout(&self.key, target, stash)).flatten())
    }

    fn ref_op(&self, op: RefOp) -> i64 {
        job_id(runtime_cell::with(|rt| rt.ref_op(&self.key, op)).flatten())
    }

    /// A new graph load started: forget reported rows.
    pub(crate) fn reset_graph(&mut self) {
        self.reported_rows = 0;
        self.graph_done = false;
        self.signals().graph_reset().emit();
    }

    /// Reports graph progress; called by `Core` once per frame.
    pub(crate) fn pump_graph(&mut self) {
        if self.graph_done {
            return;
        }
        let progress = self
            .read(|s| s.graph().map(|g| (g.row_count(), g.progress())))
            .flatten();
        let Some((rows, progress)) = progress else {
            return;
        };
        if rows > self.reported_rows {
            let start = self.reported_rows;
            self.reported_rows = rows;
            self.signals()
                .graph_changed()
                .emit(to_i64(start), to_i64(rows - start));
            return;
        }
        if !progress.is_finished() || progress.rows > self.reported_rows {
            return;
        }
        self.graph_done = true;
        let error = match &progress.state {
            LoadState::Failed(err) => err.to_string(),
            LoadState::Cancelled => "cancelled".to_owned(),
            LoadState::Loading | LoadState::Done => String::new(),
        };
        self.signals()
            .graph_loaded()
            .emit(to_i64(rows), &gstr(&error));
    }
}
