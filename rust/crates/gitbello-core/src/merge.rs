//! Merge workflows (PLAN §4, M7): the merge preview, the operation in
//! progress, conflicted files with their conflict blocks, and the commit
//! the undo strip offers. Plain data and pure parsers; the backend runs git
//! and the runtime decides when.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use crate::repo::{git_path, text, Conflict, Operation, ParseError};

/// How a merge integrates the other branch (the dialog's split button).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MergeMode {
    /// `--ff`: fast-forwards when it can, else a merge commit.
    #[default]
    Default,
    /// `--no-ff`: always a merge commit.
    NoFastForward,
    /// `--squash`: the combined changes staged, no merge commit.
    Squash,
    /// `--ff-only`: refuses unless it can fast-forward.
    FastForwardOnly,
}

impl MergeMode {
    pub fn from_id(id: &str) -> Option<Self> {
        Some(match id {
            "default" => Self::Default,
            "no_ff" => Self::NoFastForward,
            "squash" => Self::Squash,
            "ff_only" => Self::FastForwardOnly,
            _ => return None,
        })
    }

    pub fn id(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::NoFastForward => "no_ff",
            Self::Squash => "squash",
            Self::FastForwardOnly => "ff_only",
        }
    }

    /// The `git merge` flag.
    pub fn flag(self) -> &'static str {
        match self {
            Self::Default => "--ff",
            Self::NoFastForward => "--no-ff",
            Self::Squash => "--squash",
            Self::FastForwardOnly => "--ff-only",
        }
    }

    /// Whether git takes a message for it (not when it only moves the branch
    /// or stages the result).
    pub fn takes_message(self) -> bool {
        matches!(self, Self::Default | Self::NoFastForward)
    }
}

/// A commit the merge would bring in.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PreviewCommit {
    pub oid: String,
    pub subject: String,
    pub author: String,
    /// Author time, seconds since the epoch.
    pub time: i64,
}

/// A file the merge would leave conflicted, with git's conflict type
/// (`contents`, `modify/delete`, `add/add`, `binary`, `rename/delete`, ...).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreviewConflict {
    pub path: PathBuf,
    pub kind: String,
}

/// What merging `target` into HEAD would do, worked out without touching
/// the working tree (`git merge-tree --write-tree`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MergePreview {
    /// The ref or commit as asked for (`feature/x`, `origin/x`, an oid).
    pub target: String,
    /// The commit it names.
    pub oid: String,
    /// Nothing to merge: `target` is already in HEAD.
    pub up_to_date: bool,
    /// HEAD is an ancestor of `target`.
    pub can_ff: bool,
    /// Commits of `target` not in HEAD, and the first of them.
    pub commit_count: usize,
    pub commits: Vec<PreviewCommit>,
    /// Files the merge changes in HEAD.
    pub files: Vec<PathBuf>,
    pub conflicts: Vec<PreviewConflict>,
    /// Local changes to files the merge changes (filled by the runtime).
    pub overlap: Vec<PathBuf>,
    /// git's default merge message.
    pub message: String,
}

/// Commits listed in a preview.
pub const PREVIEW_COMMITS: usize = 50;

/// `git log` format of [`parse_preview_commits`].
pub const PREVIEW_LOG_FORMAT: &str = "--format=%H%x00%s%x00%an%x00%at%x00";

/// Commits from `git log -z` with [`PREVIEW_LOG_FORMAT`].
pub fn parse_preview_commits(output: &[u8]) -> Vec<PreviewCommit> {
    let fields: Vec<&[u8]> = output.split(|&b| b == 0).collect();
    fields
        .chunks(4)
        .filter(|c| c.len() == 4)
        .filter_map(|c| {
            let oid = text(c[0]).trim().to_owned();
            (!oid.is_empty()).then(|| PreviewCommit {
                oid,
                subject: text(c[1]),
                author: text(c[2]),
                time: text(c[3]).trim().parse().unwrap_or(0),
            })
        })
        .collect()
}

