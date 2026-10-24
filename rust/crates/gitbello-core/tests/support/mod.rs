//! Fixture helpers: real temporary repositories (AGENTS rule 7).
//!
//! Paths contain spaces and non-ASCII characters on purpose. Every git call goes
//! through `GitRunner` and is isolated from the user's global and system config.

#![allow(dead_code)]

use std::cell::Cell;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use gitbello_core::git::{GitCommand, GitError, GitOutput, GitRunner};

static NEXT_DIR: AtomicUsize = AtomicUsize::new(0);

/// Fixed base time so fixture hashes are reproducible.
const EPOCH: i64 = 1_700_000_000;

/// A temporary directory removed on drop.
pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    pub fn new(label: &str) -> Self {
        let n = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("gitbello tést {label} {}-{n}", std::process::id()));
        if path.exists() {
            remove_tree(&path);
        }
        fs::create_dir_all(&path).expect("create temp dir");
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        remove_tree(&self.path);
    }
}

/// `remove_dir_all` that also handles git's read-only object files on Windows.
fn remove_tree(path: &Path) {
    if fs::remove_dir_all(path).is_ok() {
        return;
    }
    fn make_writable(path: &Path) {
        if let Ok(meta) = fs::symlink_metadata(path) {
            let mut perms = meta.permissions();
            #[allow(clippy::permissions_set_readonly_false)]
            perms.set_readonly(false);
            let _ = fs::set_permissions(path, perms);
            if meta.is_dir() {
                if let Ok(entries) = fs::read_dir(path) {
                    for entry in entries.flatten() {
                        make_writable(&entry.path());
                    }
                }
            }
        }
    }
    make_writable(path);
    let _ = fs::remove_dir_all(path);
}

pub fn runner() -> GitRunner {
    GitRunner::discover().expect("git 2.40+ must be installed to run tests")
}

/// A repository in a temp dir, with a deterministic clock and identity.
pub struct TestRepo {
    dir: TempDir,
    path: PathBuf,
    global_config: PathBuf,
    runner: GitRunner,
    clock: Cell<i64>,
}

