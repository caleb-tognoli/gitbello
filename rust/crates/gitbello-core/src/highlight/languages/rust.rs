use super::super::generic::{Escape, Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::{no_hints, LanguageDef};

static SPEC: Spec = Spec {
    line_comments: &["//"],
    doc_comments: &["///", "//!"],
    block_comment: Some(("/*", "*/")),
    doc_blocks: true,
    strings: &[
        Str {
            hashed: true,
            ..Str::lines("br", "", Escape::None)
        },
        Str {
            hashed: true,
            ..Str::lines("cr", "", Escape::None)
        },
        Str {
            hashed: true,
            ..Str::lines("r", "", Escape::None)
        },
        Str::lines("b\"", "\"", BACKSLASH),
        Str::lines("c\"", "\"", BACKSLASH),
        Str::lines("\"", "\"", BACKSLASH),
    ],
    char_literals: true,
    keywords: &[
        "as", "async", "await", "const", "crate", "dyn", "enum", "extern", "fn", "impl", "in",
        "let", "mod", "move", "mut", "pub", "ref", "self", "Self", "static", "struct", "super",
        "trait", "type", "union", "unsafe", "use", "where",
    ],
    control_keywords: &[
        "break", "continue", "else", "for", "if", "loop", "match", "return", "while", "yield",
    ],
    types: &[
        "bool", "char", "str", "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32",
        "i64", "i128", "isize", "f32", "f64",
    ],
    constants: &["true", "false", "None"],
    caps_constants: true,
    capitalized_types: true,
    calls: true,
    definitions: &[
        ("fn", TokenKind::Function),
        ("struct", TokenKind::Type),
        ("enum", TokenKind::Type),
        ("union", TokenKind::Type),
        ("trait", TokenKind::Type),
        ("type", TokenKind::Type),
    ],
    macros: true,
    attributes: &["#![", "#["],
    ..Spec::EMPTY
};

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static RUST: LanguageDef = LanguageDef {
    id: "rust",
    name: "Rust",
    extensions: &["rs"],
    file_names: &[],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
