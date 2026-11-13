use super::super::generic::{
    dollar_end, heredoc, matching, Interp, Spec, SpecLexer, Str, BACKSLASH, HOOK_STATE,
};
use super::super::kind::TokenKind;
use super::super::lexer::Cx;
use super::super::scan::{ident_end, is_ident, string_end, word_start};
use super::{no_hints, LanguageDef};

static INTERP: &[Interp] = &[Interp {
    open: "#{",
    close: '}',
    language: "ruby",
}];

static SPEC: Spec = Spec {
    line_comments: &["#"],
    strings: &[
        Str {
            interps: INTERP,
            ..Str::lines("\"", "\"", BACKSLASH)
        },
        Str {
            interps: INTERP,
            ..Str::lines("`", "`", BACKSLASH)
        },
        Str::lines("'", "'", BACKSLASH),
    ],
    keywords: &[
        "alias", "and", "begin", "BEGIN", "class", "def", "do", "end", "END", "in", "module",
        "not", "or", "super", "then", "undef",
    ],
    control_keywords: &[
        "break", "case", "else", "elsif", "ensure", "for", "if", "next", "raise", "redo", "rescue",
        "retry", "return", "unless", "until", "when", "while", "yield",
    ],
    constants: &[
        "true",
        "false",
        "nil",
        "__FILE__",
        "__LINE__",
        "__dir__",
        "__method__",
    ],
    variables: &["self"],
    functions: &[
        "attr_accessor",
        "attr_reader",
        "attr_writer",
        "extend",
        "include",
        "lambda",
        "loop",
        "module_function",
        "p",
        "prepend",
        "print",
        "private",
        "proc",
        "protected",
        "public",
        "puts",
        "require",
        "require_relative",
    ],
    capitalized_types: true,
    caps_constants: true,
    calls: true,
    definitions: &[
        ("def", TokenKind::Function),
        ("class", TokenKind::Type),
        ("module", TokenKind::Type),
    ],
    regex_literals: true,
    hook: Some(ruby_words),
    resume: Some(ruby_resume),
    ..Spec::EMPTY
};

/// `=begin` comments, `@ivar`, `@@cvar` and `$global` variables,
/// `:symbols`, `key:` hash keys, `name?`/`name!` methods, `%w[…]`-style
/// literals and heredoc openers.
fn ruby_words(_spec: &'static Spec, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    let len = chars.len();
    let c = chars[i];
    let next = chars.get(i + 1).copied();
    let name_start = |n: Option<char>| n.is_some_and(|n| n.is_alphabetic() || n == '_');
    match c {
        '=' if i == 0 && cx.starts_with(0, "=begin") => {
            cx.push(0, len, TokenKind::Comment);
            cx.set_state(BLOCK_COMMENT);
            Some(len)
        }
        '@' => {
            let at = if next == Some('@') { i + 2 } else { i + 1 };
            if !name_start(chars.get(at).copied()) {
                return None;
            }
            let end = ident_end(chars, at);
            cx.push(i, end, TokenKind::Variable);
            Some(end)
        }
        '$' => {
            let end = dollar_end(chars, i);
            (end > i + 1).then(|| {
                cx.push(i, end, TokenKind::Variable);
                end
            })
        }
        ':' => {
            let after_word = i > 0 && (is_ident(chars[i - 1]) || chars[i - 1] == ':');
            if after_word || next == Some(':') {
                return None;
            }
            let end = if next == Some('"') {
                string_end(chars, i + 1, '"')
            } else if name_start(next) {
                method_end(chars, ident_end(chars, i + 1))
            } else {
                return None;
            };
            cx.push(i, end, TokenKind::Constant);
            Some(end)
        }
        '%' => percent_literal(cx, i),
        '<' if cx.starts_with(i, "<<") => {
            let at = i + 2;
            let marker = match chars.get(at) {
                Some('~' | '-') => at + 1,
                Some(c) if c.is_uppercase() => at,
                _ => return None,
            };
            let quote = chars
                .get(marker)
                .copied()
                .filter(|&q| q == '\'' || q == '"');
            let word = marker + usize::from(quote.is_some());
            if !name_start(chars.get(word).copied()) {
                return None;
            }
            let tag_end = ident_end(chars, word);
            let end = match quote {
                Some(q) => string_end(chars, marker, q),
                None => tag_end,
            };
            let tag: String = chars[word..tag_end].iter().collect();
            cx.push(i, end, TokenKind::String);
            heredoc::open(cx, &tag, quote == Some('\''));
            Some(end)
        }
        _ if (c.is_alphabetic() || c == '_') && word_start(chars, i) => {
            let end = ident_end(chars, i);
            let after = chars.get(end).copied();
            if after == Some(':')
                && chars.get(end + 1) != Some(&':')
                && i.checked_sub(1).is_none_or(|p| chars[p] != ':')
            {
                cx.push(i, end, TokenKind::Key);
                return Some(end);
            }
            let method = method_end(chars, end);
            if method == end {
                return None;
            }
            let word: String = chars[i..method].iter().collect();
            let kind = if word == "defined?" || word == "block_given?" {
                TokenKind::Keyword
            } else {
                TokenKind::Function
            };
            cx.push(i, method, kind);
            Some(method)
        }
        _ => None,
    }
}

