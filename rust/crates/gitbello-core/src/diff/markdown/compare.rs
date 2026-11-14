//! Comparing the blocks of two Markdown documents. Equal blocks show once;
//! between them, a removed block that resembles an added one of the same
//! kind shows once as changed, with its removed and added words (code
//! lines, table rows) marked; the rest show as removed or added.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use super::seq::{self, Edit};
use super::{Block, Change, CodeLine, Content, MarkdownDiff, Row, ShownBlock, Span};

/// Past this many removed × added blocks between two equal ones, nothing is
/// paired (every pair is tried).
const MAX_PAIRS: usize = 2500;
/// How alike two paragraphs' words must be to show as one changed block.
const TEXT_LIKENESS: f32 = 0.45;
/// How alike two code blocks' lines or tables' rows must be.
const LINES_LIKENESS: f32 = 0.3;

/// The preview of `old` → `new`.
pub fn compare(old: &[Block], new: &[Block]) -> MarkdownDiff {
    let hash = |b: &Block| {
        let mut h = DefaultHasher::new();
        b.hash(&mut h);
        h.finish()
    };
    let old_keys: Vec<u64> = old.iter().map(hash).collect();
    let new_keys: Vec<u64> = new.iter().map(hash).collect();
    let mut out = Vec::with_capacity(new.len());
    let (mut removed, mut added) = (Vec::new(), Vec::new());
    for edit in seq::diff(&old_keys, &new_keys) {
        match edit {
            Edit::Equal(_, j) => {
                region(&removed, &added, old, new, &mut out);
                removed.clear();
                added.clear();
                out.push(ShownBlock::new(new[j].clone(), Change::Same));
            }
            Edit::Delete(i) => removed.push(i),
            Edit::Insert(j) => added.push(j),
        }
    }
    region(&removed, &added, old, new, &mut out);
    MarkdownDiff {
        blocks: out,
        ..MarkdownDiff::default()
    }
}

/// The blocks between two equal ones: removed ones paired in order with the
/// first alike added one after the last pairing. One block replaced by one
/// of the same kind is always paired (a renamed heading reads as one).
fn region(
    removed: &[usize],
    added: &[usize],
    old: &[Block],
    new: &[Block],
    out: &mut Vec<ShownBlock>,
) {
    let shown = |block: &Block, change: Change| ShownBlock::new(block.clone(), change);
    if removed.len() * added.len() > MAX_PAIRS {
        out.extend(removed.iter().map(|&i| shown(&old[i], Change::Removed)));
        out.extend(added.iter().map(|&j| shown(&new[j], Change::Added)));
        return;
    }
    let one_for_one = removed.len() == 1 && added.len() == 1;
    let mut next = 0;
    for &i in removed {
        let found = (next..added.len())
            .find_map(|k| merge(&old[i], &new[added[k]], one_for_one).map(|b| (k, b)));
        match found {
            Some((k, block)) => {
                out.extend(
                    added[next..k]
                        .iter()
                        .map(|&j| shown(&new[j], Change::Added)),
                );
                out.push(ShownBlock::new(block, Change::Changed));
                next = k + 1;
            }
            None => out.push(shown(&old[i], Change::Removed)),
        }
    }
    out.extend(added[next..].iter().map(|&j| shown(&new[j], Change::Added)));
}

/// `new` with what changed from `old` marked, when they are alike enough to
/// show as one block (or of the same kind, with `force`).
fn merge(old: &Block, new: &Block, force: bool) -> Option<Block> {
    if std::mem::discriminant(&old.kind) != std::mem::discriminant(&new.kind) {
        return None;
    }
    let content = match (&old.content, &new.content) {
        (Content::Text(a), Content::Text(b)) => {
            let (spans, likeness) = merge_spans(a, b);
            // Only the containers or the marker changed (a task ticked).
            let same_text = spans.iter().all(|s| s.change == Change::Same);
            (force || same_text || likeness >= TEXT_LIKENESS).then_some(Content::Text(spans))?
        }
        (Content::Code { lines: a, .. }, Content::Code { info, lines: b }) => {
            let (lines, likeness) = merge_lines(a, b);
            (force || likeness >= LINES_LIKENESS).then(|| Content::Code {
                info: info.clone(),
                lines,
            })?
        }
        (
            Content::Table {
                aligns: a_aligns,
                rows: a,
            },
            Content::Table { aligns, rows: b },
        ) if a_aligns.len() == aligns.len() => {
            let (rows, likeness) = merge_rows(a, b);
            (force || likeness >= LINES_LIKENESS || a.first() == b.first()).then(|| {
                Content::Table {
                    aligns: aligns.clone(),
                    rows,
                }
            })?
        }
        (Content::None, Content::None) => Content::None,
        _ => return None,
    };
    Some(Block {
        content,
        ..new.clone()
    })
}

/// A word, a run of spaces or one other character, in its span's look.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Token<'a> {
    text: &'a str,
    style: u8,
    link: Option<&'a str>,
}

impl Token<'_> {
    fn is_space(&self) -> bool {
        self.text.chars().all(char::is_whitespace)
    }
}

