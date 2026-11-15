//! Worktrees (M6, M7.16) through the runtime: add, lock, remove and prune,
//! creating worktrees (bases, fetch fallback, free folders, rollback, setup
//! and undo), the cleanup flow, missing folders and
//! badges across open worktrees.

use crate::support;

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use gitbello_core::config::{Config, DEFAULT_WORKTREE_TEMPLATE};
use gitbello_core::git::{GitError, GitErrorKind};
use gitbello_core::ops::{NewWorktree, WorktreeOp, WorktreeStart};
use gitbello_core::runtime::{normalize, CreatedWorktree, JobState, Runtime, RuntimeEvent};
use gitbello_core::worktree_setup::WorktreeSetup;
use gitbello_core::worktrees::{worktree_path, CleanupReason};
use support::rt::{finish, ok, open, outcome, poll_until, settle};
use support::TestRepo;

fn worktree_paths(rt: &Runtime, key: &Path) -> Vec<PathBuf> {
    rt.repo(key)
        .and_then(|s| s.worktrees())
        .map(|list| list.iter().map(|wt| wt.path.clone()).collect())
        .unwrap_or_default()
}

/// git reports resolved paths (`/private/var` on macOS, long names on
/// Windows), so compare normalized ones.
fn listed(rt: &Runtime, key: &Path, path: &Path) -> bool {
    worktree_paths(rt, key)
        .iter()
        .any(|p| normalize(p) == normalize(path))
}

/// Waits until the worktree list (refreshed by worktree jobs) is current.
fn settle_worktrees(rt: &mut Runtime, key: &Path) {
    use gitbello_core::jobs::{RefreshKind, RefreshSet};
    rt.refresh(key, RefreshSet::EMPTY.with(RefreshKind::Worktrees));
    settle(rt, key);
}

#[test]
fn add_lock_remove_and_prune_worktrees() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.branch("existing");
    let (mut rt, key) = open(&repo);

    let existing = repo.sibling("existing wörktree");
    let add = WorktreeOp::Add {
        path: existing.clone(),
        branch: "existing".into(),
        start: None,
    };
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, add));
    let fresh = repo.sibling("fresh");
    let add_new = WorktreeOp::Add {
        path: fresh.clone(),
        branch: "fresh".into(),
        start: Some("main".into()),
    };
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, add_new));
    settle_worktrees(&mut rt, &key);
    assert!(listed(&rt, &key, &existing) && listed(&rt, &key, &fresh));
    let state = rt.repo(&key).unwrap();
    assert!(state.branch("fresh").unwrap().worktree.is_some());
    assert_eq!(state.branch("fresh").unwrap().upstream, None, "no tracking");

    let lock = WorktreeOp::Lock {
        path: existing.clone(),
        reason: "on a usb disk".into(),
    };
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, lock));
    let locked = |rt: &Runtime| {
        rt.repo(&key)
            .unwrap()
            .worktrees()
            .unwrap()
            .iter()
            .find(|wt| normalize(&wt.path) == normalize(&existing))
            .and_then(|wt| wt.locked.clone())
    };
    settle_worktrees(&mut rt, &key);
    assert_eq!(locked(&rt).as_deref(), Some("on a usb disk"));
    let unlock = WorktreeOp::Unlock {
        path: existing.clone(),
    };
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, unlock));
    settle_worktrees(&mut rt, &key);
    assert_eq!(locked(&rt), None);

    // A worktree with changes is only removed by force.
    fs::write(fresh.join("a.txt"), "edited\n").unwrap();
    let remove = |force| WorktreeOp::Remove {
        path: fresh.clone(),
        force,
    };
    let err = outcome(&mut rt, &key, |rt| rt.worktree_op(&key, remove(false))).expect("dirty");
    assert!(err.stderr.contains("modified or untracked"), "{err}");
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, remove(true)));
    assert!(!fresh.exists());

    // A deleted folder shows as prunable until pruned.
    fs::remove_dir_all(&existing).unwrap();
    settle_worktrees(&mut rt, &key);
    let prunable = rt
        .repo(&key)
        .unwrap()
        .worktrees()
        .unwrap()
        .iter()
        .filter(|wt| wt.prunable.is_some())
        .count();
    assert_eq!(prunable, 1, "the deleted one is prunable");
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, WorktreeOp::Prune));
    settle_worktrees(&mut rt, &key);
    assert_eq!(worktree_paths(&rt, &key).len(), 1);
}

