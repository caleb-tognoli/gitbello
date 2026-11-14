//! Uncommitted moves (a file moved without `git mv`): one renamed change in
//! Changes, its diff, commit, discard with undo and shelve, on real
//! temporary repositories.

mod support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::backend::{CliBackend, GitBackend};
use gitbello_core::changes::change_code;
use gitbello_core::diff::{DiffContent, LineKind};
use gitbello_core::git::CancelToken;
use gitbello_core::moves::is_worktree_move;
use gitbello_core::repo::{Change as DiffChange, FileChange, RepoStatus};
use gitbello_core::runtime::Runtime;
use support::rt::{open, poll_until, succeed};
use support::TestRepo;

fn lines(count: usize) -> String {
    (1..=count).map(|n| format!("line {n}\n")).collect()
}

/// A repository with `src/util.rs` committed, then moved to `lib/util.rs`
/// with one line edited, plus a deleted and an untracked file that are not
/// the same file.
fn moved() -> TestRepo {
    let repo = TestRepo::init();
    repo.commit("src/util.rs", &lines(40), "base");
    repo.commit("gone.txt", "bye\n", "more");
    fs::remove_file(repo.path().join("src/util.rs")).expect("file operation");
    repo.write(
        "lib/util.rs",
        &lines(40).replace("line 20\n", "line twenty\n"),
    );
    fs::remove_file(repo.path().join("gone.txt")).expect("file operation");
    repo.write("notes.txt", "something else\n");
    repo
}

fn paired(repo: &TestRepo) -> RepoStatus {
    let backend = CliBackend::new(repo.app_runner());
    let cancel = CancelToken::new();
    let mut status = backend.status(repo.path(), &cancel).expect("status");
    backend
        .pair_moves(repo.path(), &mut status, &cancel)
        .expect("pair");
    status
}

fn find<'a>(status: &'a RepoStatus, path: &str) -> Option<&'a FileChange> {
    status.changes.iter().find(|c| c.path == Path::new(path))
}

fn changes_of(rt: &Runtime, key: &Path) -> Vec<(String, String)> {
    let status = rt.repo(key).and_then(|s| s.status()).expect("status");
    let mut out: Vec<(String, String)> = status
        .changes
        .iter()
        .map(|c| {
            (
                change_code(c).to_owned(),
                c.path.to_string_lossy().into_owned(),
            )
        })
        .collect();
    out.sort();
    out
}

fn wait_for(rt: &mut Runtime, key: &Path, wanted: &[(&str, &str)]) {
    let wanted: Vec<(String, String)> = wanted
        .iter()
        .map(|(c, p)| ((*c).to_owned(), (*p).to_owned()))
        .collect();
    poll_until(rt, |rt, _| {
        rt.repo(key).and_then(|s| s.status()).is_some() && changes_of(rt, key) == wanted
    });
}

#[test]
fn a_moved_file_pairs_with_its_source() {
    let repo = moved();
    let status = paired(&repo);
    let moved = find(&status, "lib/util.rs").expect("moved file listed");
    assert!(is_worktree_move(moved));
    assert_eq!(change_code(moved), "R");
    assert_eq!(moved.original_path, Some(PathBuf::from("src/util.rs")));
    assert!(moved.score.is_some_and(|s| s >= 90), "{:?}", moved.score);
    assert!(
        find(&status, "src/util.rs").is_none(),
        "the source is folded in"
    );
    assert_eq!(change_code(find(&status, "gone.txt").expect("listed")), "D");
    assert_eq!(
        change_code(find(&status, "notes.txt").expect("listed")),
        "?"
    );
    // Read-only: the real index has no trace of the scratch one.
    assert_eq!(repo.git(&["ls-files"]), "gone.txt\nsrc/util.rs");
    let leftovers: Vec<_> = fs::read_dir(repo.path().join(".git"))
        .expect("file operation")
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("gitbello-"))
        .collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
    // The same files pair the same way from the cache.
    assert_eq!(paired(&repo), status);
}

