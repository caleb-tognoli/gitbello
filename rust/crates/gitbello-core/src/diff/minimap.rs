//! The diff minimap (PLAN M7.6): rows of a diff or of the resolver drawn as
//! small blocks, one per character, on their row's background, rendered
//! here into RGBA tiles so the UI only wraps them in textures. An overview
//! gives the marks of the whole diff in a few buckets, for the strip beside
//! the minimap; a [`StripMap`] places rows in the whole file there, so the
//! lines a collapsed gap hides take their room.

use crate::changes::PickState;
use crate::highlight::{DiffStates, LineState, LineStates, Syntax, TokenKind};
use crate::merge::{ConflictFile, ConflictLayout, ConflictRow, ConflictRowKind};

use std::ops::Range;

use super::{changed_ranges, display_text, DiffLayout, FileDiff, LayoutRow, LineKind, OldFile};

/// What a minimap line shows, and so its background.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mark {
    Context,
    /// A hunk header, the end row or a conflict block's header.
    Header,
    Added,
    Removed,
    Ours,
    Theirs,
    Base,
    /// A line a block choice wrote this session (the resolver).
    Resolved,
}

impl Mark {
    /// Index into [`MinimapPalette::rows`].
    pub fn index(self) -> usize {
        match self {
            Self::Context => 0,
            Self::Header => 1,
            Self::Added => 2,
            Self::Removed => 3,
            Self::Ours => 4,
            Self::Theirs => 5,
            Self::Base => 6,
            Self::Resolved => 7,
        }
    }

    fn is_conflict(self) -> bool {
        matches!(self, Self::Ours | Self::Theirs | Self::Base)
    }

    fn is_change(self) -> bool {
        matches!(self, Self::Added | Self::Removed) || self.is_conflict()
    }
}

pub const MARK_COUNT: usize = 8;

/// One side of a minimap row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MiniLine<'a> {
    pub mark: Mark,
    /// Raw line text (empty for headers).
    pub text: &'a [u8],
    /// A changed line left out of the commit.
    pub left_out: bool,
    /// The state the line starts in (see [`crate::highlight::LineStates`]).
    pub state: LineState,
}

/// A minimap row: `left` only when unified; side by side, either side may
/// be empty.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MiniRow<'a> {
    pub left: Option<MiniLine<'a>>,
    pub right: Option<MiniLine<'a>>,
    /// The row hides lines of the file after it (a collapsed gap).
    pub divider: bool,
}

/// Rows of what the diff view shows, unified or side by side.
pub trait MinimapSource {
    fn row_count(&self) -> usize;
    fn row(&self, row: usize) -> MiniRow<'_>;
    fn split(&self) -> bool;
    /// How the rows' text is coloured.
    fn syntax(&self) -> Syntax;
    /// The changed characters `[start, end)` of each side of a row against
    /// the line it pairs with (as `changed_ranges` finds them). Apart from
    /// `row` because only tiles draw them.
    fn words(&self, _row: usize) -> [Option<(usize, usize)>; 2] {
        [None, None]
    }
    /// The rows that open a collapsed gap, top down, with the lines it
    /// hides; empty when nothing is hidden or the file's length is unknown.
    fn gaps(&self) -> Vec<StripGap> {
        Vec::new()
    }
}

/// A row that opens a collapsed gap ([`MinimapSource::gaps`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StripGap {
    pub row: usize,
    /// The gap's index, for expanding it.
    pub gap: usize,
    pub hidden: u32,
}

/// The rows of a file diff with its open gaps (see [`DiffLayout`]).
pub struct DiffMinimap<'a> {
    diff: &'a FileDiff,
    layout: &'a DiffLayout,
    old: Option<&'a OldFile>,
    /// Line picks of the commit selection, by diff line; empty when lines
    /// cannot be picked.
    picks: &'a [PickState],
    split: bool,
    syntax: Syntax,
    states: &'a DiffStates,
}

impl<'a> DiffMinimap<'a> {
    pub fn new(
        diff: &'a FileDiff,
        layout: &'a DiffLayout,
        old: Option<&'a OldFile>,
        picks: &'a [PickState],
        split: bool,
        syntax: Syntax,
        states: &'a DiffStates,
    ) -> Self {
        Self {
            diff,
            layout,
            old,
            picks,
            split,
            syntax,
            states,
        }
    }

    fn line(&self, index: usize) -> Option<MiniLine<'a>> {
        let line = self.diff.line(index)?;
        let mark = match line.kind {
            LineKind::Hunk => Mark::Header,
            LineKind::Context => Mark::Context,
            LineKind::Added => Mark::Added,
            LineKind::Removed => Mark::Removed,
        };
        let changed = matches!(mark, Mark::Added | Mark::Removed);
        Some(MiniLine {
            mark,
            text: if mark == Mark::Header { b"" } else { line.text },
            left_out: changed && self.picks.get(index) == Some(&PickState::None),
            state: self
                .states
                .before(mark == Mark::Removed, line.old_line, line.new_line),
        })
    }

    /// The changed characters of diff line `index` against its partner.
    fn word(&self, index: usize) -> Option<(usize, usize)> {
        let line = self.diff.line(index)?;
        let other = self.diff.line(self.diff.partner(index)?)?;
        let (this, other) = (display_text(line.text), display_text(other.text));
        match line.kind {
            LineKind::Removed => changed_ranges(&this, &other).map(|(old, _)| old),
            LineKind::Added => changed_ranges(&other, &this).map(|(_, new)| new),
            _ => None,
        }
    }

    fn both(&self, line: MiniLine<'a>, divider: bool) -> MiniRow<'a> {
        MiniRow {
            left: Some(line),
            right: self.split.then_some(line),
            divider,
        }
    }
}

