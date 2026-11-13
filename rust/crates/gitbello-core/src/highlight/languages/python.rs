use super::super::generic::{
    lex_str_to, Escape, Interp, Spec, SpecLexer, Str, BACKSLASH, HOOK_STATE,
};
use super::super::kind::TokenKind;
use super::super::lexer::Cx;
use super::super::scan::word_start;
use super::{no_hints, LanguageDef};

static FORMAT: &[Interp] = &[Interp {
    open: "{",
    close: '}',
    language: "python",
}];

/// Plain, raw, f- and raw f-strings; the quotes come from the text.
static PLAIN: Str = Str::new("", "", BACKSLASH);
static RAW: Str = Str::new("", "", Escape::None);
static FORMATTED: Str = Str {
    interps: FORMAT,
    doubled_braces: true,
    ..Str::new("", "", BACKSLASH)
};
static RAW_FORMATTED: Str = Str {
    interps: FORMAT,
    doubled_braces: true,
    ..Str::new("", "", Escape::None)
};

static SPEC: Spec = Spec {
    line_comments: &["#"],
    keywords: &[
        "and", "as", "assert", "async", "await", "class", "def", "del", "from", "global", "import",
        "in", "is", "lambda", "nonlocal", "not", "or", "type", "with",
    ],
    control_keywords: &[
        "break", "case", "continue", "elif", "else", "except", "finally", "for", "if", "match",
        "pass", "raise", "return", "try", "while", "yield",
    ],
    types: &[
        "bool",
        "bytearray",
        "bytes",
        "complex",
        "dict",
        "float",
        "frozenset",
        "int",
        "list",
        "object",
        "set",
        "str",
        "tuple",
    ],
    constants: &[
        "True",
        "False",
        "None",
        "NotImplemented",
        "Ellipsis",
        "__debug__",
    ],
    functions: &["print", "len", "range", "isinstance", "super"],
    variables: &["self", "cls"],
    caps_constants: true,
    capitalized_types: true,
    calls: true,
    definitions: &[("def", TokenKind::Function), ("class", TokenKind::Type)],
    annotation_sigils: &['@'],
    hook: Some(strings),
    resume: Some(resume_string),
    ..Spec::EMPTY
};

/// Strings with any prefix (`r`, `b`, `f`, `rb`, `fr`… in either case),
/// single or triple quoted.
fn strings(_spec: &'static Spec, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    if !word_start(chars, i) {
        return None;
    }
    let prefix = (i..chars.len().min(i + 3))
        .find(|&j| !"rRbBfFuU".contains(chars[j]))
        .unwrap_or(chars.len());
    let quote = *chars.get(prefix).filter(|&&q| q == '"' || q == '\'')?;
    if prefix - i > 2 {
        return None;
    }
    let letters: String = chars[i..prefix].iter().collect::<String>().to_lowercase();
    let kind = u16::from(letters.contains('r')) | u16::from(letters.contains('f')) << 1;
    let rule = RULES[usize::from(kind)];
    let triple: String = std::iter::repeat_n(quote, 3).collect();
    let close = if cx.starts_with(prefix, &triple) {
        triple
    } else {
        quote.to_string()
    };
    let body = prefix + close.chars().count();
    let (end, closed) = lex_str_to(cx, rule, i, body, &close, TokenKind::String, false);
    if !closed && close.len() == 3 {
        let single = u16::from(quote == '\'') << 2;
        cx.set_state(HOOK_STATE | single | kind);
    }
    Some(end)
}

/// The rules by kind: bit 0 raw, bit 1 formatted.
static RULES: [&Str; 4] = [&PLAIN, &RAW, &FORMATTED, &RAW_FORMATTED];

/// A triple-quoted string that goes on from the line above (`state`: the
/// rule's kind, and bit 2 for `'''`).
fn resume_string(_spec: &'static Spec, cx: &mut Cx<'_>, state: u16) -> usize {
    let rule = RULES[usize::from(state & 3)];
    let close = if state & 4 != 0 { "'''" } else { "\"\"\"" };
    let (end, closed) = lex_str_to(cx, rule, 0, 0, close, TokenKind::String, false);
    if !closed {
        cx.set_state(state);
    }
    end
}

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static PYTHON: LanguageDef = LanguageDef {
    id: "python",
    name: "Python",
    extensions: &["py", "pyi", "pyw"],
    file_names: &[],
    shebangs: &["python"],
    lexer: &LEXER,
    hints: no_hints,
};
