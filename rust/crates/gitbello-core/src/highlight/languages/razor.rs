//! Razor (`.razor` components, `.cshtml` views): HTML with C# after `@`.

use super::super::generic::{matching, outside_code};
use super::super::kind::TokenKind;
use super::super::lexer::{language_tag, Cx, Lexer};
use super::super::scan::{ident_end, is_ident, scan_while};
use super::super::LineState;
use super::{markup, no_hints, Language, LanguageDef};

/// Directives, at a line's start, with C# after them.
const DIRECTIVES: &[&str] = &[
    "page",
    "model",
    "using",
    "inject",
    "inherits",
    "implements",
    "layout",
    "namespace",
    "attribute",
    "rendermode",
    "typeparam",
    "preservewhitespace",
    "addTagHelper",
    "removeTagHelper",
    "tagHelperPrefix",
];

/// C# statements after `@` whose header is C# and whose `{ … }` body is a
/// code block (`@using` only before `(`).
const CONTROL: &[&str] = &[
    "if", "foreach", "for", "while", "switch", "try", "lock", "do",
];

/// Elements without a closing tag.
const VOID: &[&str] = &[
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source",
    "track", "wbr",
];

/// HTML is the host; after `@` come `@* … *@` comments, directives,
/// `@{ … }`, `@code { … }`, `@functions { … }` and `@section` blocks,
/// statements (`@if (x) { … }`, with `else`, `catch` and `finally` going
/// on), explicit `@( … )` and implicit `@a.b(c)` expressions, component
/// attributes (`@onclick="…"`) with C# values and the `@@` escape;
/// `name@host` stays text. In a code block, C# goes on to the brace that
/// closes it (counted outside strings and comments); a `<tag` where a
/// statement starts is markup until its element closes, and `@:` starts a
/// line of text.
struct RazorLexer;

/// [`Cx::state`] flags, above the stack of [`Level`]s (three of four bits).
mod flag {
    /// Inside a `@* … *@` comment.
    pub const COMMENT: u16 = 1 << 12;
    /// A statement's block just closed: `else`, `catch` or `finally` may
    /// go on with another.
    pub const AFTER: u16 = 1 << 13;
    /// A statement's header ended without its `{`: the next line may open
    /// the block.
    pub const PENDING: u16 = 1 << 14;
    /// A tag in a code block's markup goes on past the line.
    pub const OPEN_TAG: u16 = 1 << 15;
}

const LEVELS: usize = 3;
const MAX_COUNT: u8 = 7;

/// What the line is in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Level {
    /// The file's markup.
    Host,
    /// A code block, with its open braces.
    Code(u8),
    /// Markup in a code block, with its open elements.
    Element(u8),
}

/// The stack of levels above the host (each four bits: a code block's
/// braces, or bit 3 and an element count), and the [`flag`]s.
#[derive(Debug, Clone, Copy)]
struct State(u16);

impl State {
    fn nibble(self, k: usize) -> u16 {
        self.0 >> (4 * k) & 0xF
    }

    fn levels(self) -> usize {
        (0..LEVELS).take_while(|&k| self.nibble(k) != 0).count()
    }

    fn top(self) -> Level {
        let Some(k) = self.levels().checked_sub(1) else {
            return Level::Host;
        };
        let bits = self.nibble(k);
        let count = u8::try_from(bits & 7).unwrap_or(0);
        if bits & 8 != 0 {
            Level::Element(count)
        } else {
            Level::Code(count)
        }
    }

    fn set(&mut self, k: usize, level: Level) {
        let bits = match level {
            Level::Host => 0,
            Level::Code(n) => u16::from(n.clamp(1, MAX_COUNT)),
            Level::Element(n) => 8 | u16::from(n.min(MAX_COUNT)),
        };
        let shift = 4 * k;
        self.0 = self.0 & !(0xF << shift) | bits << shift;
    }

