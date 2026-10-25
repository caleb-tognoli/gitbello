//! The commit selection (M6.5 P3 acceptance, PLAN §3.10): seeding from the
//! index, partly included files, renames, deletions, untracked files, amend,
//! hooks and discards, through the runtime on real temporary repositories.

mod support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::changes::{FilePick, PickState};
use gitbello_core::diff::{FileDiff, LineKind};
use gitbello_core::git::GitErrorKind;
use gitbello_core::runtime::Runtime;
use support::rt::{finish, open, poll_until, settle, succeed};
use support::TestRepo;

fn paths(list: &[&str]) -> Vec<PathBuf> {
    list.iter().map(PathBuf::from).collect()
}

fn state(rt: &Runtime, key: &Path, path: &str) -> PickState {
    rt.repo(key)
        .expect("open")
        .selection()
        .state(Path::new(path))
}

fn pick(rt: &Runtime, key: &Path, path: &str) -> Option<FilePick> {
    rt.repo(key)?.selection().pick(Path::new(path)).cloned()
}

/// Selects `path` in the Changes view and waits for its diff.
fn show(rt: &mut Runtime, key: &Path, path: &str) -> FileDiff {
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

fn line(diff: &FileDiff, kind: LineKind, text: &str) -> usize {
    (0..diff.line_count())
        .find(|&i| {
            diff.line(i)
                .is_some_and(|l| l.kind == kind && l.text == text.as_bytes())
        })
        .unwrap_or_else(|| panic!("no {kind:?} line {text:?}"))
}

fn commit(rt: &mut Runtime, key: &Path, message: &str, amend: bool) {
    let job = rt.commit(key, format!("{message}\n"), amend);
    succeed(rt, key, job);
}

/// `git ls-files -s` of the real index.
fn index(repo: &TestRepo) -> String {
    repo.git(&["ls-files", "-s"])
}

fn committed(repo: &TestRepo, path: &str) -> String {
    repo.git(&["show", &format!("HEAD:{path}")])
}

fn hook(repo: &TestRepo, name: &str, script: &str) {
    let hooks = repo.path().join(".git/hooks");
    fs::create_dir_all(&hooks).expect("hooks dir");
    fs::write(hooks.join(name), format!("#!/bin/sh\n{script}\n")).expect("hook");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(hooks.join(name), fs::Permissions::from_mode(0o755)).expect("chmod");
    }
}

#[test]
fn seeds_from_the_index_and_reseeds_after_outside_staging() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.commit("b.txt", "b\n", "more");
    repo.write("a.txt", "a2\n");
    repo.write("b.txt", "b2\n");
    repo.write("c.txt", "c\n");
    repo.git(&["add", "a.txt"]);
    let (mut rt, key) = open(&repo);
    // Something staged: exactly that is picked.
    assert_eq!(state(&rt, &key, "a.txt"), PickState::All);
    assert_eq!(state(&rt, &key, "b.txt"), PickState::None);
    assert_eq!(state(&rt, &key, "c.txt"), PickState::None);

    // Staged outside gitbello meanwhile: b.txt joins, nothing is dropped.
    repo.git(&["add", "b.txt"]);
    settle(&mut rt, &key);
    assert_eq!(state(&rt, &key, "b.txt"), PickState::All);
    assert_eq!(state(&rt, &key, "c.txt"), PickState::None);

    // A file appearing later starts picked.
    repo.write("d.txt", "d\n");
    settle(&mut rt, &key);
    assert_eq!(state(&rt, &key, "d.txt"), PickState::All);

    commit(&mut rt, &key, "Picked", false);
    assert_eq!(
        repo.git(&["show", "--name-only", "--format=", "HEAD"]),
        "a.txt\nb.txt\nd.txt"
    );
    assert_eq!(repo.git(&["status", "--porcelain"]), "?? c.txt");
}

#[test]
fn nothing_staged_picks_everything() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.write("a.txt", "a2\n");
    repo.write("new ünï.txt", "n\n");
    let (rt, key) = open(&repo);
    assert_eq!(rt.repo(&key).unwrap().selection().picked_count(), 2);
}

