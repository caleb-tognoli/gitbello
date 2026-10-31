//! Merge workflows (M7) through the runtime, on temporary repositories:
//! previews, merges, the conflict resolver, finishing operations and the
//! undo strip.

mod support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::changes::PickState;
use gitbello_core::git::GitErrorKind;
use gitbello_core::merge::{BlockChoice, ConflictKind, FileChoice, MergeMode, UndoMode};
use gitbello_core::ops::RefOp;
use gitbello_core::repo::Operation;
use gitbello_core::runtime::{CommitMode, Runtime, RuntimeEvent};
use support::rt::{finish, ok, open, outcome, poll_until, settle};
use support::TestRepo;

/// `main` and `feat` both change line 2 of `f.txt`; `feat` also adds
/// `new.txt`. Leaves `main` checked out.
fn diverged() -> TestRepo {
    let repo = TestRepo::init();
    repo.commit("f.txt", "a\nb\nc\n", "base");
    repo.branch("feat");
    repo.commit("f.txt", "a\nB1\nc\n", "main change");
    repo.checkout("feat");
    repo.commit("f.txt", "a\nB2\nc\n", "feat change");
    repo.commit("new.txt", "new\n", "feat adds a file");
    repo.checkout("main");
    repo
}

fn preview(rt: &mut Runtime, key: &Path, target: &str) -> gitbello_core::merge::MergePreview {
    rt.load_merge_preview(key, target).expect("preview starts");
    poll_until(rt, |rt, _| {
        rt.repo(key).is_some_and(|s| s.merge_preview().is_some())
    });
    rt.repo(key)
        .and_then(|s| s.merge_preview())
        .cloned()
        .expect("preview arrived")
}

fn read(repo: &TestRepo, file: &str) -> String {
    fs::read_to_string(repo.path().join(file))
        .expect("file exists")
        .replace("\r\n", "\n")
}

fn subject(repo: &TestRepo, rev: &str) -> String {
    repo.git(&["log", "-1", "--format=%s", rev])
        .trim()
        .to_owned()
}

/// Selects conflicted `path` and waits for its conflicts to load.
fn show_conflict(rt: &mut Runtime, key: &Path, path: &str) {
    rt.select_change(key, Path::new(path), false);
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .and_then(|s| s.conflict())
            .is_some_and(|c| !c.is_loading() && c.file().is_some())
    });
}

fn conflicted(rt: &Runtime, key: &Path) -> usize {
    rt.repo(key).map_or(0, |s| s.conflict_counts().0)
}

#[test]
fn previews_clean_conflicting_and_fast_forward_merges() {
    let repo = diverged();
    repo.branch("ahead");
    let (mut rt, key) = open(&repo);

    let p = preview(&mut rt, &key, "feat");
    assert!(!p.up_to_date && !p.can_ff);
    assert_eq!(p.commit_count, 2);
    assert_eq!(p.commits[0].subject, "feat adds a file");
    assert_eq!(p.conflicts.len(), 1);
    assert_eq!(p.conflicts[0].path, PathBuf::from("f.txt"));
    assert_eq!(p.conflicts[0].kind, "contents");
    assert!(p.files.contains(&PathBuf::from("new.txt")));
    assert_eq!(p.message, "Merge branch 'feat'");
    assert!(p.overlap.is_empty());

    // Already in HEAD.
    let p = preview(&mut rt, &key, "ahead");
    assert!(p.up_to_date);

    // Fast-forward: main is behind `feat2`, which only adds commits.
    repo.branch("feat2");
    repo.checkout("feat2");
    repo.commit("g.txt", "g\n", "g");
    repo.checkout("main");
    repo.write("g.txt", "local edit\n");
    settle(&mut rt, &key);
    let p = preview(&mut rt, &key, "feat2");
    assert!(p.can_ff && p.conflicts.is_empty());
    assert_eq!(p.files, [PathBuf::from("g.txt")]);
    assert_eq!(p.overlap, [PathBuf::from("g.txt")]);
}