const HEADER: MiniLine<'static> = MiniLine {
    mark: Mark::Header,
    text: b"",
    left_out: false,
    state: LineState::START,
};

impl MinimapSource for DiffMinimap<'_> {
    fn row_count(&self) -> usize {
        self.layout.row_count(self.split)
    }

    fn row(&self, row: usize) -> MiniRow<'_> {
        match self.layout.row(self.split, row) {
            None => MiniRow::default(),
            Some(LayoutRow::Diff(n)) if self.split => {
                let (left, right) = self.diff.split_row(n).unwrap_or((None, None));
                MiniRow {
                    left: left.and_then(|i| self.line(i)),
                    right: right.and_then(|i| self.line(i)),
                    divider: false,
                }
            }
            Some(LayoutRow::Diff(index)) => MiniRow {
                left: self.line(index),
                ..MiniRow::default()
            },
            Some(LayoutRow::Header(header)) => {
                // A header opens the gap before its hunk.
                let hides = self.layout.hidden_lines(header.hunk) != Some(0);
                self.both(HEADER, hides)
            }
            Some(LayoutRow::Hidden { old, new }) => {
                let text = self.old.and_then(|f| f.line(old)).unwrap_or_default();
                self.both(
                    MiniLine {
                        mark: Mark::Context,
                        text,
                        left_out: false,
                        state: self.states.before(false, Some(old), Some(new)),
                    },
                    false,
                )
            }
            Some(LayoutRow::End) => self.both(HEADER, true),
            // A marker row is blank; it does not end a change block.
            Some(LayoutRow::Marker(_)) => MiniRow::default(),
        }
    }

    fn split(&self) -> bool {
        self.split
    }

    fn syntax(&self) -> Syntax {
        self.syntax
    }

    fn words(&self, row: usize) -> [Option<(usize, usize)>; 2] {
        match self.layout.row(self.split, row) {
            Some(LayoutRow::Diff(n)) if self.split => {
                let (left, right) = self.diff.split_row(n).unwrap_or((None, None));
                [
                    left.and_then(|i| self.word(i)),
                    right.and_then(|i| self.word(i)),
                ]
            }
            Some(LayoutRow::Diff(index)) => [self.word(index), None],
            _ => [None, None],
        }
    }

    fn gaps(&self) -> Vec<StripGap> {
        if !self.layout.end_known() {
            return Vec::new();
        }
        self.layout
            .gap_rows(self.split)
            .filter_map(|(row, gap)| {
                let hidden = self.layout.hidden_lines(gap)?;
                (hidden > 0).then_some(StripGap { row, gap, hidden })
            })
            .collect()
    }
}

/// The rows of a conflicted file in the resolver (see [`ConflictLayout`]).
pub struct ConflictMinimap<'a> {
    file: &'a ConflictFile,
    layout: &'a ConflictLayout,
    /// Lines of the file that block choices wrote this session.
    resolved: &'a [Range<usize>],
    split: bool,
    syntax: Syntax,
    states: Option<&'a LineStates>,
}

impl<'a> ConflictMinimap<'a> {
    pub fn new(
        file: &'a ConflictFile,
        layout: &'a ConflictLayout,
        resolved: &'a [Range<usize>],
        split: bool,
        syntax: Syntax,
        states: Option<&'a LineStates>,
    ) -> Self {
        Self {
            file,
            layout,
            resolved,
            split,
            syntax,
            states,
        }
    }

    fn line(&self, row: Option<&ConflictRow>) -> Option<MiniLine<'a>> {
        let row = row?;
        let resolved = |line: Option<usize>| {
            line.is_some_and(|l| self.resolved.iter().any(|r| r.contains(&l)))
        };
        let mark = match row.kind {
            ConflictRowKind::Context if resolved(row.line) => Mark::Resolved,
            ConflictRowKind::Context => Mark::Context,
            ConflictRowKind::Header => Mark::Header,
            ConflictRowKind::Ours => Mark::Ours,
            ConflictRowKind::Base => Mark::Base,
            ConflictRowKind::Theirs => Mark::Theirs,
        };
        let text = row.line.and_then(|l| self.file.line(l)).unwrap_or_default();
        let state = match (self.states, row.line) {
            (Some(states), Some(line)) => states.before(line),
            _ => LineState::START,
        };
        Some(MiniLine {
            mark,
            text: if mark == Mark::Header { b"" } else { text },
            left_out: false,
            state,
        })
    }
}

impl MinimapSource for ConflictMinimap<'_> {
    fn row_count(&self) -> usize {
        if self.split {
            self.layout.split.len()
        } else {
            self.layout.unified.len()
        }
    }

    fn row(&self, row: usize) -> MiniRow<'_> {
        if self.split {
            let Some((left, right)) = self.layout.split.get(row) else {
                return MiniRow::default();
            };
            MiniRow {
                left: self.line(left.as_ref()),
                right: self.line(right.as_ref()),
                divider: false,
            }
        } else {
            MiniRow {
                left: self.line(self.layout.unified.get(row)),
                ..MiniRow::default()
            }
        }
    }

    fn split(&self) -> bool {
        self.split
    }

    fn syntax(&self) -> Syntax {
        self.syntax
    }
}

