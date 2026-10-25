//! The rows a diff view shows: the diff's lines plus the unchanged lines of
//! the file the user expanded between its hunks (PLAN §3.10). Those lines
//! come from the old file, which is where git takes context lines from too.
//! Rows are kept as runs, so a large diff costs a few entries, not one per
//! line.

use super::{DiffContent, FileDiff, Hunk, LineKind};

/// Lines one click on an expander shows.
pub const EXPAND_STEP: u32 = 20;

/// Context lines the diffs are loaded with (`-U3`); a last hunk that ends in
/// fewer reaches the end of the file.
pub const CONTEXT_LINES: usize = 3;

/// Which part of a gap an expander shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Expand {
    /// More lines just above the next hunk.
    Up,
    /// More lines just below the previous hunk.
    Down,
    /// The whole gap.
    All,
}

impl Expand {
    pub fn from_id(id: &str) -> Option<Self> {
        match id {
            "up" => Some(Self::Up),
            "down" => Some(Self::Down),
            "all" => Some(Self::All),
            _ => None,
        }
    }
}

/// The expander buttons a header (or the end row) shows for its gap.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Expanders {
    None,
    /// Above the first hunk: more lines upwards.
    Up,
    /// Below the last hunk: more lines downwards.
    Down,
    /// A large gap: upwards from the next hunk or downwards from the previous.
    Both,
    /// A small gap: all of it at once.
    All,
}

impl Expanders {
    pub fn id(self) -> &'static str {
        match self {
            Self::None => "",
            Self::Up => "up",
            Self::Down => "down",
            Self::Both => "both",
            Self::All => "all",
        }
    }
}

/// The old side of a diff, split into lines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OldFile {
    oid: String,
    text: Vec<u8>,
    /// Byte offset where each line starts.
    starts: Vec<usize>,
}

impl OldFile {
    pub fn new(oid: impl Into<String>, text: Vec<u8>) -> Self {
        let mut starts = Vec::new();
        if !text.is_empty() {
            starts.push(0);
        }
        for (i, &b) in text.iter().enumerate() {
            if b == b'\n' && i + 1 < text.len() {
                starts.push(i + 1);
            }
        }
        Self {
            oid: oid.into(),
            text,
            starts,
        }
    }

    /// Blob id the text was read from.
    pub fn oid(&self) -> &str {
        &self.oid
    }

    pub fn line_count(&self) -> u32 {
        u32::try_from(self.starts.len()).unwrap_or(u32::MAX)
    }

    /// Line `number` (1-based) without its `\n`.
    pub fn line(&self, number: u32) -> Option<&[u8]> {
        let index = usize::try_from(number).ok()?.checked_sub(1)?;
        let start = *self.starts.get(index)?;
        let end = self
            .starts
            .get(index + 1)
            .copied()
            .unwrap_or(self.text.len());
        let line = self.text.get(start..end)?;
        Some(line.strip_suffix(b"\n").unwrap_or(line))
    }
}

/// How far the user opened each gap. Gap `i` comes before hunk `i`; the
/// last gap follows the last hunk.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Expansion {
    /// `[below the previous hunk, above the next hunk]` per gap.
    gaps: Vec<[u32; 2]>,
    /// Every gap is open, however the hunks change.
    whole: bool,
}

impl Expansion {
    pub fn is_empty(&self) -> bool {
        !self.whole && self.gaps.iter().all(|g| *g == [0, 0])
    }

    /// The whole file is shown.
    pub fn is_whole(&self) -> bool {
        self.whole
    }

    pub fn expand(&mut self, gap: usize, how: Expand) {
        if self.gaps.len() <= gap {
            self.gaps.resize(gap + 1, [0, 0]);
        }
        if let Some(open) = self.gaps.get_mut(gap) {
            match how {
                Expand::Down => open[0] = open[0].saturating_add(EXPAND_STEP),
                Expand::Up => open[1] = open[1].saturating_add(EXPAND_STEP),
                Expand::All => *open = [u32::MAX, 0],
            }
        }
    }

    /// Opens every gap (`true`) or closes them all again.
    pub fn set_whole(&mut self, whole: bool) {
        self.gaps.clear();
        self.whole = whole;
    }

    fn get(&self, gap: usize) -> [u32; 2] {
        if self.whole {
            return [u32::MAX, 0];
        }
        self.gaps.get(gap).copied().unwrap_or([0, 0])
    }
}

