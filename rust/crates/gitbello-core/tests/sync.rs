//! Fetch, pull, push and auto-fetch (M5) through the runtime, against a
//! local bare remote that a second checkout pushes to.

use crate::support;

use std::fs;
use std::time::Duration;

use gitbello_core::config::Config;
use gitbello_core::git::GitErrorKind;
use gitbello_core::ops::{PullMode, UpstreamRewrite, AUTO_FETCH_JOB_LABEL};
use gitbello_core::runtime::{JobState, Runtime, RuntimeEvent};
use support::rt::{finish, open, poll_until, settle, succeed};
use support::TestRepo;

/// `main` pushed to a bare `origin`, plus a second clone of it.
fn shared() -> (TestRepo, std::path::PathBuf) {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let remote = repo.add_remote();
    let other = repo.clone_remote(&remote, "other clöne");
    (repo, other)
}

fn tracking(rt: &Runtime, key: &std::path::Path) -> (u32, u32) {
    let status = rt.repo(key).and_then(|s| s.status()).expect("status");
    (status.ahead, status.behind)
}

#[test]
fn fetch_reports_behind_and_pull_fast_forwards() {
    let (repo, other) = shared();
    repo.push_from(&other, "b.txt", "b\n", "from the other clone");
    let (mut rt, key) = open(&repo);
    assert_eq!(tracking(&rt, &key), (0, 0));
    assert!(rt.repo(&key).unwrap().can_fetch());
    assert_eq!(rt.repo(&key).unwrap().remotes(), ["origin"]);

    let job = rt.fetch(&key);
    assert_eq!(rt.fetch(&key), job, "a second fetch joins the running one");
    assert!(rt.repo(&key).unwrap().is_fetching());
    succeed(&mut rt, &key, job);
    assert!(!rt.repo(&key).unwrap().is_fetching());
    assert_eq!(tracking(&rt, &key), (0, 1));

    // Local changes survive the pull (autostash).
    repo.write("a.txt", "local edit\n");
    assert!(rt.repo(&key).unwrap().can_pull());
    let job = rt.pull(&key, None);
    succeed(&mut rt, &key, job);
    assert_eq!(tracking(&rt, &key), (0, 0));
    assert_eq!(
        fs::read_to_string(repo.path().join("b.txt")).unwrap(),
        "b\n"
    );
    assert_eq!(
        fs::read_to_string(repo.path().join("a.txt")).unwrap(),
        "local edit\n"
    );
}

#[test]
fn diverged_pull_refuses_then_merges_or_rebases() {
    let (repo, other) = shared();
    repo.push_from(&other, "b.txt", "b\n", "theirs");
    repo.commit("c.txt", "c\n", "ours");
    let (mut rt, key) = open(&repo);
    let job = rt.fetch(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(tracking(&rt, &key), (1, 1));

    let job = rt.pull(&key, Some(PullMode::FastForwardOnly));
    let err = finish(&mut rt, &key, job).expect("ff-only cannot pull diverged branches");
    assert_eq!(err.kind, GitErrorKind::Diverged, "{err}");

    let job = rt.pull(&key, Some(PullMode::Rebase));
    succeed(&mut rt, &key, job);
    assert_eq!(tracking(&rt, &key), (1, 0));
    let parents = repo.git(&["rev-list", "--parents", "-n", "1", "HEAD"]);
    assert_eq!(parents.split(' ').count(), 2, "rebased: no merge commit");

    // A merge pull from a fresh divergence makes a merge commit.
    repo.push_from(&other, "d.txt", "d\n", "theirs again");
    repo.commit("e.txt", "e\n", "ours again");
    let job = rt.fetch(&key);
    succeed(&mut rt, &key, job);
    let job = rt.pull(&key, Some(PullMode::Merge));
    succeed(&mut rt, &key, job);
    let parents = repo.git(&["rev-list", "--parents", "-n", "1", "HEAD"]);
    assert_eq!(parents.split(' ').count(), 3, "a merge commit");
    assert_eq!(tracking(&rt, &key).1, 0);
}

#[test]
fn push_updates_the_upstream_and_sets_one_for_new_branches() {
    let (repo, other) = shared();
    repo.commit("b.txt", "b\n", "to push");
    let (mut rt, key) = open(&repo);
    assert_eq!(tracking(&rt, &key), (1, 0));
    assert!(rt.repo(&key).unwrap().can_push());
    let job = rt.push(&key, None);
    succeed(&mut rt, &key, job);
    assert_eq!(tracking(&rt, &key), (0, 0));
    assert_eq!(
        repo.git(&["rev-parse", "refs/remotes/origin/main"]),
        repo.head()
    );

    // A branch without upstream is pushed under its own name and tracks it.
    repo.git(&["switch", "--quiet", "-c", "topic"]);
    repo.commit("t.txt", "t\n", "topic work");
    settle(&mut rt, &key);
    assert_eq!(rt.repo(&key).unwrap().upstream_of("topic"), None);
    let job = rt.push(&key, None);
    succeed(&mut rt, &key, job);
    assert_eq!(
        rt.repo(&key).unwrap().upstream_of("topic"),
        Some(("origin".to_owned(), "topic".to_owned()))
    );

    // Someone else pushed to main: our push is rejected as non-fast-forward.
    repo.git(&["switch", "--quiet", "main"]);
    repo.push_from(&other, "x.txt", "x\n", "theirs");
    repo.commit("y.txt", "y\n", "ours");
    settle(&mut rt, &key);
    let job = rt.push(&key, None);
    let err = finish(&mut rt, &key, job).expect("rejected");
    assert_eq!(err.kind, GitErrorKind::NonFastForward, "{err}");
}

/// Waits until HEAD's info (which says whether the branch was rewritten)
/// matches HEAD again, then returns the rewrite state.
fn rewrite_after_settle(
    rt: &mut Runtime,
    key: &std::path::Path,
    want: Option<UpstreamRewrite>,
) -> Option<UpstreamRewrite> {
    settle(rt, key);
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .expect("open repo")
            .history_tracking()
            .is_some()
            && rt.repo(key).expect("open repo").upstream_rewrite() == want
    });
    rt.repo(key).expect("open repo").upstream_rewrite()
}

