//! Core models to Godot dictionaries and arrays. Conversion only.

use std::path::Path;

use gitbello_core::blame::BlameLoad;
use gitbello_core::changes::{change_code, is_conflicted, FilePick};
use gitbello_core::compare::{
    CompareCommit, CompareFile, CompareMode, CompareSide, OnlyOn, RecentComparison, ResolvedSide,
};
use gitbello_core::diff::eol::{EndingSummary, FinalNewline, Marker};
use gitbello_core::diff::image::{ImageSides, SideImage};
use gitbello_core::diff::{
    changed_ranges, display_text,
    viewer::{self, Offered},
    DiffContent, DiffKind, FileDiff, LayoutRow, LineKind,
};
use gitbello_core::file_history::FileVersion;
use gitbello_core::git::{GitError, GitErrorKind};
use gitbello_core::highlight::{highlight, language_for, Language};
use gitbello_core::ignore::{
    IgnoreLine, IgnorePreview, IgnoreRule, IgnoreRules, IgnoreTarget, Suggestion,
};
use gitbello_core::merge::{
    ConflictFile, ConflictKind, ConflictRow, ConflictRowKind, MergePreview,
};
use gitbello_core::repo::{
    Change, CommitDetails, CommitFile, Conflict, FileChange, FileState, Head, Operation, Ref,
    RefKind, RepoStatus, Shelf, ShelfFile, StashEntry, Worktree,
};
use gitbello_core::runtime::{
    BlameState, CompareState, ConflictState, DiffState, FileHistoryState, FileSelection, RepoState,
    WorkingVersion,
};
use gitbello_core::sidebar::{operation_label, Badge, BranchNode, LabelKind, RefLabel};
use godot::prelude::*;

pub fn gstr(text: &str) -> GString {
    GString::from(text)
}

pub fn path_str(path: &Path) -> GString {
    GString::from(path.to_string_lossy().as_ref())
}

pub fn to_i64(value: usize) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

/// Stable snake_case id for an error kind, for GDScript to match on.
pub fn error_kind_id(kind: GitErrorKind) -> &'static str {
    match kind {
        GitErrorKind::GitNotFound => "git_not_found",
        GitErrorKind::VersionTooOld => "version_too_old",
        GitErrorKind::Spawn => "spawn",
        GitErrorKind::Io => "io",
        GitErrorKind::NotARepository => "not_a_repository",
        GitErrorKind::AuthFailed => "auth_failed",
        GitErrorKind::NonFastForward => "non_fast_forward",
        GitErrorKind::Conflict => "conflict",
        GitErrorKind::LockExists => "lock_exists",
        GitErrorKind::Cancelled => "cancelled",
        GitErrorKind::UnexpectedOutput => "unexpected_output",
        GitErrorKind::Stale => "stale",
        GitErrorKind::LocalChanges => "local_changes",
        GitErrorKind::Diverged => "diverged",
        GitErrorKind::NoUpstream => "no_upstream",
        GitErrorKind::NoRemote => "no_remote",
        GitErrorKind::NotFullyMerged => "not_fully_merged",
        GitErrorKind::CheckedOutElsewhere => "checked_out_elsewhere",
        GitErrorKind::AlreadyExists => "already_exists",
        GitErrorKind::InUse => "in_use",
        GitErrorKind::FolderLeft => "folder_left",
        GitErrorKind::TrackedMatches => "tracked_matches",
        GitErrorKind::UnknownRevision => "unknown_revision",
        _ => "other",
    }
}

/// `{kind, title, message, command, stderr, exit_code}`; `message` is the
/// first `fatal:` or `error:` line of stderr (else its first line that is
/// not a hint or progress), `title` the human-readable kind.
pub fn error_dict(error: &GitError) -> VarDictionary {
    let lines = || {
        error
            .stderr
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
    };
    let message = lines()
        .find_map(|l| {
            l.strip_prefix("fatal: ")
                .or_else(|| l.strip_prefix("error: "))
        })
        .or_else(|| {
            lines().find(|l| {
                !["hint:", "remote:", "To ", "From "]
                    .iter()
                    .any(|p| l.starts_with(p))
            })
        })
        .unwrap_or_default();
    vdict! {
        "kind" => error_kind_id(error.kind),
        "title" => &gstr(&error.kind.to_string()),
        "message" => &gstr(message),
        "command" => &gstr(&error.command),
        "stderr" => &gstr(&error.stderr),
        "exit_code" => error.exit_code.map_or(-1, i64::from),
    }
}

pub fn badge_dict(badge: &Badge) -> VarDictionary {
    vdict! {
        "changed" => to_i64(badge.changed),
        "conflicts" => to_i64(badge.conflicts),
        "ahead" => i64::from(badge.ahead),
        "behind" => i64::from(badge.behind),
        "unpublished" => badge.unpublished,
        "operation" => &gstr(badge.operation.map_or("", operation_label)),
        "head" => &gstr(&badge.head),
        "summary" => &gstr(&badge.summary()),
    }
}

pub fn operation_id(operation: Option<Operation>) -> &'static str {
    match operation {
        None => "",
        Some(Operation::Merge) => "merge",
        Some(Operation::CherryPick) => "cherry_pick",
        Some(Operation::Revert) => "revert",
        Some(Operation::Rebase { .. }) => "rebase",
        Some(Operation::ApplyMailbox) => "am",
        Some(Operation::Bisect) => "bisect",
    }
}

fn change_id(change: Change) -> &'static str {
    match change {
        Change::Unmodified => "",
        Change::Modified => "modified",
        Change::TypeChanged => "typechange",
        Change::Added => "added",
        Change::Deleted => "deleted",
        Change::Renamed => "renamed",
        Change::Copied => "copied",
    }
}

/// The status letter the file lists show: `M`, `A`, `D`, `R`, `C`, `T`.
fn change_letter(change: Change) -> &'static str {
    match change {
        Change::Modified => "M",
        Change::Added => "A",
        Change::Deleted => "D",
        Change::Renamed => "R",
        Change::Copied => "C",
        Change::TypeChanged => "T",
        Change::Unmodified => "",
    }
}

fn conflict_id(conflict: Conflict) -> &'static str {
    match conflict {
        Conflict::BothDeleted => "both_deleted",
        Conflict::AddedByUs => "added_by_us",
        Conflict::DeletedByThem => "deleted_by_them",
        Conflict::AddedByThem => "added_by_them",
        Conflict::DeletedByUs => "deleted_by_us",
        Conflict::BothAdded => "both_added",
        Conflict::BothModified => "both_modified",
    }
}

fn change_dict(change: &FileChange) -> VarDictionary {
    let (index, worktree, conflict) = match change.state {
        FileState::Tracked { index, worktree } => (change_id(index), change_id(worktree), ""),
        FileState::Unmerged(c) => ("", "", conflict_id(c)),
        FileState::Untracked => ("", "untracked", ""),
        FileState::Ignored => ("", "ignored", ""),
    };
    vdict! {
        "path" => &path_str(&change.path),
        "original_path" => &change.original_path.as_deref().map_or_else(GString::new, path_str),
        "index" => index,
        "worktree" => worktree,
        "conflict" => conflict,
        "staged" => change.is_staged(),
        "unstaged" => change.is_unstaged(),
        "submodule" => change.submodule,
    }
}

