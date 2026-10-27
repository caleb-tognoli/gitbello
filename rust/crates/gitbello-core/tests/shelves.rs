//! Shelves (M6.5 P4 acceptance, PLAN §4 Shelves): stashes tied to a branch,
//! found by commit, through the runtime on real temporary repositories.

mod support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::git::GitErrorKind;
use gitbello_core::ops::{CheckoutChanges, CheckoutTarget};
use gitbello_core::repo::Shelf;
use gitbello_core::runtime::{Runtime, RuntimeEvent};
use support::rt::{open, outcome, poll_until, settle, succeed};
use support::TestRepo;

fn shelves(rt: &Runtime, key: &Path) -> Vec<Shelf> {
    rt.repo(key).expect("open").shelves().to_vec()
}

fn named(rt: &Runtime, key: &Path, name: &str) -> Shelf {
    shelves(rt, key)
        .into_iter()
        .find(|s| s.name == name)
        .unwrap_or_else(|| panic!("no shelf {name}: {:?}", shelves(rt, key)))
}

fn read(repo: &TestRepo, file: &str) -> Option<String> {
    fs::read_to_string(repo.path().join(file)).ok()
}

/// Re-reads the stash list (changed outside the runtime) and waits for it.
fn refresh_stashes(rt: &mut Runtime, key: &Path) {
    use gitbello_core::jobs::{RefreshKind, RefreshSet};
    rt.refresh(key, RefreshSet::EMPTY.with(RefreshKind::Stashes));
    settle(rt, key);
}

fn status(repo: &TestRepo) -> String {
    repo.git(&["status", "--porcelain"])
}

#[test]
fn shelve_files_untracked_included_then_restore() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.commit("keep.txt", "k\n", "more");
    repo.write("a.txt", "a2\n");
    repo.write("keep.txt", "k2\n");
    repo.write("new ünï.txt", "n\n");
    let (mut rt, key) = open(&repo);

    let job = rt.shelve(
        &key,
        vec![PathBuf::from("a.txt"), PathBuf::from("new ünï.txt")],
        "half done",
    );
    succeed(&mut rt, &key, job);
    assert_eq!(
        status(&repo),
        "M keep.txt",
        "only the picked files were shelved"
    );
    let shelf = named(&rt, &key, "half done");
    assert_eq!(
        (shelf.branch.as_deref(), shelf.auto, shelf.made_here),
        (Some("main"), false, true)
    );

    rt.load_shelf_files(&key, &shelf.oid).expect("job");
    poll_until(&mut rt, |_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::ShelfLoaded { oid, .. } if *oid == shelf.oid))
    });
    let files = rt
        .repo(&key)
        .and_then(|s| s.shelf_files(&shelf.oid))
        .expect("files")
        .to_vec();
    let listed: Vec<(String, bool)> = files
        .iter()
        .map(|f| (f.path.to_string_lossy().into_owned(), f.untracked))
        .collect();
    assert_eq!(
        listed,
        [
            ("a.txt".to_owned(), false),
            ("new ünï.txt".to_owned(), true)
        ]
    );

    // Previews: a tracked file against the shelf's base, an untracked one in full.
    for (path, added) in [("a.txt", "a2"), ("new ünï.txt", "n")] {
        rt.select_shelf_file(&key, &shelf.oid, Path::new(path), false);
        poll_until(&mut rt, |rt, _| {
            rt.repo(&key).and_then(|s| s.diff()).is_some_and(|d| {
                d.target().path == Path::new(path) && !d.is_loading() && d.diff().is_some()
            })
        });
        let diff = rt
            .repo(&key)
            .and_then(|s| s.diff())
            .and_then(|d| d.diff())
            .expect("diff");
        assert_eq!(diff.additions, 1, "{path}");
        assert!(
            diff.lines(0, 10).any(|l| l.text == added.as_bytes()),
            "{path}"
        );
        assert!(!rt.repo(&key).expect("open").can_pick_lines());
    }

    let job = rt.restore_shelf(&key, &shelf.oid);
    succeed(&mut rt, &key, job);
    assert_eq!(read(&repo, "a.txt").as_deref(), Some("a2\n"));
    assert_eq!(read(&repo, "new ünï.txt").as_deref(), Some("n\n"));
    assert!(shelves(&rt, &key).is_empty(), "a restored shelf is dropped");
}