/// The result of `git merge-tree --write-tree -z --name-only --messages`:
/// the tree, the conflicted paths and each conflict's type.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MergeTree {
    pub tree: String,
    pub conflicts: Vec<PreviewConflict>,
}

pub fn parse_merge_tree(output: &[u8]) -> Result<MergeTree, ParseError> {
    let mut fields = output.split(|&b| b == 0);
    let tree = text(fields.next().unwrap_or_default()).trim().to_owned();
    if tree.is_empty() {
        return Err(ParseError::new("merge-tree", "no tree id"));
    }
    let mut paths: Vec<PathBuf> = Vec::new();
    for field in fields.by_ref() {
        if field.is_empty() {
            break;
        }
        let path = git_path(field);
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    // Informational messages: `<count> NUL <path>... NUL <type> NUL <message> NUL`.
    let rest: Vec<&[u8]> = fields.collect();
    let mut kinds: Vec<(PathBuf, String)> = Vec::new();
    let mut i = 0;
    while i < rest.len() {
        let Ok(count) = text(rest[i]).trim().parse::<usize>() else {
            break;
        };
        let msg_paths = rest.get(i + 1..i + 1 + count).unwrap_or_default();
        let kind = rest.get(i + 1 + count).map(|k| text(k)).unwrap_or_default();
        if let Some(kind) = kind
            .strip_prefix("CONFLICT (")
            .and_then(|k| k.strip_suffix(')'))
        {
            for path in msg_paths {
                kinds.push((git_path(path), kind.to_owned()));
            }
        }
        i += count + 3;
    }
    let conflicts = paths
        .into_iter()
        .map(|path| {
            let kind = kinds
                .iter()
                .find(|(p, _)| *p == path)
                .map_or_else(|| "contents".to_owned(), |(_, k)| k.clone());
            PreviewConflict { path, kind }
        })
        .collect();
    Ok(MergeTree { tree, conflicts })
}

/// git's default merge message for merging `target` (a full ref name, or a
/// commit id) into `branch`; `into` is left out for `main` and `master`.
pub fn default_merge_message(target: &str, branch: Option<&str>) -> String {
    let what = if let Some(name) = target.strip_prefix("refs/heads/") {
        format!("branch '{name}'")
    } else if let Some(name) = target.strip_prefix("refs/remotes/") {
        format!("remote-tracking branch '{name}'")
    } else if let Some(name) = target.strip_prefix("refs/tags/") {
        format!("tag '{name}'")
    } else {
        format!("commit '{target}'")
    };
    match branch {
        Some(branch) if branch != "main" && branch != "master" => {
            format!("Merge {what} into {branch}")
        }
        _ => format!("Merge {what}"),
    }
}

/// The other side of a merge, as its message names it (`feature/x` from
/// "Merge branch 'feature/x'"), else `None`.
pub fn merged_name(message: &str) -> Option<String> {
    let first = message.lines().next()?.trim();
    let rest = first.strip_prefix("Merge ")?;
    let start = rest.find('\'')?;
    let end = rest[start + 1..].find('\'')?;
    Some(rest[start + 1..start + 1 + end].to_owned())
}

/// A message file without git's comment lines (`# Conflicts:` and so on),
/// with trailing blank lines dropped.
pub fn strip_comments(message: &str) -> String {
    let kept: Vec<&str> = message
        .lines()
        .filter(|line| !line.starts_with('#'))
        .collect();
    let mut text = kept.join("\n");
    let trimmed = text.trim_end().len();
    text.truncate(trimmed);
    text
}

/// The operation in progress with what the banner says about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OperationDetails {
    pub kind: Operation,
    /// The branch being merged into or rebased (short name), if known.
    pub head_name: Option<String>,
    /// The other side: the merged branch, the picked commit's subject, or
    /// what a rebase replays onto.
    pub other_name: Option<String>,
    pub other_oid: Option<String>,
    /// The message git prepared (`MERGE_MSG` without comments), for the
    /// commit box.
    pub message: String,
    /// Rebase progress: the commit being replayed, of how many.
    pub step: Option<(u32, u32)>,
}