/// Commits `file` in checkout `dir` on branch `branch` as `email` and pushes it.
fn push_as(repo: &TestRepo, dir: &std::path::Path, branch: &str, email: &str, file: &str) {
    let run = |args: &[&str]| {
        repo.command_in(dir)
            .env("GIT_AUTHOR_EMAIL", email)
            .args(args)
            .run()
            .unwrap_or_else(|err| panic!("git {args:?}: {err}"))
    };
    run(&["fetch", "--quiet", "origin"]);
    run(&["switch", "--quiet", branch]);
    run(&["pull", "--quiet", "--ff-only"]);
    fs::write(dir.join(file), "theirs\n").expect("write file");
    run(&["add", "--", file]);
    run(&["commit", "--quiet", "-m", "teammate"]);
    run(&["push", "--quiet", "origin", branch]);
}

#[test]
fn amending_a_pushed_commit_is_a_rewrite_and_force_pushes_with_a_pinned_lease() {
    let (repo, other) = shared();
    repo.git(&["switch", "--quiet", "-c", "topic"]);
    repo.commit("t.txt", "t\n", "topic work");
    let (mut rt, key) = open(&repo);
    let job = rt.push(&key, None);
    succeed(&mut rt, &key, job);
    assert_eq!(rt.repo(&key).unwrap().upstream_rewrite(), None);

    repo.git(&["commit", "--amend", "--quiet", "-m", "topic work, amended"]);
    let own = Some(UpstreamRewrite { shared: false });
    assert_eq!(rewrite_after_settle(&mut rt, &key, own), own);
    assert_eq!(tracking(&rt, &key), (1, 1));
    let pushed = repo.git(&["rev-parse", "refs/remotes/origin/topic"]);
    let lease = rt.repo(&key).unwrap().push_lease().expect("a lease");
    assert_eq!(lease, pushed);
    let job = rt.push(&key, Some(&lease));
    succeed(&mut rt, &key, job);
    assert_eq!(tracking(&rt, &key), (0, 0));
    assert_eq!(
        repo.git(&["rev-parse", "refs/remotes/origin/topic"]),
        repo.head()
    );

    // Rewritten again, but a teammate pushed on top before our (background)
    // fetch: no longer a rewrite of ours, and the lease read before the
    // fetch refuses the push although origin/topic is now current.
    repo.git(&[
        "commit",
        "--amend",
        "--quiet",
        "-m",
        "topic work, amended twice",
    ]);
    assert_eq!(rewrite_after_settle(&mut rt, &key, own), own);
    let lease = rt.repo(&key).unwrap().push_lease().expect("a lease");
    push_as(&repo, &other, "topic", "bob@example.com", "b.txt");
    let job = rt.fetch(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(rewrite_after_settle(&mut rt, &key, None), None);
    let theirs = repo.git(&["rev-parse", "refs/remotes/origin/topic"]);
    assert_ne!(theirs, lease);
    let job = rt.push(&key, Some(&lease));
    assert!(
        finish(&mut rt, &key, job).is_some(),
        "the stale lease refuses"
    );
    let job = rt.fetch(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(
        repo.git(&["rev-parse", "refs/remotes/origin/topic"]),
        theirs
    );
}

#[test]
fn a_teammates_commit_dropped_locally_is_not_a_rewrite() {
    let (repo, other) = shared();
    repo.git(&["switch", "--quiet", "-c", "topic"]);
    repo.commit("t.txt", "t\n", "topic work");
    let (mut rt, key) = open(&repo);
    let job = rt.push(&key, None);
    succeed(&mut rt, &key, job);
    push_as(&repo, &other, "topic", "bob@example.com", "b.txt");
    let job = rt.pull(&key, None);
    succeed(&mut rt, &key, job);
    // Their commit was on this branch (its reflog) but is not ours.
    repo.git(&["reset", "--quiet", "--hard", "HEAD~1"]);
    repo.commit("c.txt", "c\n", "ours instead");
    assert_eq!(rewrite_after_settle(&mut rt, &key, None), None);
    assert_eq!(tracking(&rt, &key), (1, 1));
}

#[test]
fn your_own_push_from_another_clone_is_not_a_rewrite() {
    let (repo, other) = shared();
    repo.git(&["switch", "--quiet", "-c", "topic"]);
    repo.commit("t.txt", "t\n", "topic work");
    let (mut rt, key) = open(&repo);
    let job = rt.push(&key, None);
    succeed(&mut rt, &key, job);
    // Yours, but this branch never pointed at it: a real divergence.
    push_as(&repo, &other, "topic", "ada@example.com", "b.txt");
    repo.commit("c.txt", "c\n", "here");
    let job = rt.fetch(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(tracking(&rt, &key), (1, 1));
    assert_eq!(rewrite_after_settle(&mut rt, &key, None), None);
}

#[test]
fn rewriting_the_default_branch_is_a_shared_rewrite() {
    let (repo, _other) = shared();
    repo.commit("b.txt", "b\n", "second");
    let (mut rt, key) = open(&repo);
    let job = rt.push(&key, None);
    succeed(&mut rt, &key, job);
    repo.git(&["commit", "--amend", "--quiet", "-m", "second, amended"]);
    let shared = Some(UpstreamRewrite { shared: true });
    assert_eq!(rewrite_after_settle(&mut rt, &key, shared), shared);
}

#[test]
fn nothing_to_sync_without_remotes_or_upstream() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let (mut rt, key) = open(&repo);
    let state = rt.repo(&key).unwrap();
    assert!(!state.can_fetch() && !state.can_pull() && !state.can_push());
    assert_eq!(state.default_remote(), None);
    assert_eq!(rt.fetch(&key), None);
    assert_eq!(rt.pull(&key, None), None);
    assert_eq!(rt.push(&key, None), None);
}

#[test]
fn auto_fetch_runs_on_its_interval_and_reports_failures_once() {
    let (repo, other) = shared();
    repo.push_from(&other, "b.txt", "b\n", "theirs");
    let mut config = Config::default();
    config.auto_fetch_minutes = 0;
    let mut rt = Runtime::with_runner(config, None, repo.app_runner());
    rt.set_auto_fetch_interval(Some(Duration::from_millis(200)));
    let key = rt.open(repo.path());
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.status())
            .is_some_and(|s| s.behind == 1)
    });

    // Break the remote: the failure is reported once, not every interval.
    repo.git(&["remote", "set-url", "origin", "../no such remote.git"]);
    let failures = |events: &[RuntimeEvent]| {
        events
            .iter()
            .filter(|e| {
                matches!(e, RuntimeEvent::Job { label, state: JobState::Finished(Some(_)), .. }
                    if label == AUTO_FETCH_JOB_LABEL)
            })
            .count()
    };
    let started = |events: &[RuntimeEvent]| {
        events
            .iter()
            .filter(|e| {
                matches!(e, RuntimeEvent::Job { label, state: JobState::Started, .. }
                    if label == AUTO_FETCH_JOB_LABEL)
            })
            .count()
    };
    let events = poll_until(&mut rt, |_, ev| started(ev) >= 3);
    assert_eq!(failures(&events), 1, "{events:#?}");
}
