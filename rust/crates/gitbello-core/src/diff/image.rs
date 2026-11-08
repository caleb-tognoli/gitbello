//! Images in diffs (PLAN M7.8 P2): which files the image viewer shows, the
//! bytes of their old and new sides, and their sizes in pixels read from the
//! file headers. The UI decodes the bytes; core only checks that they look
//! like the format their name says.

use std::collections::hash_map::DefaultHasher;
use std::fs;
use std::hash::Hasher;
use std::path::Path;
use std::sync::Arc;

use super::{DiffContent, DiffKind, DiffTarget, FileDiff};
use crate::backend::GitBackend;
use crate::git::{CancelToken, GitError, GitErrorKind};

/// Sides larger than this many bytes are not read until the user asks
/// ("load anyway").
pub const MAX_IMAGE_BYTES: usize = 20 * 1024 * 1024;

/// Images wider or taller than this many pixels are not previewed (Godot's
/// texture limit).
pub const MAX_IMAGE_SIDE: u32 = 16384;

/// A format the image viewer decodes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageFormat {
    Png,
    Jpeg,
    Webp,
    Bmp,
    Tga,
    Svg,
}

impl ImageFormat {
    pub fn id(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpeg",
            Self::Webp => "webp",
            Self::Bmp => "bmp",
            Self::Tga => "tga",
            Self::Svg => "svg",
        }
    }

    /// The format `path`'s extension names (any case), if the viewer shows it.
    pub fn for_path(path: &Path) -> Option<Self> {
        let ext = path.extension()?.to_str()?.to_ascii_lowercase();
        Some(match ext.as_str() {
            "png" => Self::Png,
            "jpg" | "jpeg" => Self::Jpeg,
            "webp" => Self::Webp,
            "bmp" => Self::Bmp,
            "tga" => Self::Tga,
            "svg" => Self::Svg,
            _ => return None,
        })
    }

    /// Whether `bytes` start the way this format does (TGA has no magic
    /// number: any bytes pass; SVG needs `<svg` near the start).
    pub fn matches(self, bytes: &[u8]) -> bool {
        match self {
            Self::Png => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
            Self::Jpeg => bytes.starts_with(&[0xFF, 0xD8, 0xFF]),
            Self::Webp => bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP",
            Self::Bmp => bytes.starts_with(b"BM"),
            Self::Tga => bytes.len() >= 18,
            Self::Svg => {
                let head = &bytes[..bytes.len().min(4096)];
                head.windows(4).any(|w| w.eq_ignore_ascii_case(b"<svg"))
            }
        }
    }

    /// Width and height from the file's header; `None` when they cannot be
    /// read without decoding (SVG) or the header is cut short.
    pub fn dimensions(self, bytes: &[u8]) -> Option<(u32, u32)> {
        let be32 = |at: usize| -> Option<u32> {
            Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
        };
        let le16 = |at: usize| -> Option<u32> {
            Some(u32::from(u16::from_le_bytes(
                bytes.get(at..at + 2)?.try_into().ok()?,
            )))
        };
        let le24 = |at: usize| -> Option<u32> {
            let b = bytes.get(at..at + 3)?;
            Some(u32::from(b[0]) | u32::from(b[1]) << 8 | u32::from(b[2]) << 16)
        };
        match self {
            // IHDR comes first: width and height at bytes 16 and 20.
            Self::Png => Some((be32(16)?, be32(20)?)),
            Self::Jpeg => jpeg_dimensions(bytes),
            Self::Webp => match bytes.get(12..16)? {
                b"VP8X" => Some((le24(24)? + 1, le24(27)? + 1)),
                b"VP8L" => {
                    let bits = u32::from_le_bytes(bytes.get(21..25)?.try_into().ok()?);
                    Some(((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1))
                }
                b"VP8 " => Some((le16(26)? & 0x3FFF, le16(28)? & 0x3FFF)),
                _ => None,
            },
            Self::Bmp => {
                let width = i32::from_le_bytes(bytes.get(18..22)?.try_into().ok()?);
                let height = i32::from_le_bytes(bytes.get(22..26)?.try_into().ok()?);
                Some((width.unsigned_abs(), height.unsigned_abs()))
            }
            Self::Tga => Some((le16(12)?, le16(14)?)),
            Self::Svg => None,
        }
    }
}