#[test]
fn merges_in_each_mode() {
    let repo = diverged();
    repo.commit("f.txt", "a\nB2\nc\n", "main agrees with feat");
    let (mut rt, key) = open(&repo);

    // ff-only refuses diverged branches.
    let err = outcome(&mut rt, &key, |rt| {
        rt.merge(&key, "feat", MergeMode::FastForwardOnly, None, false)
    })
    .expect("refused");
    assert_ne!(err.kind, GitErrorKind::Conflict, "{err}");

    // Squash stages the result and leaves no operation.
    ok(&mut rt, &key, |rt| {
        rt.merge(&key, "feat", MergeMode::Squash, None, false)
    });
    let state = rt.repo(&key).unwrap();
    assert_eq!(state.operation(), None);
    assert!(state
        .status()
        .unwrap()
        .changes
        .iter()
        .any(|c| c.path == Path::new("new.txt") && c.is_staged()));
    repo.git(&["reset", "-q", "--hard"]);
    settle(&mut rt, &key);

    // A merge commit with our message.
    let message = Some("Bring in feat\n\nWith a body".to_owned());
    ok(&mut rt, &key, |rt| {
        rt.merge(&key, "feat", MergeMode::NoFastForward, message, false)
    });
    assert_eq!(subject(&repo, "HEAD"), "Bring in feat");
    assert_eq!(
        repo.git(&["rev-list", "--parents", "-n1", "HEAD"])
            .split_whitespace()
            .count(),
        3
    );

    // Default fast-forwards when it can.
    repo.branch("later");
    repo.checkout("later");
    let tip = repo.commit("h.txt", "h\n", "later");
    repo.checkout("main");
    settle(&mut rt, &key);
    ok(&mut rt, &key, |rt| {
        rt.merge(&key, "later", MergeMode::Default, None, false)
    });
    assert_eq!(repo.head(), tip);
}

#[test]
fn shelves_local_changes_around_a_merge() {
    let repo = diverged();
    repo.commit("f.txt", "a\nB2\nc\n", "main agrees with feat");
    repo.write("new.txt", "my own new.txt\n");
    let (mut rt, key) = open(&repo);
    let p = preview(&mut rt, &key, "feat");
    assert_eq!(p.overlap, [PathBuf::from("new.txt")]);

    // Without shelving, git refuses to overwrite the untracked file.
    let err = outcome(&mut rt, &key, |rt| {
        rt.merge(&key, "feat", MergeMode::Default, None, false)
    });
    assert!(err.is_some());
    assert_eq!(read(&repo, "new.txt"), "my own new.txt\n");

    // Shelved: the merge goes through and the change comes back (as a
    // conflicting restore, since new.txt now exists: the shelf stays).
    let job = rt.merge(&key, "feat", MergeMode::Default, None, true);
    let err = finish(&mut rt, &key, job);
    assert!(repo
        .git(&["log", "--format=%s"])
        .contains("feat adds a file"));
    if err.is_some() {
        assert_eq!(rt.repo(&key).unwrap().shelves().len(), 1);
    }

    // A clean shelve-and-merge restores the changes and drops the shelf.
    let repo = diverged();
    repo.commit("f.txt", "a\nB2\nc\n", "main agrees with feat");
    repo.write("f.txt", "a\nB2\nc\nlocal\n");
    let (mut rt, key) = open(&repo);
    ok(&mut rt, &key, |rt| {
        rt.merge(&key, "feat", MergeMode::NoFastForward, None, true)
    });
    assert_eq!(read(&repo, "f.txt"), "a\nB2\nc\nlocal\n");
    assert!(rt.repo(&key).unwrap().shelves().is_empty());
}

#[test]
fn conflicting_shelve_and_merge_keeps_the_shelf() {
    let repo = diverged();
    repo.write("other.txt", "local\n");
    repo.git(&["add", "other.txt"]);
    let (mut rt, key) = open(&repo);
    let err = outcome(&mut rt, &key, |rt| {
        rt.merge(&key, "feat", MergeMode::Default, None, true)
    })
    .expect("conflicts");
    assert_eq!(err.kind, GitErrorKind::Conflict);
    let state = rt.repo(&key).unwrap();
    assert_eq!(state.operation(), Some(Operation::Merge));
    assert_eq!(state.shelves().len(), 1);
    assert!(state.shelves()[0].auto);
    assert!(!repo.path().join("other.txt").exists());
}

