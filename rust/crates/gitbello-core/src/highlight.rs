//! Syntax highlighting for diff lines: small hand-written tokenizers, one
//! line at a time (no state across lines, so a block comment or string that
//! spans lines is only colored on its first line). Positions are character
//! indices into the line as displayed (tabs already expanded).

use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TokenKind {
    Keyword,
    Type,
    String,
    Number,
    Comment,
}

impl TokenKind {
    /// Stable id for the UI (index into its color table).
    pub fn id(self) -> i32 {
        match self {
            Self::Keyword => 0,
            Self::Type => 1,
            Self::String => 2,
            Self::Number => 3,
            Self::Comment => 4,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token {
    pub start: usize,
    pub end: usize,
    pub kind: TokenKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Language {
    Rust,
    GdScript,
    Python,
    JavaScript,
    CLike,
    Go,
    Json,
    Toml,
    Yaml,
    Shell,
    Markdown,
}

/// The language of a file, from its extension or name.
pub fn language_for(path: &Path) -> Option<Language> {
    let name = path.file_name()?.to_string_lossy().to_lowercase();
    if matches!(name.as_str(), "makefile" | "dockerfile") {
        return Some(Language::Shell);
    }
    let ext = path.extension()?.to_string_lossy().to_lowercase();
    Some(match ext.as_str() {
        "rs" => Language::Rust,
        "gd" => Language::GdScript,
        "py" | "pyi" => Language::Python,
        "js" | "mjs" | "cjs" | "jsx" | "ts" | "tsx" => Language::JavaScript,
        "c" | "h" | "cc" | "cpp" | "cxx" | "hpp" | "hh" | "cs" | "java" | "kt" | "kts"
        | "swift" | "glsl" | "gdshader" | "shader" => Language::CLike,
        "go" => Language::Go,
        "json" | "jsonc" => Language::Json,
        "toml" | "ini" | "cfg" | "tscn" | "tres" | "godot" | "import" => Language::Toml,
        "yml" | "yaml" => Language::Yaml,
        "sh" | "bash" | "zsh" | "fish" | "ps1" => Language::Shell,
        "md" | "markdown" => Language::Markdown,
        _ => return None,
    })
}

struct Spec {
    line_comments: &'static [&'static str],
    block_comment: Option<(&'static str, &'static str)>,
    quotes: &'static [char],
    keywords: &'static [&'static str],
    types: &'static [&'static str],
    /// Identifiers starting with an uppercase letter are types.
    capitalized_types: bool,
}

const RUST: Spec = Spec {
    line_comments: &["//"],
    block_comment: Some(("/*", "*/")),
    quotes: &['"'],
    keywords: &[
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
        "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
        "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait",
        "true", "type", "unsafe", "use", "where", "while",
    ],
    types: &[
        "bool", "char", "str", "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32",
        "i64", "i128", "isize", "f32", "f64",
    ],
    capitalized_types: true,
};

const GDSCRIPT: Spec = Spec {
    line_comments: &["#"],
    block_comment: None,
    quotes: &['"', '\''],
    keywords: &[
        "and",
        "as",
        "await",
        "break",
        "class",
        "class_name",
        "const",
        "continue",
        "elif",
        "else",
        "enum",
        "extends",
        "false",
        "for",
        "func",
        "if",
        "in",
        "is",
        "match",
        "not",
        "null",
        "or",
        "pass",
        "preload",
        "return",
        "self",
        "signal",
        "static",
        "super",
        "true",
        "var",
        "when",
        "while",
    ],
    types: &["bool", "int", "float", "void"],
    capitalized_types: true,
};

const PYTHON: Spec = Spec {
    line_comments: &["#"],
    block_comment: None,
    quotes: &['"', '\''],
    keywords: &[
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
        "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True",
        "try", "while", "with", "yield", "self",
    ],
    types: &[
        "int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes",
    ],
    capitalized_types: true,
};

const JAVASCRIPT: Spec = Spec {
    line_comments: &["//"],
    block_comment: Some(("/*", "*/")),
    quotes: &['"', '\'', '`'],
    keywords: &[
        "async",
        "await",
        "break",
        "case",
        "catch",
        "class",
        "const",
        "continue",
        "default",
        "delete",
        "do",
        "else",
        "export",
        "extends",
        "false",
        "finally",
        "for",
        "from",
        "function",
        "if",
        "import",
        "in",
        "instanceof",
        "interface",
        "let",
        "new",
        "null",
        "of",
        "return",
        "static",
        "super",
        "switch",
        "this",
        "throw",
        "true",
        "try",
        "type",
        "typeof",
        "undefined",
        "var",
        "void",
        "while",
        "yield",
    ],
    types: &["string", "number", "boolean", "any", "unknown", "never"],
    capitalized_types: true,
};

const C_LIKE: Spec = Spec {
    line_comments: &["//"],
    block_comment: Some(("/*", "*/")),
    quotes: &['"', '\''],
    keywords: &[
        "abstract",
        "break",
        "case",
        "catch",
        "class",
        "const",
        "continue",
        "default",
        "delete",
        "do",
        "else",
        "enum",
        "extends",
        "false",
        "final",
        "for",
        "fun",
        "if",
        "implements",
        "import",
        "namespace",
        "new",
        "null",
        "nullptr",
        "override",
        "package",
        "private",
        "protected",
        "public",
        "return",
        "static",
        "struct",
        "switch",
        "this",
        "throw",
        "true",
        "try",
        "typedef",
        "uniform",
        "using",
        "val",
        "var",
        "virtual",
        "void",
        "while",
        "#include",
        "#define",
        "#ifdef",
        "#ifndef",
        "#endif",
        "#if",
        "#else",
    ],
    types: &[
        "bool", "char", "double", "float", "int", "long", "short", "unsigned", "string", "vec2",
        "vec3", "vec4", "mat4",
    ],
    capitalized_types: true,
};

const GO: Spec = Spec {
    line_comments: &["//"],
    block_comment: Some(("/*", "*/")),
    quotes: &['"', '\'', '`'],
    keywords: &[
        "break",
        "case",
        "chan",
        "const",
        "continue",
        "default",
        "defer",
        "else",
        "false",
        "for",
        "func",
        "go",
        "goto",
        "if",
        "import",
        "interface",
        "map",
        "nil",
        "package",
        "range",
        "return",
        "select",
        "struct",
        "switch",
        "true",
        "type",
        "var",
    ],
    types: &[
        "bool", "byte", "error", "float32", "float64", "int", "int64", "rune", "string", "uint",
    ],
    capitalized_types: false,
};

const JSON: Spec = Spec {
    line_comments: &["//"],
    block_comment: None,
    quotes: &['"'],
    keywords: &["true", "false", "null"],
    types: &[],
    capitalized_types: false,
};

const TOML: Spec = Spec {
    line_comments: &["#", ";"],
    block_comment: None,
    quotes: &['"', '\''],
    keywords: &["true", "false"],
    types: &[],
    capitalized_types: false,
};

const YAML: Spec = Spec {
    line_comments: &["#"],
    block_comment: None,
    quotes: &['"', '\''],
    keywords: &["true", "false", "null", "yes", "no"],
    types: &[],
    capitalized_types: false,
};

const SHELL: Spec = Spec {
    line_comments: &["#"],
    block_comment: None,
    quotes: &['"', '\''],
    keywords: &[
        "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if",
        "in", "local", "return", "then", "while", "echo", "cd", "set",
    ],
    types: &[],
    capitalized_types: false,
};

fn spec(language: Language) -> &'static Spec {
    match language {
        Language::Rust => &RUST,
        Language::GdScript => &GDSCRIPT,
        Language::Python => &PYTHON,
        Language::JavaScript => &JAVASCRIPT,
        Language::CLike => &C_LIKE,
        Language::Go => &GO,
        Language::Json => &JSON,
        Language::Toml => &TOML,
        Language::Yaml => &YAML,
        Language::Shell | Language::Markdown => &SHELL,
    }
}