/// The size of a baseline or progressive JPEG from its first SOF marker.
fn jpeg_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    let mut at = 2;
    loop {
        while *bytes.get(at)? == 0xFF && *bytes.get(at + 1)? == 0xFF {
            at += 1;
        }
        if *bytes.get(at)? != 0xFF {
            return None;
        }
        let marker = *bytes.get(at + 1)?;
        let length = usize::from(u16::from_be_bytes(
            bytes.get(at + 2..at + 4)?.try_into().ok()?,
        ));
        let is_sof = matches!(marker, 0xC0..=0xCF) && !matches!(marker, 0xC4 | 0xC8 | 0xCC);
        if is_sof {
            let height = u16::from_be_bytes(bytes.get(at + 5..at + 7)?.try_into().ok()?);
            let width = u16::from_be_bytes(bytes.get(at + 7..at + 9)?.try_into().ok()?);
            return Some((u32::from(width), u32::from(height)));
        }
        at += 2 + length;
    }
}

/// One side of an image diff.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SideImage {
    /// The file does not exist on this side (added or deleted).
    Missing,
    /// Read: `id` changes when the bytes do (a blob id, or a hash of a
    /// working-tree file), so the UI decodes each version once.
    Loaded {
        bytes: Arc<[u8]>,
        id: String,
        dimensions: Option<(u32, u32)>,
    },
    /// Larger than the limit; `bytes` is its size when known.
    TooLarge { bytes: Option<u64> },
    /// Wider or taller than [`MAX_IMAGE_SIDE`].
    TooManyPixels { size: u64, width: u32, height: u32 },
    /// Not readable or not in the format its name says.
    Unreadable { size: u64 },
}

impl SideImage {
    /// Its size in bytes, when known.
    pub fn size(&self) -> Option<u64> {
        match self {
            Self::Missing => None,
            Self::Loaded { bytes, .. } => Some(bytes.len() as u64),
            Self::TooLarge { bytes } => *bytes,
            Self::TooManyPixels { size, .. } | Self::Unreadable { size } => Some(*size),
        }
    }

    fn from_bytes(format: ImageFormat, bytes: Vec<u8>, id: String) -> Self {
        let size = bytes.len() as u64;
        if !format.matches(&bytes) {
            return Self::Unreadable { size };
        }
        let dimensions = format.dimensions(&bytes);
        match dimensions {
            Some((width, height)) if width > MAX_IMAGE_SIDE || height > MAX_IMAGE_SIDE => {
                Self::TooManyPixels {
                    size,
                    width,
                    height,
                }
            }
            _ => Self::Loaded {
                bytes: bytes.into(),
                id,
                dimensions,
            },
        }
    }
}

/// Both sides of an image diff (ours and theirs for a conflict).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageSides {
    pub format: ImageFormat,
    pub old: SideImage,
    pub new: SideImage,
}

/// Whether the image viewer shows `diff` of `path`: an image format by name,
/// binary content (or text for SVG), not empty.
pub fn image_format(diff: &FileDiff, path: &Path) -> Option<ImageFormat> {
    let format = ImageFormat::for_path(path)?;
    if diff.is_empty() {
        return None;
    }
    match diff.content {
        DiffContent::Binary { .. } => Some(format),
        DiffContent::Text if format == ImageFormat::Svg => Some(format),
        _ => None,
    }
}

/// Whether the new side of a diff of `kind` is the working-tree file.
fn new_side_on_disk(kind: DiffKind) -> bool {
    matches!(
        kind,
        DiffKind::Unstaged
            | DiffKind::Untracked
            | DiffKind::Head
            | DiffKind::Amend
            | DiffKind::Working
    )
}

