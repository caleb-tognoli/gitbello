//! History editing through the runtime, on temporary repositories: which
//! commits can be edited, each one-shot action, local changes, conflicts
//! and undo.

use crate::support;

use std::fs;
use std::path::Path;

use gitbello_core::git::GitErrorKind;
use gitbello_core::history_edit::{RewriteAction, RewriteBlock, RewriteKind, RewriteStop};
use gitbello_core::repo::Operation;
use gitbello_core::runtime::Runtime;
use support::rt::{ok, open, outcome, poll_until, settle};
use support::TestRepo;

/// `main` with `base` pushed to a remote; `feat` adds `a`, `b` and `c`
/// (one file each) and is checked out.
fn branch() -> TestRepo {
    let repo = TestRepo::init();
    repo.commit("base.txt", "base\n", "base");
    repo.add_remote();
    repo.branch("feat");
    repo.checkout("feat");
    repo.commit("a.txt", "a\n", "add a");
    repo.commit("b.txt", "b\n", "add b");
    repo.commit("c.txt", "c\n", "add c");
    repo
}

/// Subjects from HEAD back to (not including) `base`.
fn subjects(repo: &TestRepo) -> Vec<String> {
    repo.git(&["log", "--format=%s", "main..HEAD"])
        .lines()
        .map(str::to_owned)
        .collect()
}

fn oid(repo: &TestRepo, rev: &str) -> String {
    repo.git(&["rev-parse", rev]).trim().to_owned()
}

/// Waits until the rewritable commits are read for the current HEAD.
fn ready(rt: &mut Runtime, key: &Path, repo: &TestRepo) {
    let head = repo.head();
    settle(rt, key);
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .and_then(|s| s.rewritable())
            .is_some_and(|l| l.head == head)
    });
}

fn edit(rt: &mut Runtime, key: &Path, repo: &TestRepo, rev: &str, action: RewriteAction) {
    ready(rt, key, repo);
    let oid = oid(repo, rev);
    ok(rt, key, |rt| rt.rewrite_history(key, &oid, action));
    settle(rt, key);
}

fn read(repo: &TestRepo, file: &str) -> Option<String> {
    fs::read_to_string(repo.path().join(file))
        .ok()
        .map(|t| t.replace("\r\n", "\n"))
}

#[test]
fn lists_the_branch_own_commits() {
    let repo = branch();
    let (mut rt, key) = open(&repo);
    ready(&mut rt, &key, &repo);
    let state = rt.repo(&key).unwrap();
    let list = state.rewritable().unwrap();
    let subjects: Vec<&str> = list.commits.iter().map(|c| c.subject.as_str()).collect();
    assert_eq!(subjects, ["add c", "add b", "add a"]);
    assert_eq!(list.stop, RewriteStop::Base);
    assert!(list.commits.iter().all(|c| !c.pushed));
    let base = oid(&repo, "main");
    assert_eq!(
        state.rewrite_reach(&base, &RewriteAction::Drop),
        Err(RewriteBlock::OnBase)
    );
    let a = oid(&repo, "HEAD~2");
    assert_eq!(state.rewrite_reach(&a, &RewriteAction::Drop), Ok((3, 0)));
    assert_eq!(
        state.rewrite_reach(&a, &RewriteAction::Fixup),
        Err(RewriteBlock::NoParent)
    );
}

#[test]
fn rewords_and_undoes() {
    let repo = branch();
    let before = repo.head();
    let (mut rt, key) = open(&repo);
    edit(
        &mut rt,
        &key,
        &repo,
        "HEAD~1",
        RewriteAction::Reword("Add b, reworded\n\nWith a body".into()),
    );
    assert_eq!(subjects(&repo), ["add c", "Add b, reworded", "add a"]);
    assert_eq!(
        repo.git(&["log", "-1", "--format=%b", "HEAD~1"]).trim(),
        "With a body"
    );
    assert_eq!(read(&repo, "c.txt").as_deref(), Some("c\n"));
    // The undo strip offers the edit.
    let after = repo.head();
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).and_then(|s| s.rebase_undo()).is_some()
    });
    let undo = rt.repo(&key).unwrap().rebase_undo().cloned().unwrap();
    assert_eq!(
        (undo.before.as_str(), undo.after.as_str()),
        (before.as_str(), after.as_str())
    );
    let done = undo.rewrite.expect("a history edit");
    assert_eq!(done.kind, RewriteKind::Reword);
    assert_eq!(done.subject, "Add b, reworded");
    ok(&mut rt, &key, |rt| rt.undo_rebase(&key));
    assert_eq!(repo.head(), before);
    assert!(!repo.path().join(".git/gitbello-rewrite").exists());
}

#[test]
fn squashes_fixes_up_and_drops() {
    let repo = branch();
    let (mut rt, key) = open(&repo);
    edit(
        &mut rt,
        &key,
        &repo,
        "HEAD~1",
        RewriteAction::Squash("Add a and b".into()),
    );
    assert_eq!(subjects(&repo), ["add c", "Add a and b"]);
    assert_eq!(
        repo.git(&["show", "--format=", "--name-only", "HEAD~1"])
            .trim(),
        "a.txt\nb.txt"
    );

    edit(&mut rt, &key, &repo, "HEAD", RewriteAction::Fixup);
    assert_eq!(subjects(&repo), ["Add a and b"]);
    assert_eq!(read(&repo, "c.txt").as_deref(), Some("c\n"));

    repo.commit("d.txt", "d\n", "add d");
    edit(&mut rt, &key, &repo, "HEAD~1", RewriteAction::Drop);
    assert_eq!(subjects(&repo), ["add d"]);
    assert_eq!(read(&repo, "a.txt"), None);
    assert_eq!(read(&repo, "d.txt").as_deref(), Some("d\n"));
}

