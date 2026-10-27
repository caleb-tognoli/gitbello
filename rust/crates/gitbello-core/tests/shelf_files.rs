//! Per-file shelf edits on real throwaway repositories.

mod support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::repo::{Shelf, ShelfFile};
use gitbello_core::runtime::{Runtime, RuntimeEvent};
use support::rt::{open, outcome, poll_until, settle, succeed};
use support::TestRepo;

fn shelf(rt: &Runtime, key: &Path) -> Shelf {
    rt.repo(key)
        .expect("open repository")
        .shelves()
        .first()
        .expect("shelf")
        .clone()
}

fn files(rt: &mut Runtime, key: &Path, oid: &str) -> Vec<ShelfFile> {
    rt.load_shelf_files(key, oid).expect("load");
    poll_until(rt, |_, events| {
        events
            .iter()
            .any(|e| matches!(e, RuntimeEvent::ShelfLoaded { oid: id, .. } if id == oid))
    });
    rt.repo(key)
        .expect("open repository")
        .shelf_files(oid)
        .expect("loaded files")
        .to_vec()
}

fn create(rt: &mut Runtime, key: &Path) -> Shelf {
    // Match the UI, which sends explicit worktree-relative paths.
    let paths = rt
        .repo(key)
        .expect("open")
        .status()
        .expect("status")
        .changes
        .iter()
        .map(|c| c.path.clone())
        .collect();
    let job = rt.shelve(key, paths, "mixed work");
    succeed(rt, key, job);
    shelf(rt, key)
}

#[test]
fn restore_one_preserves_staging_unrelated_local_edits_and_the_remainder() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a base\n", "base");
    repo.commit("b.txt", "b base\n", "base b");
    repo.commit("local.txt", "local base\n", "base local");
    repo.write("a.txt", "a staged\n");
    repo.git(&["add", "a.txt"]);
    repo.write("a.txt", "a working\n");
    repo.write("b.txt", "b saved\n");
    repo.write("new ünï.txt", "new saved\n");
    let (mut rt, key) = open(&repo);
    let original = create(&mut rt, &key);
    assert!(
        !repo.path().join("new ünï.txt").exists(),
        "untracked file was shelved; status: {}; stored: {}",
        repo.git(&["status", "--porcelain"]),
        repo.git(&[
            "stash",
            "show",
            "--only-untracked",
            "--name-only",
            &original.oid
        ])
    );
    repo.write("local.txt", "unrelated staged\n");
    repo.git(&["add", "local.txt"]);
    let job = rt.restore_shelf_file(&key, &original.oid, Path::new("a.txt"));
    succeed(&mut rt, &key, job);
    assert_eq!(
        fs::read_to_string(repo.path().join("a.txt")).unwrap(),
        "a working\n"
    );
    assert_eq!(repo.git(&["show", ":a.txt"]), "a staged");
    assert_eq!(repo.git(&["show", ":local.txt"]), "unrelated staged");
    assert_eq!(
        fs::read_to_string(repo.path().join("b.txt")).unwrap(),
        "b base\n"
    );
    assert!(!repo.path().join("new ünï.txt").exists());
    let remainder = shelf(&rt, &key);
    assert_ne!(remainder.oid, original.oid);
    assert_eq!(
        remainder.time, original.time,
        "the shelf keeps its original date"
    );
    assert_eq!(
        (remainder.name, remainder.branch, remainder.auto),
        (original.name, original.branch, original.auto)
    );
    let listed = files(&mut rt, &key, &remainder.oid);
    assert_eq!(
        listed.iter().map(|f| f.path.clone()).collect::<Vec<_>>(),
        [PathBuf::from("b.txt"), PathBuf::from("new ünï.txt")]
    );
    let job = rt.restore_shelf_file(&key, &remainder.oid, Path::new("new ünï.txt"));
    succeed(&mut rt, &key, job);
    assert_eq!(
        fs::read_to_string(repo.path().join("new ünï.txt")).unwrap(),
        "new saved\n"
    );
    assert_eq!(repo.git(&["show", ":a.txt"]), "a staged");
    assert_eq!(repo.git(&["show", ":local.txt"]), "unrelated staged");
    let remainder = shelf(&rt, &key);
    let job = rt.restore_shelf_file(&key, &remainder.oid, Path::new("b.txt"));
    succeed(&mut rt, &key, job);
    assert!(rt.repo(&key).unwrap().shelves().is_empty());
    assert_eq!(
        fs::read_to_string(repo.path().join("b.txt")).unwrap(),
        "b saved\n"
    );
    assert!(repo
        .git(&["for-each-ref", "refs/gitbello/shelf-backup/"])
        .is_empty());
}