pub fn status_dict(status: &RepoStatus) -> VarDictionary {
    let (head, detached) = match &status.head {
        Head::Branch(name) => (name.as_str(), false),
        Head::Detached => ("", true),
        Head::Unknown => ("", false),
    };
    let mut changes = Array::<VarDictionary>::new();
    for change in status
        .changes
        .iter()
        .filter(|c| c.state != FileState::Ignored)
    {
        changes.push(&change_dict(change));
    }
    vdict! {
        "head" => head,
        "detached" => detached,
        "oid" => &gstr(status.oid.as_deref().unwrap_or_default()),
        "upstream" => &gstr(status.upstream.as_deref().unwrap_or_default()),
        "ahead" => i64::from(status.ahead),
        "behind" => i64::from(status.behind),
        "stash_count" => i64::from(status.stash_count),
        "changes" => &changes,
    }
}

fn ref_dict(r: &Ref) -> VarDictionary {
    let upstream = r
        .upstream
        .as_deref()
        .map(|u| u.strip_prefix("refs/remotes/").unwrap_or(u))
        .unwrap_or_default();
    vdict! {
        "name" => &gstr(&r.name),
        "short_name" => &gstr(&r.short_name),
        "commit" => &gstr(r.commit()),
        "is_head" => r.is_head,
        "upstream" => &gstr(upstream),
        "ahead" => i64::from(r.tracking.ahead),
        "behind" => i64::from(r.tracking.behind),
        "gone" => r.tracking.gone,
        "worktree" => &r.worktree.as_deref().map_or_else(GString::new, path_str),
        "committed_at" => r.committed_at.unwrap_or(0),
    }
}

/// Nested `{name, ref, children}` dictionaries; `ref` is the ref's dictionary
/// (see [`ref_dict`]) for branches and empty for folders.
pub fn branch_tree(nodes: &[BranchNode], refs: &[Ref]) -> Array<VarDictionary> {
    let mut out = Array::new();
    for node in nodes {
        let r = node
            .ref_name
            .as_deref()
            .and_then(|name| refs.iter().find(|r| r.name == name))
            .map(ref_dict)
            .unwrap_or_default();
        out.push(&vdict! {
            "name" => &gstr(&node.name),
            "ref" => &r,
            "children" => &branch_tree(&node.children, refs),
        });
    }
    out
}

/// Local and remote branches as [`ref_dict`]s plus `kind` (`branch` or
/// `remote`), locals first; symbolic refs such as `origin/HEAD` are left out.
pub fn branch_refs(refs: &[Ref]) -> Array<VarDictionary> {
    let mut out = Array::new();
    for kind in ["branch", "remote"] {
        for r in refs.iter().filter(|r| r.symref_target.is_none()) {
            let matches = match r.kind {
                RefKind::Branch => kind == "branch",
                RefKind::RemoteBranch { .. } => kind == "remote",
                _ => false,
            };
            if matches {
                let mut dict = ref_dict(r);
                dict.set("kind", kind);
                out.push(&dict);
            }
        }
    }
    out
}

pub fn tags(refs: &[Ref]) -> Array<VarDictionary> {
    let mut out = Array::new();
    let mut tags: Vec<&Ref> = refs.iter().filter(|r| r.kind == RefKind::Tag).collect();
    tags.sort_by(|a, b| b.short_name.cmp(&a.short_name));
    for tag in tags {
        out.push(&vdict! {
            "name" => &gstr(&tag.short_name),
            "commit" => &gstr(tag.commit()),
            "annotated" => tag.peeled.is_some(),
        });
    }
    out
}

pub fn stashes(entries: &[StashEntry]) -> Array<VarDictionary> {
    let mut out = Array::new();
    for s in entries {
        out.push(&vdict! {
            "index" => to_i64(s.index),
            "message" => &gstr(&s.message),
            "branch" => &gstr(s.branch.as_deref().unwrap_or_default()),
            "time" => s.time,
            "oid" => &gstr(&s.oid),
        });
    }
    out
}

/// Shelf rows: `{oid, branch, name, auto, made_here, time}`.
pub fn shelves(list: &[Shelf]) -> Array<VarDictionary> {
    let mut out = Array::new();
    for s in list {
        out.push(&vdict! {
            "oid" => &gstr(&s.oid),
            "branch" => &gstr(s.branch.as_deref().unwrap_or_default()),
            "name" => &gstr(&s.name),
            "auto" => s.auto,
            "made_here" => s.made_here,
            "time" => s.time,
        });
    }
    out
}

/// A shelf's files: `{path, original_path, code, untracked}`.
pub fn shelf_files(files: &[ShelfFile]) -> Array<VarDictionary> {
    let mut out = Array::new();
    for f in files {
        let code = match f.change {
            _ if f.untracked => "?",
            Change::Unmodified => "M",
            change => change_letter(change),
        };
        out.push(&vdict! {
            "path" => &path_str(&f.path),
            "original_path" => &f.original_path.as_deref().map_or_else(GString::new, path_str),
            "code" => code,
            "untracked" => f.untracked,
        });
    }
    out
}

/// Worktree rows. `badge` gives the live badge of a worktree path (the
/// current one from its own status, linked ones from their badge refresh).
pub fn worktrees(
    list: &[Worktree],
    current: Option<&Path>,
    badge: impl Fn(&Worktree, bool) -> Option<Badge>,
) -> Array<VarDictionary> {
    let mut out = Array::new();
    let main = list
        .iter()
        .find(|wt| wt.is_main)
        .map(|wt| wt.path.as_path());
    for wt in list {
        let is_current = current.is_some_and(|c| same_path(c, &wt.path));
        let badge = badge(wt, is_current);
        out.push(&vdict! {
            "badge" => &gstr(&badge.as_ref().map(Badge::summary).unwrap_or_default()),
            "changed" => badge.as_ref().map_or(-1, |b| to_i64(b.changed)),
            "conflicts" => badge.as_ref().map_or(0, |b| to_i64(b.conflicts)),
            "ahead" => badge.as_ref().map_or(0, |b| i64::from(b.ahead)),
            "behind" => badge.as_ref().map_or(0, |b| i64::from(b.behind)),
            "unpublished" => badge.as_ref().is_some_and(|b| b.unpublished),
            "operation" => &gstr(operation_id(badge.as_ref().and_then(|b| b.operation))),
            "path" => &path_str(&wt.path),
            "name" => &gstr(&wt.path.file_name().map_or_else(|| wt.path.to_string_lossy(), |n| n.to_string_lossy())),
            "short_name" => &gstr(&gitbello_core::worktrees::short_name(&wt.path, main)),
            "branch" => &gstr(wt.branch_name().unwrap_or_default()),
            "head" => &gstr(wt.head.as_deref().unwrap_or_default()),
            "detached" => wt.detached,
            "bare" => wt.bare,
            "locked" => wt.locked.is_some(),
            "lock_reason" => &gstr(wt.locked.as_deref().unwrap_or_default()),
            "prunable" => wt.prunable.is_some(),
            "is_main" => wt.is_main,
            "is_current" => is_current,
        });
    }
    out
}

