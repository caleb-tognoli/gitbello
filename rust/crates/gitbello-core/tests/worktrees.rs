//! Worktrees (M6) through the runtime: add, lock, remove and prune, the
//! new-task flow with its rollback, the cleanup flow, missing folders and
//! badges across open worktrees.

mod support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::config::{Config, DEFAULT_WORKTREE_TEMPLATE};
use gitbello_core::git::GitErrorKind;
use gitbello_core::ops::{NewTask, WorktreeOp};
use gitbello_core::runtime::{Runtime, RuntimeEvent};
use gitbello_core::worktrees::{worktree_path, CleanupReason};
use support::rt::{ok, open, outcome, poll_until, settle};
use support::TestRepo;

fn worktree_paths(rt: &Runtime, key: &Path) -> Vec<PathBuf> {
    rt.repo(key)
        .and_then(|s| s.worktrees())
        .map(|list| list.iter().map(|wt| wt.path.clone()).collect())
        .unwrap_or_default()
}

fn listed(rt: &Runtime, key: &Path, path: &Path) -> bool {
    worktree_paths(rt, key)
        .iter()
        .any(|p| p.components().eq(path.components()))
}

/// Waits until the worktree list (refreshed by worktree jobs) is current.
fn settle_worktrees(rt: &mut Runtime, key: &Path) {
    use gitbello_core::jobs::{RefreshKind, RefreshSet};
    rt.refresh(key, RefreshSet::EMPTY.with(RefreshKind::Worktrees));
    settle(rt, key);
}

#[test]
fn add_lock_remove_and_prune_worktrees() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.branch("existing");
    let (mut rt, key) = open(&repo);

    let existing = repo.sibling("existing wörktree");
    let add = WorktreeOp::Add {
        path: existing.clone(),
        branch: "existing".into(),
        start: None,
    };
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, add));
    let fresh = repo.sibling("fresh");
    let add_new = WorktreeOp::Add {
        path: fresh.clone(),
        branch: "fresh".into(),
        start: Some("main".into()),
    };
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, add_new));
    settle_worktrees(&mut rt, &key);
    assert!(listed(&rt, &key, &existing) && listed(&rt, &key, &fresh));
    let state = rt.repo(&key).unwrap();
    assert!(state.branch("fresh").unwrap().worktree.is_some());
    assert_eq!(state.branch("fresh").unwrap().upstream, None, "no tracking");

    let lock = WorktreeOp::Lock {
        path: existing.clone(),
        reason: "on a usb disk".into(),
    };
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, lock));
    let locked = |rt: &Runtime| {
        rt.repo(&key).unwrap().worktrees().unwrap()[1]
            .locked
            .clone()
    };
    settle_worktrees(&mut rt, &key);
    assert_eq!(locked(&rt).as_deref(), Some("on a usb disk"));
    let unlock = WorktreeOp::Unlock {
        path: existing.clone(),
    };
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, unlock));
    settle_worktrees(&mut rt, &key);
    assert_eq!(locked(&rt), None);

    // A worktree with changes is only removed by force.
    fs::write(fresh.join("a.txt"), "edited\n").unwrap();
    let remove = |force| WorktreeOp::Remove {
        path: fresh.clone(),
        force,
    };
    let err = outcome(&mut rt, &key, |rt| rt.worktree_op(&key, remove(false))).expect("dirty");
    assert!(err.stderr.contains("modified or untracked"), "{err}");
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, remove(true)));
    assert!(!fresh.exists());

    // A deleted folder shows as prunable until pruned.
    fs::remove_dir_all(&existing).unwrap();
    settle_worktrees(&mut rt, &key);
    assert!(rt.repo(&key).unwrap().worktrees().unwrap()[1]
        .prunable
        .is_some());
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, WorktreeOp::Prune));
    settle_worktrees(&mut rt, &key);
    assert_eq!(worktree_paths(&rt, &key).len(), 1);
}