#[test]
fn resolves_blocks_and_commits_the_merge_without_other_local_changes() {
    let repo = diverged();
    repo.commit("notes.txt", "notes\n", "notes");
    repo.write("notes.txt", "my local notes\n");
    let (mut rt, key) = open(&repo);
    let err = outcome(&mut rt, &key, |rt| {
        rt.merge(&key, "feat", MergeMode::Default, None, false)
    });
    assert_eq!(err.map(|e| e.kind), Some(GitErrorKind::Conflict));
    let state = rt.repo(&key).unwrap();
    assert_eq!(state.commit_mode(), CommitMode::Merge);
    let details = state.operation_details().unwrap();
    assert_eq!(details.other_name.as_deref(), Some("feat"));
    assert!(details.message.starts_with("Merge branch 'feat'"));
    assert_eq!(
        state.commit_block_reason(false),
        Some("Resolve conflicts first")
    );
    // Locked checkboxes: the merged file is in, the local edit is out.
    assert_eq!(state.pick_state(Path::new("new.txt")), PickState::All);
    assert_eq!(state.pick_state(Path::new("notes.txt")), PickState::None);
    assert!(!rt.pick_files(&key, &[PathBuf::from("notes.txt")], true));

    show_conflict(&mut rt, &key, "f.txt");
    let conflict = rt.repo(&key).unwrap().conflict().unwrap();
    let file = conflict.file().unwrap();
    assert_eq!(conflict.kind(), ConflictKind::Content);
    assert_eq!(file.blocks.len(), 1);
    assert!(file.has_base(), "merges write zdiff3 markers");

    ok(&mut rt, &key, |rt| {
        rt.resolve_block(&key, Path::new("f.txt"), 0, BlockChoice::OursThenTheirs)
    });
    assert_eq!(read(&repo, "f.txt"), "a\nB1\nB2\nc\n");
    let state = rt.repo(&key).unwrap();
    assert_eq!(conflicted(&rt, &key), 0, "staged once no block is left");
    assert!(state.is_resolved(Path::new("f.txt")));
    assert_eq!(state.conflict_counts(), (0, 1));
    assert!(state.conflict().is_none(), "resolved files show as diffs");
    assert!(state.diff().is_some());

    // Undo brings the conflict back, then pick theirs instead.
    ok(&mut rt, &key, |rt| rt.undo_block_choice(&key));
    assert_eq!(conflicted(&rt, &key), 1);
    assert!(read(&repo, "f.txt").contains("<<<<<<<"));
    show_conflict(&mut rt, &key, "f.txt");
    ok(&mut rt, &key, |rt| {
        rt.resolve_file(&key, Path::new("f.txt"), FileChoice::Theirs)
    });
    assert_eq!(read(&repo, "f.txt"), "a\nB2\nc\n");

    let state = rt.repo(&key).unwrap();
    assert_eq!(state.commit_block_reason(false), None);
    assert_eq!(
        state.commit_block_reason(true),
        Some("Commit the merge first")
    );
    ok(&mut rt, &key, |rt| {
        rt.commit(&key, "Merge feat by hand\n".into(), false)
    });
    assert_eq!(subject(&repo, "HEAD"), "Merge feat by hand");
    assert_eq!(rt.repo(&key).unwrap().operation(), None);
    let committed = repo.git(&["show", "--name-only", "--format=", "HEAD"]);
    assert!(!committed.contains("notes.txt"), "{committed}");
    assert_eq!(read(&repo, "notes.txt"), "my local notes\n");
}

