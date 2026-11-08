//! Compare (PLAN M7.12) on real repositories: sides, modes, counts, files
//! and their diffs, through the backend and the runtime.

mod support;

use std::path::{Path, PathBuf};

use gitbello_core::backend::{CliBackend, GitBackend};
use gitbello_core::compare::{
    CompareMode, CompareRequest, CompareSide, Comparison, OnlyOn, SideKind,
};
use gitbello_core::diff::{DiffContent, DiffKind, LineKind};
use gitbello_core::git::{CancelToken, GitErrorKind};
use gitbello_core::jobs::{RefreshKind, RefreshSet};
use gitbello_core::merge::FileChoice;
use gitbello_core::ops::RefOp;
use gitbello_core::repo::Change;
use gitbello_core::runtime::{DiffSlot, RuntimeEvent};
use support::rt::{ok, open, outcome, poll_until, settle};
use support::TestRepo;

fn backend(repo: &TestRepo) -> CliBackend {
    CliBackend::new(repo.app_runner())
}

fn compare(
    repo: &TestRepo,
    left: &str,
    right: CompareSide,
    mode: Option<CompareMode>,
) -> Comparison {
    let request = CompareRequest {
        left: left.to_owned(),
        right,
        mode,
    };
    backend(repo)
        .compare(repo.path(), &request, &CancelToken::new())
        .unwrap_or_else(|err| panic!("compare {left}: {err}"))
}

fn rev(spec: &str) -> CompareSide {
    CompareSide::Rev(spec.to_owned())
}

fn paths(cmp: &Comparison) -> Vec<(Change, String)> {
    cmp.files
        .iter()
        .map(|f| (f.change, f.path.to_string_lossy().replace('\\', "/")))
        .collect()
}

/// `main` and `topic` both move on after `topic` splits off.
fn diverged() -> TestRepo {
    let repo = TestRepo::init();
    repo.commit("shared.txt", "one\ntwo\nthree\n", "Base");
    repo.branch("topic");
    repo.commit("main only.txt", "main\n", "Main moves on");
    repo.checkout("topic");
    repo.commit("tópic file.txt", "a\nb\n", "Topic adds a file");
    repo.commit("shared.txt", "one\nTWO\nthree\n", "Topic edits shared");
    repo.checkout("main");
    repo
}

#[test]
fn branches_since_fork_and_exact() {
    let repo = diverged();
    let cmp = compare(&repo, "main", rev("topic"), None);
    assert_eq!(cmp.left.kind, SideKind::Branch);
    assert_eq!(cmp.right.kind, SideKind::Branch);
    assert_eq!(cmp.left.name(), "main");
    assert_eq!(cmp.right.name(), "topic");
    assert_eq!(cmp.default_mode, CompareMode::SinceFork);
    assert_eq!(cmp.mode, CompareMode::SinceFork);
    assert!(cmp.can_fork());
    assert_eq!(cmp.merge_base.as_deref(), Some(cmp.base.as_str()));
    assert_eq!((cmp.only_right, cmp.only_left), (2, 1));
    assert_eq!(
        paths(&cmp),
        vec![
            (Change::Modified, "shared.txt".to_owned()),
            (Change::Added, "tópic file.txt".to_owned()),
        ],
        "since fork leaves out what main did meanwhile"
    );
    let shared = cmp.file(Path::new("shared.txt")).unwrap();
    assert_eq!(shared.stats, Some((1, 1)));
    assert_eq!((cmp.additions, cmp.deletions), (3, 1));

    let exact = compare(&repo, "main", rev("topic"), Some(CompareMode::Exact));
    assert_eq!(exact.mode, CompareMode::Exact);
    assert_eq!(exact.base, exact.left.oid.clone().unwrap());
    assert_eq!(
        paths(&exact),
        vec![
            (Change::Deleted, "main only.txt".to_owned()),
            (Change::Modified, "shared.txt".to_owned()),
            (Change::Added, "tópic file.txt".to_owned()),
        ],
        "exact shows main's newer file as removed"
    );
}

