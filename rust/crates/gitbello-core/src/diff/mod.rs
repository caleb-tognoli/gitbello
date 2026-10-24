//! Diffs of one file (PLAN §3.10): `git diff` output parsed into hunks and
//! lines. Line text stays in one byte buffer, raw (CRLF and invalid UTF-8
//! kept), so the UI reads slices and later milestones can build patches.

use std::path::PathBuf;

use crate::repo::ParseError;

mod patch;

pub use patch::{build_patch, PatchMode};

/// Diffs whose git output exceeds this many bytes are not loaded until the
/// user asks for them ("load anyway").
pub const LARGE_DIFF_BYTES: usize = 2 * 1024 * 1024;

/// Characters of a line the UI gets; longer lines end in `…`.
pub const MAX_DISPLAY_CHARS: usize = 2000;

/// Columns between tab stops when lines are prepared for display.
pub const TAB_WIDTH: usize = 4;

/// git treats a file as binary when this prefix contains a NUL byte.
const BINARY_SNIFF_BYTES: usize = 8000;

/// Which side of the working copy a diff compares.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DiffKind {
    /// Working tree against the index.
    Unstaged,
    /// Index against HEAD.
    Staged,
    /// A file git does not track yet: everything is added.
    Untracked,
    /// A file in a commit, against the commit's first parent.
    Commit,
}

/// The commit a [`DiffKind::Commit`] diff shows.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CommitSide {
    pub oid: String,
    /// First parent; `None` for a root commit.
    pub parent: Option<String>,
}

/// The diff to show: one file in one change list.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DiffTarget {
    pub kind: DiffKind,
    /// Repository-relative path, as in status.
    pub path: PathBuf,
    /// Source of a staged rename or copy.
    pub original_path: Option<PathBuf>,
    /// Set for [`DiffKind::Commit`].
    pub commit: Option<CommitSide>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineKind {
    /// `@@ -a,b +c,d @@ section` (the text is the whole header line).
    Hunk,
    Context,
    Added,
    Removed,
}

/// One displayed line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DiffLine<'a> {
    pub kind: LineKind,
    /// Line number in the old file (context and removed lines).
    pub old_line: Option<u32>,
    /// Line number in the new file (context and added lines).
    pub new_line: Option<u32>,
    /// Content without the `+`/`-`/space prefix and without `\n`.
    pub text: &'a [u8],
    /// Followed by `\ No newline at end of file`.
    pub no_newline: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct LineEntry {
    kind: LineKind,
    old: u32,
    new: u32,
    start: usize,
    end: usize,
    no_newline: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Hunk {
    pub old_start: u32,
    pub old_count: u32,
    pub new_start: u32,
    pub new_count: u32,
    /// Index of the hunk's header in the line list.
    pub line: usize,
}

/// File-level facts from the extended header lines.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DiffHeader {
    pub new_file: bool,
    pub deleted_file: bool,
    pub old_mode: Option<String>,
    pub new_mode: Option<String>,
    pub similarity: Option<u8>,
    pub renamed_from: Option<String>,
    pub copied_from: Option<String>,
    /// Blob ids from the `index <old>..<new>` line (full with `--full-index`);
    /// all zeros for a side that does not exist.
    pub old_oid: Option<String>,
    pub new_oid: Option<String>,
}

impl DiffHeader {
    /// Short human-readable notes ("New file", "Mode 100644 → 100755", ...).
    pub fn notes(&self) -> Vec<String> {
        let mut notes = Vec::new();
        if self.new_file {
            notes.push("New file".to_owned());
        }
        if self.deleted_file {
            notes.push("Deleted file".to_owned());
        }
        let similarity = self
            .similarity
            .map(|s| format!(" ({s}% similar)"))
            .unwrap_or_default();
        if let Some(from) = &self.renamed_from {
            notes.push(format!("Renamed from {from}{similarity}"));
        }
        if let Some(from) = &self.copied_from {
            notes.push(format!("Copied from {from}{similarity}"));
        }
        if let (Some(old), Some(new)) = (&self.old_mode, &self.new_mode) {
            if !self.new_file && !self.deleted_file && old != new {
                notes.push(format!("Mode {old} → {new}"));
            }
        }
        notes
    }
}