#[test]
fn rename_the_only_shelf_keeps_its_contents_and_identity() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base\n", "base");
    repo.write("a.txt", "saved\n");
    let (mut rt, key) = open(&repo);
    let job = rt.shelve(&key, Vec::new(), "original");
    succeed(&mut rt, &key, job);
    let shelf = named(&rt, &key, "original");
    let error = outcome(&mut rt, &key, |rt| {
        rt.rename_shelf(&key, &shelf.oid, "renamed")
    });
    assert!(
        error.is_none(),
        "{error:?}; stash list: {}",
        repo.git(&["stash", "list"])
    );
    assert_eq!(shelves(&rt, &key).len(), 1);
    assert_eq!(named(&rt, &key, "renamed").oid, shelf.oid);
    assert!(repo
        .git(&["for-each-ref", "refs/gitbello/rename-shelf/"])
        .is_empty());
    let job = rt.restore_shelf(&key, &shelf.oid);
    succeed(&mut rt, &key, job);
    assert_eq!(read(&repo, "a.txt").as_deref(), Some("saved\n"));
}

#[test]
fn rename_the_newest_shelf_leaves_older_shelves_alone() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base\n", "base");
    repo.write("a.txt", "older\n");
    repo.git(&["stash", "push", "-q", "-m", "older"]);
    repo.write("a.txt", "newer\n");
    let (mut rt, key) = open(&repo);
    let older = named(&rt, &key, "older");
    let job = rt.shelve(&key, Vec::new(), "newer");
    succeed(&mut rt, &key, job);
    let newer = named(&rt, &key, "newer");
    let job = rt.rename_shelf(&key, &newer.oid, "renamed");
    succeed(&mut rt, &key, job);
    assert_eq!(shelves(&rt, &key).len(), 2);
    assert_eq!(named(&rt, &key, "older").oid, older.oid);
    assert_eq!(named(&rt, &key, "renamed").oid, newer.oid);
    assert_eq!(repo.git(&["status", "--porcelain"]), "");
}

#[test]
fn shelves_are_found_by_commit_after_other_stashes_move() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.write("a.txt", "mine\n");
    let (mut rt, key) = open(&repo);
    let job = rt.shelve(&key, Vec::new(), "mine");
    succeed(&mut rt, &key, job);
    let mine = named(&rt, &key, "mine");

    // Stashes made elsewhere push it down; dropping one shifts it again.
    repo.write("a.txt", "other\n");
    repo.git(&["stash", "push", "-q", "-m", "other work"]);
    repo.write("a.txt", "third\n");
    repo.git(&["stash", "push", "-q"]);
    repo.git(&["stash", "drop", "-q", "stash@{0}"]);
    refresh_stashes(&mut rt, &key);
    let other = named(&rt, &key, "other work");
    assert!(!other.made_here && other.branch.as_deref() == Some("main"));

    let job = rt.rename_shelf(&key, &mine.oid, "renamed");
    succeed(&mut rt, &key, job);
    let renamed = named(&rt, &key, "renamed");
    assert_eq!(renamed.oid, mine.oid, "a rename keeps the commit");
    assert_eq!(shelves(&rt, &key).len(), 2, "the old entry is gone");

    let job = rt.restore_shelf(&key, &mine.oid);
    succeed(&mut rt, &key, job);
    assert_eq!(read(&repo, "a.txt").as_deref(), Some("mine\n"));
    let left = shelves(&rt, &key);
    assert_eq!(left.len(), 1);
    assert_eq!(left[0].oid, other.oid, "the other stash is untouched");
}

