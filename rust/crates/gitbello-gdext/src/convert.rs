//! Core models to Godot dictionaries and arrays. Conversion only.

use std::path::Path;

use gitbello_core::changes::{change_code, ChangeGroup};
use gitbello_core::diff::{display_text, DiffContent, DiffKind, FileDiff, LineKind};
use gitbello_core::git::{GitError, GitErrorKind};
use gitbello_core::repo::{
    Change, Conflict, FileChange, FileState, Head, Operation, Ref, RefKind, RepoStatus, StashEntry,
    Worktree,
};
use gitbello_core::runtime::DiffState;
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
        _ => "other",
    }
}

/// `{kind, title, message, command, stderr, exit_code}`; `message` is the
/// first meaningful stderr line, `title` the human-readable kind.
pub fn error_dict(error: &GitError) -> VarDictionary {
    let message = error
        .stderr
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map(|l| {
            l.trim_start_matches("fatal: ")
                .trim_start_matches("error: ")
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

/// Worktree rows. `badge` gives the live badge of a worktree path (the
/// current one from its own status, linked ones from their badge refresh).
pub fn worktrees(
    list: &[Worktree],
    current: Option<&Path>,
    badge: impl Fn(&Worktree, bool) -> Option<Badge>,
) -> Array<VarDictionary> {
    let mut out = Array::new();
    for wt in list {
        let is_current = current.is_some_and(|c| same_path(c, &wt.path));
        let badge = badge(wt, is_current);
        out.push(&vdict! {
            "badge" => &gstr(&badge.as_ref().map(Badge::summary).unwrap_or_default()),
            "changed" => badge.as_ref().map_or(-1, |b| to_i64(b.changed)),
            "path" => &path_str(&wt.path),
            "name" => &gstr(&wt.path.file_name().map_or_else(|| wt.path.to_string_lossy(), |n| n.to_string_lossy())),
            "branch" => &gstr(wt.branch_name().unwrap_or_default()),
            "head" => &gstr(wt.head.as_deref().unwrap_or_default()),
            "detached" => wt.detached,
            "bare" => wt.bare,
            "locked" => wt.locked.is_some(),
            "prunable" => wt.prunable.is_some(),
            "is_main" => wt.is_main,
            "is_current" => is_current,
        });
    }
    out
}

/// A changes-panel row: `{path, original_path, code, group}`.
pub fn change_row(change: &FileChange, group: ChangeGroup) -> VarDictionary {
    vdict! {
        "path" => &path_str(&change.path),
        "original_path" => &change.original_path.as_deref().map_or_else(GString::new, path_str),
        "code" => change_code(change, group),
        "group" => group.id(),
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

/// `{state, path, kind, content, notes, additions, deletions, line_count,
/// max_line, old_size, new_size, bytes, error}`; `state` is `none`,
/// `loading`, `error` or `ready`. Sizes are -1 when unknown.
pub fn diff_info(state: Option<&DiffState>) -> VarDictionary {
    let Some(state) = state else {
        return vdict! { "state" => "none" };
    };
    let target = state.target();
    let kind = match target.kind {
        DiffKind::Unstaged => "unstaged",
        DiffKind::Staged => "staged",
        DiffKind::Untracked => "untracked",
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
            info.set("notes", &notes);
            info.set("additions", i64::from(diff.additions));
            info.set("deletions", i64::from(diff.deletions));
            info.set("line_count", to_i64(diff.line_count()));
            info.set("max_line", i64::from(diff.max_line_number()));
            info.set("old_size", old_size);
            info.set("new_size", new_size);
            info.set("bytes", bytes);
        }
    }
    info
}

/// Diff lines as `{kind, old, new, text, no_newline}`; kind 0 = hunk header,
/// 1 = context, 2 = added, 3 = removed; line numbers are 0 when absent.
pub fn diff_lines(diff: &FileDiff, start: usize, count: usize) -> Array<VarDictionary> {
    let mut out = Array::new();
    for line in diff.lines(start, count) {
        let kind: i64 = match line.kind {
            LineKind::Hunk => 0,
            LineKind::Context => 1,
            LineKind::Added => 2,
            LineKind::Removed => 3,
        };
        out.push(&vdict! {
            "kind" => kind,
            "old" => i64::from(line.old_line.unwrap_or(0)),
            "new" => i64::from(line.new_line.unwrap_or(0)),
            "text" => &gstr(&display_text(line.text)),
            "no_newline" => line.no_newline,
        });
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
        out.push(&vdict! {
            "name" => &gstr(&label.name),
            "kind" => kind,
            "is_head" => label.is_head,
        });
    }
    out
}