/// A colour as red, green, blue and alpha bytes (not premultiplied).
pub type Rgba = [u8; 4];

/// The minimap's colours.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MinimapPalette {
    /// Row backgrounds by [`Mark::index`].
    pub rows: [Rgba; MARK_COUNT],
    /// Text without a syntax colour.
    pub text: Rgba,
    /// The dashes of a collapsed gap.
    pub divider: Rgba,
    /// Drawn over lines left out of the commit.
    pub veil: Rgba,
    /// Drawn over the changed words of an added and a removed line.
    pub added_word: Rgba,
    pub removed_word: Rgba,
    /// Text by `TokenKind::id` (a kind drawn as plain text has `text`).
    pub syntax: [Rgba; TokenKind::COUNT],
}

/// Colours of [`MinimapPalette::from_colors`] before the syntax colours.
const FIXED_COLORS: usize = MARK_COUNT + 5;

/// Colours [`MinimapPalette::from_colors`] takes: the row backgrounds, the
/// text, the divider, the veil, the added and removed words, then one per
/// token kind in id order.
pub const PALETTE_LEN: usize = FIXED_COLORS + TokenKind::COUNT;

impl MinimapPalette {
    /// The palette from [`PALETTE_LEN`] colours in field order, or `None`
    /// when some are missing.
    pub fn from_colors(colors: &[Rgba]) -> Option<Self> {
        if colors.len() < PALETTE_LEN {
            return None;
        }
        let mut rows = [[0; 4]; MARK_COUNT];
        rows.copy_from_slice(&colors[..MARK_COUNT]);
        let mut syntax = [[0; 4]; TokenKind::COUNT];
        syntax.copy_from_slice(&colors[FIXED_COLORS..PALETTE_LEN]);
        Some(Self {
            rows,
            text: colors[MARK_COUNT],
            divider: colors[MARK_COUNT + 1],
            veil: colors[MARK_COUNT + 2],
            added_word: colors[MARK_COUNT + 3],
            removed_word: colors[MARK_COUNT + 4],
            syntax,
        })
    }
}

/// How a tile is drawn, in device pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MinimapStyle {
    /// Tile width.
    pub columns: usize,
    /// Height of a row.
    pub row_px: usize,
    /// Width of a character's block.
    pub char_px: usize,
    pub palette: MinimapPalette,
}

/// Rows `first..first + rows` of `source` as RGBA bytes, `style.columns`
/// wide and `rows * style.row_px` high; rows past the end stay transparent.
/// Side by side, the old side fills the left half and the new side the
/// right half, a block's width apart.
pub fn render_tile(
    source: &dyn MinimapSource,
    first: usize,
    rows: usize,
    style: &MinimapStyle,
) -> Vec<u8> {
    let width = style.columns;
    let row_px = style.row_px.max(1);
    let char_px = style.char_px.max(1);
    let mut canvas = Canvas {
        pixels: vec![0; width * rows * row_px * 4],
        width,
    };
    let half = width.saturating_sub(char_px) / 2;
    let end = first.saturating_add(rows).min(source.row_count());
    for row in first..end {
        let top = (row - first) * row_px;
        let mini = source.row(row);
        let [left_word, right_word] = source.words(row);
        let sides = if source.split() {
            [
                (mini.left, left_word, 0, half),
                (mini.right, right_word, width - half, width),
            ]
        } else {
            [(mini.left, left_word, 0, width), (None, None, 0, 0)]
        };
        for (line, word, left, right) in sides {
            if let Some(line) = line {
                draw_line(
                    &mut canvas,
                    &line,
                    word,
                    &source.syntax(),
                    (left, right),
                    top,
                    row_px,
                    char_px,
                    &style.palette,
                );
            }
        }
        // Headers on both sides make one band across the gap.
        if source.split()
            && matches!((mini.left, mini.right), (Some(l), Some(r)) if l.mark == Mark::Header && r.mark == Mark::Header)
        {
            canvas.fill(
                half,
                width - half,
                top,
                top + row_px,
                style.palette.rows[Mark::Header.index()],
            );
        }
        if mini.divider {
            let dash = 3 * char_px;
            let mut x = 0;
            while x < width {
                canvas.fill(
                    x,
                    (x + dash).min(width),
                    top,
                    top + 1,
                    style.palette.divider,
                );
                x += dash + 2 * char_px;
            }
        }
    }
    canvas.pixels
}

