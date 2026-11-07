//! Line endings in a diff (PLAN M7.9): the marker rows a diff view shows
//! after a line without a final newline and, after the last line, when
//! endings changed, and what a file's changes add up to (`CRLF → LF`, only
//! endings changed, the final newline added or removed).
//!
//! Endings are read as git compares them: a line's text keeps its `\r`, so
//! a repository that normalizes endings shows no ending changes at all.

use super::{FileDiff, LineKind};

/// The endings of some lines.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Endings {
    Lf,
    Crlf,
    Mixed,
}

impl Endings {
    pub fn id(self) -> &'static str {
        match self {
            Self::Lf => "LF",
            Self::Crlf => "CRLF",
            Self::Mixed => "mixed",
        }
    }

    /// `acc` with one more line ending `self`.
    fn add_to(self, acc: Option<Endings>) -> Option<Endings> {
        match acc {
            None => Some(self),
            Some(seen) if seen == self => Some(seen),
            Some(_) => Some(Self::Mixed),
        }
    }

    fn join(a: Option<Endings>, b: Option<Endings>) -> Option<Endings> {
        match (a, b) {
            (Some(a), b) => a.add_to(b),
            (None, b) => b,
        }
    }
}

/// A row a diff view shows between lines.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Marker {
    /// The line above is the last of its file and has no newline: on the
    /// old side, the new side or both (an unchanged last line).
    NoNewline { old: bool, new: bool },
    /// The diff changed line endings (shown after its last line): from the
    /// endings before to the endings after, on `lines` lines.
    LineEndings {
        from: Endings,
        to: Endings,
        lines: u32,
    },
}

/// How the final newline changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FinalNewline {
    Added,
    Removed,
}

impl FinalNewline {
    pub fn id(self) -> &'static str {
        match self {
            Self::Added => "added",
            Self::Removed => "removed",
        }
    }
}

/// What a diff's ending changes add up to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct EndingSummary {
    /// Endings before and after over the blocks whose endings changed;
    /// `None` when none did.
    pub changed: Option<(Endings, Endings)>,
    /// Lines whose ending changed.
    pub lines: u32,
    pub final_newline: Option<FinalNewline>,
    /// Nothing else changed: every changed line pairs with one of the same
    /// text, and endings or the final newline did change.
    pub only: bool,
}

impl EndingSummary {
    /// The row shown after the diff's last line when endings changed.
    pub fn marker(&self) -> Option<Marker> {
        let (from, to) = self.changed?;
        Some(Marker::LineEndings {
            from,
            to,
            lines: self.lines,
        })
    }
}

/// Marker rows by the line or row they follow.
pub(super) type Markers = Vec<(usize, Marker)>;

/// The no-newline rows of `diff`: after diff line `n` (unified) and after
/// side-by-side row `n`. (The line-endings row follows the last line; see
/// [`EndingSummary::marker`].)
pub(super) fn markers(diff: &FileDiff) -> (Markers, Markers) {
    let mut unified = Vec::new();
    for index in 0..diff.line_count() {
        if let Some(marker) = no_newline_marker(diff, &[Some(index)]) {
            unified.push((index, marker));
        }
    }
    let mut split = Vec::new();
    for row in 0..diff.split_row_count() {
        let Some((left, right)) = diff.split_row(row) else {
            continue;
        };
        let sides = if left == right {
            [left, None]
        } else {
            [left, right]
        };
        if let Some(marker) = no_newline_marker(diff, &sides) {
            split.push((row, marker));
        }
    }
    (unified, split)
}

/// The no-newline marker of the lines on a row, if one lacks it.
fn no_newline_marker(diff: &FileDiff, lines: &[Option<usize>]) -> Option<Marker> {
    let (mut old, mut new) = (false, false);
    for line in lines.iter().flatten().filter_map(|&i| diff.line(i)) {
        if line.no_newline {
            match line.kind {
                LineKind::Removed => old = true,
                LineKind::Added => new = true,
                LineKind::Context => (old, new) = (true, true),
                LineKind::Hunk => {}
            }
        }
    }
    (old || new).then_some(Marker::NoNewline { old, new })
}

fn is_change(diff: &FileDiff, index: usize) -> bool {
    diff.line(index)
        .is_some_and(|l| matches!(l.kind, LineKind::Added | LineKind::Removed))
}

/// The ending of diff line `index`; `None` for a line without a newline.
fn ending(diff: &FileDiff, index: usize) -> Option<Endings> {
    let line = diff.line(index)?;
    if line.no_newline {
        None
    } else if line.text.ends_with(b"\r") {
        Some(Endings::Crlf)
    } else {
        Some(Endings::Lf)
    }
}

