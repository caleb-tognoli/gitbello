use super::super::kind::TokenKind;
use super::super::lexer::{Cx, Lexer};
use super::super::scan::{number_end, scan_while, string_end};
use super::{no_hints, LanguageDef};

/// `[section]` headers as types (a quoted subsection too), `key = value`
/// with the key as a key, comments on their own line, and in values numbers
/// and booleans. Values stay plain otherwise, quoted ones too.
struct IniLexer;

impl Lexer for IniLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let chars = cx.chars();
        let len = chars.len();
        let start = scan_while(chars, cx.pos, char::is_whitespace);
        cx.pos = len;
        let Some(&first) = chars.get(start) else {
            return;
        };
        if first == ';' || first == '#' || cx.starts_with(start, "!") {
            cx.push(start, len, TokenKind::Comment);
            return;
        }
        if first == '[' {
            let close = (start..len)
                .rev()
                .find(|&j| chars[j] == ']')
                .map_or(len, |j| j + 1);
            cx.push(start, close, TokenKind::Type);
            comment_after(cx, close);
            return;
        }
        let Some(op) = (start..len).find(|&j| chars[j] == '=' || chars[j] == ':') else {
            cx.push(start, len, TokenKind::Key);
            return;
        };
        let key_end = (start..op)
            .rev()
            .find(|&j| !chars[j].is_whitespace())
            .map_or(op, |j| j + 1);
        cx.push(start, key_end, TokenKind::Key);
        cx.push(op, op + 1, TokenKind::Operator);
        value(cx, op + 1);
    }
}

/// A value: a quoted string (plain, but a `;` in it starts no comment), a
/// number, a boolean or plain text, then an inline comment after
/// whitespace.
fn value(cx: &mut Cx<'_>, from: usize) {
    let chars = cx.chars();
    let len = chars.len();
    let mut i = scan_while(chars, from, char::is_whitespace);
    while i < len {
        let c = chars[i];
        let spaced = chars[i - 1].is_whitespace();
        if (c == ';' || c == '#') && spaced {
            cx.push(i, len, TokenKind::Comment);
            return;
        }
        if c == '"' || c == '\'' {
            i = string_end(chars, i, c);
            continue;
        }
        let word_end = scan_while(chars, i, |ch| !ch.is_whitespace() && ch != ',');
        let word: String = chars[i..word_end].iter().collect::<String>().to_lowercase();
        let at_word = i == 0 || !chars[i - 1].is_alphanumeric();
        if at_word
            && matches!(
                word.as_str(),
                "true" | "false" | "yes" | "no" | "on" | "off"
            )
        {
            cx.push(i, word_end, TokenKind::Constant);
        } else if at_word
            && (c.is_ascii_digit()
                || (c == '-' && chars.get(i + 1).is_some_and(char::is_ascii_digit)))
            && number_end(chars, i + usize::from(c == '-')) == word_end
        {
            cx.push(i, word_end, TokenKind::Number);
        }
        i = word_end.max(i + 1);
    }
}

fn comment_after(cx: &mut Cx<'_>, from: usize) {
    let chars = cx.chars();
    let at = scan_while(chars, from, char::is_whitespace);
    if matches!(chars.get(at), Some(';' | '#')) {
        cx.push(at, chars.len(), TokenKind::Comment);
    }
}

pub static INI: LanguageDef = LanguageDef {
    id: "ini",
    name: "INI",
    extensions: &["ini", "cfg", "conf", "properties", "desktop", "inf", "url"],
    file_names: &[
        ".editorconfig",
        ".gitconfig",
        ".gitmodules",
        ".npmrc",
        ".pypirc",
    ],
    shebangs: &[],
    lexer: &IniLexer,
    hints: no_hints,
};
