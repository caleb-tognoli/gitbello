//! Core models to Godot dictionaries and arrays. Conversion only.

use std::path::Path;

use gitbello_core::changes::{change_code, is_conflicted, FilePick, Selection};
use gitbello_core::diff::{
    changed_ranges, display_text, DiffContent, DiffKind, FileDiff, LayoutRow, LineKind,
};
use gitbello_core::git::{GitError, GitErrorKind};
use gitbello_core::highlight::{highlight, language_for, Language};
use gitbello_core::repo::{
    Change, CommitDetails, CommitFile, Conflict, FileChange, FileState, Head, Operation, Ref,
    RefKind, RepoStatus, Shelf, ShelfFile, StashEntry, Worktree,
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
/// commit_time, summary, body, file_count, additions, deletions}`.
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
    }
}

/// A commit file row: `{path, original_path, code}`.
pub fn commit_file_row(file: &CommitFile) -> VarDictionary {
    vdict! {
        "path" => &path_str(&file.path),
        "original_path" => &file.original_path.as_deref().map_or_else(GString::new, path_str),
        "code" => change_letter(file.change),
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

/// `{state, path, kind, content, code, original_path, similarity, notes,
/// additions, deletions, line_count, split_count, max_line, can_expand,
/// whole, old_size, new_size, bytes, error}`; `state` is `none`, `loading`,
/// `error` or `ready`. `line_count` and `split_count` count the rows shown
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
        out.push(&vdict! {
            "name" => &gstr(&label.name),
            "kind" => kind,
            "is_head" => label.is_head,
        });
    }
    out
}
