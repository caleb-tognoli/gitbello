//! Image diffs (M7.8 P2) on temporary repositories: both sides of every
//! kind of diff, the size limit, files that are not what their name says,
//! SVG text, and the ours/theirs of a conflicted image.

use crate::support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::backend::{CliBackend, GitBackend};
use gitbello_core::diff::image::{read_sides, ImageFormat, ImageSides, SideImage};
use gitbello_core::diff::viewer::{offered, Viewer};
use gitbello_core::diff::{CommitSide, DiffKind, DiffTarget};
use gitbello_core::git::{CancelToken, GitErrorKind};
use support::rt::{open, poll_until};
use support::TestRepo;

/// A PNG signature and IHDR of `width` × `height`, then `tag` so versions differ.
fn png(width: u32, height: u32, tag: &str) -> Vec<u8> {
    let mut bytes = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
    bytes.extend_from_slice(&width.to_be_bytes());
    bytes.extend_from_slice(&height.to_be_bytes());
    bytes.extend_from_slice(&[8, 6, 0, 0, 0]);
    bytes.extend_from_slice(tag.as_bytes());
    bytes
}

fn put(repo: &TestRepo, file: &str, bytes: &[u8]) {
    let path = repo.path().join(file);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create the folder");
    }
    fs::write(path, bytes).expect("write the file");
}

fn commit_bytes(repo: &TestRepo, file: &str, bytes: &[u8], message: &str) {
    put(repo, file, bytes);
    repo.git(&["add", "--", file]);
    repo.git(&["commit", "-q", "-m", message]);
}

fn target(kind: DiffKind, path: &str) -> DiffTarget {
    DiffTarget {
        kind,
        path: PathBuf::from(path),
        original_path: None,
        commit: None,
    }
}

fn sides(repo: &TestRepo, target: &DiffTarget, limit: Option<usize>) -> Option<ImageSides> {
    let backend = CliBackend::new(repo.app_runner());
    let cancel = CancelToken::new();
    let diff = backend
        .diff(repo.path(), target, None, &cancel)
        .expect("diff");
    read_sides(&backend, repo.path(), target, &diff, limit, &cancel).expect("read the sides")
}

fn dims(side: &SideImage) -> Option<(u32, u32)> {
    match side {
        SideImage::Loaded { dimensions, .. } => *dimensions,
        _ => None,
    }
}

#[test]
fn both_sides_come_from_blobs_or_the_working_tree() {
    let repo = TestRepo::init();
    commit_bytes(&repo, "img/ïcon ä.png", &png(2, 3, "one"), "add icon");
    commit_bytes(&repo, "gone.png", &png(1, 1, "gone"), "add gone");
    put(&repo, "img/ïcon ä.png", &png(4, 5, "two"));
    fs::remove_file(repo.path().join("gone.png")).unwrap();
    put(&repo, "new.PNG", &png(6, 7, "new"));

    // Changes (working tree against HEAD): old from the blob, new from disk.
    let head = sides(&repo, &target(DiffKind::Head, "img/ïcon ä.png"), None).unwrap();
    assert_eq!(head.format, ImageFormat::Png);
    assert_eq!(
        (dims(&head.old), dims(&head.new)),
        (Some((2, 3)), Some((4, 5)))
    );
    assert!(matches!(&head.new, SideImage::Loaded { id, .. } if id.starts_with("file:")));
    let deleted = sides(&repo, &target(DiffKind::Head, "gone.png"), None).unwrap();
    assert_eq!(dims(&deleted.old), Some((1, 1)));
    assert_eq!(deleted.new, SideImage::Missing);
    let untracked = sides(&repo, &target(DiffKind::Untracked, "new.PNG"), None).unwrap();
    assert_eq!(untracked.old, SideImage::Missing);
    assert_eq!(dims(&untracked.new), Some((6, 7)));

    // Staged: the new side is the index's blob, not the working file.
    repo.git(&["add", "--", "img/ïcon ä.png"]);
    put(&repo, "img/ïcon ä.png", &png(8, 9, "three"));
    let staged = sides(&repo, &target(DiffKind::Staged, "img/ïcon ä.png"), None).unwrap();
    assert_eq!(
        (dims(&staged.old), dims(&staged.new)),
        (Some((2, 3)), Some((4, 5)))
    );

    // A commit: both sides from its blobs.
    repo.git(&["commit", "-q", "-m", "bigger icon"]);
    let oid = repo.head();
    let parent = repo.git(&["rev-parse", "HEAD^"]).trim().to_owned();
    let commit = DiffTarget {
        commit: Some(CommitSide {
            oid,
            parent: Some(parent),
        }),
        ..target(DiffKind::Commit, "img/ïcon ä.png")
    };
    let committed = sides(&repo, &commit, None).unwrap();
    assert_eq!(
        (dims(&committed.old), dims(&committed.new)),
        (Some((2, 3)), Some((4, 5)))
    );
}

