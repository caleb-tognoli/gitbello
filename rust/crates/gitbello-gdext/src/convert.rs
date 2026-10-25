//! Core models to Godot dictionaries and arrays. Conversion only.

use std::path::Path;

use gitbello_core::changes::{change_code, is_conflicted, FilePick, Selection};
use gitbello_core::diff::{
    changed_ranges, display_text, DiffContent, DiffKind, FileDiff, LineKind,
};
use gitbello_core::git::{GitError, GitErrorKind};
use gitbello_core::highlight::{highlight, language_for, Language};
use gitbello_core::repo::{
    Change, CommitDetails, CommitFile, Conflict, FileChange, FileState, Head, Operation, Ref,
    RefKind, RepoStatus, StashEntry, Worktree,
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
        GitErrorKind::Stale => "stale",
        GitErrorKind::LocalChanges => "local_changes",
        GitErrorKind::Diverged => "diverged",
        GitErrorKind::NoUpstream => "no_upstream",
        GitErrorKind::NoRemote => "no_remote",
        GitErrorKind::NotFullyMerged => "not_fully_merged",
        GitErrorKind::CheckedOutElsewhere => "checked_out_elsewhere",
        GitErrorKind::AlreadyExists => "already_exists",
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
            "conflicts" => badge.as_ref().map_or(0, |b| to_i64(b.conflicts)),
            "ahead" => badge.as_ref().map_or(0, |b| i64::from(b.ahead)),
            "behind" => badge.as_ref().map_or(0, |b| i64::from(b.behind)),
            "operation" => &gstr(operation_id(badge.as_ref().and_then(|b| b.operation))),
            "path" => &path_str(&wt.path),
            "name" => &gstr(&wt.path.file_name().map_or_else(|| wt.path.to_string_lossy(), |n| n.to_string_lossy())),
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
/// commit_time, summary, body, file_count}`.
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
    }
}

/// A commit file row: `{path, original_path, code}`.
pub fn commit_file_row(file: &CommitFile) -> VarDictionary {
    let code = match file.change {
        Change::Modified => "M",
        Change::Added => "A",
        Change::Deleted => "D",
        Change::Renamed => "R",
        Change::Copied => "C",
        Change::TypeChanged => "T",
        Change::Unmodified => "",
    };
    vdict! {
        "path" => &path_str(&file.path),
        "original_path" => &file.original_path.as_deref().map_or_else(GString::new, path_str),
        "code" => code,
    }
}

/// A Changes view row: `{path, original_path, code, pick, conflicted, as_staged}`.
pub fn change_row(change: &FileChange, selection: &Selection) -> VarDictionary {
    vdict! {
        "path" => &path_str(&change.path),
        "original_path" => &change.original_path.as_deref().map_or_else(GString::new, path_str),
        "code" => change_code(change),
        "pick" => selection.state(&change.path).id(),
        "conflicted" => is_conflicted(change),
        "as_staged" => selection.pick(&change.path) == Some(&FilePick::AsStaged),
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
        DiffKind::Head => "head",
        DiffKind::Commit => "commit",
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
            info.set("split_count", to_i64(diff.split_row_count()));
            info.set("max_line", i64::from(diff.max_line_number()));
            info.set("old_size", old_size);
            info.set("new_size", new_size);
            info.set("bytes", bytes);
        }
    }
    info
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
    let mut syntax = PackedInt32Array::new();
    if let (Some(language), false) = (language, line.kind == LineKind::Hunk) {
        for token in highlight(language, &text) {
            syntax.push(i32::try_from(token.start).unwrap_or(i32::MAX));
            syntax.push(i32::try_from(token.end).unwrap_or(i32::MAX));
            syntax.push(token.kind.id());
        }
    }
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

/// Diff lines `start..start + count` (see [`diff_line`]).
pub fn diff_lines(
    diff: &FileDiff,
    start: usize,
    count: usize,
    language: Option<Language>,
) -> Array<VarDictionary> {
    let end = start.saturating_add(count).min(diff.line_count());
    let mut out = Array::new();
    for index in start.min(end)..end {
        out.push(&diff_line(diff, index, language));
    }
    out
}

/// Side-by-side rows `start..start + count` as `{left, right}`, each a line
/// (see [`diff_line`]) or empty; a hunk header is the same line on both sides.
pub fn split_rows(
    diff: &FileDiff,
    start: usize,
    count: usize,
    language: Option<Language>,
) -> Array<VarDictionary> {
    let end = start.saturating_add(count).min(diff.split_row_count());
    let mut out = Array::new();
    for row in start.min(end)..end {
        let Some((left, right)) = diff.split_row(row) else {
            break;
        };
        let side = |line: Option<usize>| {
            line.map(|l| diff_line(diff, l, language))
                .unwrap_or_default()
        };
        out.push(&vdict! {
            "left" => &side(left),
            "right" => &side(right),
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