    fn set_top(&mut self, level: Level) {
        if let Some(k) = self.levels().checked_sub(1) {
            self.set(k, level);
        }
    }

    /// Pushes `level`; false when the stack is full.
    fn push(&mut self, level: Level) -> bool {
        let k = self.levels();
        if k >= LEVELS {
            return false;
        }
        self.set(k, level);
        true
    }

    fn pop(&mut self) {
        if let Some(k) = self.levels().checked_sub(1) {
            self.0 &= !(0xF << (4 * k));
        }
    }

    fn has(self, flag: u16) -> bool {
        self.0 & flag != 0
    }

    fn put(&mut self, flag: u16, on: bool) {
        if on {
            self.0 |= flag;
        } else {
            self.0 &= !flag;
        }
    }
}

/// How markup is read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    /// The file's markup.
    Host,
    /// An element in a code block: up to its end.
    Element,
    /// An `@:` line: up to the line's end.
    Line,
}

const HTML: markup::MarkupLexer = markup::MarkupLexer { html: true };

/// One line: the state, and where HTML and C# go on from (their embedded
/// state on this line so far; `None`: from the line above).
struct Run {
    st: State,
    html_nested: Option<LineState>,
    cs_nested: Option<LineState>,
    html_tag: u16,
    cs_tag: u16,
    csharp: Language,
}

impl Lexer for RazorLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let (Some(html), Some(csharp)) = (Language::by_id("html"), Language::by_id("csharp"))
        else {
            return;
        };
        let len = cx.len();
        let mut run = Run {
            st: State(cx.state()),
            html_nested: None,
            cs_nested: None,
            html_tag: language_tag(html),
            cs_tag: language_tag(csharp),
            csharp,
        };
        let mut pos = cx.pos;
        if run.st.has(flag::COMMENT) {
            pos = run.comment(cx, pos, pos);
        }
        if !run.st.has(flag::COMMENT) {
            pos = run.line_start(cx, pos);
            // Each pass moves on or changes the stack; the guard is a
            // backstop.
            let mut guard = 4 * len + 8;
            while pos < len && guard > 0 {
                guard -= 1;
                pos = match run.st.top() {
                    Level::Host => run.markup(cx, pos, Mode::Host),
                    Level::Element(_) => run.markup(cx, pos, Mode::Element),
                    Level::Code(depth) => run.code(cx, pos, depth),
                };
            }
        }
        run.finish(cx);
        cx.pos = len;
        cx.set_state(run.st.0);
    }
}

impl Run {
    /// HTML in `[start, end)`, going on from where it was.
    fn html(&mut self, cx: &mut Cx<'_>, start: usize, end: usize) {
        cx.set_nested(self.html_nested);
        cx.embed_open(self.html_tag, &HTML, start, end, true);
        self.html_nested = cx.nested();
    }

    /// True when HTML stands among a tag's attributes.
    fn in_tag(&self, cx: &mut Cx<'_>) -> bool {
        cx.set_nested(self.html_nested);
        cx.nested_state_of(self.html_tag)
            .is_some_and(markup::in_tag)
    }

    /// C# from `start`: lexed to the line's end, then again up to the first
    /// position `stop` takes (told whether the position is code, not a
    /// string or comment). Returns that position, or `None` when the code
    /// runs to the line's end.
    fn csharp_until(
        &mut self,
        cx: &mut Cx<'_>,
        start: usize,
        mut stop: impl FnMut(usize, bool) -> bool,
    ) -> Option<usize> {
        let len = cx.len();
        cx.set_nested(self.cs_nested);
        let mark = cx.token_count();
        cx.embed_open(self.cs_tag, self.csharp.lexer(), start, len, true);
        let mut code = vec![false; len];
        for j in outside_code(cx, mark, start, len, &[]) {
            code[j] = true;
        }
        let at = (start..len).find(|&j| stop(j, code[j]));
        if let Some(at) = at {
            cx.truncate(mark);
            cx.set_nested(self.cs_nested);
            cx.embed_open(self.cs_tag, self.csharp.lexer(), start, at, true);
        }
        self.cs_nested = cx.nested();
        at
    }