#[test]
fn large_or_wrong_files_are_not_read_as_images() {
    let repo = TestRepo::init();
    commit_bytes(&repo, "a.png", &png(2, 2, "first"), "add");
    put(&repo, "a.png", &png(3, 3, "second, a little longer"));
    let limited = sides(&repo, &target(DiffKind::Head, "a.png"), Some(10)).unwrap();
    assert!(matches!(limited.old, SideImage::TooLarge { .. }));
    assert_eq!(
        limited.new,
        SideImage::TooLarge {
            bytes: Some(png(3, 3, "second, a little longer").len() as u64)
        }
    );
    put(&repo, "fake.png", b"not\0a png");
    let fake = sides(&repo, &target(DiffKind::Untracked, "fake.png"), None).unwrap();
    assert_eq!(fake.new, SideImage::Unreadable { size: 9 });
    put(&repo, "data.bin", &png(1, 1, "x"));
    assert_eq!(
        sides(&repo, &target(DiffKind::Untracked, "data.bin"), None),
        None
    );
}

#[test]
fn svg_text_is_an_image() {
    let repo = TestRepo::init();
    repo.commit(
        "logo.svg",
        "<svg width=\"4\" height=\"4\"></svg>\n",
        "add logo",
    );
    repo.write("logo.svg", "<svg width=\"8\" height=\"8\"></svg>\n");
    let backend = CliBackend::new(repo.app_runner());
    let diff = backend
        .diff(
            repo.path(),
            &target(DiffKind::Head, "logo.svg"),
            None,
            &CancelToken::new(),
        )
        .unwrap();
    assert_eq!(offered(&diff, Path::new("logo.svg")).viewer, Viewer::Image);
    let svg = sides(&repo, &target(DiffKind::Head, "logo.svg"), None).unwrap();
    assert_eq!(svg.format, ImageFormat::Svg);
    assert!(matches!(
        svg.old,
        SideImage::Loaded {
            dimensions: None,
            ..
        }
    ));
    assert!(matches!(
        svg.new,
        SideImage::Loaded {
            dimensions: None,
            ..
        }
    ));
}

#[test]
fn the_runtime_loads_image_diffs_and_conflicted_images() {
    let repo = TestRepo::init();
    commit_bytes(&repo, "pic.png", &png(2, 2, "base"), "base");
    repo.branch("theirs");
    commit_bytes(&repo, "pic.png", &png(3, 3, "ours"), "ours");
    repo.checkout("theirs");
    commit_bytes(&repo, "pic.png", &png(5, 5, "theirs"), "theirs");
    repo.checkout("main");
    commit_bytes(&repo, "other.png", &png(1, 1, "a"), "other");
    put(&repo, "other.png", &png(1, 2, "b"));

    let (mut rt, key) = open(&repo);
    rt.select_change(&key, Path::new("other.png"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| !d.is_loading() && d.images().is_some())
    });
    let images = rt.repo(&key).unwrap().diff().unwrap().images().unwrap();
    assert_eq!(
        (dims(&images.old), dims(&images.new)),
        (Some((1, 1)), Some((1, 2)))
    );

    let err = repo
        .try_git(&["merge", "--no-edit", "theirs"])
        .expect_err("the merge should conflict");
    assert_eq!(err.kind, GitErrorKind::Conflict, "{err}");
    support::rt::settle(&mut rt, &key);
    rt.select_change(&key, Path::new("pic.png"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.conflict())
            .is_some_and(|c| !c.is_loading() && c.images().is_some())
    });
    let conflict = rt.repo(&key).unwrap().conflict().unwrap();
    let images = conflict.images().unwrap();
    assert_eq!(
        (dims(&images.old), dims(&images.new)),
        (Some((3, 3)), Some((5, 5)))
    );
}
