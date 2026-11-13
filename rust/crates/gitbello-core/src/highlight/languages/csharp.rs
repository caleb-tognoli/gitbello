use super::super::generic::{Escape, Interp, Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::{no_hints, LanguageDef};

static INTERP: &[Interp] = &[Interp {
    open: "{",
    close: '}',
    language: "csharp",
}];

static STRINGS: &[Str] = &[
    Str {
        interps: INTERP,
        doubled_braces: true,
        ..Str::lines("$@\"", "\"", Escape::Doubled)
    },
    Str {
        interps: INTERP,
        doubled_braces: true,
        ..Str::lines("@$\"", "\"", Escape::Doubled)
    },
    Str {
        interps: INTERP,
        doubled_braces: true,
        ..Str::new("$\"", "\"", BACKSLASH)
    },
    Str::lines("@\"", "\"", Escape::Doubled),
    Str::lines("\"\"\"", "\"\"\"", Escape::None),
    Str::new("\"", "\"", BACKSLASH),
];

static SPEC: Spec = Spec {
    line_comments: &["//"],
    doc_comments: &["///"],
    block_comment: Some(("/*", "*/")),
    doc_blocks: true,
    strings: STRINGS,
    char_literals: true,
    keywords: &[
        "abstract",
        "as",
        "async",
        "await",
        "base",
        "checked",
        "class",
        "const",
        "delegate",
        "enum",
        "event",
        "explicit",
        "extern",
        "file",
        "fixed",
        "get",
        "global",
        "implicit",
        "in",
        "init",
        "interface",
        "internal",
        "is",
        "lock",
        "nameof",
        "namespace",
        "new",
        "operator",
        "out",
        "override",
        "params",
        "partial",
        "private",
        "protected",
        "public",
        "readonly",
        "record",
        "ref",
        "required",
        "scoped",
        "sealed",
        "set",
        "sizeof",
        "stackalloc",
        "static",
        "struct",
        "this",
        "typeof",
        "unchecked",
        "unsafe",
        "using",
        "value",
        "virtual",
        "volatile",
        "where",
        "with",
    ],
    control_keywords: &[
        "break", "case", "catch", "continue", "default", "do", "else", "finally", "for", "foreach",
        "goto", "if", "return", "switch", "throw", "try", "when", "while", "yield",
    ],
    types: &[
        "bool", "byte", "char", "decimal", "double", "dynamic", "float", "int", "long", "nint",
        "nuint", "object", "sbyte", "short", "string", "uint", "ulong", "ushort", "var", "void",
    ],
    constants: &["true", "false", "null"],
    capitalized_types: true,
    calls: true,
    definitions: &[
        ("class", TokenKind::Type),
        ("new", TokenKind::Type),
        ("struct", TokenKind::Type),
        ("interface", TokenKind::Type),
        ("enum", TokenKind::Type),
        ("record", TokenKind::Type),
        ("namespace", TokenKind::Type),
    ],
    line_attributes: true,
    hash_words: true,
    ..Spec::EMPTY
};

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static CSHARP: LanguageDef = LanguageDef {
    id: "csharp",
    name: "C#",
    extensions: &["cs", "csx"],
    file_names: &[],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
