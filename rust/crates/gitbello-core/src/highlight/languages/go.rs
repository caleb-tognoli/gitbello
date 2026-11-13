use super::super::generic::{Escape, Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::{no_hints, LanguageDef};

static SPEC: Spec = Spec {
    line_comments: &["//"],
    block_comment: Some(("/*", "*/")),
    strings: &[
        Str::lines("`", "`", Escape::None),
        Str::new("\"", "\"", BACKSLASH),
    ],
    char_literals: true,
    keywords: &[
        "chan",
        "const",
        "func",
        "import",
        "interface",
        "map",
        "package",
        "struct",
        "type",
        "var",
        // go.mod
        "module",
        "require",
        "replace",
        "exclude",
        "retract",
        "toolchain",
        "go",
    ],
    control_keywords: &[
        "break",
        "case",
        "continue",
        "default",
        "defer",
        "else",
        "fallthrough",
        "for",
        "goto",
        "if",
        "range",
        "return",
        "select",
        "switch",
    ],
    types: &[
        "any",
        "bool",
        "byte",
        "comparable",
        "complex64",
        "complex128",
        "error",
        "float32",
        "float64",
        "int",
        "int8",
        "int16",
        "int32",
        "int64",
        "rune",
        "string",
        "uint",
        "uint8",
        "uint16",
        "uint32",
        "uint64",
        "uintptr",
    ],
    constants: &["true", "false", "nil", "iota"],
    functions: &[
        "append", "cap", "clear", "close", "copy", "delete", "len", "make", "max", "min", "new",
        "panic", "print", "println", "recover",
    ],
    calls: true,
    definitions: &[("func", TokenKind::Function), ("type", TokenKind::Type)],
    ..Spec::EMPTY
};

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static GO: LanguageDef = LanguageDef {
    id: "go",
    name: "Go",
    extensions: &["go"],
    file_names: &["go.mod", "go.work"],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