#[test]
fn stages_files_edited_outside_and_reopens_conflicts() {
    let repo = TestRepo::init();
    repo.start_conflicting_merge("c.txt");
    let (mut rt, key) = open(&repo);
    show_conflict(&mut rt, &key, "c.txt");
    let file = rt
        .repo(&key)
        .unwrap()
        .conflict()
        .unwrap()
        .file()
        .unwrap()
        .clone();
    assert!(
        !file.has_base(),
        "a merge made outside has no base in its markers"
    );

    // Recreate with the base.
    ok(&mut rt, &key, |rt| {
        rt.reopen_conflicts(&key, Path::new("c.txt"), true)
    });
    show_conflict(&mut rt, &key, "c.txt");
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.conflict())
            .and_then(|c| c.file())
            .is_some_and(|f| f.has_base())
    });
    assert!(rt.repo(&key).unwrap().conflict_shows_base());

    // An editor removes the markers: the file gets staged.
    repo.write("c.txt", "merged by hand\n");
    settle(&mut rt, &key);
    poll_until(&mut rt, |rt, _| conflicted(rt, &key) == 0);
    settle(&mut rt, &key);
    assert!(rt.repo(&key).unwrap().is_resolved(Path::new("c.txt")));

    // Reopen brings the conflict back.
    ok(&mut rt, &key, |rt| {
        rt.reopen_conflicts(&key, Path::new("c.txt"), false)
    });
    assert_eq!(conflicted(&rt, &key), 1);

    ok(&mut rt, &key, |rt| {
        rt.ref_op(&key, RefOp::Abort(Operation::Merge))
    });
    assert_eq!(rt.repo(&key).unwrap().operation(), None);
}

#[test]
fn resolves_modify_delete_and_binary_conflicts() {
    let repo = TestRepo::init();
    repo.commit("gone.txt", "base\n", "base");
    fs::write(repo.path().join("pic.bin"), b"\0\x01base").unwrap();
    repo.git(&["add", "pic.bin"]);
    repo.git(&["commit", "-q", "-m", "binary"]);
    repo.branch("feat");
    repo.git(&["rm", "-q", "gone.txt"]);
    fs::write(repo.path().join("pic.bin"), b"\0\x01ours").unwrap();
    repo.git(&["commit", "-q", "-am", "main deletes, edits binary"]);
    repo.checkout("feat");
    repo.commit("gone.txt", "changed\n", "feat edits");
    fs::write(repo.path().join("pic.bin"), b"\0\x01theirs!").unwrap();
    repo.git(&["commit", "-q", "-am", "feat edits binary"]);
    repo.checkout("main");
    let (mut rt, key) = open(&repo);
    let p = preview(&mut rt, &key, "feat");
    let kinds: Vec<&str> = p.conflicts.iter().map(|c| c.kind.as_str()).collect();
    assert!(kinds.contains(&"modify/delete"), "{kinds:?}");

    let err = outcome(&mut rt, &key, |rt| {
        rt.merge(&key, "feat", MergeMode::Default, None, false)
    });
    assert_eq!(err.map(|e| e.kind), Some(GitErrorKind::Conflict));
    assert_eq!(conflicted(&rt, &key), 2);

    show_conflict(&mut rt, &key, "gone.txt");
    assert_eq!(
        rt.repo(&key).unwrap().conflict().unwrap().kind(),
        ConflictKind::ModifyDelete {
            deleted_by_us: true
        }
    );
    show_conflict(&mut rt, &key, "pic.bin");
    let conflict = rt.repo(&key).unwrap().conflict().unwrap();
    assert_eq!(conflict.kind(), ConflictKind::Binary);
    assert_eq!(conflict.file().unwrap().theirs_size, Some(9));

    ok(&mut rt, &key, |rt| {
        rt.resolve_file(&key, Path::new("gone.txt"), FileChoice::Keep)
    });
    assert_eq!(read(&repo, "gone.txt"), "changed\n");
    ok(&mut rt, &key, |rt| {
        rt.resolve_file(&key, Path::new("pic.bin"), FileChoice::Theirs)
    });
    assert_eq!(
        fs::read(repo.path().join("pic.bin")).unwrap(),
        b"\0\x01theirs!"
    );
    assert_eq!(conflicted(&rt, &key), 0);

    // Deleting works too: reopen gone.txt and delete it.
    ok(&mut rt, &key, |rt| {
        rt.reopen_conflicts(&key, Path::new("gone.txt"), false)
    });
    assert_eq!(conflicted(&rt, &key), 1);
    ok(&mut rt, &key, |rt| {
        rt.resolve_file(&key, Path::new("gone.txt"), FileChoice::Delete)
    });
    assert!(!repo.path().join("gone.txt").exists());
    ok(&mut rt, &key, |rt| rt.continue_operation(&key, None));
    assert_eq!(subject(&repo, "HEAD"), "Merge branch 'feat'");
}