#[test]
fn tags_and_commits_also_compare_since_the_fork() {
    let repo = TestRepo::init();
    let first = repo.commit("a.txt", "1\n", "One");
    repo.git(&["tag", "v1"]);
    repo.commit("a.txt", "1\n2\n", "Two");
    let cmp = compare(&repo, "v1", rev("HEAD"), None);
    assert_eq!(cmp.left.kind, SideKind::Tag);
    assert_eq!(cmp.left.name(), "v1");
    assert_eq!(cmp.right.kind, SideKind::Branch, "HEAD names the branch");
    assert_eq!(cmp.mode, CompareMode::SinceFork);
    assert_eq!((cmp.only_right, cmp.only_left), (1, 0));
    assert_eq!(paths(&cmp), vec![(Change::Modified, "a.txt".to_owned())]);

    let by_hash = compare(&repo, &first, rev("HEAD~0"), None);
    assert_eq!(by_hash.left.kind, SideKind::Commit);
    assert_eq!(by_hash.left.name(), &first[..7]);
    assert_eq!(by_hash.right.kind, SideKind::Commit);
    assert_eq!(by_hash.right.name(), "HEAD~0");
}

#[test]
fn unrelated_histories_force_exact() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "Main root");
    repo.git(&["checkout", "--quiet", "--orphan", "other"]);
    repo.git(&["rm", "-rfq", "."]);
    repo.commit("b.txt", "b\n", "Other root");
    repo.checkout("main");
    let cmp = compare(&repo, "main", rev("other"), Some(CompareMode::SinceFork));
    assert!(!cmp.can_fork());
    assert_eq!(cmp.default_mode, CompareMode::SinceFork);
    assert_eq!(cmp.mode, CompareMode::Exact, "no merge base: exact");
    assert_eq!((cmp.only_right, cmp.only_left), (1, 1));
    assert_eq!(
        paths(&cmp),
        vec![
            (Change::Deleted, "a.txt".to_owned()),
            (Change::Added, "b.txt".to_owned()),
        ]
    );
}

#[test]
fn renames_are_listed_once_with_counts() {
    let repo = TestRepo::init();
    let content = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\n";
    repo.commit("old name.txt", content, "Add");
    repo.git(&["tag", "start"]);
    std::fs::create_dir(repo.path().join("dir")).unwrap();
    repo.git(&["mv", "old name.txt", "dir/nëw name.txt"]);
    repo.write("dir/nëw name.txt", &format!("{content}line 7\n"));
    repo.git(&["add", "-A"]);
    repo.git(&["commit", "-q", "-m", "Rename"]);
    let cmp = compare(&repo, "start", rev("HEAD"), None);
    assert_eq!(cmp.files.len(), 1);
    let file = &cmp.files[0];
    assert_eq!(file.change, Change::Renamed);
    assert_eq!(file.path, PathBuf::from("dir/nëw name.txt"));
    assert_eq!(file.original_path, Some(PathBuf::from("old name.txt")));
    assert_eq!(file.stats, Some((1, 0)));

    let target = cmp.target(file);
    assert_eq!(target.kind, DiffKind::Commit);
    let diff = backend(&repo)
        .diff(repo.path(), &target, None, &CancelToken::new())
        .unwrap();
    let added: Vec<&[u8]> = diff
        .lines(0, 99)
        .filter(|l| l.kind == LineKind::Added)
        .map(|l| l.text)
        .collect();
    assert_eq!(added, [b"line 7"]);
}