/// What a diff holds besides its lines.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DiffContent {
    #[default]
    Text,
    /// git reported "Binary files differ"; sizes are filled in when known.
    Binary {
        old_size: Option<u64>,
        new_size: Option<u64>,
    },
    /// Not loaded: the output passed [`LARGE_DIFF_BYTES`] (at least `bytes`).
    TooLarge { bytes: u64 },
    /// A combined diff (unmerged file): shown as plain lines, no numbers.
    Combined,
}

/// The parsed diff of one file.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FileDiff {
    pub header: DiffHeader,
    pub content: DiffContent,
    pub additions: u32,
    pub deletions: u32,
    pub hunks: Vec<Hunk>,
    lines: Vec<LineEntry>,
    text: Vec<u8>,
    /// Per line: the removed/added line it pairs with, or [`NONE`].
    partners: Vec<u32>,
    /// Side-by-side rows as (left, right) line indices; a hunk header fills
    /// both sides.
    split: Vec<[u32; 2]>,
}

/// No line (in [`FileDiff`]'s pairing tables).
const NONE: u32 = u32::MAX;

impl FileDiff {
    /// A diff that was not loaded because it is larger than the limit.
    pub fn too_large(bytes: usize) -> Self {
        Self {
            content: DiffContent::TooLarge {
                bytes: bytes as u64,
            },
            ..Self::default()
        }
    }

    pub fn line_count(&self) -> usize {
        self.lines.len()
    }

    /// The line a removed or added line is paired with: the n-th removed
    /// line of a change block pairs with its n-th added line.
    pub fn partner(&self, line: usize) -> Option<usize> {
        self.partners
            .get(line)
            .filter(|&&p| p != NONE)
            .map(|&p| p as usize)
    }

    /// Rows of the side-by-side layout.
    pub fn split_row_count(&self) -> usize {
        self.split.len()
    }

    /// `(left, right)` line indices of a side-by-side row; context lines and
    /// hunk headers have the same line on both sides.
    pub fn split_row(&self, row: usize) -> Option<(Option<usize>, Option<usize>)> {
        let [left, right] = *self.split.get(row)?;
        let side = |l: u32| (l != NONE).then_some(l as usize);
        Some((side(left), side(right)))
    }

    /// Fills the pairing tables once the lines are final.
    fn pair_lines(&mut self) {
        let n = self.lines.len();
        self.partners = vec![NONE; n];
        self.split = Vec::with_capacity(n);
        let to = |i: usize| u32::try_from(i).unwrap_or(NONE);
        let mut i = 0;
        while i < n {
            match self.lines[i].kind {
                LineKind::Hunk | LineKind::Context => {
                    self.split.push([to(i), to(i)]);
                    i += 1;
                }
                LineKind::Removed | LineKind::Added => {
                    let removed_start = i;
                    while i < n && self.lines[i].kind == LineKind::Removed {
                        i += 1;
                    }
                    let added_start = i;
                    while i < n && self.lines[i].kind == LineKind::Added {
                        i += 1;
                    }
                    let removed = added_start - removed_start;
                    let added = i - added_start;
                    for k in 0..removed.max(added) {
                        let left = (k < removed).then(|| removed_start + k);
                        let right = (k < added).then(|| added_start + k);
                        if let (Some(l), Some(r)) = (left, right) {
                            self.partners[l] = to(r);
                            self.partners[r] = to(l);
                        }
                        self.split
                            .push([left.map_or(NONE, to), right.map_or(NONE, to)]);
                    }
                }
            }
        }
    }

    /// No lines and nothing else to report (the file matches its base).
    pub fn is_empty(&self) -> bool {
        self.lines.is_empty() && self.content == DiffContent::Text && self.header.notes().is_empty()
    }

