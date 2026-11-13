use super::super::generic::{Escape, Interp, Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::{no_hints, LanguageDef};

static INTERP: &[Interp] = &[Interp {
    open: "${",
    close: '}',
    language: "dart",
}];

/// A string with `$name` and `${…}`.
const fn interpolated(quote: &'static str, escape: Escape) -> Str {
    Str {
        interps: INTERP,
        dollar_names: true,
        ..Str::new(quote, quote, escape)
    }
}

/// A triple-quoted string with `$name` and `${…}`, across lines.
const fn interpolated_lines(quote: &'static str) -> Str {
    Str {
        multiline: true,
        ..interpolated(quote, BACKSLASH)
    }
}

static SPEC: Spec = Spec {
    line_comments: &["//"],
    doc_comments: &["///"],
    block_comment: Some(("/*", "*/")),
    doc_blocks: true,
    strings: &[
        Str::lines("r\"\"\"", "\"\"\"", Escape::None),
        Str::lines("r'''", "'''", Escape::None),
        Str::new("r\"", "\"", Escape::None),
        Str::new("r'", "'", Escape::None),
        interpolated_lines("\"\"\""),
        interpolated_lines("'''"),
        interpolated("\"", BACKSLASH),
        interpolated("'", BACKSLASH),
    ],
    keywords: &[
        "abstract",
        "as",
        "async",
        "await",
        "base",
        "class",
        "const",
        "covariant",
        "deferred",
        "enum",
        "export",
        "extends",
        "extension",
        "external",
        "factory",
        "final",
        "get",
        "hide",
        "implements",
        "import",
        "in",
        "interface",
        "is",
        "late",
        "library",
        "mixin",
        "new",
        "of",
        "on",
        "operator",
        "part",
        "required",
        "sealed",
        "set",
        "show",
        "static",
        "super",
        "sync",
        "this",
        "typedef",
        "var",
        "with",
    ],
    control_keywords: &[
        "assert", "break", "case", "catch", "continue", "default", "do", "else", "finally", "for",
        "if", "rethrow", "return", "switch", "throw", "try", "when", "while", "yield",
    ],
    types: &["bool", "double", "dynamic", "int", "num", "void"],
    constants: &["true", "false", "null"],
    capitalized_types: true,
    calls: true,
    constructors: true,
    definitions: &[
        ("class", TokenKind::Type),
        ("enum", TokenKind::Type),
        ("mixin", TokenKind::Type),
        ("extension", TokenKind::Type),
        ("typedef", TokenKind::Type),
    ],
    annotation_sigils: &['@'],
    ..Spec::EMPTY
};

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static DART: LanguageDef = LanguageDef {
    id: "dart",
    name: "Dart",
    extensions: &["dart"],
    file_names: &[],
    shebangs: &["dart"],
    lexer: &LEXER,
    hints: no_hints,
};
