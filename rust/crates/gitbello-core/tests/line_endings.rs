//! Line endings in diffs (M7.9) on temporary repositories: a converted
//! file's marker rows and summary in Changes and in a commit, none of it
//! where `.gitattributes` normalizes endings, Restore line endings with its
//! undo, and the scan that finds the files whose only changes are endings.

use crate::support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::changes::ChangeFilter;
use gitbello_core::diff::eol::{Endings, Marker};
use gitbello_core::diff::{FileDiff, LayoutRow};
use gitbello_core::runtime::{Runtime, RuntimeEvent};
use support::rt::{open, poll_until, succeed};
use support::TestRepo;

fn bytes(repo: &TestRepo, file: &str) -> Vec<u8> {
    fs::read(repo.path().join(file)).expect("read")
}

fn paths(list: &[&str]) -> Vec<PathBuf> {
    list.iter().map(PathBuf::from).collect()
}

/// Selects `file` in Changes and waits for its diff.
fn changes_diff(rt: &mut Runtime, key: &Path, file: &str) -> FileDiff {
    rt.select_change(key, Path::new(file), false);
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .and_then(|s| s.diff())
            .is_some_and(|d| !d.is_loading() && d.diff().is_some())
    });
    rt.repo(key)
        .and_then(|s| s.diff())
        .and_then(|d| d.diff())
        .cloned()
        .expect("the diff")
}

#[test]
fn a_converted_file_shows_only_its_endings_changed() {
    let repo = TestRepo::init();
    repo.commit("crlf.txt", "a\r\nb\r\nc\r\n", "base");
    repo.write("crlf.txt", "a\nb\nc\n");
    let (mut rt, key) = open(&repo);
    let diff = changes_diff(&mut rt, &key, "crlf.txt");
    let summary = diff.endings();
    assert_eq!(summary.changed, Some((Endings::Crlf, Endings::Lf)));
    assert_eq!(summary.lines, 3);
    assert!(summary.only);
    // One row after the last line, in the layout the view shows.
    let layout = rt
        .repo(&key)
        .and_then(|s| s.diff())
        .expect("state")
        .layout()
        .clone();
    let markers: Vec<LayoutRow> = layout
        .rows(false, 0, usize::MAX)
        .filter(|r| matches!(r, LayoutRow::Marker(_)))
        .collect();
    assert_eq!(
        markers,
        [LayoutRow::Marker(Marker::LineEndings {
            from: Endings::Crlf,
            to: Endings::Lf,
            lines: 3
        })]
    );
}

#[test]
fn a_commit_that_converts_a_file_and_drops_its_final_newline() {
    let repo = TestRepo::init();
    repo.commit("notes.txt", "one\ntwo\n", "base");
    let converted = repo.commit("notes.txt", "one\r\ntwo", "convert");
    let (mut rt, key) = open(&repo);
    rt.load_commit(&key, &converted);
    poll_until(&mut rt, |_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::CommitLoaded { .. }))
    });
    rt.select_commit_file(&key, Some(Path::new("notes.txt")), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.commit_diff())
            .is_some_and(|d| !d.is_loading() && d.diff().is_some())
    });
    let state = rt.repo(&key).and_then(|s| s.commit_diff()).expect("state");
    let summary = state.diff().expect("diff").endings();
    // The last line lost its newline, so only "one" counts as converted.
    assert_eq!(summary.changed, Some((Endings::Lf, Endings::Crlf)));
    assert_eq!(summary.lines, 1);
    assert_eq!(summary.final_newline.map(|f| f.id()), Some("removed"));
    assert!(summary.only);
}

#[test]
fn normalized_endings_show_no_markers() {
    let repo = TestRepo::init();
    repo.write(".gitattributes", "* text=auto\n");
    repo.commit("f.txt", "a\nb\n", "base");
    // git converts CRLF to LF before comparing: only b → B shows.
    repo.write("f.txt", "a\r\nB\r\n");
    let (mut rt, key) = open(&repo);
    let diff = changes_diff(&mut rt, &key, "f.txt");
    assert_eq!((diff.additions, diff.deletions), (1, 1));
    assert!(diff.markers().is_empty());
    assert_eq!(diff.endings().changed, None);
    assert!(!diff.endings().only);
}

