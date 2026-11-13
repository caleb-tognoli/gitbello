//! The declarative lexer most languages use: a [`Spec`] lists a language's
//! comments, strings, word lists and switches for its quirks, plus an
//! optional [`Hook`] for what is its own. Hand-written lexers reuse
//! [`lex_str`] for strings with escapes and interpolation.

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};
use std::sync::OnceLock;

use super::kind::TokenKind;
use super::languages::Language;
use super::lexer::{Cx, Lexer};
use super::scan::{ident_end, is_ident, number_end, scan_while, string_end, word_start};

/// How a string escapes characters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Escape {
    /// No escapes (raw strings).
    None,
    /// An escape character before the escaped one (`\n`, PowerShell's `` `n ``).
    With(char),
    /// The closing quote doubled (`''` in SQL and YAML, `""` in C# verbatim strings).
    Doubled,
}

/// Backslash escapes.
pub const BACKSLASH: Escape = Escape::With('\\');

/// Code embedded in a string: `open`, code in `language` up to the matching
/// `close` (nesting counted), then `close`.
#[derive(Debug)]
pub struct Interp {
    pub open: &'static str,
    pub close: char,
    /// The embedded language's id.
    pub language: &'static str,
}

/// A kind of string literal.
#[derive(Debug)]
pub struct Str {
    /// What opens it; a prefix (`r"`, `f"`, `@"`) only at a word start.
    pub open: &'static str,
    pub close: &'static str,
    pub escape: Escape,
    pub interps: &'static [Interp],
    /// `{{` and `}}` are escapes (Python f-strings, C# `$"…"`).
    pub doubled_braces: bool,
    /// `$name` inside is a variable (shells, Kotlin, PHP).
    pub dollar_names: bool,
    /// `open` is a prefix followed by `#`s and `"`, closed by `"` and as
    /// many `#`s (Rust `r#"…"#`, Swift `#"…"#`; an empty prefix needs a `#`).
    pub hashed: bool,
    /// The string goes on past the end of a line (Python `"""`, template
    /// literals); otherwise the line end closes it.
    pub multiline: bool,
}

impl Str {
    /// A string from `open` to `close` with `escape`, nothing embedded.
    pub const fn new(open: &'static str, close: &'static str, escape: Escape) -> Self {
        Self {
            open,
            close,
            escape,
            interps: &[],
            doubled_braces: false,
            dollar_names: false,
            hashed: false,
            multiline: false,
        }
    }

    /// A string from `open` to `close` with `escape` that may span lines.
    pub const fn lines(open: &'static str, close: &'static str, escape: Escape) -> Self {
        Self {
            multiline: true,
            ..Self::new(open, close, escape)
        }
    }
}

/// [`Cx::state`] values of a [`SpecLexer`]: 0 at the start, then what a
/// line left open. A hook's own states have [`HOOK_STATE`] set.
mod state {
    pub const COMMENT: u16 = 1;
    pub const DOC_COMMENT: u16 = 2;
    /// `STRING | rule index << 8 | hashes`: inside `spec.strings[rule]`.
    pub const STRING: u16 = 0x1000;
}

/// Set in the states a [`Spec`]'s hook leaves (its own encoding below
/// it); the spec's `resume` continues them.
pub const HOOK_STATE: u16 = 0x8000;

/// A 12-bit hash of a heredoc's terminator (`EOF`), kept in a hook's state
/// to recognise the line that closes it.
pub fn tag_hash(tag: &str) -> u16 {
    let mut hash: u32 = 0x811c_9dc5;
    for b in tag.bytes() {
        hash = (hash ^ u32::from(b)).wrapping_mul(0x0100_0193);
    }
    u16::try_from((hash ^ hash >> 12 ^ hash >> 24) & 0xFFF).unwrap_or_default()
}

/// Heredocs (shells, Ruby, PHP): the hook that finds an opener calls
/// [`heredoc::open`], and the language's resume hands lines in a
/// [`heredoc::is`] state to [`heredoc::resume`].
pub mod heredoc {
    use super::{dollar_end, matching, tag_hash, HOOK_STATE};
    use crate::highlight::kind::TokenKind;
    use crate::highlight::languages::Language;
    use crate::highlight::lexer::Cx;
    use crate::highlight::scan::{ident_end, scan_while};

    /// A heredoc whose body expands variables.
    const EXPANDING: u16 = 0x1000;
    /// A heredoc whose body is literal (a quoted tag).
    const LITERAL: u16 = 0x2000;
    const KINDS: u16 = 0x7000;

