use super::super::kind::TokenKind;
use super::super::lexer::{Cx, Lexer};
use super::super::scan::{find_end, is_ident, number_end, scan_while, string_end};
use super::{no_hints, LanguageDef};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Dialect {
    Css,
    Scss,
    Less,
}

/// CSS and its dialects, a line at a time: each part of a line is a
/// selector (elements as tags; classes, ids, pseudo-classes and attribute
/// selectors as attributes), a declaration (the property as a key, then its
/// value: numbers with units, `#fff` as constants, functions, strings,
/// `!important` as a keyword) or an at-rule (a keyword, then its prelude).
/// A part is a selector when a `{` follows it, or when it ends the line
/// without a `;` and has no `:` or one followed by a letter (`a:hover,`). SCSS adds `$variables`, `#{…}`, `%placeholders`, `//`
/// comments and control at-rules; LESS adds `@variables`, `@{…}` and `//`.
pub(super) struct CssLexer {
    dialect: Dialect,
    /// The text is a declaration list (an HTML `style` attribute).
    declarations: bool,
}

/// The declarations of an HTML `style="…"` attribute.
pub(super) static DECLARATIONS: CssLexer = CssLexer {
    dialect: Dialect::Css,
    declarations: true,
};

/// Rules of an HTML `<style>` element.
pub(super) static STYLESHEET: CssLexer = CssLexer {
    dialect: Dialect::Css,
    declarations: false,
};

/// Words of a `@media`/`@supports` prelude that are keywords.
const PRELUDE_KEYWORDS: &[&str] = &["and", "not", "only", "or", "from", "through", "to", "in"];

/// SCSS at-rules that change the flow.
const CONTROL_AT_RULES: &[&str] = &[
    "@if", "@else", "@each", "@for", "@while", "@return", "@debug", "@warn", "@error",
];

/// A character that can continue a CSS identifier.
fn css_ident(c: char) -> bool {
    is_ident(c) || c == '-'
}

/// The state of a line that starts inside a `/* … */` comment.
const IN_COMMENT: u16 = 1;

impl Lexer for CssLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let len = cx.len();
        let mut i = cx.pos;
        cx.pos = len;
        if cx.state() == IN_COMMENT {
            cx.set_state(0);
            let at = (i..len).find(|&j| cx.starts_with(j, "*/"));
            let end = at.map_or(len, |j| j + 2);
            cx.push(i, end, TokenKind::Comment);
            if at.is_none() {
                cx.set_state(IN_COMMENT);
            }
            i = end;
        }
        if self.declarations {
            while i < len {
                i = self.declarations(cx, i, false);
                if i < len && cx.at(i) == Some('}') {
                    i += 1;
                }
            }
            return;
        }
        while i < len {
            i = self.part(cx, i);
        }
    }
}

impl CssLexer {
    /// The end of a comment at `i`; a `/*` comment that does not close on
    /// the line leaves the next line in it.
    fn comment_at(&self, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
        if cx.starts_with(i, "/*") {
            let end = find_end(cx.chars(), i + 2, "*/");
            if !(end >= i + 4 && cx.starts_with(end - 2, "*/")) {
                cx.set_state(IN_COMMENT);
            }
            return Some(end);
        }
        let spaced = i == 0 || cx.at(i - 1).is_some_and(char::is_whitespace);
        (self.dialect != Dialect::Css && spaced && cx.starts_with(i, "//")).then(|| cx.len())
    }

