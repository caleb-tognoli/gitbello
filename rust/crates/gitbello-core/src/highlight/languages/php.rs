use super::super::generic::{heredoc, matching, outside_code, Spec, SpecLexer, Str, BACKSLASH};
use super::super::kind::TokenKind;
use super::super::lexer::{language_tag, Cx, Lexer};
use super::super::scan::{ident_end, is_ident, scan_while, string_end, word_start};
use super::{markup, no_hints, Language, LanguageDef};

/// PHP code (between `<?php` and `?>`).
static SPEC: Spec = Spec {
    line_comments: &["//", "#"],
    block_comment: Some(("/*", "*/")),
    doc_blocks: true,
    strings: &[
        Str {
            dollar_names: true,
            ..Str::lines("\"", "\"", BACKSLASH)
        },
        Str {
            dollar_names: true,
            ..Str::lines("`", "`", BACKSLASH)
        },
        Str::lines("'", "'", BACKSLASH),
    ],
    keywords: &[
        "abstract",
        "and",
        "array",
        "as",
        "class",
        "clone",
        "const",
        "declare",
        "echo",
        "empty",
        "enum",
        "extends",
        "final",
        "fn",
        "function",
        "global",
        "implements",
        "include",
        "include_once",
        "instanceof",
        "insteadof",
        "interface",
        "isset",
        "list",
        "namespace",
        "new",
        "or",
        "parent",
        "print",
        "private",
        "protected",
        "public",
        "readonly",
        "require",
        "require_once",
        "self",
        "static",
        "trait",
        "unset",
        "use",
        "var",
        "xor",
    ],
    control_keywords: &[
        "break",
        "case",
        "catch",
        "continue",
        "default",
        "die",
        "do",
        "else",
        "elseif",
        "endfor",
        "endforeach",
        "endif",
        "endswitch",
        "endwhile",
        "exit",
        "finally",
        "for",
        "foreach",
        "goto",
        "if",
        "match",
        "return",
        "switch",
        "throw",
        "try",
        "while",
        "yield",
    ],
    types: &[
        "bool", "boolean", "callable", "double", "float", "int", "integer", "iterable", "mixed",
        "never", "object", "string", "void",
    ],
    constants: &["true", "false", "null"],
    case_insensitive: true,
    capitalized_types: true,
    caps_constants: true,
    calls: true,
    definitions: &[
        ("function", TokenKind::Function),
        ("class", TokenKind::Type),
        ("interface", TokenKind::Type),
        ("trait", TokenKind::Type),
        ("enum", TokenKind::Type),
        ("extends", TokenKind::Type),
        ("implements", TokenKind::Type),
        ("instanceof", TokenKind::Type),
    ],
    dollar_variables: true,
    hook: Some(php_words),
    resume: Some(php_resume),
    ..Spec::EMPTY
};

static HEREDOC: heredoc::Rules = heredoc::Rules {
    dollars: true,
    hash_interp: None,
    tail: true,
};

/// A heredoc going on from the line above.
fn php_resume(_spec: &'static Spec, cx: &mut Cx<'_>, state: u16) -> usize {
    if heredoc::is(state) {
        heredoc::resume(cx, state, &HEREDOC)
    } else {
        0
    }
}

/// `<?php`, `<?=` and `?>` as tags, `#[…]` attributes, heredoc openers
/// and the class after `new`.
fn php_words(_spec: &'static Spec, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    match chars[i] {
        '<' if cx.starts_with(i, "<<<") => {
            let at = i + 3;
            let quote = chars.get(at).copied().filter(|&q| q == '\'' || q == '"');
            let word = at + usize::from(quote.is_some());
            if !chars
                .get(word)
                .is_some_and(|&c| c.is_alphabetic() || c == '_')
            {
                return None;
            }
            let tag_end = ident_end(chars, word);
            let end = match quote {
                Some(q) => string_end(chars, at, q),
                None => tag_end,
            };
            let tag: String = chars[word..tag_end].iter().collect();
            cx.push(i, end, TokenKind::String);
            // A nowdoc (`<<<'EOT'`) is literal.
            heredoc::open(cx, &tag, quote == Some('\''));
            Some(end)
        }
        '<' if cx.starts_with(i, "<?") => {
            let end = if cx.starts_with(i, "<?=") {
                i + 3
            } else {
                let word = ident_end(chars, i + 2);
                let name: String = chars[i + 2..word].iter().collect();
                if name.eq_ignore_ascii_case("php") {
                    word
                } else {
                    i + 2
                }
            };
            cx.push(i, end, TokenKind::Tag);
            Some(end)
        }
        '?' if cx.starts_with(i, "?>") => {
            cx.push(i, i + 2, TokenKind::Tag);
            Some(i + 2)
        }
        '#' if cx.starts_with(i, "#[") => {
            let end = matching(chars, i + 2, ']').map_or(chars.len(), |j| j + 1);
            cx.push(i, end, TokenKind::Annotation);
            Some(end)
        }
        'n' | 'N' if word_start(chars, i) => {
            // `new \App\Thing(…)`: the class, with its namespace, is a type.
            let end = ident_end(chars, i);
            let word: String = chars[i..end].iter().collect();
            if !word.eq_ignore_ascii_case("new") {
                return None;
            }
            cx.push(i, end, TokenKind::Keyword);
            let at = scan_while(chars, end, char::is_whitespace);
            let name = scan_while(chars, at, |c| is_ident(c) || c == '\\');
            if chars
                .get(at)
                .is_some_and(|&c| c == '\\' || c.is_alphabetic())
            {
                cx.push(at, name, TokenKind::Type);
                Some(name)
            } else {
                Some(end)
            }
        }
        _ => None,
    }
}

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