#[test]
fn commits_a_cherry_pick_with_its_author() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "base\n", "base");
    repo.branch("other");
    repo.commit("f.txt", "ours\n", "ours");
    repo.checkout("other");
    fs::write(repo.path().join("f.txt"), "theirs\n").unwrap();
    repo.git(&[
        "commit",
        "-q",
        "--author=Zed <zed@example.com>",
        "-am",
        "zed's change",
    ]);
    let picked = repo.head();
    repo.checkout("main");
    let (mut rt, key) = open(&repo);
    let err = outcome(&mut rt, &key, |rt| {
        rt.ref_op(
            &key,
            RefOp::CherryPick {
                commit: picked.clone(),
            },
        )
    });
    assert!(err.is_some());
    let state = rt.repo(&key).unwrap();
    assert_eq!(state.commit_mode(), CommitMode::CherryPick);
    let details = state.operation_details().unwrap();
    assert_eq!(details.other_oid.as_deref(), Some(picked.as_str()));
    assert_eq!(details.other_name.as_deref(), Some("zed's change"));

    ok(&mut rt, &key, |rt| {
        rt.resolve_file(&key, Path::new("f.txt"), FileChoice::Theirs)
    });
    ok(&mut rt, &key, |rt| {
        rt.commit(&key, "Pick zed's change\n".into(), false)
    });
    assert_eq!(
        repo.git(&["log", "-1", "--format=%an|%s"]).trim(),
        "Zed|Pick zed's change"
    );
    assert_eq!(rt.repo(&key).unwrap().operation(), None);
}

#[test]
fn continues_and_skips_a_rebase() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "base\n", "base");
    repo.branch("topic");
    repo.commit("f.txt", "main\n", "main");
    repo.checkout("topic");
    repo.commit("f.txt", "topic 1\n", "topic 1");
    repo.commit("f.txt", "topic 2\n", "topic 2");
    let (mut rt, key) = open(&repo);
    let _ = repo.try_git(&["rebase", "main"]);
    settle(&mut rt, &key);
    let state = rt.repo(&key).unwrap();
    assert_eq!(state.commit_mode(), CommitMode::Rebase);
    assert_eq!(
        state.commit_block_reason(false),
        Some("Use Continue in the banner")
    );
    let details = state.operation_details().unwrap();
    assert_eq!(details.head_name.as_deref(), Some("topic"));
    assert_eq!(details.step, Some((1, 2)));
    assert!(
        rt.continue_operation(&key, None).is_none(),
        "conflicts left"
    );

    // Skip the first commit; the second conflicts too: resolve and continue.
    let _ = outcome(&mut rt, &key, |rt| rt.skip_operation(&key));
    settle(&mut rt, &key);
    assert_eq!(
        rt.repo(&key).unwrap().operation_details().unwrap().step,
        Some((2, 2))
    );
    ok(&mut rt, &key, |rt| {
        rt.resolve_file(&key, Path::new("f.txt"), FileChoice::Theirs)
    });
    ok(&mut rt, &key, |rt| rt.continue_operation(&key, None));
    assert_eq!(rt.repo(&key).unwrap().operation(), None);
    assert_eq!(subject(&repo, "HEAD"), "topic 2");
    assert_eq!(subject(&repo, "HEAD~1"), "main");
}

fn wait_undoable(rt: &mut Runtime, key: &Path, oid: &str) {
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .and_then(|s| s.undoable_commit())
            .is_some_and(|c| c.oid == oid)
    });
}