#[test]
fn working_copy_against_a_branch() {
    let repo = diverged();
    repo.checkout("topic");
    repo.write("shared.txt", "one\nTWO\nthree\nfour\n");
    repo.write("ünträcked.txt", "x\ny\nz\n");
    std::fs::remove_file(repo.path().join("tópic file.txt")).unwrap();
    let cmp = compare(&repo, "main", CompareSide::WorkingCopy, None);
    assert_eq!(cmp.right.kind, SideKind::WorkingCopy);
    assert_eq!(cmp.right.name(), "");
    assert_eq!(cmp.default_mode, CompareMode::SinceFork);
    assert_eq!((cmp.only_right, cmp.only_left), (2, 1), "counted from HEAD");
    assert_eq!(
        paths(&cmp),
        vec![
            (Change::Modified, "shared.txt".to_owned()),
            (Change::Added, "ünträcked.txt".to_owned()),
        ],
        "the deleted topic file was never on the fork point"
    );
    let shared = cmp.file(Path::new("shared.txt")).unwrap();
    assert_eq!(shared.stats, Some((2, 1)));
    assert!(!shared.untracked);
    let untracked = cmp.file(Path::new("ünträcked.txt")).unwrap();
    assert!(untracked.untracked);
    assert_eq!(untracked.stats, Some((3, 0)));
    assert_eq!(cmp.target(untracked).kind, DiffKind::Untracked);

    let target = cmp.target(shared);
    assert_eq!(target.kind, DiffKind::Working);
    let diff = backend(&repo)
        .diff(repo.path(), &target, None, &CancelToken::new())
        .unwrap();
    let changed: Vec<(LineKind, &[u8])> = diff
        .lines(0, 99)
        .filter(|l| matches!(l.kind, LineKind::Added | LineKind::Removed))
        .map(|l| (l.kind, l.text))
        .collect();
    assert_eq!(
        changed,
        vec![
            (LineKind::Removed, &b"two"[..]),
            (LineKind::Added, &b"TWO"[..]),
            (LineKind::Added, &b"four"[..]),
        ]
    );

    let exact = compare(
        &repo,
        "main",
        CompareSide::WorkingCopy,
        Some(CompareMode::Exact),
    );
    assert!(paths(&exact).contains(&(Change::Deleted, "main only.txt".to_owned())));
}

#[test]
fn binary_sizes_use_the_compare_base() {
    let repo = TestRepo::init();
    repo.commit("pic.bin", "\0one", "One");
    repo.git(&["tag", "v1"]);
    repo.commit("pic.bin", "\0two two", "Two");
    repo.commit("other.txt", "x\n", "Three");
    let cmp = compare(&repo, "v1", rev("HEAD"), None);
    let file = cmp.file(Path::new("pic.bin")).unwrap();
    assert_eq!(file.stats, None, "binary files have no line counts");
    let diff = backend(&repo)
        .diff(repo.path(), &cmp.target(file), None, &CancelToken::new())
        .unwrap();
    assert_eq!(
        diff.content,
        DiffContent::Binary {
            old_size: Some(4),
            new_size: Some(8)
        },
        "the old side is the base, not the right side's parent"
    );
}

#[test]
fn unknown_and_option_like_revisions_fail() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "One");
    let b = backend(&repo);
    for spec in ["nope", "--output=x", "", "  "] {
        let request = CompareRequest {
            left: spec.to_owned(),
            right: CompareSide::WorkingCopy,
            mode: None,
        };
        let err = b
            .compare(repo.path(), &request, &CancelToken::new())
            .expect_err("should fail");
        assert_eq!(err.kind, GitErrorKind::UnknownRevision, "{spec:?}: {err}");
    }
    assert!(!repo.path().join("x").exists());
}

#[test]
fn working_copy_on_an_unborn_branch_compares_against_the_left() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "One");
    repo.git(&["checkout", "--quiet", "--orphan", "fresh"]);
    let cmp = compare(&repo, "main", CompareSide::WorkingCopy, None);
    assert_eq!(cmp.right.oid, None);
    assert_eq!(cmp.mode, CompareMode::Exact);
    assert_eq!((cmp.only_right, cmp.only_left), (0, 1));
    assert_eq!(paths(&cmp), vec![], "the index still holds a.txt");
}