/// `{oid, parents, author, email, time, committer, committer_email,
/// commit_time, summary, body, file_count, additions, deletions, coauthors}`
/// (coauthors as `[{name, email}]`, from the `Co-authored-by` trailers).
pub fn commit_info(commit: &CommitDetails) -> VarDictionary {
    let parents: PackedStringArray = commit.parents.iter().map(|p| gstr(p)).collect();
    vdict! {
        "oid" => &gstr(&commit.oid),
        "parents" => &parents,
        "author" => &gstr(&commit.author_name),
        "email" => &gstr(&commit.author_email),
        "time" => commit.author_time,
        "committer" => &gstr(&commit.committer_name),
        "committer_email" => &gstr(&commit.committer_email),
        "commit_time" => commit.committer_time,
        "summary" => &gstr(commit.summary()),
        "body" => &gstr(commit.body()),
        "file_count" => to_i64(commit.files.len()),
        "additions" => i64::from(commit.additions),
        "deletions" => i64::from(commit.deletions),
        "coauthors" => &identities(&commit.coauthors()),
    }
}

/// Co-authors as `[{name, email}, ...]`.
pub fn identities(list: &[(&str, &str)]) -> Array<VarDictionary> {
    let mut out = Array::new();
    for (name, email) in list {
        out.push(&vdict! { "name" => &gstr(name), "email" => &gstr(email) });
    }
    out
}

/// A commit file row: `{path, original_path, code}`.
pub fn commit_file_row(file: &CommitFile) -> VarDictionary {
    vdict! {
        "path" => &path_str(&file.path),
        "original_path" => &file.original_path.as_deref().map_or_else(GString::new, path_str),
        "code" => change_letter(file.change),
    }
}

/// One side of a comparison: `{spec, name, kind, full_name, oid}` (`name`
/// empty and `kind` `working` for the working copy, `oid` empty on an unborn
/// branch).
pub fn compare_side(side: &ResolvedSide) -> VarDictionary {
    vdict! {
        "spec" => &gstr(&side.spec),
        "name" => &gstr(&side.name()),
        "kind" => side.kind.id(),
        "full_name" => &gstr(side.full_name.as_deref().unwrap_or_default()),
        "oid" => &gstr(side.oid.as_deref().unwrap_or_default()),
        "subject" => &gstr(side.subject.as_deref().unwrap_or_default()),
    }
}

/// The open comparison: `{state, reloading, request, left, right, mode,
/// default_mode, can_fork, merge_base, base, only_right, only_left,
/// file_count, shown_count, additions, deletions, filter, error}`. `state`
/// is `none`, `loading` (nothing loaded yet), `error` or `ready`;
/// `reloading` says a new read runs behind a shown result. `request` is
/// `{left, right, working, mode}` as asked (`mode` "" for the default).
/// The result's fields are left out until one loaded.
pub fn compare_info(state: Option<&CompareState>) -> VarDictionary {
    let Some(state) = state else {
        return vdict! { "state" => "none" };
    };
    let request = state.request();
    let (right, working) = match &request.right {
        CompareSide::Rev(spec) => (spec.as_str(), false),
        CompareSide::WorkingCopy => ("", true),
    };
    let mut info = vdict! {
        "request" => &vdict! {
            "left" => &gstr(&request.left),
            "right" => &gstr(right),
            "working" => working,
            "mode" => request.mode.map_or("", CompareMode::id),
        },
        "filter" => &gstr(state.filter()),
        "shown_count" => to_i64(state.shown_count()),
        "reloading" => state.is_loading() && state.comparison().is_some(),
    };
    match (state.error(), state.comparison()) {
        (Some(error), _) if !state.is_loading() => {
            info.set("state", "error");
            info.set("error", &error_dict(error));
        }
        (_, None) => info.set("state", "loading"),
        (_, Some(_)) => info.set("state", "ready"),
    }
    let focus = match (state.focus(), state.focus_error()) {
        (None, _) => "none",
        (Some(_), _) if state.focus_loading() => "loading",
        (Some(_), Some(_)) => "error",
        (Some(_), None) => "ready",
    };
    info.set("focus", &gstr(state.focus().unwrap_or_default()));
    info.set("focus_state", focus);
    if let Some(error) = state.focus_error() {
        info.set("focus_error", &error_dict(error));
    }
    if let Some(shown) = state.shown_comparison() {
        info.set("file_count", to_i64(shown.files.len()));
        info.set(
            "additions",
            i64::try_from(shown.additions).unwrap_or(i64::MAX),
        );
        info.set(
            "deletions",
            i64::try_from(shown.deletions).unwrap_or(i64::MAX),
        );
    }
    if let Some(cmp) = state.comparison() {
        info.set("all_file_count", to_i64(cmp.files.len()));
        info.set("commit_count", to_i64(cmp.commits.len()));
        info.set("commits_truncated", cmp.commits_truncated);
        info.set(
            "listed_right",
            to_i64(
                cmp.commits
                    .iter()
                    .filter(|c| c.only == OnlyOn::Right)
                    .count(),
            ),
        );
        info.set("left", &compare_side(&cmp.left));
        info.set("right", &compare_side(&cmp.right));
        info.set("mode", cmp.mode.id());
        info.set("default_mode", cmp.default_mode.id());
        info.set("can_fork", cmp.can_fork());
        info.set(
            "merge_base",
            &gstr(cmp.merge_base.as_deref().unwrap_or_default()),
        );
        info.set("base", &gstr(&cmp.base));
        info.set("only_right", i64::from(cmp.only_right));
        info.set("only_left", i64::from(cmp.only_left));
    }
    info
}

/// A commit only on one side, shaped like a History row (`graph_rows`)
/// without the graph: `{oid, hash, subject, author, email, coauthors, time,
/// refs, only ("left" or "right"), parents, in_head, outgoing}`.
pub fn compare_commit_row(commit: &CompareCommit, refs: &[RefLabel]) -> VarDictionary {
    let coauthors: Vec<(&str, &str)> = commit
        .coauthors
        .iter()
        .map(|(name, email)| (name.as_str(), email.as_str()))
        .collect();
    vdict! {
        "oid" => &gstr(&commit.oid),
        "hash" => &gstr(&commit.oid),
        "subject" => &gstr(&commit.subject),
        "author" => &gstr(&commit.author),
        "email" => &gstr(&commit.email),
        "coauthors" => &identities(&coauthors),
        "refs" => &labels(refs),
        "outgoing" => false,
        "time" => commit.time,
        "only" => match commit.only {
            OnlyOn::Left => "left",
            OnlyOn::Right => "right",
        },
        "parents" => i64::from(commit.parents),
        "in_head" => commit.in_head,
    }
}

/// A version of a file's history, shaped like a History row (`graph_rows`)
/// without the graph: `{oid, hash, subject, author, email, coauthors, time,
/// refs, outgoing, parents, path, original_path, code, additions, deletions,
/// exists}`. `path` is the file's name in that commit, `code` what the
/// commit did to it; the counts are -1 for a binary file; `exists` is false
/// when the commit deleted the file.
pub fn file_version_row(version: &FileVersion, refs: &[RefLabel]) -> VarDictionary {
    let coauthors: Vec<(&str, &str)> = version
        .coauthors
        .iter()
        .map(|(name, email)| (name.as_str(), email.as_str()))
        .collect();
    let (additions, deletions) = version
        .stats
        .map_or((-1, -1), |(a, r)| (i64::from(a), i64::from(r)));
    vdict! {
        "oid" => &gstr(&version.oid),
        "hash" => &gstr(&version.oid),
        "subject" => &gstr(&version.subject),
        "author" => &gstr(&version.author),
        "email" => &gstr(&version.email),
        "coauthors" => &identities(&coauthors),
        "refs" => &labels(refs),
        "outgoing" => false,
        "time" => version.time,
        "parents" => to_i64(version.parents.len()),
        "path" => &path_str(&version.path),
        "original_path" => &version.original_path.as_deref().map_or_else(GString::new, path_str),
        "code" => change_letter(version.change),
        "additions" => additions,
        "deletions" => deletions,
        "exists" => version.exists(),
    }
}