/// Inside `=begin` … `=end`.
const BLOCK_COMMENT: u16 = HOOK_STATE | 0x3000;

static HEREDOC: heredoc::Rules = heredoc::Rules {
    dollars: false,
    hash_interp: Some("ruby"),
    tail: false,
};

/// A `=begin` comment or a heredoc going on from the line above.
fn ruby_resume(_spec: &'static Spec, cx: &mut Cx<'_>, state: u16) -> usize {
    let len = cx.len();
    if state == BLOCK_COMMENT {
        cx.push(0, len, TokenKind::Comment);
        if !cx.starts_with(0, "=end") {
            cx.set_state(state);
        }
        return len;
    }
    if heredoc::is(state) {
        return heredoc::resume(cx, state, &HEREDOC);
    }
    0
}

/// `end`, or past a `?` or `!` that ends a method name there (`empty?`,
/// `save!`; not `!=`, `?:` or a ternary's `?x`).
fn method_end(chars: &[char], end: usize) -> usize {
    match chars.get(end) {
        Some('?' | '!') => {
            let after = chars.get(end + 1).copied();
            let ends = match after {
                None => true,
                Some(a) => !is_ident(a) && a != '=' && a != ':' && a != '"' && a != '\'',
            };
            if ends {
                end + 1
            } else {
                end
            }
        }
        _ => end,
    }
}

/// `%w[…]`, `%i(…)`, `%q{…}`, `%r{…}` and their kin at `i`: words and
/// strings as strings, symbol lists as constants, `%r` as a regex.
fn percent_literal(cx: &mut Cx<'_>, i: usize) -> Option<usize> {
    let chars = cx.chars();
    let kind = match chars.get(i + 1)? {
        'q' | 'Q' | 'w' | 'W' | 'x' => TokenKind::String,
        'i' | 'I' | 's' => TokenKind::Constant,
        'r' => TokenKind::Regex,
        _ => return None,
    };
    let open = *chars.get(i + 2)?;
    let close = match open {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '<' => '>',
        '|' | '!' | '/' => open,
        _ => return None,
    };
    let body = i + 3;
    let end = if close == open {
        (body..chars.len()).find(|&j| chars[j] == close)
    } else {
        matching(chars, body, close)
    };
    let end = end.map_or(chars.len(), |j| {
        if kind == TokenKind::Regex {
            ident_end(chars, j + 1)
        } else {
            j + 1
        }
    });
    cx.push(i, end, kind);
    Some(end)
}

static LEXER: SpecLexer = SpecLexer::new(&SPEC);

pub static RUBY: LanguageDef = LanguageDef {
    id: "ruby",
    name: "Ruby",
    extensions: &["rb", "rbw", "rake", "gemspec", "ru", "podspec", "jbuilder"],
    file_names: &[
        "gemfile",
        "rakefile",
        "guardfile",
        "podfile",
        "vagrantfile",
        "brewfile",
        "fastfile",
    ],
    shebangs: &["ruby"],
    lexer: &LEXER,
    hints: no_hints,
};
