//! Commit details and per-file commit diffs on real repositories.

mod support;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use gitbello_core::backend::{CliBackend, GitBackend};
use gitbello_core::config::Config;
use gitbello_core::diff::{CommitSide, DiffContent, DiffKind, DiffTarget, LineKind};
use gitbello_core::git::CancelToken;
use gitbello_core::repo::Change;
use gitbello_core::runtime::{DiffSlot, Runtime, RuntimeEvent};
use support::TestRepo;

fn backend(repo: &TestRepo) -> CliBackend {
    CliBackend::new(repo.app_runner())
}

#[test]
fn details_of_root_normal_rename_and_merge_commits() {
    let repo = TestRepo::init();
    let root = repo.commit("a.txt", "a\n", "Root\n\nFirst body line.");
    repo.commit("old name.txt", "same content\nfor rename\n", "Add old");
    repo.git(&["mv", "old name.txt", "new näme.txt"]);
    repo.write("a.txt", "a\nb\n");
    repo.git(&["add", "-A"]);
    repo.git(&["commit", "-q", "-m", "Rename and edit"]);
    let renamed = repo.head();
    let b = backend(&repo);

    let details = b
        .commit_details(repo.path(), &root, &CancelToken::new())
        .unwrap();
    assert!(details.parents.is_empty());
    assert_eq!(details.summary(), "Root");
    assert_eq!(details.body(), "First body line.");
    assert_eq!(details.author_name, "Ada Lövelace");
    assert_eq!(details.files.len(), 1);
    assert_eq!(details.files[0].change, Change::Added);
    assert_eq!(
        (details.additions, details.deletions),
        (1, 0),
        "the root adds a.txt's line"
    );

    let details = b
        .commit_details(repo.path(), &renamed, &CancelToken::new())
        .unwrap();
    assert_eq!(details.parents.len(), 1);
    let rename = details
        .files
        .iter()
        .find(|f| f.change == Change::Renamed)
        .expect("rename listed");
    assert_eq!(rename.path, PathBuf::from("new näme.txt"));
    assert_eq!(rename.original_path, Some(PathBuf::from("old name.txt")));
    assert_eq!(
        (details.additions, details.deletions),
        (1, 0),
        "a pure rename adds no lines, a.txt one"
    );

    // A file diff in that commit, and the root commit's diff.
    let target = DiffTarget {
        kind: DiffKind::Commit,
        path: PathBuf::from("a.txt"),
        original_path: None,
        commit: Some(CommitSide {
            oid: renamed.clone(),
            parent: details.parents.first().cloned(),
        }),
    };
    let diff = b
        .diff(repo.path(), &target, None, &CancelToken::new())
        .unwrap();
    assert_eq!((diff.additions, diff.deletions), (1, 0));
    let added: Vec<&[u8]> = diff
        .lines(0, 99)
        .filter(|l| l.kind == LineKind::Added)
        .map(|l| l.text)
        .collect();
    assert_eq!(added, [b"b"]);
    let root_target = DiffTarget {
        commit: Some(CommitSide {
            oid: root.clone(),
            parent: None,
        }),
        ..target.clone()
    };
    let root_diff = b
        .diff(repo.path(), &root_target, None, &CancelToken::new())
        .unwrap();
    assert!(root_diff.header.new_file);
    let rename_target = DiffTarget {
        path: PathBuf::from("new näme.txt"),
        original_path: Some(PathBuf::from("old name.txt")),
        ..target
    };
    let rename_diff = b
        .diff(repo.path(), &rename_target, None, &CancelToken::new())
        .unwrap();
    assert_eq!(
        rename_diff.header.renamed_from.as_deref(),
        Some("old name.txt")
    );

    // A merge lists its changes against the first parent.
    repo.branch("side");
    repo.commit("main.txt", "m\n", "On main");
    repo.checkout("side");
    repo.commit("side.txt", "s\n", "On side");
    repo.checkout("main");
    let merge = repo.merge("side", "Merge side");
    let details = b
        .commit_details(repo.path(), &merge, &CancelToken::new())
        .unwrap();
    assert_eq!(details.parents.len(), 2);
    let paths: Vec<&Path> = details.files.iter().map(|f| f.path.as_path()).collect();
    assert_eq!(paths, [Path::new("side.txt")]);
}

#[test]
fn binary_files_in_commits_report_sizes() {
    let repo = TestRepo::init();
    std::fs::write(repo.path().join("i.bin"), [0u8, 1, 2]).unwrap();
    repo.git(&["add", "i.bin"]);
    repo.git(&["commit", "-q", "-m", "bin"]);
    std::fs::write(repo.path().join("i.bin"), [0u8, 1, 2, 3, 4]).unwrap();
    repo.git(&["commit", "-q", "-am", "bigger"]);
    let head = repo.head();
    let parent = repo.git(&["rev-parse", "HEAD^"]);
    let target = DiffTarget {
        kind: DiffKind::Commit,
        path: PathBuf::from("i.bin"),
        original_path: None,
        commit: Some(CommitSide {
            oid: head,
            parent: Some(parent),
        }),
    };
    let diff = backend(&repo)
        .diff(repo.path(), &target, None, &CancelToken::new())
        .unwrap();
    assert_eq!(
        diff.content,
        DiffContent::Binary {
            old_size: Some(3),
            new_size: Some(5)
        }
    );
}

#[test]
fn runtime_loads_a_commit_and_its_file_diffs() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "First");
    let second = repo.commit("a.txt", "a\nmore\n", "Second");
    let mut rt = Runtime::with_runner(Config::default(), None, repo.app_runner());
    let key = rt.open(repo.path());
    let deadline = Instant::now() + Duration::from_secs(10);
    let wait = |rt: &mut Runtime, done: &dyn Fn(&Runtime, &[RuntimeEvent]) -> bool| {
        let mut seen = Vec::new();
        loop {
            seen.extend(rt.poll());
            if done(rt, &seen) {
                return;
            }
            assert!(Instant::now() < deadline, "timed out: {seen:#?}");
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    wait(&mut rt, &|rt, _| {
        rt.repo(&key).is_some_and(|s| s.is_ready())
    });
    rt.load_commit(&key, &second[..10]);
    wait(&mut rt, &|_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::CommitLoaded { .. }))
    });
    let commit = rt.repo(&key).unwrap().commit().unwrap().clone();
    assert_eq!(commit.oid, second);
    assert_eq!(commit.summary(), "Second");

    rt.select_commit_file(&key, Some(Path::new("a.txt")), false);
    wait(&mut rt, &|_, ev| {
        ev.iter().any(|e| {
            matches!(
                e,
                RuntimeEvent::DiffChanged {
                    slot: DiffSlot::Commit,
                    ..
                }
            )
        })
    });
    let state = rt.repo(&key).unwrap();
    assert_eq!(state.commit_diff().unwrap().diff().unwrap().additions, 1);
    // The changes panel's diff is a separate slot.
    assert!(state.diff().is_none());
}