/// Reads [`OperationDetails`] for `kind` from the marker files in `git_dir`.
/// `subject` names a commit (for cherry-picks).
pub fn read_operation_details(
    git_dir: &Path,
    kind: Operation,
    subject: impl Fn(&str) -> Option<String>,
) -> OperationDetails {
    let read = |name: &str| std::fs::read(git_dir.join(name)).ok().map(|b| text(&b));
    let line = |name: &str| {
        read(name)
            .map(|t| t.trim().to_owned())
            .filter(|t| !t.is_empty())
    };
    let short = |name: String| {
        name.strip_prefix("refs/heads/")
            .map(str::to_owned)
            .unwrap_or(name)
    };
    let message = read("MERGE_MSG")
        .map(|m| strip_comments(&m))
        .unwrap_or_default();
    let mut details = OperationDetails {
        kind,
        head_name: None,
        other_name: None,
        other_oid: None,
        message,
        step: None,
    };
    match kind {
        Operation::Merge => {
            details.other_oid =
                line("MERGE_HEAD").and_then(|t| t.lines().next().map(str::to_owned));
            details.other_name = merged_name(&details.message);
        }
        Operation::CherryPick | Operation::Revert => {
            let head = if kind == Operation::CherryPick {
                "CHERRY_PICK_HEAD"
            } else {
                "REVERT_HEAD"
            };
            details.other_oid = line(head);
            details.other_name = details.other_oid.as_deref().and_then(subject);
        }
        Operation::Rebase { .. } => {
            let dir = if git_dir.join("rebase-merge").is_dir() {
                "rebase-merge"
            } else {
                "rebase-apply"
            };
            details.head_name = line(&format!("{dir}/head-name")).map(short);
            details.other_oid = line(&format!("{dir}/onto"));
            let number = |name: &str| line(&format!("{dir}/{name}")).and_then(|t| t.parse().ok());
            let (step, steps) = if dir == "rebase-merge" {
                (number("msgnum"), number("end"))
            } else {
                (number("next"), number("last"))
            };
            details.step = step.zip(steps);
        }
        Operation::ApplyMailbox | Operation::Bisect => {}
    }
    details
}

/// What kind of conflict a file has, which decides what the resolver
/// offers: blocks for text, a side to pick for the rest.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictKind {
    /// Both sides changed the text.
    Content,
    /// Both sides added the file.
    AddAdd,
    /// One side deleted the file, the other modified it.
    ModifyDelete { deleted_by_us: bool },
    /// Only one side has the file (a rename on the other side, usually).
    AddedByOne { by_us: bool },
    /// Both sides deleted (or renamed away) the file.
    BothDeleted,
    /// A conflicted file with binary content.
    Binary,
}

impl ConflictKind {
    pub fn from_status(conflict: Conflict) -> Self {
        match conflict {
            Conflict::BothModified => Self::Content,
            Conflict::BothAdded => Self::AddAdd,
            Conflict::DeletedByUs => Self::ModifyDelete {
                deleted_by_us: true,
            },
            Conflict::DeletedByThem => Self::ModifyDelete {
                deleted_by_us: false,
            },
            Conflict::AddedByUs => Self::AddedByOne { by_us: true },
            Conflict::AddedByThem => Self::AddedByOne { by_us: false },
            Conflict::BothDeleted => Self::BothDeleted,
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Self::Content => "content",
            Self::AddAdd => "add_add",
            Self::ModifyDelete { .. } => "modify_delete",
            Self::AddedByOne { .. } => "added_by_one",
            Self::BothDeleted => "both_deleted",
            Self::Binary => "binary",
        }
    }

    /// Whether the file can hold conflict markers.
    pub fn is_text(self) -> bool {
        matches!(self, Self::Content | Self::AddAdd)
    }
}