    /// Lexes the part of the line at `i` and returns where it ends.
    fn part(&self, cx: &mut Cx<'_>, i: usize) -> usize {
        let chars = cx.chars();
        let len = chars.len();
        let i = scan_while(chars, i, char::is_whitespace);
        let Some(c) = cx.at(i) else {
            return len;
        };
        if let Some(end) = self.comment_at(cx, i) {
            cx.push(i, end, TokenKind::Comment);
            return end;
        }
        if c == '}' || c == '{' || c == ';' {
            cx.push(i, i + 1, TokenKind::Punctuation);
            if c == '{' {
                return self.declarations(cx, i + 1, true);
            }
            return i + 1;
        }
        if c == '@' && self.variable_declaration(cx, i).is_none() {
            return self.at_rule(cx, i);
        }
        let end = segment_end(chars, i);
        let first_colon = colon_outside_parens(chars, i, end);
        let selector = match chars.get(end) {
            Some('{') => true,
            Some(';' | '}') => false,
            // The line goes on: `h1,` or `a:hover,` start a rule,
            // `color: red` and `transition: a 1s,` are declarations.
            _ => first_colon.is_none_or(|colon| {
                chars
                    .get(colon + 1)
                    .is_some_and(|&ch| ch.is_alphabetic() || ch == ':')
            }),
        };
        // `a:hover {` and `&::before {` are selectors; `color: red {` is not
        // CSS but reads better as a declaration of a nested property (SCSS).
        let selector = selector
            && !(chars.get(end) == Some(&'{')
                && first_colon.is_some_and(|colon| cx.at(colon + 1) == Some(' ')));
        if selector {
            self.selector(cx, i, end);
            end
        } else {
            self.declarations(cx, i, false)
        }
    }

    /// `$name:` (SCSS) or `@name:` (LESS) at `i`: where its name ends.
    fn variable_declaration(&self, cx: &Cx<'_>, i: usize) -> Option<usize> {
        let sigil = match self.dialect {
            Dialect::Scss => '$',
            Dialect::Less => '@',
            Dialect::Css => return None,
        };
        if cx.at(i) != Some(sigil) {
            return None;
        }
        let chars = cx.chars();
        let end = scan_while(chars, i + 1, css_ident);
        let colon = scan_while(chars, end, char::is_whitespace);
        (end > i + 1 && cx.at(colon) == Some(':')).then_some(end)
    }

    /// An at-rule: its name as a keyword, then its prelude up to `{` or `;`.
    fn at_rule(&self, cx: &mut Cx<'_>, i: usize) -> usize {
        let chars = cx.chars();
        let name_end = scan_while(chars, i + 1, css_ident);
        let name: String = chars[i..name_end].iter().collect::<String>().to_lowercase();
        let control = self.dialect == Dialect::Scss && CONTROL_AT_RULES.contains(&name.as_str());
        let kind = if control {
            TokenKind::KeywordControl
        } else {
            TokenKind::Keyword
        };
        if name_end == i + 1 {
            return i + 1;
        }
        cx.push(i, name_end, kind);
        let end = segment_end(chars, name_end);
        match name.as_str() {
            "@mixin" | "@function" | "@include" => {
                let at = scan_while(chars, name_end, char::is_whitespace);
                let fn_end = scan_while(chars, at, css_ident);
                cx.push(at, fn_end, TokenKind::Function);
                self.values(cx, fn_end, end, true);
            }
            "@extend" => self.selector(cx, name_end, end),
            _ => self.values(cx, name_end, end, true),
        }
        end
    }