#[test]
fn new_task_fetches_the_base_and_adds_a_worktree() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let remote = repo.add_remote();
    let other = repo.clone_remote(&remote, "other");
    let upstream_tip = {
        repo.push_from(&other, "b.txt", "b\n", "newer on the remote");
        repo.command_in(&other)
            .args(["rev-parse", "HEAD"])
            .run()
            .unwrap()
            .stdout_text()
            .trim()
            .to_owned()
    };
    let (mut rt, key) = open(&repo);
    let state = rt.repo(&key).unwrap();
    assert_eq!(state.default_base().as_deref(), Some("origin/main"));
    let main = state.main_worktree().unwrap().to_path_buf();
    let path = worktree_path(DEFAULT_WORKTREE_TEMPLATE, &main, "feature/new task");
    assert!(
        path.to_string_lossy().contains(".worktrees"),
        "{}",
        path.display()
    );

    let task = NewTask {
        branch: "feature/new-task".into(),
        base: "origin/main".into(),
        path: path.clone(),
        fetch_remote: Some("origin".into()),
    };
    ok(&mut rt, &key, |rt| rt.new_task(&key, task.clone()));
    settle_worktrees(&mut rt, &key);
    assert!(listed(&rt, &key, &path));
    assert!(
        path.join("b.txt").is_file(),
        "started from the fetched base"
    );
    let branch = rt
        .repo(&key)
        .unwrap()
        .branch("feature/new-task")
        .unwrap()
        .clone();
    assert_eq!(branch.target, upstream_tip);
    assert_eq!(branch.upstream, None, "the task branch does not track main");

    // The same branch again is refused before anything is created.
    let other_path = repo.sibling("another");
    let again = NewTask {
        path: other_path.clone(),
        ..task
    };
    let err = outcome(&mut rt, &key, |rt| rt.new_task(&key, again)).expect("exists");
    assert_eq!(err.kind, GitErrorKind::AlreadyExists, "{err}");
    assert!(!other_path.exists());
}

#[test]
fn new_task_rolls_back_when_the_worktree_cannot_be_added() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let (mut rt, key) = open(&repo);
    // A non-empty folder: `git worktree add -b` creates the branch, then
    // refuses the folder.
    let path = repo.sibling("occupied");
    fs::create_dir_all(&path).unwrap();
    fs::write(path.join("keep.txt"), "mine\n").unwrap();
    let task = NewTask {
        branch: "doomed".into(),
        base: "main".into(),
        path: path.clone(),
        fetch_remote: None,
    };
    let err = outcome(&mut rt, &key, |rt| rt.new_task(&key, task)).expect("refused");
    assert!(err.stderr.contains("already exists"), "{err}");
    settle_worktrees(&mut rt, &key);
    assert!(
        rt.repo(&key).unwrap().branch("doomed").is_none(),
        "branch rolled back"
    );
    assert_eq!(worktree_paths(&rt, &key).len(), 1);
    assert_eq!(fs::read_to_string(path.join("keep.txt")).unwrap(), "mine\n");
}

