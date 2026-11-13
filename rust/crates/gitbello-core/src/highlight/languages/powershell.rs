use super::super::generic::{matching, Escape, Interp, Spec, SpecLexer, Str};
use super::super::kind::TokenKind;
use super::super::lexer::Cx;
use super::super::scan::{is_ident, scan_while, word_start};
use super::{no_hints, Language, LanguageDef};

static INTERP: &[Interp] = &[Interp {
    open: "$(",
    close: ')',
    language: "powershell",
}];

static BACKTICK: Escape = Escape::With('`');

static SPEC: Spec = Spec {
    line_comments: &["#"],
    block_comment: Some(("<#", "#>")),
    strings: &[
        Str {
            interps: INTERP,
            dollar_names: true,
            ..Str::lines("@\"", "\"@", BACKTICK)
        },
        Str::lines("@'", "'@", Escape::None),
        Str {
            interps: INTERP,
            dollar_names: true,
            ..Str::lines("\"", "\"", BACKTICK)
        },
        Str::lines("'", "'", Escape::Doubled),
    ],
    keywords: &[
        "begin",
        "class",
        "clean",
        "dynamicparam",
        "end",
        "enum",
        "filter",
        "function",
        "hidden",
        "in",
        "param",
        "process",
        "static",
        "using",
        "workflow",
    ],
    control_keywords: &[
        "break", "catch", "continue", "do", "else", "elseif", "exit", "finally", "for", "foreach",
        "if", "return", "switch", "throw", "trap", "try", "until", "while",
    ],
    case_insensitive: true,
    calls: true,
    definitions: &[
        ("function", TokenKind::Function),
        ("filter", TokenKind::Function),
        ("class", TokenKind::Type),
        ("enum", TokenKind::Type),
    ],
    hook: Some(powershell_words),
    ..Spec::EMPTY
};

/// `-eq`, `-and`… compare and combine; other dashed words are parameters.
static OPERATORS: &[&str] = &[
    "eq",
    "ne",
    "gt",
    "ge",
    "lt",
    "le",
    "ieq",
    "ine",
    "ceq",
    "cne",
    "like",
    "notlike",
    "match",
    "notmatch",
    "cmatch",
    "imatch",
    "contains",
    "notcontains",
    "in",
    "notin",
    "replace",
    "creplace",
    "split",
    "join",
    "is",
    "isnot",
    "as",
    "and",
    "or",
    "xor",
    "not",
    "band",
    "bor",
    "bxor",
    "bnot",
    "shl",
    "shr",
    "f",
];

/// Variables, subexpressions, `[Type]`s, `-Parameter`s and `Verb-Noun`
/// commands.
fn powershell_words(_spec: &'static Spec, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    let c = chars[i];
    let next = chars.get(i + 1).copied();
    if c == '$' {
        if next == Some('(') {
            let inner = i + 2;
            let end = matching(chars, inner, ')');
            cx.push(i, inner, TokenKind::StringInterpolation);
            if let Some(ps) = Language::by_id("powershell") {
                cx.embed(ps, inner, end.unwrap_or(chars.len()));
            }
            return Some(match end {
                Some(e) => {
                    cx.push(e, e + 1, TokenKind::StringInterpolation);
                    e + 1
                }
                None => chars.len(),
            });
        }
        let end = match next {
            Some('{') => matching(chars, i + 2, '}').map_or(chars.len(), |j| j + 1),
            Some(n) if is_ident(n) => scan_while(chars, i + 1, |ch| is_ident(ch) || ch == ':'),
            Some('$' | '?' | '^') => i + 2,
            _ => return None,
        };
        let name: String = chars[i + 1..end].iter().collect::<String>().to_lowercase();
        let kind = if matches!(name.as_str(), "true" | "false" | "null") {
            TokenKind::Constant
        } else {
            TokenKind::Variable
        };
        cx.push(i, end, kind);
        return Some(end);
    }
    let spaced = i == 0 || chars[i - 1].is_whitespace() || chars[i - 1] == '(';
    if c == '-' && spaced && next.is_some_and(char::is_alphabetic) {
        let end = scan_while(chars, i + 1, |ch| is_ident(ch) || ch == '-');
        let word: String = chars[i + 1..end].iter().collect::<String>().to_lowercase();
        let kind = if OPERATORS.contains(&word.as_str()) {
            TokenKind::Keyword
        } else {
            TokenKind::Attribute
        };
        cx.push(i, end, kind);
        return Some(end);
    }
    if c == '[' && next.is_some_and(|n| n.is_alphabetic()) {
        let close = scan_while(chars, i + 1, |ch| is_ident(ch) || ch == '.' || ch == '`');
        let close = if cx.starts_with(close, "[]") {
            close + 2
        } else {
            close
        };
        if chars.get(close) == Some(&']') {
            cx.push(i, close + 1, TokenKind::Type);
            return Some(close + 1);
        }
    }
    if c.is_alphabetic() && word_start(chars, i) {
        let verb = scan_while(chars, i, char::is_alphabetic);
        if chars.get(verb) == Some(&'-') && chars.get(verb + 1).is_some_and(|n| n.is_alphabetic()) {
            let end = scan_while(chars, verb + 1, |ch| is_ident(ch) || ch == '-');
            cx.push(i, end, TokenKind::Function);
            return Some(end);
        }
    }
    None
}

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static POWERSHELL: LanguageDef = LanguageDef {
    id: "powershell",
    name: "PowerShell",
    extensions: &["ps1", "psm1", "psd1"],
    file_names: &[],
    shebangs: &["pwsh", "powershell"],
    lexer: &LEXER,
    hints: no_hints,
};
