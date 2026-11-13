//! The lexer interface: a lexer reads one line through a [`Cx`] and pushes
//! tokens. A line starts from a [`LineState`] and ends in one: a lexer reads
//! its own part with [`Cx::state`] (0 at the start) and leaves what is still
//! open (a block comment, a string) with [`Cx::set_state`]. Code embedded
//! with [`Cx::embed`] starts from 0 and its state is dropped at the end of
//! its range; code embedded with [`Cx::embed_open`] (a `<script>` block that
//! goes on) keeps its state in the frame above, for the next line.

use super::hints::FileHints;
use super::kind::TokenKind;
use super::languages::Language;
use super::Token;

/// Deepest nesting of one language inside another.
pub const MAX_DEPTH: usize = 4;

/// A lexer for one language.
pub trait Lexer: Sync {
    /// Lexes `cx.chars()` from `cx.pos` to the end, pushing tokens in order.
    fn lex(&self, cx: &mut Cx<'_>);
}

/// One level of the nesting stack: the language and its lexer's own state.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
struct Frame {
    language: u16,
    state: u16,
}

/// Where a line starts: a stack of languages (the file's own at the
/// bottom) with each lexer's own state. Small and `Copy`, so one can be
/// kept per line.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct LineState {
    frames: [Frame; MAX_DEPTH],
    depth: u8,
}

impl LineState {
    /// The state a file starts in (the default).
    pub const START: Self = Self {
        frames: [Frame {
            language: 0,
            state: 0,
        }; MAX_DEPTH],
        depth: 0,
    };

    /// True for the state a file starts in.
    pub fn is_start(&self) -> bool {
        self.depth == 0 && self.frames[0].state == 0
    }

    /// The bottom lexer's own state (0 at the start).
    pub fn state(&self) -> u16 {
        self.frames[0].state
    }

    /// Languages pushed above the file's own (0 at the start).
    pub fn depth(&self) -> usize {
        usize::from(self.depth)
    }

    /// The tag of the code nested at `level` (1-based; see
    /// [`Cx::embed_open`]).
    pub fn language_at(&self, level: usize) -> Option<u16> {
        (level >= 1 && level <= self.depth()).then(|| self.frames[level].language)
    }

    /// The state of the code nested at `level` (1-based).
    pub fn state_at(&self, level: usize) -> Option<u16> {
        (level >= 1 && level <= self.depth()).then(|| self.frames[level].state)
    }

    /// The same state with nothing above `depth` (unused frames zeroed, so
    /// equal states compare equal).
    fn cut(mut self, depth: usize) -> Self {
        let depth = depth.min(MAX_DEPTH - 1);
        for frame in &mut self.frames[depth + 1..] {
            *frame = Frame::default();
        }
        self.depth = u8::try_from(depth).unwrap_or_default();
        self
    }

    /// The state the next line starts in when the bottom lexer left `state`
    /// and the code it embedded `nested`.
    pub(super) fn next(state: u16, nested: Option<LineState>) -> Self {
        let mut out = nested.unwrap_or(Self::START);
        out.frames[0] = Frame { language: 0, state };
        let depth = out.depth();
        out.cut(depth)
    }
}

/// A tag for embedded code of a registered language (see
/// [`Cx::embed_open`]).
pub fn language_tag(language: Language) -> u16 {
    u16::try_from(language.index() + 1).unwrap_or(u16::MAX)
}

/// What a lexer sees and writes while it reads a line.
pub struct Cx<'a> {
    chars: &'a [char],
    /// Where the lexer is; it may move it freely.
    pub pos: usize,
    hints: &'a FileHints,
    tokens: &'a mut Vec<Token>,
    state: u16,
    depth: usize,
    /// The state the line started in: the frames above `depth` are where
    /// code embedded with [`Cx::embed_open`] goes on from.
    incoming: LineState,
    /// The frames above `depth` the line leaves, from the last
    /// [`Cx::embed_open`].
    nested: Option<LineState>,
}

