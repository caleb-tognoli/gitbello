//! The state each line of a text starts in, found by lexing the text once
//! from its first line, so that a line can be lexed alone and still be
//! coloured as part of a block comment or a string that started above it.

use std::sync::Arc;

use super::hints::Syntax;
use super::lexer::LineState;

/// Lines between two checks of the stop condition in [`LineStates::compute`].
const CHECK_EVERY: usize = 1024;

/// The state each line of a text starts in. Only lines that do not start in
/// the start state are kept (most lines of most files do), so the cost is a
/// few bytes per line inside a comment or a string.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LineStates {
    /// `(line index, state)` for lines that start in another state than the
    /// start, by line.
    entries: Vec<(u32, LineState)>,
    /// Lines the text has.
    lines: usize,
}

impl LineStates {
    /// The states of `lines` (raw, as stored: `\r` and tabs kept) lexed with
    /// `syntax`; `None` when `stop` returns true (checked every 1,024 lines).
    pub fn compute<'a>(
        syntax: &Syntax,
        lines: impl IntoIterator<Item = &'a [u8]>,
        stop: impl Fn() -> bool,
    ) -> Option<Self> {
        let mut out = Self::default();
        let mut state = LineState::default();
        for (i, line) in lines.into_iter().enumerate() {
            if i % CHECK_EVERY == CHECK_EVERY - 1 && stop() {
                return None;
            }
            out.push(state);
            state = syntax.next_state(line, state);
        }
        Some(out)
    }

    /// Adds the next line, starting in `state`.
    pub fn push(&mut self, state: LineState) {
        if !state.is_start() {
            if let Ok(line) = u32::try_from(self.lines) {
                self.entries.push((line, state));
            }
        }
        self.lines += 1;
    }

    /// The states of the lines of `text` (split at `\n`).
    pub fn of_text(syntax: &Syntax, text: &[u8], stop: impl Fn() -> bool) -> Option<Self> {
        let text = text.strip_suffix(b"\n").unwrap_or(text);
        if text.is_empty() {
            return Some(Self::default());
        }
        Self::compute(syntax, text.split(|&b| b == b'\n'), stop)
    }

    /// The state line `index` (0-based) starts in.
    pub fn before(&self, index: usize) -> LineState {
        let Ok(index) = u32::try_from(index) else {
            return LineState::default();
        };
        self.entries
            .binary_search_by_key(&index, |(line, _)| *line)
            .map_or_else(|_| LineState::default(), |at| self.entries[at].1)
    }

    /// Lines of the text.
    pub fn line_count(&self) -> usize {
        self.lines
    }

    /// Lines that start in another state than the start.
    pub fn kept(&self) -> usize {
        self.entries.len()
    }
}

/// Whether the line states of a diff (or a conflicted file) are known.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum StatesStatus {
    /// Plain text, or nothing to colour.
    #[default]
    None,
    /// Being computed: lines are lexed alone meanwhile.
    Loading,
    Ready,
    /// A side was too large to read: its lines are lexed alone.
    Skipped,
}

impl StatesStatus {
    pub fn id(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Loading => "loading",
            Self::Ready => "ready",
            Self::Skipped => "skipped",
        }
    }
}

/// The line states of both sides of a diff, each by its 1-based line
/// numbers; a side without states lexes its lines alone.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DiffStates {
    pub old: Option<Arc<LineStates>>,
    pub new: Option<Arc<LineStates>>,
}

impl DiffStates {
    /// The state a diff line starts in: a removed line by its old number,
    /// others by the new one (by the old one when the new side has none).
    pub fn before(&self, removed: bool, old_line: Option<u32>, new_line: Option<u32>) -> LineState {
        let side = |states: &Option<Arc<LineStates>>, line: Option<u32>| {
            let states = states.as_ref()?;
            let index = usize::try_from(line?.checked_sub(1)?).ok()?;
            (index < states.line_count()).then(|| states.before(index))
        };
        let found = if removed {
            side(&self.old, old_line)
        } else {
            side(&self.new, new_line).or_else(|| side(&self.old, old_line))
        };
        found.unwrap_or_default()
    }

    pub fn is_empty(&self) -> bool {
        self.old.is_none() && self.new.is_none()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::highlight::{Language, TokenKind};

    #[test]
    fn a_block_comment_carries_to_the_lines_below() {
        let rust = Syntax::new(Language::by_id("rust"), &[]);
        let text = b"let a = 1; /* open\nstill inside\nclose */ let b = 2;\nlet c = 3;\n";
        let states = LineStates::of_text(&rust, text, || false).unwrap();
        assert_eq!(states.line_count(), 4);
        assert_eq!(states.kept(), 2);
        assert!(states.before(0).is_start());
        assert!(!states.before(1).is_start());
        assert!(states.before(3).is_start());
        assert!(states.before(99).is_start());
        let tokens = rust.highlight_line_from(b"still inside", states.before(1));
        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].kind, TokenKind::Comment);
        let tokens = rust.highlight_line_from(b"close */ let b = 2;", states.before(2));
        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[1].kind, TokenKind::Keyword);
    }

    #[test]
    fn diff_lines_take_the_state_of_their_side() {
        let rust = Syntax::new(Language::by_id("rust"), &[]);
        let old = LineStates::of_text(
            &rust,
            b"/* a
b */
c
",
            || false,
        )
        .unwrap();
        let new = LineStates::of_text(
            &rust,
            b"x
/* y
z */
",
            || false,
        )
        .unwrap();
        let states = DiffStates {
            old: Some(Arc::new(old)),
            new: Some(Arc::new(new)),
        };
        // Removed line 2 of the old side is inside the comment.
        assert!(!states.before(true, Some(2), None).is_start());
        // A context line goes by its new number: new line 2 starts at the
        // start, though old line 2 does not.
        assert!(states.before(false, Some(2), Some(2)).is_start());
        assert!(!states.before(false, None, Some(3)).is_start());
        // Past the end, or no number: the start.
        assert!(states.before(false, None, Some(9)).is_start());
        assert!(states.before(true, None, Some(3)).is_start());
        let old_only = DiffStates {
            new: None,
            ..states
        };
        assert!(!old_only.before(false, Some(2), Some(1)).is_start());
        assert!(DiffStates::default().is_empty());
    }

    #[test]
    fn plain_text_and_stopping() {
        let plain = Syntax::plain();
        let states = LineStates::of_text(&plain, b"/* a\nb", || false).unwrap();
        assert_eq!(states.kept(), 0);
        assert_eq!(
            LineStates::of_text(&plain, b"", || false)
                .unwrap()
                .line_count(),
            0
        );
        let many = "x\n".repeat(5_000);
        assert!(LineStates::of_text(&plain, many.as_bytes(), || true).is_none());
    }
}
