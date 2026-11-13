//! Settings a language derives once per file from some of its lines, and
//! the [`Syntax`] a diff is coloured with: its language plus those hints.

use super::languages::Language;
use super::lexer::LineState;

/// Lines a language looks at to derive its hints.
pub const HINT_LINES: usize = 200;

/// Per-file settings for a lexer.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct FileHints {
    /// The field delimiter of delimiter-separated values.
    pub delimiter: Option<char>,
}

/// The delimiter, among `,` `;` tab and `|`, that splits the most `lines`
/// into the same number of fields (ignoring quoted text and empty lines);
/// ties go in that order. `None` when no candidate occurs.
pub fn sniff_delimiter(lines: &[String]) -> Option<char> {
    const CANDIDATES: [char; 4] = [',', ';', '\t', '|'];
    let mut best: Option<(char, usize)> = None;
    for candidate in CANDIDATES {
        let mut counts: Vec<usize> = lines
            .iter()
            .take(HINT_LINES)
            .filter(|l| !l.trim().is_empty())
            .map(|l| fields_outside_quotes(l, candidate))
            .filter(|&n| n > 0)
            .collect();
        if counts.is_empty() {
            continue;
        }
        counts.sort_unstable();
        // The most common count, and how many lines have it.
        let mut agreeing = 0;
        let mut run = 0;
        for (i, n) in counts.iter().enumerate() {
            run = if i > 0 && counts[i - 1] == *n {
                run + 1
            } else {
                1
            };
            agreeing = agreeing.max(run);
        }
        if best.is_none_or(|(_, score)| agreeing > score) {
            best = Some((candidate, agreeing));
        }
    }
    best.map(|(c, _)| c)
}

/// How often `delimiter` occurs in `line` outside double quotes.
fn fields_outside_quotes(line: &str, delimiter: char) -> usize {
    let mut quoted = false;
    let mut count = 0;
    for c in line.chars() {
        if c == '"' {
            quoted = !quoted;
        } else if c == delimiter && !quoted {
            count += 1;
        }
    }
    count
}

/// How a file is coloured: its language (none for plain text) and the
/// hints that language derived from the file.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct Syntax {
    pub language: Option<Language>,
    pub hints: FileHints,
}

impl Syntax {
    /// Plain text.
    pub fn plain() -> Self {
        Self::default()
    }

    /// `language` with the hints it derives from `lines` (the first
    /// [`HINT_LINES`] are enough).
    pub fn new(language: Option<Language>, lines: &[String]) -> Self {
        let hints = language.map_or_else(FileHints::default, |l| {
            (l.def().hints)(&lines[..lines.len().min(HINT_LINES)])
        });
        Self { language, hints }
    }

    /// The tokens of `line`, from the start state; empty for plain text.
    pub fn highlight(&self, line: &str) -> Vec<super::Token> {
        self.highlight_from(line, LineState::default()).0
    }

    /// The tokens of `line` lexed from `state`, and the state the next line
    /// starts in; nothing for plain text.
    pub fn highlight_from(&self, line: &str, state: LineState) -> (Vec<super::Token>, LineState) {
        match self.language {
            Some(language) => super::highlight(language, line, &self.hints, state),
            None => (Vec::new(), LineState::default()),
        }
    }

    /// The state the line after the raw line `bytes` starts in, when it
    /// starts in `state`.
    pub fn next_state(&self, bytes: &[u8], state: LineState) -> LineState {
        if self.language.is_none() {
            return LineState::default();
        }
        let text = String::from_utf8_lossy(bytes.strip_suffix(b"\r").unwrap_or(bytes));
        self.highlight_from(&text, state).1
    }

    /// The tokens of a raw line (`bytes` as stored, tabs kept) from the
    /// start state (see [`Syntax::highlight_line_from`]).
    pub fn highlight_line(&self, bytes: &[u8]) -> Vec<super::Token> {
        self.highlight_line_from(bytes, LineState::default())
    }

    /// The tokens of a raw line (`bytes` as stored, tabs kept) lexed from
    /// `state`, in columns of its displayed text
    /// ([`crate::diff::display_text`]): lexers see the tabs (a TSV
    /// delimiter, a Makefile recipe) and a token over a tab covers the
    /// spaces it is shown as.
    pub fn highlight_line_from(&self, bytes: &[u8], state: LineState) -> Vec<super::Token> {
        self.highlight_line_next(bytes, state).0
    }

