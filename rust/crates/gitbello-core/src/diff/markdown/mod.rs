//! Markdown files drawn as a document, with what changed marked on it: the
//! diff's Preview mode. Both sides are parsed into a flat list of blocks
//! (paragraphs, headings, list items, code, tables…; containers become each
//! block's quote depth, list depth and marker), the blocks are compared, and
//! a block changed on both sides shows once with its changed words, lines
//! or rows marked. The UI only lays the blocks out.

mod blocks;
mod compare;
pub mod fold;
mod images;
mod inline;
pub mod links;
pub mod seq;

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub use blocks::parse;
pub use compare::compare;
pub use fold::{Folds, PreviewLayout, PreviewRow};
pub use images::{read_images, ImageRef, MarkdownImage, MAX_IMAGES, MAX_PICTURE_BYTES};
pub use links::{resolve_link, Anchors, LinkTarget};

use super::image::ImageFormat;
use crate::highlight::{fence_language, LineState, Syntax, Token};

use super::image::{is_zero, new_side_on_disk};
use super::{DiffContent, DiffTarget, FileDiff};
use crate::backend::GitBackend;
use crate::git::{CancelToken, GitError, GitErrorKind};

/// Sides larger than this many bytes are not previewed.
pub const MAX_MARKDOWN_BYTES: usize = 2 * 1024 * 1024;

/// Whether `path`'s extension (any case) names a Markdown file.
pub fn is_markdown_path(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .is_some_and(|e| matches!(e.as_str(), "md" | "markdown" | "mdown" | "mkd" | "mdx"))
}

/// Whether the Preview mode is offered for `diff` of `path`: a Markdown file
/// with text lines.
pub fn previews(diff: &FileDiff, path: &Path) -> bool {
    is_markdown_path(path) && diff.content == DiffContent::Text && !diff.is_empty()
}

/// Inline styles of a [`Span`], as bits.
pub mod style {
    pub const STRONG: u8 = 1;
    pub const EMPHASIS: u8 = 2;
    pub const CODE: u8 = 4;
    pub const STRIKE: u8 = 8;
    pub const LINK: u8 = 16;
    pub const IMAGE: u8 = 32;
}

/// How a block, span, code line or table row changed between the sides.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Change {
    #[default]
    Same,
    Added,
    Removed,
    /// A block on both sides whose content differs (its parts say how).
    Changed,
}

impl Change {
    pub fn id(self) -> &'static str {
        match self {
            Self::Same => "same",
            Self::Added => "added",
            Self::Removed => "removed",
            Self::Changed => "changed",
        }
    }
}

/// A run of text in one style. `link` is the target of a link or the source
/// of an image.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct Span {
    pub text: String,
    pub style: u8,
    pub link: Option<String>,
    pub change: Change,
}

/// What starts a list item's first block.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ListMarker {
    Bullet,
    Ordered(u64),
    /// A task list item, done or not.
    Task(bool),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Align {
    #[default]
    None,
    Left,
    Center,
    Right,
}

impl Align {
    pub fn id(self) -> &'static str {
        match self {
            Self::None => "",
            Self::Left => "left",
            Self::Center => "center",
            Self::Right => "right",
        }
    }
}

/// A line of a code block.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CodeLine {
    pub text: String,
    pub change: Change,
}

/// A table row: its cells' spans.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Row {
    pub cells: Vec<Vec<Span>>,
    pub change: Change,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BlockKind {
    Paragraph,
    /// `#` to `######`.
    Heading(u8),
    /// Fenced or indented code, and front matter.
    Code,
    /// The first row is the header.
    Table,
    Rule,
}