    /// A statement's header from `start` (`if (x)`, ` Scripts`) to its `{`,
    /// which opens a code block, or to the line's end when the `{` is on a
    /// later line.
    fn header(&mut self, cx: &mut Cx<'_>, start: usize) -> usize {
        let chars = cx.chars();
        let mut parens = 0i32;
        let brace = self.csharp_until(cx, start, |j, code| {
            if code {
                match chars[j] {
                    '(' | '[' => parens += 1,
                    ')' | ']' => parens -= 1,
                    '{' => return parens <= 0,
                    _ => {}
                }
            }
            false
        });
        match brace {
            Some(b) => {
                cx.push(b, b + 1, TokenKind::Punctuation);
                self.st.push(Level::Code(1));
                b + 1
            }
            None => {
                self.st.put(flag::PENDING, true);
                cx.len()
            }
        }
    }

    /// The flags the line above left: a block's `{`, or `else` after one.
    fn line_start(&mut self, cx: &mut Cx<'_>, pos: usize) -> usize {
        let chars = cx.chars();
        let at = scan_while(chars, pos, char::is_whitespace);
        if at >= chars.len() {
            return pos;
        }
        if self.st.has(flag::PENDING) {
            self.st.put(flag::PENDING, false);
            if chars[at] == '{' {
                cx.push(at, at + 1, TokenKind::Punctuation);
                self.st.push(Level::Code(1));
                return at + 1;
            }
        }
        if self.st.has(flag::AFTER) {
            self.st.put(flag::AFTER, false);
            if let Some(next) = self.continuation(cx, at) {
                return next;
            }
        }
        pos
    }

    /// After a block's closing brace, at `from`: what goes on after it.
    fn after_block(&mut self, cx: &mut Cx<'_>, from: usize) -> usize {
        let chars = cx.chars();
        let at = scan_while(chars, from, char::is_whitespace);
        if at >= chars.len() {
            self.st.put(flag::AFTER, true);
            return at;
        }
        self.continuation(cx, at).unwrap_or(from)
    }

    /// `else`, `catch` or `finally` at `at` going on after a block, or the
    /// `while (x);` that ends a `do`.
    fn continuation(&mut self, cx: &mut Cx<'_>, at: usize) -> Option<usize> {
        let chars = cx.chars();
        let end = ident_end(chars, at);
        let word: String = chars[at..end].iter().collect();
        match word.as_str() {
            "else" | "catch" | "finally" => Some(self.header(cx, at)),
            "while" => {
                let semi = self.csharp_until(cx, at, |j, code| code && chars[j] == ';');
                Some(semi.map_or(cx.len(), |s| {
                    cx.push(s, s + 1, TokenKind::Punctuation);
                    s + 1
                }))
            }
            _ => None,
        }
    }

    /// A `@* … *@` comment from `from`, its end searched from `search`;
    /// returns where it ends (the line's end when it goes on).
    fn comment(&mut self, cx: &mut Cx<'_>, from: usize, search: usize) -> usize {
        let len = cx.len();
        let close = (search..len).find(|&k| cx.starts_with(k, "*@"));
        let end = close.map_or(len, |c| c + 2);
        cx.push(from, end, TokenKind::Comment);
        self.st.put(flag::COMMENT, close.is_none());
        end
    }

