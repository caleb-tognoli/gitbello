//! Which blocks the Preview shows: the changed blocks with a block of
//! context on each side and the heading of their section, the rest folded
//! into gap rows the user opens a few blocks at a time, like the text view's
//! gaps between hunks. With the whole file asked for, or nothing marked (an
//! added or deleted file), every block shows.

use super::{BlockKind, Change, MarkdownDiff};
use crate::diff::{Expand, Expanders};

/// Unchanged blocks kept on each side of a changed one.
pub const CONTEXT_BLOCKS: usize = 1;
/// Blocks one click on an expander shows.
pub const EXPAND_BLOCKS: u32 = 5;
/// Runs of hidden blocks shorter than this show instead (a gap row would
/// take as much room as the block).
pub const MIN_GAP: usize = 2;

/// How far the user opened each gap: `[below the blocks above it, above the
/// blocks below it]`, by gap index.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Folds {
    gaps: Vec<[u32; 2]>,
}

impl Folds {
    pub fn expand(&mut self, gap: usize, how: Expand) {
        if self.gaps.len() <= gap {
            self.gaps.resize(gap + 1, [0, 0]);
        }
        if let Some(open) = self.gaps.get_mut(gap) {
            match how {
                Expand::Down => open[0] = open[0].saturating_add(EXPAND_BLOCKS),
                Expand::Up => open[1] = open[1].saturating_add(EXPAND_BLOCKS),
                Expand::All => *open = [u32::MAX, 0],
            }
        }
    }

    /// Closes every gap again.
    pub fn clear(&mut self) {
        self.gaps.clear();
    }

    fn get(&self, gap: usize) -> [u32; 2] {
        self.gaps.get(gap).copied().unwrap_or([0, 0])
    }
}

/// A row of the Preview.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PreviewRow {
    /// Block `index` of [`MarkdownDiff::blocks`].
    Block(usize),
    /// Blocks `first..first + hidden` folded away, as gap `gap`.
    Gap {
        gap: usize,
        first: usize,
        hidden: usize,
        expanders: Expanders,
    },
}

/// The rows the Preview shows.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PreviewLayout {
    rows: Vec<PreviewRow>,
}

impl PreviewLayout {
    /// The rows of `diff` with `folds` opened; every block with `whole`.
    pub fn build(diff: &MarkdownDiff, folds: &Folds, whole: bool) -> Self {
        let count = diff.blocks.len();
        let changes = diff.changes();
        if whole || changes.is_empty() {
            return Self {
                rows: (0..count).map(PreviewRow::Block).collect(),
            };
        }
        let mut kept = vec![false; count];
        let mut heading: Option<usize> = None;
        let mut next_change = changes.iter().peekable();
        for (i, block) in diff.blocks.iter().enumerate() {
            if next_change.peek() == Some(&&i) {
                next_change.next();
                let from = i.saturating_sub(CONTEXT_BLOCKS);
                let to = (i + CONTEXT_BLOCKS + 1).min(count);
                kept[from..to].fill(true);
                if let Some(h) = heading {
                    kept[h] = true;
                }
            }
            // A removed heading no longer starts a section.
            if matches!(block.block.kind, BlockKind::Heading(_)) && block.change != Change::Removed
            {
                heading = Some(i);
            }
        }
        let mut rows = Vec::with_capacity(count);
        let mut gap = 0;
        let mut i = 0;
        while i < count {
            if kept[i] {
                rows.push(PreviewRow::Block(i));
                i += 1;
                continue;
            }
            let start = i;
            while i < count && !kept[i] {
                i += 1;
            }
            let end = i;
            if end - start < MIN_GAP {
                rows.extend((start..end).map(PreviewRow::Block));
                continue;
            }
            let [down, up] = folds.get(gap);
            let len = end - start;
            let down = usize::try_from(down).unwrap_or(usize::MAX).min(len);
            let up = usize::try_from(up).unwrap_or(usize::MAX).min(len - down);
            let hidden = len - down - up;
            rows.extend((start..start + down).map(PreviewRow::Block));
            if hidden > 0 {
                let expanders = if start == 0 {
                    Expanders::Up
                } else if end == count {
                    Expanders::Down
                } else if hidden <= EXPAND_BLOCKS as usize {
                    Expanders::All
                } else {
                    Expanders::Both
                };
                rows.push(PreviewRow::Gap {
                    gap,
                    first: start + down,
                    hidden,
                    expanders,
                });
            }
            rows.extend((end - up..end).map(PreviewRow::Block));
            gap += 1;
        }
        Self { rows }
    }