fn text_without_cr(text: &[u8]) -> &[u8] {
    text.strip_suffix(b"\r").unwrap_or(text)
}

/// One change block: its removed lines, then its added lines.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Block {
    from: Option<Endings>,
    to: Option<Endings>,
    /// Added lines whose ending is not the one they replaced.
    lines: u32,
    /// Every removed line pairs with an added one of the same text.
    same_text: bool,
}

impl Block {
    /// The block changed endings: they differ before and after, or some
    /// line's did.
    fn changes_endings(&self) -> bool {
        matches!((self.from, self.to), (Some(from), Some(to)) if from != to || self.lines > 0)
    }
}

/// The change block whose last line is diff line `index`.
fn block_ending_at(diff: &FileDiff, index: usize) -> Option<Block> {
    if !is_change(diff, index) || is_change(diff, index + 1) {
        return None;
    }
    let mut start = index;
    while start > 0 && is_change(diff, start - 1) {
        start -= 1;
    }
    Some(block(diff, start, index + 1))
}

/// The block of diff lines `start..end` (removed lines, then added ones).
fn block(diff: &FileDiff, start: usize, end: usize) -> Block {
    let kind = |i: usize| diff.line(i).map(|l| l.kind);
    let added_start = (start..end)
        .find(|&i| kind(i) == Some(LineKind::Added))
        .unwrap_or(end);
    let mut from = None;
    for i in start..added_start {
        from = ending(diff, i).map_or(from, |e| e.add_to(from));
    }
    // An insertion takes the endings of its hunk's unchanged lines.
    if from.is_none() && added_start == start {
        from = hunk_context_endings(diff, start);
    }
    let mut to = None;
    let mut lines = 0;
    for i in added_start..end {
        let Some(new) = ending(diff, i) else {
            continue;
        };
        to = new.add_to(to);
        // A line that had no newline gained one: that is the final newline's
        // change, not its ending's.
        let old = match diff.partner(i) {
            Some(p) => ending(diff, p),
            None => from.filter(|f| *f != Endings::Mixed),
        };
        if old.is_some_and(|old| old != new) {
            lines += 1;
        }
    }
    let removed = added_start - start;
    let same_text = removed == end - added_start
        && (start..added_start).all(|i| {
            let partner = diff.partner(i).and_then(|p| diff.line(p));
            match (diff.line(i), partner) {
                (Some(a), Some(b)) => text_without_cr(a.text) == text_without_cr(b.text),
                _ => false,
            }
        });
    Block {
        from,
        to,
        lines,
        same_text,
    }
}

/// The endings of the unchanged lines in the hunk around diff line `index`.
fn hunk_context_endings(diff: &FileDiff, index: usize) -> Option<Endings> {
    let header = diff.hunks.iter().rev().find(|h| h.line <= index)?.line;
    let end = diff
        .hunks
        .iter()
        .find(|h| h.line > index)
        .map_or(diff.line_count(), |h| h.line);
    (header + 1..end)
        .filter(|&i| diff.line(i).is_some_and(|l| l.kind == LineKind::Context))
        .filter_map(|i| ending(diff, i))
        .fold(None, |acc, e| e.add_to(acc))
}

/// What `diff`'s ending changes add up to.
pub fn summary(diff: &FileDiff) -> EndingSummary {
    let mut summary = EndingSummary::default();
    let (mut from, mut to) = (None, None);
    let mut same_text = true;
    let mut blocks = 0;
    for index in 0..diff.line_count() {
        let Some(block) = block_ending_at(diff, index) else {
            continue;
        };
        blocks += 1;
        same_text &= block.same_text;
        if block.changes_endings() {
            from = Endings::join(block.from, from);
            to = Endings::join(block.to, to);
            summary.lines += block.lines;
        }
    }
    summary.changed = from.zip(to);
    if !diff.header.new_file && !diff.header.deleted_file {
        let (mut old_lacks, mut new_lacks) = (false, false);
        for line in diff.lines(0, diff.line_count()).filter(|l| l.no_newline) {
            match line.kind {
                LineKind::Removed => old_lacks = true,
                LineKind::Added => new_lacks = true,
                LineKind::Context => (old_lacks, new_lacks) = (true, true),
                LineKind::Hunk => {}
            }
        }
        summary.final_newline = match (old_lacks, new_lacks) {
            (true, false) => Some(FinalNewline::Added),
            (false, true) => Some(FinalNewline::Removed),
            _ => None,
        };
    }
    summary.only =
        blocks > 0 && same_text && (summary.changed.is_some() || summary.final_newline.is_some());
    summary
}