#[test]
fn the_diff_of_a_move_is_its_edit() {
    let repo = moved();
    let (mut rt, key) = open(&repo);
    wait_for(
        &mut rt,
        &key,
        &[("?", "notes.txt"), ("D", "gone.txt"), ("R", "lib/util.rs")],
    );
    rt.select_change(&key, Path::new("lib/util.rs"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| !d.is_loading() && d.diff().is_some())
    });
    let state = rt.repo(&key).and_then(|s| s.diff()).expect("diff state");
    assert_eq!(
        state.target().original_path,
        Some(PathBuf::from("src/util.rs"))
    );
    let diff = state.diff().expect("diff");
    assert_eq!(diff.content, DiffContent::Text);
    assert_eq!(diff.header.change(), DiffChange::Renamed);
    assert_eq!((diff.additions, diff.deletions), (1, 1));
    let texts: Vec<(LineKind, String)> = (0..diff.line_count())
        .filter_map(|i| diff.line(i))
        .filter(|l| l.kind != LineKind::Context && l.kind != LineKind::Hunk)
        .map(|l| (l.kind, String::from_utf8_lossy(l.text).into_owned()))
        .collect();
    assert_eq!(
        texts,
        [
            (LineKind::Removed, "line 20".to_owned()),
            (LineKind::Added, "line twenty".to_owned())
        ]
    );
}

#[test]
fn committing_a_move_commits_a_rename() {
    let repo = moved();
    let (mut rt, key) = open(&repo);
    wait_for(
        &mut rt,
        &key,
        &[("?", "notes.txt"), ("D", "gone.txt"), ("R", "lib/util.rs")],
    );
    rt.pick_all(&key, false);
    rt.pick_files(&key, &[PathBuf::from("lib/util.rs")], true);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).is_some_and(|s| s.can_commit(false)) && rt.pending_jobs() == 0
    });
    let job = rt.commit(&key, "Move util\n".to_owned(), false);
    succeed(&mut rt, &key, job);
    let names = repo.git(&["show", "-M", "--name-status", "--format=", "HEAD"]);
    assert!(
        names.starts_with("R0") || names.starts_with("R1"),
        "{names}"
    );
    assert!(names.contains("src/util.rs\tlib/util.rs"), "{names}");
    assert!(!names.contains("gone.txt"), "{names}");
    wait_for(&mut rt, &key, &[("?", "notes.txt"), ("D", "gone.txt")]);
}

#[test]
fn discarding_a_move_puts_the_file_back_and_undo_moves_it_again() {
    let repo = moved();
    let (mut rt, key) = open(&repo);
    wait_for(
        &mut rt,
        &key,
        &[("?", "notes.txt"), ("D", "gone.txt"), ("R", "lib/util.rs")],
    );
    let job = rt.discard_files(&key, vec![PathBuf::from("lib/util.rs")]);
    succeed(&mut rt, &key, job);
    assert!(!repo.path().join("lib/util.rs").exists());
    assert_eq!(
        fs::read_to_string(repo.path().join("src/util.rs")).expect("file operation"),
        lines(40)
    );
    wait_for(&mut rt, &key, &[("?", "notes.txt"), ("D", "gone.txt")]);

    let job = rt.undo_discard(&key);
    succeed(&mut rt, &key, job);
    assert!(
        !repo.path().join("src/util.rs").exists(),
        "undo removes the source again"
    );
    assert!(fs::read_to_string(repo.path().join("lib/util.rs"))
        .expect("file operation")
        .contains("line twenty"));
    wait_for(
        &mut rt,
        &key,
        &[("?", "notes.txt"), ("D", "gone.txt"), ("R", "lib/util.rs")],
    );
}

#[test]
fn shelving_a_move_takes_both_paths() {
    let repo = moved();
    let (mut rt, key) = open(&repo);
    wait_for(
        &mut rt,
        &key,
        &[("?", "notes.txt"), ("D", "gone.txt"), ("R", "lib/util.rs")],
    );
    let job = rt.shelve(&key, vec![PathBuf::from("lib/util.rs")], "move");
    succeed(&mut rt, &key, job);
    assert!(repo.path().join("src/util.rs").exists());
    assert!(!repo.path().join("lib/util.rs").exists());
    wait_for(&mut rt, &key, &[("?", "notes.txt"), ("D", "gone.txt")]);
}

fn begin_amend(rt: &mut Runtime, key: &Path) {
    let head = rt
        .repo(key)
        .and_then(|s| s.status())
        .and_then(|s| s.oid.clone())
        .expect("a commit");
    let job = rt.begin_amend(key, &head);
    succeed(rt, key, job);
    assert!(rt.repo(key).expect("open").is_amending());
}

fn amend_changes(rt: &Runtime, key: &Path) -> Vec<(String, String, Option<PathBuf>)> {
    let status = rt
        .repo(key)
        .and_then(|s| s.changes_status())
        .expect("amend changes");
    let mut out: Vec<_> = status
        .changes
        .iter()
        .map(|c| {
            (
                change_code(c).to_owned(),
                c.path.to_string_lossy().into_owned(),
                c.original_path.clone(),
            )
        })
        .collect();
    out.sort();
    out
}