#[allow(clippy::too_many_arguments)]
fn draw_line(
    canvas: &mut Canvas,
    line: &MiniLine<'_>,
    word: Option<(usize, usize)>,
    syntax: &Syntax,
    (left, right): (usize, usize),
    top: usize,
    row_px: usize,
    char_px: usize,
    palette: &MinimapPalette,
) {
    let bottom = top + row_px;
    canvas.fill(left, right, top, bottom, palette.rows[line.mark.index()]);
    if let Some((start, end)) = word {
        let color = if line.mark == Mark::Removed {
            palette.removed_word
        } else {
            palette.added_word
        };
        let from = (left + start * char_px).min(right);
        let to = (left + end * char_px).min(right);
        canvas.fill(from, to, top, bottom, color);
    }
    if !line.text.is_empty() {
        let text = display_text(line.text);
        let tokens = syntax.highlight_line_from(line.text, line.state);
        let block_px = (row_px - row_px / 3).max(1);
        let mut token = 0;
        for (column, ch) in text.chars().enumerate() {
            let x = left + column * char_px;
            if x >= right {
                break;
            }
            if ch.is_whitespace() {
                continue;
            }
            while token < tokens.len() && tokens[token].end <= column {
                token += 1;
            }
            let color = match tokens.get(token) {
                Some(t) if t.start <= column => palette
                    .syntax
                    .get(usize::try_from(t.kind.id()).unwrap_or(0))
                    .copied()
                    .unwrap_or(palette.text),
                _ => palette.text,
            };
            canvas.fill(x, (x + char_px).min(right), top, top + block_px, color);
        }
    }
    if line.left_out {
        canvas.fill(left, right, top, bottom, palette.veil);
    }
}

struct Canvas {
    pixels: Vec<u8>,
    width: usize,
}

impl Canvas {
    /// Blends `color` over the pixels `x0..x1` × `y0..y1`.
    fn fill(&mut self, x0: usize, x1: usize, y0: usize, y1: usize, color: Rgba) {
        if color[3] == 0 {
            return;
        }
        let height = self.pixels.len() / (self.width * 4).max(1);
        for y in y0..y1.min(height) {
            let row = y * self.width;
            for x in x0..x1.min(self.width) {
                let at = (row + x) * 4;
                blend(&mut self.pixels[at..at + 4], color);
            }
        }
    }
}

/// Source-over blending of non-premultiplied colours.
fn blend(dst: &mut [u8], src: Rgba) {
    let sa = u32::from(src[3]);
    if sa == 255 {
        dst.copy_from_slice(&src);
        return;
    }
    let da = u32::from(dst[3]) * (255 - sa) / 255;
    let out_a = sa + da;
    if out_a == 0 {
        return;
    }
    for (d, s) in dst[..3].iter_mut().zip(&src[..3]) {
        let value = (u32::from(*s) * sa + u32::from(*d) * da) / out_a;
        *d = u8::try_from(value).unwrap_or(u8::MAX);
    }
    dst[3] = u8::try_from(out_a).unwrap_or(u8::MAX);
}

/// Bucket flags of [`overview`].
pub const OVERVIEW_ADDED: u8 = 1;
pub const OVERVIEW_REMOVED: u8 = 2;
pub const OVERVIEW_CONFLICT: u8 = 4;
pub const OVERVIEW_LEFT_OUT: u8 = 8;
pub const OVERVIEW_RESOLVED: u8 = 16;

/// Where rows sit on the strip: in rows shown, or in the whole file, where
/// the lines a collapsed gap hides take room just above the row that opens
/// it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StripMap {
    rows: usize,
    gaps: Vec<StripGap>,
    total: u64,
}

impl StripMap {
    pub fn new(source: &dyn MinimapSource, whole_file: bool) -> Self {
        let rows = source.row_count();
        let gaps = if whole_file {
            source.gaps()
        } else {
            Vec::new()
        };
        let hidden: u64 = gaps.iter().map(|g| u64::from(g.hidden)).sum();
        Self {
            rows,
            gaps,
            total: rows as u64 + hidden,
        }
    }

    /// The strip's length in lines (rows plus hidden lines).
    pub fn total(&self) -> u64 {
        self.total
    }

    /// Lines above (fractional) row `row`, its gap included when it opens
    /// one.
    pub fn units(&self, row: f64) -> f64 {
        let hidden: u64 = self
            .gaps
            .iter()
            .take_while(|g| g.row as f64 <= row)
            .map(|g| u64::from(g.hidden))
            .sum();
        row + hidden as f64
    }

    /// Where row `row` starts on the strip, `0..=1`.
    pub fn position(&self, row: f64) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        (self.units(row) / self.total as f64).clamp(0.0, 1.0)
    }

    /// The (fractional) row at `fraction` of the strip, and the gap when it
    /// falls in one (then the row is the one that opens it).
    pub fn target(&self, fraction: f64) -> (f64, Option<usize>) {
        let at = fraction.clamp(0.0, 1.0) * self.total as f64;
        let mut units = 0.0;
        let mut row = 0;
        for gap in &self.gaps {
            let plain = (gap.row - row) as f64;
            if at < units + plain {
                return (row as f64 + (at - units), None);
            }
            units += plain;
            if at < units + f64::from(gap.hidden) {
                return (gap.row as f64, Some(gap.gap));
            }
            units += f64::from(gap.hidden);
            row = gap.row;
        }
        ((row as f64 + (at - units)).min(self.rows as f64), None)
    }
}

