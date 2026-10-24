//! Branches, tags, checkout (with the dirty-tree stash flow) and
//! cherry-pick (M5) through the runtime, on temporary repositories.

mod support;

use std::fs;
use std::path::Path;

use gitbello_core::git::GitErrorKind;
use gitbello_core::ops::{CheckoutTarget, RefOp};
use gitbello_core::repo::{Operation, RefKind};
use gitbello_core::runtime::Runtime;
use support::rt::{finish, ok, open, outcome};
use support::TestRepo;

fn head_branch(rt: &Runtime, key: &Path) -> Option<String> {
    rt.repo(key)?.current_branch().map(str::to_owned)
}

fn has_ref(rt: &Runtime, key: &Path, name: &str) -> bool {
    rt.repo(key)
        .and_then(|s| s.refs())
        .is_some_and(|refs| refs.iter().any(|r| r.name == name))
}

fn branch(name: &str) -> CheckoutTarget {
    CheckoutTarget::Branch(name.to_owned())
}

#[test]
fn create_rename_and_delete_branches() {
    let repo = TestRepo::init();
    let first = repo.commit("a.txt", "a\n", "first");
    repo.commit("a.txt", "b\n", "second");
    let (mut rt, key) = open(&repo);

    let create = RefOp::CreateBranch {
        name: "old/start".into(),
        start: first.clone(),
        checkout: false,
    };
    ok(&mut rt, &key, |rt| rt.ref_op(&key, create));
    let state = rt.repo(&key).unwrap();
    assert_eq!(
        state.branch("old/start").map(|r| r.target.clone()),
        Some(first)
    );
    assert_eq!(head_branch(&rt, &key).as_deref(), Some("main"));

    let job = rt.ref_op(
        &key,
        RefOp::CreateBranch {
            name: "old/start".into(),
            start: "main".into(),
            checkout: false,
        },
    );
    let err = finish(&mut rt, &key, job).expect("exists");
    assert_eq!(err.kind, GitErrorKind::AlreadyExists, "{err}");

    let create_and_switch = RefOp::CreateBranch {
        name: "töpic".into(),
        start: "main".into(),
        checkout: true,
    };
    ok(&mut rt, &key, |rt| rt.ref_op(&key, create_and_switch));
    assert_eq!(head_branch(&rt, &key).as_deref(), Some("töpic"));

    let rename = RefOp::RenameBranch {
        old: "töpic".into(),
        new: "renamed".into(),
    };
    ok(&mut rt, &key, |rt| rt.ref_op(&key, rename));
    assert_eq!(head_branch(&rt, &key).as_deref(), Some("renamed"));
    assert!(!has_ref(&rt, &key, "refs/heads/töpic"));

    // `old/start` is behind main, so merged: a plain delete works. A branch
    // with its own commit needs force.
    let delete = |name: &str, force| RefOp::DeleteBranch {
        name: name.into(),
        force,
    };
    ok(&mut rt, &key, |rt| {
        rt.ref_op(&key, delete("old/start", false))
    });
    assert!(!has_ref(&rt, &key, "refs/heads/old/start"));
    repo.commit("u.txt", "u\n", "unmerged work");
    ok(&mut rt, &key, |rt| rt.checkout(&key, branch("main"), false));
    let err = outcome(&mut rt, &key, |rt| {
        rt.ref_op(&key, delete("renamed", false))
    })
    .expect("unmerged");
    assert_eq!(err.kind, GitErrorKind::NotFullyMerged, "{err}");
    ok(&mut rt, &key, |rt| rt.ref_op(&key, delete("renamed", true)));
    assert!(!has_ref(&rt, &key, "refs/heads/renamed"));
}

