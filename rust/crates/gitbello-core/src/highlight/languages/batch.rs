use super::super::generic::{Spec, SpecLexer};
use super::super::kind::TokenKind;
use super::super::lexer::Cx;
use super::super::scan::{ident_end, is_ident, scan_while, word_start};
use super::{no_hints, LanguageDef};

static SPEC: Spec = Spec {
    keywords: &[
        "assoc",
        "attrib",
        "cd",
        "chdir",
        "choice",
        "cls",
        "color",
        "copy",
        "defined",
        "del",
        "dir",
        "disabledelayedexpansion",
        "do",
        "echo",
        "enabledelayedexpansion",
        "enableextensions",
        "endlocal",
        "equ",
        "erase",
        "errorlevel",
        "exist",
        "geq",
        "gtr",
        "in",
        "leq",
        "lss",
        "md",
        "mkdir",
        "mklink",
        "move",
        "neq",
        "not",
        "nul",
        "path",
        "pause",
        "popd",
        "prompt",
        "pushd",
        "rd",
        "ren",
        "rename",
        "rmdir",
        "set",
        "setlocal",
        "shift",
        "start",
        "title",
        "type",
        "ver",
        "xcopy",
    ],
    control_keywords: &["call", "else", "exit", "for", "goto", "if"],
    case_insensitive: true,
    hook: Some(batch_words),
    ..Spec::EMPTY
};

/// `REM` and `::` comments, `:labels` (and `goto :label`) as functions,
/// `%VAR%`, `%1`, `%~dp0`, `%%i` and `!VAR!` as variables, quoted strings,
/// `/switches` as attributes, and the text of `echo`, `title` and `set`
/// (with `set`'s name as a variable).
fn batch_words(_spec: &'static Spec, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    let len = chars.len();
    let c = chars[i];
    let first = cx.at_line_start(i);
    match c {
        ':' if first && cx.starts_with(i, "::") => {
            cx.push(i, len, TokenKind::Comment);
            Some(len)
        }
        ':' if first || (i > 0 && chars[i - 1].is_whitespace()) => {
            let end = ident_end(chars, i + 1);
            (end > i + 1).then(|| {
                cx.push(i, end, TokenKind::Function);
                end
            })
        }
        '%' | '!' => {
            let end = variable_end(chars, i)?;
            cx.push(i, end, TokenKind::Variable);
            Some(end)
        }
        '"' => {
            let end = (i + 1..len)
                .find(|&j| chars[j] == '"')
                .map_or(len, |j| j + 1);
            text(cx, i, end, Some(TokenKind::String));
            Some(end)
        }
        '/' if i > 0 && chars[i - 1].is_whitespace() => {
            let next = chars.get(i + 1).copied();
            if !next.is_some_and(|n| n.is_alphabetic() || n == '?') {
                return None;
            }
            let end = scan_while(chars, i + 2, is_ident);
            cx.push(i, end, TokenKind::Attribute);
            Some(end)
        }
        _ if c.is_alphabetic() && word_start(chars, i) => {
            let end = ident_end(chars, i);
            let word: String = chars[i..end].iter().collect::<String>().to_lowercase();
            let after = chars.get(end).copied();
            let spaced = after.is_none_or(char::is_whitespace);
            match word.as_str() {
                "rem" if spaced => {
                    cx.push(i, len, TokenKind::Comment);
                    Some(len)
                }
                "echo" | "title" if spaced || matches!(after, Some('.' | ':' | '(')) => {
                    cx.push(i, end, TokenKind::Keyword);
                    let stop = command_end(chars, end);
                    let rest: String = chars[end..stop].iter().collect::<String>();
                    if matches!(rest.trim().to_lowercase().as_str(), "on" | "off") {
                        let at = scan_while(chars, end, char::is_whitespace);
                        cx.push(at, at + rest.trim().chars().count(), TokenKind::Keyword);
                    } else {
                        text(cx, end, stop, None);
                    }
                    Some(stop)
                }
                "set" if spaced => Some(set_command(cx, i, end)),
                _ => None,
            }
        }
        _ => None,
    }
}