    /// Code from `pos` in a block with `depth` open braces: up to the brace
    /// that closes it, markup, an `@:` line or a comment, else to the line's
    /// end.
    fn code(&mut self, cx: &mut Cx<'_>, pos: usize, depth: u8) -> usize {
        let chars = cx.chars();
        let len = chars.len();
        let mut depth = depth;
        let mut statement = true;
        let at = self.csharp_until(cx, pos, |j, code| {
            let c = chars[j];
            if !code {
                statement = false;
                return false;
            }
            if c.is_whitespace() {
                return false;
            }
            let next = chars.get(j + 1).copied();
            match c {
                '{' => {
                    depth = depth.saturating_add(1);
                    statement = true;
                }
                '}' => {
                    depth = depth.saturating_sub(1);
                    if depth == 0 {
                        return true;
                    }
                    statement = true;
                }
                ';' | ':' => statement = true,
                '<' if statement && next.is_some_and(char::is_alphabetic) => return true,
                '@' if next == Some('*') || (statement && next == Some(':')) => return true,
                _ => statement = false,
            }
            false
        });
        let Some(j) = at else {
            self.st.set_top(Level::Code(depth));
            return len;
        };
        if chars[j] == '}' {
            cx.push(j, j + 1, TokenKind::Punctuation);
            self.st.pop();
            return self.after_block(cx, j + 1);
        }
        self.st.set_top(Level::Code(depth));
        match chars[j] {
            '<' if self.st.push(Level::Element(0)) => j,
            '<' => self.markup(cx, j, Mode::Line),
            _ if chars.get(j + 1) == Some(&'*') => self.comment(cx, j, j + 2),
            _ => {
                cx.push(j, j + 1, TokenKind::Macro);
                cx.push(j + 1, j + 2, TokenKind::Punctuation);
                self.markup(cx, j + 2, Mode::Line)
            }
        }
    }

    /// Markup from `pos`: to the line's end, a transition that opens a code
    /// block, or (in a code block) the end of its element.
    fn markup(&mut self, cx: &mut Cx<'_>, pos: usize, mode: Mode) -> usize {
        let chars = cx.chars();
        let len = chars.len();
        let counting = mode == Mode::Element;
        let mut count = match self.st.top() {
            Level::Element(n) if counting => n,
            _ => 0,
        };
        // After a tag's `>`: where the element ends if `count` is 0.
        let mut check: Option<usize> = None;
        if counting && self.st.has(flag::OPEN_TAG) {
            match tag_close(chars, pos) {
                Some(end) => {
                    self.st.put(flag::OPEN_TAG, false);
                    if chars[end - 2] == '/' {
                        count = count.saturating_sub(1);
                    }
                    check = Some(end);
                }
                None => return self.markup_rest(cx, pos, count),
            }
        }
        let mut seg = pos;
        let mut j = pos;
        while j < len {
            if check.is_some_and(|e| j >= e) {
                check = None;
                if count == 0 {
                    self.html(cx, seg, j);
                    self.st.pop();
                    return j;
                }
            }
            let c = chars[j];
            if c == '@' && j + 1 < len && !(j > 0 && is_ident(chars[j - 1])) {
                self.html(cx, seg, j);
                if counting {
                    self.st.set_top(Level::Element(count));
                }
                let (next, changed) = self.transition(cx, j);
                seg = next;
                if changed {
                    return next;
                }
                j = next.max(j + 1);
                continue;
            }
            if counting && c == '<' {
                if cx.starts_with(j, "<!--") {
                    j = (j + 4..len)
                        .find(|&k| cx.starts_with(k, "-->"))
                        .map_or(len, |k| k + 3);
                    continue;
                }
                let closing = chars.get(j + 1) == Some(&'/');
                let name = if closing { j + 2 } else { j + 1 };
                if chars.get(name).is_some_and(|c| c.is_alphabetic()) {
                    let name_end =
                        scan_while(chars, name, |c| is_ident(c) || matches!(c, '-' | ':' | '.'));
                    let tag = chars[name..name_end]
                        .iter()
                        .collect::<String>()
                        .to_lowercase();
                    let end = tag_close(chars, name_end);
                    if closing {
                        count = count.saturating_sub(1);
                        check = Some(end.unwrap_or(len));
                    } else {
                        let self_closing = end.is_some_and(|e| chars[e - 2] == '/');
                        let void = VOID.contains(&tag.as_str());
                        if !self_closing && !void {
                            count = count.saturating_add(1).min(MAX_COUNT);
                        }
                        match end {
                            Some(e) => check = Some(e),
                            None if !void => self.st.put(flag::OPEN_TAG, true),
                            None => check = Some(len),
                        }
                    }
                    j = name_end;
                    continue;
                }
            }
            j += 1;
        }
        if counting && count == 0 && check.is_some() {
            self.html(cx, seg, len);
            self.st.pop();
            return len;
        }
        self.markup_rest(cx, seg, count)
    }

