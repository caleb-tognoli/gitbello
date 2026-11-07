//! How a diff can be shown (PLAN M7.8): which viewer draws it and the modes
//! that viewer offers for it, in the order the cycle shortcut goes through
//! them. A file with one side only offers one mode, and the UI shows no
//! picker for fewer than two.

use std::path::Path;

use super::image::image_format;
use super::{DiffContent, FileDiff};
use crate::merge::{ConflictFile, ConflictKind};

/// What draws a diff.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Viewer {
    /// Lines of text (also the resolver's blocks).
    Text,
    /// Old and new pictures.
    Image,
    /// Nothing to switch: a binary summary, an empty diff, a message.
    #[default]
    None,
}

impl Viewer {
    pub fn id(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Image => "image",
            Self::None => "none",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "text" => Self::Text,
            "image" => Self::Image,
            "none" => Self::None,
            _ => return None,
        })
    }

    /// Every mode the viewer has, in cycle order.
    pub fn all_modes(self) -> &'static [DiffMode] {
        match self {
            Self::Text => &[DiffMode::Unified, DiffMode::Split],
            Self::Image => &[
                DiffMode::Split,
                DiffMode::Onion,
                DiffMode::Swipe,
                DiffMode::Difference,
            ],
            Self::None => &[],
        }
    }

    /// The mode a viewer starts in before one is saved.
    pub fn default_mode(self) -> DiffMode {
        match self {
            Self::Text => DiffMode::Unified,
            Self::Image => DiffMode::Split,
            Self::None => DiffMode::Single,
        }
    }
}

/// One way to show a diff. `Split` is old | new for text and images alike.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffMode {
    /// Old and new lines in one column.
    Unified,
    /// Old on the left, new on the right.
    Split,
    /// New over old with an opacity slider.
    Onion,
    /// A divider dragged across reveals old on one side, new on the other.
    Swipe,
    /// Changed pixels highlighted.
    Difference,
    /// The only side there is (an added or deleted image).
    Single,
}

impl DiffMode {
    pub fn id(self) -> &'static str {
        match self {
            Self::Unified => "unified",
            Self::Split => "split",
            Self::Onion => "onion",
            Self::Swipe => "swipe",
            Self::Difference => "difference",
            Self::Single => "single",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "unified" => Self::Unified,
            "split" => Self::Split,
            "onion" => Self::Onion,
            "swipe" => Self::Swipe,
            "difference" => Self::Difference,
            "single" => Self::Single,
            _ => return None,
        })
    }
}

/// The viewer of a diff and its modes, in cycle order.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Offered {
    pub viewer: Viewer,
    pub modes: Vec<DiffMode>,
}

impl Offered {
    fn none() -> Self {
        Self::default()
    }

    fn text(both_sides: bool) -> Self {
        Self {
            viewer: Viewer::Text,
            modes: if both_sides {
                Viewer::Text.all_modes().to_vec()
            } else {
                vec![DiffMode::Unified]
            },
        }
    }

    /// `saved` when it is offered, else the first mode offered (`None` when
    /// nothing is). The saved setting is not changed by a fallback.
    pub fn mode(&self, saved: DiffMode) -> Option<DiffMode> {
        if self.modes.contains(&saved) {
            Some(saved)
        } else {
            self.modes.first().copied()
        }
    }

    /// The mode after `current`, wrapping; `None` with fewer than two modes.
    pub fn next(&self, current: DiffMode) -> Option<DiffMode> {
        if self.modes.len() < 2 {
            return None;
        }
        let at = self.modes.iter().position(|&m| m == current);
        Some(self.modes[at.map_or(0, |i| (i + 1) % self.modes.len())])
    }
}

/// How `diff` of `path` can be shown. Text with both sides offers unified
/// and split; an added or deleted file (untracked included) and a combined
/// diff offer unified only; an image (see [`image_format`]) offers the image
/// modes, or `single` with one side; other binary, too large and empty
/// diffs offer nothing.
pub fn offered(diff: &FileDiff, path: &Path) -> Offered {
    if diff.is_empty() {
        return Offered::none();
    }
    if image_format(diff, path).is_some() {
        let both = !diff.header.new_file && !diff.header.deleted_file;
        return Offered {
            viewer: Viewer::Image,
            modes: if both {
                Viewer::Image.all_modes().to_vec()
            } else {
                vec![DiffMode::Single]
            },
        };
    }
    match diff.content {
        DiffContent::Text => Offered::text(!diff.header.new_file && !diff.header.deleted_file),
        DiffContent::Combined => Offered::text(false),
        DiffContent::Binary { .. } | DiffContent::TooLarge { .. } => Offered::none(),
    }
}