impl TestRepo {
    /// `git init` on branch `main`.
    pub fn init() -> Self {
        let dir = TempDir::new("repo");
        let path = dir.path().join("wörk tree");
        fs::create_dir_all(&path).expect("create repo dir");
        let global_config = dir.path().join("global.gitconfig");
        fs::write(&global_config, "").expect("write empty global config");
        let repo = Self {
            dir,
            path,
            global_config,
            runner: runner(),
            clock: Cell::new(EPOCH),
        };
        repo.git(&["init", "--quiet", "--initial-branch=main"]);
        repo
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn runner(&self) -> &GitRunner {
        &self.runner
    }

    /// A runner for code under test that writes (commits): the fixture's
    /// empty global config and a fixed identity, but no fixed clock.
    pub fn app_runner(&self) -> GitRunner {
        self.runner
            .clone()
            .with_env("GIT_CONFIG_GLOBAL", &self.global_config)
            .with_env("GIT_CONFIG_NOSYSTEM", "1")
            .with_env("GIT_CONFIG_COUNT", "2")
            .with_env("GIT_CONFIG_KEY_0", "commit.gpgsign")
            .with_env("GIT_CONFIG_VALUE_0", "false")
            .with_env("GIT_CONFIG_KEY_1", "core.autocrlf")
            .with_env("GIT_CONFIG_VALUE_1", "false")
            .with_env("GIT_AUTHOR_NAME", "Ada Lövelace")
            .with_env("GIT_AUTHOR_EMAIL", "ada@example.com")
            .with_env("GIT_COMMITTER_NAME", "Ada Lövelace")
            .with_env("GIT_COMMITTER_EMAIL", "ada@example.com")
    }

    /// A temp sibling directory that is not a repository.
    pub fn non_repo_dir(&self) -> PathBuf {
        let path = self.dir.path().join("not a repo");
        fs::create_dir_all(&path).expect("create dir");
        path
    }

    /// A write command in the repository with the fixture environment applied.
    pub fn command(&self) -> GitCommand {
        self.command_in(&self.path)
    }

    /// Like [`TestRepo::command`] but runs in `dir` (a worktree or remote).
    pub fn command_in(&self, dir: &Path) -> GitCommand {
        let time = self.clock.get();
        self.clock.set(time + 60);
        let date = format!("{time} +0000");
        self.runner
            .write(dir)
            .env("GIT_CONFIG_GLOBAL", &self.global_config)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_NAME", "Ada Lövelace")
            .env("GIT_AUTHOR_EMAIL", "ada@example.com")
            .env("GIT_AUTHOR_DATE", &date)
            .env("GIT_COMMITTER_NAME", "Ada Lövelace")
            .env("GIT_COMMITTER_EMAIL", "ada@example.com")
            .env("GIT_COMMITTER_DATE", &date)
            .args(["-c", "commit.gpgsign=false", "-c", "core.autocrlf=false"])
    }

    pub fn try_git(&self, args: &[&str]) -> Result<GitOutput, GitError> {
        self.command().args(args).run()
    }

    /// Runs git and returns trimmed stdout; panics on failure.
    pub fn git(&self, args: &[&str]) -> String {
        match self.try_git(args) {
            Ok(output) => String::from_utf8_lossy(&output.stdout).trim().to_owned(),
            Err(err) => panic!("git {args:?} failed: {err}"),
        }
    }

    /// Writes `file`, stages it and commits. Returns the new commit hash.
    pub fn commit(&self, file: &str, content: &str, message: &str) -> String {
        let target = self.path.join(file);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).expect("create parent dirs");
        }
        fs::write(&target, content).expect("write file");
        self.git(&["add", "--", file]);
        self.command()
            .args(["commit", "--quiet", "-F", "-"])
            .stdin(message)
            .run()
            .unwrap_or_else(|err| panic!("commit failed: {err}"));
        self.head()
    }

    pub fn head(&self) -> String {
        self.git(&["rev-parse", "HEAD"])
    }

    pub fn branch(&self, name: &str) {
        self.git(&["branch", name]);
    }

    pub fn checkout(&self, name: &str) {
        self.git(&["checkout", "--quiet", name]);
    }

    /// `git merge --no-ff`; returns the merge commit hash.
    pub fn merge(&self, branch: &str, message: &str) -> String {
        self.git(&["merge", "--no-ff", "--quiet", "-m", message, branch]);
        self.head()
    }

    /// Feeds a `git fast-import` stream (fast way to build large histories).
    pub fn fast_import(&self, stream: &str) {
        self.command()
            .args(["fast-import", "--quiet"])
            .stdin(stream)
            .run()
            .unwrap_or_else(|err| panic!("fast-import failed: {err}"));
    }

    /// Path of a new, not yet existing directory next to the repository.
    pub fn sibling(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }

    /// Writes a file in the working tree without staging it.
    pub fn write(&self, file: &str, content: &str) {
        let target = self.path.join(file);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).expect("create parent dirs");
        }
        fs::write(&target, content).expect("write file");
    }

    /// Creates a bare repository next to this one, adds it as `origin` and
    /// pushes `main` with upstream tracking. Returns the remote's path.
    pub fn add_remote(&self) -> PathBuf {
        let remote = self.sibling("remöte.git");
        self.git(&[
            "init",
            "--quiet",
            "--bare",
            "--initial-branch=main",
            &path_arg(&remote),
        ]);
        self.git(&["remote", "add", "origin", &path_arg(&remote)]);
        self.git(&["push", "--quiet", "-u", "origin", "main"]);
        remote
    }

    /// `git worktree add -b <branch> <sibling dir>`; returns the worktree path.
    pub fn add_worktree(&self, branch: &str, dir_name: &str) -> PathBuf {
        let path = self.sibling(dir_name);
        self.git(&["worktree", "add", "--quiet", "-b", branch, &path_arg(&path)]);
        path
    }

    /// Modifies `file` and stashes it with `message`.
    pub fn stash(&self, file: &str, content: &str, message: &str) {
        self.write(file, content);
        self.git(&["stash", "push", "--quiet", "-m", message]);
    }

    /// Leaves the repository in a conflicted merge on `file`: `main` and a
    /// `conflict` branch change the same line. Returns the conflicting branch name.
    pub fn start_conflicting_merge(&self, file: &str) -> &'static str {
        self.commit(file, "base\n", "conflict base");
        self.branch("conflict");
        self.commit(file, "ours\n", "ours");
        self.checkout("conflict");
        self.commit(file, "theirs\n", "theirs");
        self.checkout("main");
        let err = self
            .try_git(&["merge", "--no-edit", "conflict"])
            .expect_err("merge should conflict");
        assert_eq!(
            err.kind,
            gitbello_core::git::GitErrorKind::Conflict,
            "{err}"
        );
        "conflict"
    }

    /// Detaches HEAD at the current commit.
    pub fn detach(&self) {
        self.git(&["checkout", "--quiet", "--detach"]);
    }
}

