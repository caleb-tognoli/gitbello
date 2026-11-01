mod support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::config::Config;
use gitbello_core::diff::{DiffContent, LARGE_DIFF_BYTES};
use gitbello_core::runtime::{DiffState, Runtime};
use support::rt::poll_until;
use support::{TempDir, TestRepo};

fn open(repo: &TestRepo, config: &Path) -> (Runtime, PathBuf) {
    fs::write(config, "").expect("global config");
    let mut settings = Config::default();
    settings.auto_fetch_minutes = 0;
    let runner = repo.app_runner().with_env("GIT_CONFIG_GLOBAL", config);
    let mut rt = Runtime::with_runner(settings, None, runner);
    let key = rt.open(repo.path());
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .is_some_and(|s| s.status().is_some() && s.refs().is_some())
            && rt.pending_jobs() == 0
    });
    (rt, key)
}

fn break_diff(config: &Path) {
    fs::write(config, "[invalid-retry-test\n").expect("invalid diff config");
}

fn state<'a>(rt: &'a Runtime, key: &Path, commit: bool) -> &'a DiffState {
    let repo = rt.repo(key).expect("repo");
    if commit {
        repo.commit_diff()
    } else {
        repo.diff()
    }
    .expect("diff state")
}

fn wait(rt: &mut Runtime, key: &Path, commit: bool, error: bool) {
    poll_until(rt, |rt, _| {
        let diff = state(rt, key, commit);
        !diff.is_loading() && diff.error().is_some() == error && rt.pending_jobs() == 0
    });
}

/// Git commands run so far, minus the status, refs and stash refreshes the
/// file watcher can start at any time: on Windows a repository with a stash
/// reports a change to `.git/refs/heads` a debounce after it opens, and under
/// load that refresh lands between two counts.
fn diff_commands(rt: &Runtime) -> usize {
    const REFRESHES: [&str; 5] = ["status", "remote", "for-each-ref", "stash", "worktree"];
    rt.command_log()
        .records_since(0)
        .iter()
        .filter(|r| !REFRESHES.contains(&r.command.split(' ').next().unwrap_or_default()))
        .count()
}

#[test]
fn failed_changes_commit_and_shelf_retry_without_reselecting() {
    for mode in ["changes", "commit", "shelf"] {
        let repo = TestRepo::init();
        repo.commit("f.txt", "base\n", "base");
        let oid = repo.commit("f.txt", "next\n", "next");
        repo.write("f.txt", "edit\n");
        let shelf = if mode == "shelf" {
            repo.git(&["stash", "push", "-m", "retry shelf"]);
            Some(repo.git(&["rev-parse", "refs/stash"]))
        } else {
            None
        };
        let temp = TempDir::new("retry config");
        let config = temp.path().join("global.gitconfig");
        let (mut rt, key) = open(&repo, &config);
        if mode == "commit" {
            rt.load_commit(&key, &oid);
            poll_until(&mut rt, |rt, _| {
                rt.repo(&key).and_then(|s| s.commit()).is_some()
            });
        }
        if let Some(oid) = &shelf {
            rt.load_shelf_files(&key, oid).expect("shelf files job");
            poll_until(&mut rt, |rt, _| {
                rt.repo(&key).and_then(|s| s.shelf_files(oid)).is_some()
            });
        }
        let select = |rt: &mut Runtime| match mode {
            "commit" => rt.select_commit_file(&key, Some(Path::new("f.txt")), false),
            "shelf" => rt.select_shelf_file(
                &key,
                shelf.as_deref().expect("shelf"),
                Path::new("f.txt"),
                false,
            ),
            _ => rt.select_change(&key, Path::new("f.txt"), false),
        };
        break_diff(&config);
        select(&mut rt);
        wait(&mut rt, &key, mode == "commit", true);
        let target = state(&rt, &key, mode == "commit").target().clone();
        let before = diff_commands(&rt);
        select(&mut rt);
        assert!(
            state(&rt, &key, mode == "commit").is_loading(),
            "{mode}: retry starts"
        );
        select(&mut rt);
        wait(&mut rt, &key, mode == "commit", true);
        assert_eq!(
            diff_commands(&rt),
            before + 1,
            "{mode}: loading requests deduplicate"
        );
        fs::write(&config, "").expect("repair config");
        select(&mut rt);
        wait(&mut rt, &key, mode == "commit", false);
        assert_eq!(state(&rt, &key, mode == "commit").target(), &target);
        assert!(state(&rt, &key, mode == "commit").diff().is_some());
        let before = diff_commands(&rt);
        select(&mut rt);
        assert!(!state(&rt, &key, mode == "commit").is_loading());
        assert_eq!(
            diff_commands(&rt),
            before,
            "{mode}: successful requests deduplicate"
        );
    }
}