/// Starts a create and runs it to the end: its job and error, if any.
fn create(
    rt: &mut Runtime,
    key: &Path,
    branch: &str,
    start: WorktreeStart,
    path: &Path,
) -> (u64, Option<GitError>) {
    let request = NewWorktree {
        branch: branch.into(),
        start,
        path: path.to_path_buf(),
    };
    let job = rt.create_worktree(key, request).expect("the create starts");
    let error = finish(rt, key, Some(job));
    settle_worktrees(rt, key);
    (job, error)
}

/// What create `job` made; it must have succeeded.
fn created(rt: &Runtime, key: &Path, job: u64) -> CreatedWorktree {
    rt.repo(key)
        .expect("open")
        .created_worktree(job)
        .expect("created")
        .clone()
}

fn new_branch(base: &str) -> WorktreeStart {
    WorktreeStart::NewBranch { base: base.into() }
}

fn rev(repo: &TestRepo, dir: &Path, name: &str) -> String {
    repo.command_in(dir)
        .args(["rev-parse", name])
        .run()
        .expect("rev-parse")
        .stdout_text()
        .trim()
        .to_owned()
}

#[test]
fn create_fetches_the_base_and_adds_a_worktree() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let remote = repo.add_remote();
    let other = repo.clone_remote(&remote, "other");
    repo.push_from(&other, "b.txt", "b\n", "newer on the remote");
    let upstream_tip = rev(&repo, &other, "HEAD");
    let (mut rt, key) = open(&repo);
    let state = rt.repo(&key).unwrap();
    assert_eq!(state.default_base().as_deref(), Some("origin/main"));
    let main = state.main_worktree().unwrap().to_path_buf();
    let path = worktree_path(DEFAULT_WORKTREE_TEMPLATE, &main, "feature/new task");
    assert_eq!(path, main.join(".worktrees").join("feature-new-task"));

    let base = new_branch("origin/main");
    let (job, error) = create(&mut rt, &key, "feature/new-task", base, &path);
    assert!(error.is_none(), "{error:?}");
    assert!(listed(&rt, &key, &path));
    assert!(
        path.join("b.txt").is_file(),
        "started from the fetched base"
    );
    let made = created(&rt, &key, job);
    assert_eq!(made.path, path);
    assert!(made.created_branch);
    assert_eq!(made.tip, upstream_tip);
    assert_eq!(made.stale, None, "fetched");
    let branch = rt
        .repo(&key)
        .unwrap()
        .branch("feature/new-task")
        .unwrap()
        .clone();
    assert_eq!(branch.target, upstream_tip);
    assert_eq!(branch.upstream, None, "the new branch does not track main");
    let exclude = main.join(".git/info/exclude");
    assert!(fs::read_to_string(&exclude)
        .unwrap()
        .ends_with("/.worktrees/\n"));
    assert!(repo.git(&["status", "--porcelain"]).is_empty());
    assert!(!main.join(".gitignore").exists());

    let second = main.join(".worktrees").join("second");
    let add_second = WorktreeOp::Add {
        path: second,
        branch: "second".into(),
        start: Some("main".into()),
    };
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, add_second));
    settle_worktrees(&mut rt, &key);
    assert_eq!(
        fs::read_to_string(&exclude)
            .unwrap()
            .matches("/.worktrees/")
            .count(),
        1,
        "the exclude entry is not duplicated"
    );

    // The same branch again is refused before anything is created.
    let other_path = repo.sibling("another");
    let base = new_branch("origin/main");
    let (_, error) = create(&mut rt, &key, "feature/new-task", base, &other_path);
    assert_eq!(error.expect("exists").kind, GitErrorKind::AlreadyExists);
    assert!(!other_path.exists());
}

#[test]
fn create_starts_from_tags_and_commits() {
    let repo = TestRepo::init();
    let first = repo.commit("a.txt", "a\n", "first");
    repo.git(&["tag", "v1"]);
    repo.commit("a.txt", "b\n", "second");
    let (mut rt, key) = open(&repo);

    let tagged = repo.sibling("from tag");
    let (job, error) = create(&mut rt, &key, "hotfix", new_branch("v1"), &tagged);
    assert!(error.is_none(), "{error:?}");
    assert_eq!(created(&rt, &key, job).tip, first);
    assert_eq!(fs::read_to_string(tagged.join("a.txt")).unwrap(), "a\n");

    let at_commit = repo.sibling("from cömmit");
    let (job, error) = create(&mut rt, &key, "old", new_branch(&first[..10]), &at_commit);
    assert!(error.is_none(), "{error:?}");
    assert_eq!(created(&rt, &key, job).tip, first);
}

