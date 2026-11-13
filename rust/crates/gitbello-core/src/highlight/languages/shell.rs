use super::super::generic::{heredoc, matching, Escape, Interp, Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::super::lexer::Cx;
use super::super::scan::{ident_end, is_ident, scan_while};
use super::{no_hints, Language, LanguageDef};

static SPEC: Spec = Spec {
    line_comments: &["#"],
    strings: &[
        Str::lines("$'", "'", BACKSLASH),
        Str {
            interps: &[Interp {
                open: "$(",
                close: ')',
                language: "shell",
            }],
            dollar_names: true,
            ..Str::lines("\"", "\"", BACKSLASH)
        },
        Str::lines("'", "'", Escape::None),
        Str::lines("`", "`", BACKSLASH),
    ],
    keywords: &[
        "alias", "declare", "export", "function", "in", "local", "readonly", "typeset", "unset",
    ],
    control_keywords: &[
        "break", "case", "continue", "do", "done", "elif", "else", "esac", "exit", "fi", "for",
        "if", "return", "select", "then", "until", "while",
    ],
    constants: &["true", "false"],
    functions: &[
        "cd", "echo", "eval", "exec", "printf", "read", "set", "shift", "source", "test", "trap",
        "wait",
    ],
    calls: true,
    definitions: &[("function", TokenKind::Function)],
    comment_after_space: true,
    dollar_variables: true,
    hook: Some(shell_words),
    resume: Some(shell_resume),
    ..Spec::EMPTY
};

static HEREDOC: heredoc::Rules = heredoc::Rules {
    dollars: true,
    hash_interp: None,
    tail: false,
};

/// The body and end line of a heredoc.
fn shell_resume(_spec: &'static Spec, cx: &mut Cx<'_>, state: u16) -> usize {
    if heredoc::is(state) {
        heredoc::resume(cx, state, &HEREDOC)
    } else {
        0
    }
}

/// A heredoc opener at `i` (`<<EOF`, `<<-EOF`, `<<'EOF'`): pushes it as a
/// string and leaves the next lines in its body.
fn heredoc_opener(cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    if !cx.starts_with(i, "<<") || cx.starts_with(i, "<<<") {
        return None;
    }
    let mut at = i + 2;
    if chars.get(at) == Some(&'-') {
        at += 1;
    }
    at = scan_while(chars, at, |c| c == ' ');
    let quote = chars.get(at).copied().filter(|&q| q == '\'' || q == '"');
    let word = if quote.is_some() { at + 1 } else { at };
    let end = ident_end(chars, word);
    if end == word {
        return None;
    }
    let tag: String = chars[word..end].iter().collect();
    let close = if quote.is_some() && chars.get(end).copied() == quote {
        end + 1
    } else {
        end
    };
    cx.push(i, close, TokenKind::String);
    heredoc::open(cx, &tag, quote.is_some());
    Some(close)
}

/// Heredoc openers, command substitution, assignments and options.
fn shell_words(_spec: &'static Spec, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    let c = chars[i];
    let spaced = i == 0 || chars[i - 1].is_whitespace();
    if c == '<' {
        return heredoc_opener(cx, i);
    }
    if c == '$' && chars.get(i + 1) == Some(&'(') {
        let inner = i + 2;
        let end = matching(chars, inner, ')');
        let close = end.unwrap_or(chars.len());
        // `$(NAME)` with one word in it is a Make variable in a recipe.
        if end.is_some() && (inner..close).all(|j| is_ident(chars[j]) || "@<^*".contains(chars[j]))
        {
            cx.push(i, close + 1, TokenKind::Variable);
            return Some(close + 1);
        }
        cx.push(i, inner, TokenKind::StringInterpolation);
        if let Some(shell) = Language::by_id("shell") {
            cx.embed(shell, inner, close);
        }
        return Some(match end {
            Some(e) => {
                cx.push(e, e + 1, TokenKind::StringInterpolation);
                e + 1
            }
            None => chars.len(),
        });
    }
    if spaced
        && c == '-'
        && chars
            .get(i + 1)
            .is_some_and(|&n| n.is_alphabetic() || n == '-')
    {
        let end = scan_while(chars, i + 1, |ch| is_ident(ch) || ch == '-');
        cx.push(i, end, TokenKind::Attribute);
        return Some(end);
    }
    if (c.is_alphabetic() || c == '_') && (spaced || i == cx.pos) {
        let end = ident_end(chars, i);
        if chars.get(end) == Some(&'=') || cx.starts_with(end, "+=") {
            cx.push(i, end, TokenKind::Variable);
            return Some(end);
        }
    }
    None
}

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static SHELL: LanguageDef = LanguageDef {
    id: "shell",
    name: "Shell",
    extensions: &["sh", "bash", "zsh", "fish", "ksh"],
    file_names: &[
        ".bashrc",
        ".bash_profile",
        ".bash_aliases",
        ".bash_logout",
        ".zshrc",
        ".zprofile",
        ".zshenv",
        ".profile",
        ".envrc",
    ],
    shebangs: &["sh", "bash", "zsh", "dash", "ksh", "fish"],
    lexer: &LEXER,
    hints: no_hints,
};
