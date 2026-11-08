//! Open (M7.8 P3) on temporary repositories: the version of a file a diff
//! shows, from a commit, its parent (a deleted file), the index, HEAD or the
//! working tree, and the runtime's job and event.

mod support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::backend::CliBackend;
use gitbello_core::diff::version::{open_version, VersionSide};
use gitbello_core::diff::{CommitSide, DiffKind, DiffTarget};
use gitbello_core::git::CancelToken;
use gitbello_core::runtime::{DiffSlot, RuntimeEvent};
use support::rt::{open, poll_until};
use support::TestRepo;

fn write(repo: &TestRepo, file: &str, text: &str) {
    let path = repo.path().join(file);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create the folder");
    }
    fs::write(path, text).expect("write the file");
}

/// A repository with `dir/ä b.txt` and `gone.txt` committed, then a second
/// commit changing the first and deleting the second, then the first changed
/// again in the working tree. Returns the two commits.
fn history(repo: &TestRepo) -> (String, String) {
    write(repo, "dir/ä b.txt", "one\n");
    write(repo, "gone.txt", "gone\n");
    repo.git(&["add", "-A"]);
    repo.git(&["commit", "-q", "-m", "first"]);
    let first = repo.head();
    write(repo, "dir/ä b.txt", "two\n");
    fs::remove_file(repo.path().join("gone.txt")).expect("delete gone.txt");
    repo.git(&["add", "-A"]);
    repo.git(&["commit", "-q", "-m", "second"]);
    let second = repo.head();
    write(repo, "dir/ä b.txt", "three\n");
    (first, second)
}

fn commit_target(path: &str, oid: &str, parent: &str) -> DiffTarget {
    DiffTarget {
        kind: DiffKind::Commit,
        path: PathBuf::from(path),
        original_path: None,
        commit: Some(CommitSide {
            oid: oid.to_owned(),
            parent: Some(parent.to_owned()),
        }),
    }
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).expect("read the version")
}

#[test]
fn versions_come_from_commits_parents_the_index_and_the_working_tree() {
    let repo = TestRepo::init();
    let (first, second) = history(&repo);
    let dir = repo
        .path()
        .join("..")
        .join(format!("versions-{}", std::process::id()));
    let backend = CliBackend::new(repo.app_runner());
    let cancel = CancelToken::new();
    let version = |target: &DiffTarget, side: VersionSide| {
        open_version(&backend, repo.path(), target, side, &dir, &cancel)
    };

    // A commit's file: the commit's version, its parent's as the old side,
    // written under the versions folder with the file's own name.
    let changed = commit_target("dir/ä b.txt", &second, &first);
    let shown = version(&changed, VersionSide::Shown).unwrap();
    assert_eq!(read(&shown), "two\n");
    assert!(
        shown.starts_with(&dir) && shown.ends_with("ä b.txt"),
        "{shown:?}"
    );
    assert_eq!(read(&version(&changed, VersionSide::Old).unwrap()), "one\n");
    // Opening it again reuses the file.
    assert_eq!(version(&changed, VersionSide::Shown).unwrap(), shown);

    // A file the commit deleted shows its parent's version; it has no new side.
    let deleted = commit_target("gone.txt", &second, &first);
    assert_eq!(
        read(&version(&deleted, VersionSide::Shown).unwrap()),
        "gone\n"
    );
    assert!(version(&deleted, VersionSide::New).is_err());

    // Changes: the working copy itself, HEAD as the old side.
    let head = DiffTarget {
        kind: DiffKind::Head,
        path: PathBuf::from("dir/ä b.txt"),
        original_path: None,
        commit: None,
    };
    assert_eq!(
        version(&head, VersionSide::Shown).unwrap(),
        repo.path().join("dir/ä b.txt")
    );
    assert_eq!(read(&version(&head, VersionSide::Old).unwrap()), "two\n");

    // Staged: the index against HEAD.
    write(&repo, "dir/ä b.txt", "staged\n");
    repo.git(&["add", "-A"]);
    write(&repo, "dir/ä b.txt", "working\n");
    let staged = DiffTarget {
        kind: DiffKind::Staged,
        ..head
    };
    assert_eq!(
        read(&version(&staged, VersionSide::Shown).unwrap()),
        "staged\n"
    );
    assert_eq!(read(&version(&staged, VersionSide::Old).unwrap()), "two\n");
    fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn the_runtime_opens_the_shown_diff_and_reports_where() {
    let repo = TestRepo::init();
    let (_, second) = history(&repo);
    let (mut rt, key) = open(&repo);
    let dir = repo
        .path()
        .join("..")
        .join(format!("rt-versions-{}", std::process::id()));
    rt.set_versions_dir(dir.clone());
    let ready = |events: &[RuntimeEvent]| {
        events.iter().find_map(|e| match e {
            RuntimeEvent::VersionReady { result, .. } => Some(result.clone()),
            _ => None,
        })
    };

    // History: the deleted file opens as its parent's version.
    rt.load_commit(&key, &second);
    poll_until(&mut rt, |_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::CommitLoaded { .. }))
    });
    rt.select_commit_file(&key, Some(Path::new("gone.txt")), false);
    assert!(rt
        .open_version(&key, DiffSlot::Commit, VersionSide::Shown)
        .is_some());
    let events = poll_until(&mut rt, |_, ev| ready(ev).is_some());
    let path = ready(&events).unwrap().expect("the version");
    assert!(path.starts_with(&dir));
    assert_eq!(read(&path), "gone\n");

    // Changes: the working copy.
    rt.select_change(&key, Path::new("dir/ä b.txt"), false);
    assert!(rt
        .open_version(&key, DiffSlot::Changes, VersionSide::Shown)
        .is_some());
    let events = poll_until(&mut rt, |_, ev| ready(ev).is_some());
    // The runtime reports the root git resolved, which can spell the temp
    // dir differently (macOS /private/var, Windows 8.3 short names).
    assert_eq!(
        ready(&events)
            .unwrap()
            .expect("the working copy")
            .canonicalize()
            .unwrap(),
        repo.path().join("dir/ä b.txt").canonicalize().unwrap()
    );
    fs::remove_dir_all(&dir).unwrap();
}