#[test]
fn checkout_remote_branches_detached_commits_and_upstreams() {
    let repo = TestRepo::init();
    let first = repo.commit("a.txt", "a\n", "first");
    let remote = repo.add_remote();
    let other = repo.clone_remote(&remote, "other");
    repo.command_in(&other)
        .args(["switch", "--quiet", "-c", "shared"])
        .run()
        .unwrap();
    repo.push_from(&other, "s.txt", "s\n", "shared work");
    repo.git(&["fetch", "--quiet", "origin"]);
    let (mut rt, key) = open(&repo);

    let track = CheckoutTarget::Track {
        remote_ref: "refs/remotes/origin/shared".into(),
        local: "shared".into(),
    };
    ok(&mut rt, &key, |rt| rt.checkout(&key, track, false));
    assert_eq!(head_branch(&rt, &key).as_deref(), Some("shared"));
    let state = rt.repo(&key).unwrap();
    assert_eq!(
        state.upstream_of("shared"),
        Some(("origin".to_owned(), "shared".to_owned()))
    );
    assert!(state.can_pull());

    let unset = RefOp::SetUpstream {
        branch: "shared".into(),
        upstream: None,
    };
    ok(&mut rt, &key, |rt| rt.ref_op(&key, unset));
    assert_eq!(rt.repo(&key).unwrap().upstream_of("shared"), None);
    let set = RefOp::SetUpstream {
        branch: "shared".into(),
        upstream: Some("origin/main".into()),
    };
    ok(&mut rt, &key, |rt| rt.ref_op(&key, set));
    assert_eq!(
        rt.repo(&key).unwrap().upstream_of("shared"),
        Some(("origin".to_owned(), "main".to_owned()))
    );

    ok(&mut rt, &key, |rt| {
        rt.checkout(&key, CheckoutTarget::Detach(first.clone()), false)
    });
    assert_eq!(head_branch(&rt, &key), None);
    assert_eq!(repo.head(), first);
}

#[test]
fn dirty_checkout_is_refused_then_stashes_and_reapplies() {
    let repo = TestRepo::init();
    let lines: String = (1..=10).map(|n| format!("line {n}\n")).collect();
    repo.commit("f.txt", &lines, "ten lines");
    repo.branch("topic");
    repo.checkout("topic");
    repo.commit(
        "f.txt",
        &lines.replace("line 1\n", "topic 1\n"),
        "topic edit",
    );
    repo.checkout("main");
    // Local edits: line 10 of a file that differs on topic (so the switch
    // refuses), a staged new file and an untracked one.
    repo.write("f.txt", &lines.replace("line 10\n", "local 10\n"));
    repo.write("staged.txt", "staged\n");
    repo.git(&["add", "staged.txt"]);
    repo.write("untracked.txt", "untracked\n");
    let (mut rt, key) = open(&repo);

    let err = outcome(&mut rt, &key, |rt| {
        rt.checkout(&key, branch("topic"), false)
    })
    .expect("dirty");
    assert_eq!(err.kind, GitErrorKind::LocalChanges, "{err}");
    assert_eq!(head_branch(&rt, &key).as_deref(), Some("main"));

    ok(&mut rt, &key, |rt| rt.checkout(&key, branch("topic"), true));
    assert_eq!(head_branch(&rt, &key).as_deref(), Some("topic"));
    let f = fs::read_to_string(repo.path().join("f.txt")).unwrap();
    assert!(
        f.starts_with("topic 1\n") && f.ends_with("local 10\n"),
        "{f}"
    );
    assert_eq!(
        fs::read_to_string(repo.path().join("untracked.txt")).unwrap(),
        "untracked\n"
    );
    // The staged file is staged again (`stash pop --index`).
    assert_eq!(repo.git(&["diff", "--cached", "--name-only"]), "staged.txt");
    assert_eq!(repo.git(&["stash", "list"]), "", "the stash was popped");
}

#[test]
fn stash_flow_keeps_the_stash_when_reapplying_conflicts() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "base\n", "base");
    repo.branch("topic");
    repo.checkout("topic");
    repo.commit("f.txt", "topic\n", "topic edit");
    repo.checkout("main");
    repo.write("f.txt", "local\n");
    let (mut rt, key) = open(&repo);

    let err =
        outcome(&mut rt, &key, |rt| rt.checkout(&key, branch("topic"), true)).expect("conflict");
    assert_eq!(err.kind, GitErrorKind::Conflict, "{err}");
    assert_eq!(head_branch(&rt, &key).as_deref(), Some("topic"));
    assert!(
        repo.git(&["stash", "list"])
            .contains("gitbello: switching to topic"),
        "the changes stay in the stash"
    );
}

#[test]
fn stash_flow_puts_changes_back_when_the_switch_fails() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "base\n", "base");
    repo.write("f.txt", "local\n");
    let (mut rt, key) = open(&repo);
    let err = outcome(&mut rt, &key, |rt| {
        rt.checkout(&key, branch("no-such-branch"), true)
    })
    .expect("fails");
    assert_ne!(err.kind, GitErrorKind::Conflict, "{err}");
    assert_eq!(
        fs::read_to_string(repo.path().join("f.txt")).unwrap(),
        "local\n"
    );
    assert_eq!(repo.git(&["stash", "list"]), "");
}

