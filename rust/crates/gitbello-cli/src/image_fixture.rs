//! The image repositories `fixture --images` adds (M7.8): `images` and
//! `images-conflict`, for the image viewer's smoke test and screenshots.
//!
//! `images` commits `logo.png` (64×64), `icon.svg`, `old.png` and
//! `photo.png`, then recolours `logo.png` in a second commit. Its working
//! tree changes `logo.png` (80×64, the circle moved), recolours `icon.svg`,
//! deletes `old.png` and adds `new.png` (a transparent gradient), `huge.png`
//! (past the 20 MB preview limit) and `wide.png` (17000 px wide).
//!
//! `images-conflict` stops in a merge where both sides changed `photo.png`
//! (ours green 48×32, theirs red 64×40).

use std::fs;
use std::path::Path;

use anyhow::Result;

use crate::fixture::Git;

pub fn build(git: &Git<'_>, dir: &Path) -> Result<()> {
    let repo = dir.join("images");
    fs::create_dir_all(&repo)?;
    git.run(&repo, &["init", "--quiet", "--initial-branch=main"], None)?;
    put(
        &repo,
        "logo.png",
        &circle(64, 64, 32.0, 32.0, [40, 110, 230]),
    )?;
    put(&repo, "icon.svg", svg("#3b82f6").as_bytes())?;
    put(
        &repo,
        "old.png",
        &circle(32, 32, 16.0, 16.0, [200, 120, 40]),
    )?;
    put(&repo, "photo.png", &stripes(48, 32, [90, 90, 90]))?;
    git.run(&repo, &["add", "--all"], None)?;
    git.run(&repo, &["commit", "--quiet", "-F", "-"], Some("Add images"))?;
    put(
        &repo,
        "logo.png",
        &circle(64, 64, 32.0, 32.0, [230, 140, 30]),
    )?;
    git.run(&repo, &["add", "--all"], None)?;
    git.run(
        &repo,
        &["commit", "--quiet", "-F", "-"],
        Some("Recolour the logo"),
    )?;

    put(
        &repo,
        "logo.png",
        &circle(80, 64, 44.0, 30.0, [230, 140, 30]),
    )?;
    put(&repo, "icon.svg", svg("#e11d48").as_bytes())?;
    fs::remove_file(repo.join("old.png"))?;
    put(&repo, "new.png", &gradient(96, 64))?;
    // Stored (uncompressed) RGBA: 2400×2400×4 is about 23 MB.
    put(
        &repo,
        "huge.png",
        &png(2400, 2400, |_, _| [120, 160, 200, 255]),
    )?;
    put(
        &repo,
        "wide.png",
        &png(17000, 1, |x, _| [(x % 256) as u8, 0, 0, 255]),
    )?;

    let repo = dir.join("images-conflict");
    fs::create_dir_all(&repo)?;
    git.run(&repo, &["init", "--quiet", "--initial-branch=main"], None)?;
    put(&repo, "photo.png", &stripes(48, 32, [90, 90, 90]))?;
    git.run(&repo, &["add", "--all"], None)?;
    git.run(
        &repo,
        &["commit", "--quiet", "-F", "-"],
        Some("Add a photo"),
    )?;
    git.run(&repo, &["branch", "topic"], None)?;
    put(&repo, "photo.png", &stripes(48, 32, [40, 170, 80]))?;
    git.run(
        &repo,
        &["commit", "--quiet", "-a", "-F", "-"],
        Some("Green photo"),
    )?;
    git.run(&repo, &["checkout", "--quiet", "topic"], None)?;
    put(&repo, "photo.png", &stripes(64, 40, [210, 50, 50]))?;
    git.run(
        &repo,
        &["commit", "--quiet", "-a", "-F", "-"],
        Some("Red photo"),
    )?;
    git.run(&repo, &["checkout", "--quiet", "main"], None)?;
    // The merge stops on the conflict; that is the state wanted.
    let _ = git.run(&repo, &["merge", "--no-edit", "topic"], None);
    Ok(())
}

fn put(repo: &Path, file: &str, bytes: &[u8]) -> Result<()> {
    fs::write(repo.join(file), bytes)?;
    Ok(())
}

fn svg(fill: &str) -> String {
    format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"48\" height=\"48\" viewBox=\"0 0 48 48\">\n\
         <rect x=\"4\" y=\"4\" width=\"40\" height=\"40\" rx=\"8\" fill=\"{fill}\"/>\n\
         <circle cx=\"24\" cy=\"24\" r=\"10\" fill=\"#ffffff\"/>\n\
         </svg>\n"
    )
}

/// A filled circle of `rgb` centred at (`cx`, `cy`) on a transparent field.
fn circle(width: u32, height: u32, cx: f32, cy: f32, rgb: [u8; 3]) -> Vec<u8> {
    let radius = width.min(height) as f32 * 0.35;
    png(width, height, |x, y| {
        let (dx, dy) = (x as f32 + 0.5 - cx, y as f32 + 0.5 - cy);
        if dx * dx + dy * dy <= radius * radius {
            [rgb[0], rgb[1], rgb[2], 255]
        } else {
            [0, 0, 0, 0]
        }
    })
}

/// Opaque diagonal stripes of `rgb` and white.
fn stripes(width: u32, height: u32, rgb: [u8; 3]) -> Vec<u8> {
    png(width, height, |x, y| {
        if (x + y) / 6 % 2 == 0 {
            [rgb[0], rgb[1], rgb[2], 255]
        } else {
            [245, 245, 245, 255]
        }
    })
}

/// Colour left to right, fading out top to bottom.
fn gradient(width: u32, height: u32) -> Vec<u8> {
    png(width, height, |x, y| {
        let r = (x * 255 / width.max(1)) as u8;
        let a = 255 - (y * 255 / height.max(1)) as u8;
        [r, 80, 255 - r, a]
    })
}

/// An RGBA PNG with `pixel(x, y)` for each pixel, deflate-stored (no
/// compression), so it needs no crate.
fn png(width: u32, height: u32, pixel: impl Fn(u32, u32) -> [u8; 4]) -> Vec<u8> {
    let mut raw = Vec::with_capacity((height * (width * 4 + 1)) as usize);
    for y in 0..height {
        raw.push(0);
        for x in 0..width {
            raw.extend_from_slice(&pixel(x, y));
        }
    }
    let mut zlib = vec![0x78, 0x01];
    let mut chunks = raw.chunks(65_535).peekable();
    while let Some(block) = chunks.next() {
        zlib.push(u8::from(chunks.peek().is_none()));
        let len = block.len() as u16;
        zlib.extend_from_slice(&len.to_le_bytes());
        zlib.extend_from_slice(&(!len).to_le_bytes());
        zlib.extend_from_slice(block);
    }
    if raw.is_empty() {
        zlib.extend_from_slice(&[1, 0, 0, 0xff, 0xff]);
    }
    zlib.extend_from_slice(&adler32(&raw).to_be_bytes());

    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"IDAT", &zlib);
    chunk(&mut out, b"IEND", &[]);
    out
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let start = out.len();
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let crc = crc32(&out[start..]);
    out.extend_from_slice(&crc.to_be_bytes());
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for &byte in bytes {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

fn adler32(bytes: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for &byte in bytes {
        a = (a + u32::from(byte)) % 65_521;
        b = (b + a) % 65_521;
    }
    (b << 16) | a
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksums_match_known_values() {
        assert_eq!(crc32(b"IEND"), 0xae42_6082);
        assert_eq!(adler32(b"Wikipedia"), 0x11e6_0398);
    }
}
