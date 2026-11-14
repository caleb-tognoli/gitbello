use std::path::{Path, PathBuf};

use gitbello_core::blame::{BlameMinimap, BlameOptions};
use gitbello_core::changes::{commit_message, ChangeFilter, PickState};
use gitbello_core::compare::{CompareMode, CompareRequest, CompareSide, OnlyOn};
use gitbello_core::diff::image::{ImageSides, SideImage};
use gitbello_core::diff::minimap::{
    self, ConflictMinimap, DiffMinimap, MinimapPalette, MinimapSource, MinimapStyle, Rgba, StripMap,
};
use gitbello_core::diff::version::VersionSide;
use gitbello_core::diff::{Expand, PatchMode};
use gitbello_core::graph::{to_hex, LoadState};
use gitbello_core::ignore::{self, Untrack};
use gitbello_core::jobs::{JobId, RefreshSet};
use gitbello_core::merge::{BlockChoice, FileChoice, MergeMode, UndoMode};
use gitbello_core::ops::{CheckoutChanges, CheckoutTarget, NewTask, PullMode, RefOp, WorktreeOp};
use gitbello_core::runtime::{
    BranchDelete, DiffSlot, DiffState, FileHistoryRequest, FileSelection, RepoState,
};
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
    /// A reload behind the shown rows started or ended (`graph_reloading`).
    #[signal]
    fn graph_reloading_changed();
    /// Refreshes started or ended (`status_refreshing`).
    #[signal]
    fn refreshing_changed();
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
    /// The comparison loaded or failed (`compare_info`).
    #[signal]
    fn compare_changed();
    /// The compare file diff loaded or failed (`compare_diff_info`).
    #[signal]
    fn compare_diff_changed();
    /// The file history has more rows, ended, failed or was reloaded, its
    /// Uncommitted changes row came or went, or the selected version's
    /// commit arrived (`file_history_info`, `file_version_details`).
    #[signal]
    fn file_history_changed();
    /// The file history's diff loaded or failed (`slot_diff_info("file")`).
    #[signal]
    fn file_history_diff_changed();
    /// The blame has its text or more lines, ended, failed or ran again,
    /// or its focused commit changed or arrived (`blame_info`,
    /// `blame_details`).
    #[signal]
    fn blame_changed();
    /// The version `blame_before` looked for: its commit, or "" when the
    /// file's history has none.
    #[signal]
    fn blame_version_found(oid: GString);
    /// The worktree folder is gone; the session no longer refreshes.
    #[signal]
    fn missing();
    /// The file `open_version` asked for: `path`, or `error` (`error_dict`)
    /// when it could not be read.
    #[signal]
    fn version_ready(path: GString, error: VarDictionary);
    /// `load_cleanup` finished (`cleanup_candidates`).
    #[signal]
    fn cleanup_loaded();
    /// The info `load_branch_delete_info` returned `job` for arrived
    /// (`branch_delete_info`).
    #[signal]
    fn branch_delete_info_ready(job: i64);
    /// The files of shelf `oid` arrived (`shelf_files`).
    #[signal]
    fn shelf_files_loaded(oid: GString);
    #[signal]
    fn shelf_replaced(old_oid: GString, new_oid: GString);
    /// The history search found more, progressed, finished or was replaced
    /// (`search_info`, `match` in `graph_rows`).
    #[signal]
    fn search_changed();
    /// The preview requested with `load_merge_preview(target)` arrived
    /// (`merge_preview`).
    #[signal]
    fn merge_preview_ready(target: GString);
    /// The check requested with `load_rebase_check(target)` arrived
    /// (`rebase_check`).
    #[signal]
    fn rebase_check_ready(target: GString);
    /// The preview `load_ignore_preview` returned `job` for arrived
    /// (`ignore_preview`).
    #[signal]
    fn ignore_preview_ready(job: i64);
    /// The ignore rules arrived (`load_ignore_rules`, and again after each
    /// status while the viewer or "Show ignored files" shows them).
    #[signal]
    fn ignore_rules_ready(job: i64);
    /// HEAD's undoable commit or the commits HEAD lacks changed
    /// (`undoable_commit`, `in_head` in `graph_rows`).
    #[signal]
    fn head_changed();
    /// `undo_commit` finished; the undone commit's message.
    #[signal]
    fn commit_undone(summary: GString, body: GString);

    /// The key passed to every core call (the opened path, normalized).
    #[func]
    fn repo_path(&self) -> GString {
        path_str(&self.key)
    }

    /// Asks for `email`'s profile picture (once per email; nothing while
    /// pictures are off). This repository's remotes say which hosts to ask,
    /// and on GitHub the core finds a commit of `email` that GitHub knows.
    /// `AppCore.avatar_changed` says when it is there.
    #[func]
    fn request_avatar(&self, email: GString) {
        runtime_cell::with(|rt| rt.request_avatar(Some(&self.key), &email.to_string()));
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

    /// `{path, name, short_name, branch, head, detached, bare, locked,
    /// prunable, is_main, is_current, badge, changed, conflicts, ahead, behind,
    /// operation}`; `short_name` is the folder name without the repository's
    /// (see `worktrees::short_name`), `badge` the summary text (`3 ↑1`),
    /// `changed` is -1 until the worktree's status is known and `operation`
    /// an id as in `operation()`.
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
    /// `force_with_lease` force pushes against where the last fetch saw the
    /// remote branch (see `force_push`). Label `push`.
    #[func]
    fn push(&self, force_with_lease: bool) -> i64 {
        let lease = if force_with_lease {
            match self.read(RepoState::push_lease).flatten() {
                Some(lease) => Some(lease),
                None => return -1,
            }
        } else {
            None
        };
        job_id(runtime_cell::with(|rt| rt.push(&self.key, lease.as_deref())).flatten())
    }

    /// Force pushes the current branch, refused unless the remote branch is
    /// still at `expected` (a `push_lease()` read when the user was asked).
    /// Label `push`.
    #[func]
    fn force_push(&self, expected: GString) -> i64 {
        let expected = expected.to_string();
        job_id(runtime_cell::with(|rt| rt.push(&self.key, Some(&expected))).flatten())
    }

    /// The commit a force push expects on the remote: where the last fetch
    /// saw the branch it pushes to, empty when there was none.
    #[func]
    fn push_lease(&self) -> GString {
        self.read(RepoState::push_lease)
            .flatten()
            .map(|l| gstr(&l))
            .unwrap_or_default()
    }

    /// `{shared}` when the current branch diverged from its upstream only
    /// because you rewrote pushed commits (amend, rebase, reset), else `{}`.
    /// `shared`: the remote's default branch or a name like `main`.
    #[func]
    fn upstream_rewrite(&self) -> VarDictionary {
        self.read(RepoState::upstream_rewrite)
            .flatten()
            .map(|r| vdict! { "shared" => r.shared })
            .unwrap_or_default()
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

    #[func]
    fn restore_shelf_file(&self, oid: GString, path: GString) -> i64 {
        job_id(
            runtime_cell::with(|rt| {
                rt.restore_shelf_file(&self.key, &oid.to_string(), Path::new(&path.to_string()))
            })
            .flatten(),
        )
    }

    #[func]
    fn discard_shelf_file(&self, oid: GString, path: GString) -> i64 {
        job_id(
            runtime_cell::with(|rt| {
                rt.discard_shelf_file(&self.key, &oid.to_string(), Path::new(&path.to_string()))
            })
            .flatten(),
        )
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

    /// Works out what deleting local `branch` would do;
    /// `branch_delete_info_ready(job)` follows.
    #[func]
    fn load_branch_delete_info(&self, branch: GString) -> i64 {
        job_id(
            runtime_cell::with(|rt| rt.load_branch_delete_info(&self.key, &branch.to_string()))
                .flatten(),
        )
    }

    /// `{branch, base, not_in_base, ahead, remote, worktree, is_head}`;
    /// `remote` is the remote branch (`origin/x`) while the remote has it,
    /// else "", `worktree` the other worktree that has it checked out, else
    /// "". Empty until it arrived.
    #[func]
    fn branch_delete_info(&self) -> VarDictionary {
        self.read(|s| {
            s.branch_delete_info().map(|info| {
                vdict! {
                    "branch" => &gstr(&info.branch),
                    "base" => &gstr(info.base.as_deref().unwrap_or("")),
                    "not_in_base" => i64::from(info.not_in_base),
                    "ahead" => i64::from(info.ahead),
                    "remote" => &gstr(&info.remote.as_ref().map(|r| r.short_name()).unwrap_or_default()),
                    "worktree" => &info.worktree.as_deref().map_or_else(GString::new, path_str),
                    "is_head" => info.is_head,
                }
            })
        })
        .flatten()
        .unwrap_or_default()
    }

    /// Deletes local branch `branch` (unless "", merged or not), remote
    /// branch `remote` (`origin/x`, unless "") and first worktree `worktree`
    /// (unless "", `force_worktree` discarding its changes or lock). A
    /// failure stops before the local branch goes. Label `delete branch`, or
    /// `delete remote branch` without a local branch; Undo with
    /// `undo_branch_delete(branch, else remote)`.
    #[func]
    fn delete_branch_with(
        &self,
        branch: GString,
        remote: GString,
        worktree: GString,
        force_worktree: bool,
    ) -> i64 {
        let (branch, remote, worktree) =
            (branch.to_string(), remote.to_string(), worktree.to_string());
        job_id(
            runtime_cell::with(|rt| {
                let remote = if remote.is_empty() {
                    None
                } else {
                    Some(rt.repo(&self.key)?.split_remote_branch(&remote)?)
                };
                let delete = BranchDelete {
                    branch: (!branch.is_empty()).then_some(branch),
                    remote,
                    worktree: (!worktree.is_empty())
                        .then(|| (PathBuf::from(worktree), force_worktree)),
                };
                rt.delete_branch(&self.key, delete)
            })
            .flatten(),
        )
    }

    /// Whether the delete of `id` (the local branch, else the remote branch
    /// `origin/x`) can be undone.
    #[func]
    fn can_undo_branch_delete(&self, id: GString) -> bool {
        self.read(|s| s.can_undo_branch_delete(&id.to_string()))
            .unwrap_or(false)
    }

    /// Puts back the delete of `id` (see `can_undo_branch_delete`): the local
    /// branch, the remote branch and the upstream. Label `undo branch delete`.
    #[func]
    fn undo_branch_delete(&self, id: GString) -> i64 {
        job_id(runtime_cell::with(|rt| rt.undo_branch_delete(&self.key, &id.to_string())).flatten())
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
    fn delete_tag(&self, name: GString, remote: GString) -> i64 {
        let remote = remote.to_string();
        job_id(
            runtime_cell::with(|rt| {
                rt.delete_tag(
                    &self.key,
                    &name.to_string(),
                    (!remote.is_empty()).then_some(remote),
                )
            })
            .flatten(),
        )
    }

    /// Applies commit `oid` on top of HEAD. Label `cherry-pick`.
    #[func]
    fn cherry_pick(&self, oid: GString) -> i64 {
        self.ref_op(RefOp::CherryPick {
            commits: vec![oid.to_string()],
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

    // --- Merge workflows (PLAN §4, M7) ---------------------------------------

    /// Works out what merging `target` (branch, remote branch, tag or commit)
    /// into HEAD would do; `merge_preview_ready(target)` follows.
    #[func]
    fn load_merge_preview(&self, target: GString) -> i64 {
        let target = target.to_string();
        job_id(runtime_cell::with(|rt| rt.load_merge_preview(&self.key, &target)).flatten())
    }

    /// See `convert::merge_preview`; empty until it arrived.
    #[func]
    fn merge_preview(&self) -> VarDictionary {
        self.read(|s| s.merge_preview().map(convert::merge_preview))
            .flatten()
            .unwrap_or_default()
    }

    /// Merges `target` into HEAD. `mode` is `default`, `no_ff`, `squash` or
    /// `ff_only`; an empty `message` means git's. With `shelve`, local
    /// changes are shelved first and restored after a clean merge. Label
    /// `merge`; conflicts fail with the `conflict` kind and leave the merge
    /// in progress.
    #[func]
    fn merge(&self, target: GString, mode: GString, message: GString, shelve: bool) -> i64 {
        let Some(mode) = MergeMode::from_id(&mode.to_string()) else {
            return -1;
        };
        let (target, message) = (target.to_string(), message.to_string());
        let message = (!message.trim().is_empty()).then_some(message);
        job_id(
            runtime_cell::with(|rt| rt.merge(&self.key, &target, mode, message, shelve)).flatten(),
        )
    }

    /// Works out what rebasing the current branch onto `target` would do,
    /// commit by commit; `rebase_check_ready(target)` follows.
    #[func]
    fn load_rebase_check(&self, target: GString) -> i64 {
        let target = target.to_string();
        job_id(runtime_cell::with(|rt| rt.load_rebase_check(&self.key, &target)).flatten())
    }

    /// See `convert::rebase_check`; empty until it arrived.
    #[func]
    fn rebase_check(&self) -> VarDictionary {
        self.read(|s| s.rebase_check().map(convert::rebase_check))
            .flatten()
            .unwrap_or_default()
    }

    /// Rebases the current branch onto `target`. With `shelve`, local
    /// changes are shelved first and restored after a clean rebase. Label
    /// `rebase`; conflicts fail with the `conflict` kind and leave the
    /// rebase in progress. A clean one can be undone (`undo_rebase`).
    #[func]
    fn rebase(&self, target: GString, shelve: bool) -> i64 {
        let target = target.to_string();
        job_id(runtime_cell::with(|rt| rt.rebase(&self.key, &target, shelve)).flatten())
    }

    /// Moves the branch back to before the rebase the undo strip offers
    /// (`undoable_commit().rebase_onto`). Label `undo rebase`.
    #[func]
    fn undo_rebase(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.undo_rebase(&self.key)).flatten())
    }

    /// See `convert::operation_info`; empty with no operation in progress.
    #[func]
    fn operation_info(&self) -> VarDictionary {
        self.read(convert::operation_info).unwrap_or_default()
    }

    /// What the commit box does: `normal`, `merge`, `cherry_pick` or `rebase`.
    #[func]
    fn commit_mode(&self) -> GString {
        self.read(|s| GString::from(s.commit_mode().id()))
            .unwrap_or_else(|| GString::from("normal"))
    }

    /// Finishes the operation once no conflict is left: commits a merge or
    /// cherry-pick with the message (git's when the summary is empty), or
    /// continues a rebase. Label `continue`; -1 when it cannot.
    #[func]
    fn continue_operation(&self, summary: GString, body: GString) -> i64 {
        let message = commit_message(&summary.to_string(), &body.to_string());
        job_id(runtime_cell::with(|rt| rt.continue_operation(&self.key, message)).flatten())
    }

    /// Skips the commit a rebase stopped at. Label `skip`.
    #[func]
    fn skip_operation(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.skip_operation(&self.key)).flatten())
    }

    /// Resolves block `block` of the conflicted file shown (`choice`:
    /// `ours`, `theirs`, `ours_theirs`, `theirs_ours`). Label `resolve
    /// conflict`; the file is staged once no block is left.
    #[func]
    fn resolve_block(&self, path: GString, block: i64, choice: GString) -> i64 {
        let (Some(choice), Ok(block)) = (
            BlockChoice::from_id(&choice.to_string()),
            usize::try_from(block),
        ) else {
            return -1;
        };
        let path = PathBuf::from(path.to_string());
        job_id(runtime_cell::with(|rt| rt.resolve_block(&self.key, &path, block, choice)).flatten())
    }

    /// Whether a block choice can be undone.
    #[func]
    fn can_undo_block_choice(&self) -> bool {
        self.read(RepoState::can_undo_block_choice).unwrap_or(false)
    }

    /// Undoes the last block choice. Label `undo conflict choice`.
    #[func]
    fn undo_block_choice(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.undo_block_choice(&self.key)).flatten())
    }

    /// Resolves conflicted `path` whole (`choice`: `ours`, `theirs`, `keep`
    /// or `delete`). Label `resolve conflict`.
    #[func]
    fn resolve_file(&self, path: GString, choice: GString) -> i64 {
        let Some(choice) = FileChoice::from_id(&choice.to_string()) else {
            return -1;
        };
        let path = PathBuf::from(path.to_string());
        job_id(runtime_cell::with(|rt| rt.resolve_file(&self.key, &path, choice)).flatten())
    }

    /// Brings back the conflicts of a resolved file. Label `reopen conflicts`.
    #[func]
    fn reopen_conflicts(&self, path: GString) -> i64 {
        let path = PathBuf::from(path.to_string());
        job_id(runtime_cell::with(|rt| rt.reopen_conflicts(&self.key, &path, false)).flatten())
    }

    /// Recreates the conflicts of `path` with the base in the markers (and
    /// shows the base). Label `reopen conflicts`.
    #[func]
    fn recreate_conflicts_with_base(&self, path: GString) -> i64 {
        let path = PathBuf::from(path.to_string());
        job_id(runtime_cell::with(|rt| rt.reopen_conflicts(&self.key, &path, true)).flatten())
    }

    /// Shows or hides the base of each conflict in the resolver;
    /// `diff_changed` follows.
    #[func]
    fn show_conflict_base(&self, show: bool) {
        runtime_cell::with(|rt| rt.show_conflict_base(&self.key, show));
    }

    /// See `convert::undoable_commit`.
    #[func]
    fn undoable_commit(&self) -> VarDictionary {
        self.read(convert::undoable_commit).unwrap_or_default()
    }

    /// Undoes HEAD commit `oid` (`mode`: `keep_changes`, or `remove_merge`
    /// for a merge commit). Label `undo commit`; `commit_undone` follows.
    #[func]
    fn undo_commit(&self, oid: GString, mode: GString) -> i64 {
        let Some(mode) = UndoMode::from_id(&mode.to_string()) else {
            return -1;
        };
        let oid = oid.to_string();
        job_id(runtime_cell::with(|rt| rt.undo_commit(&self.key, &oid, mode)).flatten())
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
    /// `delete_branches`, their branches, with `delete_remotes` on their
    /// remote too. Label `clean up worktrees`.
    #[func]
    fn cleanup(
        &self,
        items: Array<VarDictionary>,
        delete_branches: bool,
        delete_remotes: bool,
    ) -> i64 {
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
        job_id(
            runtime_cell::with(|rt| rt.cleanup(&self.key, items, delete_branches, delete_remotes))
                .flatten(),
        )
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

    /// Ignored files among the rows shown ("Show ignored files"); they are
    /// the last rows.
    #[func]
    fn shown_ignored_count(&self) -> i64 {
        self.read(|s| to_i64(s.changes().ignored())).unwrap_or(0)
    }

    /// Shows only the changed files whose path contains `text` (any case),
    /// narrowed by `options`: any of `included`, `excluded`, `new`,
    /// `modified`, `deleted`, `endings_only`, and `ignored` (also list ignored
    /// files, last). Rows change at once (no signal).
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
            endings_only: has("endings_only"),
            ignored: has("ignored"),
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
            let Some(status) = s.changes_status() else {
                return rows;
            };
            for &i in s.changes().indices().iter().skip(start).take(count) {
                rows.push(&convert::change_row(&status.changes[i], s));
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
            let Some(status) = s.changes_status() else {
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
            let status = s.changes_status()?;
            s.changes()
                .indices()
                .iter()
                .position(|&i| status.changes[i].path == path)
                .map(to_i64)
        })
        .flatten()
        .unwrap_or(-1)
    }

    /// Paths of the checked files the filter shows (all or part picked),
    /// conflicted ones left out.
    #[func]
    fn shown_picked_paths(&self) -> PackedStringArray {
        self.read(|s| s.shown_picked_paths().iter().map(|p| path_str(p)).collect())
            .unwrap_or_default()
    }

    /// Files the next commit takes something of.
    #[func]
    fn picked_count(&self) -> i64 {
        self.read(|s| to_i64(s.picked_count())).unwrap_or(0)
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
    /// A conflicted file shows its conflicts instead: see
    /// `convert::conflict_info`.
    #[func]
    fn diff_info(&self) -> VarDictionary {
        self.read(|s| {
            if let Some(conflict) = s.conflict() {
                return convert::conflict_info(conflict, s.conflict_shows_base());
            }
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
            if let Some(conflict) = s.conflict() {
                return Some(convert::conflict_rows(conflict, false, start, count));
            }
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
        let slot = parse_slot(&slot);
        self.read(|s| {
            if let (DiffSlot::Changes, Some(conflict)) = (slot, s.conflict()) {
                return Some(convert::conflict_rows(conflict, true, start, count));
            }
            let state = slot_diff(s, slot)?;
            let rows = convert::diff_rows(state, true, start, count);
            if slot == DiffSlot::Changes {
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

    /// The syntax token kinds in id order, `{name, parent}`: the `syntax`
    /// triples of diff rows and the minimap palette's syntax colours use
    /// these ids.
    #[func]
    fn syntax_kinds() -> Array<VarDictionary> {
        convert::syntax_kinds()
    }

    /// Minimap rows `first_row..first_row + rows` of a diff (`slot` as for
    /// `diff_split_rows`; the resolver's file in `changes`) as RGBA8 bytes,
    /// `columns` wide and `rows * row_px` high, `char_px` per character.
    /// `palette` holds `minimap::PALETTE_LEN` colours: the row backgrounds
    /// (context, header, added, removed, ours, theirs, base, resolved), the
    /// text, the gap dashes, the veil over lines left out, the changed words
    /// of added and removed lines, then one colour per syntax token kind
    /// (`syntax_kinds()` order).
    /// Empty when there is no diff or the palette is short.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn diff_minimap_tile(
        &self,
        slot: GString,
        split: bool,
        first_row: i64,
        rows: i64,
        columns: i64,
        row_px: i64,
        char_px: i64,
        palette: PackedColorArray,
    ) -> PackedByteArray {
        let colors: Vec<Rgba> = palette.as_slice().iter().map(rgba).collect();
        let (Some(palette), Ok(first), Ok(rows), Ok(columns), Ok(row_px), Ok(char_px)) = (
            MinimapPalette::from_colors(&colors),
            usize::try_from(first_row),
            usize::try_from(rows),
            usize::try_from(columns),
            usize::try_from(row_px),
            usize::try_from(char_px),
        ) else {
            return PackedByteArray::new();
        };
        let style = MinimapStyle {
            columns: columns.min(4096),
            row_px: row_px.clamp(1, 64),
            char_px: char_px.clamp(1, 16),
            palette,
        };
        let rows = rows.min(4096);
        self.with_minimap(&slot, split, |source| {
            PackedByteArray::from(minimap::render_tile(source, first, rows, &style).as_slice())
        })
        .unwrap_or_default()
    }

    /// The marks of a whole diff in `buckets` slices from the top: one byte
    /// of flags each, 1 added, 2 removed, 4 conflict, 8 left out of the
    /// commit, 16 resolved this session. With `whole_file`, the strip spans
    /// the file: the lines collapsed gaps hide take their room.
    #[func]
    fn diff_overview(
        &self,
        slot: GString,
        split: bool,
        buckets: i64,
        whole_file: bool,
    ) -> PackedByteArray {
        let buckets = usize::try_from(buckets).unwrap_or(0).min(16_384);
        self.with_minimap(&slot, split, |source| {
            PackedByteArray::from(minimap::overview(source, buckets, whole_file).as_slice())
        })
        .unwrap_or_default()
    }

    /// Where (fractional) row `row` starts on the strip, `0..1`
    /// (`whole_file` as for `diff_overview`).
    #[func]
    fn diff_strip_position(&self, slot: GString, split: bool, row: f64, whole_file: bool) -> f64 {
        self.with_minimap(&slot, split, |source| {
            StripMap::new(source, whole_file).position(row)
        })
        .unwrap_or(0.0)
    }

    /// The (fractional) row at `fraction` of the strip and the collapsed
    /// gap there: `{row, gap}`, `gap` -1 outside one.
    #[func]
    fn diff_strip_target(
        &self,
        slot: GString,
        split: bool,
        fraction: f64,
        whole_file: bool,
    ) -> VarDictionary {
        let (row, gap) = self
            .with_minimap(&slot, split, |source| {
                StripMap::new(source, whole_file).target(fraction)
            })
            .unwrap_or((0.0, None));
        vdict! {
            "row" => row,
            "gap" => gap.and_then(|g| i64::try_from(g).ok()).unwrap_or(-1),
        }
    }

    /// The first row of the next change block after `from_row` (`forward`)
    /// or before it, wrapping past either end, in the rows of `slot`'s diff
    /// as for `diff_overview`. -1 without changes.
    #[func]
    fn diff_change_row(&self, slot: GString, split: bool, from_row: i64, forward: bool) -> i64 {
        let from = usize::try_from(from_row).unwrap_or(0);
        if slot == BLAME_SLOT {
            // The blame's blocks of changes are the focused commit's runs.
            return self
                .read(|s| {
                    let blame = s.blame()?;
                    blame.table().next_run_of(blame.focus()?, from, forward)
                })
                .flatten()
                .map_or(-1, to_i64);
        }
        self.with_minimap(&slot, split, |source| {
            minimap::change_row(source, from, forward)
        })
        .flatten()
        .and_then(|row| i64::try_from(row).ok())
        .unwrap_or(-1)
    }

    // --- Compare (M7.12) ----------------------------------------------------

    /// Opens a comparison of `left` (any revision) with `right` (a revision,
    /// or the working copy when `working`), replacing any other; `mode` is
    /// `fork`, `exact` or "" for the default. `compare_changed` follows.
    #[func]
    fn open_compare(&self, left: GString, right: GString, working: bool, mode: GString) {
        let request = CompareRequest {
            left: left.to_string(),
            right: if working {
                CompareSide::WorkingCopy
            } else {
                CompareSide::Rev(right.to_string())
            },
            mode: CompareMode::parse(&mode.to_string()),
        };
        runtime_cell::with(|rt| rt.open_compare(&self.key, request));
    }

    /// `fork`, `exact` or "" (the default) for the open comparison.
    #[func]
    fn set_compare_mode(&self, mode: GString) {
        let mode = CompareMode::parse(&mode.to_string());
        runtime_cell::with(|rt| rt.set_compare_mode(&self.key, mode));
    }

    #[func]
    fn reload_compare(&self) {
        runtime_cell::with(|rt| rt.reload_compare(&self.key));
    }

    #[func]
    fn close_compare(&self) {
        runtime_cell::with(|rt| rt.close_compare(&self.key));
    }

    /// See `convert::compare_info`.
    #[func]
    fn compare_info(&self) -> VarDictionary {
        self.read(|s| convert::compare_info(s.compare()))
            .unwrap_or_else(|| convert::compare_info(None))
    }

    /// Shows only the files whose path contains `text` (any case); a path in
    /// double quotes shows only the file at exactly that path.
    #[func]
    fn set_compare_filter(&self, text: GString) {
        runtime_cell::with(|rt| rt.set_compare_filter(&self.key, &text.to_string()));
    }

    /// The files the filter shows, rows `start..start + count`
    /// (`convert::compare_file_row`).
    #[func]
    fn compare_files(&self, start: i64, count: i64) -> Array<VarDictionary> {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| {
            let mut rows = Array::new();
            if let Some(compare) = s.compare() {
                let end = start.saturating_add(count).min(compare.shown_count());
                for index in start..end {
                    if let Some(file) = compare.shown_file(index) {
                        rows.push(&convert::compare_file_row(file));
                    }
                }
            }
            rows
        })
        .unwrap_or_default()
    }

    /// The row of `path` among the shown files, or -1.
    #[func]
    fn compare_file_index(&self, path: GString) -> i64 {
        let path = PathBuf::from(path.to_string());
        self.read(|s| s.compare()?.shown_index(&path))
            .flatten()
            .map_or(-1, to_i64)
    }

    /// Shows the diff of `path` in the comparison; `compare_diff_changed` follows.
    #[func]
    fn select_compare_file(&self, path: GString, full: bool) {
        let path = PathBuf::from(path.to_string());
        runtime_cell::with(|rt| rt.select_compare_file(&self.key, Some(&path), full));
    }

    /// Commits only on one side, rows `start..start + count`, the right
    /// side's first (`convert::compare_commit_row`).
    #[func]
    fn compare_commits(&self, start: i64, count: i64) -> Array<VarDictionary> {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| {
            let mut rows = Array::new();
            if let Some(compare) = s.compare() {
                let end = start.saturating_add(count).min(compare.commit_count());
                for index in start..end {
                    if let Some(commit) = compare.commit(index) {
                        rows.push(&convert::compare_commit_row(commit, s.labels(&commit.oid)));
                    }
                }
            }
            rows
        })
        .unwrap_or_default()
    }

    /// The details of the commit the comparison is narrowed to, shaped as
    /// `commit_info` (empty until they load).
    #[func]
    fn compare_focus_details(&self) -> VarDictionary {
        self.read(|s| {
            let commit = s.compare()?.focus_details()?;
            let mut info = convert::commit_info(commit);
            info.set("refs", &convert::labels(s.labels(&commit.oid)));
            Some(info)
        })
        .flatten()
        .unwrap_or_default()
    }

    /// The row of commit `oid` among `compare_commits`, or -1.
    #[func]
    fn compare_commit_index(&self, oid: GString) -> i64 {
        let oid = oid.to_string();
        self.read(|s| s.compare()?.commit_index(&oid))
            .flatten()
            .map_or(-1, to_i64)
    }

    /// Narrows the files to commit `oid`'s own ("" for the whole
    /// comparison again); `compare_changed` follows.
    #[func]
    fn focus_compare_commit(&self, oid: GString) {
        let oid = oid.to_string();
        let oid = (!oid.is_empty()).then_some(oid);
        runtime_cell::with(|rt| rt.focus_compare_commit(&self.key, oid.as_deref()));
    }

    /// Writes `paths` as the `left` or `right` side has them into the
    /// working copy, backed up for `undo_discard`. Label `restore from
    /// revision`; -1 when that side is the working copy.
    #[func]
    fn restore_compare_files(&self, paths: PackedStringArray, side: GString) -> i64 {
        let paths = path_list(&paths);
        let side = if side == "left" {
            OnlyOn::Left
        } else {
            OnlyOn::Right
        };
        job_id(runtime_cell::with(|rt| rt.restore_compare_files(&self.key, &paths, side)).flatten())
    }

    /// Applies `oids` on top of HEAD in that order (oldest first). Label
    /// `cherry-pick`.
    #[func]
    fn cherry_pick_commits(&self, oids: PackedStringArray) -> i64 {
        self.ref_op(RefOp::CherryPick {
            commits: oids.as_slice().iter().map(|o| o.to_string()).collect(),
        })
    }

    #[func]
    fn clear_compare_diff(&self) {
        runtime_cell::with(|rt| rt.select_compare_file(&self.key, None, false));
    }

    /// Like `diff_info`, for the compare file diff.
    #[func]
    fn compare_diff_info(&self) -> VarDictionary {
        self.read(|s| convert::diff_info(s.compare_diff()))
            .unwrap_or_default()
    }

    /// Like `diff_lines`, for the compare file diff.
    #[func]
    fn compare_diff_lines(&self, start: i64, count: i64) -> Array<VarDictionary> {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| Some(convert::diff_rows(s.compare_diff()?, false, start, count)))
            .flatten()
            .unwrap_or_default()
    }

    // --- File history (M8a) ------------------------------------------------

    /// Opens the history of `path` (repository-relative), replacing any
    /// other. `start` is the revision it is read from, or "" for HEAD,
    /// which the history then follows; `start_name` is what the view calls
    /// a fixed start. `file_history_changed` follows, again as rows arrive.
    #[func]
    fn open_file_history(&self, path: GString, start: GString, start_name: GString) {
        let start = start.to_string();
        let request = FileHistoryRequest {
            path: PathBuf::from(path.to_string()),
            start: (!start.is_empty()).then_some(start),
            start_name: start_name.to_string(),
        };
        runtime_cell::with(|rt| rt.open_file_history(&self.key, request));
    }

    #[func]
    fn close_file_history(&self) {
        runtime_cell::with(|rt| rt.close_file_history(&self.key));
    }

    /// See `convert::file_history_info`.
    #[func]
    fn file_history_info(&self) -> VarDictionary {
        self.read(|s| convert::file_history_info(s.file_history(), s.file_history_working()))
            .unwrap_or_else(|| convert::file_history_info(None, None))
    }

    /// Shows only the commits whose subject, author, co-authors or hash
    /// (from its start) contain `text`, any case; "" shows them all. The
    /// Uncommitted changes row hides while a filter is on.
    /// `file_history_changed` follows.
    #[func]
    fn set_file_history_filter(&self, text: GString) {
        runtime_cell::with(|rt| rt.set_file_history_filter(&self.key, &text.to_string()));
    }

    /// The versions the filter shows, `start..start + count`, newest first
    /// (`convert::file_version_row`). The Uncommitted changes row is not
    /// among them (`file_history_info`'s `has_working`).
    #[func]
    fn file_history_rows(&self, start: i64, count: i64) -> Array<VarDictionary> {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| {
            let mut rows = Array::new();
            if let Some(history) = s.file_history() {
                for version in history.rows(start, count) {
                    rows.push(&convert::file_version_row(&version, s.labels(&version.oid)));
                }
            }
            rows
        })
        .unwrap_or_default()
    }

    /// The row of commit `oid` among `file_history_rows`, or -1.
    #[func]
    fn file_history_index(&self, oid: GString) -> i64 {
        let oid = oid.to_string();
        self.read(|s| s.file_history()?.index_of(&oid))
            .flatten()
            .map_or(-1, to_i64)
    }

    /// Shows the diff of the file in commit `oid` against its first parent,
    /// or of the uncommitted changes for "" (`slot_diff_info("file")`,
    /// `file_history_diff_changed`); the commit's details follow as
    /// `file_history_changed` (`file_version_details`).
    #[func]
    fn select_file_version(&self, oid: GString, full: bool) {
        let oid = oid.to_string();
        let selection = if oid.is_empty() {
            FileSelection::Working
        } else {
            FileSelection::Version(oid)
        };
        runtime_cell::with(|rt| rt.select_file_version(&self.key, Some(selection), full));
    }

    #[func]
    fn clear_file_diff(&self) {
        runtime_cell::with(|rt| rt.select_file_version(&self.key, None, false));
    }

    /// The selected version's commit, shaped as `commit_info` plus `refs`
    /// (empty until it loads, and for the uncommitted changes).
    #[func]
    fn file_version_details(&self) -> VarDictionary {
        self.read(|s| {
            let commit = s.file_history()?.details()?;
            let mut info = convert::commit_info(commit);
            info.set("refs", &convert::labels(s.labels(&commit.oid)));
            Some(info)
        })
        .flatten()
        .unwrap_or_default()
    }

    /// Writes the file as commit `oid` has it into the working copy, under
    /// the name the history was opened with, backed up for `undo_discard`.
    /// Label `restore from revision`; -1 when that commit deleted the file.
    #[func]
    fn restore_file_version(&self, oid: GString) -> i64 {
        let oid = oid.to_string();
        job_id(runtime_cell::with(|rt| rt.restore_file_version(&self.key, &oid)).flatten())
    }

    // --- Blame (M8b) --------------------------------------------------------

    /// Blames the open file history's file as version `oid` has it (the
    /// working copy for ""), with `git blame`'s `-w` and `-M` as asked.
    /// `blame_changed` follows, again as lines arrive. The same blame is
    /// kept; a version without the file closes the blame.
    #[func]
    fn blame_file_version(&self, oid: GString, ignore_whitespace: bool, detect_moves: bool) {
        let oid = oid.to_string();
        let selection = if oid.is_empty() {
            FileSelection::Working
        } else {
            FileSelection::Version(oid)
        };
        let options = BlameOptions {
            ignore_whitespace,
            detect_moves,
        };
        runtime_cell::with(|rt| rt.blame_file_version(&self.key, &selection, options));
    }

    #[func]
    fn close_blame(&self) {
        runtime_cell::with(|rt| rt.close_blame(&self.key));
    }

    /// See `convert::blame_info`.
    #[func]
    fn blame_info(&self) -> VarDictionary {
        self.read(|s| convert::blame_info(s.blame()))
            .unwrap_or_else(|| convert::blame_info(None))
    }

    /// See `convert::blame_rows`.
    #[func]
    fn blame_lines(&self, start: i64, count: i64) -> Array<VarDictionary> {
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| Some(convert::blame_rows(s.blame()?, start, count)))
            .flatten()
            .unwrap_or_default()
    }

    /// See `convert::blame_line`.
    #[func]
    fn blame_line(&self, line: i64) -> VarDictionary {
        let Ok(line) = usize::try_from(line) else {
            return VarDictionary::new();
        };
        self.read(|s| Some(convert::blame_line(s.blame()?, line)))
            .flatten()
            .unwrap_or_default()
    }

    /// Focuses commit `oid` of the blame ("" for none): its lines are
    /// flagged in `blame_lines` and its details load (`blame_details`).
    /// `blame_changed` follows.
    #[func]
    fn focus_blame_commit(&self, oid: GString) {
        let oid = oid.to_string();
        runtime_cell::with(|rt| {
            rt.focus_blame_commit(&self.key, (!oid.is_empty()).then_some(oid.as_str()));
        });
    }

    /// The focused commit, shaped as `commit_info` plus `refs` (empty until
    /// it loads, and for lines not committed yet).
    #[func]
    fn blame_details(&self) -> VarDictionary {
        self.read(|s| {
            let commit = s.blame()?.details()?;
            let mut info = convert::commit_info(commit);
            info.set("refs", &convert::labels(s.labels(&commit.oid)));
            Some(info)
        })
        .flatten()
        .unwrap_or_default()
    }

    /// Looks for the version of the file that line `line` (0-based) came
    /// from, before the commit it is blamed on; `blame_version_found`
    /// carries it. Label `find blamed version`; -1 when that commit added
    /// the line with the file.
    #[func]
    fn blame_before(&self, line: i64) -> i64 {
        let Ok(line) = usize::try_from(line) else {
            return -1;
        };
        job_id(runtime_cell::with(|rt| rt.blame_before(&self.key, line)).flatten())
    }

    /// Like `diff_info`, for the diff in `slot` (`changes`, `commit`,
    /// `compare` or `file`).
    #[func]
    fn slot_diff_info(&self, slot: GString) -> VarDictionary {
        let slot = parse_slot(&slot);
        self.read(|s| convert::diff_info(slot_diff(s, slot)))
            .unwrap_or_default()
    }

    /// Like `diff_lines`, for the diff in `slot`, without commit picks.
    #[func]
    fn slot_diff_lines(&self, slot: GString, start: i64, count: i64) -> Array<VarDictionary> {
        let slot = parse_slot(&slot);
        let start = usize::try_from(start).unwrap_or(0);
        let count = usize::try_from(count).unwrap_or(0);
        self.read(|s| Some(convert::diff_rows(slot_diff(s, slot)?, false, start, count)))
            .flatten()
            .unwrap_or_default()
    }

    // --- Commit details -----------------------------------------------------

    /// Loads a commit's details (full or unique hash); `commit_loaded` follows.
    #[func]
    fn load_commit(&self, oid: GString) {
        runtime_cell::with(|rt| rt.load_commit(&self.key, &oid.to_string()));
    }

    /// See `convert::commit_info`, plus `refs` (the commit's labels, as in
    /// `graph_rows`); empty until a commit loaded.
    #[func]
    fn commit_info(&self) -> VarDictionary {
        self.read(|s| {
            s.commit().map(|commit| {
                let mut info = convert::commit_info(commit);
                info.set("refs", &convert::labels(s.labels(&commit.oid)));
                info
            })
        })
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

    /// Open: the file of `side` (`shown`, `old` or `new`) in diff `slot`
    /// (`changes`, where a conflict shows its file, or `commit`): the working
    /// copy, or a version written to the cache. `version_ready` follows.
    /// Returns whether it started.
    #[func]
    fn open_version(&self, slot: GString, side: GString) -> bool {
        let Some(side) = VersionSide::parse(&side.to_string()) else {
            return false;
        };
        let slot = parse_slot(&slot);
        runtime_cell::with(|rt| rt.open_version(&self.key, slot, side).is_some()).unwrap_or(false)
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

    /// One side (`old` or `new`; ours and theirs of a conflict) of the image
    /// diff in `slot` (`changes` or `commit`): `diff_info`'s `image` side
    /// plus its `bytes` (empty unless `state` is `image`). Called once per
    /// side `id`; the UI decodes the bytes.
    #[func]
    fn image_side(&self, slot: GString, side: GString) -> VarDictionary {
        let new = side == "new";
        self.with_images(&slot, |images| {
            let side = if new { &images.new } else { &images.old };
            let mut info = convert::image_side_info(side);
            let bytes = match side {
                SideImage::Loaded { bytes, .. } => PackedByteArray::from(&bytes[..]),
                _ => PackedByteArray::new(),
            };
            info.set("bytes", &bytes);
            info
        })
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

    /// Puts back the line endings (and final newline) the unstaged changes
    /// of `paths` changed, keeping their text; backed up first for
    /// `undo_discard`. Label `restore line endings`.
    #[func]
    fn restore_line_endings(&self, paths: PackedStringArray) -> i64 {
        let paths = path_list(&paths);
        job_id(runtime_cell::with(|rt| rt.restore_line_endings(&self.key, paths)).flatten())
    }

    /// Whether `restore_line_endings(paths)` has something to restore: a
    /// file whose only changes are line endings, or the Changes diff's file
    /// showing ending changes.
    #[func]
    fn can_restore_line_endings(&self, paths: PackedStringArray) -> bool {
        let paths = path_list(&paths);
        self.read(|s| s.can_restore_endings(&paths))
            .unwrap_or(false)
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

    // --- Ignore rules (M7.7a, docs/IGNORE_RULES.md) ---------------------------

    /// The rules offered for `paths`, relative to the `.gitignore` in `dir`
    /// ("" for the root), narrowest first. See `convert::ignore_suggestions`.
    #[func]
    fn ignore_suggestions(&self, paths: PackedStringArray, dir: GString) -> Array<VarDictionary> {
        let list = ignore::suggestions(&path_list(&paths), Path::new(&dir.to_string()));
        convert::ignore_suggestions(&list)
    }

    /// Folders with a `.gitignore` above every one of `paths`, "" (the root,
    /// listed even without one) first.
    #[func]
    fn ignore_files(&self, paths: PackedStringArray) -> PackedStringArray {
        runtime_cell::with(|rt| rt.ignore_files(&self.key, &path_list(&paths)))
            .unwrap_or_default()
            .iter()
            .map(|p| path_str(p))
            .collect()
    }

    /// Works out what `rule` (`{pattern, target, dir}`, see
    /// `convert::ignore_rule`) would do; `ignore_preview_ready(job)` follows.
    #[func]
    fn load_ignore_preview(&self, rule: VarDictionary) -> i64 {
        let Some(rule) = convert::ignore_rule(&rule) else {
            return -1;
        };
        job_id(runtime_cell::with(|rt| rt.load_ignore_preview(&self.key, rule)).flatten())
    }

    /// See `convert::ignore_preview`; empty until it arrived.
    #[func]
    fn ignore_preview(&self) -> VarDictionary {
        runtime_cell::with(|rt| rt.ignore_preview(&self.key).map(convert::ignore_preview))
            .flatten()
            .unwrap_or_default()
    }

    /// Adds `rule` to its file. `untrack` is `keep`, `remove` (stop tracking
    /// the files it matches) or `refuse` (fail with `tracked_matches` when
    /// any are tracked). Label `ignore`.
    #[func]
    fn add_ignore_rule(&self, rule: VarDictionary, untrack: GString) -> i64 {
        let untrack = match untrack.to_string().as_str() {
            "keep" => Untrack::Keep,
            "remove" => Untrack::Remove,
            "refuse" => Untrack::RefuseIfTracked,
            _ => return -1,
        };
        let Some(rule) = convert::ignore_rule(&rule) else {
            return -1;
        };
        job_id(runtime_cell::with(|rt| rt.add_ignore_rule(&self.key, rule, untrack)).flatten())
    }

    #[func]
    fn can_undo_ignore(&self) -> bool {
        runtime_cell::with(|rt| rt.can_undo_ignore(&self.key)).unwrap_or(false)
    }

    /// Takes back the most recent ignore edit. Label `undo ignore`.
    #[func]
    fn undo_ignore(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.undo_ignore(&self.key)).flatten())
    }

    // --- Ignore rules viewer (M7.7b) ------------------------------------------

    /// Works out every ignore file, its lines and what each decides;
    /// `ignore_rules_ready(job)` follows.
    #[func]
    fn load_ignore_rules(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.load_ignore_rules(&self.key)).flatten())
    }

    /// While `open`, the rules are reloaded after every status (the viewer).
    #[func]
    fn watch_ignore_rules(&self, open: bool) {
        runtime_cell::with(|rt| rt.watch_ignore_rules(&self.key, open));
    }

    #[func]
    fn has_ignore_rules(&self) -> bool {
        self.read(|s| s.ignore_rules().is_some()).unwrap_or(false)
    }

    /// See `convert::ignore_sources`; empty until the rules arrived.
    #[func]
    fn ignore_sources(&self) -> Array<VarDictionary> {
        self.read(|s| s.ignore_rules().map(convert::ignore_sources))
            .flatten()
            .unwrap_or_default()
    }

    /// Lines of source `source` (an index into `ignore_sources`); see
    /// `convert::ignore_lines`.
    #[func]
    fn ignore_lines(&self, source: i64) -> Array<VarDictionary> {
        let source = usize::try_from(source).unwrap_or(usize::MAX);
        self.read(|s| {
            let src = s.ignore_rules()?.source(source)?;
            Some(convert::ignore_lines(&src.lines))
        })
        .flatten()
        .unwrap_or_default()
    }

    /// Rows `ignore_hidden` has for line `line` of source `source`.
    #[func]
    fn ignore_hidden_count(&self, source: i64, line: i64) -> i64 {
        let (source, line) = (index(source), index(line));
        self.read(|s| {
            let line = s.ignore_rules()?.line(source, line)?;
            Some(to_i64(line.tracked.len() + line.hidden.len()))
        })
        .flatten()
        .unwrap_or(0)
    }

    /// Rows `start..start + count` of what line `line` of source `source`
    /// decides; see `convert::ignore_hidden`.
    #[func]
    fn ignore_hidden(
        &self,
        source: i64,
        line: i64,
        start: i64,
        count: i64,
    ) -> Array<VarDictionary> {
        let (source, line) = (index(source), index(line));
        let (start, count) = (index(start), index(count));
        self.read(|s| {
            let line = s.ignore_rules()?.line(source, line)?;
            Some(convert::ignore_hidden(line, start, count))
        })
        .flatten()
        .unwrap_or_default()
    }

    /// Removes a rule line (undoable). Label `remove ignore rule`; -1 for a
    /// comment or blank line.
    #[func]
    fn remove_ignore_rule(&self, source: i64, line: i64) -> i64 {
        let (source, line) = (index(source), index(line));
        job_id(runtime_cell::with(|rt| rt.remove_ignore_rule(&self.key, source, line)).flatten())
    }

    /// Stops tracking the tracked files a line matches (undoable). Label
    /// `stop tracking ignored files`.
    #[func]
    fn untrack_ignored(&self, source: i64, line: i64) -> i64 {
        let (source, line) = (index(source), index(line));
        job_id(runtime_cell::with(|rt| rt.untrack_ignored(&self.key, source, line)).flatten())
    }

    /// Makes git stop ignoring `path`, a row of "Show ignored files"
    /// (undoable). Label `stop ignoring`.
    #[func]
    fn stop_ignoring(&self, path: GString) -> i64 {
        let path = PathBuf::from(path.to_string());
        job_id(runtime_cell::with(|rt| rt.stop_ignoring(&self.key, &path)).flatten())
    }

    /// How Stop ignoring would go for `path`: `{action: "remove"|"negate",
    /// source, line, pattern, negation, target}`; empty when it cannot.
    #[func]
    fn stop_ignoring_plan(&self, path: GString) -> VarDictionary {
        let path = PathBuf::from(path.to_string());
        self.read(|s| {
            let rules = s.ignore_rules()?;
            let (source, line) = rules.ignored_by(&path)?;
            let (src, at) = (rules.source(source)?, rules.line(source, line)?);
            let entry = rules
                .ignored
                .iter()
                .map(|(e, _)| e)
                .find(|e| e.path == path)?;
            let mut out = vdict! {
                "source" => &gstr(&src.name),
                "line" => to_i64(at.number),
                "pattern" => &gstr(&at.text),
            };
            match ignore::unignore(src, at, entry) {
                ignore::Unignore::RemoveLine => out.set("action", "remove"),
                ignore::Unignore::Negate { target, line } => {
                    out.set("action", "negate");
                    out.set("negation", &gstr(&line));
                    out.set(
                        "target",
                        match target {
                            ignore::IgnoreTarget::Shared { .. } => "shared",
                            ignore::IgnoreTarget::Local => "local",
                            ignore::IgnoreTarget::Global => "global",
                        },
                    );
                }
            }
            Some(out)
        })
        .flatten()
        .unwrap_or_default()
    }

    /// The rule lines of template `name` the root `.gitignore` lacks, one
    /// per line ("" when it has them all, or before the rules arrived).
    #[func]
    fn ignore_template_lines(&self, name: GString) -> GString {
        runtime_cell::with(|rt| rt.ignore_template_lines(&self.key, &name.to_string()))
            .flatten()
            .map(|s| gstr(&s))
            .unwrap_or_default()
    }

    /// A folder of untracked files worth ignoring: `{folder, count}`, or
    /// empty.
    #[func]
    fn ignore_hint(&self) -> VarDictionary {
        runtime_cell::with(|rt| rt.ignore_hint(&self.key))
            .flatten()
            .map(|(folder, count)| {
                vdict! {
                    "folder" => &path_str(&folder),
                    "count" => to_i64(count),
                }
            })
            .unwrap_or_default()
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

    #[func]
    fn begin_amend(&self, head: GString) -> i64 {
        job_id(runtime_cell::with(|rt| rt.begin_amend(&self.key, &head.to_string())).flatten())
    }

    #[func]
    fn cancel_amend(&self) {
        runtime_cell::with(|rt| rt.cancel_amend(&self.key));
    }

    #[func]
    fn is_amending(&self) -> bool {
        self.read(|s| s.is_amending()).unwrap_or(false)
    }

    #[func]
    fn amend_requires_force_push(&self) -> bool {
        self.read(|s| s.amend_requires_force_push())
            .unwrap_or(false)
    }

    /// Reads HEAD's message; arrives as `head_message_loaded`.
    #[func]
    fn load_head_message(&self) -> i64 {
        job_id(runtime_cell::with(|rt| rt.load_head_message(&self.key)).flatten())
    }

    /// Whether a status has been read (the first one can take a while).
    #[func]
    fn has_status(&self) -> bool {
        self.read(|state| state.status().is_some()).unwrap_or(false)
    }

    /// Whether the status is being read again (after a file change, a job or
    /// focus): what Changes shows may be about to change.
    #[func]
    fn status_refreshing(&self) -> bool {
        self.read(|state| {
            state
                .refreshing()
                .contains(gitbello_core::jobs::RefreshKind::Status)
        })
        .unwrap_or(false)
    }

    /// Whether the history is loading again behind the rows shown.
    #[func]
    fn graph_reloading(&self) -> bool {
        self.read(|state| state.graph_reloading()).unwrap_or(false)
    }

    /// Whether the History view shows this session: a hidden history does not
    /// reload until it is shown again.
    #[func]
    fn set_history_visible(&self, visible: bool) {
        runtime_cell::with(|rt| rt.set_history_visible(&self.key, visible));
    }

    #[func]
    fn set_history_all_branches(&self, all: bool) {
        let scope = if all {
            gitbello_core::graph::HistoryScope::AllBranches
        } else {
            gitbello_core::graph::HistoryScope::CurrentBranch
        };
        runtime_cell::with(|rt| rt.set_history_scope(&self.key, scope));
    }

    #[func]
    fn history_info(&self) -> VarDictionary {
        self.read(|state| {
            let info = state.history_tracking();
            vdict! {
                "all_branches" => state.history_scope() == gitbello_core::graph::HistoryScope::AllBranches,
                "ready" => info.is_some(),
                "upstream" => &gstr(info.and_then(|i| i.upstream.as_deref()).unwrap_or("")),
                "gone" => info.is_some_and(|i| i.upstream_gone),
                "outgoing" => to_i64(info.map_or(0, |i| i.outgoing.len())),
            }
        }).unwrap_or_default()
    }

    #[func]
    fn graph_find_commit(&self, oid: GString) -> i64 {
        self.read(|state| state.graph()?.index().row_for_oid(&oid.to_string()))
            .flatten()
            .filter(|&row| row < self.reported_rows)
            .map_or(-1, to_i64)
    }

    #[func]
    fn commit_is_outgoing(&self, oid: GString) -> bool {
        self.read(|state| state.is_outgoing(&oid.to_string()))
            .unwrap_or(false)
    }

    /// Rows reported through `graph_changed` so far.
    #[func]
    fn graph_row_count(&self) -> i64 {
        to_i64(self.reported_rows)
    }

    /// Full parent object ids mapped to their reported graph rows; unresolved
    /// parents and invalid source rows are omitted.
    #[func]
    fn graph_parent_rows(&self, row: i64) -> VarDictionary {
        let Ok(row) = usize::try_from(row) else {
            return VarDictionary::new();
        };
        if row >= self.reported_rows {
            return VarDictionary::new();
        }
        self.read(|state| {
            let mut rows = VarDictionary::new();
            let Some(loader) = state.graph() else {
                return rows;
            };
            let index = loader.index();
            if let Some(commit) = index.commit(row) {
                for parent in commit.parent_rows {
                    if parent < self.reported_rows {
                        rows.set(&gstr(&to_hex(index.hash(parent))), to_i64(parent));
                    }
                }
            }
            rows
        })
        .unwrap_or_default()
    }

    /// Visible slice of the graph. Each row is a Dictionary with `row`, `hash`,
    /// `subject`, `author`, `email`, `time` (unix seconds), `coauthors`
    /// (`[{name, email}]`, the author left out), `column`, `color`,
    /// `width` (columns used), `segments` (PackedInt32Array of
    /// `kind, from, to, color` quadruples; kind 0 = pass, 1 = in, 2 = out),
    /// `refs` (`{name, kind, is_head, remote, remotes}` labels; kind is branch,
    /// remote or tag; `remote` names a remote branch's remote; `remotes` lists
    /// the remote branches merged into a local one)
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
                    "coauthors" => &convert::identities(&commit.coauthors),
                    "column" => i64::from(layout.column),
                    "color" => i64::from(layout.color),
                    "width" => i64::from(layout.width()),
                    "segments" => &segments,
                    "refs" => &convert::labels(state.labels(&hash)),
                    "match" => search.is_some_and(|s| s.is_match(row)),
                    "in_head" => state.in_head(&hash),
                    "outgoing" => state.is_outgoing(&hash),
                });
            }
            rows
        })
        .unwrap_or_default()
    }

    /// Finds the commits whose subject, author or co-author name or email contains `query`
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

    /// Where the history search's matches are among the rows reported so
    /// far, in `buckets` slices from the top: one byte each, 1 for a match.
    #[func]
    fn search_overview(&self, buckets: i64) -> PackedByteArray {
        let buckets = usize::try_from(buckets).unwrap_or(0).min(16_384);
        let rows = self.reported_rows;
        self.read(|state| state.search().map(|s| s.overview(rows, buckets)))
            .flatten()
            .map(|flags| PackedByteArray::from(flags.as_slice()))
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
/// `changes`, `commit` or `compare`.
/// The slot id the minimap and change-row calls take for the blame.
const BLAME_SLOT: &str = "blame";

fn parse_slot(id: &GString) -> DiffSlot {
    if *id == "commit" {
        DiffSlot::Commit
    } else if *id == "compare" {
        DiffSlot::Compare
    } else if *id == "file" {
        DiffSlot::File
    } else {
        DiffSlot::Changes
    }
}

/// The diff shown in `slot`.
fn slot_diff(s: &RepoState, slot: DiffSlot) -> Option<&DiffState> {
    match slot {
        DiffSlot::Changes => s.diff(),
        DiffSlot::Commit => s.commit_diff(),
        DiffSlot::Compare => s.compare_diff(),
        DiffSlot::File => s.file_diff(),
    }
}

fn parse_mode(id: &GString) -> Option<PatchMode> {
    (*id == "discard").then_some(PatchMode::Discard)
}

/// Sets `picked` on a `diff_lines` row from the diff's line picks.
fn mark_picked(line: &mut VarDictionary, picks: &[PickState]) {
    // An empty side of a side-by-side row stays empty.
    if line.is_empty() {
        return;
    }
    let picked = line
        .get("index")
        .and_then(|v| v.try_to::<i64>().ok())
        .and_then(|i| usize::try_from(i).ok())
        .and_then(|i| picks.get(i))
        .map_or("", |p| p.id());
    line.set("picked", picked);
}

fn rgba(color: &Color) -> Rgba {
    let byte = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
    [byte(color.r), byte(color.g), byte(color.b), byte(color.a)]
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

    /// Calls `f` with the minimap rows of `slot`'s diff, or of the
    /// resolver's file in `changes`.
    fn with_images<R>(&self, slot: &GString, f: impl FnOnce(&ImageSides) -> R) -> Option<R> {
        let slot = parse_slot(slot);
        self.read(|s| {
            if let (DiffSlot::Changes, Some(conflict)) = (slot, s.conflict()) {
                return conflict.images().map(f);
            }
            slot_diff(s, slot)?.images().map(f)
        })
        .flatten()
    }

    fn with_minimap<R>(
        &self,
        slot: &GString,
        split: bool,
        f: impl FnOnce(&dyn MinimapSource) -> R,
    ) -> Option<R> {
        if *slot == BLAME_SLOT {
            return self
                .read(|s| {
                    let blame = s.blame()?;
                    let table = blame.table();
                    Some(f(&BlameMinimap::new(&table, blame.focus())))
                })
                .flatten();
        }
        let slot = parse_slot(slot);
        self.read(|s| {
            if let (DiffSlot::Changes, Some(conflict)) = (slot, s.conflict()) {
                let file = conflict.file()?;
                return Some(f(&ConflictMinimap::new(
                    file,
                    conflict.layout(),
                    conflict.resolved(),
                    split,
                    conflict.syntax(),
                    conflict.line_states(),
                )));
            }
            let state = slot_diff(s, slot)?;
            let picks = if slot == DiffSlot::Changes && s.can_pick_lines() {
                s.diff_picks()
            } else {
                &[]
            };
            Some(f(&DiffMinimap::new(
                state.diff()?,
                state.layout(),
                state.old_file(),
                picks,
                split,
                state.syntax(),
                state.line_states(),
            )))
        })
        .flatten()
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

/// A GDScript index (negative ones match nothing).
fn index(value: i64) -> usize {
    usize::try_from(value).unwrap_or(usize::MAX)
}

/// `paths` from GDScript as paths.
fn path_list(paths: &PackedStringArray) -> Vec<PathBuf> {
    paths
        .as_slice()
        .iter()
        .map(|p| PathBuf::from(p.to_string()))
        .collect()
}