/// One conflict in a file, by line index (0-based) of its markers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictBlock {
    /// `<<<<<<<` line.
    pub start: usize,
    /// `|||||||` line, when the base is in the markers (diff3, zdiff3).
    pub base: Option<usize>,
    /// `=======` line.
    pub separator: usize,
    /// `>>>>>>>` line.
    pub end: usize,
    pub ours_label: String,
    pub theirs_label: String,
}

impl ConflictBlock {
    pub fn ours(&self) -> std::ops::Range<usize> {
        self.start + 1..self.base.unwrap_or(self.separator)
    }

    pub fn base_lines(&self) -> Option<std::ops::Range<usize>> {
        self.base.map(|b| b + 1..self.separator)
    }

    pub fn theirs(&self) -> std::ops::Range<usize> {
        self.separator + 1..self.end
    }
}

/// How to resolve a conflict block.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockChoice {
    Ours,
    Theirs,
    OursThenTheirs,
    TheirsThenOurs,
}

impl BlockChoice {
    pub fn from_id(id: &str) -> Option<Self> {
        Some(match id {
            "ours" => Self::Ours,
            "theirs" => Self::Theirs,
            "ours_theirs" => Self::OursThenTheirs,
            "theirs_ours" => Self::TheirsThenOurs,
            _ => return None,
        })
    }
}

/// How to resolve a whole file (non-text conflicts, or every block at once).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileChoice {
    Ours,
    Theirs,
    /// Keep the file (the side that has it).
    Keep,
    Delete,
}

impl FileChoice {
    pub fn from_id(id: &str) -> Option<Self> {
        Some(match id {
            "ours" => Self::Ours,
            "theirs" => Self::Theirs,
            "keep" => Self::Keep,
            "delete" => Self::Delete,
            _ => return None,
        })
    }
}

/// Lines of `bytes`, each with its line ending.
pub fn split_lines(bytes: &[u8]) -> Vec<&[u8]> {
    let mut lines = Vec::new();
    let mut start = 0;
    for (i, &b) in bytes.iter().enumerate() {
        if b == b'\n' {
            lines.push(&bytes[start..=i]);
            start = i + 1;
        }
    }
    if start < bytes.len() {
        lines.push(&bytes[start..]);
    }
    lines
}

/// Marker length git uses unless `conflict-marker-size` says otherwise.
const MARKER: usize = 7;

/// `Some(label)` when `line` is a marker of `c` repeated (at least 7 times),
/// followed by the end of the line or a space and a label.
fn marker(line: &[u8], c: u8) -> Option<String> {
    let line = line.strip_suffix(b"\n").unwrap_or(line);
    let line = line.strip_suffix(b"\r").unwrap_or(line);
    let n = line.iter().take_while(|&&b| b == c).count();
    if n < MARKER {
        return None;
    }
    match line.get(n) {
        None => Some(String::new()),
        Some(b' ') => Some(text(&line[n + 1..])),
        Some(_) => None,
    }
}

/// The conflict blocks in a file's lines. Incomplete blocks are ignored.
pub fn parse_blocks(lines: &[&[u8]]) -> Vec<ConflictBlock> {
    let mut blocks = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let Some(ours_label) = marker(lines[i], b'<') else {
            i += 1;
            continue;
        };
        let start = i;
        let (mut base, mut separator) = (None, None);
        let mut j = i + 1;
        let mut end = None;
        while j < lines.len() {
            if separator.is_none() && base.is_none() && marker(lines[j], b'|').is_some() {
                base = Some(j);
            } else if separator.is_none() && marker(lines[j], b'=').is_some() {
                separator = Some(j);
            } else if separator.is_some() {
                if let Some(label) = marker(lines[j], b'>') {
                    end = Some((j, label));
                    break;
                }
            } else if marker(lines[j], b'<').is_some() {
                break; // a new block before this one ended
            }
            j += 1;
        }
        match (separator, end) {
            (Some(separator), Some((end, theirs_label))) => {
                blocks.push(ConflictBlock {
                    start,
                    base,
                    separator,
                    end,
                    ours_label,
                    theirs_label,
                });
                i = end + 1;
            }
            _ => i = j.max(i + 1),
        }
    }
    blocks
}

