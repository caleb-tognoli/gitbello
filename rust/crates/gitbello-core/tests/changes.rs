//! Diffs, staging and commits through the backend and the runtime, on real
//! temporary repositories.

mod support;

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use gitbello_core::backend::{CliBackend, GitBackend};
use gitbello_core::changes::PickState;
use gitbello_core::config::Config;
use gitbello_core::diff::{DiffContent, DiffKind, DiffTarget, LineKind};
use gitbello_core::git::{CancelToken, GitErrorKind};
use gitbello_core::jobs::RefreshKind;
use gitbello_core::repo::{Change, FileState};
use gitbello_core::runtime::{JobState, Runtime, RuntimeEvent, COMMIT_JOB_LABEL};
use support::TestRepo;

const WAIT: Duration = Duration::from_secs(10);

fn backend(repo: &TestRepo) -> CliBackend {
    CliBackend::new(repo.app_runner())
}

fn no_cancel() -> CancelToken {
    CancelToken::new()
}

fn target(kind: DiffKind, path: &str) -> DiffTarget {
    DiffTarget {
        kind,
        path: PathBuf::from(path),
        original_path: None,
        commit: None,
    }
}

fn paths(list: &[&str]) -> Vec<PathBuf> {
    list.iter().map(PathBuf::from).collect()
}

/// Which side of git's index a change is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Side {
    Staged,
    Unstaged,
    Untracked,
}

/// `(side, path)` of every change (a file staged and edited is on both sides).
fn lists(repo: &TestRepo) -> Vec<(Side, String)> {
    let status = backend(repo)
        .status(repo.path(), &no_cancel())
        .expect("status");
    let mut out = Vec::new();
    for change in &status.changes {
        let path = change.path.to_string_lossy().into_owned();
        if change.is_staged() {
            out.push((Side::Staged, path.clone()));
        }
        match change.state {
            FileState::Untracked => out.push((Side::Untracked, path)),
            FileState::Tracked { worktree, .. } if worktree != Change::Unmodified => {
                out.push((Side::Unstaged, path))
            }
            _ => {}
        }
    }
    out
}

#[test]
fn diff_of_unstaged_staged_and_untracked_files() {
    let repo = TestRepo::init();
    repo.commit("app.txt", "one\ntwo\nthree\n", "base");
    repo.write("app.txt", "one\n2\nthree\nfour\n");
    let b = backend(&repo);

    let diff = b
        .diff(
            repo.path(),
            &target(DiffKind::Unstaged, "app.txt"),
            None,
            &no_cancel(),
        )
        .unwrap();
    assert_eq!((diff.additions, diff.deletions), (2, 1));
    let kinds: Vec<LineKind> = diff.lines(0, 99).map(|l| l.kind).collect();
    use LineKind::*;
    assert_eq!(kinds, [Hunk, Context, Removed, Added, Context, Added]);

    repo.git(&["add", "app.txt"]);
    let unstaged = b
        .diff(
            repo.path(),
            &target(DiffKind::Unstaged, "app.txt"),
            None,
            &no_cancel(),
        )
        .unwrap();
    assert!(unstaged.is_empty());
    let staged = b
        .diff(
            repo.path(),
            &target(DiffKind::Staged, "app.txt"),
            None,
            &no_cancel(),
        )
        .unwrap();
    assert_eq!(staged.additions, 2);

    repo.write("new dir/ünïcode.txt", "a\r\nb");
    let untracked = b
        .diff(
            repo.path(),
            &target(DiffKind::Untracked, "new dir/ünïcode.txt"),
            None,
            &no_cancel(),
        )
        .unwrap();
    assert!(untracked.header.new_file);
    let last = untracked.line(2).unwrap();
    assert_eq!((last.text, last.no_newline), (&b"b"[..], true));
    assert_eq!(untracked.line(1).unwrap().text, b"a\r");
}