    /// What a language's heredoc body may hold and how its end line looks.
    pub struct Rules {
        /// `$name`, `${…}` are variables.
        pub dollars: bool,
        /// `#{…}` is interpolation in this language (Ruby).
        pub hash_interp: Option<&'static str>,
        /// The end line may go on after the tag (`EOT;` in PHP).
        pub tail: bool,
    }

    /// Leaves the line in a heredoc ending at a line `tag`.
    pub fn open(cx: &mut Cx<'_>, tag: &str, literal: bool) {
        let kind = if literal { LITERAL } else { EXPANDING };
        cx.set_state(HOOK_STATE | kind | tag_hash(tag));
    }

    /// True for a state [`open`] left.
    pub fn is(state: u16) -> bool {
        state & HOOK_STATE != 0 && matches!(state & KINDS, EXPANDING | LITERAL)
    }

    /// Lexes a line of the heredoc `state`: its body as a string, or its end
    /// line. Returns where lexing goes on (the line end, or after the tag).
    pub fn resume(cx: &mut Cx<'_>, state: u16, rules: &Rules) -> usize {
        let chars = cx.chars();
        let len = chars.len();
        let at = scan_while(chars, 0, char::is_whitespace);
        let end = ident_end(chars, at);
        let word: String = chars[at..end].iter().collect();
        let rest_blank = chars[end..].iter().all(|c| c.is_whitespace());
        let closes = end > at && tag_hash(&word) == state & 0xFFF && (rest_blank || rules.tail);
        if closes {
            cx.push(at, end, TokenKind::String);
            return end;
        }
        cx.set_state(state);
        if state & KINDS == LITERAL {
            cx.push(0, len, TokenKind::String);
            return len;
        }
        let mut seg = 0;
        let mut j = 0;
        while j < len {
            if rules.dollars && chars[j] == '$' {
                let end = dollar_end(chars, j);
                if end > j + 1 {
                    cx.push(seg, j, TokenKind::String);
                    cx.push(j, end, TokenKind::Variable);
                    j = end;
                    seg = j;
                    continue;
                }
            }
            if let Some(id) = rules.hash_interp.filter(|_| cx.starts_with(j, "#{")) {
                let close = matching(chars, j + 2, '}');
                cx.push(seg, j, TokenKind::String);
                cx.push(j, j + 2, TokenKind::StringInterpolation);
                if let Some(language) = Language::by_id(id) {
                    cx.embed(language, j + 2, close.unwrap_or(len));
                }
                j = close.map_or(len, |c| {
                    cx.push(c, c + 1, TokenKind::StringInterpolation);
                    c + 1
                });
                seg = j;
                continue;
            }
            j += 1;
        }
        cx.push(seg, len, TokenKind::String);
        len
    }
}

/// A hook's continuation: called at the start of a line that starts in a
/// [`HOOK_STATE`], it lexes what goes on from the line above and returns
/// where normal lexing resumes (setting the state again if it is still open).
pub type Resume = fn(&'static Spec, &mut Cx<'_>, u16) -> usize;

/// A language's own rule, tried at every position before the others: it
/// pushes what it recognises at `i` and returns where it ended.
pub type Hook = fn(&'static Spec, &mut Cx<'_>, usize) -> Option<usize>;

/// Which strings and words are keys. With keys, the other strings are a
/// data file's values and stay plain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Keys {
    None,
    /// A string followed by `:` (JSON).
    Strings,
    /// A string or a bare word followed by `:` (JSON5).
    StringsAndWords,
}

