use super::super::generic::{Interp, Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::{no_hints, LanguageDef};

pub(super) static KEYWORDS: &[&str] = &[
    "async",
    "await",
    "class",
    "const",
    "delete",
    "export",
    "extends",
    "from",
    "function",
    "get",
    "import",
    "in",
    "instanceof",
    "let",
    "new",
    "of",
    "set",
    "static",
    "super",
    "this",
    "typeof",
    "var",
    "void",
    "with",
];

pub(super) static CONTROL: &[&str] = &[
    "break", "case", "catch", "continue", "default", "do", "else", "finally", "for", "if",
    "return", "switch", "throw", "try", "while", "yield",
];

pub(super) static CONSTANTS: &[&str] = &["true", "false", "null", "undefined", "NaN", "Infinity"];

pub(super) static DEFINITIONS: &[(&str, TokenKind)] = &[
    ("function", TokenKind::Function),
    ("class", TokenKind::Type),
    ("new", TokenKind::Type),
    ("interface", TokenKind::Type),
    ("type", TokenKind::Type),
    ("enum", TokenKind::Type),
    ("namespace", TokenKind::Type),
];

static STRINGS: &[Str] = &[
    Str {
        interps: &[Interp {
            open: "${",
            close: '}',
            language: "javascript",
        }],
        ..Str::lines("`", "`", BACKSLASH)
    },
    Str::new("\"", "\"", BACKSLASH),
    Str::new("'", "'", BACKSLASH),
];

static SPEC: Spec = Spec {
    line_comments: &["//"],
    block_comment: Some(("/*", "*/")),
    doc_blocks: true,
    strings: STRINGS,
    keywords: KEYWORDS,
    control_keywords: CONTROL,
    constants: CONSTANTS,
    caps_constants: true,
    capitalized_types: true,
    calls: true,
    definitions: DEFINITIONS,
    annotation_sigils: &['@'],
    regex_literals: true,
    ..Spec::EMPTY
};

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static JAVASCRIPT: LanguageDef = LanguageDef {
    id: "javascript",
    name: "JavaScript",
    extensions: &["js", "mjs", "cjs", "jsx"],
    file_names: &[],
    shebangs: &["node", "deno", "bun"],
    lexer: &LEXER,
    hints: no_hints,
};