/// [`Cx::state`] values of [`PhpFile`]: where the line above ended.
mod mode {
    /// Not known (a line lexed alone, or the file's start): PHP, unless
    /// the line starts with an HTML tag.
    pub const UNKNOWN: u16 = 0;
    pub const HTML: u16 = 1;
    pub const PHP: u16 = 2;
}

/// A PHP file: HTML (with its script and style blocks) around `<?php`,
/// `<?=` and `<?` … `?>` islands of PHP. Each keeps its own state across
/// lines, and HTML goes on after an island where it was before it on the
/// same line (`href="<?= $url ?>"`).
struct PhpFile;

/// The end of the PHP opener at `i` (`<?php`, `<?=`, `<?` before a space or
/// the end), if one starts there; `<?xml` is not one.
fn opener_end(cx: &Cx<'_>, i: usize) -> Option<usize> {
    if !cx.starts_with(i, "<?") {
        return None;
    }
    if cx.starts_with(i, "<?=") {
        return Some(i + 3);
    }
    let word = ident_end(cx.chars(), i + 2);
    let name: String = cx.chars()[i + 2..word].iter().collect();
    if name.eq_ignore_ascii_case("php") {
        Some(word)
    } else if word == i + 2 && cx.at(i + 2).is_none_or(char::is_whitespace) {
        Some(i + 2)
    } else {
        None
    }
}

/// True when the line's first character after spaces opens an HTML tag.
fn starts_with_tag(cx: &Cx<'_>) -> bool {
    let at = scan_while(cx.chars(), cx.pos, char::is_whitespace);
    cx.at(at) == Some('<')
        && cx
            .at(at + 1)
            .is_some_and(|c| c.is_alphabetic() || c == '/' || c == '!')
}

impl Lexer for PhpFile {
    fn lex(&self, cx: &mut Cx<'_>) {
        let len = cx.len();
        let Some(html) = Language::by_id("html") else {
            return;
        };
        let (html_tag, php_tag) = (language_tag(html), mode::PHP);
        let mut mode = match cx.state() {
            mode::UNKNOWN if starts_with_tag(cx) => mode::HTML,
            mode::UNKNOWN => mode::PHP,
            known => known,
        };
        let mut pos = cx.pos;
        // HTML's state where an island started on this line.
        let mut html_before: Option<Option<super::super::LineState>> = None;
        loop {
            if mode == mode::HTML {
                let open = (pos..len).find_map(|j| opener_end(cx, j).map(|end| (j, end)));
                let html_end = open.map_or(len, |(j, _)| j);
                if let Some(saved) = html_before.take() {
                    cx.set_nested(saved);
                }
                cx.embed_open(
                    html_tag,
                    &markup::MarkupLexer { html: true },
                    pos,
                    html_end,
                    true,
                );
                let Some((at, end)) = open else {
                    break;
                };
                html_before = Some(cx.nested());
                cx.push(at, end, TokenKind::Tag);
                pos = end;
                mode = mode::PHP;
            } else {
                // Lexed up to each `?>` in turn until one is outside strings
                // and block comments, then again up to it (so each island is
                // lexed about twice, not to the line's end).
                let before = cx.nested();
                let mark = cx.token_count();
                let mut close = None;
                let mut from = pos;
                while let Some(c) = (from..len.saturating_sub(1)).find(|&j| cx.starts_with(j, "?>"))
                {
                    cx.embed_open(php_tag, &LEXER, pos, c + 2, true);
                    let code = outside_code(cx, mark, c, c + 1, &["//", "#"])
                        .next()
                        .is_some();
                    cx.truncate(mark);
                    cx.set_nested(before);
                    if code {
                        close = Some(c);
                        break;
                    }
                    from = c + 2;
                }
                let Some(close) = close else {
                    cx.embed_open(php_tag, &LEXER, pos, len, true);
                    break;
                };
                cx.embed_open(php_tag, &LEXER, pos, close, true);
                cx.push(close, close + 2, TokenKind::Tag);
                pos = close + 2;
                mode = mode::HTML;
                if html_before.is_none() {
                    html_before = Some(None);
                }
            }
        }
        cx.pos = len;
        cx.set_state(mode);
    }
}

static FILE: PhpFile = PhpFile;

pub static PHP: LanguageDef = LanguageDef {
    id: "php",
    name: "PHP",
    extensions: &["php", "phtml", "php3", "php4", "php5", "phps"],
    file_names: &[],
    shebangs: &["php"],
    lexer: &FILE,
    hints: no_hints,
};