#[test]
fn commits_part_of_a_file_and_keeps_the_rest() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", "base");
    repo.write("f.txt", "1\ntwo\n3\n4\n5\n6\n7\n8\n9\nten\n");
    let (mut rt, key) = open(&repo);
    let diff = show(&mut rt, &key, "f.txt");
    assert!(rt.repo(&key).unwrap().can_pick_lines());
    // Leave out the second change (`10` → `ten`).
    let lines = [
        line(&diff, LineKind::Removed, "10"),
        line(&diff, LineKind::Added, "ten"),
    ];
    assert!(rt.pick_lines(&key, &lines, false));
    assert_eq!(state(&rt, &key, "f.txt"), PickState::Partial);
    let picks = rt.repo(&key).unwrap().diff_picks().to_vec();
    assert_eq!(picks[line(&diff, LineKind::Added, "two")], PickState::All);
    assert_eq!(picks[line(&diff, LineKind::Added, "ten")], PickState::None);

    // Editing elsewhere in the file keeps the picks.
    repo.write("f.txt", "0\n1\ntwo\n3\n4\n5\n6\n7\n8\n9\nten\n");
    settle(&mut rt, &key);
    show(&mut rt, &key, "f.txt");
    assert_eq!(state(&rt, &key, "f.txt"), PickState::Partial);

    // A line added to a partly included file starts left out.
    let diff = show(&mut rt, &key, "f.txt");
    let picks = rt.repo(&key).unwrap().diff_picks().to_vec();
    assert_eq!(picks[line(&diff, LineKind::Added, "0")], PickState::None);
    commit(&mut rt, &key, "Two", false);
    assert_eq!(committed(&repo, "f.txt"), "1\ntwo\n3\n4\n5\n6\n7\n8\n9\n10");
    assert_eq!(
        fs::read_to_string(repo.path().join("f.txt")).unwrap(),
        "0\n1\ntwo\n3\n4\n5\n6\n7\n8\n9\nten\n"
    );
    // The real index follows the commit; the rest stays a change, picked.
    assert_eq!(repo.git(&["diff", "--cached", "--name-only"]), "");
    assert_eq!(repo.git(&["status", "--porcelain"]), "M f.txt");
    assert_eq!(state(&rt, &key, "f.txt"), PickState::All);
}

#[test]
fn renames_deletions_and_untracked_files() {
    let repo = TestRepo::init();
    repo.commit("old name.txt", "same\ncontent\nhere\n", "base");
    repo.commit("gone.txt", "bye\n", "more");
    repo.git(&["mv", "old name.txt", "new name.txt"]);
    fs::remove_file(repo.path().join("gone.txt")).unwrap();
    repo.write("fresh.txt", "a\nb\nc\n");
    let (mut rt, key) = open(&repo);
    // The rename is staged, so only it is picked; add the rest.
    assert_eq!(state(&rt, &key, "new name.txt"), PickState::All);
    rt.pick_files(&key, &paths(&["gone.txt"]), true);

    // Part of an untracked file: only its first line.
    let diff = show(&mut rt, &key, "fresh.txt");
    rt.pick_files(&key, &paths(&["fresh.txt"]), true);
    rt.pick_lines(
        &key,
        &[
            line(&diff, LineKind::Added, "b"),
            line(&diff, LineKind::Added, "c"),
        ],
        false,
    );
    assert_eq!(state(&rt, &key, "fresh.txt"), PickState::Partial);

    commit(&mut rt, &key, "Move, delete, add", false);
    let names = repo.git(&["show", "-M", "--name-status", "--format=", "HEAD"]);
    assert!(
        names.contains("R100\told name.txt\tnew name.txt"),
        "{names}"
    );
    assert!(names.contains("D\tgone.txt"), "{names}");
    assert!(names.contains("A\tfresh.txt"), "{names}");
    assert_eq!(committed(&repo, "fresh.txt"), "a");
    assert_eq!(repo.git(&["status", "--porcelain"]), "M fresh.txt");
}