#[test]
fn discard_one_and_undo_replace_the_shelf_without_touching_working_files() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base\n", "base");
    repo.write("a.txt", "saved\n");
    repo.write("new.txt", "new saved\n");
    let (mut rt, key) = open(&repo);
    let original = create(&mut rt, &key);
    repo.write("local.txt", "keep me\n");
    let before = repo.git(&["status", "--porcelain"]);
    let job = rt.discard_shelf_file(&key, &original.oid, Path::new("new.txt"));
    succeed(&mut rt, &key, job);
    let remainder = shelf(&rt, &key);
    assert_eq!(files(&mut rt, &key, &remainder.oid).len(), 1);
    assert_eq!(repo.git(&["status", "--porcelain"]), before);
    assert!(rt.repo(&key).unwrap().can_undo_shelf_discard());
    let job = rt.undo_shelf_discard(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(shelf(&rt, &key).oid, original.oid);
    assert_eq!(rt.repo(&key).unwrap().shelves().len(), 1);
    assert_eq!(files(&mut rt, &key, &original.oid).len(), 2);
    assert_eq!(repo.git(&["status", "--porcelain"]), before);
    assert!(repo
        .git(&["for-each-ref", "refs/gitbello/shelf-backup/"])
        .is_empty());
    assert!(!rt.repo(&key).unwrap().can_undo_shelf_discard());
}

#[test]
fn last_file_discard_removes_the_shelf_and_undo_recovers_it() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base\n", "base");
    repo.write("a.txt", "saved\n");
    let (mut rt, key) = open(&repo);
    let original = create(&mut rt, &key);
    let job = rt.discard_shelf_file(&key, &original.oid, Path::new("a.txt"));
    succeed(&mut rt, &key, job);
    assert!(rt.repo(&key).unwrap().shelves().is_empty());
    let job = rt.undo_shelf_discard(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(shelf(&rt, &key).oid, original.oid);
}

#[test]
fn restore_and_discard_support_added_deleted_renamed_and_binary_files() {
    for kind in ["added", "deleted", "renamed", "binary"] {
        for restore in [true, false] {
            let repo = TestRepo::init();
            repo.commit("original.txt", "original content\n", "base");
            repo.commit("keep.txt", "keep base\n", "base keep");
            let path = match kind {
                "added" => {
                    repo.write("new ü file.txt", "added\n");
                    repo.git(&["add", "new ü file.txt"]);
                    "new ü file.txt"
                }
                "deleted" => {
                    fs::remove_file(repo.path().join("original.txt")).unwrap();
                    "original.txt"
                }
                "renamed" => {
                    repo.git(&["mv", "original.txt", "renamed ü file.txt"]);
                    "renamed ü file.txt"
                }
                "binary" => {
                    fs::write(repo.path().join("original.txt"), [0, 255, 1, 0]).unwrap();
                    "original.txt"
                }
                _ => unreachable!(),
            };
            repo.write("keep.txt", "keep saved\n");
            // The source of a staged rename no longer matches an explicit
            // stash pathspec, so build this fixture using git's all-files mode.
            repo.git(&[
                "stash",
                "push",
                "--include-untracked",
                "-q",
                "-m",
                "mixed work",
            ]);
            let (mut rt, key) = open(&repo);
            let original = shelf(&rt, &key);
            assert!(
                repo.git(&["status", "--porcelain"]).is_empty(),
                "{kind}: shelving left local changes: {}",
                repo.git(&["status", "--porcelain"])
            );
            let job = if restore {
                rt.restore_shelf_file(&key, &original.oid, Path::new(path))
            } else {
                rt.discard_shelf_file(&key, &original.oid, Path::new(path))
            };
            succeed(&mut rt, &key, job);
            let remainder = shelf(&rt, &key);
            let list = files(&mut rt, &key, &remainder.oid);
            assert_eq!(list.len(), 1, "{kind}, restore={restore}: {list:?}");
            assert_eq!(list[0].path, Path::new("keep.txt"));
            assert_eq!(
                fs::read_to_string(repo.path().join("keep.txt")).unwrap(),
                "keep base\n"
            );
            if restore {
                match kind {
                    "added" => assert_eq!(
                        fs::read_to_string(repo.path().join(path)).unwrap(),
                        "added\n"
                    ),
                    "deleted" => assert!(!repo.path().join(path).exists()),
                    "renamed" => {
                        assert!(!repo.path().join("original.txt").exists());
                        assert_eq!(
                            fs::read_to_string(repo.path().join(path)).unwrap(),
                            "original content\n"
                        );
                    }
                    "binary" => {
                        assert_eq!(fs::read(repo.path().join(path)).unwrap(), [0, 255, 1, 0])
                    }
                    _ => unreachable!(),
                }
            } else {
                assert!(repo.git(&["status", "--porcelain"]).is_empty());
                let job = rt.undo_shelf_discard(&key);
                succeed(&mut rt, &key, job);
                assert_eq!(shelf(&rt, &key).oid, original.oid);
            }
        }
    }
}