/// A language as data, lexed by [`SpecLexer`].
#[derive(Debug)]
pub struct Spec {
    pub line_comments: &'static [&'static str],
    /// Line comments that document (`///`, `##`); tried first.
    pub doc_comments: &'static [&'static str],
    pub block_comment: Option<(&'static str, &'static str)>,
    /// A block comment opened with one more `*` (`/**`) documents.
    pub doc_blocks: bool,
    /// String kinds, tried in order (put `"""` before `"`).
    pub strings: &'static [Str],
    /// `'` opens a char literal only when it closes after one character or
    /// an escape, so lifetimes (`'a`) stay plain (Rust, C).
    pub char_literals: bool,
    pub keywords: &'static [&'static str],
    /// Keywords that change the flow (`if`, `return`).
    pub control_keywords: &'static [&'static str],
    pub types: &'static [&'static str],
    pub constants: &'static [&'static str],
    /// Builtin functions, coloured even when not called.
    pub functions: &'static [&'static str],
    /// Builtin variables (`gl_Position`, `self` where it is one).
    pub variables: &'static [&'static str],
    /// Word lists are lowercase and words are compared lowercased.
    pub case_insensitive: bool,
    /// Identifiers starting with an uppercase letter are types, unless
    /// called or after a `.`.
    pub capitalized_types: bool,
    /// `ALL_CAPS` identifiers are constants.
    pub caps_constants: bool,
    /// An identifier before `(` is a function.
    pub calls: bool,
    /// A capitalized identifier before `(` is a type (a constructor call,
    /// Dart's `Text('…')`), unless after a `.`.
    pub constructors: bool,
    /// Keywords whose next identifier is defined, with its kind
    /// (`fn` → function, `struct` → type).
    pub definitions: &'static [(&'static str, TokenKind)],
    /// `name!` is a macro, and `{…}` in its string arguments are
    /// placeholders (Rust).
    pub macros: bool,
    /// Characters that start an annotation word (`@Override`).
    pub annotation_sigils: &'static [char],
    /// Openers of bracketed attributes, coloured to the matching `]`
    /// (`#[`, `[[`).
    pub attributes: &'static [&'static str],
    /// A line that is `[…]` is an attribute (C#).
    pub line_attributes: bool,
    /// `#word` is a preprocessor directive (C), coloured as a macro, and
    /// `<…>` after `#include` is a string.
    pub hash_words: bool,
    /// A line comment needs whitespace (or the line start) before it, so
    /// `a#b` is not one (shells).
    pub comment_after_space: bool,
    /// `/…/` where an operand may start is a regex (JavaScript).
    pub regex_literals: bool,
    /// `$name`, `${…}` and `$1`, `$@`… are variables (shells).
    pub dollar_variables: bool,
    pub keys: Keys,
    pub hook: Option<Hook>,
    /// Continues what the hook left open at the end of a line.
    pub resume: Option<Resume>,
}

impl Spec {
    /// A spec with nothing in it, to fill with `..Spec::EMPTY`.
    pub const EMPTY: Spec = Spec {
        line_comments: &[],
        doc_comments: &[],
        block_comment: None,
        doc_blocks: false,
        strings: &[],
        char_literals: false,
        keywords: &[],
        control_keywords: &[],
        types: &[],
        constants: &[],
        functions: &[],
        variables: &[],
        case_insensitive: false,
        capitalized_types: false,
        caps_constants: false,
        calls: false,
        constructors: false,
        definitions: &[],
        macros: false,
        annotation_sigils: &[],
        attributes: &[],
        line_attributes: false,
        hash_words: false,
        comment_after_space: false,
        regex_literals: false,
        dollar_variables: false,
        keys: Keys::None,
        hook: None,
        resume: None,
    };

    /// The string kind opening at `i`: the rule, where its body starts and
    /// its closer (with the hashes of a hashed string).
    fn string_at(&self, cx: &Cx<'_>, i: usize) -> Option<(&'static Str, usize, String)> {
        let chars = cx.chars();
        for rule in self.strings {
            if !cx.starts_with(i, rule.open) {
                continue;
            }
            let prefixed = rule.open.chars().next().is_some_and(is_ident);
            if prefixed && !word_start(chars, i) {
                continue;
            }
            let after = i + rule.open.chars().count();
            if !rule.hashed {
                return Some((rule, after, rule.close.to_owned()));
            }
            let hashes = scan_while(chars, after, |c| c == '#') - after;
            if (hashes == 0 && rule.open.is_empty()) || chars.get(after + hashes) != Some(&'"') {
                continue;
            }
            let close = format!("\"{}", "#".repeat(hashes));
            return Some((rule, after + hashes + 1, close));
        }
        None
    }
}

/// Lexes a line by a [`Spec`]. Its lookup tables are built from the spec
/// on first use.
pub struct SpecLexer {
    spec: &'static Spec,
    tables: OnceLock<Tables>,
}

impl SpecLexer {
    pub const fn new(spec: &'static Spec) -> Self {
        Self {
            spec,
            tables: OnceLock::new(),
        }
    }

    fn tables(&self) -> &Tables {
        self.tables.get_or_init(|| Tables::new(self.spec))
    }