#[test]
fn cleanup_finds_merged_and_gone_worktrees_and_removes_them() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.add_remote();
    // merged: at main. gone: pushed, then deleted on the remote. active:
    // its own commit. dirty: merged but with a local change.
    let merged = repo.add_worktree("merged", "wt merged");
    let gone = repo.add_worktree("gone", "wt gone");
    repo.command_in(&gone)
        .args([
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "squashed elsewhere",
        ])
        .run()
        .unwrap();
    repo.git(&["push", "--quiet", "-u", "origin", "gone"]);
    repo.git(&["push", "--quiet", "origin", "--delete", "gone"]);
    repo.git(&["fetch", "--quiet", "--prune", "origin"]);
    let active = repo.add_worktree("active", "wt active");
    repo.command_in(&active)
        .args(["commit", "--quiet", "--allow-empty", "-m", "work"])
        .run()
        .unwrap();
    let dirty = repo.add_worktree("dirty", "wt dirty");
    fs::write(dirty.join("a.txt"), "changed\n").unwrap();
    let (mut rt, key) = open(&repo);
    settle_worktrees(&mut rt, &key);

    rt.load_cleanup(&key).expect("scan starts");
    poll_until(&mut rt, |_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::CleanupLoaded { .. }))
    });
    let mut found: Vec<(String, CleanupReason)> = rt
        .repo(&key)
        .unwrap()
        .cleanup()
        .unwrap()
        .iter()
        .map(|c| (c.branch.clone(), c.reason))
        .collect();
    found.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(
        found,
        [
            ("dirty".to_owned(), CleanupReason::Merged),
            ("gone".to_owned(), CleanupReason::UpstreamGone),
            ("merged".to_owned(), CleanupReason::Merged),
        ]
    );

    // Without force the dirty one fails; the others still go.
    let items = vec![
        (merged.clone(), "merged".to_owned(), false),
        (gone.clone(), "gone".to_owned(), false),
        (dirty.clone(), "dirty".to_owned(), false),
    ];
    let err = outcome(&mut rt, &key, |rt| rt.cleanup(&key, items, true)).expect("dirty refuses");
    assert!(err.stderr.contains("modified or untracked"), "{err}");
    settle_worktrees(&mut rt, &key);
    let state = rt.repo(&key).unwrap();
    assert!(!merged.exists() && !gone.exists() && dirty.exists());
    assert!(state.branch("merged").is_none() && state.branch("gone").is_none());
    assert!(state.branch("dirty").is_some() && state.branch("active").is_some());
}

#[test]
fn a_deleted_worktree_folder_is_reported_once() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let linked = repo.add_worktree("linked", "lïnked");
    let mut config = Config::default();
    config.auto_fetch_minutes = 0;
    let mut rt = Runtime::with_runner(config, None, repo.app_runner());
    let key = rt.open(&linked);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).and_then(|s| s.status()).is_some()
    });
    assert_eq!(rt.repo(&key).unwrap().display_name(), "wörk tree/lïnked");

    // On Windows a refresh running in the folder (started by the deletion
    // itself) briefly blocks removing it, as it would for Explorer: retry.
    for attempt in 0.. {
        match fs::remove_dir_all(&linked) {
            Ok(()) => break,
            Err(err) if attempt < 100 => {
                let _ = err;
                rt.poll();
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(err) => panic!("cannot delete the worktree folder: {err}"),
        }
    }
    rt.on_focus(&key);
    let mut events = poll_until(&mut rt, |rt, _| rt.repo(&key).unwrap().is_missing());
    // Later refreshes are not tried; the ones already queued fail quietly.
    rt.on_focus(&key);
    events.extend(poll_until(&mut rt, |rt, _| rt.pending_jobs() == 0));
    events.extend(rt.poll());
    let missing = events
        .iter()
        .filter(|e| matches!(e, RuntimeEvent::Missing { .. }))
        .count();
    let failed = events
        .iter()
        .any(|e| matches!(e, RuntimeEvent::RefreshFailed { .. }));
    assert!(missing == 1 && !failed, "{events:#?}");
}

#[test]
fn badges_follow_changes_made_in_another_open_worktree() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let linked = repo.add_worktree("linked", "linked");
    let (mut rt, main_key) = open(&repo);
    let linked_key = rt.open(&linked);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&linked_key).and_then(|s| s.status()).is_some()
            && rt.repo(&main_key).and_then(|s| s.worktrees()).is_some()
    });
    fs::write(linked.join("new.txt"), "x\n").unwrap();
    rt.on_focus(&linked_key);
    poll_until(&mut rt, |rt, _| {
        let main = rt.repo(&main_key).unwrap();
        let path = main.worktrees().unwrap()[1].path.clone();
        main.worktree_badge(&path).is_some_and(|b| b.changed == 1)
    });
}