    /// The markup in `[seg, len)` up to the line's end, keeping an
    /// element's count.
    fn markup_rest(&mut self, cx: &mut Cx<'_>, seg: usize, count: u8) -> usize {
        let len = cx.len();
        self.html(cx, seg, len);
        if let Level::Element(_) = self.st.top() {
            self.st.set_top(Level::Element(count));
        }
        len
    }

    /// The `@` at `j`, after the markup before it: where lexing goes on, and
    /// whether the line goes on in another level (a code block, a comment).
    fn transition(&mut self, cx: &mut Cx<'_>, j: usize) -> (usize, bool) {
        let chars = cx.chars();
        let len = chars.len();
        match chars[j + 1] {
            '@' => {
                cx.push(j, j + 2, TokenKind::StringEscape);
                (j + 2, false)
            }
            '*' => {
                let end = self.comment(cx, j, j + 2);
                (end, self.st.has(flag::COMMENT))
            }
            '(' => {
                cx.push(j, j + 1, TokenKind::Macro);
                cx.push(j + 1, j + 2, TokenKind::Punctuation);
                let close = matching(chars, j + 2, ')').unwrap_or(len);
                cx.embed(self.csharp, j + 2, close);
                cx.push(close, close + 1, TokenKind::Punctuation);
                ((close + 1).min(len), false)
            }
            '{' => {
                cx.push(j, j + 1, TokenKind::Macro);
                cx.push(j + 1, j + 2, TokenKind::Punctuation);
                self.st.push(Level::Code(1));
                (j + 2, true)
            }
            c if is_ident(c) && !c.is_ascii_digit() => self.word(cx, j),
            _ => (j, false),
        }
    }

    /// `@` and a word at `j`: a component attribute, a block, a statement,
    /// a directive or an implicit expression.
    fn word(&mut self, cx: &mut Cx<'_>, j: usize) -> (usize, bool) {
        let chars = cx.chars();
        let len = chars.len();
        let start = j + 1;
        let end = ident_end(chars, start);
        let word: String = chars[start..end].iter().collect();
        let after = scan_while(chars, end, char::is_whitespace);
        let before = chars[..j].iter().rev().find(|c| !c.is_whitespace());
        if before != Some(&'=') && self.in_tag(cx) {
            return (self.attribute(cx, j), false);
        }
        match word.as_str() {
            "code" | "functions" | "section" => {
                cx.push(j, j + 1, TokenKind::Macro);
                cx.push(start, end, TokenKind::Keyword);
                (self.header(cx, end), true)
            }
            "using" if chars.get(after) == Some(&'(') => {
                cx.push(j, j + 1, TokenKind::Macro);
                (self.header(cx, start), true)
            }
            w if CONTROL.contains(&w) => {
                cx.push(j, j + 1, TokenKind::Macro);
                (self.header(cx, start), true)
            }
            w if DIRECTIVES.contains(&w) && cx.at_line_start(j) => {
                cx.push(j, j + 1, TokenKind::Macro);
                cx.push(start, end, TokenKind::Keyword);
                cx.embed(self.csharp, end, len);
                (len, false)
            }
            _ => {
                let stop = implicit_end(chars, start);
                cx.push(j, j + 1, TokenKind::Macro);
                cx.embed(self.csharp, start, stop);
                (stop, false)
            }
        }
    }