#[test]
fn files_staged_in_part_outside_are_committed_as_staged() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "a\nb\nc\n", "base");
    repo.write("f.txt", "a\nB\nc\n");
    repo.git(&["add", "f.txt"]);
    repo.write("f.txt", "a\nZ\nc\n");
    let (mut rt, key) = open(&repo);
    assert_eq!(pick(&rt, &key, "f.txt"), Some(FilePick::AsStaged));
    // The staged `B` is not in the working tree: it stays as staged.
    show(&mut rt, &key, "f.txt");
    assert_eq!(pick(&rt, &key, "f.txt"), Some(FilePick::AsStaged));
    assert!(rt.repo(&key).unwrap().diff_as_staged());

    commit(&mut rt, &key, "As staged", false);
    assert_eq!(committed(&repo, "f.txt"), "a\nB\nc");
    assert_eq!(
        fs::read_to_string(repo.path().join("f.txt")).unwrap(),
        "a\nZ\nc\n"
    );
}

#[test]
fn files_staged_in_part_resolve_to_line_picks() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", "base");
    repo.write("f.txt", "1\ntwo\n3\n4\n5\n6\n7\n8\n9\n10\n");
    repo.git(&["add", "f.txt"]);
    repo.write("f.txt", "1\ntwo\n3\n4\n5\n6\n7\n8\n9\nten\n");
    let (mut rt, key) = open(&repo);
    let diff = show(&mut rt, &key, "f.txt");
    assert!(matches!(pick(&rt, &key, "f.txt"), Some(FilePick::Lines(_))));
    let picks = rt.repo(&key).unwrap().diff_picks().to_vec();
    assert_eq!(picks[line(&diff, LineKind::Added, "two")], PickState::All);
    assert_eq!(picks[line(&diff, LineKind::Added, "ten")], PickState::None);
}

#[test]
fn files_staged_elsewhere_but_left_out_keep_their_staging() {
    let repo = TestRepo::init();
    repo.commit("x.txt", "x\n", "base");
    repo.commit("y.txt", "y\n", "more");
    repo.write("x.txt", "staged x\n");
    repo.git(&["add", "x.txt"]);
    repo.write("x.txt", "edited again\n");
    repo.write("y.txt", "y2\n");
    let (mut rt, key) = open(&repo);
    rt.pick_files(&key, &paths(&["x.txt"]), false);
    rt.pick_files(&key, &paths(&["y.txt"]), true);
    commit(&mut rt, &key, "Only y", false);
    assert_eq!(
        repo.git(&["show", "--name-only", "--format=", "HEAD"]),
        "y.txt"
    );
    assert_eq!(repo.git(&["show", ":x.txt"]), "staged x");
}

#[test]
fn amend_with_and_without_new_picks() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.write("a.txt", "a2\n");
    repo.write("b.txt", "b\n");
    let (mut rt, key) = open(&repo);
    rt.pick_files(&key, &paths(&["b.txt"]), false);
    commit(&mut rt, &key, "Change a", false);
    assert_eq!(repo.git(&["rev-list", "--count", "HEAD"]), "2");

    // Nothing picked: amending only rewords.
    rt.pick_all(&key, false);
    assert!(rt.repo(&key).unwrap().can_commit(true));
    commit(&mut rt, &key, "Change a, reworded", true);
    assert_eq!(repo.git(&["rev-list", "--count", "HEAD"]), "2");
    assert_eq!(
        repo.git(&["show", "--name-only", "--format=%s", "HEAD"]),
        "Change a, reworded\n\na.txt"
    );

    rt.pick_files(&key, &paths(&["b.txt"]), true);
    commit(&mut rt, &key, "Change a and add b", true);
    assert_eq!(repo.git(&["rev-list", "--count", "HEAD"]), "2");
    assert_eq!(
        repo.git(&["show", "--name-only", "--format=", "HEAD"]),
        "a.txt\nb.txt"
    );
}

#[test]
fn a_failing_hook_leaves_the_index_alone() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.write("a.txt", "a2\n");
    repo.git(&["add", "a.txt"]);
    repo.write("a.txt", "a3\n");
    repo.write("b.txt", "b\n");
    let before = index(&repo);
    let head = repo.head();
    hook(&repo, "pre-commit", "echo 'lint failed' >&2\nexit 1");
    let (mut rt, key) = open(&repo);
    rt.pick_all(&key, true);
    let job = rt.commit(&key, "Blocked\n".into(), false);
    let err = finish(&mut rt, &key, job).expect("the hook rejects it");
    assert!(err.stderr.contains("lint failed"), "{err:?}");
    assert_eq!(index(&repo), before);
    assert_eq!(repo.head(), head);
    assert!(!repo.path().join(".git/gitbello-commit-index").exists());
}