impl<'a> Cx<'a> {
    pub(super) fn new(
        chars: &'a [char],
        hints: &'a FileHints,
        tokens: &'a mut Vec<Token>,
        incoming: LineState,
    ) -> Self {
        Self {
            chars,
            pos: 0,
            hints,
            tokens,
            state: incoming.state(),
            depth: 0,
            incoming,
            nested: None,
        }
    }

    /// The text this lexer reads (for a nested language, only its part).
    pub fn chars(&self) -> &'a [char] {
        self.chars
    }

    pub fn len(&self) -> usize {
        self.chars.len()
    }

    pub fn is_empty(&self) -> bool {
        self.chars.is_empty()
    }

    /// The character at `i`, if inside the text.
    pub fn at(&self, i: usize) -> Option<char> {
        self.chars.get(i).copied()
    }

    /// True when `s` starts at `i`.
    pub fn starts_with(&self, i: usize, s: &str) -> bool {
        (i..)
            .zip(s.chars())
            .all(|(j, c)| self.chars.get(j) == Some(&c))
    }

    /// True when the text before `i` is only whitespace.
    pub fn at_line_start(&self, i: usize) -> bool {
        self.chars[..i.min(self.chars.len())]
            .iter()
            .all(|c| c.is_whitespace())
    }

    pub fn hints(&self) -> &FileHints {
        self.hints
    }

    /// This lexer's own state for the line (0 at the start).
    pub fn state(&self) -> u16 {
        self.state
    }

    /// Sets the state the next line starts in.
    pub fn set_state(&mut self, state: u16) {
        self.state = state;
    }

    /// Adds a token `[start, end)` of `kind`. Empty tokens are dropped and
    /// a token that overlaps the previous one is cut to start after it, so
    /// the tokens stay sorted and disjoint.
    pub fn push(&mut self, start: usize, end: usize, kind: TokenKind) {
        let end = end.min(self.chars.len());
        let start = self.tokens.last().map_or(start, |t| start.max(t.end));
        if end > start {
            self.tokens.push(Token { start, end, kind });
        }
    }

    /// Tokens pushed so far on the line (to roll back with
    /// [`Cx::truncate`]).
    pub fn token_count(&self) -> usize {
        self.tokens.len()
    }

    /// The tokens pushed since `mark` ([`Cx::token_count`]).
    pub fn tokens_since(&self, mark: usize) -> &[Token] {
        self.tokens.get(mark..).unwrap_or_default()
    }

    /// Drops the tokens pushed since `mark`, to lex that part again.
    pub fn truncate(&mut self, mark: usize) {
        self.tokens.truncate(mark);
    }

    /// Leaves the strings pushed since `mark` (with their escapes) as plain
    /// text: a data file's values, which would otherwise colour most of it.
    pub fn plain_strings_since(&mut self, mark: usize) {
        let mut index = 0;
        self.tokens.retain(|t| {
            index += 1;
            index <= mark || !matches!(t.kind, TokenKind::String | TokenKind::StringEscape)
        });
    }

    /// The embedded code this line leaves open so far: kept while other
    /// code is embedded, and put back with [`Cx::set_nested`].
    pub fn nested(&self) -> Option<LineState> {
        self.nested
    }

    pub fn set_nested(&mut self, nested: Option<LineState>) {
        self.nested = nested;
    }

    /// The state the code tagged `tag` left at its last [`Cx::embed_open`]
    /// on this line, else at the end of the line above.
    pub fn nested_state_of(&self, tag: u16) -> Option<u16> {
        let source = self.nested.unwrap_or(self.incoming);
        let level = self.depth + 1;
        if source.language_at(level) == Some(tag) {
            source.state_at(level)
        } else {
            None
        }
    }

    /// Lexes `[start, end)` with `lexer`, code that may go on past the
    /// line: with `resume` it starts from the state the code tagged `tag`
    /// left (see [`Cx::nested_state_of`]), else from 0, and its state is
    /// kept for the next line. Tag a registered language with
    /// [`language_tag`]. Past [`MAX_DEPTH`] the range stays plain.
    pub fn embed_open(
        &mut self,
        tag: u16,
        lexer: &dyn Lexer,
        start: usize,
        end: usize,
        resume: bool,
    ) {
        let end = end.min(self.chars.len());
        let level = self.depth + 1;
        if start > end || level >= MAX_DEPTH {
            return;
        }
        let incoming = self.open_frame(tag, resume);
        let mut inner = Cx {
            chars: &self.chars[..end],
            pos: start,
            hints: self.hints,
            tokens: self.tokens,
            state: incoming.frames[level].state,
            depth: level,
            incoming,
            nested: None,
        };
        lexer.lex(&mut inner);
        let (state, nested) = (inner.state, inner.nested);
        self.close_frame(tag, incoming, state, nested);
    }

    /// [`Cx::embed_open`] over `text`, code the line holds escaped (a
    /// script in a string, its `\"` unescaped): `map[k]` is where `text[k]`
    /// is on the line, and `map[text.len()]` where the code ends.
    pub fn embed_open_mapped(
        &mut self,
        tag: u16,
        lexer: &dyn Lexer,
        text: &[char],
        map: &[usize],
        resume: bool,
    ) {
        let level = self.depth + 1;
        if level >= MAX_DEPTH || map.len() != text.len() + 1 {
            return;
        }
        let incoming = self.open_frame(tag, resume);
        let mut tokens = Vec::new();
        let mut inner = Cx {
            chars: text,
            pos: 0,
            hints: self.hints,
            tokens: &mut tokens,
            state: incoming.frames[level].state,
            depth: level,
            incoming,
            nested: None,
        };
        lexer.lex(&mut inner);
        let (state, nested) = (inner.state, inner.nested);
        self.close_frame(tag, incoming, state, nested);
        for token in tokens {
            self.push(map[token.start], map[token.end], token.kind);
        }
    }

    /// The state code tagged `tag` embedded one level up starts in (see
    /// [`Cx::embed_open`]).
    fn open_frame(&self, tag: u16, resume: bool) -> LineState {
        let level = self.depth + 1;
        let source = self.nested.unwrap_or(self.incoming);
        if resume && source.language_at(level) == Some(tag) {
            return source;
        }
        let mut incoming = source.cut(level);
        incoming.frames[level] = Frame {
            language: tag,
            state: 0,
        };
        incoming
    }

    /// Keeps the state embedded code tagged `tag` left, for the next line.
    fn close_frame(
        &mut self,
        tag: u16,
        incoming: LineState,
        state: u16,
        nested: Option<LineState>,
    ) {
        let level = self.depth + 1;
        let mut out = nested.unwrap_or_else(|| incoming.cut(level));
        out.frames[level] = Frame {
            language: tag,
            state,
        };
        self.nested = Some(out);
    }

    /// Lexes `[start, end)` as `language`, pushing its tokens among this
    /// lexer's. Past [`MAX_DEPTH`] the range stays plain.
    pub fn embed(&mut self, language: Language, start: usize, end: usize) {
        self.embed_with(language.lexer(), start, end);
    }

    /// Lexes `[start, end)` with `lexer` (a mode of a language that is not
    /// registered on its own, such as CSS declarations), as [`Cx::embed`].
    pub fn embed_with(&mut self, lexer: &dyn Lexer, start: usize, end: usize) {
        let end = end.min(self.chars.len());
        if start >= end || self.depth + 1 >= MAX_DEPTH {
            return;
        }
        let level = self.depth + 1;
        let mut inner = Cx {
            chars: &self.chars[..end],
            pos: start,
            hints: self.hints,
            tokens: self.tokens,
            state: 0,
            depth: level,
            incoming: self.incoming.cut(level),
            nested: None,
        };
        lexer.lex(&mut inner);
    }
}
