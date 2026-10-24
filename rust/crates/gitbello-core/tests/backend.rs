mod support;

use std::path::PathBuf;

use gitbello_core::backend::{CliBackend, GitBackend};
use gitbello_core::git::{CancelToken, GitErrorKind};
use gitbello_core::repo::{Change, Conflict, FileState, Head, Operation, RefKind};
use support::TestRepo;

fn backend(repo: &TestRepo) -> CliBackend {
    CliBackend::new(repo.runner().clone())
}

fn no_cancel() -> CancelToken {
    CancelToken::new()
}

#[test]
fn status_reports_staged_unstaged_untracked_and_renames() {
    let repo = TestRepo::init();
    repo.commit("keep.txt", "keep\n", "base");
    repo.commit("old näme.txt", "rename me\n", "to rename");
    repo.write("keep.txt", "changed\n");
    repo.write("staged.txt", "new\n");
    repo.git(&["add", "staged.txt"]);
    repo.git(&["mv", "old näme.txt", "new näme.txt"]);
    repo.write("dir/ünïcode file.txt", "u\n");

    let status = backend(&repo).status(repo.path(), &no_cancel()).unwrap();
    assert_eq!(status.head, Head::Branch("main".into()));
    let find = |p: &str| {
        status
            .changes
            .iter()
            .find(|c| c.path == std::path::Path::new(p))
            .unwrap_or_else(|| panic!("{p} missing from {:#?}", status.changes))
    };
    assert_eq!(
        find("keep.txt").state,
        FileState::Tracked {
            index: Change::Unmodified,
            worktree: Change::Modified
        }
    );
    assert!(find("staged.txt").is_staged());
    let renamed = find("new näme.txt");
    assert_eq!(renamed.original_path, Some(PathBuf::from("old näme.txt")));
    assert_eq!(find("dir/ünïcode file.txt").state, FileState::Untracked);
}

#[test]
fn status_on_unborn_and_detached_heads() {
    let repo = TestRepo::init();
    let unborn = backend(&repo).status(repo.path(), &no_cancel()).unwrap();
    assert_eq!(unborn.oid, None);
    assert!(unborn.is_clean());

    repo.commit("a.txt", "a\n", "first");
    repo.detach();
    let detached = backend(&repo).status(repo.path(), &no_cancel()).unwrap();
    assert_eq!(detached.head, Head::Detached);
    assert_eq!(detached.oid, Some(repo.head()));
}

#[test]
fn status_tracks_upstream_and_stash_count() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.add_remote();
    repo.commit("a.txt", "b\n", "ahead one");
    repo.stash("a.txt", "stashed\n", "my stash");

    let status = backend(&repo).status(repo.path(), &no_cancel()).unwrap();
    assert_eq!(status.upstream.as_deref(), Some("origin/main"));
    assert_eq!((status.ahead, status.behind), (1, 0));
    assert_eq!(status.stash_count, 1);
}

#[test]
fn conflicted_merge_shows_unmerged_entries_and_operation() {
    let repo = TestRepo::init();
    repo.start_conflicting_merge("clash.txt");
    let backend = backend(&repo);
    let status = backend.status(repo.path(), &no_cancel()).unwrap();
    assert!(status.has_conflicts());
    assert_eq!(
        status.changes[0].state,
        FileState::Unmerged(Conflict::BothModified)
    );
    assert_eq!(
        backend.operation(repo.path(), &no_cancel()).unwrap(),
        Some(Operation::Merge)
    );
    repo.git(&["merge", "--abort"]);
    assert_eq!(backend.operation(repo.path(), &no_cancel()).unwrap(), None);
}