/// How the resolver can show `file`: its conflict blocks unified or split;
/// a conflict without blocks (a card) offers nothing.
pub fn conflict_offered(file: &ConflictFile) -> Offered {
    match file.kind {
        ConflictKind::Content | ConflictKind::AddAdd if !file.blocks.is_empty() => {
            Offered::text(true)
        }
        _ => Offered::none(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::{parse_diff, untracked_diff};

    fn modes(diff: &FileDiff) -> (Viewer, Vec<&'static str>) {
        modes_of(diff, "f.txt")
    }

    fn modes_of(diff: &FileDiff, path: &str) -> (Viewer, Vec<&'static str>) {
        let offered = offered(diff, Path::new(path));
        (
            offered.viewer,
            offered.modes.iter().map(|m| m.id()).collect(),
        )
    }

    #[test]
    fn text_with_both_sides_offers_unified_and_split() {
        let modified = parse_diff(
            b"diff --git a/a.txt b/a.txt\nindex 1..2 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\n",
        )
        .unwrap();
        assert_eq!(modes(&modified), (Viewer::Text, vec!["unified", "split"]));
        let renamed = parse_diff(
            b"diff --git a/a.txt b/b.txt\nsimilarity index 80%\nrename from a.txt\nrename to b.txt\n--- a/a.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-a\n+b\n",
        )
        .unwrap();
        assert_eq!(modes(&renamed), (Viewer::Text, vec!["unified", "split"]));
    }

    #[test]
    fn one_sided_text_offers_unified_only() {
        let added = parse_diff(
            b"diff --git a/n.txt b/n.txt\nnew file mode 100644\nindex 0..2\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+n\n",
        )
        .unwrap();
        assert_eq!(modes(&added), (Viewer::Text, vec!["unified"]));
        let deleted = parse_diff(
            b"diff --git a/d.txt b/d.txt\ndeleted file mode 100644\nindex 1..0\n--- a/d.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-d\n",
        )
        .unwrap();
        assert_eq!(modes(&deleted), (Viewer::Text, vec!["unified"]));
        assert_eq!(
            modes(&untracked_diff(b"one\ntwo\n")),
            (Viewer::Text, vec!["unified"])
        );
    }

    #[test]
    fn binary_large_and_empty_offer_nothing() {
        let binary = parse_diff(
            b"diff --git a/i.png b/i.png\nindex 1..2 100644\nBinary files a/i.png and b/i.png differ\n",
        )
        .unwrap();
        assert_eq!(modes(&binary), (Viewer::None, vec![]));
        assert_eq!(modes(&untracked_diff(b"PNG\0data")), (Viewer::None, vec![]));
        let large = FileDiff {
            content: DiffContent::TooLarge { bytes: 9 },
            ..FileDiff::default()
        };
        assert_eq!(modes(&large), (Viewer::None, vec![]));
        assert_eq!(modes(&parse_diff(b"").unwrap()), (Viewer::None, vec![]));
        assert_eq!(modes(&untracked_diff(b"")), (Viewer::None, vec![]));
    }

    #[test]
    fn images_offer_the_image_modes() {
        let modified = parse_diff(
            b"diff --git a/i.png b/i.png\nindex 1..2 100644\nBinary files a/i.png and b/i.png differ\n",
        )
        .unwrap();
        assert_eq!(
            modes_of(&modified, "i.png"),
            (Viewer::Image, vec!["split", "onion", "swipe", "difference"])
        );
        assert_eq!(
            modes_of(&untracked_diff(b"PNG\0data"), "new.png"),
            (Viewer::Image, vec!["single"])
        );
        assert_eq!(
            modes_of(&untracked_diff(b"<svg/>\n"), "new.svg"),
            (Viewer::Image, vec!["single"])
        );
        let deleted = parse_diff(
            b"diff --git a/d.jpg b/d.jpg\ndeleted file mode 100644\nindex 1..0\nBinary files a/d.jpg and /dev/null differ\n",
        )
        .unwrap();
        assert_eq!(modes_of(&deleted, "d.jpg"), (Viewer::Image, vec!["single"]));
        assert_eq!(modes_of(&modified, "i.bin"), (Viewer::None, vec![]));
    }

    #[test]
    fn a_mode_not_offered_falls_back_to_the_first() {
        let one = Offered::text(false);
        assert_eq!(one.mode(DiffMode::Split), Some(DiffMode::Unified));
        assert_eq!(one.next(DiffMode::Unified), None);
        let both = Offered::text(true);
        assert_eq!(both.mode(DiffMode::Split), Some(DiffMode::Split));
        assert_eq!(both.next(DiffMode::Unified), Some(DiffMode::Split));
        assert_eq!(both.next(DiffMode::Split), Some(DiffMode::Unified));
        assert_eq!(both.next(DiffMode::Onion), Some(DiffMode::Unified));
        assert_eq!(Offered::none().mode(DiffMode::Unified), None);
    }

    #[test]
    fn conflicts_with_blocks_offer_both_text_modes() {
        let ids = |file: &ConflictFile| {
            conflict_offered(file)
                .modes
                .iter()
                .map(|m| m.id())
                .collect::<Vec<_>>()
        };
        let blocks = b"a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> topic\nz\n".to_vec();
        let content = ConflictFile::new("f.txt".into(), ConflictKind::Content, Some(blocks));
        assert_eq!(ids(&content), vec!["unified", "split"]);
        let resolved = ConflictFile::new(
            "f.txt".into(),
            ConflictKind::Content,
            Some(b"a\nz\n".to_vec()),
        );
        assert!(ids(&resolved).is_empty());
        let binary = ConflictFile::new("i.png".into(), ConflictKind::Binary, None);
        assert!(ids(&binary).is_empty());
        let deleted = ConflictFile::new(
            "d.txt".into(),
            ConflictKind::ModifyDelete {
                deleted_by_us: true,
            },
            Some(b"x\n".to_vec()),
        );
        assert!(ids(&deleted).is_empty());
    }

    #[test]
    fn ids_round_trip() {
        for viewer in [Viewer::Text, Viewer::Image, Viewer::None] {
            assert_eq!(Viewer::parse(viewer.id()), Some(viewer));
            assert!(viewer
                .all_modes()
                .iter()
                .all(|m| DiffMode::parse(m.id()) == Some(*m)));
        }
        assert_eq!(DiffMode::parse("single"), Some(DiffMode::Single));
        assert_eq!(DiffMode::parse("side"), None);
    }
}