/// `bytes` with conflict block `block` replaced by the lines `choice` takes.
/// `None` when there is no such block.
pub fn resolve_block(bytes: &[u8], block: usize, choice: BlockChoice) -> Option<Vec<u8>> {
    let lines = split_lines(bytes);
    let found = parse_blocks(&lines).into_iter().nth(block)?;
    let take = |range: std::ops::Range<usize>, out: &mut Vec<u8>| {
        for line in &lines[range] {
            out.extend_from_slice(line);
        }
    };
    let mut out = Vec::with_capacity(bytes.len());
    take(0..found.start, &mut out);
    match choice {
        BlockChoice::Ours => take(found.ours(), &mut out),
        BlockChoice::Theirs => take(found.theirs(), &mut out),
        BlockChoice::OursThenTheirs => {
            take(found.ours(), &mut out);
            take(found.theirs(), &mut out);
        }
        BlockChoice::TheirsThenOurs => {
            take(found.theirs(), &mut out);
            take(found.ours(), &mut out);
        }
    }
    // The `>>>>>>>` line's ending stays when the file went on past it.
    take(found.end + 1..lines.len(), &mut out);
    Some(out)
}

/// A conflicted file as the resolver shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictFile {
    pub path: PathBuf,
    pub kind: ConflictKind,
    /// The working-tree bytes (empty when the file is missing or binary).
    pub content: Vec<u8>,
    /// Byte ranges of the lines of `content` (ending included).
    lines: Vec<(usize, usize)>,
    pub blocks: Vec<ConflictBlock>,
    /// Sizes of our and their versions (stages 2 and 3), when they exist.
    pub ours_size: Option<u64>,
    pub theirs_size: Option<u64>,
}

impl ConflictFile {
    /// Builds the model of `path`'s working-tree `content`. Text with a NUL
    /// byte counts as binary.
    pub fn new(path: PathBuf, kind: ConflictKind, content: Option<Vec<u8>>) -> Self {
        let content = content.unwrap_or_default();
        let binary = kind.is_text() && crate::diff::looks_binary(&content);
        let kind = if binary { ConflictKind::Binary } else { kind };
        let (lines, blocks) = if kind.is_text() {
            let lines = split_lines(&content);
            let blocks = parse_blocks(&lines);
            let mut ranges = Vec::with_capacity(lines.len());
            let mut at = 0;
            for line in &lines {
                ranges.push((at, at + line.len()));
                at += line.len();
            }
            (ranges, blocks)
        } else {
            (Vec::new(), Vec::new())
        };
        Self {
            path,
            kind,
            content: if kind.is_text() { content } else { Vec::new() },
            lines,
            blocks,
            ours_size: None,
            theirs_size: None,
        }
    }

    pub fn line_count(&self) -> usize {
        self.lines.len()
    }

    /// Line `index` without its ending.
    pub fn line(&self, index: usize) -> Option<&[u8]> {
        let (start, end) = *self.lines.get(index)?;
        let line = &self.content[start..end];
        let line = line.strip_suffix(b"\n").unwrap_or(line);
        Some(line.strip_suffix(b"\r").unwrap_or(line))
    }

    /// Whether every block has the base between its markers.
    pub fn has_base(&self) -> bool {
        !self.blocks.is_empty() && self.blocks.iter().all(|b| b.base.is_some())
    }

    /// The blocks are gone: the file can be staged as resolved.
    pub fn is_resolved_text(&self) -> bool {
        self.kind.is_text() && self.blocks.is_empty()
    }
}

/// What a row of the resolver shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictRowKind {
    /// A line outside the blocks.
    Context,
    /// The header of block `block` (its actions).
    Header,
    Ours,
    Base,
    Theirs,
}

