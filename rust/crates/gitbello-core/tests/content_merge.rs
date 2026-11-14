//! Branches merged by content (squashed or rebased into main), what the
//! delete dialogs are told about detached and rebasing worktrees, and
//! keeping a detached worktree's commits as a branch, on temporary
//! repositories.

mod support;

use std::path::Path;

use gitbello_core::backend::{CliBackend, ContentMerge, GitBackend};
use gitbello_core::git::CancelToken;
use gitbello_core::repo::Operation;
use gitbello_core::runtime::{BranchDeleteInfo, Runtime, RuntimeEvent, WorktreeDeleteInfo};
use gitbello_core::worktrees::CleanupReason;
use support::rt::{open, poll_until, settle, succeed};
use support::{path_arg, TestRepo};

/// `topic` with two commits off `main`.
fn repo_with_topic() -> TestRepo {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.git(&["switch", "--quiet", "-c", "topic"]);
    repo.commit("t.txt", "1\n", "topic 1");
    repo.commit("u.txt", "2\n", "topic 2");
    repo.git(&["switch", "--quiet", "main"]);
    repo.commit("m.txt", "main moved on\n", "main work");
    repo
}

/// Squashes `branch` into main as one new commit, as GitHub does.
fn squash_into_main(repo: &TestRepo, branch: &str) {
    repo.git(&["merge", "--squash", "--quiet", branch]);
    repo.command()
        .args(["commit", "--quiet", "-m", "Squashed (#1)"])
        .run()
        .expect("squash commit");
}

fn content(repo: &TestRepo, tip: &str) -> ContentMerge {
    let backend = CliBackend::new(repo.runner().clone());
    backend
        .merged_by_content(
            repo.path(),
            &["main".to_owned()],
            &[tip.to_owned()],
            500,
            &CancelToken::new(),
        )
        .expect("content check")[0]
}

fn delete_info(rt: &mut Runtime, key: &Path, branch: &str) -> BranchDeleteInfo {
    let job = rt.load_branch_delete_info(key, branch).expect("info job");
    // Known at once, without the merged check.
    let partial = rt
        .repo(key)
        .and_then(|s| s.branch_delete_info().cloned())
        .expect("partial info");
    assert!(!partial.checked);
    assert_eq!(partial.branch, branch);
    poll_until(rt, |_, events| {
        events
            .iter()
            .any(|e| matches!(e, RuntimeEvent::BranchDeleteInfoLoaded { job: j, .. } if *j == job))
    });
    rt.repo(key)
        .and_then(|s| s.branch_delete_info().cloned())
        .expect("info")
}

fn worktree_info(rt: &mut Runtime, key: &Path, path: &Path) -> WorktreeDeleteInfo {
    let job = rt.load_worktree_delete_info(key, path).expect("info job");
    poll_until(rt, |_, events| {
        events.iter().any(
            |e| matches!(e, RuntimeEvent::WorktreeDeleteInfoLoaded { job: j, .. } if *j == job),
        )
    });
    rt.repo(key)
        .expect("repo")
        .worktree_delete_info()
        .cloned()
        .expect("info")
}

#[test]
fn a_squashed_branch_is_merged() {
    let repo = repo_with_topic();
    assert_eq!(
        content(&repo, "topic"),
        ContentMerge {
            missing: 2,
            squashed: false
        }
    );
    squash_into_main(&repo, "topic");
    repo.commit("m.txt", "later\n", "after the squash");
    assert_eq!(
        content(&repo, "topic"),
        ContentMerge {
            missing: 0,
            squashed: true
        }
    );

    let (mut rt, key) = open(&repo);
    let info = delete_info(&mut rt, &key, "topic");
    assert!(info.checked);
    assert!(info.squashed);
    assert_eq!(info.not_in_base, 0);
}

#[test]
fn a_rebased_branch_is_merged_commit_by_commit() {
    let repo = repo_with_topic();
    repo.git(&["cherry-pick", "--quiet", "main..topic"]);
    assert_eq!(content(&repo, "topic"), ContentMerge::default());
    // One commit picked, the other not: only that one is missing.
    repo.git(&["switch", "--quiet", "-c", "half", "topic~1"]);
    repo.commit("h.txt", "h\n", "half only");
    repo.git(&["switch", "--quiet", "main"]);
    assert_eq!(content(&repo, "half").missing, 1);
}

