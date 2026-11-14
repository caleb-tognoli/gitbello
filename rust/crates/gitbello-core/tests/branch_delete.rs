//! Deleting branches with their remote branch and worktree, what the delete
//! dialog is told first, undo, deleting remote branches and tags on the
//! remote, and cleanup with remote branches, on temporary repositories with
//! a local bare remote.

use crate::support;

use std::path::Path;

use gitbello_core::git::GitErrorKind;
use gitbello_core::runtime::{BranchDelete, RemoteBranch, Runtime, RuntimeEvent};
use support::rt::{finish, ok, open, poll_until};
use support::{path_arg, TestRepo};

fn has_ref(rt: &Runtime, key: &Path, name: &str) -> bool {
    rt.repo(key)
        .and_then(|s| s.refs())
        .is_some_and(|refs| refs.iter().any(|r| r.name == name))
}

/// Whether the bare `remote` has branch `name`.
fn remote_has(repo: &TestRepo, remote: &Path, name: &str) -> Option<String> {
    let git_dir = format!("--git-dir={}", path_arg(remote));
    repo.try_git(&[
        &git_dir,
        "rev-parse",
        "--verify",
        "--quiet",
        &format!("refs/heads/{name}"),
    ])
    .ok()
    .map(|out| out.stdout_text().trim().to_owned())
    .filter(|oid| !oid.is_empty())
}

fn origin(branch: &str) -> RemoteBranch {
    RemoteBranch {
        remote: "origin".into(),
        branch: branch.into(),
    }
}

/// `main` pushed to `origin`, and `topic` with one commit of its own,
/// pushed with its upstream, plus one more commit not pushed.
fn repo_with_topic() -> (TestRepo, std::path::PathBuf, String) {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let remote = repo.add_remote();
    repo.git(&["switch", "--quiet", "-c", "topic"]);
    let pushed = repo.commit("t.txt", "1\n", "topic 1");
    repo.git(&["push", "--quiet", "-u", "origin", "topic"]);
    repo.commit("t.txt", "2\n", "topic 2");
    repo.git(&["switch", "--quiet", "main"]);
    (repo, remote, pushed)
}

fn load_info(rt: &mut Runtime, key: &Path, branch: &str) {
    let job = rt.load_branch_delete_info(key, branch).expect("info job");
    poll_until(rt, |_, events| {
        events
            .iter()
            .any(|e| matches!(e, RuntimeEvent::BranchDeleteInfoLoaded { job: j, .. } if *j == job))
    });
}

#[test]
fn delete_info_counts_what_would_be_lost() {
    let (repo, _remote, _) = repo_with_topic();
    let worktree = repo.add_worktree("wt", "wört tree");
    let (mut rt, key) = open(&repo);

    load_info(&mut rt, &key, "topic");
    let info = rt
        .repo(&key)
        .unwrap()
        .branch_delete_info()
        .cloned()
        .unwrap();
    assert_eq!(info.base.as_deref(), Some("main"));
    assert_eq!(info.not_in_base, 2);
    assert_eq!(info.ahead, 1);
    assert_eq!(info.remote, Some(origin("topic")));
    assert_eq!(info.worktree, None);
    assert!(!info.is_head);

    // Merged into a local main that is ahead of origin/main: nothing lost.
    repo.commit(
        "a.txt",
        "local
",
        "not pushed",
    );
    repo.git(&["branch", "merged-locally", "main"]);
    rt.refresh(&key, gitbello_core::jobs::RefreshSet::all());
    support::rt::settle(&mut rt, &key);
    load_info(&mut rt, &key, "merged-locally");
    let info = rt
        .repo(&key)
        .unwrap()
        .branch_delete_info()
        .cloned()
        .unwrap();
    assert_eq!(info.not_in_base, 0);

    load_info(&mut rt, &key, "wt");
    let info = rt
        .repo(&key)
        .unwrap()
        .branch_delete_info()
        .cloned()
        .unwrap();
    assert_eq!(info.not_in_base, 0);
    assert_eq!(info.remote, None);
    assert_eq!(
        info.worktree.map(|p| p.canonicalize().unwrap()),
        Some(worktree.canonicalize().unwrap())
    );

    load_info(&mut rt, &key, "main");
    let info = rt
        .repo(&key)
        .unwrap()
        .branch_delete_info()
        .cloned()
        .unwrap();
    assert!(info.is_head);
    assert_eq!(info.remote, Some(origin("main")));
}