impl BlockKind {
    pub fn id(self) -> &'static str {
        match self {
            Self::Paragraph => "paragraph",
            Self::Heading(_) => "heading",
            Self::Code => "code",
            Self::Table => "table",
            Self::Rule => "rule",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Content {
    Text(Vec<Span>),
    /// `info` is the fence's language tag.
    Code {
        info: String,
        lines: Vec<CodeLine>,
    },
    Table {
        aligns: Vec<Align>,
        rows: Vec<Row>,
    },
    None,
}

/// A block with its containers: `quote` blockquotes and `indent` lists
/// around it; `marker` on the first block of a list item.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Block {
    pub kind: BlockKind,
    pub quote: u8,
    pub indent: u8,
    pub marker: Option<ListMarker>,
    pub content: Content,
}

/// A block of the preview and how it changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShownBlock {
    pub block: Block,
    pub change: Change,
    /// A code block's syntax tokens, one list per line (each side's lines
    /// lexed in order); empty for other blocks and unknown languages.
    pub syntax: Vec<Vec<Token>>,
    /// A heading's anchor, as GitHub makes it (none for a removed one).
    pub anchor: Option<String>,
}

impl ShownBlock {
    pub fn new(block: Block, change: Change) -> Self {
        Self {
            block,
            change,
            syntax: Vec::new(),
            anchor: None,
        }
    }
}

/// The blocks of the preview, both sides merged in document order.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MarkdownDiff {
    pub blocks: Vec<ShownBlock>,
    /// Why there is no preview: a side larger than [`MAX_MARKDOWN_BYTES`].
    pub too_large: bool,
    /// The Markdown file, repository-relative: links resolve against it.
    pub path: PathBuf,
    /// Only the old side exists (a deleted file): its pictures are old.
    pub old_only: bool,
    /// The repository's pictures the blocks show, at most [`MAX_IMAGES`].
    pub images: Vec<ImageRef>,
}

impl MarkdownDiff {
    /// Index of each block that changed, in order (for jumping between them).
    pub fn changes(&self) -> Vec<usize> {
        self.blocks
            .iter()
            .enumerate()
            .filter(|(_, b)| b.change != Change::Same)
            .map(|(i, _)| i)
            .collect()
    }

    /// The picture `span` of block `block` shows: its index in
    /// [`MarkdownDiff::images`].
    pub fn image_of(&self, block: usize, span: &Span) -> Option<usize> {
        let image = self.image_ref(block, span)?;
        self.images.iter().position(|i| *i == image)
    }

    /// Where a span's link points, from this document.
    pub fn link_target(&self, link: &str) -> LinkTarget {
        resolve_link(&self.path, link)
    }

    fn image_ref(&self, block: usize, span: &Span) -> Option<ImageRef> {
        if span.style & style::IMAGE == 0 {
            return None;
        }
        let LinkTarget::File { path, .. } = self.link_target(span.link.as_deref()?) else {
            return None;
        };
        ImageFormat::for_path(&path)?;
        let block_removed = self.blocks.get(block)?.change == Change::Removed;
        let old = self.old_only
            || span.change == Change::Removed
            || (span.change == Change::Same && block_removed);
        Some(ImageRef { path, old })
    }

    /// Fills each block's syntax tokens and anchor, and the pictures.
    fn finish(&mut self) {
        let mut anchors = Anchors::default();
        for block in &mut self.blocks {
            match &block.block.content {
                Content::Code { info, lines } => block.syntax = code_tokens(info, lines),
                Content::Text(spans)
                    if matches!(block.block.kind, BlockKind::Heading(_))
                        && block.change != Change::Removed =>
                {
                    let text: String = spans
                        .iter()
                        .filter(|s| s.change != Change::Removed)
                        .map(|s| s.text.as_str())
                        .collect();
                    block.anchor = Some(anchors.next(&text));
                }
                _ => {}
            }
        }
        let mut images = Vec::new();
        'blocks: for (i, block) in self.blocks.iter().enumerate() {
            let spans: Box<dyn Iterator<Item = &Span>> = match &block.block.content {
                Content::Text(spans) => Box::new(spans.iter()),
                Content::Table { rows, .. } => {
                    Box::new(rows.iter().flat_map(|r| r.cells.iter().flatten()))
                }
                Content::Code { .. } | Content::None => continue,
            };
            for span in spans {
                if let Some(image) = self.image_ref(i, span) {
                    if !images.contains(&image) {
                        if images.len() == MAX_IMAGES {
                            break 'blocks;
                        }
                        images.push(image);
                    }
                }
            }
        }
        self.images = images;
    }
}