#[test]
fn checkout_of_a_branch_used_by_another_worktree_is_classified() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.add_worktree("elsewhere", "wörktree");
    let (mut rt, key) = open(&repo);
    let err = outcome(&mut rt, &key, |rt| {
        rt.checkout(&key, branch("elsewhere"), false)
    })
    .expect("busy");
    assert_eq!(err.kind, GitErrorKind::CheckedOutElsewhere, "{err}");
}

#[test]
fn tags_are_created_pushed_and_deleted() {
    let repo = TestRepo::init();
    let first = repo.commit("a.txt", "a\n", "first");
    let remote = repo.add_remote();
    let (mut rt, key) = open(&repo);

    let light = RefOp::CreateTag {
        name: "v0.1".into(),
        target: first.clone(),
        message: None,
    };
    ok(&mut rt, &key, |rt| rt.ref_op(&key, light));
    let annotated = RefOp::CreateTag {
        name: "v1.0".into(),
        target: "HEAD".into(),
        message: Some("Release ünïcode\n\nNotes.".into()),
    };
    ok(&mut rt, &key, |rt| rt.ref_op(&key, annotated));
    let tags: Vec<_> = rt
        .repo(&key)
        .unwrap()
        .refs()
        .unwrap()
        .iter()
        .filter(|r| r.kind == RefKind::Tag)
        .map(|r| (r.short_name.clone(), r.peeled.is_some()))
        .collect();
    assert_eq!(
        tags,
        [("v0.1".to_owned(), false), ("v1.0".to_owned(), true)]
    );
    assert_eq!(
        repo.git(&["tag", "-l", "--format=%(contents:subject)", "v1.0"]),
        "Release ünïcode"
    );

    ok(&mut rt, &key, |rt| rt.push_tag(&key, "v1.0"));
    let remote_tags = repo.git(&["ls-remote", "--tags", &support::path_arg(&remote)]);
    assert!(remote_tags.contains("refs/tags/v1.0"), "{remote_tags}");

    let delete = RefOp::DeleteTag {
        name: "v0.1".into(),
    };
    ok(&mut rt, &key, |rt| rt.ref_op(&key, delete));
    assert!(!has_ref(&rt, &key, "refs/tags/v0.1"));
}

#[test]
fn cherry_picks_commits_merges_and_aborts_conflicts() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "base");
    repo.branch("side");
    repo.checkout("side");
    let pick = repo.commit("p.txt", "picked\n", "to pick");
    repo.branch("merge-src");
    repo.checkout("merge-src");
    repo.commit("m.txt", "m\n", "merged in");
    repo.checkout("side");
    let merge = repo.merge("merge-src", "a merge");
    let clash = repo.commit("a.txt", "side\n", "clashes");
    repo.checkout("main");
    repo.commit("a.txt", "main\n", "main edit");
    let (mut rt, key) = open(&repo);

    ok(&mut rt, &key, |rt| {
        rt.ref_op(&key, RefOp::CherryPick { commit: pick })
    });
    assert!(repo.path().join("p.txt").is_file());
    assert_eq!(repo.git(&["log", "-1", "--format=%s"]), "to pick");

    // A merge commit is picked against its first parent.
    ok(&mut rt, &key, |rt| {
        rt.ref_op(&key, RefOp::CherryPick { commit: merge })
    });
    assert!(repo.path().join("m.txt").is_file());

    let err = outcome(&mut rt, &key, |rt| {
        rt.ref_op(&key, RefOp::CherryPick { commit: clash })
    })
    .expect("conflict");
    assert_eq!(err.kind, GitErrorKind::Conflict, "{err}");
    support::rt::poll_until(&mut rt, |rt, _| {
        rt.repo(&key).unwrap().operation() == Some(Operation::CherryPick)
    });
    ok(&mut rt, &key, |rt| {
        rt.ref_op(&key, RefOp::Abort(Operation::CherryPick))
    });
    assert_eq!(rt.repo(&key).unwrap().operation(), None);
    assert_eq!(
        fs::read_to_string(repo.path().join("a.txt")).unwrap(),
        "main\n"
    );
}