/// A shown hunk header: its hunk and the range of the rows below it, up to
/// the next header (it grows as lines around it are expanded).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HeaderRow {
    pub hunk: usize,
    pub old_start: u32,
    pub old_count: u32,
    pub new_start: u32,
    pub new_count: u32,
}

impl HeaderRow {
    /// `@@ -a,b +c,d @@` with the original header's section text after it.
    pub fn text(&self, diff: &FileDiff) -> String {
        let original = diff
            .hunks
            .get(self.hunk)
            .and_then(|h| diff.line(h.line))
            .map(|l| String::from_utf8_lossy(l.text).into_owned())
            .unwrap_or_default();
        let section = original
            .strip_prefix("@@")
            .and_then(|rest| rest.split_once("@@"))
            .map_or("", |(_, section)| section);
        let range = |start: u32, count: u32| match count {
            1 => start.to_string(),
            _ => format!("{start},{count}"),
        };
        format!(
            "@@ -{} +{} @@{section}",
            range(self.old_start, self.old_count),
            range(self.new_start, self.new_count)
        )
    }
}

/// One row of a [`DiffLayout`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayoutRow {
    /// Unified: line `n` of the diff. Side by side: row `n` of its table.
    Diff(usize),
    /// A hunk header, whose expanders open gap `hunk`.
    Header(HeaderRow),
    /// An unchanged line outside the hunks, by its old and new numbers.
    Hidden { old: u32, new: u32 },
    /// After the last hunk, where more of the file follows (or may follow,
    /// until the old file is read).
    End,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Run {
    Diff { first: usize, count: usize },
    Header(usize),
    Hidden { old: u32, new: u32, count: u32 },
    End,
}

impl Run {
    fn len(&self) -> usize {
        match *self {
            Run::Diff { count, .. } => count,
            Run::Hidden { count, .. } => count as usize,
            Run::Header(_) | Run::End => 1,
        }
    }
}

/// Rows as runs, each with the row it starts at.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Runs {
    runs: Vec<(usize, Run)>,
    rows: usize,
}

impl Runs {
    fn push(&mut self, run: Run) {
        if run.len() > 0 {
            self.runs.push((self.rows, run));
            self.rows += run.len();
        }
    }

    fn row(&self, row: usize, headers: &[HeaderRow]) -> Option<LayoutRow> {
        if row >= self.rows {
            return None;
        }
        let at = self.runs.partition_point(|(start, _)| *start <= row);
        let (start, run) = *self.runs.get(at.checked_sub(1)?)?;
        let offset = row - start;
        Some(match run {
            Run::Diff { first, .. } => LayoutRow::Diff(first + offset),
            Run::Header(i) => LayoutRow::Header(*headers.get(i)?),
            Run::Hidden { old, new, .. } => {
                let offset = u32::try_from(offset).ok()?;
                LayoutRow::Hidden {
                    old: old + offset,
                    new: new + offset,
                }
            }
            Run::End => LayoutRow::End,
        })
    }
}

/// What a gap leaves hidden.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Gap {
    /// Lines still hidden; `None` after the last hunk while the old file's
    /// length is unknown.
    hidden: Option<u32>,
}

/// The rows of a diff view, unified and side by side. See the module docs.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DiffLayout {
    unified: Runs,
    split: Runs,
    headers: Vec<HeaderRow>,
    gaps: Vec<Gap>,
    max_line: u32,
}

/// First old (or new) line of a hunk, and the one after it. A hunk with no
/// lines on a side starts after the line its header names.
fn span(start: u32, count: u32) -> (u32, u32) {
    let first = if count == 0 { start + 1 } else { start };
    (first, first + count)
}

/// Start of a range in a hunk header: the line before it when it is empty.
fn header_start(first: u32, count: u32) -> u32 {
    if count == 0 {
        first.saturating_sub(1)
    } else {
        first
    }
}