#[test]
fn deletes_local_and_remote_then_undo_puts_both_back() {
    let (repo, remote, pushed) = repo_with_topic();
    let local = repo.git(&["rev-parse", "topic"]).trim().to_owned();
    let (mut rt, key) = open(&repo);

    let delete = BranchDelete {
        branch: Some("topic".into()),
        remote: Some(origin("topic")),
        worktree: None,
    };
    // Not merged anywhere: deleted all the same (the dialog said so).
    ok(&mut rt, &key, |rt| rt.delete_branch(&key, delete));
    assert!(!has_ref(&rt, &key, "refs/heads/topic"));
    assert!(!has_ref(&rt, &key, "refs/remotes/origin/topic"));
    assert_eq!(remote_has(&repo, &remote, "topic"), None);
    assert!(rt.repo(&key).unwrap().can_undo_branch_delete("topic"));

    ok(&mut rt, &key, |rt| rt.undo_branch_delete(&key, "topic"));
    assert_eq!(repo.git(&["rev-parse", "topic"]).trim(), local);
    assert_eq!(
        remote_has(&repo, &remote, "topic").as_deref(),
        Some(pushed.as_str())
    );
    assert_eq!(
        repo.git(&["rev-parse", "--abbrev-ref", "topic@{upstream}"])
            .trim(),
        "origin/topic"
    );
    assert!(!rt.repo(&key).unwrap().can_undo_branch_delete("topic"));
}

#[test]
fn undo_never_overwrites_a_branch_made_since() {
    let (repo, remote, _) = repo_with_topic();
    let (mut rt, key) = open(&repo);
    let delete = BranchDelete {
        branch: Some("topic".into()),
        remote: Some(origin("topic")),
        worktree: None,
    };
    ok(&mut rt, &key, |rt| rt.delete_branch(&key, delete));

    // Someone pushes another `topic`; a local `topic` is created too.
    let other = repo.clone_remote(&remote, "other");
    repo.command_in(&other)
        .args(["switch", "--quiet", "-c", "topic"])
        .run()
        .unwrap();
    repo.push_from(&other, "o.txt", "o\n", "someone else's topic");
    repo.command_in(&other)
        .args(["push", "--quiet", "origin", "topic"])
        .run()
        .unwrap();
    let theirs = remote_has(&repo, &remote, "topic").unwrap();
    repo.git(&["branch", "topic", "main"]);

    let job = rt.undo_branch_delete(&key, "topic");
    let err = finish(&mut rt, &key, job).expect("refused");
    assert_eq!(err.kind, GitErrorKind::AlreadyExists, "{err}");
    assert_eq!(remote_has(&repo, &remote, "topic"), Some(theirs.clone()));

    // Without the local one in the way, the push back is refused instead.
    repo.git(&["branch", "-D", "topic"]);
    let job = rt.undo_branch_delete(&key, "topic");
    assert!(finish(&mut rt, &key, job).is_some(), "push back refused");
    assert_eq!(remote_has(&repo, &remote, "topic"), Some(theirs));
}

#[test]
fn a_remote_that_lost_the_branch_already_is_fine() {
    let (repo, remote, _) = repo_with_topic();
    let git_dir = format!("--git-dir={}", path_arg(&remote));
    repo.git(&[&git_dir, "branch", "-D", "topic"]);
    let (mut rt, key) = open(&repo);
    assert!(has_ref(&rt, &key, "refs/remotes/origin/topic"));

    let delete = BranchDelete {
        branch: Some("topic".into()),
        remote: Some(origin("topic")),
        worktree: None,
    };
    ok(&mut rt, &key, |rt| rt.delete_branch(&key, delete));
    assert!(!has_ref(&rt, &key, "refs/heads/topic"));
    assert!(!has_ref(&rt, &key, "refs/remotes/origin/topic"));

    // Undo puts back what this repository showed: both.
    ok(&mut rt, &key, |rt| rt.undo_branch_delete(&key, "topic"));
    assert!(has_ref(&rt, &key, "refs/heads/topic"));
    assert!(remote_has(&repo, &remote, "topic").is_some());
}