#[test]
fn runtime_opens_filters_and_diffs_a_comparison() {
    let repo = diverged();
    let (mut rt, key) = open(&repo);
    rt.open_compare(
        &key,
        CompareRequest {
            left: "main".to_owned(),
            right: rev("topic"),
            mode: None,
        },
    );
    let loaded = |rt: &gitbello_core::runtime::Runtime| {
        rt.repo(&key)
            .and_then(|s| s.compare())
            .is_some_and(|c| !c.is_loading() && c.comparison().is_some())
    };
    let events = poll_until(&mut rt, |rt, _| loaded(rt));
    assert!(events
        .iter()
        .any(|e| matches!(e, RuntimeEvent::CompareChanged { .. })));
    let state = rt.repo(&key).unwrap().compare().unwrap();
    assert_eq!(state.shown_count(), 2);
    assert_eq!(state.shown_index(Path::new("tópic file.txt")), Some(1));

    rt.set_compare_filter(&key, "TÓPIC");
    let state = rt.repo(&key).unwrap().compare().unwrap();
    assert_eq!(state.shown_count(), 1);
    assert_eq!(
        state.shown_file(0).unwrap().path,
        PathBuf::from("tópic file.txt")
    );
    rt.set_compare_filter(&key, "");

    rt.select_compare_file(&key, Some(Path::new("shared.txt")), false);
    poll_until(&mut rt, |rt, ev| {
        ev.iter().any(|e| {
            matches!(
                e,
                RuntimeEvent::DiffChanged {
                    slot: DiffSlot::Compare,
                    ..
                }
            )
        }) && rt
            .repo(&key)
            .and_then(|s| s.compare_diff())
            .is_some_and(|d| d.diff().is_some())
    });
    let diff = rt.repo(&key).unwrap().compare_diff().unwrap();
    assert_eq!(diff.target().kind, DiffKind::Commit);
    assert!(diff.layout().row_count(false) > 0);

    rt.set_compare_mode(&key, Some(CompareMode::Exact));
    poll_until(&mut rt, |rt, _| {
        loaded(rt)
            && rt
                .repo(&key)
                .and_then(|s| s.compare())
                .and_then(|c| c.comparison())
                .is_some_and(|c| c.mode == CompareMode::Exact)
    });
    let state = rt.repo(&key).unwrap();
    assert_eq!(state.compare().unwrap().shown_count(), 3);
    assert!(
        state.compare_diff().is_none(),
        "the base changed: the old diff is dropped"
    );

    rt.open_compare(
        &key,
        CompareRequest {
            left: "nope".to_owned(),
            right: rev("topic"),
            mode: None,
        },
    );
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.compare())
            .is_some_and(|c| c.error().is_some())
    });
    let error = rt.repo(&key).unwrap().compare().unwrap().error().unwrap();
    assert_eq!(error.kind, GitErrorKind::UnknownRevision);

    rt.close_compare(&key);
    assert!(rt.repo(&key).unwrap().compare().is_none());
}

fn request(left: &str, right: CompareSide) -> CompareRequest {
    CompareRequest {
        left: left.to_owned(),
        right,
        mode: None,
    }
}

/// Opens `request` in the runtime and waits for its result.
fn open_loaded(rt: &mut gitbello_core::runtime::Runtime, key: &Path, request: CompareRequest) {
    rt.open_compare(key, request);
    wait_loaded(rt, key);
}

fn wait_loaded(rt: &mut gitbello_core::runtime::Runtime, key: &Path) {
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .and_then(|s| s.compare())
            .is_some_and(|c| !c.is_loading() && c.comparison().is_some())
    });
}

fn shown_paths(rt: &gitbello_core::runtime::Runtime, key: &Path) -> Vec<String> {
    let compare = rt
        .repo(key)
        .expect("repo open")
        .compare()
        .expect("comparison open");
    (0..compare.shown_count())
        .map(|i| {
            compare
                .shown_file(i)
                .expect("file in range")
                .path
                .to_string_lossy()
                .replace('\\', "/")
        })
        .collect()
}