/// Tokens of one line, sorted and non-overlapping.
pub fn highlight(language: Language, line: &str) -> Vec<Token> {
    let chars: Vec<char> = line.chars().collect();
    if language == Language::Markdown {
        return markdown(&chars);
    }
    let spec = spec(language);
    let mut tokens = Vec::new();
    let mut i = 0;
    let at = |i: usize, s: &str| {
        s.chars()
            .enumerate()
            .all(|(k, c)| chars.get(i + k) == Some(&c))
    };
    let mut push = |start: usize, end: usize, kind: TokenKind| {
        if end > start {
            tokens.push(Token { start, end, kind });
        }
    };
    while i < chars.len() {
        let c = chars[i];
        if spec.line_comments.iter().any(|m| at(i, m))
            && (language != Language::Shell || i == 0 || chars[i - 1].is_whitespace())
        {
            push(i, chars.len(), TokenKind::Comment);
            break;
        }
        if let Some((open, close)) = spec.block_comment {
            if at(i, open) {
                let body = i + open.chars().count();
                let end = (body..chars.len())
                    .find(|&j| at(j, close))
                    .map_or(chars.len(), |j| j + close.chars().count());
                push(i, end, TokenKind::Comment);
                i = end;
                continue;
            }
        }
        if spec.quotes.contains(&c) || (language == Language::Rust && rust_char(&chars, i)) {
            let end = string_end(&chars, i, c);
            push(i, end, TokenKind::String);
            i = end;
            continue;
        }
        let word_start = i == 0 || !is_ident(chars[i - 1]);
        if c.is_ascii_digit() && word_start {
            let end = scan(&chars, i, |ch| {
                ch.is_alphanumeric() || ch == '.' || ch == '_'
            });
            push(i, end, TokenKind::Number);
            i = end;
            continue;
        }
        let ident_start = is_ident(c) || (c == '#' && language == Language::CLike) || c == '@';
        if ident_start && word_start {
            let end = scan(&chars, i + 1, is_ident);
            let word: String = chars[i..end].iter().collect();
            // `@name` is an annotation or decorator.
            if c == '@' || spec.keywords.contains(&word.as_str()) {
                push(i, end, TokenKind::Keyword);
            } else if spec.types.contains(&word.as_str())
                || (spec.capitalized_types && c.is_uppercase())
            {
                push(i, end, TokenKind::Type);
            }
            i = end;
            continue;
        }
        if language == Language::Shell && c == '$' {
            let end = scan(&chars, i + 1, |ch| is_ident(ch) || ch == '{' || ch == '}');
            push(i, end, TokenKind::Type);
            i = end.max(i + 1);
            continue;
        }
        if language == Language::Toml && c == '[' && chars[..i].iter().all(|c| c.is_whitespace()) {
            let end = chars
                .iter()
                .rposition(|&c| c == ']')
                .map_or(chars.len(), |j| j + 1);
            push(i, end, TokenKind::Type);
            i = end;
            continue;
        }
        i += 1;
    }
    tokens
}

