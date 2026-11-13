use super::super::generic::{Keys, Spec, SpecLexer, Str, BACKSLASH};
use super::{no_hints, LanguageDef};

/// JSON with the JSONC and JSON5 additions: comments, single quotes and
/// bare keys.
static SPEC: Spec = Spec {
    line_comments: &["//"],
    block_comment: Some(("/*", "*/")),
    strings: &[
        Str::new("\"", "\"", BACKSLASH),
        Str::new("'", "'", BACKSLASH),
    ],
    constants: &["true", "false", "null", "NaN", "Infinity"],
    keys: Keys::StringsAndWords,
    ..Spec::EMPTY
};

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static JSON: LanguageDef = LanguageDef {
    id: "json",
    name: "JSON",
    extensions: &[
        "json",
        "jsonc",
        "json5",
        "jsonl",
        "ndjson",
        "code-workspace",
    ],
    file_names: &[".babelrc", ".eslintrc", ".prettierrc"],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
