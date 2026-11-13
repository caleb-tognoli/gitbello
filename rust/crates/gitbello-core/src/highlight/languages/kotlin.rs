use super::super::generic::{Escape, Interp, Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::{no_hints, LanguageDef};

static INTERP: &[Interp] = &[Interp {
    open: "${",
    close: '}',
    language: "kotlin",
}];

static SPEC: Spec = Spec {
    line_comments: &["//"],
    block_comment: Some(("/*", "*/")),
    doc_blocks: true,
    strings: &[
        Str {
            interps: INTERP,
            dollar_names: true,
            ..Str::lines("\"\"\"", "\"\"\"", Escape::None)
        },
        Str {
            interps: INTERP,
            dollar_names: true,
            ..Str::new("\"", "\"", BACKSLASH)
        },
    ],
    char_literals: true,
    keywords: &[
        "abstract",
        "actual",
        "annotation",
        "as",
        "by",
        "class",
        "companion",
        "const",
        "constructor",
        "crossinline",
        "data",
        "enum",
        "expect",
        "external",
        "fun",
        "get",
        "import",
        "in",
        "infix",
        "init",
        "inline",
        "inner",
        "interface",
        "internal",
        "is",
        "lateinit",
        "noinline",
        "object",
        "open",
        "operator",
        "out",
        "override",
        "package",
        "private",
        "protected",
        "public",
        "reified",
        "sealed",
        "set",
        "super",
        "suspend",
        "tailrec",
        "this",
        "typealias",
        "val",
        "value",
        "var",
        "vararg",
    ],
    control_keywords: &[
        "break", "catch", "continue", "do", "else", "finally", "for", "if", "return", "throw",
        "try", "when", "while",
    ],
    constants: &["true", "false", "null"],
    caps_constants: true,
    capitalized_types: true,
    calls: true,
    definitions: &[
        ("fun", TokenKind::Function),
        ("class", TokenKind::Type),
        ("interface", TokenKind::Type),
        ("object", TokenKind::Type),
        ("typealias", TokenKind::Type),
    ],
    annotation_sigils: &['@'],
    ..Spec::EMPTY
};

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static KOTLIN: LanguageDef = LanguageDef {
    id: "kotlin",
    name: "Kotlin",
    extensions: &["kt", "kts"],
    file_names: &[],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