#[test]
fn create_checks_out_an_existing_or_a_remote_branch() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.branch("existing");
    let remote = repo.add_remote();
    let other = repo.clone_remote(&remote, "other");
    let git = |args: &[&str]| {
        repo.command_in(&other)
            .args(args)
            .run()
            .unwrap_or_else(|err| panic!("git {args:?}: {err}"));
    };
    git(&["checkout", "--quiet", "-b", "topic"]);
    fs::write(other.join("t.txt"), "t\n").unwrap();
    git(&["add", "--", "t.txt"]);
    git(&["commit", "--quiet", "-m", "topic work"]);
    git(&["push", "--quiet", "origin", "topic"]);
    let (mut rt, key) = open(&repo);

    // Pushed after the last fetch: the create's fetch brings it.
    let path = repo.sibling("topic wört");
    let remote_start = WorktreeStart::Remote {
        upstream: "origin/topic".into(),
    };
    let (job, error) = create(&mut rt, &key, "topic", remote_start, &path);
    assert!(error.is_none(), "{error:?}");
    assert!(path.join("t.txt").is_file(), "the fetched remote branch");
    assert!(created(&rt, &key, job).created_branch);
    let branch = rt.repo(&key).unwrap().branch("topic").unwrap().clone();
    assert_eq!(
        branch.upstream.as_deref(),
        Some("refs/remotes/origin/topic")
    );

    let existing = repo.sibling("existing");
    let (job, error) = create(
        &mut rt,
        &key,
        "existing",
        WorktreeStart::Existing,
        &existing,
    );
    assert!(error.is_none(), "{error:?}");
    assert!(!created(&rt, &key, job).created_branch);
    assert!(listed(&rt, &key, &existing));

    let unknown = repo.sibling("unknown");
    let (_, error) = create(&mut rt, &key, "nope", WorktreeStart::Existing, &unknown);
    assert!(error.expect("unknown").stderr.contains("not found"));
}

#[test]
fn a_taken_folder_gets_a_number() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let (mut rt, key) = open(&repo);
    let wanted = repo.sibling("occupied");
    fs::create_dir_all(&wanted).unwrap();
    fs::write(wanted.join("keep.txt"), "mine\n").unwrap();

    let (job, error) = create(&mut rt, &key, "task", new_branch("main"), &wanted);
    assert!(error.is_none(), "{error:?}");
    let path = repo.sibling("occupied-2");
    assert_eq!(created(&rt, &key, job).path, path);
    assert!(listed(&rt, &key, &path));
    assert_eq!(
        fs::read_to_string(wanted.join("keep.txt")).unwrap(),
        "mine\n"
    );
}

#[test]
fn create_rolls_back_when_the_worktree_cannot_be_added() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let (mut rt, key) = open(&repo);
    // git creates the branch, then cannot make the folder under a file.
    let file = repo.sibling("a file");
    fs::write(&file, "x\n").unwrap();
    let (_, error) = create(
        &mut rt,
        &key,
        "doomed",
        new_branch("main"),
        &file.join("sub"),
    );
    assert!(error.is_some());
    assert!(
        rt.repo(&key).unwrap().branch("doomed").is_none(),
        "branch rolled back"
    );
    assert_eq!(worktree_paths(&rt, &key).len(), 1);
    assert_eq!(fs::read_to_string(&file).unwrap(), "x\n");
}

#[test]
fn an_offline_create_starts_from_the_base_last_fetched() {
    let repo = TestRepo::init();
    let tip = repo.commit("a.txt", "a\n", "first");
    let remote = repo.add_remote();
    let (mut rt, key) = open(&repo);
    // The remote goes away (offline, say).
    fs::rename(&remote, repo.sibling("gone.git")).unwrap();

    let path = repo.sibling("offline");
    let (job, error) = create(&mut rt, &key, "offline", new_branch("origin/main"), &path);
    assert!(error.is_none(), "{error:?}");
    let made = created(&rt, &key, job);
    assert_eq!(made.tip, tip);
    let stale = made.stale.expect("not fetched");
    assert_eq!(stale.base, "origin/main");
    assert!(!stale.timed_out && !stale.error.is_empty(), "{stale:?}");
    assert!(stale.fetched_at.is_some_and(|t| t > 0), "{stale:?}");

    // A remote branch never fetched cannot be checked out offline.
    let never = WorktreeStart::Remote {
        upstream: "origin/never".into(),
    };
    let (_, error) = create(&mut rt, &key, "never", never, &repo.sibling("never"));
    let error = error.expect("nothing to start from");
    assert_eq!(error.command, "fetch", "{error}");
    assert!(rt.repo(&key).unwrap().branch("never").is_none());
}