/// Reads both sides of `diff` (of `target` in `toplevel`) when the image
/// viewer shows it: the old side from its blob, the new side from its blob
/// or the working tree. Sides past `limit` bytes are left out as too large.
pub fn read_sides(
    backend: &dyn GitBackend,
    toplevel: &Path,
    target: &DiffTarget,
    diff: &FileDiff,
    limit: Option<usize>,
    cancel: &CancelToken,
) -> Result<Option<ImageSides>, GitError> {
    let Some(format) = image_format(diff, &target.path) else {
        return Ok(None);
    };
    let limit = limit.unwrap_or(usize::MAX);
    let (old_size, new_size) = match diff.content {
        DiffContent::Binary { old_size, new_size } => (old_size, new_size),
        _ => (None, None),
    };
    let header = &diff.header;
    let old = match header.old_oid.as_deref().filter(|o| !is_zero(o)) {
        Some(oid) if !header.new_file => {
            read_blob(backend, toplevel, format, oid, old_size, limit, cancel)?
        }
        _ => SideImage::Missing,
    };
    let new = if header.deleted_file {
        SideImage::Missing
    } else if new_side_on_disk(target.kind) {
        read_file(&toplevel.join(&target.path), format, limit)
    } else {
        match header.new_oid.as_deref().filter(|o| !is_zero(o)) {
            Some(oid) => read_blob(backend, toplevel, format, oid, new_size, limit, cancel)?,
            None => SideImage::Missing,
        }
    };
    Ok(Some(ImageSides { format, old, new }))
}

/// Reads stages 2 and 3 (ours and theirs) of a conflicted image at `path`.
pub fn read_conflict_sides(
    backend: &dyn GitBackend,
    toplevel: &Path,
    path: &Path,
    limit: Option<usize>,
    cancel: &CancelToken,
) -> Result<Option<ImageSides>, GitError> {
    let Some(format) = ImageFormat::for_path(path) else {
        return Ok(None);
    };
    let limit = limit.unwrap_or(usize::MAX);
    let slashed = path.to_string_lossy().replace('\\', "/");
    let side = |stage: u8| -> Result<SideImage, GitError> {
        read_blob(
            backend,
            toplevel,
            format,
            &format!(":{stage}:{slashed}"),
            None,
            limit,
            cancel,
        )
    };
    let old = side(2)?;
    let new = side(3)?;
    Ok(Some(ImageSides { format, old, new }))
}

fn is_zero(oid: &str) -> bool {
    oid.bytes().all(|b| b == b'0')
}

fn read_blob(
    backend: &dyn GitBackend,
    toplevel: &Path,
    format: ImageFormat,
    spec: &str,
    size: Option<u64>,
    limit: usize,
    cancel: &CancelToken,
) -> Result<SideImage, GitError> {
    match backend.blob(toplevel, spec, limit, cancel) {
        Ok(Some(bytes)) => Ok(SideImage::from_bytes(format, bytes, spec.to_owned())),
        Ok(None) if cancel.is_cancelled() => Err(GitError::new(
            "cat-file",
            GitErrorKind::Cancelled,
            "cancelled",
        )),
        Ok(None) => Ok(SideImage::TooLarge { bytes: size }),
        Err(err) if err.kind == GitErrorKind::Cancelled => Err(err),
        // A side missing from the object database: say so in its place.
        Err(_) => Ok(match size {
            Some(size) => SideImage::Unreadable { size },
            None => SideImage::Missing,
        }),
    }
}