#[test]
fn diff_handles_renames_binary_and_large_files() {
    let repo = TestRepo::init();
    repo.commit("old.txt", "same\ncontent\nhere\n", "base");
    fs::write(repo.path().join("img.bin"), [0u8, 1, 2, 3]).unwrap();
    repo.git(&["add", "img.bin"]);
    repo.git(&["commit", "-q", "-m", "binary"]);
    repo.git(&["mv", "old.txt", "new.txt"]);
    let b = backend(&repo);

    let renamed = b
        .diff(
            repo.path(),
            &DiffTarget {
                kind: DiffKind::Staged,
                path: PathBuf::from("new.txt"),
                original_path: Some(PathBuf::from("old.txt")),
                commit: None,
            },
            None,
            &no_cancel(),
        )
        .unwrap();
    assert_eq!(renamed.header.renamed_from.as_deref(), Some("old.txt"));
    assert_eq!(renamed.line_count(), 0);

    fs::write(repo.path().join("img.bin"), [0u8, 9, 9, 9, 9, 9]).unwrap();
    let binary = b
        .diff(
            repo.path(),
            &target(DiffKind::Unstaged, "img.bin"),
            None,
            &no_cancel(),
        )
        .unwrap();
    assert_eq!(
        binary.content,
        DiffContent::Binary {
            old_size: Some(4),
            new_size: Some(6)
        }
    );

    let big: String = (0..5000).map(|i| format!("line {i}\n")).collect();
    repo.write("new.txt", &big);
    let limited = b
        .diff(
            repo.path(),
            &target(DiffKind::Unstaged, "new.txt"),
            Some(1000),
            &no_cancel(),
        )
        .unwrap();
    assert!(matches!(limited.content, DiffContent::TooLarge { bytes } if bytes > 1000));
    let full = b
        .diff(
            repo.path(),
            &target(DiffKind::Unstaged, "new.txt"),
            None,
            &no_cancel(),
        )
        .unwrap();
    assert_eq!(full.additions, 5000);
}

#[test]
fn stage_and_unstage_files_including_odd_names() {
    let repo = TestRepo::init();
    repo.commit("keep.txt", "keep\n", "base");
    repo.commit("gone.txt", "bye\n", "to delete");
    repo.write("keep.txt", "changed\n");
    repo.write("[ab].txt", "a glob\n");
    repo.write("a.txt", "matched by the glob\n");
    repo.write("dir/spaced ünï.txt", "u\n");
    fs::remove_file(repo.path().join("gone.txt")).unwrap();
    let b = backend(&repo);

    let all = paths(&[
        "keep.txt",
        "[ab].txt",
        "a.txt",
        "dir/spaced ünï.txt",
        "gone.txt",
    ]);
    b.stage(repo.path(), Some(&all[..2]), &no_cancel()).unwrap();
    // `[ab].txt` is literal: `a.txt` is not staged with it.
    let listed = lists(&repo);
    assert!(
        listed.contains(&(Side::Staged, "[ab].txt".into())),
        "{listed:?}"
    );
    assert!(
        listed.contains(&(Side::Untracked, "a.txt".into())),
        "{listed:?}"
    );
    assert!(
        listed.contains(&(Side::Unstaged, "gone.txt".into())),
        "{listed:?}"
    );

    b.stage(repo.path(), Some(&all), &no_cancel()).unwrap();
    let listed = lists(&repo);
    assert!(listed.iter().all(|(g, _)| *g == Side::Staged), "{listed:?}");
    assert_eq!(listed.len(), 5);

    b.unstage(repo.path(), Some(&all[2..4]), &no_cancel())
        .unwrap();
    let listed = lists(&repo);
    assert!(
        listed.contains(&(Side::Untracked, "a.txt".into())),
        "{listed:?}"
    );
    assert!(listed.contains(&(Side::Untracked, "dir/spaced ünï.txt".into())));

    b.unstage(repo.path(), None, &no_cancel()).unwrap();
    assert!(lists(&repo).iter().all(|(g, _)| *g != Side::Staged));
    b.stage(repo.path(), None, &no_cancel()).unwrap();
    assert!(lists(&repo).iter().all(|(g, _)| *g == Side::Staged));
}