    pub fn line(&self, index: usize) -> Option<DiffLine<'_>> {
        let entry = self.lines.get(index)?;
        let numbered =
            |n: u32, kinds: &[LineKind]| (n > 0 && kinds.contains(&entry.kind)).then_some(n);
        Some(DiffLine {
            kind: entry.kind,
            old_line: numbered(entry.old, &[LineKind::Context, LineKind::Removed]),
            new_line: numbered(entry.new, &[LineKind::Context, LineKind::Added]),
            text: self.text.get(entry.start..entry.end).unwrap_or_default(),
            no_newline: entry.no_newline,
        })
    }

    /// Lines `start..start + count`, clamped to the diff.
    pub fn lines(&self, start: usize, count: usize) -> impl Iterator<Item = DiffLine<'_>> {
        let end = start.saturating_add(count).min(self.lines.len());
        (start.min(end)..end).filter_map(|i| self.line(i))
    }

    /// Largest line number shown, for sizing the number gutter.
    pub fn max_line_number(&self) -> u32 {
        self.hunks
            .iter()
            .map(|h| (h.old_start + h.old_count).max(h.new_start + h.new_count))
            .max()
            .unwrap_or(0)
    }

    fn push(&mut self, kind: LineKind, old: u32, new: u32, text: &[u8]) {
        let start = self.text.len();
        self.text.extend_from_slice(text);
        self.lines.push(LineEntry {
            kind,
            old,
            new,
            start,
            end: self.text.len(),
            no_newline: false,
        });
        match kind {
            LineKind::Added => self.additions += 1,
            LineKind::Removed => self.deletions += 1,
            LineKind::Hunk | LineKind::Context => {}
        }
    }

    fn mark_no_newline(&mut self) {
        if let Some(last) = self.lines.last_mut() {
            last.no_newline = true;
        }
    }
}

/// Lines of `bytes` split on `\n`; a final line without `\n` is kept.
fn split_lines(bytes: &[u8]) -> impl Iterator<Item = &[u8]> {
    let trimmed = bytes.strip_suffix(b"\n").unwrap_or(bytes);
    let empty = bytes.is_empty();
    trimmed.split(|&b| b == b'\n').filter(move |_| !empty)
}

fn after(line: &[u8], prefix: &str) -> Option<String> {
    line.strip_prefix(prefix.as_bytes())
        .map(|rest| String::from_utf8_lossy(rest).into_owned())
}

/// Parses `git diff` output for one file. Only the first file is read when
/// the output has several.
pub fn parse_diff(output: &[u8]) -> Result<FileDiff, ParseError> {
    let mut diff = parse_lines(output)?;
    diff.pair_lines();
    Ok(diff)
}