impl ConflictRowKind {
    pub fn id(self) -> &'static str {
        match self {
            Self::Context => "context",
            Self::Header => "header",
            Self::Ours => "ours",
            Self::Base => "base",
            Self::Theirs => "theirs",
        }
    }
}

/// One line of the resolver: a file line (`line`), or a block header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConflictRow {
    pub kind: ConflictRowKind,
    pub line: Option<usize>,
    pub block: Option<usize>,
}

/// The rows of a conflicted file, unified and side by side. Markers are
/// left out; with `show_base` the base lines are shown too.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ConflictLayout {
    pub unified: Vec<ConflictRow>,
    /// `(left, right)`; a header or base row is the same row on both sides.
    pub split: Vec<(Option<ConflictRow>, Option<ConflictRow>)>,
}

impl ConflictLayout {
    pub fn build(file: &ConflictFile, show_base: bool) -> Self {
        let mut layout = Self::default();
        let mut at = 0;
        let row =
            |kind, line: Option<usize>, block: Option<usize>| ConflictRow { kind, line, block };
        let context = |layout: &mut Self, range: std::ops::Range<usize>| {
            for line in range {
                let r = row(ConflictRowKind::Context, Some(line), None);
                layout.unified.push(r);
                layout.split.push((Some(r), Some(r)));
            }
        };
        for (b, block) in file.blocks.iter().enumerate() {
            context(&mut layout, at..block.start);
            let header = row(ConflictRowKind::Header, None, Some(b));
            layout.unified.push(header);
            layout.split.push((Some(header), Some(header)));
            let side = |kind, range: std::ops::Range<usize>| -> Vec<ConflictRow> {
                range.map(|l| row(kind, Some(l), Some(b))).collect()
            };
            let ours = side(ConflictRowKind::Ours, block.ours());
            let theirs = side(ConflictRowKind::Theirs, block.theirs());
            let base = match (show_base, block.base_lines()) {
                (true, Some(range)) => side(ConflictRowKind::Base, range),
                _ => Vec::new(),
            };
            layout.unified.extend(&ours);
            layout.unified.extend(&base);
            layout.unified.extend(&theirs);
            for r in &base {
                layout.split.push((Some(*r), Some(*r)));
            }
            for i in 0..ours.len().max(theirs.len()) {
                layout
                    .split
                    .push((ours.get(i).copied(), theirs.get(i).copied()));
            }
            at = block.end + 1;
        }
        context(&mut layout, at..file.line_count());
        layout
    }
}

/// The commit the undo strip offers: HEAD, while it is on no remote branch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UndoableCommit {
    pub oid: String,
    pub subject: String,
    pub body: String,
    /// Committer time, seconds since the epoch.
    pub time: i64,
    pub parents: Vec<String>,
}

impl UndoableCommit {
    pub fn is_merge(&self) -> bool {
        self.parents.len() > 1
    }
}

/// `git log -1` format of [`parse_undoable`].
pub const UNDOABLE_LOG_FORMAT: &str = "--format=%H%x00%P%x00%ct%x00%B";

pub fn parse_undoable(output: &[u8]) -> Option<UndoableCommit> {
    let mut fields = output.splitn(4, |&b| b == 0);
    let oid = text(fields.next()?).trim().to_owned();
    if oid.is_empty() {
        return None;
    }
    let parents = text(fields.next()?)
        .split_whitespace()
        .map(str::to_owned)
        .collect();
    let time = text(fields.next()?).trim().parse().unwrap_or(0);
    let (subject, body) = crate::changes::split_message(&text(fields.next().unwrap_or_default()));
    Some(UndoableCommit {
        oid,
        subject,
        body,
        time,
        parents,
    })
}

/// What the history and the undo strip need to know about HEAD.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HeadInfo {
    pub undoable: Option<UndoableCommit>,
    /// Commits of branches, remote branches and tags that HEAD lacks (what
    /// "Merge into current" can be offered on).
    pub not_in_head: HashSet<String>,
}

