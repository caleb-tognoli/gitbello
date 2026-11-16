//! Markdown previews on temporary repositories: both sides of each kind of
//! diff compared, one-sided files shown plain, the size limit, the
//! runtime loading the preview with the diff, and the pictures read at the
//! side that shows them.

use crate::support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::backend::{CliBackend, GitBackend};
use gitbello_core::diff::image::ImageFormat;
use gitbello_core::diff::markdown::PreviewRow;
use gitbello_core::diff::markdown::{
    read_images, read_sides, Change, Content, ImageRef, MarkdownDiff, MAX_MARKDOWN_BYTES,
};
use gitbello_core::diff::viewer::{offered, Viewer};
use gitbello_core::diff::{CommitSide, DiffKind, DiffTarget, Expand};
use gitbello_core::git::CancelToken;
use gitbello_core::runtime::DiffSlot;
use support::rt::{open, poll_until};
use support::TestRepo;

const OLD: &str = "# Read me\n\nThe quick brown fox.\n\n- one\n- two\n";
const NEW: &str = "# Read me\n\nThe quick red fox.\n\n- one\n- two\n- three\n";

fn put(repo: &TestRepo, file: &str, text: &str) {
    let path = repo.path().join(file);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create the folder");
    }
    fs::write(path, text).expect("write the file");
}

fn commit_text(repo: &TestRepo, file: &str, text: &str, message: &str) {
    put(repo, file, text);
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

fn preview(repo: &TestRepo, target: &DiffTarget) -> Option<MarkdownDiff> {
    let backend = CliBackend::new(repo.app_runner());
    let cancel = CancelToken::new();
    let diff = backend
        .diff(repo.path(), target, None, &cancel)
        .expect("diff");
    read_sides(&backend, repo.path(), target, &diff, &cancel)
        .expect("read the sides")
        .map(|p| (*p).clone())
}

/// `change` per block.
fn changes(preview: &MarkdownDiff) -> Vec<Change> {
    preview.blocks.iter().map(|b| b.change).collect()
}

#[test]
fn both_sides_are_compared_for_every_kind() {
    let repo = TestRepo::init();
    let file = "docs/rëad mé.md";
    commit_text(&repo, file, OLD, "add the readme");
    put(&repo, file, NEW);
    let expected = vec![
        Change::Same,
        Change::Changed,
        Change::Same,
        Change::Same,
        Change::Added,
    ];

    let head = preview(&repo, &target(DiffKind::Head, file)).expect("a preview");
    assert_eq!(changes(&head), expected);
    let Content::Text(spans) = &head.blocks[1].block.content else {
        panic!("not text: {:?}", head.blocks[1]);
    };
    let marked: Vec<(&str, Change)> = spans
        .iter()
        .filter(|s| s.change != Change::Same)
        .map(|s| (s.text.as_str(), s.change))
        .collect();
    assert_eq!(
        marked,
        vec![("brown", Change::Removed), ("red", Change::Added)]
    );

    let unstaged = preview(&repo, &target(DiffKind::Unstaged, file)).unwrap();
    assert_eq!(changes(&unstaged), expected);
    repo.git(&["add", "--", file]);
    let staged = preview(&repo, &target(DiffKind::Staged, file)).unwrap();
    assert_eq!(changes(&staged), expected);

    repo.git(&["commit", "-q", "-m", "edit the readme"]);
    let commit = DiffTarget {
        commit: Some(CommitSide {
            oid: repo.head(),
            parent: Some(repo.git(&["rev-parse", "HEAD^"]).trim().to_owned()),
        }),
        ..target(DiffKind::Commit, file)
    };
    assert_eq!(changes(&preview(&repo, &commit).unwrap()), expected);
}

#[test]
fn one_sided_files_show_plain_and_others_have_no_preview() {
    let repo = TestRepo::init();
    commit_text(&repo, "gone.md", OLD, "add");
    commit_text(&repo, "notes.txt", OLD, "add notes");
    fs::remove_file(repo.path().join("gone.md")).unwrap();
    put(&repo, "new.markdown", NEW);
    put(&repo, "notes.txt", NEW);

    let deleted = preview(&repo, &target(DiffKind::Head, "gone.md")).unwrap();
    assert_eq!(deleted.blocks.len(), 4);
    assert!(deleted.changes().is_empty());
    let added = preview(&repo, &target(DiffKind::Untracked, "new.markdown")).unwrap();
    assert_eq!(added.blocks.len(), 5);
    assert!(added.changes().is_empty());
    assert!(preview(&repo, &target(DiffKind::Head, "notes.txt")).is_none());
}

#[test]
fn large_sides_are_not_previewed() {
    let repo = TestRepo::init();
    commit_text(&repo, "big.md", "small\n", "add");
    put(&repo, "big.md", &"word ".repeat(MAX_MARKDOWN_BYTES / 4));
    let large = preview(&repo, &target(DiffKind::Head, "big.md")).unwrap();
    assert!(large.too_large);
    assert!(large.blocks.is_empty());
}

#[test]
fn the_runtime_loads_the_preview_with_the_diff() {
    let repo = TestRepo::init();
    commit_text(&repo, "README.md", OLD, "add");
    put(&repo, "README.md", NEW);
    let (mut rt, key) = open(&repo);
    rt.select_change(&key, Path::new("README.md"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| !d.is_loading() && d.markdown().is_some())
    });
    let state = rt.repo(&key).unwrap().diff().unwrap();
    assert_eq!(state.markdown().unwrap().changes(), vec![1, 4]);
    let offered = offered(state.diff().unwrap(), Path::new("README.md"));
    assert_eq!(offered.viewer, Viewer::Markdown);
}