/// Shows `path` and waits for its diff.
fn show(rt: &mut Runtime, key: &Path, path: &str) -> gitbello_core::diff::FileDiff {
    rt.select_change(key, Path::new(path), false);
    let wanted = PathBuf::from(path);
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .and_then(|s| s.diff())
            .is_some_and(|d| d.target().path == wanted && !d.is_loading() && d.diff().is_some())
    });
    rt.repo(key)
        .and_then(|s| s.diff())
        .and_then(|d| d.diff())
        .cloned()
        .expect("diff")
}

#[test]
fn amending_a_commit_that_moved_a_file_shows_the_rename() {
    let repo = TestRepo::init();
    repo.commit("src/util.rs", &lines(40), "base");
    fs::create_dir_all(repo.path().join("lib")).expect("file operation");
    repo.git(&["mv", "src/util.rs", "lib/util.rs"]);
    repo.git(&["commit", "-qm", "Move util"]);
    let (mut rt, key) = open(&repo);
    begin_amend(&mut rt, &key);
    assert_eq!(
        amend_changes(&rt, &key),
        [(
            "R".to_owned(),
            "lib/util.rs".to_owned(),
            Some(PathBuf::from("src/util.rs"))
        )]
    );
    let diff = show(&mut rt, &key, "lib/util.rs");
    assert_eq!(diff.header.change(), DiffChange::Renamed);
    assert_eq!((diff.additions, diff.deletions), (0, 0));
    // Amending as it is keeps the rename.
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).is_some_and(|s| s.can_commit(true)) && rt.pending_jobs() == 0
    });
    let job = rt.commit(&key, "Move util, reworded\n".to_owned(), true);
    succeed(&mut rt, &key, job);
    let names = repo.git(&["show", "-M", "--name-status", "--format=%s", "HEAD"]);
    assert_eq!(
        names,
        "Move util, reworded\n\nR100\tsrc/util.rs\tlib/util.rs"
    );
}

#[test]
fn a_move_made_while_amending_pairs_and_amends_as_a_rename() {
    let repo = TestRepo::init();
    repo.commit("src/util.rs", &lines(40), "base");
    repo.commit("other.txt", "other\n", "Add other");
    fs::remove_file(repo.path().join("src/util.rs")).expect("file operation");
    repo.write(
        "lib/util.rs",
        &lines(40).replace("line 20\n", "line twenty\n"),
    );
    let (mut rt, key) = open(&repo);
    begin_amend(&mut rt, &key);
    let listed = amend_changes(&rt, &key);
    assert!(
        listed.contains(&(
            "R".to_owned(),
            "lib/util.rs".to_owned(),
            Some(PathBuf::from("src/util.rs"))
        )),
        "{listed:?}"
    );
    assert!(
        !listed.iter().any(|(_, p, _)| p == "src/util.rs"),
        "{listed:?}"
    );
    let diff = show(&mut rt, &key, "lib/util.rs");
    assert_eq!(diff.header.change(), DiffChange::Renamed);
    assert_eq!((diff.additions, diff.deletions), (1, 1));
    rt.pick_files(&key, &[PathBuf::from("lib/util.rs")], true);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).is_some_and(|s| s.can_commit(true)) && rt.pending_jobs() == 0
    });
    let job = rt.commit(&key, "Add other, move util\n".to_owned(), true);
    succeed(&mut rt, &key, job);
    let names = repo.git(&["show", "-M", "--name-status", "--format=", "HEAD"]);
    assert!(names.contains("A\tother.txt"), "{names}");
    assert!(names.contains("src/util.rs\tlib/util.rs"), "{names}");
}

#[test]
fn a_move_without_edits_shows_its_whole_file_on_request() {
    use gitbello_core::runtime::DiffSlot;
    let repo = TestRepo::init();
    repo.commit("src/util.rs", &lines(40), "base");
    fs::create_dir_all(repo.path().join("lib")).expect("lib folder");
    repo.git(&["mv", "src/util.rs", "lib/util.rs"]);
    let (mut rt, key) = open(&repo);
    let diff = show(&mut rt, &key, "lib/util.rs");
    assert!(diff.is_empty(), "no edits");
    assert!(diff.header.old_oid.is_some(), "the old blob is found");
    let state = rt.repo(&key).and_then(|s| s.diff()).expect("diff state");
    assert!(state.layout().has_hidden(), "the file can be shown");
    assert_eq!(state.layout().row_count(false), 0);

    rt.show_whole_diff(&key, DiffSlot::Changes, true);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| d.layout().row_count(false) == 40)
    });
    rt.show_whole_diff(&key, DiffSlot::Changes, false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| d.layout().row_count(false) == 0)
    });
}