    /// Lexes what the line above left open (`incoming`, a [`state`] or a
    /// hook's state) from `i`; returns where normal lexing goes on.
    fn resume(&self, cx: &mut Cx<'_>, incoming: u16, i: usize) -> usize {
        let spec = self.spec;
        let len = cx.len();
        if incoming & HOOK_STATE != 0 {
            return spec.resume.map_or(i, |resume| resume(spec, cx, incoming));
        }
        match incoming {
            state::COMMENT | state::DOC_COMMENT => {
                let Some((_, close)) = spec.block_comment else {
                    return i;
                };
                let close_at = (i..len).find(|&j| cx.starts_with(j, close));
                let end = close_at.map_or(len, |j| j + close.chars().count());
                let kind = if incoming == state::DOC_COMMENT {
                    TokenKind::CommentDoc
                } else {
                    TokenKind::Comment
                };
                cx.push(i, end, kind);
                if close_at.is_none() {
                    cx.set_state(incoming);
                }
                end
            }
            s if s & 0xF000 == state::STRING => {
                let Some(rule) = spec.strings.get(usize::from((s >> 8) & 0xF)) else {
                    return i;
                };
                let close = if rule.hashed {
                    format!("\"{}", "#".repeat(usize::from(s & 0xFF)))
                } else {
                    rule.close.to_owned()
                };
                let (end, closed) = lex_str_to(cx, rule, i, i, &close, TokenKind::String, false);
                if !closed {
                    cx.set_state(s);
                }
                end
            }
            _ => i,
        }
    }
}

/// The state inside string rule `index` with `hashes` hashes.
fn string_state(index: usize, hashes: usize) -> u16 {
    let index = u16::try_from(index.min(0xF)).unwrap_or_default();
    let hashes = u16::try_from(hashes.min(0xFF)).unwrap_or_default();
    state::STRING | index << 8 | hashes
}

impl std::fmt::Debug for SpecLexer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("SpecLexer").field(self.spec).finish()
    }
}

/// FNV-1a, quick for the short words of the word tables.
struct Fnv(u64);

impl Default for Fnv {
    fn default() -> Self {
        Self(0xcbf2_9ce4_8422_2325)
    }
}

impl Hasher for Fnv {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0 ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3);
        }
    }
}

type WordMap = HashMap<&'static str, TokenKind, BuildHasherDefault<Fnv>>;

/// A spec's lists as lookups.
struct Tables {
    /// Listed words (lowercase for a case-insensitive spec) and their kind;
    /// a word in two lists keeps the first in [`Tables::new`]'s order.
    words: WordMap,
    /// Definition keywords and the kind of the name they announce.
    definitions: WordMap,
    /// ASCII characters that can open a comment, a string, an attribute or
    /// a char literal; other ASCII characters skip those checks.
    opens: [bool; 128],
}

impl Tables {
    fn new(spec: &Spec) -> Self {
        let mut words = WordMap::default();
        for (list, kind) in [
            (spec.control_keywords, TokenKind::KeywordControl),
            (spec.keywords, TokenKind::Keyword),
            (spec.constants, TokenKind::Constant),
            (spec.types, TokenKind::Type),
            (spec.variables, TokenKind::Variable),
            (spec.functions, TokenKind::Function),
        ] {
            for word in list {
                words.entry(*word).or_insert(kind);
            }
        }
        let mut definitions = WordMap::default();
        for (word, kind) in spec.definitions {
            definitions.entry(*word).or_insert(*kind);
        }
        let mut opens = [false; 128];
        let mut mark = |text: &str| {
            if let Some(c) = text.chars().next().filter(char::is_ascii) {
                opens[c as usize] = true;
            }
        };
        let block = spec.block_comment.map(|(open, _)| open);
        for text in spec
            .line_comments
            .iter()
            .chain(spec.doc_comments)
            .chain(spec.attributes)
            .chain(block.as_ref())
        {
            mark(text);
        }
        for rule in spec.strings {
            mark(if rule.open.is_empty() { "#" } else { rule.open });
        }
        if spec.char_literals {
            mark("'");
        }
        if spec.line_attributes {
            mark("[");
        }
        Self {
            words,
            definitions,
            opens,
        }
    }

    fn may_open(&self, c: char) -> bool {
        !c.is_ascii() || self.opens[c as usize]
    }
}

/// Characters after which `/` starts a regex rather than dividing.
const REGEX_AFTER: &str = "(,=:[!&|?{};+-*%<>~^";