#[test]
fn a_slow_fetch_falls_back_after_the_timeout() {
    let repo = TestRepo::init();
    let tip = repo.commit("a.txt", "a\n", "first");
    repo.add_remote();
    let (mut rt, key) = open(&repo);
    rt.set_fetch_timeout(Duration::ZERO);

    let path = repo.sibling("slow");
    let (job, error) = create(&mut rt, &key, "slow", new_branch("origin/main"), &path);
    assert!(error.is_none(), "{error:?}");
    let made = created(&rt, &key, job);
    assert_eq!(made.tip, tip);
    assert!(made.stale.is_some_and(|s| s.timed_out));
}

/// A setup command that writes `file` in its folder (in both shells).
fn write_command(file: &str) -> String {
    format!("echo done> {file}")
}

#[test]
fn setup_copies_untracked_files_and_runs_its_command() {
    let repo = TestRepo::init();
    repo.commit(".gitignore", ".env*\nnode_modules/\n", "ignore");
    let main = repo.path().to_path_buf();
    fs::write(main.join(".env"), "SECRET=1\n").unwrap();
    fs::write(main.join(".env.local"), "LOCAL=1\n").unwrap();
    fs::create_dir_all(main.join(".vscode")).unwrap();
    fs::write(main.join(".vscode").join("settings.json"), "{}\n").unwrap();
    fs::create_dir_all(main.join("node_modules").join("x")).unwrap();
    fs::write(main.join("node_modules").join("x").join("i.js"), "1\n").unwrap();
    let (mut rt, key) = open(&repo);
    assert!(rt.worktree_setup(&key).is_empty());
    let patterns = [".env*".into(), ".vscode/".into(), ".worktrees/".into()];
    let setup = WorktreeSetup::cleaned(&patterns, &write_command("setup.txt"));
    assert!(rt.set_worktree_setup(&key, setup.clone()));
    assert_eq!(rt.worktree_setup(&key), setup);

    let path = main.join(".worktrees").join("task");
    let (_, error) = create(&mut rt, &key, "task", new_branch("main"), &path);
    assert!(error.is_none(), "{error:?}");
    // A file already there is kept.
    fs::write(path.join(".env.local"), "MINE=1\n").unwrap();
    let job = rt.run_worktree_setup(&key, &path).expect("a setup");
    assert!(rt.repo(&key).unwrap().setup_running(&path));
    let error = finish(&mut rt, &key, Some(job));
    assert!(error.is_none(), "{error:?}");
    assert!(!rt.repo(&key).unwrap().setup_running(&path));
    assert_eq!(fs::read_to_string(path.join(".env")).unwrap(), "SECRET=1\n");
    assert_eq!(
        fs::read_to_string(path.join(".env.local")).unwrap(),
        "MINE=1\n"
    );
    assert!(path.join(".vscode").join("settings.json").is_file());
    assert!(!path.join("node_modules").exists(), "not in the patterns");
    assert!(
        !path.join(".worktrees").exists(),
        "never a worktree into another"
    );
    assert!(path.join("setup.txt").is_file(), "the command ran there");
}

#[test]
fn a_failed_setup_keeps_the_worktree_and_its_output() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let (mut rt, key) = open(&repo);
    rt.set_worktree_setup(&key, WorktreeSetup::cleaned(&[], "echo oops&& exit 3"));
    let path = repo.sibling("failing");
    let (_, error) = create(&mut rt, &key, "failing", new_branch("main"), &path);
    assert!(error.is_none(), "{error:?}");

    let job = rt.run_worktree_setup(&key, &path);
    let error = finish(&mut rt, &key, job).expect("the command fails");
    assert_eq!(error.exit_code, Some(3), "{error}");
    assert!(error.stderr.contains("oops"), "{error}");
    assert!(listed(&rt, &key, &path), "kept");
}