#[test]
fn moves_commits() {
    let repo = branch();
    let (mut rt, key) = open(&repo);
    edit(&mut rt, &key, &repo, "HEAD~2", RewriteAction::MoveUp);
    assert_eq!(subjects(&repo), ["add c", "add a", "add b"]);
    edit(&mut rt, &key, &repo, "HEAD", RewriteAction::MoveDown);
    assert_eq!(subjects(&repo), ["add a", "add c", "add b"]);
    ready(&mut rt, &key, &repo);
    let head = repo.head();
    assert_eq!(
        rt.repo(&key)
            .unwrap()
            .rewrite_reach(&head, &RewriteAction::MoveUp),
        Err(RewriteBlock::AtHead)
    );
}

#[test]
fn keeps_local_changes() {
    let repo = branch();
    repo.write("c.txt", "c\nlocal\n");
    repo.write("new.txt", "untracked\n");
    let (mut rt, key) = open(&repo);
    edit(&mut rt, &key, &repo, "HEAD~2", RewriteAction::Drop);
    assert_eq!(subjects(&repo), ["add c", "add b"]);
    assert_eq!(read(&repo, "c.txt").as_deref(), Some("c\nlocal\n"));
    assert_eq!(read(&repo, "new.txt").as_deref(), Some("untracked\n"));
    assert!(repo.git(&["stash", "list"]).trim().is_empty());
}

#[test]
fn stops_at_merges() {
    let repo = branch();
    repo.checkout("main");
    repo.commit("m.txt", "m\n", "on main");
    repo.checkout("feat");
    repo.merge("main", "merge main");
    repo.commit("d.txt", "d\n", "add d");
    let (mut rt, key) = open(&repo);
    ready(&mut rt, &key, &repo);
    let state = rt.repo(&key).unwrap();
    let list = state.rewritable().unwrap();
    assert_eq!(list.commits.len(), 1);
    assert_eq!(list.stop, RewriteStop::Merge);
    let a = oid(&repo, "HEAD~1^1~2");
    assert_eq!(
        state.rewrite_reach(&a, &RewriteAction::Drop),
        Err(RewriteBlock::PastMerge)
    );
    let head = repo.head();
    assert_eq!(
        state.rewrite_reach(&head, &RewriteAction::Fixup),
        Err(RewriteBlock::PastMerge)
    );
    assert_eq!(state.rewrite_reach(&head, &RewriteAction::Drop), Ok((1, 0)));
}

#[test]
fn edits_pushed_commits_on_the_default_branch() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.commit("b.txt", "b\n", "second");
    repo.add_remote();
    repo.commit("c.txt", "c\n", "third");
    let (mut rt, key) = open(&repo);
    ready(&mut rt, &key, &repo);
    let state = rt.repo(&key).unwrap();
    let list = state.rewritable().unwrap();
    assert_eq!(list.commits.len(), 3);
    assert_eq!(list.stop, RewriteStop::Root);
    let pushed: Vec<bool> = list.commits.iter().map(|c| c.pushed).collect();
    assert_eq!(pushed, [false, true, true]);
    let first = oid(&repo, "HEAD~2");
    assert_eq!(
        state.rewrite_reach(&first, &RewriteAction::Drop),
        Ok((3, 2))
    );

    // Dropping a pushed root commit; undo is offered though HEAD is not new.
    let before = repo.head();
    edit(&mut rt, &key, &repo, "HEAD~2", RewriteAction::Drop);
    assert_eq!(repo.git(&["log", "--format=%s"]).trim(), "third\nsecond");
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).and_then(|s| s.rebase_undo()).is_some()
    });
    ok(&mut rt, &key, |rt| rt.undo_rebase(&key));
    assert_eq!(repo.head(), before);

    // Dropping HEAD leaves the pushed commit: still undoable.
    edit(&mut rt, &key, &repo, "HEAD", RewriteAction::Drop);
    assert_eq!(repo.head(), oid(&repo, "origin/main"));
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).and_then(|s| s.rebase_undo()).is_some()
    });
}

#[test]
fn conflicts_leave_the_rebase_for_the_banner() {
    let repo = branch();
    repo.commit(
        "a.txt", "a
more
", "change a",
    );
    let (mut rt, key) = open(&repo);
    ready(&mut rt, &key, &repo);
    // Without "add a", "change a" has nothing to change.
    let add_a = oid(&repo, "HEAD~3");
    let err = outcome(&mut rt, &key, |rt| {
        rt.rewrite_history(&key, &add_a, RewriteAction::Drop)
    })
    .expect("conflicts");
    assert_eq!(err.kind, GitErrorKind::Conflict, "{err}");
    settle(&mut rt, &key);
    let state = rt.repo(&key).unwrap();
    assert!(matches!(
        state.operation(),
        Some(Operation::Rebase { interactive: true })
    ));
    assert!(state.rebase_undo().is_none());
    assert!(
        state.rewritable().is_none(),
        "no edits while one is in progress"
    );
    repo.git(&["rebase", "--abort"]);
}