#[test]
fn unstage_works_on_an_unborn_branch() {
    let repo = TestRepo::init();
    repo.write("first.txt", "1\n");
    repo.write("second.txt", "2\n");
    let b = backend(&repo);
    b.stage(repo.path(), None, &no_cancel()).unwrap();
    b.unstage(repo.path(), Some(&paths(&["first.txt"])), &no_cancel())
        .unwrap();
    let listed = lists(&repo);
    assert!(listed.contains(&(Side::Untracked, "first.txt".into())));
    assert!(listed.contains(&(Side::Staged, "second.txt".into())));
    b.unstage(repo.path(), None, &no_cancel()).unwrap();
    assert!(lists(&repo).iter().all(|(g, _)| *g == Side::Untracked));
}

#[test]
fn commit_amend_and_hook_failures() {
    let repo = TestRepo::init();
    let b = backend(&repo);
    repo.write("a.txt", "a\n");
    b.stage(repo.path(), None, &no_cancel()).unwrap();
    b.commit(repo.path(), "First\n\nWith a body.\n", false, &no_cancel())
        .unwrap();
    assert_eq!(
        repo.git(&["log", "-1", "--format=%s|%b"]),
        "First|With a body."
    );
    assert_eq!(
        b.head_message(repo.path(), &no_cancel()).unwrap(),
        "First\n\nWith a body.\n\n"
    );

    b.commit(repo.path(), "First, reworded\n", true, &no_cancel())
        .unwrap();
    assert_eq!(repo.git(&["rev-list", "--count", "HEAD"]), "1");
    assert_eq!(repo.git(&["log", "-1", "--format=%s"]), "First, reworded");

    let err = b
        .commit(repo.path(), "Nothing staged\n", false, &no_cancel())
        .unwrap_err();
    assert_eq!(err.exit_code, Some(1));

    // A pre-commit hook that rejects the commit: its output reaches the error.
    let hooks = repo.path().join(".git/hooks");
    fs::create_dir_all(&hooks).unwrap();
    fs::write(
        hooks.join("pre-commit"),
        "#!/bin/sh\necho 'lint failed: a.txt' >&2\nexit 1\n",
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(hooks.join("pre-commit"), fs::Permissions::from_mode(0o755)).unwrap();
    }
    repo.write("a.txt", "b\n");
    b.stage(repo.path(), None, &no_cancel()).unwrap();
    let err = b
        .commit(repo.path(), "Blocked\n", false, &no_cancel())
        .unwrap_err();
    assert!(err.stderr.contains("lint failed: a.txt"), "{err:?}");
    assert_eq!(err.kind, GitErrorKind::Other);
}

fn poll_until(
    rt: &mut Runtime,
    mut done: impl FnMut(&Runtime, &[RuntimeEvent]) -> bool,
) -> Vec<RuntimeEvent> {
    let deadline = Instant::now() + WAIT;
    let mut seen = Vec::new();
    loop {
        seen.extend(rt.poll());
        if done(rt, &seen) {
            return seen;
        }
        assert!(Instant::now() < deadline, "timed out; events: {seen:#?}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn open(repo: &TestRepo) -> (Runtime, PathBuf) {
    let mut rt = Runtime::with_runner(Config::default(), None, repo.app_runner());
    let key = rt.open(repo.path());
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .is_some_and(|s| s.status().is_some() && s.refs().is_some())
    });
    (rt, key)
}

fn picked(rt: &Runtime, key: &Path) -> usize {
    rt.repo(key).map_or(0, |s| s.selection().picked_count())
}