#[test]
fn restoring_line_endings_keeps_the_text_and_can_be_undone() {
    let repo = TestRepo::init();
    repo.commit("crlf.txt", "a\r\nb\r\nc\r\n", "base");
    repo.commit("edit.txt", "x\ny\n", "edit");
    repo.commit("dossier é/notes ü.txt", "1\r\n2\r\n", "unicode");
    repo.write("crlf.txt", "a\nb\nc\n");
    repo.write("edit.txt", "x\r\nY\r\n");
    repo.write("dossier é/notes ü.txt", "1\n2");
    repo.write("new.txt", "n\r\n");
    let (mut rt, key) = open(&repo);
    let files = ["crlf.txt", "edit.txt", "dossier é/notes ü.txt", "new.txt"];
    let job = rt.restore_line_endings(&key, paths(&files));
    succeed(&mut rt, &key, job);
    assert_eq!(bytes(&repo, "crlf.txt"), b"a\r\nb\r\nc\r\n");
    assert_eq!(bytes(&repo, "edit.txt"), b"x\nY\n", "Y stays");
    assert_eq!(bytes(&repo, "dossier é/notes ü.txt"), b"1\r\n2\r\n");
    assert_eq!(
        bytes(&repo, "new.txt"),
        b"n\r\n",
        "untracked files are left alone"
    );
    assert_eq!(
        repo.git(&["status", "--porcelain"]),
        "M edit.txt\n?? new.txt"
    );

    let job = rt.undo_discard(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(bytes(&repo, "crlf.txt"), b"a\nb\nc\n");
    assert_eq!(bytes(&repo, "edit.txt"), b"x\r\nY\r\n");
    assert_eq!(bytes(&repo, "dossier é/notes ü.txt"), b"1\n2");
}

#[test]
fn nothing_to_restore_starts_no_job_and_staged_changes_stay() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "a\r\n", "base");
    repo.write("f.txt", "a\n");
    repo.git(&["add", "f.txt"]);
    let (rt, key) = open(&repo);
    // Staged only: the working copy matches the index.
    assert_eq!(rt.restore_line_endings(&key, paths(&["f.txt"])), None);
    assert_eq!(bytes(&repo, "f.txt"), b"a\n");
}

#[test]
fn the_scan_finds_the_files_whose_only_changes_are_endings() {
    let repo = TestRepo::init();
    repo.commit("crlf.txt", "a\r\nb\r\n", "base");
    repo.commit("nonl.txt", "one\ntwo", "nonl");
    repo.commit("both.txt", "p\r\nq", "both");
    repo.commit("real.txt", "r\ns\n", "real");
    repo.write("crlf.txt", "a\nb\n");
    repo.write("nonl.txt", "one\ntwo\n");
    repo.write("both.txt", "p\nq\n");
    repo.write("real.txt", "r\r\nS\r\n");
    let (mut rt, key) = open(&repo);
    let wanted = ["both.txt", "crlf.txt", "nonl.txt"];
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .is_some_and(|s| wanted.iter().all(|p| s.is_endings_only(Path::new(p))))
    });
    let state = rt.repo(&key).expect("state");
    assert!(!state.is_endings_only(Path::new("real.txt")));
    assert!(state.can_restore_endings(&paths(&["crlf.txt"])));
    assert!(
        !state.can_restore_endings(&paths(&["real.txt"])),
        "not shown, not endings only"
    );

    let filter = ChangeFilter {
        endings_only: true,
        ..ChangeFilter::default()
    };
    rt.set_change_filter(&key, filter);
    let state = rt.repo(&key).expect("state");
    let status = state.status().expect("status");
    let shown: Vec<String> = state
        .changes()
        .indices()
        .iter()
        .map(|&i| status.changes[i].path.to_string_lossy().into_owned())
        .collect();
    assert_eq!(shown, wanted);

    // Restoring them all leaves no changes.
    let job = rt.restore_line_endings(&key, paths(&wanted));
    succeed(&mut rt, &key, job);
    assert_eq!(repo.git(&["status", "--porcelain"]), "M real.txt");
}