#[test]
fn retry_keeps_the_size_limit_and_previous_full_load_consent() {
    for full in [false, true] {
        let repo = TestRepo::init();
        repo.commit("f.txt", "base\n", "base");
        repo.write("f.txt", &"changed line\n".repeat(LARGE_DIFF_BYTES / 8));
        let temp = TempDir::new("retry size config");
        let config = temp.path().join("global.gitconfig");
        let (mut rt, key) = open(&repo, &config);
        break_diff(&config);
        rt.select_change(&key, Path::new("f.txt"), full);
        wait(&mut rt, &key, false, true);
        fs::write(&config, "").expect("repair config");
        rt.select_change(&key, Path::new("f.txt"), false);
        wait(&mut rt, &key, false, false);
        let content = state(&rt, &key, false).diff().expect("loaded").content;
        assert_eq!(matches!(content, DiffContent::TooLarge { .. }), !full);
    }
}

#[test]
fn retry_preserves_open_gaps_and_commit_selection() {
    let repo = TestRepo::init();
    let original = (0..100).map(|n| format!("line {n}\n")).collect::<String>();
    repo.commit("f.txt", &original, "base");
    repo.write("f.txt", &original.replace("line 50\n", "changed\n"));
    let temp = TempDir::new("retry expansion config");
    let config = temp.path().join("global.gitconfig");
    let (mut rt, key) = open(&repo, &config);
    rt.select_change(&key, Path::new("f.txt"), false);
    wait(&mut rt, &key, false, false);
    rt.show_whole_diff(&key, gitbello_core::runtime::DiffSlot::Changes, true);
    poll_until(&mut rt, |rt, _| rt.pending_jobs() == 0);
    rt.pick_all(&key, false);
    let diff = state(&rt, &key, false).diff().expect("loaded diff");
    let added = (0..diff.line_count())
        .find(|&row| {
            diff.line(row)
                .is_some_and(|line| line.kind == gitbello_core::diff::LineKind::Added)
        })
        .expect("added line");
    assert!(rt.pick_lines(&key, &[added], true));
    let selection = rt
        .repo(&key)
        .expect("repo")
        .selection()
        .pick(Path::new("f.txt"))
        .cloned();
    assert!(matches!(
        selection,
        Some(gitbello_core::changes::FilePick::Lines(_))
    ));
    break_diff(&config);
    rt.select_change(&key, Path::new("f.txt"), true);
    wait(&mut rt, &key, false, true);
    fs::write(&config, "").expect("repair config");
    rt.select_change(&key, Path::new("f.txt"), false);
    wait(&mut rt, &key, false, false);
    assert!(state(&rt, &key, false).expansion().is_whole());
    assert_eq!(
        rt.repo(&key)
            .expect("repo")
            .selection()
            .pick(Path::new("f.txt"))
            .cloned(),
        selection
    );
}

#[test]
fn failed_conflict_preview_retries_the_same_path() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "base\n", "base");
    repo.branch("topic");
    repo.commit("f.txt", "main\n", "main");
    repo.checkout("topic");
    repo.commit("f.txt", "topic\n", "topic");
    repo.checkout("main");
    let error = repo
        .try_git(&["merge", "--no-edit", "topic"])
        .expect_err("fixture merge conflicts");
    assert_eq!(error.kind, gitbello_core::git::GitErrorKind::Conflict);
    let temp = TempDir::new("conflict retry config");
    let config = temp.path().join("global.gitconfig");
    let (mut rt, key) = open(&repo, &config);
    let path = Path::new("f.txt");
    let wait_conflict = |rt: &mut Runtime, error: bool| {
        poll_until(rt, |rt, _| {
            rt.repo(&key)
                .and_then(|s| s.conflict())
                .is_some_and(|c| !c.is_loading() && c.error().is_some() == error)
                && rt.pending_jobs() == 0
        });
    };
    break_diff(&config);
    rt.select_change(&key, path, false);
    wait_conflict(&mut rt, true);
    let before = diff_commands(&rt);
    rt.select_change(&key, path, false);
    assert!(rt.repo(&key).unwrap().conflict().unwrap().is_loading());
    rt.select_change(&key, path, false);
    wait_conflict(&mut rt, true);
    assert_eq!(diff_commands(&rt), before + 1, "loading retry deduplicates");
    fs::write(&config, "").expect("repair config");
    rt.select_change(&key, path, false);
    wait_conflict(&mut rt, false);
    let conflict = rt.repo(&key).unwrap().conflict().unwrap();
    assert_eq!(conflict.path(), path);
    assert!(conflict.file().is_some());
    let before = diff_commands(&rt);
    rt.select_change(&key, path, false);
    assert_eq!(diff_commands(&rt), before, "ready preview deduplicates");
}