fn read_file(path: &Path, format: ImageFormat, limit: usize) -> SideImage {
    let Ok(meta) = fs::metadata(path) else {
        return SideImage::Missing;
    };
    if usize::try_from(meta.len()).map_or(true, |len| len > limit) {
        return SideImage::TooLarge {
            bytes: Some(meta.len()),
        };
    }
    match fs::read(path) {
        Ok(bytes) => {
            let mut hasher = DefaultHasher::new();
            hasher.write(&bytes);
            let id = format!("file:{:016x}", hasher.finish());
            SideImage::from_bytes(format, bytes, id)
        }
        Err(_) => SideImage::Unreadable { size: meta.len() },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::{parse_diff, untracked_diff};

    /// A 1×1 PNG.
    pub(crate) const PNG: &[u8] = &[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00,
    ];

    #[test]
    fn formats_come_from_the_extension() {
        assert_eq!(
            ImageFormat::for_path(Path::new("a/B.PNG")),
            Some(ImageFormat::Png)
        );
        assert_eq!(
            ImageFormat::for_path(Path::new("x.jpeg")),
            Some(ImageFormat::Jpeg)
        );
        assert_eq!(
            ImageFormat::for_path(Path::new("x.JPG")),
            Some(ImageFormat::Jpeg)
        );
        assert_eq!(
            ImageFormat::for_path(Path::new("ïcon.svg")),
            Some(ImageFormat::Svg)
        );
        assert_eq!(ImageFormat::for_path(Path::new("x.gif")), None);
        assert_eq!(ImageFormat::for_path(Path::new("png")), None);
    }

    #[test]
    fn magic_numbers_and_dimensions() {
        assert!(ImageFormat::Png.matches(PNG));
        assert_eq!(ImageFormat::Png.dimensions(PNG), Some((3, 2)));
        assert!(!ImageFormat::Jpeg.matches(PNG));
        // SOI, an APP0 segment, then SOF0 with height 5 and width 7.
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00,
            0x05, 0x00, 0x07, 0x01,
        ];
        assert!(ImageFormat::Jpeg.matches(&jpeg));
        assert_eq!(ImageFormat::Jpeg.dimensions(&jpeg), Some((7, 5)));
        let mut webp = b"RIFF\0\0\0\0WEBPVP8X".to_vec();
        webp.extend_from_slice(&[0; 8]);
        webp.extend_from_slice(&[9, 0, 0, 19, 0, 0]);
        assert!(ImageFormat::Webp.matches(&webp));
        assert_eq!(ImageFormat::Webp.dimensions(&webp), Some((10, 20)));
        let mut bmp = b"BM".to_vec();
        bmp.resize(18, 0);
        bmp.extend_from_slice(&4i32.to_le_bytes());
        bmp.extend_from_slice(&(-6i32).to_le_bytes());
        assert_eq!(ImageFormat::Bmp.dimensions(&bmp), Some((4, 6)));
        let mut tga = vec![0u8; 12];
        tga.extend_from_slice(&[8, 0, 9, 0, 32, 0]);
        assert_eq!(ImageFormat::Tga.dimensions(&tga), Some((8, 9)));
        assert!(ImageFormat::Svg.matches(b"<?xml version=\"1.0\"?>\n<SVG width=\"4\">"));
        assert!(!ImageFormat::Svg.matches(b"plain text"));
        assert_eq!(ImageFormat::Png.dimensions(&PNG[..18]), None);
    }

    #[test]
    fn huge_or_wrong_bytes_are_not_previewed() {
        let mut huge = PNG.to_vec();
        huge[16..20].copy_from_slice(&20000u32.to_be_bytes());
        assert!(matches!(
            SideImage::from_bytes(ImageFormat::Png, huge, "x".into()),
            SideImage::TooManyPixels {
                width: 20000,
                height: 2,
                ..
            }
        ));
        assert_eq!(
            SideImage::from_bytes(ImageFormat::Png, b"not a png".to_vec(), "x".into()),
            SideImage::Unreadable { size: 9 }
        );
        assert!(matches!(
            SideImage::from_bytes(ImageFormat::Png, PNG.to_vec(), "x".into()),
            SideImage::Loaded {
                dimensions: Some((3, 2)),
                ..
            }
        ));
    }

    #[test]
    fn the_viewer_shows_binary_images_and_svg_text() {
        let binary = parse_diff(
            b"diff --git a/i.png b/i.png\nindex 1..2 100644\nBinary files a/i.png and b/i.png differ\n",
        )
        .unwrap();
        assert_eq!(
            image_format(&binary, Path::new("i.png")),
            Some(ImageFormat::Png)
        );
        assert_eq!(image_format(&binary, Path::new("i.bin")), None);
        let svg = untracked_diff(b"<svg/>\n");
        assert_eq!(
            image_format(&svg, Path::new("i.svg")),
            Some(ImageFormat::Svg)
        );
        // A text file named like a raster image stays text.
        assert_eq!(
            image_format(&untracked_diff(b"hi\n"), Path::new("i.png")),
            None
        );
        assert_eq!(image_format(&untracked_diff(b""), Path::new("i.svg")), None);
    }
}