fn parse_lines(output: &[u8]) -> Result<FileDiff, ParseError> {
    let mut diff = FileDiff::default();
    let mut lines = split_lines(output).peekable();
    let mut seen_file = false;

    // Extended header, up to the first hunk.
    while let Some(&line) = lines.peek() {
        if line.starts_with(b"@@") {
            break;
        }
        if line.starts_with(b"diff ") {
            if seen_file {
                return Ok(diff);
            }
            seen_file = true;
            if line.starts_with(b"diff --cc ") || line.starts_with(b"diff --combined ") {
                diff.content = DiffContent::Combined;
            }
        } else if let Some(mode) = after(line, "new file mode ") {
            diff.header.new_file = true;
            diff.header.new_mode = Some(mode);
        } else if let Some(mode) = after(line, "deleted file mode ") {
            diff.header.deleted_file = true;
            diff.header.old_mode = Some(mode);
        } else if let Some(mode) = after(line, "old mode ") {
            diff.header.old_mode = Some(mode);
        } else if let Some(mode) = after(line, "new mode ") {
            diff.header.new_mode = Some(mode);
        } else if let Some(ids) = after(line, "index ") {
            let ids = ids.split(' ').next().unwrap_or_default();
            if let Some((old, new)) = ids.split_once("..") {
                diff.header.old_oid = Some(old.to_owned());
                diff.header.new_oid = Some(new.to_owned());
            }
        } else if let Some(score) = after(line, "similarity index ") {
            diff.header.similarity = score.trim_end_matches('%').parse().ok();
        } else if let Some(from) = after(line, "rename from ") {
            diff.header.renamed_from = Some(from);
        } else if let Some(from) = after(line, "copy from ") {
            diff.header.copied_from = Some(from);
        } else if line.starts_with(b"Binary files ") && line.ends_with(b" differ") {
            diff.content = DiffContent::Binary {
                old_size: None,
                new_size: None,
            };
        }
        lines.next();
    }

    if diff.content == DiffContent::Combined {
        for line in lines {
            if line.starts_with(b"diff ") {
                break;
            }
            let kind = if line.starts_with(b"@@@") {
                LineKind::Hunk
            } else {
                LineKind::Context
            };
            diff.push(kind, 0, 0, line);
        }
        return Ok(diff);
    }

    while let Some(header) = lines.next() {
        if header.starts_with(b"diff ") {
            break;
        }
        let range = parse_hunk_header(header)?;
        diff.hunks.push(Hunk {
            line: diff.lines.len(),
            ..range
        });
        diff.push(LineKind::Hunk, 0, 0, header);
        let (mut old, mut new) = (range.old_start, range.new_start);
        let (mut old_left, mut new_left) = (range.old_count, range.new_count);
        while old_left > 0 || new_left > 0 {
            let line = lines
                .next()
                .ok_or_else(|| ParseError::new("diff", "hunk ends early"))?;
            let (kind, text) = match line.first() {
                // git writes empty context lines as "" with diff.suppressBlankEmpty.
                None => (LineKind::Context, line),
                Some(b' ') => (LineKind::Context, &line[1..]),
                Some(b'-') => (LineKind::Removed, &line[1..]),
                Some(b'+') => (LineKind::Added, &line[1..]),
                Some(b'\\') => {
                    diff.mark_no_newline();
                    continue;
                }
                Some(_) => return Err(ParseError::new("diff", "unexpected line in hunk")),
            };
            let short = || ParseError::new("diff", "hunk longer than its header says");
            match kind {
                LineKind::Context => {
                    old_left = old_left.checked_sub(1).ok_or_else(short)?;
                    new_left = new_left.checked_sub(1).ok_or_else(short)?;
                    diff.push(kind, old, new, text);
                    old += 1;
                    new += 1;
                }
                LineKind::Removed => {
                    old_left = old_left.checked_sub(1).ok_or_else(short)?;
                    diff.push(kind, old, 0, text);
                    old += 1;
                }
                LineKind::Added => {
                    new_left = new_left.checked_sub(1).ok_or_else(short)?;
                    diff.push(kind, 0, new, text);
                    new += 1;
                }
                LineKind::Hunk => {}
            }
        }
        while lines.next_if(|l| l.starts_with(b"\\")).is_some() {
            diff.mark_no_newline();
        }
    }
    Ok(diff)
}

/// `@@ -a[,b] +c[,d] @@ ...`; a missing count means 1.
fn parse_hunk_header(line: &[u8]) -> Result<Hunk, ParseError> {
    let bad = || {
        ParseError::new(
            "diff hunk header",
            String::from_utf8_lossy(line).into_owned(),
        )
    };
    let text = std::str::from_utf8(line).unwrap_or_default();
    let rest = text.strip_prefix("@@ -").ok_or_else(bad)?;
    let (ranges, _) = rest.split_once(" @@").ok_or_else(bad)?;
    let (old, new) = ranges.split_once(" +").ok_or_else(bad)?;
    let range = |r: &str| -> Option<(u32, u32)> {
        match r.split_once(',') {
            Some((start, count)) => Some((start.parse().ok()?, count.parse().ok()?)),
            None => Some((r.parse().ok()?, 1)),
        }
    };
    let (old_start, old_count) = range(old).ok_or_else(bad)?;
    let (new_start, new_count) = range(new).ok_or_else(bad)?;
    Ok(Hunk {
        old_start,
        old_count,
        new_start,
        new_count,
        line: 0,
    })
}

/// Whether `content` looks binary the way git decides it (a NUL byte early on).
pub fn looks_binary(content: &[u8]) -> bool {
    content[..content.len().min(BINARY_SNIFF_BYTES)].contains(&0)
}

/// The diff of an untracked file: every line added.
pub fn untracked_diff(content: &[u8]) -> FileDiff {
    let mut diff = untracked_lines(content);
    diff.pair_lines();
    diff
}