#[test]
fn commits_are_listed_per_side_and_marked_when_head_has_them() {
    let repo = diverged();
    let cmp = compare(&repo, "main", rev("topic"), None);
    let listed: Vec<(&str, OnlyOn, bool)> = cmp
        .commits
        .iter()
        .map(|c| (c.subject.as_str(), c.only, c.in_head))
        .collect();
    assert_eq!(
        listed,
        vec![
            ("Topic edits shared", OnlyOn::Right, false),
            ("Topic adds a file", OnlyOn::Right, false),
            ("Main moves on", OnlyOn::Left, true),
        ]
    );
    assert!(!cmp.commits_truncated);
    assert!(cmp.commits.iter().all(|c| c.parents == 1 && c.time > 0));
    // Against the working copy the right side is HEAD: its commits are
    // HEAD's, the left side's are not.
    let working = compare(&repo, "topic", CompareSide::WorkingCopy, None);
    assert!(working
        .commits
        .iter()
        .all(|c| c.in_head == (c.only == OnlyOn::Right)));
    assert_eq!(working.commits.len(), 3);
}

#[test]
fn a_commit_narrows_the_files_to_its_own() {
    let repo = diverged();
    let root = repo
        .git(&["rev-list", "--max-parents=0", "HEAD"])
        .trim()
        .to_owned();
    let first = backend(&repo)
        .compare_commit(repo.path(), &root, &CancelToken::new())
        .unwrap();
    assert_eq!(
        paths(&first),
        vec![(Change::Added, "shared.txt".to_owned())]
    );
    assert!(first.left.oid.is_none(), "a root commit has no parent");

    let (mut rt, key) = open(&repo);
    open_loaded(&mut rt, &key, request("main", rev("topic")));
    assert_eq!(shown_paths(&rt, &key), vec!["shared.txt", "tópic file.txt"]);
    let adds = repo.git(&["rev-parse", "topic~1"]).trim().to_owned();
    rt.focus_compare_commit(&key, Some(&adds));
    assert!(rt.repo(&key).unwrap().compare().unwrap().focus_loading());
    assert!(shown_paths(&rt, &key).is_empty(), "nothing while it loads");
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.compare())
            .is_some_and(|c| !c.focus_loading())
    });
    assert_eq!(shown_paths(&rt, &key), vec!["tópic file.txt"]);
    let details = rt
        .repo(&key)
        .and_then(|s| s.compare())
        .and_then(|c| c.focus_details())
        .expect("the commit's details load with its files");
    assert_eq!(details.oid, adds);
    assert!(details.message.starts_with("Topic adds a file"));
    let listed = rt.repo(&key).and_then(|s| s.compare()).and_then(|c| {
        let index = c.commit_index(&adds)?;
        c.commit(index).cloned()
    });
    let listed = listed.expect("the commit is listed");
    assert!(!listed.email.is_empty(), "rows carry the author's email");
    rt.select_compare_file(&key, Some(Path::new("tópic file.txt")), false);
    let target = rt
        .repo(&key)
        .unwrap()
        .compare_diff()
        .unwrap()
        .target()
        .clone();
    let commit = target.commit.unwrap();
    assert_eq!(commit.oid, adds);
    assert_eq!(
        commit.parent.as_deref(),
        Some(repo.git(&["rev-parse", "topic~2"]).trim())
    );
    rt.focus_compare_commit(&key, None);
    assert_eq!(shown_paths(&rt, &key), vec!["shared.txt", "tópic file.txt"]);
    assert!(
        rt.repo(&key).unwrap().compare_diff().is_none(),
        "the commit's diff is not the comparison's"
    );
}