impl DiffLayout {
    /// The rows of `diff` with `expansion`'s gaps open. Gaps stay closed
    /// until `old` (the diff's old side) is given.
    pub fn build(diff: &FileDiff, expansion: &Expansion, old: Option<&OldFile>) -> Self {
        let mut layout = Self {
            max_line: diff.max_line_number(),
            ..Self::default()
        };
        if diff.hunks.is_empty() || diff.content != DiffContent::Text {
            layout.unified.push(Run::Diff {
                first: 0,
                count: diff.line_count(),
            });
            layout.split.push(Run::Diff {
                first: 0,
                count: diff.split_row_count(),
            });
            return layout;
        }
        // Side-by-side rows of the hunk headers.
        let mut header_rows = Vec::with_capacity(diff.hunks.len());
        for row in 0..diff.split_row_count() {
            if let Some((Some(left), _)) = diff.split_row(row) {
                if diff.line(left).is_some_and(|l| l.kind == LineKind::Hunk) {
                    header_rows.push(row);
                }
            }
        }
        let opened = |gap: usize| match old {
            Some(_) => expansion.get(gap),
            None => [0, 0],
        };
        // The header counting the rows below it, if one is shown yet.
        let mut open: Option<usize> = None;
        let mut previous: Option<&Hunk> = None;
        for (index, hunk) in diff.hunks.iter().enumerate() {
            let (old_first, old_end) = span(hunk.old_start, hunk.old_count);
            let (new_first, new_end) = span(hunk.new_start, hunk.new_count);
            let start = previous.map_or(1, |p| span(p.old_start, p.old_count).1);
            let size = old_first.saturating_sub(start);
            let [down, up] = opened(index);
            let down = down.min(size);
            let up = up.min(size - down);
            let shift = i64::from(new_first) - i64::from(old_first);
            layout.hidden(start, shift, down, open);
            let hidden = size - down - up;
            layout.gaps.push(Gap {
                hidden: Some(hidden),
            });
            if hidden > 0 || size == 0 {
                layout.headers.push(HeaderRow {
                    hunk: index,
                    old_start: old_first.saturating_sub(up),
                    old_count: 0,
                    new_start: new_first.saturating_sub(up),
                    new_count: 0,
                });
                let header = layout.headers.len() - 1;
                layout.unified.push(Run::Header(header));
                layout.split.push(Run::Header(header));
                open = Some(header);
            }
            layout.hidden(old_first.saturating_sub(up), shift, up, open);
            let line_end = diff
                .hunks
                .get(index + 1)
                .map_or(diff.line_count(), |next| next.line);
            layout.unified.push(Run::Diff {
                first: hunk.line + 1,
                count: line_end.saturating_sub(hunk.line + 1),
            });
            let split_first = header_rows.get(index).map_or(0, |r| r + 1);
            let split_end = header_rows
                .get(index + 1)
                .copied()
                .unwrap_or(diff.split_row_count());
            layout.split.push(Run::Diff {
                first: split_first,
                count: split_end.saturating_sub(split_first),
            });
            layout.count(open, old_end - old_first, new_end - new_first);
            previous = Some(hunk);
        }
        // After the last hunk.
        let last = previous.map_or((1, 1), |h| {
            (
                span(h.old_start, h.old_count).1,
                span(h.new_start, h.new_count).1,
            )
        });
        let size = match old {
            Some(old) => Some((old.line_count() + 1).saturating_sub(last.0)),
            None if reaches_end(diff) => Some(0),
            None => None,
        };
        let down = size.map_or(0, |size| opened(diff.hunks.len())[0].min(size));
        layout.hidden(last.0, i64::from(last.1) - i64::from(last.0), down, open);
        let hidden = size.map(|size| size - down);
        layout.gaps.push(Gap { hidden });
        if hidden != Some(0) {
            layout.unified.push(Run::End);
            layout.split.push(Run::End);
        }
        // Header starts in git's form, once their counts are known.
        for header in &mut layout.headers {
            header.old_start = header_start(header.old_start, header.old_count);
            header.new_start = header_start(header.new_start, header.new_count);
        }
        layout
    }

    /// Adds `count` unchanged lines from old line `old` (new line `old +
    /// shift`), counted by header `open`.
    fn hidden(&mut self, old: u32, shift: i64, count: u32, open: Option<usize>) {
        if count == 0 {
            return;
        }
        let new = u32::try_from(i64::from(old) + shift).unwrap_or(0);
        let run = Run::Hidden { old, new, count };
        self.unified.push(run);
        self.split.push(run);
        self.count(open, count, count);
        self.max_line = self.max_line.max(old + count - 1).max(new + count - 1);
    }

    fn count(&mut self, open: Option<usize>, old: u32, new: u32) {
        if let Some(header) = open.and_then(|i| self.headers.get_mut(i)) {
            header.old_count += old;
            header.new_count += new;
        }
    }

    pub fn row_count(&self, split: bool) -> usize {
        self.runs(split).rows
    }

    pub fn row(&self, split: bool, row: usize) -> Option<LayoutRow> {
        self.runs(split).row(row, &self.headers)
    }