impl Lexer for SpecLexer {
    fn lex(&self, cx: &mut Cx<'_>) {
        let spec = self.spec;
        let tables = self.tables();
        let chars = cx.chars();
        let len = chars.len();
        let mut i = cx.pos;
        // The kind of the name a definition keyword announced.
        let mut pending: Option<TokenKind> = None;
        // Inside the arguments of a `name!(` on this line.
        let mut in_macro = false;
        // A `/` here would start a regex.
        let mut operand = true;
        // The current word, and lowercased for a case-insensitive spec;
        // reused so a line allocates them once.
        let mut word = String::new();
        let mut lowered = String::new();
        let incoming = cx.state();
        cx.set_state(0);
        if incoming != 0 {
            i = self.resume(cx, incoming, i);
        }
        while i < len {
            let c = chars[i];
            if c.is_whitespace() {
                i += 1;
                continue;
            }
            if let Some(end) = spec.hook.and_then(|hook| hook(spec, cx, i)) {
                if end > i {
                    i = end;
                    pending = None;
                    operand = false;
                    continue;
                }
            }
            if tables.may_open(c) {
                let spaced = !spec.comment_after_space || i == 0 || chars[i - 1].is_whitespace();
                if spaced && spec.doc_comments.iter().any(|m| cx.starts_with(i, m)) {
                    cx.push(i, len, TokenKind::CommentDoc);
                    i = len;
                    break;
                }
                if spaced && spec.line_comments.iter().any(|m| cx.starts_with(i, m)) {
                    cx.push(i, len, TokenKind::Comment);
                    i = len;
                    break;
                }
                if let Some((open, close)) = spec.block_comment {
                    if cx.starts_with(i, open) {
                        let body = i + open.chars().count();
                        let close_at = (body..len).find(|&j| cx.starts_with(j, close));
                        let end = close_at.map_or(len, |j| j + close.chars().count());
                        let doc = spec.doc_blocks
                            && chars.get(body) == Some(&'*')
                            && !cx.starts_with(body, close)
                            && chars.get(body + 1) != Some(&'*');
                        let kind = if doc {
                            TokenKind::CommentDoc
                        } else {
                            TokenKind::Comment
                        };
                        cx.push(i, end, kind);
                        if close_at.is_none() {
                            cx.set_state(if doc {
                                state::DOC_COMMENT
                            } else {
                                state::COMMENT
                            });
                        }
                        i = end;
                        continue;
                    }
                }
                if let Some(open) = spec.attributes.iter().find(|a| cx.starts_with(i, a)) {
                    let bracket = i + open.chars().position(|c| c == '[').unwrap_or(0);
                    let end = matching(chars, bracket + 1, ']').map_or(len, |j| j + 1);
                    cx.push(i, end, TokenKind::Annotation);
                    i = end;
                    continue;
                }
                if spec.line_attributes && c == '[' && cx.at_line_start(i) {
                    let last = chars.iter().rposition(|c| !c.is_whitespace());
                    if last.is_some_and(|j| chars[j] == ']') {
                        cx.push(i, len, TokenKind::Annotation);
                        i = len;
                        continue;
                    }
                }
                if let Some((rule, body, close)) = spec.string_at(cx, i) {
                    let kind = if spec.keys != Keys::None && rule.interps.is_empty() {
                        let end = str_end(chars, body, &close, rule.escape);
                        key_kind(chars, end)
                    } else {
                        TokenKind::String
                    };
                    let mark = cx.token_count();
                    let (end, closed) = lex_str_to(cx, rule, i, body, &close, kind, in_macro);
                    if spec.keys != Keys::None && kind == TokenKind::String {
                        // With keys, the other strings are values: plain.
                        cx.plain_strings_since(mark);
                    }
                    if !closed && rule.multiline {
                        let index = spec
                            .strings
                            .iter()
                            .position(|r| std::ptr::eq(r, rule))
                            .unwrap_or_default();
                        let hashes = if rule.hashed { close.len() - 1 } else { 0 };
                        cx.set_state(string_state(index, hashes));
                    }
                    i = end;
                    pending = None;
                    operand = false;
                    continue;
                }
                if spec.char_literals && char_literal(chars, i) {
                    let end = string_end(chars, i, '\'');
                    cx.push(i, end, TokenKind::String);
                    i = end;
                    operand = false;
                    continue;
                }
            }
            let at_word = word_start(chars, i);
            if c.is_ascii_digit() && at_word {
                let end = number_end(chars, i);
                cx.push(i, end, TokenKind::Number);
                i = end;
                operand = false;
                continue;
            }
            if spec.hash_words && c == '#' && chars.get(i + 1).is_some_and(|&n| is_ident(n)) {
                let end = ident_end(chars, i + 1);
                cx.push(i, end, TokenKind::Macro);
                word.clear();
                word.extend(&chars[i..end]);
                i = end;
                if word == "#include" || word == "#import" {
                    let at = scan_while(chars, i, char::is_whitespace);
                    if chars.get(at) == Some(&'<') {
                        let close = (at..len).find(|&j| chars[j] == '>').map_or(len, |j| j + 1);
                        cx.push(at, close, TokenKind::String);
                        i = close;
                    }
                }
                continue;
            }
            if spec.annotation_sigils.contains(&c)
                && chars
                    .get(i + 1)
                    .is_some_and(|&n| n.is_alphabetic() || n == '_')
            {
                let mut end = ident_end(chars, i + 1);
                while chars.get(end) == Some(&'.')
                    && chars.get(end + 1).is_some_and(|&n| is_ident(n))
                {
                    end = ident_end(chars, end + 1);
                }
                cx.push(i, end, TokenKind::Annotation);
                i = end;
                continue;
            }
            if is_ident(c) && at_word {
                let end = ident_end(chars, i);
                word.clear();
                word.extend(&chars[i..end]);
                let key: &str = if spec.case_insensitive {
                    lowered.clear();
                    lowered.extend(word.chars().flat_map(char::to_lowercase));
                    &lowered
                } else {
                    &word
                };
                let next = chars.get(end).copied();
                let listed = tables.words.get(key).copied();
                let kind = if let Some(kind) = listed {
                    Some(kind)
                } else if let Some(kind) = pending {
                    Some(kind)
                } else if spec.macros && next == Some('!') && chars.get(end + 1) != Some(&'=') {
                    in_macro = true;
                    cx.push(i, end + 1, TokenKind::Macro);
                    i = end + 1;
                    pending = None;
                    operand = true;
                    continue;
                } else if spec.keys == Keys::StringsAndWords
                    && key_kind(chars, end) == TokenKind::Key
                {
                    Some(TokenKind::Key)
                } else if spec.caps_constants && is_caps(&word) {
                    Some(TokenKind::Constant)
                } else if spec.calls && next == Some('(') {
                    if spec.constructors && c.is_uppercase() && !member(chars, i) {
                        Some(TokenKind::Type)
                    } else {
                        Some(TokenKind::Function)
                    }
                } else if spec.capitalized_types && c.is_uppercase() && !member(chars, i) {
                    Some(TokenKind::Type)
                } else {
                    None
                };
                if let Some(kind) = kind {
                    cx.push(i, end, kind);
                }
                pending = tables.definitions.get(key).copied();
                operand = matches!(listed, Some(TokenKind::Keyword | TokenKind::KeywordControl));
                i = end;
                continue;
            }
            if spec.dollar_variables && c == '$' {
                let end = dollar_end(chars, i);
                if end > i + 1 {
                    cx.push(i, end, TokenKind::Variable);
                    i = end;
                    operand = false;
                    continue;
                }
            }
            if spec.regex_literals && c == '/' && operand {
                if let Some(end) = regex_end(chars, i) {
                    cx.push(i, end, TokenKind::Regex);
                    i = end;
                    operand = false;
                    continue;
                }
            }
            if c == ';' {
                in_macro = false;
            }
            pending = None;
            operand = spec.regex_literals && REGEX_AFTER.contains(c);
            i += 1;
        }
        cx.pos = i;
    }
}