/// Marks of all of `source`'s rows in `buckets` equal slices from the top
/// of the strip (`whole_file` as in [`StripMap`]), one byte of `OVERVIEW_*`
/// flags each. Fewer rows than buckets spread each row over the buckets it
/// covers.
pub fn overview(source: &dyn MinimapSource, buckets: usize, whole_file: bool) -> Vec<u8> {
    let mut out = vec![0; buckets];
    let map = StripMap::new(source, whole_file);
    let total = usize::try_from(map.total()).unwrap_or(usize::MAX);
    if total == 0 || buckets == 0 {
        return out;
    }
    let mut gaps = map.gaps.iter().peekable();
    let mut hidden = 0;
    for row in 0..source.row_count() {
        while let Some(gap) = gaps.next_if(|g| g.row <= row) {
            hidden += gap.hidden as usize;
        }
        let mini = source.row(row);
        let mut flags = 0;
        for line in [mini.left, mini.right].into_iter().flatten() {
            flags |= match line.mark {
                Mark::Added => OVERVIEW_ADDED,
                Mark::Removed => OVERVIEW_REMOVED,
                Mark::Resolved => OVERVIEW_RESOLVED,
                mark if mark.is_conflict() => OVERVIEW_CONFLICT,
                _ => 0,
            };
            if line.left_out {
                flags |= OVERVIEW_LEFT_OUT;
            }
        }
        if flags == 0 {
            continue;
        }
        let units = row + hidden;
        let from = (units * buckets / total).min(buckets - 1);
        let to = ((units + 1) * buckets).div_ceil(total).max(from + 1);
        for bucket in &mut out[from..to.min(buckets)] {
            *bucket |= flags;
        }
    }
    out
}