#[test]
fn undoes_commits_into_local_changes() {
    let repo = TestRepo::init();
    let first = repo.commit("a.txt", "one\n", "first");
    let remote = repo.add_remote();
    let _ = remote;
    repo.git(&["push", "-q", "-u", "origin", "main"]);
    repo.commit("a.txt", "two\n", "second\n\nbody text");
    let third = repo.commit("b.txt", "b\n", "third");
    let (mut rt, key) = open(&repo);
    wait_undoable(&mut rt, &key, &third);

    let job = rt.undo_commit(&key, &third, UndoMode::KeepChanges).unwrap();
    let events = poll_until(&mut rt, |_, ev| support::rt::result(ev, job).is_some());
    assert_eq!(support::rt::result(&events, job), Some(None));
    settle(&mut rt, &key);
    let message = events.iter().find_map(|e| match e {
        RuntimeEvent::CommitUndone { message, .. } => Some(message.clone()),
        _ => None,
    });
    assert_eq!(message.as_deref().map(str::trim), Some("third"));
    let second = repo.head();
    wait_undoable(&mut rt, &key, &second);
    assert_eq!(
        rt.repo(&key).unwrap().undoable_commit().unwrap().body,
        "body text"
    );

    // A second undo in a row: both commits' changes are local now.
    ok(&mut rt, &key, |rt| {
        rt.undo_commit(&key, &second, UndoMode::KeepChanges)
    });
    assert_eq!(repo.head(), first);
    assert_eq!(read(&repo, "a.txt"), "two\n");
    assert_eq!(read(&repo, "b.txt"), "b\n");
    // The pushed commit is not offered.
    settle(&mut rt, &key);
    poll_until(&mut rt, |rt, _| rt.pending_jobs() == 0);
    assert!(rt.repo(&key).unwrap().undoable_commit().is_none());
    assert!(rt
        .undo_commit(&key, &first, UndoMode::KeepChanges)
        .is_none());
}

#[test]
fn undoes_the_first_commit() {
    let repo = TestRepo::init();
    let only = repo.commit("a.txt", "a\n", "only");
    let (mut rt, key) = open(&repo);
    wait_undoable(&mut rt, &key, &only);
    ok(&mut rt, &key, |rt| {
        rt.undo_commit(&key, &only, UndoMode::KeepChanges)
    });
    assert!(repo
        .try_git(&["rev-parse", "-q", "--verify", "HEAD"])
        .is_err());
    assert_eq!(read(&repo, "a.txt"), "a\n");
    assert_eq!(rt.repo(&key).unwrap().status().unwrap().oid, None);
}

#[test]
fn undoes_a_merge_commit_either_way() {
    for mode in [UndoMode::KeepChanges, UndoMode::RemoveMerge] {
        let repo = diverged();
        repo.commit("f.txt", "a\nB2\nc\n", "main agrees with feat");
        let before = repo.head();
        repo.write("local.txt", "local\n");
        let (mut rt, key) = open(&repo);
        ok(&mut rt, &key, |rt| {
            rt.merge(&key, "feat", MergeMode::NoFastForward, None, false)
        });
        let merge = repo.head();
        wait_undoable(&mut rt, &key, &merge);
        assert!(rt.repo(&key).unwrap().undoable_commit().unwrap().is_merge());
        ok(&mut rt, &key, |rt| rt.undo_commit(&key, &merge, mode));
        assert_eq!(repo.head(), before);
        assert_eq!(read(&repo, "local.txt"), "local\n");
        let merged_file = repo.path().join("new.txt").exists();
        assert_eq!(merged_file, mode == UndoMode::KeepChanges, "{mode:?}");
    }
}

#[test]
fn knows_which_commits_head_lacks() {
    let repo = diverged();
    let (mut rt, key) = open(&repo);
    let feat = repo.git(&["rev-parse", "feat"]).trim().to_owned();
    let main = repo.head();
    poll_until(&mut rt, |rt, _| !rt.repo(&key).unwrap().in_head(&feat));
    assert!(rt.repo(&key).unwrap().in_head(&main));
}