/// `String`, or `Key` when a `:` follows `end` (past spaces).
fn key_kind(chars: &[char], end: usize) -> TokenKind {
    let next = scan_while(chars, end, char::is_whitespace);
    if chars.get(next) == Some(&':') {
        TokenKind::Key
    } else {
        TokenKind::String
    }
}

/// True when the word at `i` follows a `.` (a member, not a type).
fn member(chars: &[char], i: usize) -> bool {
    i > 0 && chars[i - 1] == '.' && !(i > 1 && chars[i - 2] == '.')
}

/// True for `ALL_CAPS` words of two or more characters.
pub fn is_caps(word: &str) -> bool {
    let mut letters = false;
    for (n, c) in word.chars().enumerate() {
        if c.is_uppercase() {
            letters = true;
        } else if !(c == '_' || (n > 0 && c.is_ascii_digit())) {
            return false;
        }
    }
    letters && word.chars().nth(1).is_some()
}

/// A char literal (`'a'`, `'\n'`) at `i`, not a lifetime (`'a`).
fn char_literal(chars: &[char], i: usize) -> bool {
    if chars[i] != '\'' {
        return false;
    }
    match chars.get(i + 1) {
        Some('\\') => true,
        Some(_) => chars.get(i + 2) == Some(&'\''),
        None => false,
    }
}

