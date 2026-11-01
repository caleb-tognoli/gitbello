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

fn begin_amend(rt: &mut Runtime, key: &Path) {
    let head = rt
        .repo(key)
        .expect("open repository")
        .status()
        .expect("loaded status")
        .oid
        .clone()
        .expect("existing commit");
    let job = rt.begin_amend(key, &head);
    succeed(rt, key, job);
    assert!(rt.repo(key).expect("open repository").is_amending());
}

#[test]
fn amend_session_reopens_original_changes_without_moving_head_or_index() {
    let repo = TestRepo::init();
    repo.commit("original.txt", "original\n", "base");
    repo.commit("original.txt", "changed\n", "last");
    let head = repo.head();
    let before = index(&repo);
    let (mut rt, key) = open(&repo);
    begin_amend(&mut rt, &key);
    assert_eq!(repo.head(), head);
    assert_eq!(index(&repo), before);
    assert_eq!(rt.repo(&key).unwrap().changes().len(), 1);
    let diff = show(&mut rt, &key, "original.txt");
    line(&diff, LineKind::Removed, "original");
    line(&diff, LineKind::Added, "changed");
    rt.pick_all(&key, false);
    commit(&mut rt, &key, "remove original changes", true);
    assert_eq!(committed(&repo, "original.txt"), "original");
    assert_eq!(
        fs::read_to_string(repo.path().join("original.txt")).unwrap(),
        "changed\n"
    );
    assert_eq!(repo.git(&["rev-list", "--count", "HEAD"]), "2");
}

#[test]
fn amend_session_preserves_excluded_overlapping_edits_and_cancel_selection() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base\n", "base");
    repo.commit("a.txt", "committed\n", "last");
    repo.write("a.txt", "working\n");
    repo.write("excluded.txt", "excluded\n");
    let (mut rt, key) = open(&repo);
    rt.pick_all(&key, false);
    let before = index(&repo);
    begin_amend(&mut rt, &key);
    show(&mut rt, &key, "a.txt");
    assert_eq!(pick(&rt, &key, "a.txt"), Some(FilePick::AsStaged));
    rt.cancel_amend(&key);
    assert_eq!(state(&rt, &key, "a.txt"), PickState::None);
    assert_eq!(state(&rt, &key, "excluded.txt"), PickState::None);
    assert_eq!(index(&repo), before);
    begin_amend(&mut rt, &key);
    commit(&mut rt, &key, "reword", true);
    assert_eq!(committed(&repo, "a.txt"), "committed");
    assert_eq!(
        fs::read_to_string(repo.path().join("a.txt")).unwrap(),
        "working\n"
    );
    assert!(!repo
        .git(&["ls-tree", "--name-only", "HEAD"])
        .contains("excluded.txt"));
}

#[test]
fn amend_session_can_exclude_original_lines_and_handle_root_additions() {
    let repo = TestRepo::init();
    repo.commit("a file è.txt", "one\ntwo\nthree\n", "root");
    let (mut rt, key) = open(&repo);
    begin_amend(&mut rt, &key);
    let diff = show(&mut rt, &key, "a file è.txt");
    assert!(rt.repo(&key).unwrap().can_pick_lines());
    rt.pick_lines(&key, &[line(&diff, LineKind::Added, "two")], false);
    commit(&mut rt, &key, "root edited", true);
    assert_eq!(committed(&repo, "a file è.txt"), "one\nthree");
    assert_eq!(repo.git(&["rev-list", "--count", "HEAD"]), "1");
    assert_eq!(
        fs::read_to_string(repo.path().join("a file è.txt")).unwrap(),
        "one\ntwo\nthree\n"
    );
}

#[test]
fn amend_session_includes_new_untracked_lines_and_refreshes_edits() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base\n", "base");
    repo.commit("a.txt", "last\n", "last");
    let (mut rt, key) = open(&repo);
    begin_amend(&mut rt, &key);
    repo.write("new.txt", "one\ntwo\n");
    repo.write("a.txt", "edited\n");
    settle(&mut rt, &key);
    let diff = show(&mut rt, &key, "a.txt");
    line(&diff, LineKind::Added, "edited");
    let diff = show(&mut rt, &key, "new.txt");
    assert!(rt.repo(&key).unwrap().can_pick_lines());
    rt.pick_files(&key, &paths(&["new.txt"]), true);
    rt.pick_lines(&key, &[line(&diff, LineKind::Added, "two")], false);
    commit(&mut rt, &key, "amended", true);
    assert_eq!(committed(&repo, "new.txt"), "one");
    assert_eq!(committed(&repo, "a.txt"), "edited");
}