#[test]
fn undo_deletes_what_the_create_made() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.branch("existing");
    let (mut rt, key) = open(&repo);

    let path = repo.sibling("undone");
    let (_, error) = create(&mut rt, &key, "undone", new_branch("main"), &path);
    assert!(error.is_none(), "{error:?}");
    fs::write(path.join("new.txt"), "untracked\n").unwrap();
    assert!(rt.repo(&key).unwrap().can_undo_create(&path));
    ok(&mut rt, &key, |rt| rt.undo_new_worktree(&key, &path));
    settle_worktrees(&mut rt, &key);
    assert!(!path.exists() && !listed(&rt, &key, &path));
    assert!(rt.repo(&key).unwrap().branch("undone").is_none());
    assert!(!rt.repo(&key).unwrap().can_undo_create(&path));

    // An existing branch stays.
    let existing = repo.sibling("existing");
    let (_, error) = create(
        &mut rt,
        &key,
        "existing",
        WorktreeStart::Existing,
        &existing,
    );
    assert!(error.is_none(), "{error:?}");
    ok(&mut rt, &key, |rt| rt.undo_new_worktree(&key, &existing));
    assert!(!existing.exists());
    assert!(rt.repo(&key).unwrap().branch("existing").is_some());
}

#[test]
fn undo_refuses_once_there_is_work_in_the_worktree() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let (mut rt, key) = open(&repo);

    let edited = repo.sibling("edited");
    let (_, error) = create(&mut rt, &key, "edited", new_branch("main"), &edited);
    assert!(error.is_none(), "{error:?}");
    fs::write(edited.join("a.txt"), "changed\n").unwrap();
    let error = outcome(&mut rt, &key, |rt| rt.undo_new_worktree(&key, &edited)).expect("refused");
    assert_eq!(error.kind, GitErrorKind::LocalChanges, "{error}");
    assert!(edited.join("a.txt").is_file());

    let committed = repo.sibling("committed");
    let (_, error) = create(&mut rt, &key, "committed", new_branch("main"), &committed);
    assert!(error.is_none(), "{error:?}");
    repo.command_in(&committed)
        .args(["commit", "--quiet", "--allow-empty", "-m", "work"])
        .run()
        .unwrap();
    let undo = |rt: &mut Runtime| rt.undo_new_worktree(&key, &committed);
    let error = outcome(&mut rt, &key, undo).expect("refused");
    assert!(error.stderr.contains("new commits"), "{error}");
    settle_worktrees(&mut rt, &key);
    assert!(listed(&rt, &key, &committed));
    assert!(rt.repo(&key).unwrap().branch("committed").is_some());
}

#[test]
fn undo_stops_a_running_setup() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let (mut rt, key) = open(&repo);
    // Longer than the tests wait for anything.
    let slow = if cfg!(windows) {
        "ping -n 60 127.0.0.1 > nul"
    } else {
        "sleep 60"
    };
    rt.set_worktree_setup(&key, WorktreeSetup::cleaned(&[], slow));
    let path = repo.sibling("slow setup");
    let (_, error) = create(&mut rt, &key, "slow", new_branch("main"), &path);
    assert!(error.is_none(), "{error:?}");
    rt.run_worktree_setup(&key, &path).expect("a setup");
    std::thread::sleep(Duration::from_millis(300));

    ok(&mut rt, &key, |rt| rt.undo_new_worktree(&key, &path));
    assert!(!path.exists());
    poll_until(&mut rt, |rt, _| {
        !rt.repo(&key).unwrap().setup_running(&path)
    });
    assert!(rt.repo(&key).unwrap().branch("slow").is_none());
}