/// Gap rows of the Changes diff's preview, as `(gap, hidden)`.
fn preview_gaps(rt: &gitbello_core::runtime::Runtime, key: &Path) -> Vec<(usize, usize)> {
    let state = rt.repo(key).expect("the repo").diff().expect("a diff");
    state
        .preview_layout()
        .rows()
        .iter()
        .filter_map(|row| match row {
            PreviewRow::Gap { gap, hidden, .. } => Some((*gap, *hidden)),
            PreviewRow::Block(_) => None,
        })
        .collect()
}

#[test]
fn the_preview_folds_unchanged_blocks_until_opened() {
    let repo = TestRepo::init();
    let doc = |edit: &str| -> String {
        (0..30)
            .map(|i| match i {
                15 => format!(
                    "paragraph {i} {edit}

"
                ),
                _ => format!(
                    "paragraph {i}

"
                ),
            })
            .collect()
    };
    commit_text(&repo, "README.md", &doc("old"), "add");
    put(&repo, "README.md", &doc("new"));
    let (mut rt, key) = open(&repo);
    rt.select_change(&key, Path::new("README.md"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| !d.is_loading() && d.markdown().is_some())
    });
    // Blocks 14..=16 show, 0..14 and 17..30 fold.
    assert_eq!(preview_gaps(&rt, &key), vec![(0, 14), (1, 13)]);

    rt.expand_markdown(&key, DiffSlot::Changes, 1, Expand::Down);
    assert_eq!(preview_gaps(&rt, &key), vec![(0, 14), (1, 8)]);

    // An edit elsewhere in the file reloads it with the gap kept open.
    put(&repo, "README.md", &doc("newer"));
    rt.refresh(&key, gitbello_core::jobs::RefreshSet::all());
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .and_then(|d| d.markdown())
            .is_some_and(|m| {
                m.blocks
                    .iter()
                    .any(|b| format!("{:?}", b.block).contains("newer"))
            })
    });
    assert_eq!(preview_gaps(&rt, &key), vec![(0, 14), (1, 8)]);

    // The whole file shows every block, and closes the gaps when turned off.
    rt.show_whole_diff(&key, DiffSlot::Changes, true);
    poll_until(&mut rt, |rt, _| preview_gaps(rt, &key).is_empty());
    let state = rt.repo(&key).unwrap().diff().unwrap();
    assert_eq!(state.preview_layout().rows().len(), 30);
    rt.show_whole_diff(&key, DiffSlot::Changes, false);
    poll_until(&mut rt, |rt, _| !preview_gaps(rt, &key).is_empty());
    assert_eq!(preview_gaps(&rt, &key), vec![(0, 14), (1, 13)]);
}