#[test]
fn refs_cover_branches_remotes_tags_and_stash() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.add_remote();
    repo.git(&["tag", "light"]);
    repo.git(&["tag", "-a", "-m", "annotated", "v1.0"]);
    repo.branch("feature/wörk");
    repo.commit("a.txt", "b\n", "ahead");
    repo.stash("a.txt", "c\n", "s");

    let refs = backend(&repo).refs(repo.path(), &no_cancel()).unwrap();
    let get = |name: &str| {
        refs.iter()
            .find(|r| r.name == name)
            .unwrap_or_else(|| panic!("{name} missing from {refs:#?}"))
    };
    let main = get("refs/heads/main");
    assert!(main.is_head);
    assert_eq!(main.tracking.ahead, 1);
    assert_eq!(
        main.worktree.as_deref().map(|p| p.ends_with("wörk tree")),
        Some(true)
    );
    assert_eq!(get("refs/heads/feature/wörk").short_name, "feature/wörk");
    assert_eq!(
        get("refs/remotes/origin/main").kind,
        RefKind::RemoteBranch {
            remote: "origin".into()
        }
    );
    let tag = get("refs/tags/v1.0");
    assert!(tag.peeled.is_some() && tag.peeled.as_deref() != Some(tag.target.as_str()));
    assert_eq!(get("refs/tags/light").peeled, None);
    assert_eq!(get("refs/stash").kind, RefKind::Stash);
}

#[test]
fn worktrees_list_main_and_linked_with_lock() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let linked = repo.add_worktree("feature/x", "lïnked wt");
    repo.git(&[
        "worktree",
        "lock",
        "--reason",
        "on usb",
        &support::path_arg(&linked),
    ]);

    let backend = backend(&repo);
    let wts = backend.worktrees(repo.path(), &no_cancel()).unwrap();
    assert_eq!(wts.len(), 2, "{wts:#?}");
    assert!(wts[0].is_main);
    assert_eq!(wts[0].branch_name(), Some("main"));
    assert_eq!(wts[1].branch_name(), Some("feature/x"));
    assert!(wts[1].path.ends_with("lïnked wt"), "{:?}", wts[1].path);
    assert_eq!(wts[1].locked.as_deref(), Some("on usb"));

    // Paths from inside the linked worktree resolve to its own git dir.
    let paths = backend.repo_paths(&linked, &no_cancel()).unwrap();
    assert_ne!(paths.git_dir, paths.common_dir);
    assert!(!paths.bare);
    let status = backend.status(&linked, &no_cancel()).unwrap();
    assert_eq!(status.head, Head::Branch("feature/x".into()));
}

#[test]
fn stash_list_has_messages_and_branches() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.stash("a.txt", "one\n", "first stash");
    repo.stash("a.txt", "two\n", "sëcond stash");
    let stashes = backend(&repo).stashes(repo.path(), &no_cancel()).unwrap();
    assert_eq!(stashes.len(), 2);
    assert_eq!(stashes[0].index, 0);
    assert_eq!(stashes[0].message, "sëcond stash");
    assert_eq!(stashes[1].message, "first stash");
    assert_eq!(stashes[0].branch.as_deref(), Some("main"));
}

#[test]
fn ignored_returns_only_ignored_paths() {
    let repo = TestRepo::init();
    repo.commit(".gitignore", "target/\n*.log\n", "ignore");
    let backend = backend(&repo);
    let paths = vec![
        PathBuf::from("target/debug/x.o"),
        PathBuf::from("src/main.rs"),
        PathBuf::from("büild.log"),
    ];
    let ignored = backend.ignored(repo.path(), &paths, &no_cancel()).unwrap();
    assert_eq!(
        ignored,
        vec![
            PathBuf::from("target/debug/x.o"),
            PathBuf::from("büild.log")
        ]
    );
    let none = backend
        .ignored(repo.path(), &[PathBuf::from("src/main.rs")], &no_cancel())
        .unwrap();
    assert!(none.is_empty());
}

#[test]
fn reads_fail_with_classified_errors_outside_a_repository() {
    let repo = TestRepo::init();
    let err = backend(&repo)
        .status(&repo.non_repo_dir(), &no_cancel())
        .unwrap_err();
    assert_eq!(err.kind, GitErrorKind::NotARepository);
}