/// The tokens of each line of a code block in the language its fence names:
/// the old side's lines (unchanged and removed) lexed in order, and the new
/// side's (unchanged and added).
fn code_tokens(info: &str, lines: &[CodeLine]) -> Vec<Vec<Token>> {
    let tag = info
        .split(|c: char| c.is_whitespace() || c == ',')
        .next()
        .unwrap_or("");
    let Some(language) = fence_language(tag) else {
        return Vec::new();
    };
    let texts: Vec<String> = lines
        .iter()
        .filter(|l| l.change != Change::Removed)
        .map(|l| l.text.clone())
        .collect();
    let syntax = Syntax::new(Some(language), &texts);
    let (mut old, mut new) = (LineState::default(), LineState::default());
    lines
        .iter()
        .map(|line| match line.change {
            Change::Removed => {
                let (tokens, next) = syntax.highlight_from(&line.text, old);
                old = next;
                tokens
            }
            Change::Added | Change::Changed => {
                let (tokens, next) = syntax.highlight_from(&line.text, new);
                new = next;
                tokens
            }
            Change::Same => {
                let (tokens, next) = syntax.highlight_from(&line.text, new);
                old = if old == new {
                    next
                } else {
                    syntax.highlight_from(&line.text, old).1
                };
                new = next;
                tokens
            }
        })
        .collect()
}

/// The preview of `old` → `new`. With one side only (an added or deleted
/// file) it is that document, nothing marked.
pub fn diff_texts(old: Option<&str>, new: Option<&str>) -> MarkdownDiff {
    diff_document(Path::new(""), old, new)
}

/// [`diff_texts`] of the Markdown file at the repository-relative `path`
/// (links and pictures resolve against it).
pub fn diff_document(path: &Path, old: Option<&str>, new: Option<&str>) -> MarkdownDiff {
    let mut diff = match (old, new) {
        (Some(old), Some(new)) => compare(&parse(old), &parse(new)),
        (Some(one), None) | (None, Some(one)) => MarkdownDiff {
            blocks: parse(one)
                .into_iter()
                .map(|block| ShownBlock::new(block, Change::Same))
                .collect(),
            old_only: new.is_none(),
            ..MarkdownDiff::default()
        },
        (None, None) => MarkdownDiff::default(),
    };
    diff.path = path.to_path_buf();
    diff.finish();
    diff
}

/// Reads both sides of `diff` (of `target` in `toplevel`) when it offers the
/// Preview mode (see [`previews`]) and compares them.
pub fn read_sides(
    backend: &dyn GitBackend,
    toplevel: &Path,
    target: &DiffTarget,
    diff: &FileDiff,
    cancel: &CancelToken,
) -> Result<Option<Arc<MarkdownDiff>>, GitError> {
    if !previews(diff, &target.path) {
        return Ok(None);
    }
    let header = &diff.header;
    let old = match header.old_oid.as_deref().filter(|o| !is_zero(o)) {
        Some(oid) if !header.new_file => read_blob(backend, toplevel, oid, cancel)?,
        _ => Side::Missing,
    };
    let new = if header.deleted_file {
        Side::Missing
    } else if new_side_on_disk(target.kind) {
        read_file(&toplevel.join(&target.path))
    } else {
        match header.new_oid.as_deref().filter(|o| !is_zero(o)) {
            Some(oid) => read_blob(backend, toplevel, oid, cancel)?,
            None => Side::Missing,
        }
    };
    let (old, new) = match (old, new) {
        (Side::TooLarge, _) | (_, Side::TooLarge) => {
            return Ok(Some(Arc::new(MarkdownDiff {
                too_large: true,
                ..MarkdownDiff::default()
            })))
        }
        (old, new) => (old.text(), new.text()),
    };
    Ok(Some(Arc::new(diff_document(
        &target.path,
        old.as_deref(),
        new.as_deref(),
    ))))
}

enum Side {
    Missing,
    TooLarge,
    Text(Vec<u8>),
}

impl Side {
    fn text(self) -> Option<String> {
        match self {
            Self::Text(bytes) => Some(String::from_utf8_lossy(&bytes).into_owned()),
            Self::Missing | Self::TooLarge => None,
        }
    }
}

