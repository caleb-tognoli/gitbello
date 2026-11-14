//! The repository's pictures a preview draws: images whose source is a path
//! in the repository, read at the version of the side that shows them (the
//! old side for a removed block or span). Web images are not downloaded.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::backend::GitBackend;
use crate::diff::image::{ImageFormat, MAX_IMAGE_SIDE};
use crate::diff::version::{new_source, old_source, VersionSource};
use crate::diff::DiffTarget;
use crate::git::{CancelToken, GitError, GitErrorKind};

/// Pictures a preview reads at most; the rest show their text.
pub const MAX_IMAGES: usize = 64;
/// Pictures larger than this many bytes are not read.
pub const MAX_PICTURE_BYTES: usize = 8 * 1024 * 1024;

/// A picture of the preview: a repository-relative path, on the old or the
/// new side.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ImageRef {
    pub path: PathBuf,
    pub old: bool,
}

/// A picture read: its bytes, as stored, and their format.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkdownImage {
    pub format: ImageFormat,
    pub bytes: Arc<[u8]>,
}

/// Reads each of `refs` for the diff of `target` in `toplevel`; `None` for
/// one missing, too large, of another format than its name says, or wider
/// than the texture limit.
pub fn read_images(
    backend: &dyn GitBackend,
    toplevel: &Path,
    target: &DiffTarget,
    refs: &[ImageRef],
    cancel: &CancelToken,
) -> Result<Vec<Option<MarkdownImage>>, GitError> {
    refs.iter()
        .map(|image| read_image(backend, toplevel, target, image, cancel))
        .collect()
}

fn read_image(
    backend: &dyn GitBackend,
    toplevel: &Path,
    target: &DiffTarget,
    image: &ImageRef,
    cancel: &CancelToken,
) -> Result<Option<MarkdownImage>, GitError> {
    if cancel.is_cancelled() {
        return Err(cancelled());
    }
    let Some(format) = ImageFormat::for_path(&image.path) else {
        return Ok(None);
    };
    let at = DiffTarget {
        kind: target.kind,
        path: image.path.clone(),
        original_path: None,
        commit: target.commit.clone(),
    };
    let source = if image.old {
        old_source(&at)
    } else {
        new_source(&at)
    };
    let bytes = match source {
        None => None,
        Some(VersionSource::Working(path)) => {
            let path = toplevel.join(path);
            match fs::metadata(&path) {
                Ok(meta) if meta.is_file() && meta.len() <= MAX_PICTURE_BYTES as u64 => {
                    fs::read(&path).ok()
                }
                _ => None,
            }
        }
        Some(VersionSource::Blob(spec)) => {
            match backend.blob(toplevel, &spec, MAX_PICTURE_BYTES, cancel) {
                Ok(Some(bytes)) => Some(bytes),
                Ok(None) if cancel.is_cancelled() => return Err(cancelled()),
                Ok(None) => None,
                Err(err) if err.kind == GitErrorKind::Cancelled => return Err(err),
                Err(_) => None,
            }
        }
    };
    Ok(bytes
        .filter(|bytes| format.matches(bytes))
        .filter(|bytes| {
            format
                .dimensions(bytes)
                .is_none_or(|(w, h)| w > 0 && h > 0 && w <= MAX_IMAGE_SIDE && h <= MAX_IMAGE_SIDE)
        })
        .map(|bytes| MarkdownImage {
            format,
            bytes: bytes.into(),
        }))
}

fn cancelled() -> GitError {
    GitError::new("cat-file", GitErrorKind::Cancelled, "cancelled")
}