fn tokens(spans: &[Span]) -> Vec<Token<'_>> {
    // 0: word characters, 1: whitespace, 2: anything else (one a token).
    let class = |c: char| -> u8 {
        if c.is_alphanumeric() || c == '_' {
            0
        } else if c.is_whitespace() {
            1
        } else {
            2
        }
    };
    let mut out = Vec::new();
    for span in spans {
        let text = span.text.as_str();
        let token = |range: std::ops::Range<usize>| Token {
            text: &text[range],
            style: span.style,
            link: span.link.as_deref(),
        };
        let mut start = 0;
        let mut previous = None;
        for (at, c) in text.char_indices() {
            let k = class(c);
            if at > start && (k == 2 || previous != Some(k)) {
                out.push(token(start..at));
                start = at;
            }
            previous = Some(k);
        }
        if start < text.len() {
            out.push(token(start..text.len()));
        }
    }
    out
}

/// `new`'s spans with the words removed from `old` and added in `new`
/// marked, and how alike the two are (0 to 1, by the characters of the
/// words they share).
fn merge_spans(old: &[Span], new: &[Span]) -> (Vec<Span>, f32) {
    let (a, b) = (tokens(old), tokens(new));
    let mut marked: Vec<(Change, &Token)> = Vec::with_capacity(b.len());
    let mut shared = 0;
    for edit in seq::diff(&a, &b) {
        match edit {
            Edit::Equal(_, j) => {
                if !b[j].is_space() {
                    shared += b[j].text.chars().count();
                }
                marked.push((Change::Same, &b[j]));
            }
            Edit::Delete(i) => marked.push((Change::Removed, &a[i])),
            Edit::Insert(j) => marked.push((Change::Added, &b[j])),
        }
    }
    let letters = |t: &[Token]| -> usize {
        t.iter()
            .filter(|t| !t.is_space())
            .map(|t| t.text.chars().count())
            .sum()
    };
    let total = letters(&a) + letters(&b);
    let likeness = if total == 0 {
        1.0
    } else {
        2.0 * shared as f32 / total as f32
    };
    (to_spans(&join_changes(marked)), likeness)
}

/// Spaces left unchanged between two changes become part of both, so a
/// changed phrase reads as one removed and one added run.
fn join_changes<'a>(marked: Vec<(Change, &'a Token<'a>)>) -> Vec<(Change, &'a Token<'a>)> {
    let mut out: Vec<(Change, &Token)> = Vec::with_capacity(marked.len());
    let mut i = 0;
    while i < marked.len() {
        let (change, token) = marked[i];
        let between = change == Change::Same
            && token.is_space()
            && i > 0
            && marked[i - 1].0 != Change::Same
            && marked.get(i + 1).is_some_and(|m| m.0 != Change::Same);
        if between {
            out.push((Change::Removed, token));
            out.push((Change::Added, token));
        } else {
            out.push((change, token));
        }
        i += 1;
    }
    // In each run of changes, the removed words come first.
    let mut sorted = Vec::with_capacity(out.len());
    let mut run: Vec<(Change, &Token)> = Vec::new();
    for item in out {
        if item.0 == Change::Same {
            run.sort_by_key(|m| m.0 == Change::Added);
            sorted.append(&mut run);
            sorted.push(item);
        } else {
            run.push(item);
        }
    }
    run.sort_by_key(|m| m.0 == Change::Added);
    sorted.append(&mut run);
    sorted
}

fn to_spans(marked: &[(Change, &Token)]) -> Vec<Span> {
    let mut out: Vec<Span> = Vec::new();
    for (change, token) in marked {
        if let Some(last) = out.last_mut() {
            if last.change == *change
                && last.style == token.style
                && last.link.as_deref() == token.link
            {
                last.text.push_str(token.text);
                continue;
            }
        }
        out.push(Span {
            text: token.text.to_owned(),
            style: token.style,
            link: token.link.map(str::to_owned),
            change: *change,
        });
    }
    out
}

fn likeness(shared: usize, a: usize, b: usize) -> f32 {
    if a + b == 0 {
        1.0
    } else {
        2.0 * shared as f32 / (a + b) as f32
    }
}

fn merge_lines(old: &[CodeLine], new: &[CodeLine]) -> (Vec<CodeLine>, f32) {
    let mut out = Vec::with_capacity(new.len());
    let mut shared = 0;
    for edit in seq::diff(old, new) {
        let (line, change) = match edit {
            Edit::Equal(_, j) => {
                shared += 1;
                (&new[j], Change::Same)
            }
            Edit::Delete(i) => (&old[i], Change::Removed),
            Edit::Insert(j) => (&new[j], Change::Added),
        };
        out.push(CodeLine {
            text: line.text.clone(),
            change,
        });
    }
    (out, likeness(shared, old.len(), new.len()))
}