    /// Rows `start..start + count`, clamped to the layout.
    pub fn rows(
        &self,
        split: bool,
        start: usize,
        count: usize,
    ) -> impl Iterator<Item = LayoutRow> + '_ {
        let end = start.saturating_add(count).min(self.row_count(split));
        (start.min(end)..end).filter_map(move |row| self.row(split, row))
    }

    fn runs(&self, split: bool) -> &Runs {
        if split {
            &self.split
        } else {
            &self.unified
        }
    }

    /// Number of gaps: one before each hunk and one after the last.
    pub fn gap_count(&self) -> usize {
        self.gaps.len()
    }

    /// The expanders of gap `gap` (shown on hunk `gap`'s header, or on the
    /// end row for the last gap).
    pub fn expanders(&self, gap: usize) -> Expanders {
        let Some(info) = self.gaps.get(gap) else {
            return Expanders::None;
        };
        match info.hidden {
            Some(0) => Expanders::None,
            _ if gap + 1 == self.gaps.len() => Expanders::Down,
            _ if gap == 0 => Expanders::Up,
            Some(hidden) if hidden <= EXPAND_STEP => Expanders::All,
            _ => Expanders::Both,
        }
    }

    /// Some lines of the file are not shown (or may not be).
    pub fn has_hidden(&self) -> bool {
        self.gaps.iter().any(|g| g.hidden != Some(0))
    }

    /// Largest line number shown, for sizing the number gutter.
    pub fn max_line_number(&self) -> u32 {
        self.max_line
    }
}