fn untracked_lines(content: &[u8]) -> FileDiff {
    let mut diff = FileDiff {
        header: DiffHeader {
            new_file: true,
            ..DiffHeader::default()
        },
        ..FileDiff::default()
    };
    if looks_binary(content) {
        diff.content = DiffContent::Binary {
            old_size: None,
            new_size: Some(content.len() as u64),
        };
        return diff;
    }
    let count = split_lines(content).count() as u32;
    if count == 0 {
        return diff;
    }
    let header = format!("@@ -0,0 +1,{count} @@");
    diff.hunks.push(Hunk {
        old_start: 0,
        old_count: 0,
        new_start: 1,
        new_count: count,
        line: 0,
    });
    diff.push(LineKind::Hunk, 0, 0, header.as_bytes());
    for (i, line) in split_lines(content).enumerate() {
        diff.push(LineKind::Added, 0, i as u32 + 1, line);
    }
    if !content.ends_with(b"\n") {
        diff.mark_no_newline();
    }
    diff
}

/// The changed parts of a removed line and the added line it pairs with,
/// as character ranges `(start, end)` in each: the text between their common
/// prefix and suffix, widened to whole words. `None` when the lines share
/// too little for a highlight to help.
pub fn changed_ranges(old: &str, new: &str) -> Option<((usize, usize), (usize, usize))> {
    let a: Vec<char> = old.chars().collect();
    let b: Vec<char> = new.chars().collect();
    let max_common = a.len().min(b.len());
    let mut prefix = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let mut suffix = a
        .iter()
        .rev()
        .zip(b.iter().rev())
        .take(max_common - prefix)
        .take_while(|(x, y)| x == y)
        .count();
    if prefix + suffix == a.len() && prefix + suffix == b.len() {
        return None; // identical
    }
    let word = |s: &[char], i: usize| s.get(i).is_some_and(|&c| c.is_alphanumeric() || c == '_');
    // Do not split a word: move the cut to the word's start (prefix) and
    // end (suffix) when the change starts or ends inside it.
    while prefix > 0 && word(&a, prefix - 1) && (word(&a, prefix) || word(&b, prefix)) {
        prefix -= 1;
    }
    while suffix > 0 && {
        let (ia, ib) = (a.len() - suffix, b.len() - suffix);
        word(&a, ia) && ((ia > 0 && word(&a, ia - 1)) || (ib > 0 && word(&b, ib - 1)))
    } {
        suffix -= 1;
    }
    let common = prefix + suffix;
    let longest = a.len().max(b.len());
    // Mostly rewritten lines read better without a highlight.
    if common * 10 < longest * 3 {
        return None;
    }
    Some(((prefix, a.len() - suffix), (prefix, b.len() - suffix)))
}