/// The open file history: `{open, path, names, start, start_name, count,
/// total, filter, loading, error, has_working, working, selected}`. `names`
/// are every name the file had (the given one first), `start` is empty for
/// HEAD, `count` is the commits shown and `total` all of them (they differ
/// under `filter`), `error` is an `error_dict` or empty, `has_working` says
/// whether the Uncommitted changes row shows, `working` is that row
/// (`{code, original_path, additions, deletions}`, as `file_version_row`,
/// with `?` for an untracked file and `U` for a conflicted one; the counts
/// are -1 until counted and for a binary file) or empty, and `selected` is
/// a commit, `working` or "".
pub fn file_history_info(
    history: Option<&FileHistoryState>,
    working: Option<WorkingVersion>,
) -> VarDictionary {
    let Some(history) = history else {
        return vdict! { "open" => false };
    };
    let request = history.request();
    let names: PackedStringArray = history.names().iter().map(|p| path_str(p)).collect();
    let selected = match history.selected() {
        Some(FileSelection::Working) => "working".to_owned(),
        Some(FileSelection::Version(oid)) => oid.clone(),
        None => String::new(),
    };
    let working_row = working.as_ref().map_or_else(VarDictionary::new, |row| {
        let (additions, deletions) = row
            .stats
            .map_or((-1, -1), |(a, d)| (i64::from(a), i64::from(d)));
        vdict! {
            "code" => row.code,
            "original_path" => &row.original_path.as_deref().map_or_else(GString::new, path_str),
            "additions" => additions,
            "deletions" => deletions,
        }
    });
    vdict! {
        "open" => true,
        "path" => &path_str(&request.path),
        "names" => &names,
        "start" => &gstr(request.start.as_deref().unwrap_or_default()),
        "start_name" => &gstr(&request.start_name),
        "count" => to_i64(history.row_count()),
        "total" => to_i64(history.total_count()),
        "filter" => &gstr(history.filter()),
        "loading" => history.is_loading(),
        "error" => &history.error().as_ref().map(error_dict).unwrap_or_default(),
        "has_working" => working.is_some(),
        "working" => &working_row,
        "selected" => &gstr(&selected),
    }
}

/// A recent comparison: `{left, right, working, mode, left_name,
/// right_name}` (the names empty unless a side is a commit).
pub fn recent_comparison(recent: &RecentComparison) -> VarDictionary {
    let (right, working) = match &recent.right {
        CompareSide::Rev(spec) => (spec.as_str(), false),
        CompareSide::WorkingCopy => ("", true),
    };
    vdict! {
        "left" => &gstr(&recent.left),
        "right" => &gstr(right),
        "working" => working,
        "mode" => recent.mode.map_or("", CompareMode::id),
        "left_name" => &gstr(&recent.left_name),
        "right_name" => &gstr(&recent.right_name),
    }
}

/// A Compare file row: `{path, original_path, code, additions, deletions,
/// untracked}`; the counts are -1 for a binary file.
pub fn compare_file_row(file: &CompareFile) -> VarDictionary {
    let (additions, deletions) = file
        .stats
        .map_or((-1, -1), |(a, r)| (i64::from(a), i64::from(r)));
    vdict! {
        "path" => &path_str(&file.path),
        "original_path" => &file.original_path.as_deref().map_or_else(GString::new, path_str),
        "code" => change_letter(file.change),
        "additions" => additions,
        "deletions" => deletions,
        "untracked" => file.untracked,
    }
}

/// A Changes view row: `{path, original_path, code, pick, conflicted,
/// resolved, as_staged, amending, in_original_commit, locked, endings_only}`.
/// `resolved` marks a file whose conflicts were resolved during the
/// operation, `locked` a checkbox that shows the index (a merge or
/// cherry-pick is being committed), `endings_only` a modified file whose
/// only changes are line endings or the final newline.
pub fn change_row(change: &FileChange, state: &RepoState) -> VarDictionary {
    let selection = state.selection();
    let mut row = vdict! {
        "path" => &path_str(&change.path),
        "original_path" => &change.original_path.as_deref().map_or_else(GString::new, path_str),
        "code" => change_code(change),
        "pick" => state.pick_state(&change.path).id(),
        "conflicted" => is_conflicted(change),
        "resolved" => state.is_resolved(&change.path),
        "as_staged" => selection.pick(&change.path) == Some(&FilePick::AsStaged),
        "amending" => state.is_amending(),
        "in_original_commit" => state.in_amended_commit(&change.path),
        "locked" => state.commit_mode().locks_picks(),
        "endings_only" => state.is_endings_only(&change.path),
    };
    if change.state == FileState::Ignored {
        row.set("ignored", true);
        row.set("ignored_dir", state.ignored_folder(&change.path));
        if let Some((source, line)) = state.ignored_by(&change.path) {
            row.set("ignored_source", &gstr(&source.name));
            row.set("ignored_line", to_i64(line.number));
            row.set("ignored_pattern", &gstr(&line.text));
        }
    }
    row
}

/// The resolver's `diff_info` (see [`diff_info`]): `kind` and `content` are
/// `conflict`, plus `conflict` = `{kind, side, ours_label, theirs_label, has_base,
/// show_base, blocks, ours_size, theirs_size, first_row, first_split_row}`
/// (the rows of the first block's header; sizes -1 when a side is missing).
pub fn conflict_info(state: &ConflictState, show_base: bool) -> VarDictionary {
    let mut info = vdict! {
        "path" => &path_str(state.path()),
        "kind" => "conflict",
        "content" => "conflict",
        "pickable" => false,
        "as_staged" => false,
        "can_expand" => false,
        "whole" => false,
    };
    let size = |s: Option<u64>| s.map_or(-1, |s| i64::try_from(s).unwrap_or(i64::MAX));
    match (state.file(), state.error()) {
        (_, Some(error)) if !state.is_loading() => {
            info.set("state", "error");
            info.set("error", &error_dict(error));
        }
        (None, _) => info.set("state", "loading"),
        (Some(file), _) => {
            info.set(
                "state",
                if state.is_loading() {
                    "loading"
                } else {
                    "ready"
                },
            );
            let layout = state.layout();
            let first = |mut rows: Box<dyn Iterator<Item = bool> + '_>| {
                rows.position(|header| header).map_or(-1, to_i64)
            };
            let header = |r: &ConflictRow| r.kind == ConflictRowKind::Header;
            let first_row = first(Box::new(layout.unified.iter().map(header)));
            let first_split_row = first(Box::new(
                layout
                    .split
                    .iter()
                    .map(|(l, _)| l.is_some_and(|r| header(&r))),
            ));
            let block = file.blocks.first();
            info.set("line_count", to_i64(layout.unified.len()));
            info.set("split_count", to_i64(layout.split.len()));
            info.set("max_line", to_i64(file.line_count()));
            set_offered(&mut info, &viewer::conflict_offered(file));
            if let Some(images) = state.images() {
                info.set("image", &images_info(images));
            }
            info.set(
                "conflict",
                &vdict! {
                    "kind" => state.kind().id(),
                    "side" => conflict_side(state.kind()),
                    "ours_label" => &gstr(block.map_or("", |b| b.ours_label.as_str())),
                    "theirs_label" => &gstr(block.map_or("", |b| b.theirs_label.as_str())),
                    "has_base" => file.has_base(),
                    "show_base" => show_base,
                    "blocks" => to_i64(file.blocks.len()),
                    "ours_size" => size(file.ours_size),
                    "theirs_size" => size(file.theirs_size),
                    "first_row" => first_row,
                    "first_split_row" => first_split_row,
                },
            );
        }
    }
    info
}

