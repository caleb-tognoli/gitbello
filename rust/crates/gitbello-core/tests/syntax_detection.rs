//! Syntax detection in the diff job (M7.13) on temporary repositories: a
//! script without an extension is found by its shebang when the diff does
//! not hold its first line, read from the working tree in Changes and from
//! the blob in History; a known extension needs no read, and a binary file
//! stays plain.

mod support;

use std::path::Path;

use gitbello_core::runtime::{Runtime, RuntimeEvent};
use support::rt::{open, poll_until};
use support::TestRepo;

/// A Python script of `lines` lines whose line `changed` reads `new`.
fn script(lines: usize, changed: usize, new: &str) -> String {
    let mut out = String::from("#!/usr/bin/env -S python3 -u\n");
    for i in 2..=lines {
        if i == changed {
            out.push_str(new);
        } else {
            out.push_str(&format!("value_{i} = {i}"));
        }
        out.push('\n');
    }
    out
}

fn changes_language(rt: &mut Runtime, key: &Path, file: &str) -> Option<&'static str> {
    rt.select_change(key, Path::new(file), false);
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .and_then(|s| s.diff())
            .is_some_and(|d| !d.is_loading() && d.diff().is_some())
    });
    let state = rt.repo(key).and_then(|s| s.diff()).expect("diff");
    state.syntax().language.map(|l| l.id())
}

#[test]
fn a_shebang_names_the_language_in_changes_and_history() {
    let repo = TestRepo::init();
    repo.commit("dossier é/run tool", &script(30, 0, ""), "add the tool");
    let changed = repo.commit(
        "dossier é/run tool",
        &script(30, 25, "value_25 = 'changed'"),
        "change line 25",
    );
    // Changes: an edit far from line 1, read from the working tree.
    repo.write("dossier é/run tool", &script(30, 20, "value_20 = None"));
    let (mut rt, key) = open(&repo);
    assert_eq!(
        changes_language(&mut rt, &key, "dossier é/run tool"),
        Some("python")
    );

    // History: the commit's diff holds lines 22..28 only; the blob is read.
    rt.load_commit(&key, &changed);
    poll_until(&mut rt, |_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::CommitLoaded { .. }))
    });
    rt.select_commit_file(&key, Some(Path::new("dossier é/run tool")), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.commit_diff())
            .is_some_and(|d| !d.is_loading() && d.diff().is_some())
    });
    let state = rt.repo(&key).and_then(|s| s.commit_diff()).expect("state");
    let diff = state.diff().expect("diff");
    assert!(diff
        .lines(0, diff.line_count())
        .all(|l| l.new_line != Some(1)));
    assert_eq!(state.syntax().language.map(|l| l.id()), Some("python"));
}

#[test]
fn names_extensions_and_plain_files() {
    let repo = TestRepo::init();
    repo.commit("main.rs", "fn main() {}\n", "rust");
    repo.commit("notes", "just text\n", "plain");
    repo.write("main.rs", "fn main() { run(); }\n");
    repo.write("notes", "#!not really\nmore text\n");
    let (mut rt, key) = open(&repo);
    assert_eq!(changes_language(&mut rt, &key, "main.rs"), Some("rust"));
    // "#!not really" names no known interpreter.
    assert_eq!(changes_language(&mut rt, &key, "notes"), None);
}