#[test]
fn invalid_and_conflicting_restores_keep_the_original_shelf_and_local_edits() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base\n", "base");
    repo.commit("b.txt", "base b\n", "base b");
    repo.write("a.txt", "saved\n");
    repo.write("b.txt", "saved b\n");
    let (mut rt, key) = open(&repo);
    let original = create(&mut rt, &key);
    repo.write("a.txt", "local edit\n");
    for path in ["missing.txt", "../a.txt", "a.txt"] {
        let error = outcome(&mut rt, &key, |rt| {
            rt.restore_shelf_file(&key, &original.oid, Path::new(path))
        });
        assert!(error.is_some(), "{path} must fail");
        assert_eq!(shelf(&rt, &key).oid, original.oid);
        assert_eq!(
            fs::read_to_string(repo.path().join("a.txt")).unwrap(),
            "local edit\n"
        );
        assert_eq!(
            fs::read_to_string(repo.path().join("b.txt")).unwrap(),
            "base b\n"
        );
    }
    assert!(outcome(&mut rt, &key, |rt| rt.discard_shelf_file(
        &key,
        "deadbeef",
        Path::new("a.txt")
    ))
    .is_some());
}

#[test]
fn undo_refuses_a_changed_or_missing_remainder_and_remains_available() {
    for rename in [false, true] {
        let repo = TestRepo::init();
        repo.commit("a.txt", "base\n", "base");
        repo.write("a.txt", "saved\n");
        repo.write("new.txt", "new saved\n");
        let (mut rt, key) = open(&repo);
        let original = create(&mut rt, &key);
        let job = rt.discard_shelf_file(&key, &original.oid, Path::new("new.txt"));
        succeed(&mut rt, &key, job);
        let remainder = shelf(&rt, &key);
        if rename {
            let job = rt.rename_shelf(&key, &remainder.oid, "changed name");
            succeed(&mut rt, &key, job);
        } else {
            repo.git(&["stash", "drop", "-q"]);
        }
        assert!(outcome(&mut rt, &key, |rt| rt.undo_shelf_discard(&key)).is_some());
        assert!(rt.repo(&key).unwrap().can_undo_shelf_discard());
        assert_eq!(repo.git(&["stash", "list"]).is_empty(), !rename);
    }
}

#[test]
fn file_edit_refreshes_other_worktrees_and_reports_the_replacement() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base\n", "base");
    let other = repo.add_worktree("other", "other");
    repo.write("a.txt", "saved\n");
    repo.write("new.txt", "new saved\n");
    let (mut rt, key) = open(&repo);
    let original = create(&mut rt, &key);
    let other_key = rt.open(&other);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&other_key).is_some_and(|s| !s.shelves().is_empty())
    });
    let job = rt
        .discard_shelf_file(&key, &original.oid, Path::new("new.txt"))
        .unwrap();
    let events = poll_until(&mut rt, |rt, events| {
        support::rt::result(events, job).is_some()
            && rt
                .repo(&other_key)
                .is_some_and(|s| s.shelves().first().is_some_and(|s| s.oid != original.oid))
    });
    assert!(events.iter().any(|e| matches!(e, RuntimeEvent::ShelfReplaced { repo, old_oid, new_oid: Some(_) } if repo == &other_key && old_oid == &original.oid)));
    settle(&mut rt, &key);
    assert_eq!(shelf(&rt, &key).oid, shelf(&rt, &other_key).oid);
}