#[test]
fn a_failed_remote_delete_keeps_the_local_branch() {
    let (repo, _remote, _) = repo_with_topic();
    let (mut rt, key) = open(&repo);
    repo.git(&["remote", "set-url", "origin", "../no such remote.git"]);
    let delete = BranchDelete {
        branch: Some("topic".into()),
        remote: Some(origin("topic")),
        worktree: None,
    };
    let job = rt.delete_branch(&key, delete);
    assert!(finish(&mut rt, &key, job).is_some());
    assert!(has_ref(&rt, &key, "refs/heads/topic"));
}

#[test]
fn deletes_a_worktree_with_its_branch_and_remote_branch() {
    let (repo, remote, _) = repo_with_topic();
    let worktree = repo.add_worktree("wt", "wört tree");
    repo.git(&["push", "--quiet", "-u", "origin", "wt"]);
    let (mut rt, key) = open(&repo);

    let delete = BranchDelete {
        branch: Some("wt".into()),
        remote: Some(origin("wt")),
        worktree: Some((worktree.clone(), false)),
    };
    ok(&mut rt, &key, |rt| rt.delete_branch(&key, delete));
    assert!(!worktree.exists());
    assert!(!has_ref(&rt, &key, "refs/heads/wt"));
    assert_eq!(remote_has(&repo, &remote, "wt"), None);

    // The branch comes back; the folder does not.
    ok(&mut rt, &key, |rt| rt.undo_branch_delete(&key, "wt"));
    assert!(has_ref(&rt, &key, "refs/heads/wt"));
    assert!(remote_has(&repo, &remote, "wt").is_some());
    assert!(!worktree.exists());
}

#[test]
fn deletes_a_remote_branch_alone_and_undoes_it() {
    let (repo, remote, pushed) = repo_with_topic();
    let (mut rt, key) = open(&repo);
    let delete = BranchDelete {
        branch: None,
        remote: Some(origin("topic")),
        worktree: None,
    };
    ok(&mut rt, &key, |rt| rt.delete_branch(&key, delete));
    assert!(has_ref(&rt, &key, "refs/heads/topic"));
    assert_eq!(remote_has(&repo, &remote, "topic"), None);
    assert!(rt
        .repo(&key)
        .unwrap()
        .can_undo_branch_delete("origin/topic"));

    ok(&mut rt, &key, |rt| {
        rt.undo_branch_delete(&key, "origin/topic")
    });
    assert_eq!(remote_has(&repo, &remote, "topic"), Some(pushed));
}

#[test]
fn deletes_a_tag_on_the_remote_too() {
    let (repo, remote, _) = repo_with_topic();
    repo.git(&["tag", "v1", "main"]);
    repo.git(&["tag", "v2", "main"]);
    repo.git(&["push", "--quiet", "origin", "v1"]);
    let (mut rt, key) = open(&repo);
    let git_dir = format!("--git-dir={}", path_arg(&remote));
    let remote_tags = || repo.git(&[&git_dir, "tag", "--list"]);

    ok(&mut rt, &key, |rt| {
        rt.delete_tag(&key, "v1", Some("origin".into()))
    });
    assert!(!has_ref(&rt, &key, "refs/tags/v1"));
    assert!(!remote_tags().contains("v1"));
    // Never pushed: fine.
    ok(&mut rt, &key, |rt| {
        rt.delete_tag(&key, "v2", Some("origin".into()))
    });
    assert!(!has_ref(&rt, &key, "refs/tags/v2"));
}

#[test]
fn cleanup_deletes_remote_branches_too() {
    let (repo, remote, _) = repo_with_topic();
    let worktree = repo.add_worktree("merged", "mérged");
    repo.git(&["push", "--quiet", "-u", "origin", "merged"]);
    let (mut rt, key) = open(&repo);
    let items = vec![(worktree.clone(), "merged".to_owned(), false)];
    ok(&mut rt, &key, |rt| rt.cleanup(&key, items, true, true));
    assert!(!worktree.exists());
    assert!(!has_ref(&rt, &key, "refs/heads/merged"));
    assert_eq!(remote_has(&repo, &remote, "merged"), None);
}