    /// A component attribute at `j` (`@onclick="…"`, `@bind-Value:event`,
    /// `@ref`), its quoted value C#; returns where it ends.
    fn attribute(&mut self, cx: &mut Cx<'_>, j: usize) -> usize {
        let chars = cx.chars();
        let len = chars.len();
        let end = scan_while(chars, j + 1, |c| {
            is_ident(c) || matches!(c, '-' | ':' | '.')
        });
        cx.push(j, end, TokenKind::Attribute);
        let eq = scan_while(chars, end, char::is_whitespace);
        if chars.get(eq) != Some(&'=') {
            return end;
        }
        cx.push(eq, eq + 1, TokenKind::Operator);
        let at = scan_while(chars, eq + 1, char::is_whitespace);
        let Some(quote) = chars.get(at).copied().filter(|&q| q == '"' || q == '\'') else {
            return at;
        };
        cx.push(at, at + 1, TokenKind::String);
        let close = (at + 1..len).find(|&k| chars[k] == quote);
        let body_end = close.unwrap_or(len);
        let mut body = at + 1;
        if chars.get(body) == Some(&'@') {
            cx.push(body, body + 1, TokenKind::Macro);
            body += 1;
        }
        cx.embed(self.csharp, body, body_end);
        match close {
            Some(c) => {
                cx.push(c, c + 1, TokenKind::String);
                c + 1
            }
            None => len,
        }
    }

    /// Keeps the state of the language the line ends in for the next line.
    fn finish(&mut self, cx: &mut Cx<'_>) {
        let len = cx.len();
        if let Level::Code(_) = self.st.top() {
            cx.set_nested(self.cs_nested);
            cx.embed_open(self.cs_tag, self.csharp.lexer(), len, len, true);
        } else {
            self.html(cx, len, len);
        }
    }
}

/// Where the tag whose attributes start at `from` ends (after its `>`,
/// skipping quoted values), if on the line.
fn tag_close(chars: &[char], from: usize) -> Option<usize> {
    let mut j = from;
    while j < chars.len() {
        match chars[j] {
            '>' => return Some(j + 1),
            q @ ('"' | '\'') => {
                j = (j + 1..chars.len()).find(|&k| chars[k] == q)? + 1;
            }
            _ => j += 1,
        }
    }
    None
}

/// The end of an implicit expression whose name starts at `start`:
/// members (`.Name`, `?.Name`), calls and indexers (`@user.Name`,
/// `@Format(x)[0]`, `@await Load()`); a trailing `.` is text.
fn implicit_end(chars: &[char], start: usize) -> usize {
    let ident_start = |k: usize| {
        chars
            .get(k)
            .is_some_and(|&c| is_ident(c) && !c.is_ascii_digit())
    };
    let mut j = ident_end(chars, start);
    if chars[start..j].iter().copied().eq("await".chars())
        && chars.get(j) == Some(&' ')
        && ident_start(j + 1)
    {
        j = ident_end(chars, j + 1);
    }
    loop {
        match chars.get(j) {
            Some('.') if ident_start(j + 1) => j = ident_end(chars, j + 1),
            Some('?') if chars.get(j + 1) == Some(&'.') && ident_start(j + 2) => {
                j = ident_end(chars, j + 2);
            }
            Some('(') => match matching(chars, j + 1, ')') {
                Some(c) => j = c + 1,
                None => break,
            },
            Some('[') => match matching(chars, j + 1, ']') {
                Some(c) => j = c + 1,
                None => break,
            },
            _ => break,
        }
    }
    j
}

static LEXER: RazorLexer = RazorLexer;

pub static RAZOR: LanguageDef = LanguageDef {
    id: "razor",
    name: "Razor",
    extensions: &["razor", "cshtml"],
    file_names: &[],
    shebangs: &[],
    lexer: &LEXER,
    hints: no_hints,
};
