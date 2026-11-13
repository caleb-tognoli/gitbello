use super::super::generic::{lex_str_to, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::super::lexer::{Cx, Lexer};
use super::super::scan::{number_end, scan_while, string_end};
use super::{no_hints, LanguageDef};

static DOUBLE: Str = Str {
    dollar_names: true,
    ..Str::new("\"", "\"", BACKSLASH)
};

/// `.env` files: `export` as a keyword, names as variables, `=` as an
/// operator, values plain (`$NAME` and `${NAME}` inside double quotes and
/// bare values as variables; a bare number or boolean as such) and `#`
/// comments. A double-quoted value goes on across lines.
struct DotenvLexer;

/// The state of a line inside a double-quoted value.
const IN_VALUE: u16 = 1;

impl Lexer for DotenvLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let chars = cx.chars();
        let len = chars.len();
        let mut i = scan_while(chars, cx.pos, char::is_whitespace);
        if cx.state() == IN_VALUE {
            cx.set_state(0);
            let mark = cx.token_count();
            let (end, closed) =
                lex_str_to(cx, &DOUBLE, cx.pos, cx.pos, "\"", TokenKind::String, false);
            cx.plain_strings_since(mark);
            cx.pos = len;
            if !closed {
                cx.set_state(IN_VALUE);
                return;
            }
            comment_after(cx, end);
            return;
        }
        cx.pos = len;
        if i >= len {
            return;
        }
        if chars[i] == '#' {
            cx.push(i, len, TokenKind::Comment);
            return;
        }
        if cx.starts_with(i, "export ") {
            cx.push(i, i + 6, TokenKind::Keyword);
            i = scan_while(chars, i + 6, char::is_whitespace);
        }
        let name_end = scan_while(chars, i, |c| c.is_alphanumeric() || "_.-".contains(c));
        let op = scan_while(chars, name_end, |c| c == ' ');
        if name_end == i || !matches!(cx.at(op), Some('=' | ':')) {
            return;
        }
        cx.push(i, name_end, TokenKind::Variable);
        cx.push(op, op + 1, TokenKind::Operator);
        let at = scan_while(chars, op + 1, |c| c == ' ');
        let end = match cx.at(at) {
            Some('"') => {
                let mark = cx.token_count();
                let (end, closed) =
                    lex_str_to(cx, &DOUBLE, at, at + 1, "\"", TokenKind::String, false);
                cx.plain_strings_since(mark);
                if !closed {
                    cx.set_state(IN_VALUE);
                }
                end
            }
            Some(q @ ('\'' | '`')) => string_end(chars, at, q),
            Some(_) => bare(cx, at),
            None => len,
        };
        comment_after(cx, end);
    }
}

/// A ` # comment` after a value that ends at `end`.
fn comment_after(cx: &mut Cx<'_>, end: usize) {
    let comment = scan_while(cx.chars(), end, char::is_whitespace);
    if cx.at(comment) == Some('#') {
        cx.push(comment, cx.len(), TokenKind::Comment);
    }
}

/// A bare value from `at` up to a ` #` comment; returns its end.
fn bare(cx: &mut Cx<'_>, at: usize) -> usize {
    let chars = cx.chars();
    let len = chars.len();
    let end = (at..len)
        .find(|&j| chars[j] == '#' && j > at && chars[j - 1].is_whitespace())
        .map_or(len, |j| j - 1);
    let end = (at..end)
        .rev()
        .find(|&j| !chars[j].is_whitespace())
        .map_or(at, |j| j + 1);
    let word: String = chars[at..end].iter().collect::<String>().to_lowercase();
    if matches!(word.as_str(), "true" | "false") {
        cx.push(at, end, TokenKind::Constant);
        return end;
    }
    let digits = at + usize::from(chars[at] == '-');
    if chars.get(digits).is_some_and(char::is_ascii_digit) && number_end(chars, digits) == end {
        cx.push(at, end, TokenKind::Number);
        return end;
    }
    let mut j = at;
    while j < end {
        if chars[j] == '$' {
            let var_end = super::super::generic::dollar_end(chars, j).min(end);
            if var_end > j + 1 {
                cx.push(j, var_end, TokenKind::Variable);
                j = var_end;
                continue;
            }
        }
        j += 1;
    }
    end
}

pub static DOTENV: LanguageDef = LanguageDef {
    id: "dotenv",
    name: ".env",
    extensions: &["env"],
    file_names: &[
        ".env",
        ".env.local",
        ".env.example",
        ".env.sample",
        ".env.template",
        ".env.development",
        ".env.development.local",
        ".env.production",
        ".env.production.local",
        ".env.staging",
        ".env.test",
        ".env.test.local",
        ".flaskenv",
    ],
    shebangs: &[],
    lexer: &DotenvLexer,
    hints: no_hints,
};