/// The side a non-text conflict is about: `ours` or `theirs` deleted a
/// modified file (`modify_delete`), or is the only one with it
/// (`added_by_one`); "" otherwise.
fn conflict_side(kind: ConflictKind) -> &'static str {
    match kind {
        ConflictKind::ModifyDelete {
            deleted_by_us: true,
        }
        | ConflictKind::AddedByOne { by_us: true } => "ours",
        ConflictKind::ModifyDelete {
            deleted_by_us: false,
        }
        | ConflictKind::AddedByOne { by_us: false } => "theirs",
        _ => "",
    }
}

/// One resolver row as a `diff_line`-style line (`index` -1, no picks):
/// context `kind` 1, ours 3 (drawn as removed), theirs 2 (as added), base 4,
/// a block header 0 with `text` "Conflict 1 of 3"; with `block` and `side`
/// (`context`, `header`, `ours`, `base`, `theirs`).
fn conflict_line(
    file: &ConflictFile,
    row: &ConflictRow,
    language: Option<Language>,
) -> VarDictionary {
    let number = row.line.map_or(0, |l| to_i64(l + 1));
    let text = row
        .line
        .and_then(|l| file.line(l))
        .map(display_text)
        .unwrap_or_default();
    let (kind, old, new): (i64, i64, i64) = match row.kind {
        ConflictRowKind::Context => (1, number, number),
        ConflictRowKind::Header => (0, 0, 0),
        ConflictRowKind::Ours => (3, number, 0),
        ConflictRowKind::Base => (4, number, 0),
        ConflictRowKind::Theirs => (2, 0, number),
    };
    let block = row.block.map_or(-1, to_i64);
    let text = if row.kind == ConflictRowKind::Header {
        format!("Conflict {} of {}", block + 1, file.blocks.len())
    } else {
        text
    };
    let syntax = if row.kind == ConflictRowKind::Header {
        PackedInt32Array::new()
    } else {
        syntax_of(language, &text)
    };
    vdict! {
        "index" => -1,
        "kind" => kind,
        "old" => old,
        "new" => new,
        "text" => &gstr(&text),
        "no_newline" => false,
        "hl" => &PackedInt32Array::new(),
        "syntax" => &syntax,
        "block" => block,
        "side" => row.kind.id(),
    }
}

/// Rows `start..start + count` of the resolver, unified (a line per row) or
/// side by side (`{left, right}`: ours left, theirs right; context, headers
/// and base lines on both). See [`conflict_line`].
pub fn conflict_rows(
    state: &ConflictState,
    split: bool,
    start: usize,
    count: usize,
) -> Array<VarDictionary> {
    let mut out = Array::new();
    let Some(file) = state.file() else {
        return out;
    };
    let language = diff_language(state.path());
    let layout = state.layout();
    if split {
        for (left, right) in layout.split.iter().skip(start).take(count) {
            let side = |row: &Option<ConflictRow>| {
                row.as_ref()
                    .map(|r| conflict_line(file, r, language))
                    .unwrap_or_default()
            };
            out.push(&vdict! { "left" => &side(left), "right" => &side(right) });
        }
    } else {
        for row in layout.unified.iter().skip(start).take(count) {
            out.push(&conflict_line(file, row, language));
        }
    }
    out
}

/// `{target, oid, up_to_date, can_ff, commit_count, commits, file_count,
/// conflicts, overlap, message}`: `commits` are `{oid, subject, author,
/// time}` (the first 50), `conflicts` `{path, kind}` with git's conflict
/// type, `overlap` the local changes the merge touches.
pub fn merge_preview(preview: &MergePreview) -> VarDictionary {
    let mut commits = Array::<VarDictionary>::new();
    for commit in &preview.commits {
        commits.push(&vdict! {
            "oid" => &gstr(&commit.oid),
            "subject" => &gstr(&commit.subject),
            "author" => &gstr(&commit.author),
            "time" => commit.time,
        });
    }
    let mut conflicts = Array::<VarDictionary>::new();
    for conflict in &preview.conflicts {
        conflicts.push(&vdict! {
            "path" => &path_str(&conflict.path),
            "kind" => &gstr(&conflict.kind),
        });
    }
    let overlap: PackedStringArray = preview.overlap.iter().map(|p| path_str(p)).collect();
    vdict! {
        "target" => &gstr(&preview.target),
        "oid" => &gstr(&preview.oid),
        "up_to_date" => preview.up_to_date,
        "can_ff" => preview.can_ff,
        "commit_count" => to_i64(preview.commit_count),
        "commits" => &commits,
        "file_count" => to_i64(preview.files.len()),
        "conflicts" => &conflicts,
        "overlap" => &overlap,
        "message" => &gstr(&preview.message),
    }
}

/// `{kind, head_name, other_name, other_oid, conflicts, resolved, step,
/// steps, message, commit_mode}`, or empty with no operation. `kind` as in
/// [`operation_id`]; `conflicts` counts the files left, `step` and `steps`
/// are 0 outside a rebase.
pub fn operation_info(state: &RepoState) -> VarDictionary {
    let Some(details) = state.operation_details() else {
        return VarDictionary::new();
    };
    let (left, resolved) = state.conflict_counts();
    let (step, steps) = details.step.unwrap_or((0, 0));
    let head = details
        .head_name
        .clone()
        .or_else(|| state.current_branch().map(str::to_owned))
        .unwrap_or_default();
    vdict! {
        "kind" => operation_id(Some(details.kind)),
        "head_name" => &gstr(&head),
        "other_name" => &gstr(details.other_name.as_deref().unwrap_or_default()),
        "other_oid" => &gstr(details.other_oid.as_deref().unwrap_or_default()),
        "conflicts" => to_i64(left),
        "resolved" => to_i64(resolved),
        "step" => i64::from(step),
        "steps" => i64::from(steps),
        "message" => &gstr(&details.message),
        "commit_mode" => state.commit_mode().id(),
    }
}

/// `{oid, subject, body, time, merge}`, or empty when nothing can be undone.
pub fn undoable_commit(state: &RepoState) -> VarDictionary {
    let Some(commit) = state.undoable_commit() else {
        return VarDictionary::new();
    };
    vdict! {
        "oid" => &gstr(&commit.oid),
        "subject" => &gstr(&commit.subject),
        "body" => &gstr(&commit.body),
        "time" => commit.time,
        "merge" => commit.is_merge(),
    }
}

fn diff_content_id(content: DiffContent) -> &'static str {
    match content {
        DiffContent::Text => "text",
        DiffContent::Binary { .. } => "binary",
        DiffContent::TooLarge { .. } => "too_large",
        DiffContent::Combined => "combined",
    }
}

