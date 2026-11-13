use std::path::Path;

use super::super::detect;
use super::super::kind::TokenKind;
use super::super::lexer::{language_tag, Cx, Lexer};
use super::super::scan::{is_ident, scan_while};
use super::{no_hints, Language, LanguageDef};

/// Block markers by the line's start (headings, quotes, fences with their
/// language as a type, rules, list markers and task boxes, table rows),
/// then inline: code spans, emphasis, links and images, autolinks and bare
/// URLs, HTML tags, escapes and table pipes. A fenced code block is lexed
/// in its fence's language (by id, alias or extension), plain when unknown.
struct MarkdownLexer;

/// [`Cx::state`] inside a fenced code block: the fence's character and
/// length, and its language's registry index + 1 (0: plain).
mod fence {
    pub const OPEN: u16 = 0x8000;
    pub const TILDE: u16 = 0x4000;
    pub const LENGTH_SHIFT: u16 = 8;
    pub const LENGTH: u16 = 0x3F;
    pub const LANGUAGE: u16 = 0xFF;
}

/// Short names fences use for languages, beyond ids and extensions.
const ALIASES: &[(&str, &str)] = &[
    ("js", "javascript"),
    ("jsx", "javascript"),
    ("node", "javascript"),
    ("ts", "typescript"),
    ("tsx", "typescript"),
    ("py", "python"),
    ("python3", "python"),
    ("sh", "shell"),
    ("bash", "shell"),
    ("zsh", "shell"),
    ("console", "shell"),
    ("shellscript", "shell"),
    ("cs", "csharp"),
    ("c#", "csharp"),
    ("rb", "ruby"),
    ("yml", "yaml"),
    ("ps1", "powershell"),
    ("pwsh", "powershell"),
    ("ps", "powershell"),
    ("bat", "batch"),
    ("cmd", "batch"),
    ("kt", "kotlin"),
    ("rs", "rust"),
    ("gd", "gdscript"),
    ("golang", "go"),
    ("c++", "cpp"),
    ("jsonc", "json"),
    ("md", "markdown"),
    ("make", "makefile"),
    ("patch", "diff"),
    ("env", "dotenv"),
    ("tscn", "godot_resource"),
    ("tres", "godot_resource"),
    ("gdshader", "godot_shader"),
    ("hlsl", "glsl"),
    ("cshtml", "razor"),
];

/// The language a fence's info string names.
fn fence_language(tag: &str) -> Option<Language> {
    let tag = tag
        .trim_start_matches('{')
        .trim_start_matches('.')
        .to_lowercase();
    if tag.is_empty() {
        return None;
    }
    Language::by_id(&tag)
        .or_else(|| {
            ALIASES
                .iter()
                .find(|(alias, _)| *alias == tag)
                .and_then(|(_, id)| Language::by_id(id))
        })
        .or_else(|| detect::by_name(Path::new(&format!("x.{tag}"))))
}

