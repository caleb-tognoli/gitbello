use super::super::generic::{Interp, Spec, SpecLexer, Str, BACKSLASH};
use super::javascript::{CONSTANTS, CONTROL, DEFINITIONS};
use super::{no_hints, LanguageDef};

static STRINGS: &[Str] = &[
    Str {
        interps: &[Interp {
            open: "${",
            close: '}',
            language: "typescript",
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
    keywords: &[
        "abstract",
        "accessor",
        "as",
        "asserts",
        "async",
        "await",
        "class",
        "const",
        "declare",
        "delete",
        "enum",
        "export",
        "extends",
        "from",
        "function",
        "get",
        "implements",
        "import",
        "in",
        "infer",
        "instanceof",
        "interface",
        "is",
        "keyof",
        "let",
        "module",
        "namespace",
        "new",
        "of",
        "override",
        "private",
        "protected",
        "public",
        "readonly",
        "satisfies",
        "set",
        "static",
        "super",
        "this",
        "type",
        "typeof",
        "unique",
        "var",
        "with",
    ],
    control_keywords: CONTROL,
    types: &[
        "any", "bigint", "boolean", "never", "number", "object", "string", "symbol", "unknown",
        "void",
    ],
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

pub static TYPESCRIPT: LanguageDef = LanguageDef {
    id: "typescript",
    name: "TypeScript",
    extensions: &["ts", "mts", "cts", "tsx"],
    file_names: &[],
    shebangs: &["ts-node", "tsx"],
    lexer: &LEXER,
    hints: no_hints,
};