/// Whether the last hunk ends at the end of the old file: it ends in fewer
/// than [`CONTEXT_LINES`] context lines, or at a missing final newline.
fn reaches_end(diff: &FileDiff) -> bool {
    let lines = diff.line_count();
    let mut context = 0;
    for index in (0..lines).rev() {
        match diff.line(index) {
            Some(line) if line.kind == LineKind::Context => {
                if line.no_newline {
                    return true;
                }
                context += 1;
            }
            _ => break,
        }
    }
    context < CONTEXT_LINES
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::parse_diff;

    /// Old file: lines `l1`..`l40`. New file: `l5` changed, `l30` changed.
    const DIFF: &[u8] = b"diff --git a/f b/f
index 1111111..2222222 100644
--- a/f
+++ b/f
@@ -2,7 +2,7 @@ fn top
 l2
 l3
 l4
-l5
+L5
 l6
 l7
 l8
@@ -27,7 +27,7 @@
 l27
 l28
 l29
-l30
+L30
 l31
 l32
 l33
";

    fn old() -> OldFile {
        let text: String = (1..=40).map(|n| format!("l{n}\n")).collect();
        OldFile::new("1111111", text.into_bytes())
    }

    fn describe(diff: &FileDiff, layout: &DiffLayout, split: bool) -> Vec<String> {
        layout
            .rows(split, 0, usize::MAX)
            .map(|row| match row {
                LayoutRow::Diff(n) if !split => {
                    String::from_utf8_lossy(diff.line(n).map(|l| l.text).unwrap_or_default())
                        .into_owned()
                }
                LayoutRow::Diff(n) => format!("row {n}"),
                LayoutRow::Header(h) => h.text(diff),
                LayoutRow::Hidden { old, new } => format!("~{old}/{new}"),
                LayoutRow::End => "end".to_owned(),
            })
            .collect()
    }

    #[test]
    fn closed_layout_is_the_diff_plus_an_end_row() {
        let diff = parse_diff(DIFF).unwrap();
        let layout = DiffLayout::build(&diff, &Expansion::default(), None);
        let rows = describe(&diff, &layout, false);
        assert_eq!(rows.len(), diff.line_count() + 1);
        assert_eq!(rows[0], "@@ -2,7 +2,7 @@ fn top");
        assert_eq!(rows[9], "@@ -27,7 +27,7 @@");
        assert_eq!(rows.last().unwrap(), "end");
        assert_eq!(layout.expanders(0), Expanders::Up);
        // l9..l26: one click opens it all.
        assert_eq!(layout.expanders(1), Expanders::All);
        assert_eq!(layout.expanders(2), Expanders::Down);
        assert_eq!(layout.max_line_number(), diff.max_line_number());
    }

    #[test]
    fn opens_gaps_from_the_old_file() {
        let diff = parse_diff(DIFF).unwrap();
        let old = old();
        let mut expansion = Expansion::default();
        expansion.expand(0, Expand::Up);
        expansion.expand(1, Expand::Down);
        let layout = DiffLayout::build(&diff, &expansion, Some(&old));
        let rows = describe(&diff, &layout, false);
        // Gap 0 (one line) opens fully, so its header goes.
        assert_eq!(rows[0], "~1/1");
        assert_eq!(rows[1], "l2");
        // Gap 1 (l9..l26, 18 lines) opens fully downwards too, so the second
        // header goes as well.
        assert_eq!(rows[9], "~9/9");
        assert_eq!(rows[26], "~26/26");
        assert_eq!(rows[27], "l27");
        assert!(!rows.iter().any(|r| r.starts_with("@@")));
        // Seven lines after the last hunk, behind the end row.
        assert_eq!(rows.last().unwrap(), "end");
        assert_eq!(layout.expanders(2), Expanders::Down);
        assert_eq!(layout.gap_count(), 3);
    }

    #[test]
    fn partly_open_gap_keeps_its_header_with_the_range_recounted() {
        let text: String = (1..=80).map(|n| format!("l{n}\n")).collect();
        let old = OldFile::new("1", text.into_bytes());
        let diff = parse_diff(
            b"diff --git a/f b/f
--- a/f
+++ b/f
@@ -2,3 +2,3 @@
 l2
-l3
+L3
 l4
@@ -60,3 +60,4 @@ section
 l60
+new
 l61
 l62
",
        )
        .unwrap();
        let mut expansion = Expansion::default();
        expansion.expand(1, Expand::Up);
        let layout = DiffLayout::build(&diff, &expansion, Some(&old));
        let rows = describe(&diff, &layout, false);
        // l5..l59 is 55 lines: 20 above the second hunk open.
        let header = rows.iter().position(|r| r.contains("section")).unwrap();
        assert_eq!(rows[header], "@@ -40,23 +40,24 @@ section");
        assert_eq!(rows[header + 1], "~40/40");
        assert_eq!(rows[header + 20], "~59/59");
        assert_eq!(rows[header + 21], "l60");
        assert_eq!(layout.expanders(1), Expanders::Both);
        // The rest of the gap (35 lines) opens in two steps then goes away.
        expansion.expand(1, Expand::Down);
        let layout = DiffLayout::build(&diff, &expansion, Some(&old));
        assert_eq!(layout.expanders(1), Expanders::All);
        expansion.expand(1, Expand::All);
        let layout = DiffLayout::build(&diff, &expansion, Some(&old));
        assert_eq!(layout.expanders(1), Expanders::None);
        let rows = describe(&diff, &layout, false);
        assert_eq!(rows.iter().filter(|r| r.starts_with("@@")).count(), 1);
        // The end: l63..l80 below, new numbers one further.
        let mut whole = Expansion::default();
        whole.set_whole(true);
        let layout = DiffLayout::build(&diff, &whole, Some(&old));
        let rows = describe(&diff, &layout, false);
        assert_eq!(rows.last().unwrap(), "~80/81");
        // Every old line once, plus the two added lines.
        assert_eq!(rows.len(), 82);
        assert!(!layout.has_hidden());
        assert_eq!(layout.max_line_number(), 81);
        assert_eq!(rows[0], "~1/1");
    }

    #[test]
    fn split_rows_follow_the_same_runs() {
        let diff = parse_diff(DIFF).unwrap();
        let old = old();
        let mut whole = Expansion::default();
        whole.set_whole(true);
        let layout = DiffLayout::build(&diff, &whole, Some(&old));
        let rows = describe(&diff, &layout, true);
        assert_eq!(rows[0], "~1/1");
        // Hunk 1's rows skip its header row (row 0).
        assert_eq!(rows[1], "row 1");
        assert_eq!(rows.last().unwrap(), "~40/40");
        assert_eq!(layout.row_count(true), 40);
    }

    #[test]
    fn last_hunk_short_of_context_ends_the_file() {
        let diff = parse_diff(
            b"diff --git a/f b/f
--- a/f
+++ b/f
@@ -1,2 +1,2 @@
 a
-b
+B
",
        )
        .unwrap();
        let layout = DiffLayout::build(&diff, &Expansion::default(), None);
        assert!(!layout.has_hidden());
        assert_eq!(layout.row_count(false), diff.line_count());
    }

    #[test]
    fn old_file_lines() {
        let old = OldFile::new("x", b"a\r\nb\n\nlast".to_vec());
        assert_eq!(old.line_count(), 4);
        assert_eq!(old.line(1), Some(&b"a\r"[..]));
        assert_eq!(old.line(3), Some(&b""[..]));
        assert_eq!(old.line(4), Some(&b"last"[..]));
        assert_eq!(old.line(5), None);
        assert_eq!(old.line(0), None);
        assert_eq!(OldFile::new("e", Vec::new()).line_count(), 0);
    }
}