/// `{state, path, kind, content, code, original_path, similarity, notes,
/// additions, deletions, line_count, split_count, max_line, can_expand,
/// whole, old_size, new_size, bytes, viewer, modes, error}`; `state` is
/// `none`, `loading`, `error` or `ready`. `viewer` (`text`, `image`, `none`)
/// and `modes` (ids in cycle order, see `diff::viewer`) come with the diff. `line_count` and `split_count` count the rows shown
/// (see [`diff_rows`]); `can_expand` says some lines of the file are hidden
/// and `whole` that the whole file is shown. Sizes and `similarity` are -1
/// when unknown.
pub fn diff_info(state: Option<&DiffState>) -> VarDictionary {
    let Some(state) = state else {
        return vdict! { "state" => "none" };
    };
    let target = state.target();
    let kind = match target.kind {
        DiffKind::Unstaged => "unstaged",
        DiffKind::Staged => "staged",
        DiffKind::Untracked => "untracked",
        DiffKind::Head => "head",
        DiffKind::Amend => "amend",
        DiffKind::AmendStaged => "staged",
        DiffKind::Commit => "commit",
        DiffKind::Working => "working",
    };
    let mut info = vdict! {
        "path" => &path_str(&target.path),
        "kind" => kind,
    };
    let size = |s: Option<u64>| s.map_or(-1, |s| i64::try_from(s).unwrap_or(i64::MAX));
    match (state.diff(), state.error()) {
        (_, Some(error)) if !state.is_loading() => {
            info.set("state", "error");
            info.set("error", &error_dict(error));
        }
        (None, _) => info.set("state", "loading"),
        (Some(diff), _) => {
            info.set(
                "state",
                if state.is_loading() {
                    "loading"
                } else {
                    "ready"
                },
            );
            let (old_size, new_size, bytes) = match diff.content {
                DiffContent::Binary { old_size, new_size } => (size(old_size), size(new_size), -1),
                DiffContent::TooLarge { bytes } => (-1, -1, size(Some(bytes))),
                DiffContent::Text | DiffContent::Combined => (-1, -1, -1),
            };
            let content = if diff.is_empty() {
                "empty"
            } else {
                diff_content_id(diff.content)
            };
            let notes: PackedStringArray = diff.header.notes().iter().map(|n| gstr(n)).collect();
            info.set("content", content);
            info.set("code", change_letter(diff.header.change()));
            info.set(
                "original_path",
                diff.header.original_path().unwrap_or_default(),
            );
            info.set("similarity", diff.header.similarity.map_or(-1, i64::from));
            info.set("notes", &notes);
            info.set("additions", i64::from(diff.additions));
            info.set("deletions", i64::from(diff.deletions));
            let layout = state.layout();
            info.set("line_count", to_i64(layout.row_count(false)));
            info.set("split_count", to_i64(layout.row_count(true)));
            info.set("max_line", i64::from(layout.max_line_number()));
            info.set("can_expand", layout.has_hidden());
            info.set("whole", state.expansion().is_whole());
            info.set("old_size", old_size);
            info.set("new_size", new_size);
            info.set("bytes", bytes);
            set_offered(&mut info, &viewer::offered(diff, &target.path));
            if diff.content == DiffContent::Text {
                set_endings(&mut info, diff.endings());
            }
            if let Some(images) = state.images() {
                info.set("image", &images_info(images));
            }
        }
    }
    info
}

/// `{format, old, new}` of an image diff (ours and theirs for a conflict),
/// each side as [`image_side_info`].
pub fn images_info(images: &ImageSides) -> VarDictionary {
    vdict! {
        "format" => images.format.id(),
        "old" => &image_side_info(&images.old),
        "new" => &image_side_info(&images.new),
    }
}

/// `{state, size, width, height, id}` of one side of an image diff. `state`
/// is `image`, `missing`, `too_large`, `too_many_pixels` or `unreadable`;
/// `size` (bytes), `width` and `height` are -1 when unknown; `id` changes
/// with the bytes (empty without them).
pub fn image_side_info(side: &SideImage) -> VarDictionary {
    let size = side
        .size()
        .map_or(-1, |s| i64::try_from(s).unwrap_or(i64::MAX));
    let (state, dimensions, id) = match side {
        SideImage::Missing => ("missing", None, ""),
        SideImage::Loaded { dimensions, id, .. } => ("image", *dimensions, id.as_str()),
        SideImage::TooLarge { .. } => ("too_large", None, ""),
        SideImage::TooManyPixels { width, height, .. } => {
            ("too_many_pixels", Some((*width, *height)), "")
        }
        SideImage::Unreadable { .. } => ("unreadable", None, ""),
    };
    let (width, height) = dimensions.map_or((-1, -1), |(w, h)| (i64::from(w), i64::from(h)));
    vdict! {
        "state" => state,
        "size" => size,
        "width" => width,
        "height" => height,
        "id" => &gstr(id),
    }
}

/// `endings` (`{from, to, lines}`: `LF`, `CRLF` or `mixed`, and the lines
/// whose ending changed; absent when none did), `final_newline` (`added`,
/// `removed` or empty) and `eol_only` (nothing else changed) of a text diff.
fn set_endings(info: &mut VarDictionary, summary: &EndingSummary) {
    if let Some((from, to)) = summary.changed {
        info.set(
            "endings",
            &vdict! {
                "from" => from.id(),
                "to" => to.id(),
                "lines" => i64::from(summary.lines),
            },
        );
    }
    info.set(
        "final_newline",
        summary.final_newline.map_or("", FinalNewline::id),
    );
    info.set("eol_only", summary.only);
}

/// A marker row (`index` -1, `kind` 5): `marker` is `no_newline` or
/// `line_endings` (with `from`, `to` and `lines`).
fn marker_line(marker: &Marker) -> VarDictionary {
    let mut line = plain_line(5, 0, 0, "", None);
    match marker {
        Marker::NoNewline { .. } => line.set("marker", "no_newline"),
        Marker::LineEndings { from, to, lines } => {
            line.set("marker", "line_endings");
            line.set("from", from.id());
            line.set("to", to.id());
            line.set("lines", i64::from(*lines));
        }
    }
    line
}

/// `viewer` and `modes` (in cycle order) of a diff or a conflict.
fn set_offered(info: &mut VarDictionary, offered: &Offered) {
    let modes: PackedStringArray = offered.modes.iter().map(|m| gstr(m.id())).collect();
    info.set("viewer", offered.viewer.id());
    info.set("modes", &modes);
}

/// The language used to color a diff of `path`.
pub fn diff_language(path: &Path) -> Option<Language> {
    language_for(path)
}

/// One diff line: `{index, kind, old, new, text, no_newline, hl, syntax}`.
/// `kind` 0 = hunk header, 1 = context, 2 = added, 3 = removed; line numbers
/// are 0 when absent; `hl` is the changed `[start, end)` character range
/// against the paired line (empty when none); `syntax` holds
/// `start, end, token kind` triples (see `highlight::TokenKind::id`).
pub fn diff_line(diff: &FileDiff, index: usize, language: Option<Language>) -> VarDictionary {
    let Some(line) = diff.line(index) else {
        return VarDictionary::new();
    };
    let text = display_text(line.text);
    let kind: i64 = match line.kind {
        LineKind::Hunk => 0,
        LineKind::Context => 1,
        LineKind::Added => 2,
        LineKind::Removed => 3,
    };
    let mut hl = PackedInt32Array::new();
    if let Some(other) = diff.partner(index).and_then(|p| diff.line(p)) {
        let other = display_text(other.text);
        let removed = line.kind == LineKind::Removed;
        let (old, new) = if removed {
            (&text, &other)
        } else {
            (&other, &text)
        };
        if let Some((old_range, new_range)) = changed_ranges(old, new) {
            let (start, end) = if removed { old_range } else { new_range };
            hl.push(i32::try_from(start).unwrap_or(i32::MAX));
            hl.push(i32::try_from(end).unwrap_or(i32::MAX));
        }
    }
    let syntax = if line.kind == LineKind::Hunk {
        PackedInt32Array::new()
    } else {
        syntax_of(language, &text)
    };
    vdict! {
        "index" => to_i64(index),
        "kind" => kind,
        "old" => i64::from(line.old_line.unwrap_or(0)),
        "new" => i64::from(line.new_line.unwrap_or(0)),
        "text" => &gstr(&text),
        "no_newline" => line.no_newline,
        "hl" => &hl,
        "syntax" => &syntax,
    }
}