#[test]
fn hooks_that_stage_their_fixes_commit_them() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.write("a.txt", "messy\n");
    // A formatter hook: rewrites the file and stages it (into the index git
    // gives the hook, the temporary one).
    hook(&repo, "pre-commit", "echo tidy > a.txt\ngit add a.txt");
    let (mut rt, key) = open(&repo);
    commit(&mut rt, &key, "Formatted", false);
    assert_eq!(committed(&repo, "a.txt"), "tidy");
    assert_eq!(repo.git(&["status", "--porcelain"]), "");
}

#[test]
fn stale_picks_fail_before_writing() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", "base");
    repo.write("f.txt", "1\ntwo\n3\n4\n5\n6\n7\n8\n9\nten\n");
    let (mut rt, key) = open(&repo);
    let diff = show(&mut rt, &key, "f.txt");
    rt.pick_lines(&key, &[line(&diff, LineKind::Added, "ten")], false);
    let head = repo.head();
    // The picked `two` changes before the commit job reads the file.
    repo.write("f.txt", "1\nTWO\n3\n4\n5\n6\n7\n8\n9\nten\n");
    let job = rt.commit(&key, "Stale\n".into(), false);
    let err = finish(&mut rt, &key, job).expect("stale picks fail");
    assert_eq!(err.kind, GitErrorKind::Stale);
    assert_eq!(repo.head(), head);
}

#[test]
fn discard_restores_head_and_undo_brings_files_back() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.commit("old.txt", "o\n", "more");
    repo.write("a.txt", "staged\n");
    repo.git(&["add", "a.txt"]);
    repo.write("a.txt", "edited\n");
    repo.git(&["mv", "old.txt", "new.txt"]);
    repo.write("junk.txt", "j\n");
    let (mut rt, key) = open(&repo);
    let job = rt.discard_files(&key, paths(&["a.txt", "new.txt", "junk.txt"]));
    succeed(&mut rt, &key, job);
    assert_eq!(repo.git(&["status", "--porcelain"]), "");
    assert_eq!(
        fs::read_to_string(repo.path().join("a.txt")).unwrap(),
        "a\n"
    );
    assert!(repo.path().join("old.txt").exists());
    assert!(!repo.path().join("junk.txt").exists());

    let job = rt.undo_discard(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(
        fs::read_to_string(repo.path().join("a.txt")).unwrap(),
        "edited\n"
    );
    assert_eq!(
        fs::read_to_string(repo.path().join("junk.txt")).unwrap(),
        "j\n"
    );
}

#[test]
fn discarding_lines_against_head() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", "base");
    repo.write("f.txt", "1\ntwo\n3\n4\n5\n6\n7\n8\n9\nten\n");
    repo.git(&["add", "f.txt"]);
    let (mut rt, key) = open(&repo);
    let diff = show(&mut rt, &key, "f.txt");
    let lines = [
        line(&diff, LineKind::Removed, "10"),
        line(&diff, LineKind::Added, "ten"),
    ];
    let job = rt.apply_lines(&key, &lines, gitbello_core::diff::PatchMode::Discard);
    succeed(&mut rt, &key, job);
    assert_eq!(
        fs::read_to_string(repo.path().join("f.txt")).unwrap(),
        "1\ntwo\n3\n4\n5\n6\n7\n8\n9\n10\n"
    );
}

#[test]
fn first_commit_of_an_unborn_branch() {
    let repo = TestRepo::init();
    repo.write("a.txt", "1\n2\n3\n");
    repo.write("b.txt", "b\n");
    let (mut rt, key) = open(&repo);
    let diff = show(&mut rt, &key, "a.txt");
    rt.pick_lines(&key, &[line(&diff, LineKind::Added, "3")], false);
    commit(&mut rt, &key, "First", false);
    assert_eq!(committed(&repo, "a.txt"), "1\n2");
    assert_eq!(committed(&repo, "b.txt"), "b");
    assert_eq!(repo.git(&["status", "--porcelain"]), "M a.txt");
}
