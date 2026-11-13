use super::super::generic::{Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::{no_hints, LanguageDef};

pub(super) static STRINGS: &[Str] = &[
    Str::new("u8\"", "\"", BACKSLASH),
    Str::new("u\"", "\"", BACKSLASH),
    Str::new("U\"", "\"", BACKSLASH),
    Str::new("L\"", "\"", BACKSLASH),
    Str::new("\"", "\"", BACKSLASH),
];

pub(super) static CONTROL: &[&str] = &[
    "break", "case", "continue", "default", "do", "else", "for", "goto", "if", "return", "switch",
    "while",
];

pub(super) static TYPES: &[&str] = &[
    "bool",
    "char",
    "double",
    "float",
    "int",
    "long",
    "short",
    "signed",
    "unsigned",
    "void",
    "size_t",
    "ssize_t",
    "ptrdiff_t",
    "intptr_t",
    "uintptr_t",
    "int8_t",
    "int16_t",
    "int32_t",
    "int64_t",
    "uint8_t",
    "uint16_t",
    "uint32_t",
    "uint64_t",
    "wchar_t",
    "char16_t",
    "char32_t",
    "FILE",
];

static SPEC: Spec = Spec {
    line_comments: &["//"],
    block_comment: Some(("/*", "*/")),
    doc_blocks: true,
    strings: STRINGS,
    char_literals: true,
    keywords: &[
        "auto",
        "const",
        "enum",
        "extern",
        "inline",
        "register",
        "restrict",
        "sizeof",
        "static",
        "struct",
        "typedef",
        "union",
        "volatile",
        "_Alignas",
        "_Alignof",
        "_Atomic",
        "_Bool",
        "_Generic",
        "_Noreturn",
        "_Static_assert",
        "_Thread_local",
        "alignas",
        "alignof",
        "static_assert",
        "thread_local",
        "typeof",
    ],
    control_keywords: CONTROL,
    types: TYPES,
    constants: &["NULL", "true", "false", "nullptr"],
    caps_constants: true,
    capitalized_types: true,
    calls: true,
    definitions: &[
        ("struct", TokenKind::Type),
        ("enum", TokenKind::Type),
        ("union", TokenKind::Type),
    ],
    hash_words: true,
    ..Spec::EMPTY
};

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static C: LanguageDef = LanguageDef {
    id: "c",
    name: "C",
    extensions: &["c"],
    file_names: &[],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
