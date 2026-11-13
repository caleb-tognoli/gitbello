use super::super::generic::matching;
use super::super::kind::TokenKind;
use super::super::lexer::{Cx, Lexer};
use super::super::scan::{is_ident, scan_while};
use super::{no_hints, Language, LanguageDef};

/// Make's own functions (`$(patsubst …)`).
static FUNCTIONS: &[&str] = &[
    "abspath",
    "addprefix",
    "addsuffix",
    "and",
    "basename",
    "call",
    "dir",
    "error",
    "eval",
    "file",
    "filter",
    "filter-out",
    "findstring",
    "firstword",
    "flavor",
    "foreach",
    "if",
    "info",
    "intcmp",
    "join",
    "lastword",
    "let",
    "notdir",
    "or",
    "origin",
    "patsubst",
    "realpath",
    "shell",
    "sort",
    "strip",
    "subst",
    "suffix",
    "value",
    "warning",
    "wildcard",
    "word",
    "wordlist",
    "words",
];

static DIRECTIVES: &[&str] = &[
    "include", "-include", "sinclude", "define", "endef", "export", "unexport", "override",
    "private", "undefine", "vpath",
];

static CONDITIONALS: &[&str] = &["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif"];

/// Recipe lines (indented) as Shell; targets as functions, variables
/// (assigned and `$(VAR)`, `$@`) as variables, directives as keywords.
struct MakefileLexer;

impl Lexer for MakefileLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let chars = cx.chars();
        let len = chars.len();
        let from = cx.pos;
        cx.pos = len;
        let start = scan_while(chars, from, char::is_whitespace);
        if chars.get(start) == Some(&'#') {
            cx.push(start, len, TokenKind::Comment);
            return;
        }
        let word_end = scan_while(chars, start, |c| !c.is_whitespace());
        let word: String = chars[start..word_end].iter().collect();
        let mut i = start;
        let mut directive = true;
        if CONDITIONALS.contains(&word.as_str()) {
            cx.push(start, word_end, TokenKind::KeywordControl);
            i = word_end;
        } else if DIRECTIVES.contains(&word.as_str()) {
            cx.push(start, word_end, TokenKind::Keyword);
            i = word_end;
        } else {
            directive = false;
        }
        // `NAME = value` (also `:=`, `::=`, `?=`, `+=`, `!=`) or
        // `targets: prerequisites`.
        let name_start = scan_while(chars, i, char::is_whitespace);
        let name_end = scan_while(chars, name_start, |c| is_ident(c) || ".-/%$()*".contains(c));
        let op_at = scan_while(chars, name_end, char::is_whitespace);
        let op_end = scan_while(chars, op_at, |c| ":?+!=".contains(c));
        let op: String = chars[op_at..op_end].iter().collect();
        if name_end > name_start && op.ends_with('=') {
            cx.push(name_start, name_end, TokenKind::Variable);
            cx.push(op_at, op_end, TokenKind::Operator);
            text(cx, op_end, len);
            return;
        }
        // Tabs reach lexers as spaces, so an indented line that is no
        // directive or assignment is a recipe.
        if start > from && !directive {
            let body = scan_while(chars, start, |c| "@-+".contains(c));
            cx.push(start, body, TokenKind::Operator);
            if let Some(shell) = Language::by_id("shell") {
                cx.embed(shell, body, len);
            }
            return;
        }
        let colon = (i..len).find(|&j| {
            chars[j] == ':' && chars.get(j + 1) != Some(&'=') && !(j > 0 && chars[j - 1] == '$')
        });
        if let (Some(colon), true) = (colon, i == start) {
            let mut j = start;
            while j < colon {
                if chars[j] == '$' {
                    j = variable(cx, j);
                    continue;
                }
                let end = scan_while(chars, j, |c| !c.is_whitespace() && c != ':' && c != '$');
                let target: String = chars[j..end].iter().collect();
                let kind = if target.starts_with('.')
                    && target
                        .chars()
                        .skip(1)
                        .all(|c| c.is_ascii_uppercase() || c == '_')
                {
                    TokenKind::Keyword
                } else {
                    TokenKind::Function
                };
                cx.push(j, end.min(colon), kind);
                j = scan_while(chars, end, char::is_whitespace).max(j + 1);
            }
            let after = scan_while(chars, colon, |c| c == ':');
            cx.push(colon, after, TokenKind::Operator);
            match (after..len).find(|&j| chars[j] == ';') {
                Some(semi) => {
                    text(cx, after, semi);
                    if let Some(shell) = Language::by_id("shell") {
                        cx.embed(shell, semi + 1, len);
                    }
                }
                None => text(cx, after, len),
            }
            return;
        }
        text(cx, i, len);
    }
}

/// Text with variables and function calls, and a trailing comment.
fn text(cx: &mut Cx<'_>, from: usize, to: usize) {
    let chars = cx.chars();
    let mut i = from;
    while i < to {
        match chars[i] {
            '$' => i = variable(cx, i),
            '#' if i == 0 || chars[i - 1] != '\\' => {
                cx.push(i, to, TokenKind::Comment);
                return;
            }
            _ => i += 1,
        }
    }
}

/// `$(VAR)`, `${VAR}`, `$@`, `$$`, or a function call `$(name args)`.
fn variable(cx: &mut Cx<'_>, i: usize) -> usize {
    let chars = cx.chars();
    let len = chars.len();
    let Some(&open) = chars.get(i + 1) else {
        return len;
    };
    if open != '(' && open != '{' {
        cx.push(i, i + 2, TokenKind::Variable);
        return i + 2;
    }
    let close_char = if open == '(' { ')' } else { '}' };
    let inner = i + 2;
    let close = matching(chars, inner, close_char).unwrap_or(len);
    let name_end = scan_while(chars, inner, |c| is_ident(c) || c == '-');
    let name: String = chars[inner..name_end].iter().collect();
    let spaced = chars.get(name_end).is_some_and(|c| c.is_whitespace());
    if spaced && FUNCTIONS.contains(&name.as_str()) {
        cx.push(i, inner, TokenKind::Variable);
        cx.push(inner, name_end, TokenKind::Function);
        text(cx, name_end, close);
        cx.push(close, close + 1, TokenKind::Variable);
    } else {
        cx.push(i, close + 1, TokenKind::Variable);
    }
    close + 1
}

pub static MAKEFILE: LanguageDef = LanguageDef {
    id: "makefile",
    name: "Makefile",
    extensions: &["mk", "mak", "make"],
    file_names: &["makefile", "gnumakefile"],
    shebangs: &["make"],
    lexer: &MakefileLexer,
    hints: no_hints,
};
