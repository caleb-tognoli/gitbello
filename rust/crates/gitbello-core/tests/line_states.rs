//! Line states (M7.13 P5a) on temporary repositories: after a diff loads,
//! a job finds the state each line of both sides starts in, so a line
//! inside a block comment opened above its hunk is coloured as a comment
//! in the working copy, staged and commit diffs; the states follow an edit
//! of the working file; in the resolver, theirs goes on from the state
//! before the block and the lines after it from the end of ours.

mod support;

use std::path::Path;

use gitbello_core::diff::{DiffKind, DiffTarget, LineKind};
use gitbello_core::highlight::{StatesStatus, TokenKind};
use gitbello_core::jobs::{RefreshKind, RefreshSet};
use gitbello_core::runtime::{DiffState, Runtime, RuntimeEvent};
use support::rt::{open, poll_until};
use support::TestRepo;

/// A Rust file of 50 lines with a block comment from line 2 to `close`;
/// line `changed` (when not 0) reads `text`.
fn source(close: usize, changed: usize, text: &str) -> String {
    let mut out = String::new();
    for i in 1..=50 {
        let line = if i == changed {
            text.to_owned()
        } else if i == 2 {
            "/* a comment that goes on".to_owned()
        } else if i == close {
            "   until here */".to_owned()
        } else if i < close {
            format!("   inside {i}")
        } else {
            format!("let value_{i} = {i};")
        };
        out.push_str(&line);
        out.push('\n');
    }
    out
}

/// The kinds of the tokens of the diff line on `side` at line `number`,
/// lexed from the state the diff found for it.
fn kinds(state: &DiffState, removed: bool, number: u32) -> Vec<TokenKind> {
    let diff = state.diff().expect("diff");
    let line = diff
        .lines(0, diff.line_count())
        .find(|l| {
            let at = if removed { l.old_line } else { l.new_line };
            at == Some(number) && (l.kind == LineKind::Removed) == removed
        })
        .unwrap_or_else(|| panic!("no line {number} (removed: {removed})"));
    let before = state.state_before(removed, line.old_line, line.new_line);
    state
        .syntax()
        .highlight_line_from(line.text, before)
        .iter()
        .map(|t| t.kind)
        .collect()
}

/// Waits until the Changes diff loaded with its states found, and its text
/// holds `text`.
fn changes_ready(rt: &mut Runtime, key: &Path, text: &str) {
    poll_until(rt, |rt, _| {
        rt.repo(key).and_then(|s| s.diff()).is_some_and(|d| {
            d.states_status() == StatesStatus::Ready
                && d.diff().is_some_and(|f| {
                    f.lines(0, f.line_count())
                        .any(|l| String::from_utf8_lossy(l.text).contains(text))
                })
        })
    });
}

#[test]
fn a_comment_opened_above_the_hunk_colours_its_lines() {
    let repo = TestRepo::init();
    repo.commit("dossier é/lib.rs", &source(40, 0, ""), "add");
    repo.write("dossier é/lib.rs", &source(40, 30, "   edited 30"));
    let (mut rt, key) = open(&repo);
    rt.select_change(&key, Path::new("dossier é/lib.rs"), false);
    changes_ready(&mut rt, &key, "edited 30");
    let state = rt.repo(&key).and_then(|s| s.diff()).expect("diff");
    assert_eq!(state.target().kind, DiffKind::Head);
    // Both sides of line 30 are inside the comment.
    assert_eq!(kinds(state, false, 30), [TokenKind::Comment]);
    assert_eq!(kinds(state, true, 30), [TokenKind::Comment]);
    // So is a context line below it.
    assert_eq!(kinds(state, false, 33), [TokenKind::Comment]);
    // Alone, the line is not a comment.
    assert!(!state
        .syntax()
        .highlight_line(b"   edited 30")
        .iter()
        .any(|t| t.kind == TokenKind::Comment));

    // The comment now closes at line 25: line 30 is code.
    repo.write(
        "dossier é/lib.rs",
        &source(25, 30, "let edited = \"thirty\";"),
    );
    rt.refresh(&key, RefreshSet::EMPTY.with(RefreshKind::Status));
    changes_ready(&mut rt, &key, "thirty");
    let state = rt.repo(&key).and_then(|s| s.diff()).expect("diff");
    let added = kinds(state, false, 30);
    assert!(added.contains(&TokenKind::Keyword), "{added:?}");
    assert!(added.contains(&TokenKind::String), "{added:?}");
    // The old side still has its comment there.
    assert_eq!(kinds(state, true, 30), [TokenKind::Comment]);
}