/// Paths are passed to git with forward slashes so they survive any shell
/// quoting git does internally on Windows.
pub fn path_arg(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

impl TestRepo {
    /// Clones `remote` into a sibling `dir_name` (another user's checkout).
    pub fn clone_remote(&self, remote: &Path, dir_name: &str) -> PathBuf {
        let path = self.sibling(dir_name);
        self.git(&["clone", "--quiet", &path_arg(remote), &path_arg(&path)]);
        path
    }

    /// Brings another checkout `dir` up to date, commits `file` there and
    /// pushes it to its origin.
    pub fn push_from(&self, dir: &Path, file: &str, content: &str, message: &str) {
        let run = |args: &[&str]| {
            self.command_in(dir)
                .args(args)
                .run()
                .unwrap_or_else(|err| panic!("git {args:?} in {}: {err}", dir.display()))
        };
        let tracked = self
            .command_in(dir)
            .args(["rev-parse", "-q", "--verify", "@{upstream}"])
            .run()
            .is_ok();
        if tracked {
            run(&["pull", "--quiet", "--ff-only"]);
        }
        fs::write(dir.join(file), content).expect("write file");
        run(&["add", "--", file]);
        self.command_in(dir)
            .args(["commit", "--quiet", "-F", "-"])
            .stdin(message)
            .run()
            .unwrap_or_else(|err| panic!("commit failed: {err}"));
        run(&["push", "--quiet", "origin", "HEAD"]);
    }
}

/// Driving a [`Runtime`] the way the UI does: poll until something holds.
pub mod rt {
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant};

    use gitbello_core::config::Config;
    use gitbello_core::git::GitError;
    use gitbello_core::runtime::{JobState, Runtime, RuntimeEvent};

    use super::TestRepo;

    pub const WAIT: Duration = Duration::from_secs(20);

    /// A runtime on `repo` with auto-fetch off, opened and refreshed.
    pub fn open(repo: &TestRepo) -> (Runtime, PathBuf) {
        let mut config = Config::default();
        config.auto_fetch_minutes = 0;
        let mut rt = Runtime::with_runner(config, None, repo.app_runner());
        let key = rt.open(repo.path());
        poll_until(&mut rt, |rt, _| {
            rt.repo(&key)
                .is_some_and(|s| s.status().is_some() && s.refs().is_some())
        });
        (rt, key)
    }

    /// Polls until `done` holds; panics with the events seen after [`WAIT`].
    pub fn poll_until(
        rt: &mut Runtime,
        mut done: impl FnMut(&Runtime, &[RuntimeEvent]) -> bool,
    ) -> Vec<RuntimeEvent> {
        let deadline = Instant::now() + WAIT;
        let mut seen = Vec::new();
        loop {
            seen.extend(rt.poll());
            if done(rt, &seen) {
                return seen;
            }
            assert!(Instant::now() < deadline, "timed out; events: {seen:#?}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// The result of `job` once it finished (`None` = success).
    pub fn result(events: &[RuntimeEvent], job: u64) -> Option<Option<GitError>> {
        events.iter().find_map(|e| match e {
            RuntimeEvent::Job {
                job: j,
                state: JobState::Finished(err),
                ..
            } if *j == job => Some(err.clone()),
            _ => None,
        })
    }

    /// Runs `job` to the end and returns its error, if any. Also waits for
    /// the refreshes it queued, so the state reflects the job.
    pub fn finish(rt: &mut Runtime, key: &Path, job: Option<u64>) -> Option<GitError> {
        let job = job.expect("the job should start");
        let events = poll_until(rt, |_, ev| result(ev, job).is_some());
        let error = result(&events, job).flatten();
        settle(rt, key);
        error
    }

    /// Starts a job with `start` and runs it to the end; it must succeed.
    pub fn ok(rt: &mut Runtime, key: &Path, start: impl FnOnce(&mut Runtime) -> Option<u64>) {
        let job = start(rt);
        succeed(rt, key, job);
    }

    /// Starts a job with `start` and returns its error, if any.
    pub fn outcome(
        rt: &mut Runtime,
        key: &Path,
        start: impl FnOnce(&mut Runtime) -> Option<u64>,
    ) -> Option<GitError> {
        let job = start(rt);
        finish(rt, key, job)
    }

    /// Like [`finish`], but the job must succeed.
    pub fn succeed(rt: &mut Runtime, key: &Path, job: Option<u64>) {
        if let Some(err) = finish(rt, key, job) {
            panic!("job failed: {err}");
        }
    }

    /// Refreshes status and refs and waits until every job (that refresh
    /// included) is done and applied, so the state is current.
    pub fn settle(rt: &mut Runtime, key: &Path) {
        use gitbello_core::jobs::{RefreshKind, RefreshSet};
        rt.refresh(
            key,
            RefreshSet::EMPTY
                .with(RefreshKind::Status)
                .with(RefreshKind::Refs),
        );
        poll_until(rt, |rt, _| rt.pending_jobs() == 0);
        // Final events are sent before a job leaves the queue: apply them.
        rt.poll();
    }
}