/// Line text prepared for display: lossy UTF-8, one trailing `\r` dropped,
/// tabs expanded to [`TAB_WIDTH`] stops, at most [`MAX_DISPLAY_CHARS`].
pub fn display_text(bytes: &[u8]) -> String {
    let bytes = bytes.strip_suffix(b"\r").unwrap_or(bytes);
    let text = String::from_utf8_lossy(bytes);
    let mut out = String::with_capacity(text.len());
    let mut column = 0;
    for ch in text.chars() {
        if column >= MAX_DISPLAY_CHARS {
            out.push('…');
            break;
        }
        if ch == '\t' {
            let spaces = TAB_WIDTH - column % TAB_WIDTH;
            out.extend(std::iter::repeat_n(' ', spaces));
            column += spaces;
        } else {
            out.push(ch);
            column += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    type Row = (LineKind, Option<u32>, Option<u32>, String, bool);

    fn texts(diff: &FileDiff) -> Vec<Row> {
        diff.lines(0, usize::MAX)
            .map(|l| {
                (
                    l.kind,
                    l.old_line,
                    l.new_line,
                    String::from_utf8_lossy(l.text).into_owned(),
                    l.no_newline,
                )
            })
            .collect()
    }

    const MODIFIED: &[u8] = b"diff --git a/src/app.txt b/src/app.txt
index 1111111..2222222 100644
--- a/src/app.txt
+++ b/src/app.txt
@@ -1,3 +1,4 @@ fn main
 one
-two
+two!
+two and a half
 three
@@ -10 +11 @@
-ten
+TEN
";

    #[test]
    fn parses_hunks_and_line_numbers() {
        let diff = parse_diff(MODIFIED).unwrap();
        assert_eq!(diff.content, DiffContent::Text);
        assert_eq!((diff.additions, diff.deletions), (3, 2));
        assert_eq!(diff.hunks.len(), 2);
        assert_eq!(
            (
                diff.hunks[1].old_start,
                diff.hunks[1].old_count,
                diff.hunks[1].line
            ),
            (10, 1, 6)
        );
        use LineKind::*;
        let lines = texts(&diff);
        assert_eq!(
            lines[0],
            (Hunk, None, None, "@@ -1,3 +1,4 @@ fn main".into(), false)
        );
        assert_eq!(lines[1], (Context, Some(1), Some(1), "one".into(), false));
        assert_eq!(lines[2], (Removed, Some(2), None, "two".into(), false));
        assert_eq!(lines[3], (Added, None, Some(2), "two!".into(), false));
        assert_eq!(
            lines[4],
            (Added, None, Some(3), "two and a half".into(), false)
        );
        assert_eq!(lines[5], (Context, Some(3), Some(4), "three".into(), false));
        assert_eq!(lines[7], (Removed, Some(10), None, "ten".into(), false));
        assert_eq!(lines[8], (Added, None, Some(11), "TEN".into(), false));
        assert_eq!(diff.max_line_number(), 12);
    }

    #[test]
    fn no_newline_markers_attach_to_the_line_before() {
        let out = b"diff --git a/f b/f
--- a/f
+++ b/f
@@ -1,2 +1,3 @@
 a
-b
\\ No newline at end of file
+b
+c
\\ No newline at end of file
";
        let diff = parse_diff(out).unwrap();
        let flags: Vec<bool> = diff.lines(0, 10).map(|l| l.no_newline).collect();
        assert_eq!(flags, [false, false, true, false, true]);
    }

    #[test]
    fn keeps_crlf_and_reads_empty_context_lines() {
        let out = b"diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n a\r\n\n-b\r\n+c\r\n";
        let diff = parse_diff(out).unwrap();
        let lines: Vec<&[u8]> = diff.lines(1, 10).map(|l| l.text).collect();
        assert_eq!(lines, [&b"a\r"[..], b"", b"b\r", b"c\r"]);
        assert_eq!(display_text(lines[0]), "a");
    }

    #[test]
    fn new_deleted_renamed_and_mode_headers() {
        let new = parse_diff(
            b"diff --git a/n b/n\nnew file mode 100644\nindex 0000000..1111111\n--- /dev/null\n+++ b/n\n@@ -0,0 +1 @@\n+x\n",
        )
        .unwrap();
        assert!(new.header.new_file);
        assert_eq!(new.header.notes(), ["New file"]);
        assert_eq!(texts(&new)[1].2, Some(1));

        let deleted = parse_diff(
            b"diff --git a/d b/d\ndeleted file mode 100755\n--- a/d\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n",
        )
        .unwrap();
        assert!(deleted.header.deleted_file);
        assert_eq!(deleted.deletions, 1);

        let renamed = parse_diff(
            b"diff --git a/old b/new\nsimilarity index 90%\nrename from old\nrename to new\n",
        )
        .unwrap();
        assert_eq!(renamed.header.notes(), ["Renamed from old (90% similar)"]);
        assert!(!renamed.is_empty());

        let mode = parse_diff(b"diff --git a/s b/s\nold mode 100644\nnew mode 100755\n").unwrap();
        assert_eq!(mode.header.notes(), ["Mode 100644 → 100755"]);
    }

    #[test]
    fn binary_and_empty_output() {
        let bin = parse_diff(
            b"diff --git a/i.png b/i.png\nindex 1..2 100644\nBinary files a/i.png and b/i.png differ\n",
        )
        .unwrap();
        assert!(matches!(bin.content, DiffContent::Binary { .. }));
        assert_eq!(bin.line_count(), 0);
        let empty = parse_diff(b"").unwrap();
        assert!(empty.is_empty());
    }

    #[test]
    fn combined_diffs_become_plain_lines() {
        let out = b"diff --cc f\nindex 1,2..0000000\n--- a/f\n+++ b/f\n@@@ -1,1 -1,1 +1,5 @@@\n++<<<<<<< HEAD\n +ours\n";
        let diff = parse_diff(out).unwrap();
        assert_eq!(diff.content, DiffContent::Combined);
        let lines = texts(&diff);
        assert_eq!(lines[0].0, LineKind::Hunk);
        assert_eq!(
            lines[1],
            (
                LineKind::Context,
                None,
                None,
                "++<<<<<<< HEAD".into(),
                false
            )
        );
    }

    #[test]
    fn only_the_first_file_is_read() {
        let mut out = MODIFIED.to_vec();
        out.extend_from_slice(
            b"diff --git a/other b/other\n--- a/other\n+++ b/other\n@@ -1 +1 @@\n-x\n+y\n",
        );
        let diff = parse_diff(&out).unwrap();
        assert_eq!(diff.hunks.len(), 2);
    }

    #[test]
    fn rejects_truncated_and_malformed_hunks() {
        assert!(parse_diff(b"diff --git a/f b/f\n@@ -1,2 +1,2 @@\n a\n").is_err());
        assert!(parse_diff(b"diff --git a/f b/f\n@@ -1 +1 @@\n a\n b\n").is_err());
        assert!(parse_diff(b"diff --git a/f b/f\n@@ nonsense @@\n").is_err());
        assert!(parse_diff(b"diff --git a/f b/f\n@@ -1 +1 @@\n?\n").is_err());
    }

    #[test]
    fn untracked_files() {
        let diff = untracked_diff(b"a\nb");
        assert!(diff.header.new_file);
        assert_eq!(diff.additions, 2);
        let lines = texts(&diff);
        assert_eq!(lines[0].3, "@@ -0,0 +1,2 @@");
        assert_eq!(lines[2], (LineKind::Added, None, Some(2), "b".into(), true));
        assert_eq!(untracked_diff(b"").line_count(), 0);
        assert!(matches!(
            untracked_diff(b"PNG\0data").content,
            DiffContent::Binary {
                new_size: Some(8),
                ..
            }
        ));
    }

    #[test]
    fn pairs_changes_for_side_by_side() {
        let diff = parse_diff(MODIFIED).unwrap();
        // 0 hunk, 1 one, 2 -two, 3 +two!, 4 +two and a half, 5 three, 6 hunk, 7 -ten, 8 +TEN
        assert_eq!(diff.partner(2), Some(3));
        assert_eq!(diff.partner(3), Some(2));
        assert_eq!(diff.partner(4), None);
        assert_eq!(diff.partner(1), None);
        let rows: Vec<_> = (0..diff.split_row_count())
            .map(|r| diff.split_row(r).unwrap())
            .collect();
        assert_eq!(
            rows,
            [
                (Some(0), Some(0)),
                (Some(1), Some(1)),
                (Some(2), Some(3)),
                (None, Some(4)),
                (Some(5), Some(5)),
                (Some(6), Some(6)),
                (Some(7), Some(8)),
            ]
        );
        let new_file = untracked_diff(
            b"a
b
",
        );
        assert_eq!(new_file.split_row(1), Some((None, Some(1))));
    }

    #[test]
    fn changed_ranges_cover_whole_words() {
        assert_eq!(
            changed_ranges("let x = old_name(1);", "let x = new_name(1);"),
            Some(((8, 16), (8, 16)))
        );
        assert_eq!(
            changed_ranges("value: 10,", "value: 12,"),
            Some(((7, 9), (7, 9)))
        );
        assert_eq!(changed_ranges("abc", "abc"), None);
        assert_eq!(changed_ranges("completely", "different words"), None);
        // A short word that changed is the whole line: no highlight.
        assert_eq!(changed_ranges("a", "ab"), None);
        assert_eq!(changed_ranges("x = 1", "x = 1;"), Some(((5, 5), (5, 6))));
    }

    #[test]
    fn display_text_expands_tabs_and_truncates() {
        assert_eq!(display_text(b"a\tb\t\tc"), "a   b       c");
        assert_eq!(display_text(&[0xff, b'x']), "\u{fffd}x");
        let long = vec![b'x'; MAX_DISPLAY_CHARS + 10];
        let shown = display_text(&long);
        assert_eq!(shown.chars().count(), MAX_DISPLAY_CHARS + 1);
        assert!(shown.ends_with('…'));
    }
}