const PNG_A: &[u8] = b"\x89PNG\r\n\x1a\nfirst";
const PNG_B: &[u8] = b"\x89PNG\r\n\x1a\nsecond";

#[test]
fn pictures_are_read_at_the_side_that_shows_them() {
    let repo = TestRepo::init();
    fs::create_dir_all(repo.path().join("docs/pics")).unwrap();
    fs::write(repo.path().join("docs/pics/a.png"), PNG_A).unwrap();
    fs::write(repo.path().join("docs/pics/b.png"), PNG_A).unwrap();
    repo.git(&["add", "--all"]);
    commit_text(
        &repo,
        "docs/read.md",
        "![a](pics/a.png)\n\n![b](./pics/b.png)\n",
        "add",
    );
    // The working copy recolours a.png, drops b's paragraph and file, and
    // adds a missing picture and a web one.
    fs::write(repo.path().join("docs/pics/a.png"), PNG_B).unwrap();
    fs::remove_file(repo.path().join("docs/pics/b.png")).unwrap();
    put(
        &repo,
        "docs/read.md",
        "![a](pics/a.png)\n\n![gone](nope.png) ![web](https://x.dev/w.png)\n",
    );
    let head_target = target(DiffKind::Head, "docs/read.md");
    let head = preview(&repo, &head_target).unwrap();
    let image = |path: &str, old: bool| ImageRef {
        path: PathBuf::from(path),
        old,
    };
    assert_eq!(
        head.images,
        vec![
            image("docs/pics/a.png", false),
            image("docs/pics/b.png", true),
            image("docs/nope.png", false),
        ]
    );
    let backend = CliBackend::new(repo.app_runner());
    let read = read_images(
        &backend,
        repo.path(),
        &head_target,
        &head.images,
        &CancelToken::new(),
    )
    .expect("read the pictures");
    let bytes: Vec<Option<&[u8]>> = read
        .iter()
        .map(|i| i.as_ref().map(|i| &i.bytes[..]))
        .collect();
    assert_eq!(bytes, vec![Some(PNG_B), Some(PNG_A), None]);
    assert!(read[0]
        .as_ref()
        .is_some_and(|i| i.format == ImageFormat::Png));

    // A deleted document's pictures are its old side's.
    fs::remove_file(repo.path().join("docs/read.md")).unwrap();
    let deleted = preview(&repo, &head_target).unwrap();
    assert!(deleted.images.iter().all(|i| i.old));
}

#[test]
fn the_runtime_reads_the_pictures_after_the_diff() {
    let repo = TestRepo::init();
    fs::write(repo.path().join("logo.png"), PNG_A).unwrap();
    repo.git(&["add", "--all"]);
    commit_text(&repo, "README.md", "# Hi\n", "add");
    put(&repo, "README.md", "# Hi\n\n![logo](logo.png)\n");
    let (mut rt, key) = open(&repo);
    rt.select_change(&key, Path::new("README.md"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| !d.is_loading() && d.markdown_images_ready())
    });
    let state = rt.repo(&key).unwrap().diff().unwrap();
    let markdown = state.markdown().unwrap();
    assert_eq!(markdown.images.len(), 1);
    let picture = state.markdown_image(0).expect("the picture was read");
    assert_eq!(&picture.bytes[..], PNG_A);
    assert!(state.markdown_image(1).is_none());
    let Content::Text(spans) = &markdown.blocks[1].block.content else {
        panic!("not text");
    };
    assert_eq!(markdown.image_of(1, &spans[0]), Some(0));
}