impl Lexer for MarkdownLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let chars = cx.chars();
        let len = chars.len();
        let start = scan_while(chars, cx.pos, char::is_whitespace);
        let incoming = cx.state();
        cx.set_state(0);
        if incoming & fence::OPEN != 0 {
            code_line(cx, incoming, start);
            cx.pos = len;
            return;
        }
        cx.pos = len;
        if start >= len {
            return;
        }
        let first = chars[start];
        if first == '`' || first == '~' {
            let run = scan_while(chars, start, |c| c == first);
            let tag = scan_while(chars, run, char::is_whitespace);
            let tag_end = scan_while(chars, tag, |c| !c.is_whitespace() && c != '{');
            // A backtick fence's info string has no backtick.
            let info_ok = first == '~' || !chars[run..].contains(&'`');
            if run - start >= 3 && info_ok {
                cx.push(start, run, TokenKind::MarkupCode);
                cx.push(tag, tag_end, TokenKind::Type);
                let name: String = chars[tag..tag_end].iter().collect();
                let language =
                    fence_language(&name).map_or(0, |l| u16::try_from(l.index() + 1).unwrap_or(0));
                let length = u16::try_from(run - start)
                    .unwrap_or(fence::LENGTH)
                    .min(fence::LENGTH);
                let tilde = if first == '~' { fence::TILDE } else { 0 };
                cx.set_state(
                    fence::OPEN
                        | tilde
                        | length << fence::LENGTH_SHIFT
                        | language.min(fence::LANGUAGE),
                );
                return;
            }
        }
        if first == '#' {
            let marks = scan_while(chars, start, |c| c == '#');
            if marks - start <= 6 && chars.get(marks).is_none_or(|c| c.is_whitespace()) {
                cx.push(start, len, TokenKind::MarkupHeading);
                return;
            }
        }
        if first == '>' {
            cx.push(start, len, TokenKind::MarkupQuote);
            return;
        }
        if matches!(first, '-' | '*' | '_') {
            let rule = chars[start..]
                .iter()
                .all(|&c| c == first || c == ' ' || c == '\t');
            if rule && chars[start..].iter().filter(|&&c| c == first).count() >= 3 {
                cx.push(start, len, TokenKind::Punctuation);
                return;
            }
        }
        let table = first == '|';
        if table && chars[start..].iter().all(|&c| "|-: \t".contains(c)) {
            cx.push(start, len, TokenKind::Punctuation);
            return;
        }
        let mut i = start;
        if let Some(marker) = list_marker(chars, start) {
            cx.push(start, marker, TokenKind::MarkupList);
            i = scan_while(chars, marker, char::is_whitespace);
            let task = chars.get(i) == Some(&'[')
                && chars.get(i + 1).is_some_and(|&c| " xX".contains(c))
                && chars.get(i + 2) == Some(&']');
            if task {
                cx.push(i, i + 3, TokenKind::MarkupList);
                i += 3;
            }
        }
        inline(cx, i, table);
    }
}

/// A line inside a fenced code block opened as `state`: the closing fence,
/// or code in the fence's language.
fn code_line(cx: &mut Cx<'_>, state: u16, start: usize) {
    let chars = cx.chars();
    let len = chars.len();
    let mark = if state & fence::TILDE != 0 { '~' } else { '`' };
    let length = usize::from(state >> fence::LENGTH_SHIFT & fence::LENGTH);
    let run = scan_while(chars, start, |c| c == mark);
    let closes = start - cx.pos <= 3
        && run - start >= length
        && chars[run..].iter().all(|c| c.is_whitespace());
    if closes {
        cx.push(start, run, TokenKind::MarkupCode);
        return;
    }
    cx.set_state(state);
    let index = usize::from(state & fence::LANGUAGE);
    if let Some(language) = index.checked_sub(1).and_then(Language::by_index) {
        cx.embed_open(language_tag(language), language.lexer(), cx.pos, len, true);
    }
}

/// The end of a list marker (`- `, `* `, `+ `, `1. `, `1) `) at `i`.
fn list_marker(chars: &[char], i: usize) -> Option<usize> {
    let end = match chars[i] {
        '-' | '*' | '+' => i + 1,
        c if c.is_ascii_digit() => {
            let digits = scan_while(chars, i, |c| c.is_ascii_digit());
            if digits - i > 9 || !matches!(chars.get(digits), Some('.' | ')')) {
                return None;
            }
            digits + 1
        }
        _ => return None,
    };
    chars
        .get(end)
        .is_none_or(|c| c.is_whitespace())
        .then_some(end)
}

fn inline(cx: &mut Cx<'_>, from: usize, table: bool) {
    let chars = cx.chars();
    let len = chars.len();
    let mut i = from;
    while i < len {
        let c = chars[i];
        match c {
            '\\' if chars.get(i + 1).is_some_and(|n| n.is_ascii_punctuation()) => {
                cx.push(i, i + 2, TokenKind::StringEscape);
                i += 2;
            }
            '`' => {
                let run = scan_while(chars, i, |c| c == '`');
                let ticks = run - i;
                let close = (run..len).find(|&j| {
                    chars[j] == '`'
                        && scan_while(chars, j, |c| c == '`') - j == ticks
                        && chars[j - 1] != '`'
                });
                let end = close.map_or(len, |j| j + ticks);
                cx.push(i, end, TokenKind::MarkupCode);
                i = end;
            }
            '|' if table => {
                cx.push(i, i + 1, TokenKind::Punctuation);
                i += 1;
            }
            '!' | '[' => i = link(cx, i).unwrap_or(i + 1),
            '<' => i = angle(cx, i).unwrap_or(i + 1),
            '*' | '_' | '~' => {
                i = emphasis(cx, i).unwrap_or_else(|| scan_while(chars, i, |ch| ch == c))
            }
            'h' if cx.starts_with(i, "https://") || cx.starts_with(i, "http://") => {
                if i > 0 && is_ident(chars[i - 1]) {
                    i += 1;
                    continue;
                }
                let mut end = scan_while(chars, i, |c| !c.is_whitespace() && c != '<');
                while end > i && ".,;:!?)".contains(chars[end - 1]) {
                    end -= 1;
                }
                cx.push(i, end, TokenKind::MarkupLink);
                i = end;
            }
            _ => i += 1,
        }
    }
}

