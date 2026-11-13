use super::super::generic::{lex_str_to, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::super::lexer::{language_tag, Cx, Lexer};
use super::super::scan::{ident_end, is_ident, number_end, scan_while};
use super::{no_hints, Language, LanguageDef};

static STRING: Str = Str::lines("\"", "\"", BACKSLASH);

/// The state of a line inside a string.
const IN_STRING: u16 = 1;
/// The state of a line inside an embedded script's `source`.
const IN_SCRIPT: u16 = 2;

/// Godot's text resources (`.tscn`, `.tres`, `project.godot`, `.import`,
/// `.gdextension`): `[header attr=value]` lines with the header as a type
/// and its attributes as attributes, `key = value` lines with the key as a
/// key, and values: numbers, constants, and calls such as
/// `ExtResource("1")` or `Vector2(0, 1)` as functions; strings (`&"…"`,
/// `^"…"` too) stay plain, as they are most of a file, unless followed by
/// `:` (a dictionary's keys). Strings go on across lines; an embedded
/// script's `script/source` is lexed as GDScript (its `\"` and `\\` read as
/// `"` and `\`).
struct GodotResourceLexer;

impl Lexer for GodotResourceLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let chars = cx.chars();
        let len = chars.len();
        let start = scan_while(chars, cx.pos, char::is_whitespace);
        if cx.state() == IN_SCRIPT {
            cx.set_state(0);
            script(cx, cx.pos, true);
            cx.pos = len;
            return;
        }
        if cx.state() == IN_STRING {
            cx.set_state(0);
            let mark = cx.token_count();
            let (end, closed) =
                lex_str_to(cx, &STRING, cx.pos, cx.pos, "\"", TokenKind::String, false);
            cx.plain_strings_since(mark);
            if !closed {
                cx.set_state(IN_STRING);
                cx.pos = len;
                return;
            }
            values(cx, end, len);
            cx.pos = len;
            return;
        }
        cx.pos = len;
        let Some(&first) = chars.get(start) else {
            return;
        };
        if first == ';' || first == '#' {
            cx.push(start, len, TokenKind::Comment);
            return;
        }
        if first == '[' {
            header(cx, start);
            return;
        }
        let key_char = |c: char| is_ident(c) || "/:.-\"".contains(c);
        let key_end = scan_while(chars, start, key_char);
        let eq = scan_while(chars, key_end, char::is_whitespace);
        if key_end > start && chars.get(eq) == Some(&'=') {
            cx.push(start, key_end, TokenKind::Key);
            cx.push(eq, eq + 1, TokenKind::Operator);
            let key: String = chars[start..key_end].iter().collect();
            let at = scan_while(chars, eq + 1, char::is_whitespace);
            if key == "script/source" && chars.get(at) == Some(&'"') {
                script(cx, at + 1, false);
            } else {
                values(cx, eq + 1, len);
            }
        } else {
            // A continuation of a value from the line before.
            values(cx, start, len);
        }
    }
}

/// A script's source from `body` to its closing quote (or the line end,
/// when it goes on), as GDScript with its escapes undone; with `resume`,
/// from the state the line above left.
fn script(cx: &mut Cx<'_>, body: usize, resume: bool) {
    let chars = cx.chars();
    let len = chars.len();
    let mut close = None;
    // The source unescaped, and where each of its characters is.
    let mut text = Vec::new();
    let mut map = Vec::new();
    let mut j = body;
    while j < len {
        match chars[j] {
            '\\' if j + 1 < len => {
                text.push(chars[j + 1]);
                map.push(j);
                j += 2;
            }
            '"' => {
                close = Some(j);
                break;
            }
            c => {
                text.push(c);
                map.push(j);
                j += 1;
            }
        }
    }
    map.push(close.unwrap_or(len));
    if let Some(gdscript) = Language::by_id("gdscript") {
        cx.embed_open_mapped(
            language_tag(gdscript),
            gdscript.lexer(),
            &text,
            &map,
            resume,
        );
    }
    match close {
        Some(c) => {
            cx.set_nested(None);
            values(cx, c + 1, len);
        }
        None => cx.set_state(IN_SCRIPT),
    }
}

