use super::super::generic::{dollar_end, lex_str, Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::super::lexer::{Cx, Lexer};
use super::super::scan::{is_ident, scan_while};
use super::{no_hints, Language, LanguageDef};

/// An exec form's `["cmd", "arg"]`: a command line, so its strings keep
/// their colour (JSON leaves values plain).
static EXEC_SPEC: Spec = Spec {
    strings: &[Str::new("\"", "\"", BACKSLASH)],
    ..Spec::EMPTY
};

static EXEC: SpecLexer = SpecLexer::new(&EXEC_SPEC);

static INSTRUCTIONS: &[&str] = &[
    "add",
    "arg",
    "cmd",
    "copy",
    "entrypoint",
    "env",
    "expose",
    "from",
    "healthcheck",
    "label",
    "maintainer",
    "onbuild",
    "run",
    "shell",
    "stopsignal",
    "user",
    "volume",
    "workdir",
];

static STRING: Str = Str {
    dollar_names: true,
    ..Str::new("\"", "\"", BACKSLASH)
};
static SINGLE: Str = Str::new("'", "'", BACKSLASH);

/// Instructions as keywords; the shell form of `RUN`, `CMD`, `ENTRYPOINT`
/// (and lines that continue one) as Shell, their exec form as strings;
/// `--flags` as attributes, `ARG`/`ENV` names as variables, `LABEL` keys
/// as keys, the `FROM` image and stage as types, parser directives as
/// annotations.
struct DockerfileLexer;

impl Lexer for DockerfileLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let chars = cx.chars();
        let len = chars.len();
        let start = scan_while(chars, cx.pos, char::is_whitespace);
        cx.pos = len;
        if start >= len {
            return;
        }
        if chars[start] == '#' {
            let text: String = chars[start + 1..]
                .iter()
                .collect::<String>()
                .trim()
                .to_lowercase();
            let directive = ["syntax=", "escape=", "check="]
                .iter()
                .any(|d| text.starts_with(d));
            let kind = if directive {
                TokenKind::Annotation
            } else {
                TokenKind::Comment
            };
            cx.push(start, len, kind);
            return;
        }
        let mut i = start;
        let mut word_end = scan_while(chars, i, |c| c.is_ascii_alphabetic());
        let mut word: String = chars[i..word_end].iter().collect::<String>().to_lowercase();
        if word == "onbuild" {
            cx.push(i, word_end, TokenKind::Keyword);
            i = scan_while(chars, word_end, char::is_whitespace);
            word_end = scan_while(chars, i, |c| c.is_ascii_alphabetic());
            word = chars[i..word_end].iter().collect::<String>().to_lowercase();
        }
        let spaced = chars.get(word_end).is_none_or(|c| c.is_whitespace());
        if !INSTRUCTIONS.contains(&word.as_str()) || !spaced {
            // A continuation line, nearly always of a `RUN`.
            embed_shell(cx, start);
            return;
        }
        cx.push(i, word_end, TokenKind::Keyword);
        let mut i = flags(cx, word_end);
        match word.as_str() {
            "run" | "cmd" | "entrypoint" | "shell" => {
                if chars.get(i) == Some(&'[') {
                    cx.embed_with(&EXEC, i, len);
                } else {
                    embed_shell(cx, i);
                }
            }
            "healthcheck" => {
                let cmd_end = scan_while(chars, i, |c| c.is_ascii_alphabetic());
                if chars[i..cmd_end]
                    .iter()
                    .collect::<String>()
                    .eq_ignore_ascii_case("cmd")
                {
                    cx.push(i, cmd_end, TokenKind::Keyword);
                    embed_shell(cx, cmd_end);
                } else {
                    args(cx, i, None);
                }
            }
            "from" => {
                let image_end = scan_while(chars, i, |c| !c.is_whitespace());
                cx.push(i, image_end, TokenKind::Type);
                i = scan_while(chars, image_end, char::is_whitespace);
                let as_end = scan_while(chars, i, |c| c.is_ascii_alphabetic());
                if chars[i..as_end]
                    .iter()
                    .collect::<String>()
                    .eq_ignore_ascii_case("as")
                {
                    cx.push(i, as_end, TokenKind::Keyword);
                    let name = scan_while(chars, as_end, char::is_whitespace);
                    let name_end = scan_while(chars, name, |c| !c.is_whitespace());
                    cx.push(name, name_end, TokenKind::Type);
                }
            }
            "arg" | "env" => args(cx, i, Some(TokenKind::Variable)),
            "label" => args(cx, i, Some(TokenKind::Key)),
            _ => args(cx, i, None),
        }
    }
}

fn embed_shell(cx: &mut Cx<'_>, from: usize) {
    if let Some(shell) = Language::by_id("shell") {
        let len = cx.len();
        cx.embed(shell, from, len);
    }
}

/// `--flag=value` options after an instruction; returns where they end.
fn flags(cx: &mut Cx<'_>, from: usize) -> usize {
    let chars = cx.chars();
    let mut i = scan_while(chars, from, char::is_whitespace);
    while cx.starts_with(i, "--") {
        let name_end = scan_while(chars, i + 2, |c| is_ident(c) || c == '-');
        cx.push(i, name_end, TokenKind::Attribute);
        let end = scan_while(chars, name_end, |c| !c.is_whitespace());
        i = scan_while(chars, end, char::is_whitespace);
    }
    i
}

/// Arguments: strings, `$VAR`s and, with `names`, the `NAME` of each
/// `NAME=value` (or of `ENV NAME value`).
fn args(cx: &mut Cx<'_>, from: usize, names: Option<TokenKind>) {
    let chars = cx.chars();
    let len = chars.len();
    let mut i = from;
    let mut first = true;
    while i < len {
        let c = chars[i];
        if c.is_whitespace() {
            i += 1;
            continue;
        }
        if c == '"' || c == '\'' {
            let rule = if c == '"' { &STRING } else { &SINGLE };
            i = lex_str(cx, rule, i, i + 1, rule.close, TokenKind::String, false);
            first = false;
            continue;
        }
        if c == '$' {
            let end = dollar_end(chars, i);
            cx.push(i, end, TokenKind::Variable);
            i = end.max(i + 1);
            continue;
        }
        if let Some(kind) = names {
            if is_ident(c) && (i == 0 || chars[i - 1].is_whitespace()) {
                let end = scan_while(chars, i, |ch| is_ident(ch) || ch == '.' || ch == '-');
                if chars.get(end) == Some(&'=')
                    || (first && chars.get(end).is_none_or(|n| n.is_whitespace()))
                {
                    cx.push(i, end, kind);
                    i = end;
                    first = false;
                    continue;
                }
            }
        }
        if c.is_ascii_digit() && (i == 0 || chars[i - 1].is_whitespace()) {
            let end = scan_while(chars, i, |ch| ch.is_ascii_digit() || ch == '.');
            if chars
                .get(end)
                .is_none_or(|n| n.is_whitespace() || *n == '/')
            {
                cx.push(i, end, TokenKind::Number);
            }
            i = end;
            continue;
        }
        first = false;
        i += 1;
    }
}

pub static DOCKERFILE: LanguageDef = LanguageDef {
    id: "dockerfile",
    name: "Dockerfile",
    extensions: &["dockerfile", "containerfile"],
    file_names: &["dockerfile", "containerfile"],
    shebangs: &[],
    lexer: &DockerfileLexer,
    hints: no_hints,
};