#[test]
fn restore_from_a_side_backs_up_and_undoes() {
    let repo = diverged();
    let (mut rt, key) = open(&repo);
    open_loaded(&mut rt, &key, request("main", rev("topic")));
    let shared = repo.path().join("shared.txt");
    let topic_file = repo.path().join("tópic file.txt");
    std::fs::write(&shared, "local edit\n").unwrap();
    ok(&mut rt, &key, |rt| {
        rt.restore_compare_files(
            &key,
            &[PathBuf::from("shared.txt"), PathBuf::from("tópic file.txt")],
            OnlyOn::Right,
        )
    });
    assert_eq!(
        std::fs::read_to_string(&shared).unwrap(),
        "one\nTWO\nthree\n"
    );
    assert_eq!(std::fs::read_to_string(&topic_file).unwrap(), "a\nb\n");
    assert_eq!(
        repo.git(&["diff", "--cached", "--name-only"]).trim(),
        "",
        "the index is left alone"
    );
    assert!(rt.repo(&key).unwrap().can_undo_discard());
    ok(&mut rt, &key, |rt| rt.undo_discard(&key));
    assert_eq!(std::fs::read_to_string(&shared).unwrap(), "local edit\n");
    assert!(!topic_file.exists(), "a file the restore created goes away");

    // The left side lacks the topic's file: restoring it deletes it.
    std::fs::write(&topic_file, "draft\n").unwrap();
    ok(&mut rt, &key, |rt| {
        rt.restore_compare_files(&key, &[PathBuf::from("tópic file.txt")], OnlyOn::Left)
    });
    assert!(!topic_file.exists());
    ok(&mut rt, &key, |rt| rt.undo_discard(&key));
    assert_eq!(std::fs::read_to_string(&topic_file).unwrap(), "draft\n");

    open_loaded(&mut rt, &key, request("main", CompareSide::WorkingCopy));
    assert!(
        rt.restore_compare_files(&key, &[PathBuf::from("shared.txt")], OnlyOn::Right)
            .is_none(),
        "the working copy cannot restore from itself"
    );
}

#[test]
fn sides_follow_the_working_copy_and_the_refs() {
    let repo = diverged();
    let (mut rt, key) = open(&repo);
    open_loaded(&mut rt, &key, request("main", CompareSide::WorkingCopy));
    assert!(shown_paths(&rt, &key).is_empty());
    std::fs::write(repo.path().join("new file.txt"), "x\n").unwrap();
    rt.refresh(&key, RefreshSet::EMPTY.with(RefreshKind::Status));
    poll_until(&mut rt, |rt, _| shown_paths(rt, &key) == ["new file.txt"]);

    open_loaded(&mut rt, &key, request("main", rev("topic")));
    assert_eq!(
        rt.repo(&key)
            .unwrap()
            .compare()
            .unwrap()
            .comparison()
            .unwrap()
            .only_right,
        2
    );
    repo.git(&["branch", "-f", "topic", "main"]);
    settle(&mut rt, &key);
    wait_loaded(&mut rt, &key);
    let cmp = rt
        .repo(&key)
        .unwrap()
        .compare()
        .unwrap()
        .comparison()
        .unwrap()
        .clone();
    assert_eq!((cmp.only_right, cmp.only_left), (0, 0));
    assert!(cmp.files.is_empty());
}

#[test]
fn several_commits_cherry_pick_and_continue_after_a_conflict() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "base\n", "Base");
    repo.branch("topic");
    repo.commit("a.txt", "main\n", "Main edits a");
    repo.checkout("topic");
    let first = repo.commit("b.txt", "b\n", "Add b");
    let second = repo.commit("a.txt", "topic\n", "Topic edits a");
    let third = repo.commit("c.txt", "c\n", "Add c");
    repo.checkout("main");
    let (mut rt, key) = open(&repo);
    let error = outcome(&mut rt, &key, |rt| {
        rt.ref_op(
            &key,
            RefOp::CherryPick {
                commits: vec![first, second, third],
            },
        )
    })
    .expect("the second pick conflicts");
    assert_eq!(error.kind, GitErrorKind::Conflict);
    settle(&mut rt, &key);
    assert!(repo.path().join("b.txt").exists(), "the first pick landed");
    ok(&mut rt, &key, |rt| {
        rt.resolve_file(&key, Path::new("a.txt"), FileChoice::Theirs)
    });
    ok(&mut rt, &key, |rt| rt.continue_operation(&key, None));
    assert!(rt.repo(&key).unwrap().operation().is_none());
    assert!(repo.path().join("c.txt").exists(), "the rest was applied");
    assert_eq!(
        repo.git(&["log", "--format=%s", "-3"]).trim(),
        "Add c\nTopic edits a\nAdd b"
    );
}