    /// Selectors in `[from, to)`.
    fn selector(&self, cx: &mut Cx<'_>, from: usize, to: usize) {
        let chars = cx.chars();
        let mut i = from;
        while i < to {
            let c = chars[i];
            if let Some(end) = self.comment_at(cx, i) {
                cx.push(i, end, TokenKind::Comment);
                i = end;
                continue;
            }
            if let Some(end) = self.interpolation(cx, i) {
                i = end;
                continue;
            }
            let start_word = i == from || !css_ident(chars[i - 1]);
            if c == '(' {
                // `:not(…)` holds selectors; a LESS mixin's `(…)` values.
                let close = matching_paren(chars, i + 1).min(to);
                let pseudo = (from..i)
                    .rev()
                    .find(|&j| !css_ident(chars[j]))
                    .is_some_and(|j| chars[j] == ':');
                if !pseudo {
                    self.values(cx, i + 1, close, true);
                    i = close + 1;
                    continue;
                }
                i += 1;
            } else if start_word && i > from && chars[i - 1] == '&' && css_ident(c) {
                // `&__title`, `&-active`: a suffix of the parent's class.
                let end = scan_while(chars, i, css_ident).min(to);
                cx.push(i, end, TokenKind::Attribute);
                i = end;
            } else if matches!(c, '.' | '#' | '%')
                && chars.get(i + 1).is_some_and(|&n| css_ident(n))
            {
                let end = scan_while(chars, i + 1, css_ident).min(to);
                cx.push(i, end, TokenKind::Attribute);
                i = end;
            } else if c == ':' {
                let name = scan_while(chars, i, |ch| ch == ':');
                let end = scan_while(chars, name, css_ident).min(to);
                cx.push(i, end, TokenKind::Attribute);
                i = end.max(i + 1);
            } else if c == '[' {
                let end = (i..to).find(|&j| chars[j] == ']').map_or(to, |j| j + 1);
                cx.push(i, end, TokenKind::Attribute);
                i = end;
            } else if c == '"' || c == '\'' {
                let end = string_end(chars, i, c).min(to);
                cx.push(i, end, TokenKind::String);
                i = end;
            } else if matches!(c, '>' | '+' | '~' | '&' | '*') {
                cx.push(i, i + 1, TokenKind::Operator);
                i += 1;
            } else if c.is_ascii_digit() && start_word {
                let end = number_end(chars, i);
                let end = if cx.at(end) == Some('%') {
                    end + 1
                } else {
                    end
                };
                cx.push(i, end.min(to), TokenKind::Number);
                i = end;
            } else if (c.is_alphabetic() || c == '_') && start_word {
                let end = scan_while(chars, i, css_ident).min(to);
                let guard = self.dialect == Dialect::Less
                    && matches!(&chars[i..end], ['w', 'h', 'e', 'n'] | ['a', 'n', 'd']);
                let kind = if guard {
                    TokenKind::Keyword
                } else {
                    TokenKind::Tag
                };
                cx.push(i, end, kind);
                i = end;
            } else {
                i += 1;
            }
        }
    }

    /// `#{…}` (SCSS) or `@{…}` (LESS) at `i`: pushed, and where it ends.
    fn interpolation(&self, cx: &mut Cx<'_>, i: usize) -> Option<usize> {
        let sigil = match self.dialect {
            Dialect::Scss => "#{",
            Dialect::Less => "@{",
            Dialect::Css => return None,
        };
        if !cx.starts_with(i, sigil) {
            return None;
        }
        let chars = cx.chars();
        let close = (i + 2..chars.len()).find(|&j| chars[j] == '}');
        let end = close.unwrap_or(chars.len());
        if self.dialect == Dialect::Less {
            let end = close.map_or(end, |c| c + 1);
            cx.push(i, end, TokenKind::Variable);
            return Some(end);
        }
        cx.push(i, i + 2, TokenKind::StringInterpolation);
        self.values(cx, i + 2, end, false);
        if let Some(close) = close {
            cx.push(close, close + 1, TokenKind::StringInterpolation);
            return Some(close + 1);
        }
        Some(end)
    }

