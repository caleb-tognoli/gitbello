use std::path::{Path, PathBuf};

use gitbello_core::changes::{commit_message, ChangeFilter, PickState};
use gitbello_core::diff::{Expand, PatchMode};
use gitbello_core::graph::{to_hex, LoadState};
use gitbello_core::jobs::{JobId, RefreshSet};
use gitbello_core::ops::{CheckoutChanges, CheckoutTarget, NewTask, PullMode, RefOp, WorktreeOp};
use gitbello_core::runtime::{DiffSlot, RepoState};
use gitbello_core::sidebar::{local_branch_tree, remote_branch_tree};
use gitbello_core::worktrees::{worktree_path, CleanupReason};
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
    /// The commit selection changed: picks, or reseeding after a status.
    #[signal]
    fn selection_changed();
    /// HEAD's message, split into summary and body (`load_head_message`).
    #[signal]
    fn head_message_loaded(summary: GString, body: GString);
    /// The commit requested with `load_commit` arrived (`commit_info`).
    #[signal]
    fn commit_loaded();
    /// The commit file diff loaded or failed (`commit_diff_info`).
    #[signal]
    fn commit_diff_changed();
    /// The worktree folder is gone; the session no longer refreshes.
    #[signal]
    fn missing();
    /// `load_cleanup` finished (`cleanup_candidates`).
    #[signal]
    fn cleanup_loaded();
    /// The files of shelf `oid` arrived (`shelf_files`).
    #[signal]
    fn shelf_files_loaded(oid: GString);
    /// The history search found more, progressed, finished or was replaced
    /// (`search_info`, `match` in `graph_rows`).
    #[signal]
    fn search_changed();

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
    /// is_current, badge, changed, conflicts, ahead, behind, operation}`;
    /// `badge` is the summary text (`3 ↑1`), `changed` is -1 until the
    /// worktree's status is known and `operation` an id as in `operation()`.
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

    /// The configured remotes: `{name, fetch_url, push_url}`.
    #[func]
    fn remote_list(&self) -> Array<VarDictionary> {
        self.read(|s| {
            s.remote_list()
                .iter()
                .map(|r| {
                    vdict! {
                        "name" => &gstr(&r.name),
                        "fetch_url" => &gstr(&r.fetch_url),
                        "push_url" => &gstr(&r.push_url),
                    }
                })
                .collect()
        })
        .unwrap_or_default()
    }

    /// Label `add remote`.
    #[func]
    fn add_remote(&self, name: GString, url: GString) -> i64 {
        self.ref_op(RefOp::AddRemote {
            name: name.to_string(),
            url: url.to_string(),
        })
    }

    /// Label `rename remote`.
    #[func]
    fn rename_remote(&self, old: GString, new: GString) -> i64 {
        self.ref_op(RefOp::RenameRemote {
            old: old.to_string(),
            new: new.to_string(),
        })
    }

    /// Also drops its remote-tracking branches. Label `remove remote`.
    #[func]
    fn remove_remote(&self, name: GString) -> i64 {
        self.ref_op(RefOp::RemoveRemote {
            name: name.to_string(),
        })
    }

    /// Sets the fetch and push URL. Label `set remote URL`.
    #[func]
    fn set_remote_url(&self, name: GString, url: GString) -> i64 {
        self.ref_op(RefOp::SetRemoteUrl {
            name: name.to_string(),
            url: url.to_string(),
        })
    }

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
    /// upstream, ahead, behind, gone, worktree, committed_at, kind}` (kind
    /// `branch` or `remote`; `committed_at` in Unix seconds, 0 when unknown).
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

    /// Checks out local branch `name`. `changes` says what happens to local
    /// changes: `keep` (git decides), `bring` (stashed and re-applied on the
    /// branch) or `leave` (an automatic shelf on the current branch). Label
    /// `checkout`.
    #[func]
    fn checkout_branch(&self, name: GString, changes: GString) -> i64 {
        self.checkout(Some(CheckoutTarget::Branch(name.to_string())), &changes)
    }

    /// Checks out remote-tracking branch `remote_ref` (`refs/remotes/...`):
    /// the local branch tracking it, or a new one. Label `checkout`.
    #[func]
    fn checkout_remote(&self, remote_ref: GString, changes: GString) -> i64 {
        let target = self
            .read(|s| s.remote_checkout_target(&remote_ref.to_string()))
            .flatten();
        self.checkout(target, &changes)
    }

    /// Checks out a commit, detaching HEAD. Label `checkout`.
    #[func]
    fn checkout_commit(&self, oid: GString, changes: GString) -> i64 {
        self.checkout(Some(CheckoutTarget::Detach(oid.to_string())), &changes)
    }

    // --- Shelves (PLAN §4 Shelves) ---------------------------------------------

    /// Every shelf, newest first: `{oid, branch, name, auto, made_here, time}`
    /// (stashes made elsewhere included, `made_here` false; `branch` empty
    /// when unknown).
    #[func]
    fn shelves(&self) -> Array<VarDictionary> {
        self.read(|s| convert::shelves(s.shelves()))
            .unwrap_or_default()
    }

    /// Reads the files of shelf `oid`; `shelf_files_loaded` follows.
    #[func]
    fn load_shelf_files(&self, oid: GString) -> i64 {
        job_id(runtime_cell::with(|rt| rt.load_shelf_files(&self.key, &oid.to_string())).flatten())
    }

    /// Files of shelf `oid` once loaded: `{path, original_path, code, untracked}`.
    #[func]
    fn shelf_files(&self, oid: GString) -> Array<VarDictionary> {
        self.read(|s| s.shelf_files(&oid.to_string()).map(convert::shelf_files))
            .flatten()
            .unwrap_or_default()
    }

    /// Shows the diff of `path` in shelf `oid` in the Changes view (its files
    /// must be loaded); `diff_changed` follows.
    #[func]
    fn select_shelf_file(&self, oid: GString, path: GString, full: bool) {
        let path = PathBuf::from(path.to_string());
        runtime_cell::with(|rt| rt.select_shelf_file(&self.key, &oid.to_string(), &path, full));
    }

    /// Shelves `paths` (every change when empty) on the current branch as
    /// `name`. Label `shelve`.
    #[func]
    fn shelve(&self, paths: PackedStringArray, name: GString) -> i64 {
        let paths: Vec<PathBuf> = paths
            .as_slice()
            .iter()
            .map(|p| PathBuf::from(p.to_string()))
            .collect();
        job_id(runtime_cell::with(|rt| rt.shelve(&self.key, paths, &name.to_string())).flatten())
    }

    /// Applies shelf `oid`, dropping it when that worked. Label `restore shelf`.
    #[func]
    fn restore_shelf(&self, oid: GString) -> i64 {
        job_id(runtime_cell::with(|rt| rt.restore_shelf(&self.key, &oid.to_string())).flatten())
    }

    /// Label `rename shelf`.
    #[func]
    fn rename_shelf(&self, oid: GString, name: GString) -> i64 {
        job_id(
            runtime_cell::with(|rt| {
                rt.rename_shelf(&self.key, &oid.to_string(), &name.to_string())
            })
            .flatten(),
        )
    }

    /// Drops shelf `oid` (`undo_shelf_discard` brings it back). Label
    /// `discard shelf`.
    #[func]
    fn discard_shelf(&self, oid: GString) -> i64 {
        job_id(runtime_cell::with(|rt| rt.discard_shelf(&self.key, &oid.to_string())).flatten())
    }

    #[func]
    fn can_undo_shelf_discard(&self) -> bool {
        self.read(RepoState::can_undo_shelf_discard)
            .unwrap_or(false)
    }

    /// Stores the last discarded shelf again. Label `undo shelf discard`.
    #[func]
    fn undo_shelf_discard(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.undo_shelf_discard(&self.key)).flatten())
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

    // --- Worktrees ----------------------------------------------------------

    /// Whether the worktree folder disappeared (see `missing`).
    #[func]
    fn is_missing(&self) -> bool {
        self.read(RepoState::is_missing).unwrap_or(false)
    }

    /// The main worktree (or bare repository) folder, or empty until known.
    #[func]
    fn main_worktree(&self) -> GString {
        self.read(|s| s.main_worktree().map(path_str))
            .flatten()
            .unwrap_or_default()
    }

    /// Where new tasks start (`origin/main`, ...), or empty.
    #[func]
    fn default_base(&self) -> GString {
        self.read(|s| s.default_base().map(|b| gstr(&b)))
            .flatten()
            .unwrap_or_default()
    }

    /// Folder for a new task on `branch`, from the `worktree_template` setting.
    #[func]
    fn worktree_path_for(&self, branch: GString) -> GString {
        runtime_cell::with(|rt| {
            let main = rt.repo(&self.key)?.main_worktree()?.to_path_buf();
            let template = rt.config().worktree_template.clone();
            Some(path_str(&worktree_path(
                &template,
                &main,
                &branch.to_string(),
            )))
        })
        .flatten()
        .unwrap_or_default()
    }

    /// The new-task flow: creates `branch` from `base` in a new worktree at
    /// `path`, fetching `fetch_remote` first (empty: no fetch); with
    /// `track_base`, `branch` tracks `base` (a remote branch of the same
    /// name). Label `new task`.
    #[func]
    fn new_task(
        &self,
        branch: GString,
        base: GString,
        path: GString,
        fetch_remote: GString,
        track_base: bool,
    ) -> i64 {
        let remote = fetch_remote.to_string();
        let task = NewTask {
            branch: branch.to_string(),
            base: base.to_string(),
            path: PathBuf::from(path.to_string()),
            fetch_remote: (!remote.is_empty()).then_some(remote),
            track_base,
        };
        job_id(runtime_cell::with(|rt| rt.new_task(&self.key, task)).flatten())
    }

    /// Checks out `branch` in a new worktree at `path`; a non-empty `start`
    /// creates the branch there first. Label `add worktree`.
    #[func]
    fn add_worktree(&self, path: GString, branch: GString, start: GString) -> i64 {
        let start = start.to_string();
        self.worktree_op(WorktreeOp::Add {
            path: PathBuf::from(path.to_string()),
            branch: branch.to_string(),
            start: (!start.is_empty()).then_some(start),
        })
    }

    /// `force` also removes one with local changes or a lock. Label `remove worktree`.
    #[func]
    fn remove_worktree(&self, path: GString, force: bool) -> i64 {
        self.worktree_op(WorktreeOp::Remove {
            path: PathBuf::from(path.to_string()),
            force,
        })
    }

    /// Label `lock worktree`.
    #[func]
    fn lock_worktree(&self, path: GString, reason: GString) -> i64 {
        self.worktree_op(WorktreeOp::Lock {
            path: PathBuf::from(path.to_string()),
            reason: reason.to_string(),
        })
    }

    /// Label `unlock worktree`.
    #[func]
    fn unlock_worktree(&self, path: GString) -> i64 {
        self.worktree_op(WorktreeOp::Unlock {
            path: PathBuf::from(path.to_string()),
        })
    }

    /// Forgets worktrees whose folders are gone. Label `prune worktrees`.
    #[func]
    fn prune_worktrees(&self) -> i64 {
        self.worktree_op(WorktreeOp::Prune)
    }

    /// Looks for worktrees to clean up; `cleanup_loaded` follows.
    #[func]
    fn load_cleanup(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.load_cleanup(&self.key)).flatten())
    }

    /// `{path, branch, reason, changed, ahead, locked}`; reason is `merged`
    /// or `upstream_gone`, changed is -1 when unknown.
    #[func]
    fn cleanup_candidates(&self) -> Array<VarDictionary> {
        self.read(|s| {
            let mut out = Array::new();
            for c in s.cleanup().unwrap_or_default() {
                out.push(&vdict! {
                    "path" => &path_str(&c.path),
                    "branch" => &gstr(&c.branch),
                    "reason" => match c.reason {
                        CleanupReason::Merged => "merged",
                        CleanupReason::UpstreamGone => "upstream_gone",
                    },
                    "changed" => c.changed.map_or(-1, to_i64),
                    "ahead" => i64::from(c.ahead),
                    "locked" => c.locked,
                });
            }
            out
        })
        .unwrap_or_default()
    }

    /// Removes worktrees (`{path, branch, force}` each) and, with
    /// `delete_branches`, their branches. Label `clean up worktrees`.
    #[func]
    fn cleanup(&self, items: Array<VarDictionary>, delete_branches: bool) -> i64 {
        let items: Vec<(PathBuf, String, bool)> = items
            .iter_shared()
            .map(|item| {
                let text = |key: &str| item.get(key).map(|v| v.to_string()).unwrap_or_default();
                let force = item
                    .get("force")
                    .and_then(|v| v.try_to::<bool>().ok())
                    .unwrap_or(false);
                (PathBuf::from(text("path")), text("branch"), force)
            })
            .collect();
        job_id(runtime_cell::with(|rt| rt.cleanup(&self.key, items, delete_branches)).flatten())
    }

    // --- Changes view ---------------------------------------------------------

    /// Changed files, shown by the filter or not.
    #[func]
    fn change_count(&self) -> i64 {
        self.read(|s| to_i64(s.changes().total())).unwrap_or(0)
    }

    /// Changed files the filter shows: conflicted first, then the rest by
    /// path. The `change_*` rows below are these.
    #[func]
    fn shown_change_count(&self) -> i64 {
        self.read(|s| to_i64(s.changes().len())).unwrap_or(0)
    }

    /// Shows only the changed files whose path contains `text` (any case),
    /// narrowed by `options`: any of `included`, `excluded`, `new`,
    /// `modified`, `deleted`. Rows change at once (no signal).
    #[func]
    fn set_change_filter(&self, text: GString, options: PackedStringArray) {
        let has = |id: &str| options.as_slice().iter().any(|o| *o == id);
        let filter = ChangeFilter {
            text: text.to_string(),
            included: has("included"),
            excluded: has("excluded"),
            new: has("new"),
            modified: has("modified"),
            deleted: has("deleted"),
        };
        runtime_cell::with(|rt| rt.set_change_filter(&self.key, filter));
    }

    /// Rows `start..start + count` of the changed files shown:
    /// `{path, original_path, code, pick, conflicted, as_staged}` (code is
    /// `M`, `A`, `D`, `R`, `?`, `U`, ...; pick is `all`, `none` or `partial`).
    #[func]
    fn change_rows(&self, start: i64, count: i64) -> Array<VarDictionary> {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| {
            let mut rows = Array::new();
            let Some(status) = s.status() else {
                return rows;
            };
            for &i in s.changes().indices().iter().skip(start).take(count) {
                rows.push(&convert::change_row(&status.changes[i], s.selection()));
            }
            rows
        })
        .unwrap_or_default()
    }

    /// Paths of rows `start..start + count`.
    #[func]
    fn change_paths(&self, start: i64, count: i64) -> PackedStringArray {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| {
            let Some(status) = s.status() else {
                return PackedStringArray::new();
            };
            s.changes()
                .indices()
                .iter()
                .skip(start)
                .take(count)
                .map(|&i| path_str(&status.changes[i].path))
                .collect()
        })
        .unwrap_or_default()
    }

    /// Row of `path`, or -1.
    #[func]
    fn change_index(&self, path: GString) -> i64 {
        let path = PathBuf::from(path.to_string());
        self.read(|s| {
            let status = s.status()?;
            s.changes()
                .indices()
                .iter()
                .position(|&i| status.changes[i].path == path)
                .map(to_i64)
        })
        .flatten()
        .unwrap_or(-1)
    }

    /// Files the next commit takes something of.
    #[func]
    fn picked_count(&self) -> i64 {
        self.read(|s| to_i64(s.selection().picked_count()))
            .unwrap_or(0)
    }

    /// Includes or excludes whole files in the commit. `selection_changed`
    /// follows on the next poll. Returns whether any file had a pick.
    #[func]
    fn pick_files(&self, paths: PackedStringArray, include: bool) -> bool {
        let paths: Vec<PathBuf> = paths
            .as_slice()
            .iter()
            .map(|p| PathBuf::from(p.to_string()))
            .collect();
        runtime_cell::with(|rt| rt.pick_files(&self.key, &paths, include)).unwrap_or(false)
    }

    /// The check-all box over the files shown: `all`, `none` or `partial`.
    #[func]
    fn selection_state(&self) -> GString {
        self.read(|s| GString::from(s.shown_selection_state().id()))
            .unwrap_or_else(|| GString::from("none"))
    }

    /// Includes or excludes every file shown.
    #[func]
    fn pick_all(&self, include: bool) {
        runtime_cell::with(|rt| rt.pick_all(&self.key, include));
    }

    /// Whether lines of the selected diff can be picked.
    #[func]
    fn can_pick_lines(&self) -> bool {
        self.read(RepoState::can_pick_lines).unwrap_or(false)
    }

    /// Picks or unpicks lines of the selected diff (`diff_lines` indices; a
    /// hunk header takes its whole hunk). Returns false when its lines
    /// cannot be picked.
    #[func]
    fn pick_lines(&self, lines: PackedInt32Array, include: bool) -> bool {
        let lines: Vec<usize> = lines
            .as_slice()
            .iter()
            .filter_map(|&l| usize::try_from(l).ok())
            .collect();
        runtime_cell::with(|rt| rt.pick_lines(&self.key, &lines, include)).unwrap_or(false)
    }

    /// Shows the diff of changed file `path` (against HEAD); `full` loads it
    /// past the size limit. `diff_changed` fires when it is loaded and after
    /// every reload.
    #[func]
    fn select_change(&self, path: GString, full: bool) {
        let path = PathBuf::from(path.to_string());
        runtime_cell::with(|rt| rt.select_change(&self.key, &path, full));
    }

    #[func]
    fn clear_diff(&self) {
        runtime_cell::with(|rt| rt.select_diff(&self.key, None, false));
    }

    /// See `convert::diff_info`: `{state, path, kind, content, notes, ...}`,
    /// plus `pickable` (lines can be picked) and `as_staged` (the file is
    /// committed exactly as staged outside gitbello).
    #[func]
    fn diff_info(&self) -> VarDictionary {
        self.read(|s| {
            let mut info = convert::diff_info(s.diff());
            info.set("pickable", s.can_pick_lines());
            info.set("as_staged", s.diff_as_staged());
            info
        })
        .unwrap_or_default()
    }

    /// Visible slice of the selected diff: `{index, kind, old, new, text,
    /// no_newline, picked}` (kind 0 = hunk header, 1 = context, 2 = added,
    /// 3 = removed; picked is `all`, `none`, `partial` or empty when lines
    /// cannot be picked). See `convert::diff_rows` for headers' expanders
    /// and the unchanged lines of open gaps (`index` -1).
    #[func]
    fn diff_lines(&self, start: i64, count: i64) -> Array<VarDictionary> {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| {
            let lines = convert::diff_rows(s.diff()?, false, start, count);
            for mut line in lines.iter_shared() {
                mark_picked(&mut line, s.diff_picks());
            }
            Some(lines)
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
            let rows = convert::diff_rows(state, true, start, count);
            if !commit {
                for row in rows.iter_shared() {
                    for side in ["left", "right"] {
                        if let Some(Ok(mut line)) =
                            row.get(side).map(|v| v.try_to::<VarDictionary>())
                        {
                            mark_picked(&mut line, s.diff_picks());
                        }
                    }
                }
            }
            Some(rows)
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
        self.read(|s| Some(convert::diff_rows(s.commit_diff()?, false, start, count)))
            .flatten()
            .unwrap_or_default()
    }

    /// Opens part of gap `gap` of a diff (`slot` is `changes` or `commit`;
    /// `how` is `up`, `down` or `all`, from a row's `expand`). The diff's
    /// changed signal follows, once the old file is read if needed.
    #[func]
    fn expand_diff(&self, slot: GString, gap: i64, how: GString) {
        let (Some(how), Ok(gap)) = (Expand::from_id(&how.to_string()), usize::try_from(gap)) else {
            return;
        };
        let slot = parse_slot(&slot);
        runtime_cell::with(|rt| rt.expand_diff(&self.key, slot, gap, how));
    }

    /// Shows every line of the file in a diff, or only its hunks again.
    #[func]
    fn show_whole_diff(&self, slot: GString, whole: bool) {
        let slot = parse_slot(&slot);
        runtime_cell::with(|rt| rt.show_whole_diff(&self.key, slot, whole));
    }

    /// Whether the selected diff's lines can be discarded (`mode` is
    /// `discard`).
    #[func]
    fn can_apply_lines(&self, mode: GString) -> bool {
        let Some(mode) = parse_mode(&mode) else {
            return false;
        };
        self.read(|s| s.can_apply_lines(mode)).unwrap_or(false)
    }

    /// Discards the selected diff lines from the working tree (`mode` is
    /// `discard`; `diff_lines` indices, a hunk header row takes its whole
    /// hunk). Returns the job id (label `discard`), or -1 when nothing applies.
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

    /// Restores `paths` to HEAD, index and working tree (untracked files are
    /// deleted; everything is backed up first for `undo_discard`).
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

    /// Whether `commit(…, amend)` can run now (the summary aside).
    #[func]
    fn can_commit(&self, amend: bool) -> bool {
        self.read(|s| s.can_commit(amend)).unwrap_or(false)
    }

    /// Why the selection cannot be committed now (`Nothing included`,
    /// `Resolve conflicts first`, ...), or "" when it can (the summary aside).
    #[func]
    fn commit_block_reason(&self, amend: bool) -> GString {
        match self.read(|s| s.commit_block_reason(amend)) {
            Some(reason) => GString::from(reason.unwrap_or_default()),
            None => GString::from("Opening the repository"),
        }
    }

    /// Commits the selection (or amends HEAD with it) through a temporary
    /// index. Returns the job id, or -1 when the summary is empty or nothing
    /// can be committed. The result arrives as `job_finished` with label
    /// `commit`; hook output is in the error's stderr.
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
    /// `kind, from, to, color` quadruples; kind 0 = pass, 1 = in, 2 = out),
    /// `refs` (`{name, kind, is_head}` labels; kind is branch, remote or tag)
    /// and `match` (whether the history search matches it; false without one).
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
            let search = state.search();
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
                    "match" => search.is_some_and(|s| s.is_match(row)),
                });
            }
            rows
        })
        .unwrap_or_default()
    }

    /// Finds the commits whose subject, author name or email contains `query`
    /// (any case), or whose hash starts with it (4+ hex digits). Results
    /// arrive with `search_changed`; the search follows the graph as it loads
    /// and reruns when it reloads. A blank query ends it.
    #[func]
    fn search_commits(&self, query: GString) {
        runtime_cell::with(|rt| rt.search_commits(&self.key, &query.to_string()));
    }

    /// The history search: `{query, matches, searched, done}` (match count,
    /// rows searched from the top); `{}` without a search.
    #[func]
    fn search_info(&self) -> VarDictionary {
        self.read(|state| {
            let Some(search) = state.search() else {
                return VarDictionary::new();
            };
            vdict! {
                "query" => &gstr(search.query()),
                "matches" => to_i64(search.match_count()),
                "searched" => to_i64(search.searched()),
                "done" => search.is_done(),
            }
        })
        .unwrap_or_default()
    }

    /// Position of graph row `row` among the matches (0-based), or -1.
    #[func]
    fn search_match_index(&self, row: i64) -> i64 {
        let Ok(row) = usize::try_from(row) else {
            return -1;
        };
        self.read(|state| state.search().and_then(|s| s.match_index(row)))
            .flatten()
            .map_or(-1, to_i64)
    }

    /// The next match after graph row `row` (before it when not `forward`),
    /// wrapping around, among the rows reported so far; -1 without matches.
    #[func]
    fn next_match(&self, row: i64, forward: bool) -> i64 {
        let row = usize::try_from(row).unwrap_or(0);
        let limit = self.reported_rows;
        self.read(|state| {
            let search = state.search()?;
            // Matches past the reported rows are not in the list yet.
            search
                .next_match(row, forward)
                .filter(|&found| found < limit)
                .or_else(|| {
                    let wrapped = if forward {
                        search.matches(0, 1).first().copied()
                    } else {
                        search.next_match(limit, false)
                    };
                    wrapped.filter(|&found| found < limit)
                })
        })
        .flatten()
        .map_or(-1, to_i64)
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

/// `commit` is the commit file diff; anything else the Changes diff.
fn parse_slot(id: &GString) -> DiffSlot {
    if *id == "commit" {
        DiffSlot::Commit
    } else {
        DiffSlot::Changes
    }
}

fn parse_mode(id: &GString) -> Option<PatchMode> {
    (*id == "discard").then_some(PatchMode::Discard)
}

/// Sets `picked` on a `diff_lines` row from the diff's line picks.
fn mark_picked(line: &mut VarDictionary, picks: &[PickState]) {
    let picked = line
        .get("index")
        .and_then(|v| v.try_to::<i64>().ok())
        .and_then(|i| usize::try_from(i).ok())
        .and_then(|i| picks.get(i))
        .map_or("", |p| p.id());
    line.set("picked", picked);
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

    fn checkout(&self, target: Option<CheckoutTarget>, changes: &GString) -> i64 {
        let (Some(target), Some(changes)) =
            (target, CheckoutChanges::from_id(&changes.to_string()))
        else {
            return -1;
        };
        job_id(runtime_cell::with(|rt| rt.checkout(&self.key, target, changes)).flatten())
    }

    fn ref_op(&self, op: RefOp) -> i64 {
        job_id(runtime_cell::with(|rt| rt.ref_op(&self.key, op)).flatten())
    }

    fn worktree_op(&self, op: WorktreeOp) -> i64 {
        job_id(runtime_cell::with(|rt| rt.worktree_op(&self.key, op)).flatten())
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