#[test]
fn index_only_remainders_stay_visible_and_restore_staged_and_working_versions() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base a\n", "base");
    repo.commit("b.txt", "base b\n", "base b");
    repo.write("a.txt", "staged a\n");
    repo.git(&["add", "a.txt"]);
    repo.write("a.txt", "base a\n");
    repo.write("b.txt", "saved b\n");
    repo.git(&["stash", "push", "-q", "-m", "index only"]);
    let (mut rt, key) = open(&repo);
    let original = shelf(&rt, &key);
    let job = rt.restore_shelf_file(&key, &original.oid, Path::new("b.txt"));
    succeed(&mut rt, &key, job);
    let remainder = shelf(&rt, &key);
    let list = files(&mut rt, &key, &remainder.oid);
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].path, Path::new("a.txt"));
    rt.select_shelf_file(&key, &remainder.oid, Path::new("a.txt"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| !d.is_loading() && d.diff().is_some())
    });
    assert!(rt
        .repo(&key)
        .unwrap()
        .diff()
        .unwrap()
        .diff()
        .unwrap()
        .lines(0, 20)
        .any(|line| line.text == b"staged a"));
    let job = rt.restore_shelf_file(&key, &remainder.oid, Path::new("a.txt"));
    succeed(&mut rt, &key, job);
    assert_eq!(repo.git(&["show", ":a.txt"]), "staged a");
    assert_eq!(
        fs::read_to_string(repo.path().join("a.txt")).unwrap(),
        "base a\n"
    );
    assert!(rt.repo(&key).unwrap().shelves().is_empty());
}

#[test]
fn divergent_branch_conflict_keeps_the_shelf_and_real_index_conflict_stages() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base\n", "base");
    repo.commit("b.txt", "base b\n", "base b");
    repo.write("a.txt", "saved\n");
    repo.write("b.txt", "saved b\n");
    repo.git(&["stash", "push", "-q", "-m", "original"]);
    repo.commit("a.txt", "other branch\n", "diverged");
    let (mut rt, key) = open(&repo);
    let original = shelf(&rt, &key);
    let error = outcome(&mut rt, &key, |rt| {
        rt.restore_shelf_file(&key, &original.oid, Path::new("a.txt"))
    })
    .expect("conflict");
    assert_eq!(error.kind, gitbello_core::git::GitErrorKind::Conflict);
    assert_eq!(shelf(&rt, &key).oid, original.oid);
    assert!(repo
        .git(&["ls-files", "--unmerged", "--", "a.txt"])
        .contains(" 3\t"));
    assert_eq!(
        fs::read_to_string(repo.path().join("b.txt")).unwrap(),
        "base b\n"
    );
}

#[test]
fn editing_an_older_shelf_does_not_change_other_shelves() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base\n", "base");
    repo.write("a.txt", "saved\n");
    repo.write("new.txt", "new saved\n");
    let (mut rt, key) = open(&repo);
    let original = create(&mut rt, &key);
    repo.write("other.txt", "other saved\n");
    let job = rt.shelve(&key, vec![PathBuf::from("other.txt")], "other");
    succeed(&mut rt, &key, job);
    let other = shelf(&rt, &key);
    let job = rt.discard_shelf_file(&key, &original.oid, Path::new("new.txt"));
    succeed(&mut rt, &key, job);
    let all = rt.repo(&key).unwrap().shelves();
    assert_eq!(all.len(), 2);
    assert!(all.contains(&other));
    let job = rt.undo_shelf_discard(&key);
    succeed(&mut rt, &key, job);
    let all = rt.repo(&key).unwrap().shelves();
    assert_eq!(all.len(), 2);
    assert!(all.contains(&other));
    assert!(all.iter().any(|s| s.oid == original.oid));
}

#[test]
fn restore_never_overwrites_an_existing_ignored_file() {
    let repo = TestRepo::init();
    repo.commit("base.txt", "base\n", "base");
    repo.write("new.txt", "shelved addition\n");
    repo.git(&["add", "new.txt"]);
    repo.git(&["stash", "push", "-q", "-m", "addition"]);
    repo.write(".gitignore", "new.txt\n");
    repo.write("new.txt", "local ignored file\n");
    let (mut rt, key) = open(&repo);
    let original = shelf(&rt, &key);
    assert!(outcome(&mut rt, &key, |rt| rt.restore_shelf_file(
        &key,
        &original.oid,
        Path::new("new.txt")
    ))
    .is_some());
    assert_eq!(
        fs::read_to_string(repo.path().join("new.txt")).unwrap(),
        "local ignored file\n"
    );
    assert_eq!(shelf(&rt, &key).oid, original.oid);
}
