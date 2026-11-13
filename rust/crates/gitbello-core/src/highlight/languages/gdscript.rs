use super::super::generic::{Escape, Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::super::lexer::Cx;
use super::super::scan::{is_ident, scan_while, string_end};
use super::{no_hints, LanguageDef};

static SPEC: Spec = Spec {
    line_comments: &["#"],
    doc_comments: &["##"],
    strings: &[
        Str::lines("\"\"\"", "\"\"\"", BACKSLASH),
        Str::lines("'''", "'''", BACKSLASH),
        Str::new("r\"", "\"", Escape::None),
        Str::new("r'", "'", Escape::None),
        // StringName and NodePath literals.
        Str::new("&\"", "\"", BACKSLASH),
        Str::new("&'", "'", BACKSLASH),
        Str::new("^\"", "\"", BACKSLASH),
        Str::new("^'", "'", BACKSLASH),
        Str::new("\"", "\"", BACKSLASH),
        Str::new("'", "'", BACKSLASH),
    ],
    keywords: &[
        "and",
        "as",
        "await",
        "breakpoint",
        "class",
        "class_name",
        "const",
        "enum",
        "extends",
        "func",
        "in",
        "is",
        "not",
        "or",
        "signal",
        "static",
        "super",
        "var",
    ],
    control_keywords: &[
        "break", "continue", "elif", "else", "for", "if", "match", "pass", "return", "when",
        "while",
    ],
    types: &["bool", "int", "float", "void"],
    constants: &["true", "false", "null", "PI", "TAU", "INF", "NAN"],
    functions: &["preload", "load", "print", "assert"],
    variables: &["self"],
    caps_constants: true,
    capitalized_types: true,
    calls: true,
    definitions: &[
        ("func", TokenKind::Function),
        ("signal", TokenKind::Function),
        ("class_name", TokenKind::Type),
        ("class", TokenKind::Type),
        ("enum", TokenKind::Type),
        ("const", TokenKind::Constant),
    ],
    annotation_sigils: &['@'],
    hook: Some(node_paths),
    ..Spec::EMPTY
};

/// `$Node/Path`, `$"Path"` and `%Unique` node references.
fn node_paths(_spec: &'static Spec, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    let c = chars[i];
    let next = chars.get(i + 1).copied()?;
    let end = match c {
        '$' if next == '"' || next == '\'' => string_end(chars, i + 1, next),
        '$' if is_ident(next) || next == '/' => {
            scan_while(chars, i + 1, |ch| is_ident(ch) || ch == '/')
        }
        '%' if next.is_alphabetic() || next == '_' => {
            // A `%` after an operand is the modulo operator.
            let before = (0..i).rev().find(|&j| !chars[j].is_whitespace());
            if before.is_some_and(|j| is_ident(chars[j]) || matches!(chars[j], ')' | ']' | '"')) {
                return None;
            }
            scan_while(chars, i + 1, is_ident)
        }
        _ => return None,
    };
    cx.push(i, end, TokenKind::Variable);
    Some(end)
}

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static GDSCRIPT: LanguageDef = LanguageDef {
    id: "gdscript",
    name: "GDScript",
    extensions: &["gd"],
    file_names: &[],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
