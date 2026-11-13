use super::super::kind::TokenKind;
use super::super::lexer::{Cx, Lexer};
use super::super::scan::scan_while;
use super::{no_hints, LanguageDef};

/// Ignore files (`.gitignore` and its kin): `#` comments, `!` before a
/// pattern as a keyword, and in patterns the wildcards (`*`, `**`, `?`,
/// `[…]`) and `\` escapes as escapes (special characters of the pattern)
/// and `/` as punctuation.
struct IgnoreLexer;

impl Lexer for IgnoreLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let len = cx.len();
        let i = cx.pos;
        cx.pos = len;
        match cx.at(i) {
            Some('#') => cx.push(i, len, TokenKind::Comment),
            Some('!') => {
                cx.push(i, i + 1, TokenKind::Keyword);
                pattern(cx, i + 1, len, None);
            }
            Some(_) => pattern(cx, i, len, None),
            None => {}
        }
    }
}

/// The wildcards, escapes and slashes of a pattern in `[from, to)`, the
/// rest as `base` when given (a quoted pattern).
fn pattern(cx: &mut Cx<'_>, from: usize, to: usize, base: Option<TokenKind>) {
    let chars = cx.chars();
    let mut j = from;
    while j < to {
        if let Some(base) = base {
            let plain = (j..to)
                .find(|&k| matches!(chars[k], '\\' | '*' | '?' | '[' | '/'))
                .unwrap_or(to);
            cx.push(j, plain, base);
            j = plain;
            if j >= to {
                break;
            }
        }
        match chars[j] {
            '\\' => {
                cx.push(j, j + 2, TokenKind::StringEscape);
                j += 2;
            }
            '*' | '?' => {
                let end = scan_while(chars, j, |c| c == '*' || c == '?').min(to);
                cx.push(j, end, TokenKind::StringEscape);
                j = end;
            }
            '[' => {
                let end = (j + 1..to)
                    .find(|&k| chars[k] == ']')
                    .map_or(j + 1, |k| k + 1);
                cx.push(j, end, TokenKind::StringEscape);
                j = end;
            }
            '/' => {
                cx.push(j, j + 1, TokenKind::Punctuation);
                j += 1;
            }
            _ => j += 1,
        }
    }
}

/// `.gitattributes`: `#` comments, a pattern (as in ignore files, possibly
/// quoted) and its attributes: names as attributes after an optional `-` or
/// `!` (operators), `=value` as an operator and a string, the `binary`
/// macro and `[attr]name` macro definitions as macros.
struct AttributesLexer;

impl Lexer for AttributesLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let chars = cx.chars();
        let len = chars.len();
        let start = scan_while(chars, cx.pos, char::is_whitespace);
        cx.pos = len;
        let Some(first) = cx.at(start) else {
            return;
        };
        if first == '#' {
            cx.push(start, len, TokenKind::Comment);
            return;
        }
        let mut i = if cx.starts_with(start, "[attr]") {
            cx.push(start, start + 6, TokenKind::Keyword);
            let end = scan_while(chars, start + 6, |c| !c.is_whitespace());
            cx.push(start + 6, end, TokenKind::Macro);
            end
        } else if first == '"' {
            let close = (start + 1..len)
                .find(|&j| chars[j] == '"' && chars[j - 1] != '\\')
                .map_or(len, |j| j + 1);
            pattern(cx, start, close, Some(TokenKind::String));
            close
        } else {
            let end = scan_while(chars, start, |c| !c.is_whitespace());
            pattern(cx, start, end, None);
            end
        };
        while i < len {
            i = scan_while(chars, i, char::is_whitespace);
            if i >= len {
                break;
            }
            let end = scan_while(chars, i, |c| !c.is_whitespace());
            let name = if matches!(chars[i], '-' | '!') {
                cx.push(i, i + 1, TokenKind::Operator);
                i + 1
            } else {
                i
            };
            let eq = (name..end).find(|&j| chars[j] == '=').unwrap_or(end);
            let word: String = chars[name..eq].iter().collect();
            let kind = if word == "binary" {
                TokenKind::Macro
            } else {
                TokenKind::Attribute
            };
            cx.push(name, eq, kind);
            if eq < end {
                cx.push(eq, eq + 1, TokenKind::Operator);
                cx.push(eq + 1, end, TokenKind::String);
            }
            i = end;
        }
    }
}

pub static IGNORE: LanguageDef = LanguageDef {
    id: "ignore",
    name: "Ignore file",
    extensions: &["gitignore", "dockerignore"],
    file_names: &[
        ".gitignore",
        ".dockerignore",
        ".npmignore",
        ".prettierignore",
        ".eslintignore",
        ".stylelintignore",
        ".vscodeignore",
        ".gcloudignore",
        ".helmignore",
        ".containerignore",
        ".ignore",
        ".rgignore",
        ".fdignore",
    ],
    shebangs: &[],
    lexer: &IgnoreLexer,
    hints: no_hints,
};

pub static GITATTRIBUTES: LanguageDef = LanguageDef {
    id: "gitattributes",
    name: "Git attributes",
    extensions: &["gitattributes"],
    file_names: &[".gitattributes"],
    shebangs: &[],
    lexer: &AttributesLexer,
    hints: no_hints,
};