    /// Declarations from `from`: `property: value;` until a `}` (left for
    /// the caller) or the end; with `nested`, a part followed by `{` is a
    /// nested rule and also ends them. Returns where they end.
    fn declarations(&self, cx: &mut Cx<'_>, from: usize, nested: bool) -> usize {
        let chars = cx.chars();
        let len = chars.len();
        let mut i = from;
        while i < len {
            i = scan_while(chars, i, char::is_whitespace);
            let Some(c) = cx.at(i) else {
                break;
            };
            if let Some(end) = self.comment_at(cx, i) {
                cx.push(i, end, TokenKind::Comment);
                i = end;
                continue;
            }
            if c == '}' {
                return i;
            }
            if c == ';' {
                cx.push(i, i + 1, TokenKind::Punctuation);
                i += 1;
                continue;
            }
            if c == '@' && self.variable_declaration(cx, i).is_none() {
                i = self.at_rule(cx, i);
                continue;
            }
            let end = segment_end(chars, i);
            if nested && chars.get(end) == Some(&'{') {
                return i;
            }
            if end == i {
                // A `{` where a declaration was expected.
                cx.push(i, i + 1, TokenKind::Punctuation);
                i += 1;
                continue;
            }
            let name_end = if matches!(c, '$' | '@') || c == '-' || css_ident(c) || c == '*' {
                scan_while(chars, i + 1, css_ident)
            } else {
                i
            };
            let colon = scan_while(chars, name_end, char::is_whitespace);
            if name_end > i && cx.at(colon) == Some(':') {
                let kind = if matches!(c, '$' | '@') || cx.starts_with(i, "--") {
                    TokenKind::Variable
                } else {
                    TokenKind::Key
                };
                cx.push(i, name_end, kind);
                cx.push(colon, colon + 1, TokenKind::Punctuation);
                self.values(cx, colon + 1, end, false);
            } else {
                // A value carried over from the line before.
                self.values(cx, i, end, false);
            }
            i = end;
        }
        len
    }

    /// A value in `[from, to)`; `prelude` for an at-rule's (where `and`,
    /// `not`… are keywords).
    fn values(&self, cx: &mut Cx<'_>, from: usize, to: usize, prelude: bool) {
        let chars = cx.chars();
        let mut i = from;
        while i < to {
            let c = chars[i];
            if c.is_whitespace() {
                i += 1;
                continue;
            }
            if let Some(end) = self.comment_at(cx, i) {
                cx.push(i, end, TokenKind::Comment);
                i = end;
                continue;
            }
            if let Some(end) = self.interpolation(cx, i) {
                i = end;
                continue;
            }
            let start_word = i == from || !css_ident(chars[i - 1]);
            if c == '"' || c == '\'' {
                let end = string_end(chars, i, c).min(to);
                cx.push(i, end, TokenKind::String);
                i = end;
            } else if c == '!' && chars.get(i + 1).is_some_and(|ch| ch.is_alphabetic()) {
                let end = scan_while(chars, i + 1, css_ident);
                cx.push(i, end, TokenKind::Keyword);
                i = end;
            } else if c == '#' && chars.get(i + 1).is_some_and(char::is_ascii_hexdigit) {
                let end = scan_while(chars, i + 1, css_ident);
                let digits = end - i - 1;
                let hex = chars[i + 1..end].iter().all(char::is_ascii_hexdigit);
                if hex && matches!(digits, 3 | 4 | 6 | 8) {
                    cx.push(i, end, TokenKind::Constant);
                }
                i = end;
            } else if start_word && (c.is_ascii_digit() || number_after_sign(chars, i)) {
                let digits = if c.is_ascii_digit() { i } else { i + 1 };
                let end = number_end(chars, digits);
                let end = if cx.at(end) == Some('%') {
                    end + 1
                } else {
                    end
                };
                cx.push(i, end.min(to), TokenKind::Number);
                i = end;
            } else if (c == '$' && self.dialect == Dialect::Scss)
                || (c == '@' && self.dialect == Dialect::Less)
                || (start_word && cx.starts_with(i, "--"))
            {
                let end = scan_while(chars, i + 1, css_ident).min(to);
                cx.push(i, end, TokenKind::Variable);
                i = end.max(i + 1);
            } else if start_word && (c.is_alphabetic() || c == '_' || c == '-') {
                let end = scan_while(chars, i, css_ident).min(to);
                let word: String = chars[i..end].iter().collect::<String>().to_lowercase();
                let after = scan_while(chars, end, char::is_whitespace);
                if cx.at(end) == Some('(') {
                    cx.push(i, end, TokenKind::Function);
                    if word == "url" {
                        let close = (end..to).find(|&j| chars[j] == ')').unwrap_or(to);
                        let body = scan_while(chars, end + 1, char::is_whitespace);
                        if !matches!(cx.at(body), Some('"' | '\'')) {
                            cx.push(body, close, TokenKind::String);
                            i = close;
                            continue;
                        }
                    }
                } else if cx.at(after) == Some(':') && after < to {
                    cx.push(i, end, TokenKind::Key);
                } else if prelude && PRELUDE_KEYWORDS.contains(&word.as_str()) {
                    cx.push(i, end, TokenKind::Keyword);
                } else if self.dialect == Dialect::Scss
                    && matches!(word.as_str(), "true" | "false" | "null")
                {
                    cx.push(i, end, TokenKind::Constant);
                }
                i = end.max(i + 1);
            } else {
                i += 1;
            }
        }
    }
}