/// A write to a conflicted file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConflictOp {
    /// Replaces the file's `expected` bytes with `content` (refused when the
    /// file changed), then stages it when `stage`.
    Write {
        path: PathBuf,
        expected: Vec<u8>,
        content: Vec<u8>,
        stage: bool,
    },
    /// Undoes a [`ConflictOp::Write`]: puts `content` back where the file
    /// still holds `expected`; with `reopen` (the file was staged as
    /// resolved) the conflict comes back first.
    Restore {
        path: PathBuf,
        expected: Vec<u8>,
        content: Vec<u8>,
        reopen: bool,
    },
    /// Takes our or their version of the whole file and stages it.
    TakeSide { path: PathBuf, ours: bool },
    /// Deletes the file (and its index entries).
    Remove { path: PathBuf },
    /// Stages files whose conflicts are gone.
    Stage { paths: Vec<PathBuf> },
    /// Recreates the conflict (`checkout -m`), or with `base` recreates it
    /// with the base in the markers (`checkout --conflict=zdiff3`).
    Reopen { path: PathBuf, base: bool },
}

/// How undoing a commit treats its changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UndoMode {
    /// Back to the first parent; the commit's changes become local changes.
    KeepChanges,
    /// Back to the first parent without the merged changes (merge commits).
    RemoveMerge,
}

