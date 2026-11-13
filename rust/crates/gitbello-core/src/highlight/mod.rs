//! Syntax highlighting for diff lines: small hand-written lexers, one line
//! at a time. A line starts in the [`LineState`] the line above left (a
//! block comment, a string that goes on), found once per text by
//! [`LineStates`]; a line lexed without it starts from the start state.
//! Positions are character indices into the line; [`Syntax::highlight_line`]
//! maps them to the displayed columns (tabs expanded).
//!
//! Adding a language: a file in `languages/` with its [`LanguageDef`]
//! (usually a [`generic::Spec`]), listed in `languages::ALL`, and a sample
//! in `tests/highlight/<id>/`. Adding a token kind: an entry in
//! [`TokenKind`] (and, optionally, theme colours).

pub mod detect;
pub mod generic;
pub mod hints;
pub mod kind;
pub mod languages;
pub mod lexer;
pub mod scan;
pub mod states;

pub use detect::detect;
pub use hints::{line_text, FileHints, Syntax};
pub use kind::TokenKind;
pub use languages::{Language, LanguageDef};
pub use lexer::{language_tag, Cx, Lexer, LineState};
pub use states::{DiffStates, LineStates, StatesStatus};

/// Characters of a line that are lexed; the rest stays plain.
pub const MAX_LEXED_CHARS: usize = 10_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token {
    pub start: usize,
    pub end: usize,
    pub kind: TokenKind,
}

/// Tokens of one line, sorted and non-overlapping, and the state the next
/// line starts in. Only the first [`MAX_LEXED_CHARS`] are lexed.
pub fn highlight(
    language: Language,
    line: &str,
    hints: &FileHints,
    state: LineState,
) -> (Vec<Token>, LineState) {
    let chars: Vec<char> = line.chars().take(MAX_LEXED_CHARS).collect();
    let mut tokens = Vec::new();
    let mut cx = Cx::new(&chars, hints, &mut tokens, state);
    language.lexer().lex(&mut cx);
    let next = LineState::next(cx.state(), cx.nested());
    (tokens, next)
}

/// `text`'s tokens, readable: each line as `| line`, then one caret line
/// per token (`  ^^^ keyword`) under it, as the diff shows them: lexed from
/// the first line on (each line from the state the one above left), with
/// their tabs, shown with tabs expanded ([`Syntax::highlight_line_next`]),
/// the hints derived from the text.
pub fn dump(language: Language, text: &[u8]) -> String {
    let text = text.strip_suffix(b"\n").unwrap_or(text);
    let raw: Vec<&[u8]> = text.split(|&b| b == b'\n').collect();
    let lines: Vec<String> = raw.iter().map(|l| line_text(l)).collect();
    let syntax = Syntax::new(Some(language), &lines);
    let mut out = String::new();
    let mut state = LineState::default();
    for bytes in raw {
        let line = crate::diff::display_text(bytes);
        if line.is_empty() {
            out.push_str("|\n");
        } else {
            out.push_str("| ");
            out.push_str(&line);
            out.push('\n');
        }
        let (tokens, next) = syntax.highlight_line_next(bytes, state);
        state = next;
        for token in tokens {
            out.push_str("  ");
            out.extend(std::iter::repeat_n(' ', token.start));
            out.extend(std::iter::repeat_n('^', token.end - token.start));
            out.push(' ');
            out.push_str(token.kind.name());
            out.push('\n');
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(id: &str, line: &str) -> Vec<(String, TokenKind)> {
        let chars: Vec<char> = line.chars().collect();
        let language = Language::by_id(id).unwrap();
        Syntax::new(Some(language), &[])
            .highlight(line)
            .into_iter()
            .map(|t| (chars[t.start..t.end].iter().collect(), t.kind))
            .collect()
    }

    #[test]
    fn a_line_of_rust() {
        use TokenKind::*;
        assert_eq!(
            kinds("rust", r#"    let x: u32 = parse("a\"b", 'c'); // done"#),
            [
                ("let".into(), Keyword),
                ("u32".into(), Type),
                ("parse".into(), Function),
                (r#""a"#.into(), String),
                (r#"\""#.into(), StringEscape),
                (r#"b""#.into(), String),
                ("'c'".into(), String),
                ("// done".into(), Comment),
            ]
        );
        assert!(kinds("rust", "x2 = y3").is_empty());
    }

    #[test]
    fn long_lines_are_cut() {
        let line = format!("{}\"tail\"", " ".repeat(MAX_LEXED_CHARS));
        assert!(kinds("rust", &line).is_empty());
        let line = format!("\"{}", "a".repeat(MAX_LEXED_CHARS * 2));
        let tokens = kinds("rust", &line);
        assert_eq!(tokens[0].0.chars().count(), MAX_LEXED_CHARS);
    }

    #[test]
    fn an_open_comment_leaves_its_state() {
        let rust = Language::by_id("rust").unwrap();
        let hints = FileHints::default();
        let (_, next) = highlight(rust, "/* open", &hints, LineState::default());
        assert!(!next.is_start());
        assert_eq!(next.depth(), 0);
        let (tokens, after) = highlight(rust, "done */ x", &hints, next);
        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert!(after.is_start());
    }
}
