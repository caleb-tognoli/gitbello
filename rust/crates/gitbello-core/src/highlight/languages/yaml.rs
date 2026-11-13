use super::super::generic::{lex_str_to, Escape, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::super::lexer::{Cx, Lexer};
use super::super::scan::{number_end, scan_while};
use super::{no_hints, LanguageDef};

static DOUBLE: Str = Str::new("\"", "\"", BACKSLASH);
static SINGLE: Str = Str::new("'", "'", Escape::Doubled);

/// Keys, `- ` items, anchors and aliases as variables, `!tags` as types,
/// block scalar indicators, and plain scalars that are numbers or
/// constants; `---`/`...` and `%` directives. String values stay plain
/// (they are most of a file), quoted or not: a block scalar's lines
/// (indented more than the line of its `|` or `>`) and a quoted string that
/// goes on are followed only to find where they end.
struct YamlLexer;

/// The state of a line inside a quoted string: double or single quoted.
const IN_DOUBLE: u16 = 1;
const IN_SINGLE: u16 = 2;
/// `IN_BLOCK | indent`: inside a block scalar whose `|` or `>` stands on a
/// line indented by `indent`.
const IN_BLOCK: u16 = 0x8000;

/// Where a plain scalar from `i` ends: before ` #`, and in flow context
/// before `,`, `]`, `}`; `: ` ends it too.
fn plain_end(chars: &[char], i: usize, flow: bool) -> usize {
    let mut j = i;
    while j < chars.len() {
        let c = chars[j];
        if c == '#' && j > i && chars[j - 1].is_whitespace() {
            break;
        }
        if c == ':'
            && chars
                .get(j + 1)
                .is_none_or(|n| n.is_whitespace() || (flow && ",]}".contains(*n)))
        {
            break;
        }
        if flow && ",]}".contains(c) {
            break;
        }
        j += 1;
    }
    // Trailing spaces are not part of it.
    (i..j)
        .rev()
        .find(|&k| !chars[k].is_whitespace())
        .map_or(i, |k| k + 1)
}

/// The kind of a whole plain scalar, if it is a number or a constant.
fn scalar_kind(word: &str) -> Option<TokenKind> {
    let lower = word.to_lowercase();
    if matches!(
        lower.as_str(),
        "true" | "false" | "yes" | "no" | "on" | "off" | "null" | "~" | ".inf" | "-.inf" | ".nan"
    ) {
        return Some(TokenKind::Constant);
    }
    let chars: Vec<char> = word.chars().collect();
    let start = usize::from(matches!(chars.first(), Some('-' | '+')));
    let numeric = chars.get(start).is_some_and(char::is_ascii_digit)
        && number_end(&chars, start) == chars.len();
    numeric.then_some(TokenKind::Number)
}

impl Lexer for YamlLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let chars = cx.chars();
        let len = chars.len();
        let incoming = cx.state();
        cx.set_state(0);
        let mut i = scan_while(chars, cx.pos, char::is_whitespace);
        let indent = i - cx.pos;
        cx.pos = len;
        // A block scalar goes on while its lines are blank or indented more
        // than its indicator's line.
        if incoming & IN_BLOCK != 0 {
            let parent = usize::from(incoming & !IN_BLOCK);
            if i >= len || indent > parent {
                cx.set_state(incoming);
                return;
            }
        }
        let mut node_start = true;
        if incoming == IN_DOUBLE || incoming == IN_SINGLE {
            let rule = if incoming == IN_DOUBLE {
                &DOUBLE
            } else {
                &SINGLE
            };
            let mark = cx.token_count();
            let (end, closed) = lex_str_to(cx, rule, 0, 0, rule.close, TokenKind::String, false);
            cx.plain_strings_since(mark);
            if !closed {
                cx.set_state(incoming);
                return;
            }
            i = end;
            node_start = false;
        }
        if i == 0 && (cx.starts_with(0, "---") || cx.starts_with(0, "...")) {
            if chars.get(3).is_none_or(|c| c.is_whitespace()) {
                cx.push(0, 3, TokenKind::Keyword);
                i = 3;
            }
        } else if i == 0 && chars.first() == Some(&'%') {
            cx.push(0, len, TokenKind::Annotation);
            return;
        }
        // A key may start here: at the line start, after `- `, `{` or `,`.
        let mut flow = 0usize;
        while i < len {
            let c = chars[i];
            if c.is_whitespace() {
                i += 1;
                continue;
            }
            if c == '#' && (i == 0 || chars[i - 1].is_whitespace()) {
                cx.push(i, len, TokenKind::Comment);
                return;
            }
            if c == '-' && node_start && chars.get(i + 1).is_none_or(|n| n.is_whitespace()) {
                cx.push(i, i + 1, TokenKind::Punctuation);
                i += 1;
                continue;
            }
            if c == '&' || c == '*' {
                let end = scan_while(chars, i + 1, |ch| {
                    !ch.is_whitespace() && !",[]{}".contains(ch)
                });
                if end > i + 1 {
                    cx.push(i, end, TokenKind::Variable);
                    i = end;
                    continue;
                }
            }
            if c == '!' {
                let end = scan_while(chars, i + 1, |ch| {
                    !ch.is_whitespace() && !",[]{}".contains(ch)
                });
                cx.push(i, end, TokenKind::Type);
                i = end;
                continue;
            }
            if (c == '|' || c == '>') && !node_start {
                let end = scan_while(chars, i + 1, |ch| {
                    ch == '-' || ch == '+' || ch.is_ascii_digit()
                });
                if chars.get(end).is_none_or(|n| n.is_whitespace()) {
                    cx.push(i, end, TokenKind::Operator);
                    // Only a comment may follow; the scalar is on the lines
                    // below.
                    let rest = scan_while(chars, end, char::is_whitespace);
                    if rest >= len || chars[rest] == '#' {
                        let indent = u16::try_from(indent).unwrap_or(0x7FFF).min(0x7FFF);
                        cx.set_state(IN_BLOCK | indent);
                    }
                    i = end;
                    continue;
                }
            }
            if c == '"' || c == '\'' {
                let rule = if c == '"' { &DOUBLE } else { &SINGLE };
                // A quoted key is followed by `:`.
                let end = string_close(chars, i, rule);
                let after = scan_while(chars, end, |ch| ch == ' ');
                let kind = if node_start && chars.get(after) == Some(&':') {
                    TokenKind::Key
                } else {
                    TokenKind::String
                };
                let mark = cx.token_count();
                let (end, closed) = lex_str_to(cx, rule, i, i + 1, rule.close, kind, false);
                if kind == TokenKind::String {
                    cx.plain_strings_since(mark);
                }
                if !closed {
                    cx.set_state(if c == '"' { IN_DOUBLE } else { IN_SINGLE });
                }
                i = end;
                node_start = false;
                continue;
            }
            match c {
                '{' | '[' => {
                    flow += 1;
                    node_start = true;
                    i += 1;
                    continue;
                }
                '}' | ']' => {
                    flow = flow.saturating_sub(1);
                    node_start = false;
                    i += 1;
                    continue;
                }
                ',' => {
                    node_start = true;
                    i += 1;
                    continue;
                }
                ':' => {
                    cx.push(i, i + 1, TokenKind::Punctuation);
                    node_start = flow > 0;
                    i += 1;
                    continue;
                }
                _ => {}
            }
            let end = plain_end(chars, i, flow > 0).max(i + 1);
            let colon = scan_while(chars, end, |ch| ch == ' ');
            let is_key = chars.get(colon) == Some(&':')
                && chars
                    .get(colon + 1)
                    .is_none_or(|n| n.is_whitespace() || ",]}".contains(*n));
            if is_key {
                cx.push(i, end, TokenKind::Key);
            } else {
                let word: String = chars[i..end].iter().collect();
                if let Some(kind) = scalar_kind(&word) {
                    cx.push(i, end, kind);
                }
            }
            node_start = false;
            i = end;
        }
    }
}

/// Where the quoted string at `i` ends.
fn string_close(chars: &[char], i: usize, rule: &Str) -> usize {
    let mut j = i + 1;
    while j < chars.len() {
        let c = chars[j];
        if rule.escape == BACKSLASH && c == '\\' {
            j += 2;
            continue;
        }
        if c == chars[i] {
            if rule.escape == Escape::Doubled && chars.get(j + 1) == Some(&c) {
                j += 2;
                continue;
            }
            return j + 1;
        }
        j += 1;
    }
    chars.len()
}

pub static YAML: LanguageDef = LanguageDef {
    id: "yaml",
    name: "YAML",
    extensions: &["yml", "yaml"],
    file_names: &[".clang-format", ".clang-tidy", ".clangd"],
    shebangs: &[],
    lexer: &YamlLexer,
    hints: no_hints,
};