#[test]
fn runtime_pick_commit_amend_cycle() {
    let repo = TestRepo::init();
    repo.commit("app.txt", "v1\n", "base");
    repo.write("app.txt", "v2\n");
    repo.write("notes.txt", "n\n");
    let (mut rt, key) = open(&repo);
    // Nothing staged: everything starts picked.
    assert_eq!(picked(&rt, &key), 2);
    assert!(rt.repo(&key).unwrap().can_commit(false));
    assert!(rt.repo(&key).unwrap().can_commit(true));

    // Selecting a change loads its diff against HEAD; editing reloads it.
    rt.select_change(&key, Path::new("app.txt"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .and_then(|d| d.diff())
            .is_some_and(|d| d.additions == 1)
    });
    assert_eq!(
        rt.repo(&key).unwrap().diff().unwrap().target().kind,
        DiffKind::Head
    );
    repo.write("app.txt", "v2\nv3\n");
    rt.refresh(
        &key,
        gitbello_core::jobs::RefreshSet::EMPTY.with(RefreshKind::Status),
    );
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .and_then(|d| d.diff())
            .is_some_and(|d| d.additions == 2)
    });
    let picks = rt.repo(&key).unwrap().diff_picks().to_vec();
    assert!(picks.iter().filter(|p| **p == PickState::All).count() >= 3);

    assert!(rt.pick_files(&key, &paths(&["notes.txt"]), false));
    assert!(rt
        .poll()
        .contains(&RuntimeEvent::SelectionChanged { repo: key.clone() }));
    assert_eq!(picked(&rt, &key), 1);
    rt.pick_all(&key, false);
    assert_eq!(
        rt.repo(&key).unwrap().commit_block_reason(false),
        Some("Nothing included")
    );
    assert!(rt.commit(&key, "Nothing\n".into(), false).is_none());
    rt.pick_files(&key, &paths(&["app.txt"]), true);

    let job = rt.commit(&key, "Ship v3\n".into(), false).unwrap();
    let events = poll_until(&mut rt, |rt, ev| {
        let finished = ev.iter().any(|e| {
            matches!(e, RuntimeEvent::Job { job: j, state: JobState::Finished(None), .. } if *j == job)
        });
        finished && rt.repo(&key).is_some_and(|s| s.changes().len() == 1)
    });
    assert!(events
        .iter()
        .any(|e| matches!(e, RuntimeEvent::Job { label, .. } if label == COMMIT_JOB_LABEL)));
    assert_eq!(repo.git(&["log", "-1", "--format=%s"]), "Ship v3");
    assert_eq!(repo.git(&["status", "--porcelain"]), "?? notes.txt");

    rt.load_head_message(&key).unwrap();
    let events = poll_until(&mut rt, |_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::HeadMessage { .. }))
    });
    assert!(events.contains(&RuntimeEvent::HeadMessage {
        repo: key.clone(),
        message: "Ship v3\n\n".into()
    }));

    // notes.txt is still unpicked: amending rewords only.
    let job = rt.commit(&key, "Ship v3 (amended)\n".into(), true).unwrap();
    poll_until(&mut rt, |_, ev| {
        ev.iter().any(|e| matches!(e, RuntimeEvent::Job { job: j, state: JobState::Finished(None), .. } if *j == job))
    });
    assert_eq!(repo.git(&["rev-list", "--count", "HEAD"]), "2");
    assert_eq!(repo.git(&["log", "-1", "--format=%s"]), "Ship v3 (amended)");
    assert_eq!(
        repo.git(&["show", "--name-only", "--format=", "HEAD"]),
        "app.txt"
    );
}

#[test]
fn runtime_reports_worktree_badges() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    let linked = repo.add_worktree("feature", "linked wörktree");
    fs::write(linked.join("a.txt"), "changed\n").unwrap();
    fs::write(linked.join("new.txt"), "new\n").unwrap();
    let (mut rt, key) = open(&repo);
    let listed = poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.worktrees())
            .is_some_and(|w| w.len() == 2)
    });
    drop(listed);
    poll_until(&mut rt, |rt, _| {
        let Some(state) = rt.repo(&key) else {
            return false;
        };
        let Some(wt) = state
            .worktrees()
            .and_then(|w| w.iter().find(|w| !w.is_main))
        else {
            return false;
        };
        state
            .worktree_badge(&wt.path)
            .is_some_and(|b| b.changed == 2 && b.head == "feature")
    });
}