/// A `-`, `+` or `.` that starts a number (`-1px`, `.5em`).
fn number_after_sign(chars: &[char], i: usize) -> bool {
    match chars[i] {
        '-' | '+' => match chars.get(i + 1) {
            Some(c) if c.is_ascii_digit() => true,
            Some('.') => chars.get(i + 2).is_some_and(char::is_ascii_digit),
            _ => false,
        },
        '.' => chars.get(i + 1).is_some_and(char::is_ascii_digit),
        _ => false,
    }
}

/// The first `:` in `[from, to)` outside parentheses.
fn colon_outside_parens(chars: &[char], from: usize, to: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (j, &c) in chars.iter().enumerate().take(to).skip(from) {
        match c {
            '(' => depth += 1,
            ')' => depth = depth.saturating_sub(1),
            ':' if depth == 0 => return Some(j),
            _ => {}
        }
    }
    None
}

/// The `)` closing the `(` before `from`, or the line end.
fn matching_paren(chars: &[char], from: usize) -> usize {
    let mut depth = 0usize;
    for (j, &c) in chars.iter().enumerate().skip(from) {
        match c {
            '(' => depth += 1,
            ')' if depth == 0 => return j,
            ')' => depth -= 1,
            _ => {}
        }
    }
    chars.len()
}

/// The first `{`, `;` or `}` from `from` outside strings and parentheses,
/// or the line end.
fn segment_end(chars: &[char], from: usize) -> usize {
    let mut depth = 0usize;
    let mut j = from;
    while j < chars.len() {
        match chars[j] {
            '"' | '\'' => {
                j = string_end(chars, j, chars[j]);
                continue;
            }
            '(' => depth += 1,
            ')' => depth = depth.saturating_sub(1),
            // `#{` and `@{` open interpolation, not a block.
            '{' if j > 0 && matches!(chars[j - 1], '#' | '@') => {
                j = (j..chars.len())
                    .find(|&k| chars[k] == '}')
                    .map_or(chars.len(), |k| k + 1);
                continue;
            }
            '{' | ';' | '}' if depth == 0 => return j,
            _ => {}
        }
        j += 1;
    }
    chars.len()
}

pub static CSS: LanguageDef = LanguageDef {
    id: "css",
    name: "CSS",
    extensions: &["css"],
    file_names: &[],
    shebangs: &[],
    lexer: &STYLESHEET,
    hints: no_hints,
};

pub static SCSS: LanguageDef = LanguageDef {
    id: "scss",
    name: "SCSS",
    extensions: &["scss"],
    file_names: &[],
    shebangs: &[],
    lexer: &CssLexer {
        dialect: Dialect::Scss,
        declarations: false,
    },
    hints: no_hints,
};

pub static LESS: LanguageDef = LanguageDef {
    id: "less",
    name: "LESS",
    extensions: &["less"],
    file_names: &[],
    shebangs: &[],
    lexer: &CssLexer {
        dialect: Dialect::Less,
        declarations: false,
    },
    hints: no_hints,
};