    /// [`Syntax::highlight_line_from`], with the state the next line starts
    /// in.
    pub fn highlight_line_next(
        &self,
        bytes: &[u8],
        state: LineState,
    ) -> (Vec<super::Token>, LineState) {
        use crate::diff::{MAX_DISPLAY_CHARS, TAB_WIDTH};
        if self.language.is_none() {
            return (Vec::new(), LineState::default());
        }
        // Borrowed when the line is valid UTF-8 (no copy per line).
        let text = String::from_utf8_lossy(bytes.strip_suffix(b"\r").unwrap_or(bytes));
        if !text.contains('\t') {
            let (mut tokens, next) = self.highlight_from(&text, state);
            clip(&mut tokens, MAX_DISPLAY_CHARS);
            return (tokens, next);
        }
        // The display column of each character, and of the end.
        let mut columns = Vec::with_capacity(text.len() + 1);
        let mut column = 0;
        let mut shown = None;
        for ch in text.chars() {
            if shown.is_none() && column >= MAX_DISPLAY_CHARS {
                shown = Some(column);
            }
            columns.push(column);
            column += if ch == '\t' {
                TAB_WIDTH - column % TAB_WIDTH
            } else {
                1
            };
        }
        columns.push(column);
        let (mut tokens, next) = self.highlight_from(&text, state);
        for token in &mut tokens {
            token.start = columns[token.start];
            token.end = columns[token.end];
        }
        clip(&mut tokens, shown.unwrap_or(column));
        (tokens, next)
    }
}

/// A raw line as lexers read it: lossy UTF-8 without its trailing `\r`,
/// tabs kept.
pub fn line_text(bytes: &[u8]) -> String {
    let bytes = bytes.strip_suffix(b"\r").unwrap_or(bytes);
    String::from_utf8_lossy(bytes).into_owned()
}

/// Cuts `tokens` at column `limit`.
fn clip(tokens: &mut Vec<super::Token>, limit: usize) {
    tokens.retain(|t| t.start < limit);
    if let Some(last) = tokens.last_mut() {
        last.end = last.end.min(limit);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(text: &str) -> Vec<String> {
        text.lines().map(str::to_owned).collect()
    }

    #[test]
    fn delimiters() {
        assert_eq!(sniff_delimiter(&lines("a,b,c\n1,2,3\n4,5,6")), Some(','));
        // Commas inside quotes do not count; semicolons agree on every line.
        assert_eq!(
            sniff_delimiter(&lines("name;note\n\"a, b\";x\n\"c, d, e\";y")),
            Some(';')
        );
        assert_eq!(sniff_delimiter(&lines("a\tb\n1\t2")), Some('\t'));
        assert_eq!(sniff_delimiter(&lines("a|b|c\n1|2|3")), Some('|'));
        assert_eq!(sniff_delimiter(&lines("one column\nsecond")), None);
        assert_eq!(sniff_delimiter(&[]), None);
        // Ties go to the comma.
        assert_eq!(sniff_delimiter(&lines("a,b;c")), Some(','));
        // Blank lines are ignored.
        assert_eq!(sniff_delimiter(&lines("a;b\n\n   \nc;d")), Some(';'));
    }

    fn spans(syntax: &Syntax, raw: &[u8]) -> Vec<(usize, usize, &'static str)> {
        syntax
            .highlight_line(raw)
            .iter()
            .map(|t| (t.start, t.end, t.kind.name()))
            .collect()
    }

    #[test]
    fn raw_lines_keep_their_tabs_and_map_to_columns() {
        let tsv = Syntax::new(Language::by_id("tsv"), &[]);
        // `ab\tc`: the tab is shown as two spaces (columns 2 and 3).
        assert_eq!(
            spans(&tsv, b"ab\tc\r"),
            [
                (0, 2, "column.0"),
                (2, 4, "punctuation"),
                (4, 5, "column.1")
            ]
        );
        assert_eq!(spans(&tsv, b"\t"), [(0, 4, "punctuation")]);
        let csv = Syntax::new(Language::by_id("csv"), &lines("a;b\nc;d"));
        assert_eq!(csv.hints.delimiter, Some(';'));
        assert_eq!(spans(&csv, b"x;y").len(), 3);
        // Tokens stop where the displayed text is cut.
        let long = format!("\t\"{}\"", "a".repeat(crate::diff::MAX_DISPLAY_CHARS * 2));
        let rust = Syntax::new(Language::by_id("rust"), &[]);
        let cut = crate::diff::MAX_DISPLAY_CHARS;
        assert_eq!(spans(&rust, long.as_bytes()), [(4, cut, "string")]);
        assert!(spans(&Syntax::plain(), b"\tfn").is_empty());
    }
}