/// `[gd_scene load_steps=3 format=3 uid="uid://…"]`.
fn header(cx: &mut Cx<'_>, start: usize) {
    let chars = cx.chars();
    let len = chars.len();
    let close = (start..len).rev().find(|&j| chars[j] == ']').unwrap_or(len);
    let name_end = ident_end(chars, start + 1);
    cx.push(start, name_end, TokenKind::Type);
    let mut i = name_end;
    while i < close {
        let c = chars[i];
        if is_ident(c) {
            let end = ident_end(chars, i);
            if chars.get(end) == Some(&'=') {
                cx.push(i, end, TokenKind::Attribute);
                cx.push(end, end + 1, TokenKind::Operator);
                i = value(cx, end + 1, close);
                continue;
            }
            i = end;
            continue;
        }
        i += 1;
    }
    if close < len {
        cx.push(close, close + 1, TokenKind::Type);
    }
}

/// Values from `from` to `end`.
fn values(cx: &mut Cx<'_>, from: usize, end: usize) {
    let mut i = from;
    while i < end {
        i = value(cx, i, end).max(i + 1);
    }
}

/// One value or part of one at `i`, before `end`: returns where it ends.
fn value(cx: &mut Cx<'_>, i: usize, end: usize) -> usize {
    let chars = cx.chars();
    let i = scan_while(chars, i, char::is_whitespace);
    let Some(&c) = chars.get(i).filter(|_| i < end) else {
        return i;
    };
    let quoted = c == '"' || ((c == '&' || c == '^') && chars.get(i + 1) == Some(&'"'));
    if quoted {
        let body = i + if c == '"' { 1 } else { 2 };
        let close = scan_close(chars, body);
        let after = scan_while(chars, close, char::is_whitespace);
        let kind = if chars.get(after) == Some(&':') {
            TokenKind::Key
        } else {
            TokenKind::String
        };
        let mark = cx.token_count();
        let (end, closed) = lex_str_to(cx, &STRING, i, body, "\"", kind, false);
        if kind == TokenKind::String {
            cx.plain_strings_since(mark);
        }
        if !closed {
            cx.set_state(IN_STRING);
        }
        return end;
    }
    let signed = c == '-' && chars.get(i + 1).is_some_and(char::is_ascii_digit);
    if c.is_ascii_digit() || signed {
        let stop = number_end(chars, i + usize::from(signed));
        cx.push(i, stop, TokenKind::Number);
        return stop;
    }
    if c.is_alphabetic() || c == '_' {
        let stop = ident_end(chars, i);
        let word: String = chars[i..stop].iter().collect();
        let kind = if matches!(
            word.as_str(),
            "true" | "false" | "null" | "inf" | "nan" | "inf_neg"
        ) {
            Some(TokenKind::Constant)
        } else if chars.get(stop) == Some(&'(') {
            Some(TokenKind::Function)
        } else if c.is_uppercase() {
            Some(TokenKind::Type)
        } else {
            None
        };
        if let Some(kind) = kind {
            cx.push(i, stop, kind);
        }
        return stop;
    }
    i + 1
}

/// Where the string whose body starts at `body` ends.
fn scan_close(chars: &[char], body: usize) -> usize {
    let mut j = body;
    while j < chars.len() {
        match chars[j] {
            '\\' => j += 2,
            '"' => return j + 1,
            _ => j += 1,
        }
    }
    chars.len()
}

pub static GODOT_RESOURCE: LanguageDef = LanguageDef {
    id: "godot_resource",
    name: "Godot resource",
    extensions: &["tscn", "tres", "godot", "import", "gdextension", "remap"],
    file_names: &["export_presets.cfg"],
    shebangs: &[],
    lexer: &GodotResourceLexer,
    hints: no_hints,
};