/// `[text](url)`, `![alt](src)`, `[text][ref]` and `[ref]: url`.
fn link(cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    let open = if chars[i] == '!' { i + 1 } else { i };
    if chars.get(open) != Some(&'[') {
        return None;
    }
    let close = (open + 1..chars.len()).find(|&j| chars[j] == ']')?;
    match chars.get(close + 1) {
        Some('(') => {
            let end = (close + 2..chars.len()).find(|&j| chars[j] == ')')?;
            cx.push(i, close + 1, TokenKind::MarkupLink);
            cx.push(close + 1, end + 1, TokenKind::String);
            Some(end + 1)
        }
        Some('[') => {
            let end = (close + 2..chars.len()).find(|&j| chars[j] == ']')?;
            cx.push(i, end + 1, TokenKind::MarkupLink);
            Some(end + 1)
        }
        Some(':') if cx.at_line_start(i) => {
            cx.push(i, close + 1, TokenKind::MarkupLink);
            let url = scan_while(chars, close + 2, char::is_whitespace);
            let url_end = scan_while(chars, url, |c| !c.is_whitespace());
            cx.push(url, url_end, TokenKind::String);
            Some(url_end)
        }
        _ => None,
    }
}

/// Autolinks (`<https://…>`) and HTML tags (`<br>`, `</div>`).
fn angle(cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    let close = (i + 1..chars.len()).find(|&j| chars[j] == '>' || chars[j] == '<')?;
    if chars[close] != '>' {
        return None;
    }
    let inner: String = chars[i + 1..close].iter().collect();
    if inner.contains("://") || (inner.contains('@') && !inner.contains(' ')) {
        cx.push(i, close + 1, TokenKind::MarkupLink);
        return Some(close + 1);
    }
    let name = inner.strip_prefix('/').unwrap_or(&inner);
    if name.starts_with(|c: char| c.is_ascii_alphabetic()) || inner.starts_with("!--") {
        cx.push(i, close + 1, TokenKind::Tag);
        return Some(close + 1);
    }
    None
}

/// `*em*`, `**strong**`, `_em_`, `__strong__`, `~~struck~~`: the run at `i`
/// and its matching run, with text between that does not start or end
/// with a space; `_` only outside words.
fn emphasis(cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    let c = chars[i];
    let run = scan_while(chars, i, |ch| ch == c);
    let n = run - i;
    if n > 3 || (c == '~' && n != 2) || chars.get(run).is_none_or(|ch| ch.is_whitespace()) {
        return None;
    }
    if c == '_' && i > 0 && is_ident(chars[i - 1]) {
        return None;
    }
    let mut j = run + 1;
    while j < chars.len() {
        if chars[j] == c {
            let end = scan_while(chars, j, |ch| ch == c);
            let closes = end - j == n
                && !chars[j - 1].is_whitespace()
                && !(c == '_' && chars.get(end).is_some_and(|&ch| is_ident(ch)));
            if closes {
                cx.push(i, end, TokenKind::MarkupEmphasis);
                return Some(end);
            }
            j = end;
            continue;
        }
        if chars[j] == '`' {
            // Code spans win over emphasis.
            return None;
        }
        j += 1;
    }
    None
}

pub static MARKDOWN: LanguageDef = LanguageDef {
    id: "markdown",
    name: "Markdown",
    extensions: &["md", "markdown", "mdx", "mdown", "mkd"],
    file_names: &[],
    shebangs: &[],
    lexer: &MarkdownLexer,
    hints: no_hints,
};