#[test]
fn staged_and_commit_diffs_read_their_blobs() {
    let repo = TestRepo::init();
    repo.commit("lib.rs", &source(40, 0, ""), "add");
    repo.write("lib.rs", &source(40, 30, "   staged 30"));
    repo.git(&["add", "lib.rs"]);
    // The working copy differs again, so the staged side is the index blob.
    repo.write("lib.rs", &source(10, 30, "let working = 30;"));
    let (mut rt, key) = open(&repo);
    rt.select_diff(
        &key,
        Some(DiffTarget {
            kind: DiffKind::Staged,
            path: "lib.rs".into(),
            original_path: None,
            commit: None,
        }),
        false,
    );
    changes_ready(&mut rt, &key, "staged 30");
    let state = rt.repo(&key).and_then(|s| s.diff()).expect("diff");
    assert_eq!(kinds(state, false, 30), [TokenKind::Comment]);

    repo.git(&["commit", "--quiet", "-m", "stage"]);
    let oid = repo.head();
    rt.load_commit(&key, &oid);
    poll_until(&mut rt, |_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::CommitLoaded { .. }))
    });
    rt.select_commit_file(&key, Some(Path::new("lib.rs")), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.commit_diff())
            .is_some_and(|d| d.states_status() == StatesStatus::Ready)
    });
    let state = rt.repo(&key).and_then(|s| s.commit_diff()).expect("diff");
    assert!(state.line_states().old.is_some() && state.line_states().new.is_some());
    assert_eq!(kinds(state, false, 30), [TokenKind::Comment]);
    assert_eq!(kinds(state, true, 30), [TokenKind::Comment]);
}

#[test]
fn new_files_and_plain_text() {
    let repo = TestRepo::init();
    repo.commit("README", "readme\n", "add");
    repo.write("new.rs", &source(5, 0, ""));
    repo.write("notes.txt", "/* not code\nstill not\n");
    let (mut rt, key) = open(&repo);
    rt.select_change(&key, Path::new("new.rs"), false);
    changes_ready(&mut rt, &key, "inside 3");
    let state = rt.repo(&key).and_then(|s| s.diff()).expect("diff");
    assert!(state.line_states().old.is_none());
    assert_eq!(kinds(state, false, 3), [TokenKind::Comment]);

    rt.select_change(&key, Path::new("notes.txt"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| d.target().path == Path::new("notes.txt") && d.diff().is_some())
    });
    let state = rt.repo(&key).and_then(|s| s.diff()).expect("diff");
    assert_eq!(state.states_status(), StatesStatus::None);
    assert!(state.line_states().is_empty());
}

#[test]
fn the_resolver_goes_on_from_ours() {
    let repo = TestRepo::init();
    repo.commit("c.rs", "fn a() {}\nlet base = 0;\nfn b() {}\n", "base");
    repo.branch("conflict");
    repo.commit("c.rs", "fn a() {}\n/* ours opens\nfn b() {}\n", "ours");
    repo.checkout("conflict");
    repo.commit("c.rs", "fn a() {}\nlet theirs = 1;\nfn b() {}\n", "theirs");
    repo.checkout("main");
    repo.try_git(&["merge", "--no-edit", "conflict"])
        .expect_err("merge should conflict");
    let (mut rt, key) = open(&repo);
    rt.select_change(&key, Path::new("c.rs"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.conflict())
            .is_some_and(|c| c.states_status() == StatesStatus::Ready)
    });
    let conflict = rt.repo(&key).and_then(|s| s.conflict()).expect("conflict");
    let file = conflict.file().expect("file");
    let at = |text: &str| {
        (0..file.line_count())
            .find(|&i| file.line(i) == Some(text.as_bytes()))
            .unwrap_or_else(|| panic!("no line {text}"))
    };
    let colour = |text: &str| -> Vec<TokenKind> {
        conflict
            .syntax()
            .highlight_line_from(text.as_bytes(), conflict.state_before(at(text)))
            .iter()
            .map(|t| t.kind)
            .collect()
    };
    // Theirs starts where the block starts, outside the comment.
    assert!(colour("let theirs = 1;").contains(&TokenKind::Keyword));
    // After the block, the file goes on as ours left it: in the comment.
    assert_eq!(colour("fn b() {}"), [TokenKind::Comment]);
}
