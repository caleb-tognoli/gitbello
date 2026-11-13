use super::super::generic::{lex_str_to, Escape, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::super::lexer::{Cx, Lexer};
use super::super::scan::{is_ident, scan_while};
use super::{no_hints, LanguageDef};

static BASIC: Str = Str::new("\"", "\"", BACKSLASH);
static LITERAL: Str = Str::new("'", "'", Escape::None);
static MULTI_BASIC: Str = Str::lines("\"\"\"", "\"\"\"", BACKSLASH);
static MULTI_LITERAL: Str = Str::lines("'''", "'''", Escape::None);

/// The states of a line inside a multi-line string, by kind.
const IN_BASIC: u16 = 1;
const IN_LITERAL: u16 = 2;

/// Tables as types, keys (bare, quoted, dotted; inside inline tables too),
/// numbers and dates, `true`/`false`/`inf`/`nan` as constants. String
/// values stay plain: they are most of a file.
struct TomlLexer;

fn bare_key(c: char) -> bool {
    is_ident(c) || c == '-'
}

/// Lexes a string at `i` if one opens there (a key of `kind`, or a plain
/// value without one); a multi-line one that does not close leaves the next
/// line in it.
fn string(cx: &mut Cx<'_>, i: usize, kind: Option<TokenKind>) -> Option<usize> {
    let rule = [&MULTI_BASIC, &MULTI_LITERAL, &BASIC, &LITERAL]
        .into_iter()
        .find(|r| cx.starts_with(i, r.open))?;
    let body = i + rule.open.chars().count();
    let mark = cx.token_count();
    let (end, closed) = lex_str_to(
        cx,
        rule,
        i,
        body,
        rule.close,
        kind.unwrap_or(TokenKind::String),
        false,
    );
    if kind.is_none() {
        cx.plain_strings_since(mark);
    }
    if !closed && rule.multiline {
        cx.set_state(if std::ptr::eq(rule, &MULTI_BASIC) {
            IN_BASIC
        } else {
            IN_LITERAL
        });
    }
    Some(end)
}

/// A multi-line string going on from the line above: returns where it
/// ends (the line end when it goes on).
fn resume(cx: &mut Cx<'_>, state: u16) -> usize {
    let rule = if state == IN_BASIC {
        &MULTI_BASIC
    } else {
        &MULTI_LITERAL
    };
    let mark = cx.token_count();
    let (end, closed) = lex_str_to(
        cx,
        rule,
        cx.pos,
        cx.pos,
        rule.close,
        TokenKind::String,
        false,
    );
    cx.plain_strings_since(mark);
    if !closed {
        cx.set_state(state);
    }
    end
}

/// Keys from `i` up to `=`: returns where the `=` is (or where keys stop).
fn keys(cx: &mut Cx<'_>, mut i: usize) -> usize {
    let chars = cx.chars();
    while i < chars.len() {
        let c = chars[i];
        if c.is_whitespace() || c == '.' {
            i += 1;
        } else if c == '"' || c == '\'' {
            i = string(cx, i, Some(TokenKind::Key)).unwrap_or(i + 1);
        } else if bare_key(c) {
            let end = scan_while(chars, i, bare_key);
            cx.push(i, end, TokenKind::Key);
            i = end;
        } else {
            break;
        }
    }
    i
}

impl Lexer for TomlLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let chars = cx.chars();
        let len = chars.len();
        let incoming = cx.state();
        cx.set_state(0);
        if incoming != 0 {
            cx.pos = resume(cx, incoming);
            if cx.state() != 0 {
                cx.pos = len;
                return;
            }
        }
        let mut i = scan_while(chars, cx.pos, char::is_whitespace);
        if incoming != 0 {
            // After a string from the line above: values, not a key.
        } else if chars.get(i) == Some(&'[') {
            let close = (i..len)
                .rev()
                .find(|&j| chars[j] == ']')
                .map_or(len, |j| j + 1);
            cx.push(i, close, TokenKind::Type);
            i = close;
        } else if chars.get(i).is_some_and(|&c| c != '#') {
            i = keys(cx, i);
        }
        // Inline tables and arrays, innermost last; in a table a key comes
        // first and after each `,`.
        let mut nesting: Vec<char> = Vec::new();
        let mut expect_key = false;
        while i < len {
            let c = chars[i];
            if c.is_whitespace() {
                i += 1;
                continue;
            }
            if c == '#' {
                cx.push(i, len, TokenKind::Comment);
                break;
            }
            if expect_key && c != '}' {
                expect_key = false;
                let end = keys(cx, i);
                if end > i {
                    i = end;
                    continue;
                }
            }
            if let Some(end) = string(cx, i, None) {
                i = end;
                continue;
            }
            match c {
                '=' => cx.push(i, i + 1, TokenKind::Operator),
                '{' | '[' => {
                    nesting.push(c);
                    expect_key = c == '{';
                }
                '}' | ']' => {
                    nesting.pop();
                }
                ',' => expect_key = nesting.last() == Some(&'{'),
                _ => {}
            }
            let signed = (c == '+' || c == '-')
                && chars.get(i + 1).is_some_and(|n| n.is_ascii_alphanumeric());
            if c.is_ascii_digit() || signed {
                // Numbers, dates and times: digits, letters and `_ : . + -`.
                let end = scan_while(chars, i + 1, |ch| {
                    ch.is_ascii_alphanumeric() || "_:.+-".contains(ch)
                });
                let word: String = chars[i..end].iter().collect();
                let kind = if word
                    .trim_start_matches(['+', '-'])
                    .starts_with(char::is_alphabetic)
                {
                    TokenKind::Constant
                } else {
                    TokenKind::Number
                };
                cx.push(i, end, kind);
                i = end;
                continue;
            }
            if c.is_alphabetic() {
                let end = scan_while(chars, i, bare_key);
                let word: String = chars[i..end].iter().collect();
                if matches!(word.as_str(), "true" | "false" | "inf" | "nan") {
                    cx.push(i, end, TokenKind::Constant);
                }
                i = end;
                continue;
            }
            i += 1;
        }
        cx.pos = len;
    }
}

pub static TOML: LanguageDef = LanguageDef {
    id: "toml",
    name: "TOML",
    extensions: &["toml"],
    file_names: &[
        "cargo.lock",
        "pipfile",
        "poetry.lock",
        "uv.lock",
        "pdm.lock",
    ],
    shebangs: &[],
    lexer: &TomlLexer,
    hints: no_hints,
};
