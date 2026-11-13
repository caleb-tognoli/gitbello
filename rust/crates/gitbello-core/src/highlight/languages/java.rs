use super::super::generic::{Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::{no_hints, LanguageDef};

static SPEC: Spec = Spec {
    line_comments: &["//"],
    block_comment: Some(("/*", "*/")),
    doc_blocks: true,
    strings: &[
        Str::lines("\"\"\"", "\"\"\"", BACKSLASH),
        Str::new("\"", "\"", BACKSLASH),
    ],
    char_literals: true,
    keywords: &[
        "abstract",
        "assert",
        "class",
        "const",
        "enum",
        "exports",
        "extends",
        "final",
        "implements",
        "import",
        "instanceof",
        "interface",
        "module",
        "native",
        "new",
        "open",
        "package",
        "permits",
        "private",
        "protected",
        "public",
        "record",
        "requires",
        "sealed",
        "static",
        "strictfp",
        "super",
        "synchronized",
        "this",
        "throws",
        "transient",
        "var",
        "volatile",
    ],
    control_keywords: &[
        "break", "case", "catch", "continue", "default", "do", "else", "finally", "for", "if",
        "return", "switch", "throw", "try", "while", "yield",
    ],
    types: &[
        "boolean", "byte", "char", "double", "float", "int", "long", "short", "void",
    ],
    constants: &["true", "false", "null"],
    caps_constants: true,
    capitalized_types: true,
    calls: true,
    definitions: &[
        ("class", TokenKind::Type),
        ("new", TokenKind::Type),
        ("interface", TokenKind::Type),
        ("enum", TokenKind::Type),
        ("record", TokenKind::Type),
    ],
    annotation_sigils: &['@'],
    ..Spec::EMPTY
};

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static JAVA: LanguageDef = LanguageDef {
    id: "java",
    name: "Java",
    extensions: &["java"],
    file_names: &[],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
