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

#[test]
fn reports_progress_from_a_clone() {
    use std::sync::{Arc, Mutex};

    let repo = TestRepo::init();
    for i in 0..20 {
        repo.commit(&format!("f{i}.txt"), &"x".repeat(1000 + i), &format!("c{i}"));
    }
    let url = format!("file:///{}", support::path_arg(repo.path()).trim_start_matches('/'));
    let target = repo.sibling("clöne");
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&seen);
    repo.command()
        .args(["clone", "--progress", "--no-local", &url])
        .arg(support::path_arg(&target))
        .on_progress(move |p| sink.lock().unwrap().push(p))
        .run()
        .unwrap();
    let seen = seen.lock().unwrap();
    assert!(
        seen.iter().any(|p| p.phase.contains("objects") && p.percent == Some(100)),
        "{seen:#?}"
    );
}

#[test]
fn cancellation_kills_git_promptly() {
    use gitbello_core::git::CancelToken;
    use std::time::{Duration, Instant};

    let repo = TestRepo::init();
    let token = CancelToken::new();
    let canceller = token.clone();
    let started = Instant::now();
    let handle = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(200));
        canceller.cancel();
    });
    // A shell alias that would run for 10 seconds; its `sleep` child keeps the
    // pipes open even after git is killed.
    let err = repo
        .command()
        .args(["-c", "alias.slow=!sleep 10", "slow"])
        .cancel_token(&token)
        .run()
        .unwrap_err();
    handle.join().unwrap();
    assert_eq!(err.kind, GitErrorKind::Cancelled);
    assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
}

#[test]
fn does_not_wait_for_helpers_that_keep_pipes_open() {
    use std::time::{Duration, Instant};

    let repo = TestRepo::init();
    let started = Instant::now();
    // The alias exits at once but leaves a background `sleep` holding stdout/stderr.
    repo.command()
        .args(["-c", "alias.bg=!sleep 10 &", "bg"])
        .run()
        .unwrap();
    assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
}

#[test]
fn logs_every_command_with_outcome() {
    use gitbello_core::git::CommandOutcome;

    let repo = TestRepo::init();
    let runner = repo.runner().clone();
    let before = runner.log().records_since(0).last().map_or(0, |r| r.seq);
    runner.read(repo.path()).args(["rev-parse", "--git-dir"]).run().unwrap();
    let _ = runner.read(repo.path()).args(["rev-parse", "HEAD"]).run();
    let records = runner.log().records_since(before);
    assert_eq!(records.len(), 2, "{records:#?}");
    assert_eq!(records[0].command, "rev-parse --git-dir");
    assert_eq!(records[0].outcome, CommandOutcome::Succeeded);
    assert_eq!(records[0].repo, repo.path());
    assert!(matches!(records[1].outcome, CommandOutcome::Failed(_)));
    assert_eq!(records[1].exit_code, Some(128));
}

#[test]
fn large_output_does_not_deadlock() {
    let repo = TestRepo::init();
    let big = "line\n".repeat(400_000);
    repo.commit("big.txt", &big, "big");
    let out = repo
        .runner()
        .read(repo.path())
        .args(["show", "HEAD:big.txt"])
        .run()
        .unwrap();
    assert_eq!(out.stdout.len(), big.len());
}