#[test]
fn cleanup_finds_merged_and_gone_worktrees_and_removes_them() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.add_remote();
    // merged: at main. gone: pushed, then deleted on the remote. active:
    // its own commit. dirty: merged but with a local change.
    let merged = repo.add_worktree("merged", "wt merged");
    let gone = repo.add_worktree("gone", "wt gone");
    repo.command_in(&gone)
        .args([
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "squashed elsewhere",
        ])
        .run()
        .unwrap();
    repo.git(&["push", "--quiet", "-u", "origin", "gone"]);
    repo.git(&["push", "--quiet", "origin", "--delete", "gone"]);
    repo.git(&["fetch", "--quiet", "--prune", "origin"]);
    let active = repo.add_worktree("active", "wt active");
    repo.command_in(&active)
        .args(["commit", "--quiet", "--allow-empty", "-m", "work"])
        .run()
        .unwrap();
    let dirty = repo.add_worktree("dirty", "wt dirty");
    fs::write(dirty.join("a.txt"), "changed\n").unwrap();
    let (mut rt, key) = open(&repo);
    settle_worktrees(&mut rt, &key);

    rt.load_cleanup(&key).expect("scan starts");
    poll_until(&mut rt, |_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::CleanupLoaded { .. }))
    });
    let mut found: Vec<(String, CleanupReason)> = rt
        .repo(&key)
        .unwrap()
        .cleanup()
        .unwrap()
        .iter()
        .map(|c| (c.branch.clone(), c.reason))
        .collect();
    found.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(
        found,
        [
            ("dirty".to_owned(), CleanupReason::Merged),
            ("gone".to_owned(), CleanupReason::UpstreamGone),
            ("merged".to_owned(), CleanupReason::Merged),
        ]
    );

    // Without force the dirty one fails; the others still go.
    let items = vec![
        (merged.clone(), "merged".to_owned(), false),
        (gone.clone(), "gone".to_owned(), false),
        (dirty.clone(), "dirty".to_owned(), false),
    ];
    let err =
        outcome(&mut rt, &key, |rt| rt.cleanup(&key, items, true, false)).expect("dirty refuses");
    assert!(err.stderr.contains("modified or untracked"), "{err}");
    settle_worktrees(&mut rt, &key);
    let state = rt.repo(&key).unwrap();
    assert!(!merged.exists() && !gone.exists() && dirty.exists());
    assert!(state.branch("merged").is_none() && state.branch("gone").is_none());
    assert!(state.branch("dirty").is_some() && state.branch("active").is_some());
}

/// A program started from inside the worktree (a copy of `findstr`, which
/// runs until its stdin closes), like an app built and launched there.
#[cfg(windows)]
fn run_from(folder: &Path) -> std::process::Child {
    let system =
        PathBuf::from(std::env::var_os("SystemRoot").expect("SystemRoot")).join("System32");
    let bin = folder.join("bin");
    fs::create_dir_all(&bin).expect("bin folder");
    let exe = bin.join("held.exe");
    fs::copy(system.join("findstr.exe"), &exe).expect("copy findstr");
    std::process::Command::new(&exe)
        .arg("x")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .spawn()
        .expect("start the copy")
}

#[cfg(windows)]
#[test]
fn a_program_running_from_a_worktree_stops_its_removal() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let linked = repo.add_worktree("linked", "in üse");
    let (mut rt, key) = open(&repo);
    let mut child = run_from(&linked);
    let remove = || WorktreeOp::Remove {
        path: linked.clone(),
        force: true,
    };

    let err = outcome(&mut rt, &key, |rt| rt.worktree_op(&key, remove())).expect("in use");
    assert_eq!(err.kind, GitErrorKind::InUse, "{err}");
    assert!(
        err.stderr
            .starts_with(&format!("error: held.exe (PID {})", child.id())),
        "{err}"
    );
    settle_worktrees(&mut rt, &key);
    assert!(listed(&rt, &key, &linked), "still a worktree");
    assert!(linked.join("a.txt").is_file(), "nothing was deleted");

    child.kill().unwrap();
    child.wait().unwrap();
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, remove()));
    assert!(!linked.exists());
}

#[cfg(windows)]
#[test]
fn a_folder_git_could_not_fully_delete_is_deleted_by_removing_again() {
    use std::os::windows::fs::OpenOptionsExt;

    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let linked = repo.add_worktree("linked", "held");
    let (mut rt, key) = open(&repo);
    // Open without sharing, as some editors do: git deletes the files
    // before it, unregisters the worktree, and leaves the rest.
    fs::create_dir_all(linked.join("sub")).unwrap();
    fs::write(linked.join("sub").join("held.txt"), "x\n").unwrap();
    let held = fs::OpenOptions::new()
        .read(true)
        .share_mode(0)
        .open(linked.join("sub").join("held.txt"))
        .unwrap();
    let remove = || WorktreeOp::Remove {
        path: linked.clone(),
        force: true,
    };

    let err = outcome(&mut rt, &key, |rt| rt.worktree_op(&key, remove())).expect("left");
    assert_eq!(err.kind, GitErrorKind::FolderLeft, "{err}");
    assert!(
        err.stderr.contains("failed to delete"),
        "git's error too: {err}"
    );
    settle_worktrees(&mut rt, &key);
    assert!(!listed(&rt, &key, &linked), "git unregistered it");
    assert!(linked.join("sub").join("held.txt").exists());

    drop(held);
    ok(&mut rt, &key, |rt| rt.worktree_op(&key, remove()));
    assert!(!linked.exists(), "the rest is deleted");
    // Without a leftover to finish, an unknown folder is git's to refuse.
    fs::create_dir_all(&linked).unwrap();
    let err = outcome(&mut rt, &key, |rt| rt.worktree_op(&key, remove())).expect("unknown");
    assert!(err.stderr.contains("is not a working tree"), "{err}");
    assert!(linked.exists());
}

