//! Watcher behaviour on real temporary repositories. Timing-based: positive
//! cases wait up to a few seconds, negative cases a short quiet period.

mod support;

use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::{Duration, Instant};

use gitbello_core::backend::{CliBackend, GitBackend};
use gitbello_core::git::CancelToken;
use gitbello_core::jobs::{RefreshKind, RefreshSet};
use gitbello_core::watch::{RepoWatcher, WatchTarget};
use support::TestRepo;

const DEBOUNCE: Duration = Duration::from_millis(100);
const WAIT: Duration = Duration::from_secs(5);
const QUIET: Duration = Duration::from_millis(800);

struct Harness {
    watcher: RepoWatcher,
    changes: Receiver<(PathBuf, RefreshSet)>,
}

fn watch(repo: &TestRepo, dirs: &[&Path]) -> Harness {
    let backend = Arc::new(CliBackend::new(repo.runner().clone()));
    let (tx, changes) = mpsc::channel();
    let watcher = RepoWatcher::new(backend.clone(), DEBOUNCE, move |repo, set| {
        let _ = tx.send((repo.to_path_buf(), set));
    })
    .expect("create watcher");
    for dir in dirs {
        let paths = backend
            .repo_paths(dir, &CancelToken::new())
            .expect("repo paths");
        watcher
            .watch(&WatchTarget::new(*dir, *dir, &paths))
            .expect("watch");
    }
    // Let the OS watch settle before making changes.
    std::thread::sleep(Duration::from_millis(200));
    Harness { watcher, changes }
}

impl Harness {
    /// Waits until a change for `repo` includes `kind`.
    fn expect(&self, repo: &Path, kind: RefreshKind) -> RefreshSet {
        let deadline = Instant::now() + WAIT;
        let mut seen = Vec::new();
        while let Ok((r, set)) = self
            .changes
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
        {
            if r == repo && set.contains(kind) {
                return set;
            }
            seen.push((r, set));
        }
        panic!("no {kind:?} change for {repo:?}; saw {seen:?}");
    }

    fn expect_quiet(&self) {
        // Drain anything from setup first.
        while self.changes.recv_timeout(Duration::from_millis(50)).is_ok() {}
    }

    fn assert_nothing(&self, what: &str) {
        if let Ok(change) = self.changes.recv_timeout(QUIET) {
            panic!("{what}: unexpected change {change:?}");
        }
    }
}

#[test]
fn working_tree_edits_request_status() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let h = watch(&repo, &[repo.path()]);
    h.expect_quiet();
    repo.write("a.txt", "changed\n");
    h.expect(repo.path(), RefreshKind::Status);
}

#[test]
fn ignored_files_and_object_writes_are_skipped() {
    let repo = TestRepo::init();
    repo.commit(".gitignore", "target/\n", "ignore target");
    std::fs::create_dir_all(repo.path().join("target")).unwrap();
    let h = watch(&repo, &[repo.path()]);
    h.expect_quiet();
    repo.write("target/build output.o", "bin");
    h.assert_nothing("ignored file");
    repo.command()
        .args(["hash-object", "-w", "--stdin"])
        .stdin("loose object")
        .run()
        .unwrap();
    h.assert_nothing("object write");
}

#[test]
fn branch_and_stash_changes_request_refs_and_stashes() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let h = watch(&repo, &[repo.path()]);
    h.expect_quiet();
    repo.branch("feature/new");
    h.expect(repo.path(), RefreshKind::Refs);
    h.expect_quiet();
    repo.stash("a.txt", "dirty\n", "wip");
    h.expect(repo.path(), RefreshKind::Stashes);
}

#[test]
fn merge_conflict_requests_operation_state() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let h = watch(&repo, &[repo.path()]);
    repo.start_conflicting_merge("clash.txt");
    h.expect(repo.path(), RefreshKind::Operation);
}

#[test]
fn linked_worktrees_are_watched_separately() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let linked = repo.add_worktree("feature/x", "lïnked");
    let h = watch(&repo, &[repo.path(), &linked]);
    h.expect_quiet();

    std::fs::write(linked.join("a.txt"), "edited in linked\n").unwrap();
    h.expect(&linked, RefreshKind::Status);

    // A new worktree shows up in the worktree list of the main one.
    h.expect_quiet();
    repo.add_worktree("feature/y", "third");
    h.expect(repo.path(), RefreshKind::Worktrees);
}

#[test]
fn unwatch_stops_reporting() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let h = watch(&repo, &[repo.path()]);
    h.expect_quiet();
    h.watcher.unwatch(repo.path());
    repo.write("a.txt", "changed\n");
    h.assert_nothing("after unwatch");
}