/// The first row of the change block (a run of rows with an added, removed
/// or conflict line) that starts after `from` (`forward`) or before it,
/// wrapping past either end. `None` without changes.
pub fn change_row(source: &dyn MinimapSource, from: usize, forward: bool) -> Option<usize> {
    let mut first = None;
    let mut last = None;
    let mut found = None;
    let mut previous = false;
    for row in 0..source.row_count() {
        let mini = source.row(row);
        // A row with neither side (a marker row) does not split a block.
        if mini.left.is_none() && mini.right.is_none() {
            continue;
        }
        let changed = [mini.left, mini.right]
            .into_iter()
            .flatten()
            .any(|line| line.mark.is_change());
        if changed && !previous {
            first.get_or_insert(row);
            last = Some(row);
            if forward && row > from {
                found = Some(row);
                break;
            }
            if !forward && row < from {
                found = Some(row);
            }
        }
        previous = changed;
    }
    found.or(if forward { first } else { last })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::{parse_diff, Expansion};
    use crate::merge::ConflictKind;

    static NO_STATES: DiffStates = DiffStates {
        old: None,
        new: None,
    };

    const DIFF: &[u8] = b"diff --git a/a.rs b/a.rs
index 1111111..2222222 100644
--- a/a.rs
+++ b/a.rs
@@ -3,3 +3,3 @@
 let a = 1;
-let b = 2;
+let b = 3;
 let c = 4;
";

    const CONFLICT: &[u8] = b"one
<<<<<<< ours
two ours
=======
two theirs
>>>>>>> theirs
three
";

    fn rust() -> Syntax {
        Syntax::new(crate::highlight::Language::by_id("rust"), &[])
    }

    fn palette() -> MinimapPalette {
        let mut colors = vec![[0, 0, 0, 0]; PALETTE_LEN];
        colors[Mark::Header.index()] = [10, 10, 10, 255];
        colors[Mark::Added.index()] = [0, 200, 0, 255];
        colors[Mark::Removed.index()] = [200, 0, 0, 255];
        colors[Mark::Ours.index()] = [0, 0, 200, 255];
        colors[Mark::Theirs.index()] = [200, 0, 200, 255];
        colors[MARK_COUNT] = [255, 255, 255, 255];
        colors[MARK_COUNT + 1] = [128, 128, 128, 255];
        colors[MARK_COUNT + 2] = [0, 0, 0, 128];
        colors[MARK_COUNT + 3] = [0, 255, 0, 255]; // added words
        colors[MARK_COUNT + 4] = [255, 0, 0, 255]; // removed words
        colors[FIXED_COLORS] = [255, 255, 0, 255]; // keywords
        MinimapPalette::from_colors(&colors).unwrap()
    }

    fn style(columns: usize) -> MinimapStyle {
        MinimapStyle {
            columns,
            row_px: 2,
            char_px: 1,
            palette: palette(),
        }
    }

    fn pixel(tile: &[u8], width: usize, x: usize, y: usize) -> Rgba {
        let at = (y * width + x) * 4;
        [tile[at], tile[at + 1], tile[at + 2], tile[at + 3]]
    }

    fn marks(source: &dyn MinimapSource) -> Vec<(Option<Mark>, Option<Mark>, bool)> {
        (0..source.row_count())
            .map(|r| {
                let row = source.row(r);
                (
                    row.left.map(|l| l.mark),
                    row.right.map(|l| l.mark),
                    row.divider,
                )
            })
            .collect()
    }

    #[test]
    fn diff_rows_mark_headers_changes_and_gaps() {
        let diff = parse_diff(DIFF).unwrap();
        let layout = DiffLayout::build(&diff, &Expansion::default(), None);
        let source = DiffMinimap::new(
            &diff,
            &layout,
            None,
            &[],
            false,
            Syntax::plain(),
            &NO_STATES,
        );
        use Mark::*;
        assert_eq!(
            marks(&source),
            vec![
                (Some(Header), None, true),
                (Some(Context), None, false),
                (Some(Removed), None, false),
                (Some(Added), None, false),
                (Some(Context), None, false),
            ]
        );
        let split = DiffMinimap::new(&diff, &layout, None, &[], true, Syntax::plain(), &NO_STATES);
        assert_eq!(
            marks(&split),
            vec![
                (Some(Header), Some(Header), true),
                (Some(Context), Some(Context), false),
                (Some(Removed), Some(Added), false),
                (Some(Context), Some(Context), false),
            ]
        );
    }

    #[test]
    fn left_out_lines_follow_the_picks() {
        let diff = parse_diff(DIFF).unwrap();
        let layout = DiffLayout::build(&diff, &Expansion::default(), None);
        let mut picks = vec![PickState::All; diff.line_count()];
        let removed = (0..diff.line_count())
            .find(|&i| diff.line(i).unwrap().kind == LineKind::Removed)
            .unwrap();
        picks[removed] = PickState::None;
        let source = DiffMinimap::new(
            &diff,
            &layout,
            None,
            &picks,
            false,
            Syntax::plain(),
            &NO_STATES,
        );
        let left_out: Vec<bool> = (0..source.row_count())
            .map(|r| source.row(r).left.is_some_and(|l| l.left_out))
            .collect();
        assert_eq!(left_out, vec![false, false, true, false, false]);
        assert_eq!(
            overview(&source, 5, false),
            vec![
                0,
                0,
                OVERVIEW_REMOVED | OVERVIEW_LEFT_OUT,
                OVERVIEW_ADDED,
                0
            ]
        );
    }

    #[test]
    fn conflict_rows_use_the_sides() {
        let file = ConflictFile::new(
            "f.txt".into(),
            ConflictKind::Content,
            Some(CONFLICT.to_vec()),
        );
        let layout = ConflictLayout::build(&file, false);
        let source = ConflictMinimap::new(&file, &layout, &[], false, Syntax::plain(), None);
        use Mark::*;
        let unified: Vec<Option<Mark>> = marks(&source).into_iter().map(|m| m.0).collect();
        assert_eq!(
            unified,
            vec![
                Some(Context),
                Some(Header),
                Some(Ours),
                Some(Theirs),
                Some(Context)
            ]
        );
        assert_eq!(overview(&source, 1, false), vec![OVERVIEW_CONFLICT]);
        let split = ConflictMinimap::new(&file, &layout, &[], true, Syntax::plain(), None);
        assert!(marks(&split).contains(&(Some(Ours), Some(Theirs), false)));
    }

    #[test]
    fn tiles_draw_backgrounds_blocks_and_syntax() {
        let diff = parse_diff(DIFF).unwrap();
        let layout = DiffLayout::build(&diff, &Expansion::default(), None);
        let source = DiffMinimap::new(&diff, &layout, None, &[], false, rust(), &NO_STATES);
        let width = 20;
        let tile = render_tile(&source, 0, 8, &style(width));
        assert_eq!(
            tile.len(),
            width * 8 * 2 * 4,
            "rows past the end are kept, transparent"
        );
        // Row 0, the header: its background, and the gap's dashes on top.
        assert_eq!(pixel(&tile, width, 0, 0), [128, 128, 128, 255]);
        assert_eq!(pixel(&tile, width, 3, 0), [10, 10, 10, 255]);
        assert_eq!(pixel(&tile, width, 3, 1), [10, 10, 10, 255]);
        // Row 2 (removed, `let b = 2;`): `let` is a keyword, then a space,
        // then plain text, on the removed background past the text.
        assert_eq!(pixel(&tile, width, 0, 4), [255, 255, 0, 255]);
        assert_eq!(pixel(&tile, width, 3, 4), [200, 0, 0, 255]);
        assert_eq!(pixel(&tile, width, 4, 4), [255, 255, 255, 255]);
        assert_eq!(pixel(&tile, width, 15, 4), [200, 0, 0, 255]);
        // Context rows have no background: only their text shows.
        assert_eq!(pixel(&tile, width, 15, 2), [0, 0, 0, 0]);
        assert_eq!(pixel(&tile, width, 0, 12), [0, 0, 0, 0]);
    }

    #[test]
    fn split_tiles_put_each_side_in_its_half() {
        let diff = parse_diff(DIFF).unwrap();
        let layout = DiffLayout::build(&diff, &Expansion::default(), None);
        let source = DiffMinimap::new(&diff, &layout, None, &[], true, Syntax::plain(), &NO_STATES);
        let width = 41;
        let tile = render_tile(&source, 2, 1, &style(width));
        assert_eq!(
            pixel(&tile, width, 15, 0),
            [200, 0, 0, 255],
            "old side on the left"
        );
        assert_eq!(
            pixel(&tile, width, 20, 0),
            [0, 0, 0, 0],
            "a gap between the halves"
        );
        assert_eq!(
            pixel(&tile, width, 21 + 15, 0),
            [0, 200, 0, 255],
            "new side on the right"
        );
    }

    #[test]
    fn left_out_lines_are_veiled() {
        let diff = parse_diff(DIFF).unwrap();
        let layout = DiffLayout::build(&diff, &Expansion::default(), None);
        let picks = vec![PickState::None; diff.line_count()];
        let source = DiffMinimap::new(
            &diff,
            &layout,
            None,
            &picks,
            false,
            Syntax::plain(),
            &NO_STATES,
        );
        let tile = render_tile(&source, 3, 1, &style(20));
        assert_eq!(pixel(&tile, 20, 15, 0), [0, 99, 0, 255]);
    }

    #[test]
    fn overview_spreads_short_diffs_and_merges_long_ones() {
        let diff = parse_diff(DIFF).unwrap();
        let layout = DiffLayout::build(&diff, &Expansion::default(), None);
        let source = DiffMinimap::new(
            &diff,
            &layout,
            None,
            &[],
            false,
            Syntax::plain(),
            &NO_STATES,
        );
        let tall = overview(&source, 10, false);
        assert_eq!(tall[4..6], [OVERVIEW_REMOVED, OVERVIEW_REMOVED]);
        assert_eq!(tall[6..8], [OVERVIEW_ADDED, OVERVIEW_ADDED]);
        assert_eq!(
            overview(&source, 1, false),
            vec![OVERVIEW_ADDED | OVERVIEW_REMOVED]
        );
        assert!(overview(&source, 0, false).is_empty());
    }

    #[test]
    fn change_rows_step_through_blocks_and_wrap() {
        let diff = parse_diff(
            b"diff --git a/a.rs b/a.rs
index 1111111..2222222 100644
--- a/a.rs
+++ b/a.rs
@@ -1,6 +1,6 @@
 a
-b
+B
 c
 d
-e
+E
 f
",
        )
        .unwrap();
        let layout = DiffLayout::build(&diff, &Expansion::default(), None);
        // Rows: header, a, -b, +B, c, d, -e, +E, f.
        let source = DiffMinimap::new(
            &diff,
            &layout,
            None,
            &[],
            false,
            Syntax::plain(),
            &NO_STATES,
        );
        assert_eq!(change_row(&source, 0, true), Some(2));
        assert_eq!(change_row(&source, 2, true), Some(6));
        assert_eq!(change_row(&source, 3, true), Some(6));
        assert_eq!(change_row(&source, 6, true), Some(2));
        assert_eq!(change_row(&source, 6, false), Some(2));
        assert_eq!(change_row(&source, 7, false), Some(6));
        assert_eq!(change_row(&source, 2, false), Some(6));
        let split = DiffMinimap::new(&diff, &layout, None, &[], true, Syntax::plain(), &NO_STATES);
        // Rows: header, a, b|B, c, d, e|E, f.
        assert_eq!(change_row(&split, 2, true), Some(5));
        let file = ConflictFile::new(
            "f.txt".into(),
            ConflictKind::Content,
            Some(CONFLICT.to_vec()),
        );
        let conflict_layout = ConflictLayout::build(&file, false);
        let conflict =
            ConflictMinimap::new(&file, &conflict_layout, &[], false, Syntax::plain(), None);
        assert_eq!(change_row(&conflict, 0, true), Some(2));
        assert_eq!(change_row(&conflict, 2, true), Some(2));
        // A single block is found from inside it, both ways.
        let one = parse_diff(DIFF).unwrap();
        let one_layout = DiffLayout::build(&one, &Expansion::default(), None);
        let source = DiffMinimap::new(
            &one,
            &one_layout,
            None,
            &[],
            false,
            Syntax::plain(),
            &NO_STATES,
        );
        assert_eq!(change_row(&source, 2, true), Some(2));
        assert_eq!(change_row(&source, 3, false), Some(2));
        let unchanged = ConflictFile::new(
            "g.txt".into(),
            ConflictKind::Content,
            Some(
                b"x
"
                .to_vec(),
            ),
        );
        let unchanged_layout = ConflictLayout::build(&unchanged, false);
        let source = ConflictMinimap::new(
            &unchanged,
            &unchanged_layout,
            &[],
            false,
            Syntax::plain(),
            None,
        );
        assert_eq!(change_row(&source, 0, true), None);
    }

    #[test]
    fn paired_lines_carry_and_draw_their_changed_words() {
        let diff = parse_diff(DIFF).unwrap();
        let layout = DiffLayout::build(&diff, &Expansion::default(), None);
        let source = DiffMinimap::new(
            &diff,
            &layout,
            None,
            &[],
            false,
            Syntax::plain(),
            &NO_STATES,
        );
        // "let b = 2;" became "let b = 3;": the number changed.
        assert_eq!(source.words(2), [Some((8, 9)), None]);
        assert_eq!(source.words(3), [Some((8, 9)), None]);
        assert_eq!(source.words(1), [None, None]);
        let split = DiffMinimap::new(&diff, &layout, None, &[], true, Syntax::plain(), &NO_STATES);
        assert_eq!(split.words(2), [Some((8, 9)), Some((8, 9))]);
        // Three pixels a row: the text's blocks leave the bottom one bare.
        let tall = MinimapStyle {
            row_px: 3,
            ..style(20)
        };
        let tile = render_tile(&source, 0, 5, &tall);
        assert_eq!(
            pixel(&tile, 20, 8, 2 * 3 + 2),
            [255, 0, 0, 255],
            "removed word"
        );
        assert_eq!(
            pixel(&tile, 20, 8, 3 * 3 + 2),
            [0, 255, 0, 255],
            "added word"
        );
        assert_eq!(
            pixel(&tile, 20, 12, 3 * 3 + 2),
            [0, 200, 0, 255],
            "the rest of the row"
        );
    }

    /// Rows with given gaps, for the strip map.
    struct Gapped {
        rows: usize,
        gaps: Vec<StripGap>,
    }

    impl MinimapSource for Gapped {
        fn row_count(&self) -> usize {
            self.rows
        }
        fn row(&self, _row: usize) -> MiniRow<'_> {
            MiniRow::default()
        }
        fn split(&self) -> bool {
            false
        }
        fn syntax(&self) -> Syntax {
            Syntax::plain()
        }
        fn gaps(&self) -> Vec<StripGap> {
            self.gaps.clone()
        }
    }

    #[test]
    fn the_strip_map_gives_hidden_lines_their_room() {
        // 10 rows; row 0 opens a gap of 20 lines, row 5 one of 60.
        let source = Gapped {
            rows: 10,
            gaps: vec![
                StripGap {
                    row: 0,
                    gap: 0,
                    hidden: 20,
                },
                StripGap {
                    row: 5,
                    gap: 1,
                    hidden: 60,
                },
            ],
        };
        let map = StripMap::new(&source, true);
        assert_eq!(map.total(), 90);
        assert_eq!(map.units(0.0), 20.0);
        assert_eq!(map.units(4.5), 24.5);
        assert_eq!(map.units(5.0), 85.0);
        assert_eq!(map.position(10.0), 1.0);
        assert_eq!(map.target(0.1), (0.0, Some(0)));
        assert_eq!(map.target(22.0 / 90.0), (2.0, None));
        assert_eq!(map.target(0.5), (5.0, Some(1)));
        assert_eq!(map.target(87.0 / 90.0), (7.0, None));
        assert_eq!(map.target(1.0), (10.0, None));
        let rows = StripMap::new(&source, false);
        assert_eq!(rows.total(), 10);
        assert_eq!(rows.target(0.5), (5.0, None));
    }

    #[test]
    fn diff_gaps_come_from_the_layout_once_the_end_is_known() {
        // Three lines of context after the change: more may follow.
        let open_end = parse_diff(
            b"diff --git a/a.rs b/a.rs
--- a/a.rs
+++ b/a.rs
@@ -3,5 +3,5 @@
 a
-b
+B
 c
 d
 e
",
        )
        .unwrap();
        let unknown = DiffLayout::build(&open_end, &Expansion::default(), None);
        let source = DiffMinimap::new(
            &open_end,
            &unknown,
            None,
            &[],
            false,
            Syntax::plain(),
            &NO_STATES,
        );
        assert!(source.gaps().is_empty(), "the file's length is unknown");
        let diff = parse_diff(DIFF).unwrap();
        let text: String = (1..=10).map(|n| format!("line {n}\n")).collect();
        let old = OldFile::new("1", text.into_bytes());
        let layout = DiffLayout::build(&diff, &Expansion::default(), Some(&old));
        let source = DiffMinimap::new(
            &diff,
            &layout,
            Some(&old),
            &[],
            false,
            Syntax::plain(),
            &NO_STATES,
        );
        // Rows: header (2 lines above the hunk), 4 lines, end (5 below).
        assert_eq!(
            source.gaps(),
            vec![
                StripGap {
                    row: 0,
                    gap: 0,
                    hidden: 2
                },
                StripGap {
                    row: 5,
                    gap: 1,
                    hidden: 5
                },
            ]
        );
        // On the whole-file strip, the change sits below the first gap.
        let flags = overview(&source, 13, true);
        assert_eq!(flags[0..3], [0, 0, 0]);
        assert_eq!(flags[4], OVERVIEW_REMOVED);
        assert_eq!(flags[5], OVERVIEW_ADDED);
        assert_eq!(flags[7..], [0; 6]);
    }

    #[test]
    fn resolved_lines_are_marked_apart_from_the_blocks_left() {
        let file = ConflictFile::new(
            "f.txt".into(),
            ConflictKind::Content,
            Some(b"one\n<<<<<<< ours\na\n=======\nb\n>>>>>>> theirs\nchosen\nthree\n".to_vec()),
        );
        let layout = ConflictLayout::build(&file, false);
        let chosen = 6..7;
        let source = ConflictMinimap::new(
            &file,
            &layout,
            std::slice::from_ref(&chosen),
            false,
            Syntax::plain(),
            None,
        );
        use Mark::*;
        let unified: Vec<Option<Mark>> = marks(&source).into_iter().map(|m| m.0).collect();
        assert_eq!(
            unified,
            vec![
                Some(Context),
                Some(Header),
                Some(Ours),
                Some(Theirs),
                Some(Resolved),
                Some(Context)
            ]
        );
        assert_eq!(
            overview(&source, 6, false),
            vec![
                0,
                0,
                OVERVIEW_CONFLICT,
                OVERVIEW_CONFLICT,
                OVERVIEW_RESOLVED,
                0
            ]
        );
        assert_eq!(
            change_row(&source, 0, true),
            Some(2),
            "resolved lines are not changes"
        );
    }

    #[test]
    fn blending_mixes_by_alpha() {
        let mut dst = [0, 0, 0, 0];
        blend(&mut dst, [100, 0, 0, 128]);
        assert_eq!(dst, [100, 0, 0, 128]);
        let mut dst = [0, 200, 0, 255];
        blend(&mut dst, [0, 0, 0, 128]);
        assert_eq!(dst, [0, 99, 0, 255]);
    }
}