/// `start, end, token kind` triples of `text`'s syntax tokens.
fn syntax_of(language: Option<Language>, text: &str) -> PackedInt32Array {
    let mut syntax = PackedInt32Array::new();
    if let Some(language) = language {
        for token in highlight(language, text) {
            syntax.push(i32::try_from(token.start).unwrap_or(i32::MAX));
            syntax.push(i32::try_from(token.end).unwrap_or(i32::MAX));
            syntax.push(token.kind.id());
        }
    }
    syntax
}

/// A line without a place in the diff (`index` -1): an unchanged line
/// outside the hunks (`kind` 1), or the end row (`kind` 0, no text).
fn plain_line(
    kind: i64,
    old: u32,
    new: u32,
    text: &str,
    language: Option<Language>,
) -> VarDictionary {
    vdict! {
        "index" => -1,
        "kind" => kind,
        "old" => i64::from(old),
        "new" => i64::from(new),
        "text" => &gstr(text),
        "no_newline" => false,
        "hl" => &PackedInt32Array::new(),
        "syntax" => &syntax_of(language, text),
    }
}

/// Rows `start..start + count` of a diff as shown, with its open gaps (see
/// `DiffLayout`). Unified: a line per row (see [`diff_line`]). Side by side:
/// `{left, right}` with a line or an empty dictionary on each side; headers
/// and unchanged lines are the same line on both. Unchanged lines outside
/// the hunks have `index` -1. Hunk headers and the end row (a header with
/// no text) carry `gap`, `expand` (their expanders: `up`, `down`, `both`,
/// `all` or empty) and `hidden`, the lines the gap hides (-1 when unknown).
pub fn diff_rows(
    state: &DiffState,
    split: bool,
    start: usize,
    count: usize,
) -> Array<VarDictionary> {
    let mut out = Array::new();
    let Some(diff) = state.diff() else {
        return out;
    };
    let language = diff_language(&state.target().path);
    let layout = state.layout();
    let with_expanders = |mut line: VarDictionary, gap: usize| {
        line.set("gap", to_i64(gap));
        line.set("expand", layout.expanders(gap).id());
        line.set("hidden", layout.hidden_lines(gap).map_or(-1, i64::from));
        line
    };
    for row in layout.rows(split, start, count) {
        let line = match row {
            LayoutRow::Diff(row) if split => {
                let (left, right) = diff.split_row(row).unwrap_or((None, None));
                let side = |line: Option<usize>| {
                    line.map(|l| diff_line(diff, l, language))
                        .unwrap_or_default()
                };
                out.push(&vdict! {
                    "left" => &side(left),
                    "right" => &side(right),
                });
                continue;
            }
            LayoutRow::Diff(index) => diff_line(diff, index, language),
            LayoutRow::Header(header) => {
                let index = diff.hunks.get(header.hunk).map_or(0, |h| h.line);
                let mut line = diff_line(diff, index, None);
                line.set("text", &gstr(&header.text(diff)));
                with_expanders(line, header.hunk)
            }
            LayoutRow::Hidden { old, new } => {
                let text = state
                    .old_file()
                    .and_then(|f| f.line(old))
                    .unwrap_or_default();
                plain_line(1, old, new, &display_text(text), language)
            }
            LayoutRow::End => with_expanders(
                plain_line(0, 0, 0, "", None),
                layout.gap_count().saturating_sub(1),
            ),
            // Side by side, a no-newline marker shows on its side only.
            LayoutRow::Marker(marker @ Marker::NoNewline { old, new }) if split => {
                let side = |shown: bool| {
                    if shown {
                        marker_line(&marker)
                    } else {
                        VarDictionary::new()
                    }
                };
                out.push(&vdict! { "left" => &side(old), "right" => &side(new) });
                continue;
            }
            LayoutRow::Marker(marker) => marker_line(&marker),
        };
        if split {
            out.push(&vdict! { "left" => &line, "right" => &line });
        } else {
            out.push(&line);
        }
    }
    out
}

/// git prints forward slashes on Windows; compare paths component-wise.
fn same_path(a: &Path, b: &Path) -> bool {
    a.components().eq(b.components())
}

pub fn labels(labels: &[RefLabel]) -> Array<VarDictionary> {
    let mut out = Array::new();
    for label in labels {
        let kind = match label.kind {
            LabelKind::Branch => "branch",
            LabelKind::RemoteBranch => "remote",
            LabelKind::Tag => "tag",
        };
        let remotes: PackedStringArray = label.remotes.iter().map(|r| gstr(r)).collect();
        out.push(&vdict! {
            "name" => &gstr(&label.name),
            "kind" => kind,
            "is_head" => label.is_head,
            "remote" => &gstr(label.remote.as_deref().unwrap_or("")),
            "remotes" => &remotes,
        });
    }
    out
}

/// `{kind, pattern, subject, level}` per suggestion; `kind` is `file`,
/// `name`, `extension`, `extension_below` or `folder`.
pub fn ignore_suggestions(list: &[Suggestion]) -> Array<VarDictionary> {
    list.iter()
        .map(|s| {
            vdict! {
                "kind" => &gstr(s.kind.id()),
                "pattern" => &gstr(&s.pattern),
                "subject" => &gstr(&s.subject),
                "level" => i64::from(s.level),
            }
        })
        .collect()
}

/// A rule from `{pattern, target: "shared"|"local", dir}` (`dir` for shared
/// rules: the `.gitignore`'s folder, "" for the root one).
pub fn ignore_rule(dict: &VarDictionary) -> Option<IgnoreRule> {
    let text = |key: &str| {
        dict.get(key)
            .and_then(|v| v.try_to::<GString>().ok())
            .map(|s| s.to_string())
            .unwrap_or_default()
    };
    let target = match text("target").as_str() {
        "shared" | "" => IgnoreTarget::Shared {
            dir: text("dir").into(),
        },
        "local" => IgnoreTarget::Local,
        "global" => IgnoreTarget::Global,
        _ => return None,
    };
    Some(IgnoreRule {
        pattern: text("pattern"),
        target,
    })
}

fn ignore_target_id(target: &IgnoreTarget) -> &'static str {
    match target {
        IgnoreTarget::Shared { .. } => "shared",
        IgnoreTarget::Local => "local",
        IgnoreTarget::Global => "global",
    }
}

