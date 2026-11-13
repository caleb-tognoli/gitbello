//! Token kinds. Each has a stable name and an optional parent it falls back
//! to when a theme gives it no colour of its own; a kind without a parent
//! and without a colour is drawn as plain text.

/// What a token is. Ids (`id()`) are positions in [`TokenKind::ALL`]; add
/// new kinds at the end so existing ids stay put.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TokenKind {
    Keyword,
    Type,
    String,
    Number,
    Comment,
    Function,
    Variable,
    Constant,
    Key,
    Tag,
    Attribute,
    Operator,
    Punctuation,
    Annotation,
    MarkupHeading,
    MarkupEmphasis,
    MarkupLink,
    DiffAdded,
    DiffRemoved,
    DiffHeader,
    Column0,
    Column1,
    Column2,
    Column3,
    Column4,
    Column5,
    Column6,
    Column7,
    KeywordControl,
    Macro,
    CommentDoc,
    StringEscape,
    StringInterpolation,
    Regex,
    MarkupCode,
    MarkupQuote,
    MarkupList,
}

impl TokenKind {
    /// Every kind, in id order.
    pub const ALL: [TokenKind; 37] = [
        Self::Keyword,
        Self::Type,
        Self::String,
        Self::Number,
        Self::Comment,
        Self::Function,
        Self::Variable,
        Self::Constant,
        Self::Key,
        Self::Tag,
        Self::Attribute,
        Self::Operator,
        Self::Punctuation,
        Self::Annotation,
        Self::MarkupHeading,
        Self::MarkupEmphasis,
        Self::MarkupLink,
        Self::DiffAdded,
        Self::DiffRemoved,
        Self::DiffHeader,
        Self::Column0,
        Self::Column1,
        Self::Column2,
        Self::Column3,
        Self::Column4,
        Self::Column5,
        Self::Column6,
        Self::Column7,
        Self::KeywordControl,
        Self::Macro,
        Self::CommentDoc,
        Self::StringEscape,
        Self::StringInterpolation,
        Self::Regex,
        Self::MarkupCode,
        Self::MarkupQuote,
        Self::MarkupList,
    ];

    /// Number of kinds.
    pub const COUNT: usize = Self::ALL.len();

    /// The CSV column kinds, cycled through by field index.
    pub const COLUMNS: [TokenKind; 8] = [
        Self::Column0,
        Self::Column1,
        Self::Column2,
        Self::Column3,
        Self::Column4,
        Self::Column5,
        Self::Column6,
        Self::Column7,
    ];

    /// Stable id for the UI: the kind's index in [`TokenKind::ALL`].
    pub fn id(self) -> i32 {
        self as i32
    }

    /// The kind with id `id`.
    pub fn from_id(id: i32) -> Option<Self> {
        usize::try_from(id)
            .ok()
            .and_then(|i| Self::ALL.get(i).copied())
    }

    /// The kind's name, as themes know it (`string.escape`).
    pub fn name(self) -> &'static str {
        match self {
            Self::Keyword => "keyword",
            Self::Type => "type",
            Self::String => "string",
            Self::Number => "number",
            Self::Comment => "comment",
            Self::Function => "function",
            Self::Variable => "variable",
            Self::Constant => "constant",
            Self::Key => "key",
            Self::Tag => "tag",
            Self::Attribute => "attribute",
            Self::Operator => "operator",
            Self::Punctuation => "punctuation",
            Self::Annotation => "annotation",
            Self::MarkupHeading => "markup.heading",
            Self::MarkupEmphasis => "markup.emphasis",
            Self::MarkupLink => "markup.link",
            Self::DiffAdded => "diff.added",
            Self::DiffRemoved => "diff.removed",
            Self::DiffHeader => "diff.header",
            Self::Column0 => "column.0",
            Self::Column1 => "column.1",
            Self::Column2 => "column.2",
            Self::Column3 => "column.3",
            Self::Column4 => "column.4",
            Self::Column5 => "column.5",
            Self::Column6 => "column.6",
            Self::Column7 => "column.7",
            Self::KeywordControl => "keyword.control",
            Self::Macro => "macro",
            Self::CommentDoc => "comment.doc",
            Self::StringEscape => "string.escape",
            Self::StringInterpolation => "string.interpolation",
            Self::Regex => "regex",
            Self::MarkupCode => "markup.code",
            Self::MarkupQuote => "markup.quote",
            Self::MarkupList => "markup.list",
        }
    }

    /// The kind with name `name`.
    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.iter().copied().find(|k| k.name() == name)
    }

    /// The kind this one falls back to when it has no colour of its own.
    pub fn parent(self) -> Option<Self> {
        match self {
            Self::KeywordControl => Some(Self::Keyword),
            Self::Macro => Some(Self::Function),
            Self::CommentDoc => Some(Self::Comment),
            Self::StringEscape | Self::Regex | Self::MarkupCode => Some(Self::String),
            Self::StringInterpolation => Some(Self::StringEscape),
            Self::MarkupQuote => Some(Self::Comment),
            Self::MarkupList => Some(Self::Punctuation),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_names_and_parents() {
        for (i, kind) in TokenKind::ALL.iter().enumerate() {
            assert_eq!(kind.id(), i32::try_from(i).unwrap());
            assert_eq!(TokenKind::from_id(kind.id()), Some(*kind));
            assert_eq!(TokenKind::from_name(kind.name()), Some(*kind));
            // Parents come before their children, so one pass resolves them.
            if let Some(parent) = kind.parent() {
                assert!(parent.id() < kind.id(), "{kind:?}");
            }
        }
        let mut names: Vec<&str> = TokenKind::ALL.iter().map(|k| k.name()).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), TokenKind::COUNT);
        assert_eq!(TokenKind::from_id(-1), None);
        assert_eq!(TokenKind::from_name("nope"), None);
        // The first five keep the ids they had before the kinds grew.
        assert_eq!(TokenKind::Comment.id(), 4);
    }
}