/// `set [/a|/p] ["]NAME=value["]` from `i` (`set` ends at `end`).
fn set_command(cx: &mut Cx<'_>, i: usize, end: usize) -> usize {
    let chars = cx.chars();
    let len = chars.len();
    cx.push(i, end, TokenKind::Keyword);
    let mut j = scan_while(chars, end, char::is_whitespace);
    if chars.get(j) == Some(&'/') && chars.get(j + 1).is_some_and(|c| c.is_alphabetic()) {
        cx.push(j, j + 2, TokenKind::Attribute);
        j = scan_while(chars, j + 2, char::is_whitespace);
    }
    let quoted = chars.get(j) == Some(&'"');
    let stop = if quoted {
        (j + 1..len)
            .find(|&k| chars[k] == '"')
            .map_or(len, |k| k + 1)
    } else {
        command_end(chars, j)
    };
    let name = if quoted { j + 1 } else { j };
    let Some(eq) = (name..stop).find(|&k| chars[k] == '=') else {
        // `set` alone or `set prefix` lists variables.
        text(cx, j, stop, None);
        return stop;
    };
    if quoted {
        cx.push(j, name, TokenKind::String);
    }
    // `set /a COUNT+=1`: the operator before `=` is not part of the name.
    let op = (name..eq)
        .rfind(|&k| is_ident(chars[k]))
        .map_or(name, |k| k + 1);
    cx.push(name, op, TokenKind::Variable);
    cx.push(op, eq + 1, TokenKind::Operator);
    text(cx, eq + 1, stop, quoted.then_some(TokenKind::String));
    stop
}

/// Where the command at `from` ends: at `&`, `|`, `<` or `>` not escaped
/// by `^`, or the line end.
fn command_end(chars: &[char], from: usize) -> usize {
    let mut j = from;
    while j < chars.len() {
        match chars[j] {
            '^' => j += 2,
            '&' | '|' | '<' | '>' => return j,
            _ => j += 1,
        }
    }
    chars.len()
}

/// Text in `[from, to)` with its variables and `^` escapes, the rest as
/// `base` when given.
fn text(cx: &mut Cx<'_>, from: usize, to: usize, base: Option<TokenKind>) {
    let chars = cx.chars();
    let mut seg = from;
    let mut j = from;
    while j < to {
        if chars[j] == '^' && j + 1 < to {
            if let Some(base) = base {
                cx.push(seg, j, base);
            }
            cx.push(j, j + 2, TokenKind::StringEscape);
            j += 2;
            seg = j;
            continue;
        }
        if matches!(chars[j], '%' | '!') {
            if let Some(end) = variable_end(chars, j).filter(|&e| e <= to) {
                if let Some(base) = base {
                    cx.push(seg, j, base);
                }
                cx.push(j, end, TokenKind::Variable);
                j = end;
                seg = j;
                continue;
            }
        }
        j += 1;
    }
    if let Some(base) = base {
        cx.push(seg, to, base);
    }
}

/// The end of the variable at `i` (`%NAME%`, `%NAME:~0,5%`, `%1`, `%*`,
/// `%~dp0`, `%%i`, `%%~nxi`, `!NAME!`), if one starts there.
fn variable_end(chars: &[char], i: usize) -> Option<usize> {
    let len = chars.len();
    let next = *chars.get(i + 1)?;
    if chars[i] == '!' {
        let close = (i + 1..len).find(|&j| chars[j] == '!' || chars[j].is_whitespace())?;
        return (chars[close] == '!' && close > i + 1 && next.is_alphabetic()).then_some(close + 1);
    }
    match next {
        '%' => {
            // `%%i`, `%%~nxi`: a for loop's variable.
            let at = i + 2;
            let letter = if chars.get(at) == Some(&'~') {
                scan_while(chars, at + 1, char::is_alphabetic).checked_sub(1)?
            } else {
                at
            };
            chars
                .get(letter)
                .is_some_and(|c| c.is_alphabetic())
                .then_some(letter + 1)
        }
        '~' => {
            // `%~dp0`, `%~1`.
            let digit = scan_while(chars, i + 2, char::is_alphabetic);
            chars
                .get(digit)
                .is_some_and(|c| c.is_ascii_digit())
                .then_some(digit + 1)
        }
        '*' => Some(i + 2),
        c if c.is_ascii_digit() => Some(i + 2),
        c if c.is_alphabetic() || c == '_' => {
            let close = (i + 1..len).find(|&j| chars[j] == '%')?;
            Some(close + 1)
        }
        _ => None,
    }
}

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static BATCH: LanguageDef = LanguageDef {
    id: "batch",
    name: "Batch",
    extensions: &["bat", "cmd"],
    file_names: &[],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