fn read_blob(
    backend: &dyn GitBackend,
    toplevel: &Path,
    spec: &str,
    cancel: &CancelToken,
) -> Result<Side, GitError> {
    match backend.blob(toplevel, spec, MAX_MARKDOWN_BYTES, cancel) {
        Ok(Some(bytes)) => Ok(Side::Text(bytes)),
        Ok(None) if cancel.is_cancelled() => Err(GitError::new(
            "cat-file",
            GitErrorKind::Cancelled,
            "cancelled",
        )),
        Ok(None) => Ok(Side::TooLarge),
        Err(err) if err.kind == GitErrorKind::Cancelled => Err(err),
        Err(_) => Ok(Side::Missing),
    }
}

fn read_file(path: &Path) -> Side {
    let Ok(meta) = fs::metadata(path) else {
        return Side::Missing;
    };
    if usize::try_from(meta.len()).map_or(true, |len| len > MAX_MARKDOWN_BYTES) {
        return Side::TooLarge;
    }
    fs::read(path).map_or(Side::Missing, Side::Text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_paths() {
        for path in ["README.md", "docs/a.MD", "x.markdown", "y.mdx"] {
            assert!(is_markdown_path(Path::new(path)), "{path}");
        }
        for path in ["md", "a.txt", "a.md.bak", "Makefile"] {
            assert!(!is_markdown_path(Path::new(path)), "{path}");
        }
    }

    #[test]
    fn changes_lists_the_changed_blocks() {
        let diff = diff_texts(
            Some("# A\n\nsame\n\nold\n\nmore\n"),
            Some("# A\n\nsame\n\nnew\n\nwords\n"),
        );
        // Nothing in common: removed, then added.
        assert_eq!(diff.changes(), vec![2, 3, 4, 5]);
        let edited = diff_texts(Some("a\n\none two three\n"), Some("a\n\none two four\n"));
        assert_eq!(edited.changes(), vec![1]);
        let added = diff_texts(None, Some("one\n\ntwo\n"));
        assert_eq!(added.blocks.len(), 2);
        assert!(added.changes().is_empty());
    }

    #[test]
    fn code_is_coloured_per_side_and_headings_get_anchors() {
        let diff = diff_texts(
            Some("# Title\n\n```rust\nlet a = \"/*\";\nfn old() {}\n```\n"),
            Some("# Title\n\n## Title\n\n```rust\nlet a = \"/*\";\nfn new() {}\n```\n\n```\nplain\n```\n"),
        );
        let anchors: Vec<Option<&str>> = diff.blocks.iter().map(|b| b.anchor.as_deref()).collect();
        assert_eq!(anchors, vec![Some("title"), Some("title-1"), None, None]);
        let code = &diff.blocks[2];
        let Content::Code { lines, .. } = &code.block.content else {
            panic!("not code: {code:?}");
        };
        assert_eq!(code.syntax.len(), lines.len());
        // `fn` is a keyword on both sides; the string did not open a comment.
        for (line, tokens) in lines.iter().zip(&code.syntax).skip(1) {
            assert!(line.text.starts_with("fn "), "{line:?}");
            assert!(
                tokens.first().is_some_and(|t| t.start == 0 && t.end == 2),
                "{tokens:?}"
            );
        }
        assert!(diff.blocks[3].syntax.is_empty(), "no language, no colours");
    }

    #[test]
    fn pictures_belong_to_their_side() {
        let diff = diff_document(
            Path::new("docs/a.md"),
            Some("![x](x.png)\n\nkeep ![o](old.png)\n"),
            Some("![x](x.png)\n\nkeep ![n](new.png) ![w](https://w.dev/w.png) ![t](t.txt)\n"),
        );
        let refs: Vec<(String, bool)> = diff
            .images
            .iter()
            .map(|i| (i.path.to_string_lossy().replace('\\', "/"), i.old))
            .collect();
        assert_eq!(
            refs,
            vec![
                ("docs/x.png".to_owned(), false),
                ("docs/old.png".to_owned(), true),
                ("docs/new.png".to_owned(), false),
            ]
        );
    }
}
