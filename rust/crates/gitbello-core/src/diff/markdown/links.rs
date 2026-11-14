//! Where a Markdown link or image points: a web page, a file of the
//! repository (relative to the Markdown file, or to the root with a leading
//! `/`) with an optional heading anchor, or a heading of the same document;
//! and the anchors GitHub gives headings (`## Getting started` →
//! `getting-started`, repeats `-1`, `-2`…).

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

/// What a link's target names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkTarget {
    /// An `http(s)`, `mailto` or other URL with a scheme.
    Web(String),
    /// A repository-relative file, and the heading anchor after `#`.
    File {
        path: PathBuf,
        anchor: Option<String>,
    },
    /// A heading of the same document (`#anchor`).
    Anchor(String),
    /// Empty, or a path that leaves the repository.
    None,
}

/// Where `link`, written in the Markdown file at the repository-relative
/// `document`, points.
pub fn resolve_link(document: &Path, link: &str) -> LinkTarget {
    let link = link.trim();
    if link.is_empty() {
        return LinkTarget::None;
    }
    if let Some(anchor) = link.strip_prefix('#') {
        return LinkTarget::Anchor(percent_decode(anchor).to_lowercase());
    }
    let scheme = link.split_once(':').map(|(s, _)| s).filter(|s| {
        s.len() >= 2
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c))
    });
    if scheme.is_some() || link.starts_with("//") {
        return LinkTarget::Web(link.to_owned());
    }
    let (path, anchor) = match link.split_once('#') {
        Some((path, anchor)) => (path, Some(percent_decode(anchor).to_lowercase())),
        None => (link, None),
    };
    let path = path.split_once('?').map_or(path, |(p, _)| p);
    let path = percent_decode(path);
    let (base, rest) = match path.strip_prefix('/') {
        Some(rest) => (PathBuf::new(), rest.to_owned()),
        None => (
            document.parent().map(Path::to_path_buf).unwrap_or_default(),
            path,
        ),
    };
    let mut out = PathBuf::new();
    for part in base.components().chain(Path::new(&rest).components()) {
        match part {
            Component::Normal(name) => out.push(name),
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    return LinkTarget::None;
                }
            }
            Component::RootDir | Component::Prefix(_) => return LinkTarget::None,
        }
    }
    if out.as_os_str().is_empty() {
        return match anchor {
            Some(anchor) => LinkTarget::Anchor(anchor),
            None => LinkTarget::None,
        };
    }
    LinkTarget::File { path: out, anchor }
}

/// `%XX` escapes decoded (invalid ones kept).
fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
            if let Some(byte) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Gives heading anchors in document order, as GitHub does: lower case,
/// letters, digits, `-` and `_` kept, spaces as `-`, the rest dropped; a
/// repeated anchor gets `-1`, `-2`….
#[derive(Debug, Default)]
pub struct Anchors {
    seen: HashMap<String, usize>,
}

impl Anchors {
    pub fn next(&mut self, heading: &str) -> String {
        let base: String = heading
            .trim()
            .to_lowercase()
            .chars()
            .filter_map(|c| match c {
                ' ' => Some('-'),
                c if c.is_alphanumeric() || c == '-' || c == '_' => Some(c),
                _ => None,
            })
            .collect();
        let count = self.seen.entry(base.clone()).or_insert(0);
        let anchor = if *count == 0 {
            base
        } else {
            format!("{base}-{count}")
        };
        *count += 1;
        anchor
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(path: &str, anchor: Option<&str>) -> LinkTarget {
        LinkTarget::File {
            path: PathBuf::from(path),
            anchor: anchor.map(str::to_owned),
        }
    }

    #[test]
    fn links_resolve_against_the_document() {
        let doc = Path::new("docs/guide/README.md");
        assert_eq!(
            resolve_link(doc, "setup.md"),
            file("docs/guide/setup.md", None)
        );
        assert_eq!(
            resolve_link(doc, "./img/a b.png"),
            file("docs/guide/img/a b.png", None)
        );
        assert_eq!(
            resolve_link(doc, "img/a%20b.png"),
            file("docs/guide/img/a b.png", None)
        );
        assert_eq!(
            resolve_link(doc, "../PLAN.md#Milestones"),
            file("docs/PLAN.md", Some("milestones"))
        );
        assert_eq!(
            resolve_link(doc, "/src/lib.rs?raw=1"),
            file("src/lib.rs", None)
        );
        assert_eq!(resolve_link(doc, "../../../out.md"), LinkTarget::None);
        assert_eq!(
            resolve_link(doc, "#install"),
            LinkTarget::Anchor("install".into())
        );
        assert_eq!(resolve_link(doc, ""), LinkTarget::None);
        assert_eq!(
            resolve_link(doc, "https://x.dev/a.png"),
            LinkTarget::Web("https://x.dev/a.png".into())
        );
        assert_eq!(
            resolve_link(doc, "mailto:a@b.c"),
            LinkTarget::Web("mailto:a@b.c".into())
        );
        assert_eq!(
            resolve_link(Path::new("README.md"), "docs/a.md"),
            file("docs/a.md", None)
        );
    }

    #[test]
    fn anchors_follow_github() {
        let mut anchors = Anchors::default();
        assert_eq!(anchors.next("Getting Started!"), "getting-started");
        assert_eq!(anchors.next("What's new in 2.0?"), "whats-new-in-20");
        assert_eq!(anchors.next("Getting started"), "getting-started-1");
        assert_eq!(anchors.next("snake_case & more"), "snake_case--more");
    }
}
