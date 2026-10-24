mod support;

use std::io::Read;

use gitbello_core::git::{GitErrorKind, GitRunner, MIN_GIT_VERSION};
use support::TestRepo;

#[test]
fn discovers_a_supported_git() {
    let runner = GitRunner::discover().unwrap();
    assert!(runner.version() >= MIN_GIT_VERSION);
    assert!(runner.executable().is_file());
}

#[test]
fn with_executable_reports_a_missing_binary() {
    let err = GitRunner::with_executable("definitely-not-git-gitbello").unwrap_err();
    assert_eq!(err.kind, GitErrorKind::GitNotFound);
}

#[test]
fn runs_in_a_path_with_spaces_and_unicode() {
    let repo = TestRepo::init();
    let top = repo.git(&["rev-parse", "--show-toplevel"]);
    assert!(top.ends_with("wörk tree"), "{top}");
}

#[test]
fn passes_commit_messages_through_stdin() {
    let repo = TestRepo::init();
    let message = "Ünïcode subject\n\nBody with \"quotes\" and $dollars";
    repo.commit("a.txt", "a\n", message);
    assert_eq!(repo.git(&["log", "-1", "--format=%B"]), message);
}

#[test]
fn classifies_not_a_repository() {
    let repo = TestRepo::init();
    let err = repo
        .runner()
        .read(&repo.non_repo_dir())
        .args(["rev-parse", "HEAD"])
        .run()
        .unwrap_err();
    assert_eq!(err.kind, GitErrorKind::NotARepository);
    assert_eq!(err.exit_code, Some(128));
    assert_eq!(err.command, "rev-parse HEAD");
}

#[test]
fn classifies_a_held_index_lock() {
    let repo = TestRepo::init();
    std::fs::write(repo.path().join("f.txt"), "x").unwrap();
    std::fs::write(repo.path().join(".git").join("index.lock"), "").unwrap();
    let err = repo.try_git(&["add", "f.txt"]).unwrap_err();
    assert_eq!(err.kind, GitErrorKind::LockExists);
}

#[test]
fn streams_output_and_reports_exit_status() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.commit("a.txt", "b\n", "second");

    let mut stream = repo
        .runner()
        .read(repo.path())
        .args(["log", "--format=%s"])
        .stream()
        .unwrap();
    let mut out = String::new();
    stream.read_to_string(&mut out).unwrap();
    stream.finish().unwrap();
    assert_eq!(out, "second\nfirst\n");

    let failing = repo
        .runner()
        .read(repo.path())
        .args(["log", "no-such-ref"])
        .stream()
        .unwrap();
    let err = failing.finish().unwrap_err();
    assert_eq!(err.exit_code, Some(128));
    assert!(err.stderr.contains("no-such-ref"), "{}", err.stderr);
}

#[test]
fn never_prompts_or_opens_an_editor() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    // Without -m or -F, git would launch an editor; the no-op editor leaves the
    // message empty, so git aborts instead of hanging.
    std::fs::write(repo.path().join("a.txt"), "changed\n").unwrap();
    repo.git(&["add", "a.txt"]);
    let err = repo.try_git(&["commit"]).unwrap_err();
    assert!(
        err.stderr.contains("empty commit message"),
        "{}",
        err.stderr
    );
}