    pub fn rows(&self) -> &[PreviewRow] {
        &self.rows
    }

    /// Whether some blocks are folded away.
    pub fn has_hidden(&self) -> bool {
        self.rows
            .iter()
            .any(|r| matches!(r, PreviewRow::Gap { .. }))
    }

    /// Row index of each changed block shown, in order.
    pub fn changes(&self, diff: &MarkdownDiff) -> Vec<usize> {
        self.rows
            .iter()
            .enumerate()
            .filter(|(_, row)| match row {
                PreviewRow::Block(b) => diff
                    .blocks
                    .get(*b)
                    .is_some_and(|b| b.change != Change::Same),
                PreviewRow::Gap { .. } => false,
            })
            .map(|(i, _)| i)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::markdown::diff_texts;

    /// `B<n>` per shown block, `[gap hidden expanders]` per gap row.
    fn shape(layout: &PreviewLayout) -> String {
        layout
            .rows()
            .iter()
            .map(|row| match row {
                PreviewRow::Block(b) => format!("B{b}"),
                PreviewRow::Gap {
                    hidden, expanders, ..
                } => format!("[{hidden} {}]", expanders.id()),
            })
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// Paragraphs `p0`…, with `changed` ones edited on the new side.
    fn doc(count: usize, changed: &[usize], headings: &[usize]) -> (String, String) {
        let block = |i: usize, new: bool| {
            let text = if new && changed.contains(&i) {
                format!("paragraph {i} edited words")
            } else {
                format!("paragraph {i} words")
            };
            if headings.contains(&i) {
                format!("## {text}\n\n")
            } else {
                format!("{text}\n\n")
            }
        };
        (
            (0..count).map(|i| block(i, false)).collect(),
            (0..count).map(|i| block(i, true)).collect(),
        )
    }

    #[test]
    fn changes_keep_their_context_and_section_heading() {
        let (old, new) = doc(30, &[12], &[2]);
        let diff = diff_texts(Some(&old), Some(&new));
        assert_eq!(diff.changes(), vec![12]);
        let layout = PreviewLayout::build(&diff, &Folds::default(), false);
        assert_eq!(shape(&layout), "[2 up] B2 [8 both] B11 B12 B13 [16 down]");
        assert!(layout.has_hidden());
        assert_eq!(layout.changes(&diff), vec![4]);
    }

    #[test]
    fn whole_and_unmarked_documents_show_every_block() {
        let (old, new) = doc(10, &[5], &[]);
        let diff = diff_texts(Some(&old), Some(&new));
        let whole = PreviewLayout::build(&diff, &Folds::default(), true);
        assert_eq!(whole.rows().len(), 10);
        assert!(!whole.has_hidden());
        let added = diff_texts(None, Some(&new));
        let layout = PreviewLayout::build(&added, &Folds::default(), false);
        assert_eq!(layout.rows().len(), 10);
        assert!(!layout.has_hidden());
    }

    #[test]
    fn single_hidden_blocks_show_and_gaps_open_by_steps() {
        let (old, new) = doc(40, &[3, 6, 20], &[]);
        let diff = diff_texts(Some(&old), Some(&new));
        let mut folds = Folds::default();
        let layout = PreviewLayout::build(&diff, &folds, false);
        // The contexts of 3 and 6 join up; 8..19 is a gap of 11.
        assert_eq!(
            shape(&layout),
            "[2 up] B2 B3 B4 B5 B6 B7 [11 both] B19 B20 B21 [18 down]"
        );
        folds.expand(1, Expand::Down);
        folds.expand(1, Expand::Up);
        let layout = PreviewLayout::build(&diff, &folds, false);
        assert_eq!(
            shape(&layout),
            "[2 up] B2 B3 B4 B5 B6 B7 B8 B9 B10 B11 B12 [1 all] B14 B15 B16 B17 B18 B19 B20 B21 [18 down]"
        );
        folds.expand(1, Expand::All);
        folds.expand(0, Expand::Up);
        folds.expand(2, Expand::Down);
        let layout = PreviewLayout::build(&diff, &folds, false);
        let shown = shape(&layout);
        assert!(shown.starts_with("B0 B1 B2"), "{shown}");
        assert!(shown.ends_with("B26 [13 down]"), "{shown}");
        folds.clear();
        assert_eq!(PreviewLayout::build(&diff, &folds, false).rows().len(), 12);
    }
}