/// The rules viewer's sources: `{kind: root|nested|local|global, name,
/// path, dir, exists, hidden_count, tracked_count, rule_count}`.
pub fn ignore_sources(rules: &IgnoreRules) -> Array<VarDictionary> {
    rules
        .sources
        .iter()
        .map(|s| {
            let rule_count = s
                .lines
                .iter()
                .filter(|l| {
                    matches!(
                        l.kind,
                        gitbello_core::ignore::LineKind::Rule
                            | gitbello_core::ignore::LineKind::Negation
                    )
                })
                .count();
            vdict! {
                "kind" => s.kind.id(),
                "name" => &gstr(&s.name),
                "path" => &path_str(&s.file),
                "dir" => &path_str(&s.dir),
                "exists" => s.exists,
                "hidden_count" => to_i64(s.hidden_count()),
                "tracked_count" => to_i64(s.tracked_count()),
                "rule_count" => to_i64(rule_count),
            }
        })
        .collect()
}

/// A source's lines: `{number, text, kind: rule|negation|comment|blank,
/// hidden_files, hidden_folders, tracked_count, reincluded, unused}`.
pub fn ignore_lines(lines: &[IgnoreLine]) -> Array<VarDictionary> {
    lines
        .iter()
        .map(|l| {
            vdict! {
                "number" => to_i64(l.number),
                "text" => &gstr(&l.text),
                "kind" => l.kind.id(),
                "hidden_files" => to_i64(l.hidden_files()),
                "hidden_folders" => to_i64(l.hidden_folders()),
                "tracked_count" => to_i64(l.tracked.len()),
                "reincluded" => to_i64(l.reincluded),
                "unused" => l.unused(),
            }
        })
        .collect()
}

/// Rows `start..start + count` of what a line decides: its tracked matches
/// first, then what it hides; `{path, is_dir, tracked}`.
pub fn ignore_hidden(line: &IgnoreLine, start: usize, count: usize) -> Array<VarDictionary> {
    let tracked = line.tracked.iter().map(|p| (p.as_path(), false, true));
    let hidden = line
        .hidden
        .iter()
        .map(|h| (h.path.as_path(), h.is_dir, false));
    tracked
        .chain(hidden)
        .skip(start)
        .take(count)
        .map(|(path, is_dir, tracked)| {
            vdict! {
                "path" => &path_str(path),
                "is_dir" => is_dir,
                "tracked" => tracked,
            }
        })
        .collect()
}

/// `{pattern, target, dir, exists, warning, hidden_count, hidden_sample,
/// tracked_count, tracked_sample}`; `warning` is "" or a `PatternWarning` id.
pub fn ignore_preview(preview: &IgnorePreview) -> VarDictionary {
    let paths = |list: &[std::path::PathBuf]| -> PackedStringArray {
        list.iter().map(|p| path_str(p)).collect()
    };
    vdict! {
        "pattern" => &gstr(&preview.rule.pattern),
        "target" => &gstr(ignore_target_id(&preview.rule.target)),
        "dir" => &path_str(preview.rule.target.dir()),
        "exists" => preview.exists,
        "warning" => &gstr(preview.warning.map_or("", |w| w.id())),
        "hidden_count" => to_i64(preview.hidden_count),
        "hidden_sample" => &paths(&preview.hidden_sample),
        "tracked_count" => to_i64(preview.tracked_count),
        "tracked_sample" => &paths(&preview.tracked_sample),
    }
}

/// A blame: `{open, state, oid, path, lines, blamed, commits, loading,
/// error, focus}`. `state` is `loading` (the text or more lines are to
/// come), `done`, `error`, `binary`, `too_large` or `missing` (the working
/// copy has no such file); `oid` is empty for the working copy; `lines` and
/// `blamed` count the file's lines and those git has reported so far;
/// `focus` is the focused commit's hash.
pub fn blame_info(blame: Option<&BlameState>) -> VarDictionary {
    let Some(blame) = blame else {
        return vdict! { "open" => false };
    };
    let load = blame.load();
    let state = match &load {
        BlameLoad::Loading => "loading",
        BlameLoad::Done => "done",
        BlameLoad::Failed(_) | BlameLoad::Cancelled => "error",
        BlameLoad::Binary => "binary",
        BlameLoad::TooLarge(_) => "too_large",
        BlameLoad::Missing => "missing",
    };
    let error = match &load {
        BlameLoad::Failed(error) => error_dict(error),
        _ => VarDictionary::new(),
    };
    let request = blame.request();
    let table = blame.table();
    vdict! {
        "open" => true,
        "state" => state,
        "oid" => &gstr(request.rev.as_deref().unwrap_or_default()),
        "path" => &path_str(&request.path),
        "lines" => to_i64(table.line_count()),
        "blamed" => to_i64(table.blamed_count()),
        "commits" => to_i64(table.commits().len()),
        "loading" => load == BlameLoad::Loading,
        "error" => &error,
        "focus" => &gstr(blame.focus().unwrap_or_default()),
    }
}

/// Lines `start..start + count` of a blame, shaped as the diff view's
/// unchanged lines (`index` -1, `kind` 1, the line's number as `old` and
/// `new`, `text`, `syntax`) plus who wrote them: `commit` (the hash; empty
/// until git reports the line), `first` (the line starts a run of its
/// commit), `author`, `email`, `time`, `summary`, `age` (0 for the oldest
/// commit of the file, 1 for the newest), `working` (not committed yet)
/// and `focus` (the line is the focused commit's).
pub fn blame_rows(blame: &BlameState, start: usize, count: usize) -> Array<VarDictionary> {
    let language = diff_language(&blame.request().path);
    let focus = blame.focus();
    let table = blame.table();
    let end = start.saturating_add(count).min(table.line_count());
    let mut out = Array::new();
    for line in start.min(end)..end {
        let number = u32::try_from(line + 1).unwrap_or(u32::MAX);
        let mut row = plain_line(
            1,
            number,
            number,
            &display_text(table.line_text(line)),
            language,
        );
        match table.commit_of(line) {
            Some(commit) => {
                row.set("commit", &gstr(&commit.oid));
                row.set("first", table.starts_run(line));
                row.set("author", &gstr(&commit.author));
                row.set("email", &gstr(&commit.email));
                row.set("time", commit.time);
                row.set("summary", &gstr(&commit.summary));
                row.set("age", f64::from(table.age(commit)));
                row.set("working", commit.is_working());
                row.set("focus", focus == Some(commit.oid.as_str()));
            }
            None => {
                row.set("commit", &GString::new());
                row.set("first", false);
                row.set("focus", false);
            }
        }
        out.push(&row);
    }
    out
}

/// What blame says of line `line` (0-based): `{commit, author, email, time,
/// summary, working, boundary, path, orig_line, previous, previous_path}`.
/// `path` is the file's name in the commit, `orig_line` the line's number
/// there, `previous` the commit the line came from ("" when this commit
/// added it). Empty until git reports the line.
pub fn blame_line(blame: &BlameState, line: usize) -> VarDictionary {
    let table = blame.table();
    let (Some(block), Some(commit)) = (table.block_of(line), table.commit_of(line)) else {
        return VarDictionary::new();
    };
    let (previous, previous_path) = match &block.previous {
        Some((oid, path)) => (gstr(oid), path_str(path)),
        None => (GString::new(), GString::new()),
    };
    vdict! {
        "commit" => &gstr(&commit.oid),
        "author" => &gstr(&commit.author),
        "email" => &gstr(&commit.email),
        "time" => commit.time,
        "summary" => &gstr(&commit.summary),
        "working" => commit.is_working(),
        "boundary" => commit.boundary,
        "path" => &path_str(&block.path),
        "orig_line" => table.orig_line(line).map_or(0, i64::from),
        "previous" => &previous,
        "previous_path" => &previous_path,
    }
}