#[test]
fn a_deleted_worktree_folder_is_reported_once() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let linked = repo.add_worktree("linked", "lïnked");
    let mut config = Config::default();
    config.auto_fetch_minutes = 0;
    let mut rt = Runtime::with_runner(config, None, repo.app_runner());
    let key = rt.open(&linked);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).and_then(|s| s.status()).is_some()
    });
    assert_eq!(rt.repo(&key).unwrap().display_name(), "wörk tree/lïnked");

    // On Windows a refresh running in the folder (started by the deletion
    // itself) briefly blocks removing it, as it would for Explorer: retry.
    // A failed attempt may already have removed `.git`, so the events
    // polled meanwhile can hold the one Missing: keep them.
    let mut events = Vec::new();
    for attempt in 0.. {
        match fs::remove_dir_all(&linked) {
            Ok(()) => break,
            Err(err) if attempt < 100 => {
                let _ = err;
                events.extend(rt.poll());
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(err) => panic!("cannot delete the worktree folder: {err}"),
        }
    }
    rt.on_focus(&key);
    events.extend(poll_until(&mut rt, |rt, _| {
        rt.repo(&key).unwrap().is_missing()
    }));
    // Later refreshes are not tried; the ones already queued fail quietly.
    rt.on_focus(&key);
    events.extend(poll_until(&mut rt, |rt, _| rt.pending_jobs() == 0));
    events.extend(rt.poll());
    let missing = events
        .iter()
        .filter(|e| matches!(e, RuntimeEvent::Missing { .. }))
        .count();
    let failed = events
        .iter()
        .any(|e| matches!(e, RuntimeEvent::RefreshFailed { .. }));
    assert!(missing == 1 && !failed, "{events:#?}");
}

#[test]
fn a_worktree_folder_left_by_a_deletion_is_missing() {
    // Windows keeps a folder another program has open until it lets go:
    // its files are gone (`.git` among them) but the folder is still there.
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let linked = repo.add_worktree("linked", "left");
    let mut config = Config::default();
    config.auto_fetch_minutes = 0;
    let mut rt = Runtime::with_runner(config, None, repo.app_runner());
    let key = rt.open(&linked);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).and_then(|s| s.status()).is_some()
    });
    fs::remove_file(linked.join(".git")).unwrap();
    fs::remove_file(linked.join("a.txt")).unwrap();
    rt.on_focus(&key);
    let mut events = poll_until(&mut rt, |rt, _| rt.repo(&key).unwrap().is_missing());
    events.extend(poll_until(&mut rt, |rt, _| rt.pending_jobs() == 0));
    events.extend(rt.poll());
    let missing = events
        .iter()
        .filter(|e| matches!(e, RuntimeEvent::Missing { .. }))
        .count();
    let reported = events.iter().any(|e| {
        matches!(
            e,
            RuntimeEvent::RefreshFailed { .. }
                | RuntimeEvent::Job {
                    state: JobState::Finished(Some(_)),
                    ..
                }
        )
    });
    assert!(missing == 1 && !reported, "{events:#?}");
}

#[test]
fn badges_follow_changes_made_in_another_open_worktree() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let linked = repo.add_worktree("linked", "linked");
    let (mut rt, main_key) = open(&repo);
    let linked_key = rt.open(&linked);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&linked_key).and_then(|s| s.status()).is_some()
            && rt.repo(&main_key).and_then(|s| s.worktrees()).is_some()
    });
    fs::write(linked.join("new.txt"), "x\n").unwrap();
    rt.on_focus(&linked_key);
    poll_until(&mut rt, |rt, _| {
        let main = rt.repo(&main_key).unwrap();
        let path = main.worktrees().unwrap()[1].path.clone();
        main.worktree_badge(&path).is_some_and(|b| b.changed == 1)
    });
}