/// The working file no longer matches the diff's new side: it changed since
/// the diff was read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mismatch;

/// A working-file line: where its text starts and ends (the text keeps a
/// `\r`, as diff lines do), and whether a `\n` follows.
#[derive(Debug, Clone, Copy)]
struct WorkingLine {
    start: usize,
    end: usize,
    newline: bool,
}

fn working_lines(bytes: &[u8]) -> Vec<WorkingLine> {
    let mut lines = Vec::new();
    let mut start = 0;
    for (i, &b) in bytes.iter().enumerate() {
        if b == b'\n' {
            lines.push(WorkingLine {
                start,
                end: i,
                newline: true,
            });
            start = i + 1;
        }
    }
    if start < bytes.len() {
        lines.push(WorkingLine {
            start,
            end: bytes.len(),
            newline: false,
        });
    }
    lines
}

/// The endings of the old side's lines in `diff` (removed and unchanged).
fn old_endings(diff: &FileDiff) -> Option<Endings> {
    (0..diff.line_count())
        .filter(|&i| {
            diff.line(i)
                .is_some_and(|l| matches!(l.kind, LineKind::Removed | LineKind::Context))
        })
        .filter_map(|i| ending(diff, i))
        .fold(None, |acc, e| e.add_to(acc))
}

/// `working` with the line endings `diff` (index → working copy) changed
/// put back, keeping the text: an added line paired with a removed line
/// takes its ending, other added lines their block's old ending (else the
/// file's). The last line gets its old final newline back when its text is
/// unchanged. `Ok(None)` when nothing changes; `Mismatch` when `working` is
/// not the diff's new side.
pub fn restore_endings(diff: &FileDiff, working: &[u8]) -> Result<Option<Vec<u8>>, Mismatch> {
    let lines = working_lines(working);
    let text = |l: &WorkingLine| &working[l.start..l.end];
    // Per working line: the ending to give it (`Some(None)`: none at all).
    let mut targets: Vec<Option<Option<Endings>>> = vec![None; lines.len()];
    let file_from = old_endings(diff).filter(|e| *e != Endings::Mixed);
    let mut index = 0;
    while index < diff.line_count() {
        let Some(line) = diff.line(index) else {
            break;
        };
        if let Some(n) = line.new_line {
            let w = (n as usize)
                .checked_sub(1)
                .and_then(|k| lines.get(k))
                .ok_or(Mismatch)?;
            if text(w) != line.text || w.newline == line.no_newline {
                return Err(Mismatch);
            }
        }
        if !is_change(diff, index) {
            index += 1;
            continue;
        }
        let start = index;
        let mut end = index;
        while is_change(diff, end) {
            end += 1;
        }
        let fallback = block(diff, start, end)
            .from
            .filter(|e| *e != Endings::Mixed)
            .or(file_from);
        for i in start..end {
            let Some(added) = diff.line(i).filter(|l| l.kind == LineKind::Added) else {
                continue;
            };
            let Some(n) = added.new_line.and_then(|n| (n as usize).checked_sub(1)) else {
                continue;
            };
            let w = lines.get(n).ok_or(Mismatch)?;
            if text(w) != added.text || w.newline == added.no_newline {
                return Err(Mismatch);
            }
            let partner = diff.partner(i).and_then(|p| diff.line(p));
            let same_text =
                partner.is_some_and(|p| text_without_cr(p.text) == text_without_cr(added.text));
            // `None` when there is no partner or it lacks a newline.
            let partner_ending = diff.partner(i).and_then(|p| ending(diff, p));
            targets[n] = if added.no_newline {
                // The last line lost its newline: back when its text is the same.
                partner_ending.filter(|_| same_text).map(Some)
            } else if let Some(old) = partner_ending {
                Some(Some(old))
            } else if partner.is_some() && n + 1 == lines.len() && same_text {
                // It gained the final newline the old last line lacked.
                Some(None)
            } else {
                fallback.map(Some)
            };
        }
        index = end;
    }
    let mut out = Vec::with_capacity(working.len());
    for (w, target) in lines.iter().zip(&targets) {
        match target {
            Some(ending) => {
                out.extend_from_slice(text_without_cr(text(w)));
                out.extend_from_slice(match ending {
                    Some(Endings::Crlf) => b"\r\n",
                    Some(_) => b"\n",
                    None => b"",
                });
            }
            None => {
                let end = if w.newline { w.end + 1 } else { w.end };
                out.extend_from_slice(&working[w.start..end]);
            }
        }
    }
    Ok((out != working).then_some(out))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::parse_diff;

    fn diff(body: &str) -> FileDiff {
        let text = format!(
            "diff --git a/f.txt b/f.txt\nindex 1111111..2222222 100644\n--- a/f.txt\n+++ b/f.txt\n{body}"
        );
        parse_diff(text.as_bytes()).expect("parse")
    }

    fn endings(from: Endings, to: Endings, lines: u32) -> Option<Marker> {
        Some(Marker::LineEndings { from, to, lines })
    }

    fn restored(body: &str, working: &str) -> Option<String> {
        restore_endings(&diff(body), working.as_bytes())
            .expect("matches")
            .map(|b| String::from_utf8(b).expect("utf-8"))
    }

    #[test]
    fn restore_puts_paired_endings_back_and_keeps_text() {
        let body = "@@ -1,3 +1,3 @@\n-a\r\n-b\r\n+a\n+b\n c\r\n";
        assert_eq!(
            restored(body, "a\nb\nc\r\n").as_deref(),
            Some("a\r\nb\r\nc\r\n")
        );
        let edited = "@@ -1,2 +1,2 @@\n-a\n-b\n+a\r\n+B\r\n";
        assert_eq!(
            restored(edited, "a\r\nB\r\n").as_deref(),
            Some("a\nB\n"),
            "B stays"
        );
        let mixed = "@@ -1,2 +1,2 @@\n-a\r\n-b\n+a\n+b\r\n";
        assert_eq!(restored(mixed, "a\nb\r\n").as_deref(), Some("a\r\nb\n"));
    }

    #[test]
    fn restore_gives_added_lines_the_old_ending() {
        let inserted = "@@ -1,2 +1,3 @@\n a\r\n+x\n b\r\n";
        assert_eq!(
            restored(inserted, "a\r\nx\nb\r\n").as_deref(),
            Some("a\r\nx\r\nb\r\n")
        );
        let more = "@@ -1,2 +1,3 @@\n-a\r\n+a\n+y\n b\r\n";
        assert_eq!(
            restored(more, "a\ny\nb\r\n").as_deref(),
            Some("a\r\ny\r\nb\r\n")
        );
        // Already the old endings: nothing to do.
        assert_eq!(restored("@@ -1 +1 @@\n-a\n+b\n", "b\n"), None);
    }

    #[test]
    fn restore_brings_the_final_newline_back_when_the_text_is_the_same() {
        let gained = "@@ -1,2 +1,2 @@\n-a\n-b\n\\ No newline at end of file\n+a\r\n+b\r\n";
        assert_eq!(restored(gained, "a\r\nb\r\n").as_deref(), Some("a\nb"));
        let lost = "@@ -1,2 +1,2 @@\n a\r\n-b\r\n+b\n\\ No newline at end of file\n";
        assert_eq!(restored(lost, "a\r\nb").as_deref(), Some("a\r\nb\r\n"));
        let changed = "@@ -1,2 +1,2 @@\n a\r\n-b\r\n+c\n\\ No newline at end of file\n";
        assert_eq!(
            restored(changed, "a\r\nc"),
            None,
            "c keeps its missing newline"
        );
    }

    #[test]
    fn restore_refuses_a_file_that_changed_since_the_diff() {
        let body = "@@ -1,2 +1,2 @@\n-a\r\n-b\r\n+a\n+b\n";
        let d = diff(body);
        assert_eq!(restore_endings(&d, b"a\nz\n"), Err(Mismatch));
        assert_eq!(restore_endings(&d, b"a\n"), Err(Mismatch));
        assert_eq!(restore_endings(&d, b"a\nb"), Err(Mismatch));
    }

    #[test]
    fn crlf_to_lf_is_one_row_at_the_end_and_only_endings() {
        let d = diff("@@ -1,3 +1,3 @@\n-a\r\n-b\r\n+a\n+b\n c\r\n");
        // No row between the lines: one after the last (see the layout).
        assert!(d.markers().is_empty() && d.split_markers().is_empty());
        assert_eq!(d.endings().marker(), endings(Endings::Crlf, Endings::Lf, 2));
        let s = summary(&d);
        assert_eq!(s.changed, Some((Endings::Crlf, Endings::Lf)));
        assert_eq!(s.lines, 2);
        assert!(s.only);
        assert_eq!(s.final_newline, None);
    }

    #[test]
    fn lf_to_crlf_and_text_changes_too() {
        let d = diff("@@ -1,2 +1,2 @@\n-a\n-b\n+a\r\n+B\r\n");
        let s = summary(&d);
        assert_eq!(s.changed, Some((Endings::Lf, Endings::Crlf)));
        assert_eq!(s.lines, 2);
        assert!(!s.only, "b became B");
    }

    #[test]
    fn mixed_endings_and_unchanged_endings() {
        let d = diff("@@ -1,2 +1,2 @@\n-a\r\n-b\n+a\n+b\n");
        assert_eq!(
            d.endings().marker(),
            endings(Endings::Mixed, Endings::Lf, 1)
        );
        // Same endings, other text: no row.
        let same = diff("@@ -1 +1 @@\n-a\r\n+b\r\n");
        assert_eq!(same.endings().marker(), None);
        let s = summary(&same);
        assert_eq!(s.changed, None);
        assert!(!s.only);
    }

    #[test]
    fn an_insertion_compares_with_its_hunks_lines() {
        let d = diff("@@ -1,2 +1,3 @@\n a\r\n+new\n b\r\n");
        assert_eq!(d.endings().marker(), endings(Endings::Crlf, Endings::Lf, 1));
        let fitting = diff("@@ -1,2 +1,3 @@\n a\r\n+new\r\n b\r\n");
        assert_eq!(fitting.endings().marker(), None);
    }

    #[test]
    fn final_newline_added_and_removed() {
        // Added: the old last line had none.
        let added = diff("@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+a\n");
        assert_eq!(
            added.markers(),
            [(
                1,
                Marker::NoNewline {
                    old: true,
                    new: false
                }
            )]
        );
        let s = summary(&added);
        assert_eq!(s.final_newline, Some(FinalNewline::Added));
        assert_eq!(s.changed, None);
        assert!(s.only);
        // Removed, with a line added before it.
        let removed = diff("@@ -1 +1,2 @@\n-a\n+a\n+b\n\\ No newline at end of file\n");
        assert_eq!(
            removed.markers(),
            [(
                3,
                Marker::NoNewline {
                    old: false,
                    new: true
                }
            )]
        );
        let s = summary(&removed);
        assert_eq!(s.final_newline, Some(FinalNewline::Removed));
        assert!(!s.only, "b was added");
        // Split: a|a, then |b with the marker on the new side only.
        assert_eq!(
            removed.split_markers(),
            [(
                2,
                Marker::NoNewline {
                    old: false,
                    new: true
                }
            )]
        );
    }

    #[test]
    fn an_unchanged_last_line_without_newline_marks_both_sides() {
        let d = diff("@@ -1,2 +1,2 @@\n-a\n+b\n c\n\\ No newline at end of file\n");
        assert_eq!(
            d.markers(),
            [(
                3,
                Marker::NoNewline {
                    old: true,
                    new: true
                }
            )]
        );
        assert_eq!(
            d.split_markers(),
            [(
                2,
                Marker::NoNewline {
                    old: true,
                    new: true
                }
            )]
        );
        assert_eq!(summary(&d).final_newline, None);
    }

    #[test]
    fn endings_and_final_newline_together() {
        // CRLF → LF, and the last line gains a newline.
        let d = diff("@@ -1,2 +1,2 @@\n-a\r\n-b\n\\ No newline at end of file\n+a\n+b\n");
        assert_eq!(
            d.markers(),
            [(
                2,
                Marker::NoNewline {
                    old: true,
                    new: false
                }
            )]
        );
        let s = summary(&d);
        assert_eq!(s.changed, Some((Endings::Crlf, Endings::Lf)));
        // b gained its newline: the final newline's change, not an ending's.
        assert_eq!(s.lines, 1);
        assert_eq!(s.final_newline, Some(FinalNewline::Added));
        assert!(s.only);
    }

    #[test]
    fn empty_lines_and_new_files() {
        // An empty CRLF line is "\r".
        let d = diff("@@ -1,2 +1,2 @@\n-a\r\n-\r\n+a\n+\n");
        assert!(summary(&d).only);
        let new_file = crate::diff::untracked_diff(b"a\nb");
        assert_eq!(
            new_file.markers(),
            [(
                2,
                Marker::NoNewline {
                    old: false,
                    new: true
                }
            )]
        );
        let s = summary(&new_file);
        assert_eq!(s.final_newline, None);
        assert!(!s.only);
    }
}