#[test]
fn amend_session_preserves_partial_working_selection_and_unrelated_staging() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", "base");
    repo.commit("a.txt", "one\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", "last");
    repo.write("a.txt", "one\n2\n3\n4\n5\n6\n7\n8\n9\nten\n");
    repo.write("unrelated.txt", "staged\n");
    repo.git(&["add", "unrelated.txt"]);
    let (mut rt, key) = open(&repo);
    rt.pick_all(&key, false);
    let diff = show(&mut rt, &key, "a.txt");
    rt.pick_lines(
        &key,
        &[
            line(&diff, LineKind::Added, "ten"),
            line(&diff, LineKind::Removed, "10"),
        ],
        true,
    );
    begin_amend(&mut rt, &key);
    commit(&mut rt, &key, "amended", true);
    assert_eq!(
        committed(&repo, "a.txt"),
        "one\n2\n3\n4\n5\n6\n7\n8\n9\nten"
    );
    assert!(repo
        .git(&["diff", "--cached", "--name-only"])
        .contains("unrelated.txt"));
}

#[test]
fn amend_session_handles_renames_deletions_and_recreated_deleted_files() {
    let repo = TestRepo::init();
    repo.commit("old.txt", "content\n", "base");
    repo.commit("deleted.txt", "before\n", "more");
    repo.git(&["mv", "old.txt", "new.txt"]);
    repo.git(&["rm", "deleted.txt"]);
    repo.git(&["commit", "-m", "rename and delete"]);
    let (mut rt, key) = open(&repo);
    begin_amend(&mut rt, &key);
    show(&mut rt, &key, "old.txt");
    show(&mut rt, &key, "new.txt");
    repo.write("deleted.txt", "restored with edits\n");
    settle(&mut rt, &key);
    let diff = show(&mut rt, &key, "deleted.txt");
    line(&diff, LineKind::Added, "restored with edits");
    rt.pick_all(&key, true);
    commit(&mut rt, &key, "amended", true);
    assert_eq!(committed(&repo, "deleted.txt"), "restored with edits");
    assert_eq!(committed(&repo, "new.txt"), "content");
    assert!(!repo
        .git(&["ls-tree", "--name-only", "HEAD"])
        .contains("old.txt"));
}

#[test]
fn amend_session_keeps_merge_parents_and_author() {
    let repo = TestRepo::init();
    repo.commit("base.txt", "base\n", "base");
    repo.git(&["checkout", "-b", "topic"]);
    repo.commit("topic.txt", "topic\n", "topic");
    repo.git(&["checkout", "main"]);
    repo.commit("main.txt", "main\n", "main");
    repo.git(&["merge", "--no-ff", "--no-edit", "topic"]);
    let parents = repo.git(&["show", "-s", "--format=%P", "HEAD"]);
    let author = repo.git(&["show", "-s", "--format=%an <%ae> %at", "HEAD"]);
    let (mut rt, key) = open(&repo);
    begin_amend(&mut rt, &key);
    commit(&mut rt, &key, "amended merge", true);
    assert_eq!(repo.git(&["show", "-s", "--format=%P", "HEAD"]), parents);
    assert_eq!(
        repo.git(&["show", "-s", "--format=%an <%ae> %at", "HEAD"]),
        author
    );
    assert_eq!(committed(&repo, "topic.txt"), "topic");
}

#[test]
fn amend_session_rejects_stale_head_and_preserves_failed_hook_state() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base\n", "base");
    repo.commit("a.txt", "last\n", "last");
    let (mut rt, key) = open(&repo);
    begin_amend(&mut rt, &key);
    let before = index(&repo);
    let head = repo.head();
    hook(&repo, "pre-commit", "echo rejected >&2\nexit 1");
    let job = rt.commit(&key, "blocked\n".into(), true);
    assert!(finish(&mut rt, &key, job).is_some());
    assert_eq!(index(&repo), before);
    assert_eq!(repo.head(), head);
    assert!(rt.repo(&key).unwrap().is_amending());
    fs::remove_file(repo.path().join(".git/hooks/pre-commit")).unwrap();

    repo.git(&["checkout", "--detach", "HEAD"]);
    settle(&mut rt, &key);
    assert!(!rt.repo(&key).unwrap().is_amending());
    repo.git(&["checkout", "main"]);
    settle(&mut rt, &key);
    begin_amend(&mut rt, &key);
    repo.git(&["checkout", "--detach", "HEAD"]);
    let job = rt.commit(&key, "detached\n".into(), true);
    assert_eq!(
        finish(&mut rt, &key, job).unwrap().kind,
        GitErrorKind::Stale
    );
    settle(&mut rt, &key);
    repo.git(&["checkout", "main"]);
    settle(&mut rt, &key);
    begin_amend(&mut rt, &key);

    repo.git(&["commit", "--allow-empty", "-m", "outside"]);
    let job = rt.commit(&key, "stale\n".into(), true);
    assert_eq!(
        finish(&mut rt, &key, job).unwrap().kind,
        GitErrorKind::Stale
    );
    settle(&mut rt, &key);
    assert!(!rt.repo(&key).unwrap().is_amending());
    assert_eq!(repo.git(&["show", "-s", "--format=%s", "HEAD"]), "outside");
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