/// The index of the `close` that ends what opened just before `from`,
/// counting nested openers of the same pair and skipping quoted strings.
pub fn matching(chars: &[char], from: usize, close: char) -> Option<usize> {
    let open = match close {
        '}' => '{',
        ')' => '(',
        ']' => '[',
        '>' => '<',
        _ => close,
    };
    let mut depth = 0usize;
    let mut j = from;
    while j < chars.len() {
        let c = chars[j];
        if matches!(c, '"' | '\'' | '`') && c != close {
            j = string_end(chars, j, c);
            continue;
        }
        if c == close {
            if depth == 0 {
                return Some(j);
            }
            depth -= 1;
        } else if c == open {
            depth += 1;
        }
        j += 1;
    }
    None
}

/// The end of a `$` variable at `i` (`$name`, `${…}`, `$1`, `$@`), or
/// `i + 1` when none follows.
pub fn dollar_end(chars: &[char], i: usize) -> usize {
    match chars.get(i + 1) {
        Some('{') => matching(chars, i + 2, '}').map_or(chars.len(), |j| j + 1),
        Some(&c) if c.is_alphabetic() || c == '_' => ident_end(chars, i + 1),
        Some(&c) if c.is_ascii_digit() || "@?#$!*-<^".contains(c) => i + 2,
        _ => i + 1,
    }
}

/// The end of an escape sequence starting at `j` (the escape character).
pub fn escape_end(chars: &[char], j: usize) -> usize {
    let len = chars.len();
    let hex = |from: usize, max: usize| {
        (from..(from + max).min(len))
            .find(|&k| !chars[k].is_ascii_hexdigit())
            .unwrap_or((from + max).min(len))
    };
    match chars.get(j + 1) {
        Some('u') if chars.get(j + 2) == Some(&'{') => (j + 3..len)
            .find(|&k| chars[k] == '}')
            .map_or(len, |k| k + 1),
        Some('x') => hex(j + 2, 2),
        Some('u') => hex(j + 2, 4),
        Some('U') => hex(j + 2, 8),
        Some(c) if c.is_digit(8) => (j + 1..(j + 4).min(len))
            .find(|&k| !chars[k].is_digit(8))
            .unwrap_or((j + 4).min(len)),
        Some(_) => j + 2,
        None => len,
    }
}

/// Where a string whose body starts at `body` ends, without pushing.
fn str_end(chars: &[char], body: usize, close: &str, escape: Escape) -> usize {
    let close: Vec<char> = close.chars().collect();
    let mut j = body;
    while j < chars.len() {
        if let Escape::With(e) = escape {
            if chars[j] == e {
                j += 2;
                continue;
            }
        }
        if chars[j..].starts_with(&close) {
            let after = j + close.len();
            if escape == Escape::Doubled && chars[after..].starts_with(&close) {
                j = after + close.len();
                continue;
            }
            return after;
        }
        j += 1;
    }
    chars.len()
}

/// Lexes the string opened at `start` whose body starts at `body`, pushing
/// `base` for its text, `string.escape` for escapes, `string.interpolation`
/// around embedded code and `variable` for `$name`s; `placeholders` marks
/// `{…}` format placeholders. Returns its end.
pub fn lex_str(
    cx: &mut Cx<'_>,
    rule: &Str,
    start: usize,
    body: usize,
    close: &str,
    base: TokenKind,
    placeholders: bool,
) -> usize {
    lex_str_to(cx, rule, start, body, close, base, placeholders).0
}

/// The positions in `[from, end)` that code covers, not the strings or
/// comments among the tokens pushed since `mark`: where an embedded
/// language may end (`?>`, a closing brace). A comment that starts with one
/// of `line_comments` does not hide its positions (PHP's `// … ?>` ends the
/// code).
pub fn outside_code<'c>(
    cx: &'c Cx<'_>,
    mark: usize,
    from: usize,
    end: usize,
    line_comments: &'c [&str],
) -> impl Iterator<Item = usize> + 'c {
    let hidden: Vec<(usize, usize)> = cx
        .tokens_since(mark)
        .iter()
        .filter(|t| match t.kind {
            TokenKind::String | TokenKind::StringEscape | TokenKind::StringInterpolation => true,
            TokenKind::Comment | TokenKind::CommentDoc => {
                !line_comments.iter().any(|m| cx.starts_with(t.start, m))
            }
            _ => false,
        })
        .map(|t| (t.start, t.end))
        .collect();
    let mut next = 0;
    (from..end).filter(move |&j| {
        while next < hidden.len() && hidden[next].1 <= j {
            next += 1;
        }
        !hidden.get(next).is_some_and(|&(s, e)| s <= j && j < e)
    })
}