fn merge_rows(old: &[Row], new: &[Row]) -> (Vec<Row>, f32) {
    let mut out = Vec::with_capacity(new.len());
    let mut shared = 0;
    for edit in seq::diff(old, new) {
        let (row, change) = match edit {
            Edit::Equal(_, j) => {
                shared += 1;
                (&new[j], Change::Same)
            }
            Edit::Delete(i) => (&old[i], Change::Removed),
            Edit::Insert(j) => (&new[j], Change::Added),
        };
        out.push(Row {
            cells: row.cells.clone(),
            change,
        });
    }
    (out, likeness(shared, old.len(), new.len()))
}

#[cfg(test)]
mod tests {
    use super::super::{diff_texts, ListMarker};
    use super::*;

    /// `change: text` per block, changed spans as `-[..]` and `+[..]`.
    fn shown(old: &str, new: &str) -> Vec<String> {
        diff_texts(Some(old), Some(new))
            .blocks
            .iter()
            .map(|b| {
                let body = match &b.block.content {
                    Content::Text(spans) => spans
                        .iter()
                        .map(|s| match s.change {
                            Change::Removed => format!("-[{}]", s.text),
                            Change::Added => format!("+[{}]", s.text),
                            _ => s.text.clone(),
                        })
                        .collect(),
                    Content::Code { lines, .. } => lines
                        .iter()
                        .map(|l| format!("{}{}", &l.change.id()[..1], l.text))
                        .collect::<Vec<_>>()
                        .join("|"),
                    Content::Table { rows, .. } => rows
                        .iter()
                        .map(|r| {
                            format!(
                                "{}{}",
                                &r.change.id()[..1],
                                r.cells
                                    .iter()
                                    .map(|c| c.iter().map(|s| s.text.as_str()).collect::<String>())
                                    .collect::<Vec<_>>()
                                    .join(",")
                            )
                        })
                        .collect::<Vec<_>>()
                        .join("|"),
                    Content::None => "---".into(),
                };
                format!("{}: {body}", b.change.id())
            })
            .collect()
    }

    #[test]
    fn unchanged_documents_show_as_they_are() {
        assert_eq!(
            shown("# A\n\ntext\n", "# A\n\ntext\n"),
            vec!["same: A", "same: text"]
        );
    }

    #[test]
    fn edited_paragraphs_mark_their_words() {
        assert_eq!(
            shown(
                "# Title\n\nThe quick brown fox jumps.\n",
                "# Title\n\nThe quick red fox jumps high.\n"
            ),
            vec![
                "same: Title",
                "changed: The quick -[brown]+[red] fox jumps+[ high].",
            ]
        );
        // A phrase reads as one removed and one added run.
        assert_eq!(
            shown("Keep a b c here.", "Keep x y z here."),
            vec!["changed: Keep -[a b c]+[x y z] here."]
        );
    }

    #[test]
    fn one_block_replaced_by_one_of_its_kind_shows_once() {
        assert_eq!(
            shown(
                "# Features

text
",
                "# What it does

text
"
            ),
            vec!["changed: -[Features]+[What it does]", "same: text"]
        );
        // Of another kind: removed and added.
        assert_eq!(
            shown(
                "# Features

text
",
                "Features list

text
"
            ),
            vec!["removed: Features", "added: Features list", "same: text"]
        );
    }

    #[test]
    fn unlike_blocks_show_removed_and_added() {
        assert_eq!(
            shown(
                "one\n\nold words entirely\n\nthree\n",
                "one\n\nnothing in common\n\n## New\n\nthree\n"
            ),
            vec![
                "same: one",
                "removed: old words entirely",
                "added: nothing in common",
                "added: New",
                "same: three",
            ]
        );
    }

    #[test]
    fn added_blocks_before_a_changed_one_keep_their_order() {
        assert_eq!(
            shown(
                "a\n\nsome long sentence here\n",
                "a\n\n# Intro\n\nsome long sentence there\n"
            ),
            vec![
                "same: a",
                "added: Intro",
                "changed: some long sentence -[here]+[there]",
            ]
        );
    }

    #[test]
    fn ticked_tasks_and_styles_count_as_changes() {
        let diff = diff_texts(Some("- [ ] ship it\n"), Some("- [x] ship it\n"));
        assert_eq!(diff.blocks.len(), 1);
        assert_eq!(diff.blocks[0].change, Change::Changed);
        assert_eq!(diff.blocks[0].block.marker, Some(ListMarker::Task(true)));
        assert_eq!(
            shown("make it bold now", "make it **bold** now"),
            vec!["changed: make it -[bold]+[bold] now"]
        );
    }

    #[test]
    fn code_and_tables_mark_lines_and_rows() {
        assert_eq!(
            shown("```\na\nb\nc\n```\n", "```\na\nB\nc\nd\n```\n"),
            vec!["changed: sa|rb|aB|sc|ad"]
        );
        assert_eq!(
            shown(
                "| k | v |\n|---|---|\n| a | 1 |\n| b | 2 |\n",
                "| k | v |\n|---|---|\n| a | 1 |\n| b | 3 |\n"
            ),
            vec!["changed: sk,v|sa,1|rb,2|ab,3"]
        );
        assert_eq!(shown("---\n", "***\n"), vec!["same: ---"]);
    }
}