#[test]
fn work_after_a_squash_is_plainly_not_merged() {
    let repo = repo_with_topic();
    squash_into_main(&repo, "topic");
    repo.git(&["switch", "--quiet", "topic"]);
    repo.commit("t.txt", "fix\n", "forgot this");
    repo.git(&["switch", "--quiet", "main"]);
    assert_eq!(
        content(&repo, "topic"),
        ContentMerge {
            missing: 3,
            squashed: false
        }
    );
}

#[test]
fn only_the_newest_base_commits_are_searched() {
    let repo = repo_with_topic();
    squash_into_main(&repo, "topic");
    for i in 0..3 {
        repo.commit("m.txt", &format!("{i}\n"), "later");
    }
    let backend = CliBackend::new(repo.runner().clone());
    let found = backend
        .merged_by_content(
            repo.path(),
            &["main".to_owned()],
            &["topic".to_owned()],
            2,
            &CancelToken::new(),
        )
        .unwrap();
    assert_eq!(found[0].missing, 2);
}

#[test]
fn cleanup_offers_squashed_branches() {
    let repo = repo_with_topic();
    let _remote = repo.add_remote();
    let wt = repo.sibling("wt topic");
    repo.git(&["worktree", "add", "--quiet", &path_arg(&wt), "topic"]);
    squash_into_main(&repo, "topic");
    repo.git(&["push", "--quiet", "origin", "main"]);
    let (mut rt, key) = open(&repo);
    settle(&mut rt, &key);
    rt.load_cleanup(&key).expect("scan starts");
    poll_until(&mut rt, |_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::CleanupLoaded { .. }))
    });
    let found: Vec<(String, CleanupReason)> = rt
        .repo(&key)
        .unwrap()
        .cleanup()
        .unwrap()
        .iter()
        .map(|c| (c.branch.clone(), c.reason))
        .collect();
    assert_eq!(found, [("topic".to_owned(), CleanupReason::Squashed)]);
}

#[test]
fn a_detached_worktree_keeps_its_commits_as_a_branch() {
    let repo = repo_with_topic();
    let wt = repo.sibling("détached");
    repo.git(&[
        "worktree",
        "add",
        "--quiet",
        "--detach",
        &path_arg(&wt),
        "main",
    ]);
    repo.command_in(&wt)
        .args(["commit", "--quiet", "--allow-empty", "-m", "on no branch"])
        .run()
        .unwrap();
    let head = repo.git(&["-C", &path_arg(&wt), "rev-parse", "HEAD"]);
    let (mut rt, key) = open(&repo);
    settle(&mut rt, &key);

    let info = worktree_info(&mut rt, &key, &wt);
    assert_eq!(info.unreferenced, 1);
    assert_eq!(info.operation, None);
    assert_eq!(info.branch, None);
    assert_eq!(info.head.as_deref(), Some(head.as_str()));

    let job = rt.remove_worktree_keeping(&key, wt.clone(), false, "rescued".into(), head.clone());
    succeed(&mut rt, &key, job);
    assert!(!wt.exists());
    assert_eq!(repo.git(&["rev-parse", "refs/heads/rescued"]), head);
}

#[test]
fn a_rebasing_worktree_names_its_branch() {
    let repo = repo_with_topic();
    let wt = repo.sibling("rebasing");
    repo.git(&["worktree", "add", "--quiet", &path_arg(&wt), "topic"]);
    // topic changes a.txt; main changes it too: the rebase stops.
    std::fs::write(wt.join("a.txt"), "topic\n").unwrap();
    repo.command_in(&wt)
        .args(["commit", "--quiet", "-am", "topic a"])
        .run()
        .unwrap();
    repo.commit("a.txt", "main\n", "main a");
    let stopped = repo.command_in(&wt).args(["rebase", "main"]).run();
    assert!(stopped.is_err(), "the rebase should stop on a conflict");
    let (mut rt, key) = open(&repo);
    settle(&mut rt, &key);

    let info = worktree_info(&mut rt, &key, &wt);
    assert!(matches!(info.operation, Some(Operation::Rebase { .. })));
    assert_eq!(info.branch.as_deref(), Some("topic"));
    assert_eq!(info.unreferenced, 0);
}
