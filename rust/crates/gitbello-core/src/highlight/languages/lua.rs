use super::super::generic::{Spec, SpecLexer, Str, BACKSLASH, HOOK_STATE};
use super::super::kind::TokenKind;
use super::super::lexer::Cx;
use super::super::scan::{ident_end, is_ident, scan_while};
use super::{no_hints, LanguageDef};

static SPEC: Spec = Spec {
    line_comments: &["--"],
    doc_comments: &["---"],
    strings: &[
        Str::new("\"", "\"", BACKSLASH),
        Str::new("'", "'", BACKSLASH),
    ],
    keywords: &[
        "and", "do", "end", "function", "in", "local", "not", "or", "then",
    ],
    control_keywords: &[
        "break", "else", "elseif", "for", "goto", "if", "repeat", "return", "until", "while",
    ],
    constants: &["true", "false", "nil"],
    variables: &["self", "_G", "_ENV"],
    functions: &[
        "assert",
        "collectgarbage",
        "dofile",
        "error",
        "getmetatable",
        "ipairs",
        "load",
        "loadfile",
        "next",
        "pairs",
        "pcall",
        "print",
        "rawequal",
        "rawget",
        "rawlen",
        "rawset",
        "require",
        "select",
        "setmetatable",
        "tonumber",
        "tostring",
        "type",
        "unpack",
        "xpcall",
    ],
    calls: true,
    hook: Some(lua_words),
    resume: Some(lua_resume),
    ..Spec::EMPTY
};

/// The long bracket opening at `i` (`[[`, `[==[`): where its body starts
/// and its closer (`]]`, `]==]`).
fn long_bracket(chars: &[char], i: usize) -> Option<(usize, String)> {
    if chars.get(i) != Some(&'[') {
        return None;
    }
    let level = scan_while(chars, i + 1, |c| c == '=') - (i + 1);
    (chars.get(i + 1 + level) == Some(&'['))
        .then(|| (i + level + 2, format!("]{}]", "=".repeat(level))))
}

/// In a long comment rather than a long string.
const LONG_COMMENT: u16 = 0x100;

/// A long comment or string from `start` whose body starts at `body`, up to
/// `close`; when it does not close on the line, the next line goes on in it.
fn long(cx: &mut Cx<'_>, start: usize, body: usize, close: &str, comment: bool) -> usize {
    let chars = cx.chars();
    let close_len = close.chars().count();
    let at = (body..chars.len()).find(|&j| cx.starts_with(j, close));
    let end = at.map_or(chars.len(), |j| j + close_len);
    let kind = if comment {
        TokenKind::Comment
    } else {
        TokenKind::String
    };
    cx.push(start, end, kind);
    if at.is_none() {
        let level = u16::try_from(close_len - 2).unwrap_or(0xFF).min(0xFF);
        cx.set_state(HOOK_STATE | if comment { LONG_COMMENT } else { 0 } | level);
    }
    end
}

/// A long comment or string going on from the line above.
fn lua_resume(_spec: &'static Spec, cx: &mut Cx<'_>, state: u16) -> usize {
    let close = format!("]{}]", "=".repeat(usize::from(state & 0xFF)));
    long(cx, 0, 0, &close, state & LONG_COMMENT != 0)
}

/// A first-line shebang, long comments (`--[[ … ]]`) and strings
/// (`[[ … ]]`), `::labels::` and the `<const>`/`<close>` attributes.
fn lua_words(_spec: &'static Spec, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    match chars[i] {
        '#' if i == 0 && cx.starts_with(0, "#!") => {
            cx.push(0, chars.len(), TokenKind::Comment);
            Some(chars.len())
        }
        '-' if cx.starts_with(i, "--") => {
            let (body, close) = long_bracket(chars, i + 2)?;
            Some(long(cx, i, body, &close, true))
        }
        '[' => {
            let (body, close) = long_bracket(chars, i)?;
            Some(long(cx, i, body, &close, false))
        }
        ':' if cx.starts_with(i, "::") => {
            let name = scan_while(chars, i + 2, char::is_whitespace);
            let end = ident_end(chars, name);
            let close = scan_while(chars, end, char::is_whitespace);
            (end > name && cx.starts_with(close, "::")).then(|| {
                cx.push(i, close + 2, TokenKind::Annotation);
                close + 2
            })
        }
        '<' => {
            let end = ident_end(chars, i + 1);
            let word: String = chars[i + 1..end].iter().collect();
            let attribute = matches!(word.as_str(), "const" | "close")
                && chars.get(end) == Some(&'>')
                && i > 0
                && !is_ident(chars[i - 1]);
            attribute.then(|| {
                cx.push(i, end + 1, TokenKind::Annotation);
                end + 1
            })
        }
        _ => None,
    }
}

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static LUA: LanguageDef = LanguageDef {
    id: "lua",
    name: "Lua",
    extensions: &["lua", "rockspec"],
    file_names: &[".luacheckrc"],
    shebangs: &["lua", "luajit"],
    lexer: &LEXER,
    hints: no_hints,
};