#[test]
fn a_shelf_shows_in_another_worktree_on_its_branch() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.branch("feature");
    repo.checkout("feature");
    repo.write("a.txt", "on feature\n");
    let (mut rt, key) = open(&repo);
    let job = rt.shelve(&key, Vec::new(), "feature work");
    succeed(&mut rt, &key, job);
    repo.checkout("main");

    let linked = repo.sibling("linked wörktree");
    let linked_arg = support::path_arg(&linked);
    repo.git(&["worktree", "add", "--quiet", &linked_arg, "feature"]);
    let other = rt.open(&linked);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&other)
            .is_some_and(|s| s.current_branch() == Some("feature") && s.stashes().is_some())
    });
    let seen = named(&rt, &other, "feature work");
    assert_eq!(seen.branch.as_deref(), Some("feature"));

    // Restored from the linked worktree; the main one's list follows.
    let job = rt.restore_shelf(&other, &seen.oid);
    succeed(&mut rt, &other, job);
    assert_eq!(
        fs::read_to_string(linked.join("a.txt")).expect("a.txt"),
        "on feature\n"
    );
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).is_some_and(|s| s.shelves().is_empty())
    });
}

#[test]
fn a_conflicting_restore_keeps_the_shelf() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.write("a.txt", "shelved\n");
    let (mut rt, key) = open(&repo);
    let job = rt.shelve(&key, Vec::new(), "clash");
    succeed(&mut rt, &key, job);
    let shelf = named(&rt, &key, "clash");
    repo.commit("a.txt", "committed meanwhile\n", "meanwhile");
    settle(&mut rt, &key);

    let err = outcome(&mut rt, &key, |rt| rt.restore_shelf(&key, &shelf.oid)).expect("conflict");
    assert_ne!(err.kind, GitErrorKind::Stale);
    assert!(status(&repo).contains("UU a.txt"), "{}", status(&repo));
    assert_eq!(named(&rt, &key, "clash").oid, shelf.oid, "the shelf stays");
}

#[test]
fn discard_and_undo() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.write("a.txt", "keep me\n");
    let (mut rt, key) = open(&repo);
    let job = rt.shelve(&key, Vec::new(), "precious");
    succeed(&mut rt, &key, job);
    let shelf = named(&rt, &key, "precious");

    let job = rt.discard_shelf(&key, &shelf.oid);
    succeed(&mut rt, &key, job);
    assert!(shelves(&rt, &key).is_empty());
    assert!(rt.repo(&key).expect("open").can_undo_shelf_discard());

    let job = rt.undo_shelf_discard(&key);
    succeed(&mut rt, &key, job);
    let back = named(&rt, &key, "precious");
    assert_eq!(
        (back.oid, back.branch.as_deref()),
        (shelf.oid, Some("main"))
    );
    assert!(!rt.repo(&key).expect("open").can_undo_shelf_discard());
}

#[test]
fn leave_changes_on_switch() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.branch("feature");
    repo.write("a.txt", "work on main\n");
    repo.write("new.txt", "n\n");
    let (mut rt, key) = open(&repo);

    // A switch that fails puts the changes back.
    let err = outcome(&mut rt, &key, |rt| {
        rt.checkout(
            &key,
            CheckoutTarget::Branch("no-such-branch".into()),
            CheckoutChanges::Leave,
        )
    });
    assert!(err.is_some());
    assert_eq!(read(&repo, "a.txt").as_deref(), Some("work on main\n"));
    assert!(shelves(&rt, &key).is_empty());

    let job = rt.checkout(
        &key,
        CheckoutTarget::Branch("feature".into()),
        CheckoutChanges::Leave,
    );
    succeed(&mut rt, &key, job);
    assert_eq!(repo.git(&["branch", "--show-current"]), "feature");
    assert_eq!(status(&repo), "", "the changes stayed behind");
    let left = shelves(&rt, &key);
    assert_eq!(left.len(), 1);
    assert_eq!(
        (
            left[0].branch.as_deref(),
            left[0].auto,
            left[0].name.as_str()
        ),
        (Some("main"), true, "Left when switching to feature")
    );

    let job = rt.checkout(
        &key,
        CheckoutTarget::Branch("main".into()),
        CheckoutChanges::Keep,
    );
    succeed(&mut rt, &key, job);
    let job = rt.restore_shelf(&key, &left[0].oid);
    succeed(&mut rt, &key, job);
    assert_eq!(read(&repo, "new.txt").as_deref(), Some("n\n"));
    assert_eq!(read(&repo, "a.txt").as_deref(), Some("work on main\n"));
}