impl UndoMode {
    pub fn from_id(id: &str) -> Option<Self> {
        Some(match id {
            "keep_changes" => Self::KeepChanges,
            "remove_merge" => Self::RemoveMerge,
            _ => return None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_merge_tree_with_conflicts() {
        let out = b"cbfb\0f.txt\0g.txt\0\0\
1\0f.txt\0Auto-merging\0Auto-merging f.txt\n\0\
1\0f.txt\0CONFLICT (contents)\0CONFLICT (content): Merge conflict in f.txt\n\0\
1\0g.txt\0CONFLICT (modify/delete)\0CONFLICT (modify/delete): g.txt deleted\n\0";
        let tree = parse_merge_tree(out).unwrap();
        assert_eq!(tree.tree, "cbfb");
        assert_eq!(
            tree.conflicts,
            [
                PreviewConflict {
                    path: "f.txt".into(),
                    kind: "contents".into()
                },
                PreviewConflict {
                    path: "g.txt".into(),
                    kind: "modify/delete".into()
                }
            ]
        );
    }

    #[test]
    fn parses_clean_merge_tree() {
        let tree = parse_merge_tree(b"abc\0\0").unwrap();
        assert_eq!(tree.tree, "abc");
        assert!(tree.conflicts.is_empty());
        assert!(parse_merge_tree(b"").is_err());
    }

    #[test]
    fn default_messages_follow_git() {
        let m = |t: &str, b: Option<&str>| default_merge_message(t, b);
        assert_eq!(m("refs/heads/feat", Some("main")), "Merge branch 'feat'");
        assert_eq!(
            m("refs/heads/feat", Some("dev")),
            "Merge branch 'feat' into dev"
        );
        assert_eq!(
            m("refs/remotes/origin/x", Some("master")),
            "Merge remote-tracking branch 'origin/x'"
        );
        assert_eq!(m("refs/tags/v1", None), "Merge tag 'v1'");
        assert_eq!(m("abc123", Some("main")), "Merge commit 'abc123'");
        assert_eq!(
            merged_name("Merge branch 'feat/x' into dev\n\n# Conflicts").as_deref(),
            Some("feat/x")
        );
        assert_eq!(merged_name("Something else"), None);
    }

    #[test]
    fn strips_comment_lines() {
        assert_eq!(
            strip_comments("Merge branch 'feat'\n\n# Conflicts:\n#\tf.txt\n"),
            "Merge branch 'feat'"
        );
    }

    const CONFLICT: &[u8] =
        b"a\n<<<<<<< HEAD\nB1\n||||||| base\nb\n=======\nB2\nB3\n>>>>>>> feat\nc\n";

    #[test]
    fn parses_blocks_with_base() {
        let lines = split_lines(CONFLICT);
        let blocks = parse_blocks(&lines);
        assert_eq!(blocks.len(), 1);
        let b = &blocks[0];
        assert_eq!((b.start, b.base, b.separator, b.end), (1, Some(3), 5, 8));
        assert_eq!(
            (b.ours(), b.base_lines(), b.theirs()),
            (2..3, Some(4..5), 6..8)
        );
        assert_eq!(
            (b.ours_label.as_str(), b.theirs_label.as_str()),
            ("HEAD", "feat")
        );
    }

    #[test]
    fn ignores_lookalikes_and_unfinished_blocks() {
        let text = b"<<<<<<<< x\n=======x\n<<<<<<< a\nours\n=======\n";
        assert!(parse_blocks(&split_lines(text)).is_empty());
        let crlf = b"<<<<<<< a\r\nx\r\n=======\r\ny\r\n>>>>>>> b\r\n";
        assert_eq!(parse_blocks(&split_lines(crlf)).len(), 1);
    }

    #[test]
    fn resolves_each_choice() {
        let r = |c| String::from_utf8(resolve_block(CONFLICT, 0, c).unwrap()).unwrap();
        assert_eq!(r(BlockChoice::Ours), "a\nB1\nc\n");
        assert_eq!(r(BlockChoice::Theirs), "a\nB2\nB3\nc\n");
        assert_eq!(r(BlockChoice::OursThenTheirs), "a\nB1\nB2\nB3\nc\n");
        assert_eq!(r(BlockChoice::TheirsThenOurs), "a\nB2\nB3\nB1\nc\n");
        assert!(resolve_block(CONFLICT, 1, BlockChoice::Ours).is_none());
    }

    #[test]
    fn resolving_keeps_crlf_and_missing_final_newline() {
        let text = b"<<<<<<< a\r\nx\r\n=======\r\ny\r\n>>>>>>> b";
        let out = resolve_block(text, 0, BlockChoice::Theirs).unwrap();
        assert_eq!(out, b"y\r\n");
    }

    #[test]
    fn layout_has_headers_and_aligned_sides() {
        let file = ConflictFile::new("f".into(), ConflictKind::Content, Some(CONFLICT.to_vec()));
        assert!(file.has_base());
        let layout = ConflictLayout::build(&file, false);
        let kinds: Vec<&str> = layout.unified.iter().map(|r| r.kind.id()).collect();
        assert_eq!(
            kinds,
            ["context", "header", "ours", "theirs", "theirs", "context"]
        );
        // context, header, 2 aligned rows (ours has one line), context
        assert_eq!(layout.split.len(), 5);
        assert_eq!(layout.split[2].0.map(|r| r.line), Some(Some(2)));
        assert_eq!(layout.split[3].0, None);
        let with_base = ConflictLayout::build(&file, true);
        assert_eq!(with_base.unified.len(), 7);
        assert_eq!(file.line(9), Some(&b"c"[..]));
    }

    #[test]
    fn binary_content_has_no_blocks() {
        let file = ConflictFile::new("f".into(), ConflictKind::Content, Some(b"\0\x01".to_vec()));
        assert_eq!(file.kind, ConflictKind::Binary);
        assert!(file.blocks.is_empty() && !file.is_resolved_text());
    }

    #[test]
    fn parses_log_records() {
        let commits = parse_preview_commits(b"aaa\0one\0Ann\x001700000000\0\nbbb\0two\0Bo\x001\0");
        assert_eq!(commits.len(), 2);
        assert_eq!(commits[0].subject, "one");
        assert_eq!(commits[1].oid, "bbb");
        let undo = parse_undoable(b"ccc\0p1 p2\x001700\0Merge x\n\nbody\n").unwrap();
        assert!(undo.is_merge());
        assert_eq!(
            (undo.subject.as_str(), undo.body.as_str()),
            ("Merge x", "body")
        );
    }
}