/// [`lex_str`], also telling whether the string closed on the line (when it
/// did not, a multi-line string goes on: start the next line with
/// `start == body == 0`).
pub fn lex_str_to(
    cx: &mut Cx<'_>,
    rule: &Str,
    start: usize,
    body: usize,
    close: &str,
    base: TokenKind,
    placeholders: bool,
) -> (usize, bool) {
    let chars = cx.chars();
    let len = chars.len();
    let close_len = close.chars().count();
    let mut seg = start;
    let mut j = body;
    'scan: while j < len {
        let c = chars[j];
        if (rule.doubled_braces || placeholders)
            && (cx.starts_with(j, "{{") || cx.starts_with(j, "}}"))
        {
            cx.push(seg, j, base);
            cx.push(j, j + 2, TokenKind::StringEscape);
            j += 2;
            seg = j;
            continue;
        }
        if placeholders && c == '{' {
            let end = (j..len).find(|&k| chars[k] == '}').map_or(len, |k| k + 1);
            cx.push(seg, j, base);
            cx.push(j, end, TokenKind::StringInterpolation);
            j = end;
            seg = j;
            continue;
        }
        for interp in rule.interps {
            if cx.starts_with(j, interp.open) {
                let inner = j + interp.open.chars().count();
                let end = matching(chars, inner, interp.close);
                cx.push(seg, j, base);
                cx.push(j, inner, TokenKind::StringInterpolation);
                if let Some(language) = Language::by_id(interp.language) {
                    cx.embed(language, inner, end.unwrap_or(len));
                }
                j = match end {
                    Some(e) => {
                        cx.push(e, e + 1, TokenKind::StringInterpolation);
                        e + 1
                    }
                    None => len,
                };
                seg = j;
                continue 'scan;
            }
        }
        if let Escape::With(e) = rule.escape {
            if c == e {
                let end = escape_end(chars, j);
                cx.push(seg, j, base);
                cx.push(j, end, TokenKind::StringEscape);
                j = end;
                seg = j;
                continue;
            }
        }
        if cx.starts_with(j, close) {
            let after = j + close_len;
            if rule.escape == Escape::Doubled && cx.starts_with(after, close) {
                cx.push(seg, j, base);
                cx.push(j, after + close_len, TokenKind::StringEscape);
                j = after + close_len;
                seg = j;
                continue;
            }
            cx.push(seg, after, base);
            return (after, true);
        }
        if rule.dollar_names && c == '$' {
            let end = dollar_end(chars, j);
            if end > j + 1 {
                cx.push(seg, j, base);
                cx.push(j, end, TokenKind::Variable);
                j = end;
                seg = j;
                continue;
            }
        }
        j += 1;
    }
    cx.push(seg, len, base);
    (len, false)
}

/// The end of a regex literal at `i` (`/`), with its flags, if it closes
/// on the line.
fn regex_end(chars: &[char], i: usize) -> Option<usize> {
    let mut class = false;
    let mut j = i + 1;
    if matches!(chars.get(j), Some('/' | '*') | None) {
        return None;
    }
    while j < chars.len() {
        match chars[j] {
            '\\' => j += 1,
            '[' => class = true,
            ']' => class = false,
            '/' if !class => return Some(scan_while(chars, j + 1, char::is_alphabetic)),
            _ => {}
        }
        j += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chars(s: &str) -> Vec<char> {
        s.chars().collect()
    }

    #[test]
    fn helpers() {
        assert!(is_caps("MAX_LEN"));
        assert!(is_caps("V2"));
        assert!(!is_caps("A"));
        assert!(!is_caps("Max"));
        assert!(!is_caps("_"));
        let c = chars("f(a, (b), \")\") + 1");
        assert_eq!(matching(&c, 2, ')'), Some(13));
        assert_eq!(matching(&chars("{a"), 1, '}'), None);
        assert_eq!(dollar_end(&chars("$HOME/x"), 0), 5);
        assert_eq!(dollar_end(&chars("${a:-{b}} c"), 0), 9);
        assert_eq!(dollar_end(&chars("$@"), 0), 2);
        assert_eq!(dollar_end(&chars("$ x"), 0), 1);
        assert_eq!(escape_end(&chars(r"\u{1F600}x"), 0), 9);
        assert_eq!(escape_end(&chars(r"\x41z"), 0), 4);
        assert_eq!(escape_end(&chars(r"\0127"), 0), 4);
        assert_eq!(escape_end(&chars(r"\n"), 0), 2);
        assert_eq!(regex_end(&chars("/a[/]b/gi;"), 0), Some(9));
        assert_eq!(regex_end(&chars("/ 2"), 0), None);
        assert_eq!(str_end(&chars("'it''s' x"), 1, "'", Escape::Doubled), 7);
    }
}