fn is_ident(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

fn scan(chars: &[char], from: usize, keep: impl Fn(char) -> bool) -> usize {
    (from..chars.len())
        .find(|&j| !keep(chars[j]))
        .unwrap_or(chars.len())
}

/// End (exclusive) of the string starting at `start` with quote `quote`;
/// the end of the line when it is not closed.
fn string_end(chars: &[char], start: usize, quote: char) -> usize {
    let mut j = start + 1;
    while j < chars.len() {
        if chars[j] == '\\' {
            j += 2;
            continue;
        }
        if chars[j] == quote {
            return j + 1;
        }
        j += 1;
    }
    chars.len()
}

/// A Rust char literal (`'a'`, `'\n'`), not a lifetime (`'a`).
fn rust_char(chars: &[char], i: usize) -> bool {
    if chars[i] != '\'' {
        return false;
    }
    match chars.get(i + 1) {
        Some('\\') => true,
        Some(_) => chars.get(i + 2) == Some(&'\''),
        None => false,
    }
}

fn markdown(chars: &[char]) -> Vec<Token> {
    let trimmed = chars.iter().position(|c| !c.is_whitespace()).unwrap_or(0);
    let starts = |s: &str| {
        s.chars()
            .enumerate()
            .all(|(k, c)| chars.get(trimmed + k) == Some(&c))
    };
    if starts("#") {
        return vec![Token {
            start: trimmed,
            end: chars.len(),
            kind: TokenKind::Keyword,
        }];
    }
    if starts("```") || starts(">") {
        return vec![Token {
            start: trimmed,
            end: chars.len(),
            kind: TokenKind::Comment,
        }];
    }
    let mut tokens = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '`' {
            let end = chars[i + 1..]
                .iter()
                .position(|&c| c == '`')
                .map_or(chars.len(), |p| i + 1 + p + 1);
            tokens.push(Token {
                start: i,
                end,
                kind: TokenKind::String,
            });
            i = end;
        } else {
            i += 1;
        }
    }
    tokens
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(language: Language, line: &str) -> Vec<(std::string::String, TokenKind)> {
        let chars: Vec<char> = line.chars().collect();
        highlight(language, line)
            .into_iter()
            .map(|t| (chars[t.start..t.end].iter().collect(), t.kind))
            .collect()
    }

    use TokenKind::*;

    #[test]
    fn rust_lines() {
        assert_eq!(
            kinds(
                Language::Rust,
                r#"    let x: u32 = parse("a\"b", 'c'); // done"#
            ),
            [
                ("let".into(), Keyword),
                ("u32".into(), Type),
                (r#""a\"b""#.into(), String),
                ("'c'".into(), String),
                ("// done".into(), Comment),
            ]
        );
        assert_eq!(
            kinds(
                Language::Rust,
                "fn f<'a>(v: &'a Vec<u8>) -> Option<i64> { 0x1F }"
            ),
            [
                ("fn".into(), Keyword),
                ("Vec".into(), Type),
                ("u8".into(), Type),
                ("Option".into(), Type),
                ("i64".into(), Type),
                ("0x1F".into(), Number),
            ]
        );
        assert_eq!(
            kinds(Language::Rust, "a /* b */ c"),
            [("/* b */".into(), Comment)]
        );
    }

    #[test]
    fn gdscript_python_and_shell() {
        assert_eq!(
            kinds(Language::GdScript, "@onready var label: Label = %Name # hi"),
            [
                ("@onready".into(), Keyword),
                ("var".into(), Keyword),
                ("Label".into(), Type),
                ("Name".into(), Type),
                ("# hi".into(), Comment),
            ]
        );
        assert_eq!(
            kinds(Language::Python, "def f(x): return 'y' if x else None"),
            [
                ("def".into(), Keyword),
                ("return".into(), Keyword),
                ("'y'".into(), String),
                ("if".into(), Keyword),
                ("else".into(), Keyword),
                ("None".into(), Keyword),
            ]
        );
        assert_eq!(
            kinds(Language::Shell, r#"echo "$HOME" a#b # note"#),
            [
                ("echo".into(), Keyword),
                (r#""$HOME""#.into(), String),
                ("# note".into(), Comment),
            ]
        );
    }

    #[test]
    fn data_formats_and_markdown() {
        assert_eq!(
            kinds(Language::Json, r#"  "key": [1.5, true, null]"#),
            [
                (r#""key""#.into(), String),
                ("1.5".into(), Number),
                ("true".into(), Keyword),
                ("null".into(), Keyword),
            ]
        );
        assert_eq!(
            kinds(Language::Toml, "[package.metadata]"),
            [("[package.metadata]".into(), Type)]
        );
        assert_eq!(
            kinds(Language::Markdown, "## Title"),
            [("## Title".into(), Keyword)]
        );
        assert_eq!(
            kinds(Language::Markdown, "Run `cargo xtask check` now"),
            [("`cargo xtask check`".into(), String)]
        );
        // Unclosed strings run to the end of the line; identifiers with
        // digits are not numbers.
        assert_eq!(
            kinds(Language::Json, r#""open"#),
            [(r#""open"#.into(), String)]
        );
        assert!(kinds(Language::Rust, "x2 = y3").is_empty());
    }

    #[test]
    fn languages_by_path() {
        assert_eq!(language_for(Path::new("src/main.rs")), Some(Language::Rust));
        assert_eq!(
            language_for(Path::new("app/x.GD")),
            Some(Language::GdScript)
        );
        assert_eq!(language_for(Path::new("Makefile")), Some(Language::Shell));
        assert_eq!(language_for(Path::new("README")), None);
    }
}
