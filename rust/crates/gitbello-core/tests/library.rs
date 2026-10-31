//! The repository library behind Home (PLAN §4 Home, M7.5): entries from
//! opening, summaries, location checks, folder scans, and the Create,
//! Initialize folder and Clone flows.

mod support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::config::Config;
use gitbello_core::git::{CancelToken, GitErrorKind};
use gitbello_core::library::{path_key, FILE_NAME};
use gitbello_core::new_repo::{CloneOptions, CreateOptions, FIRST_COMMIT_MESSAGE};
use gitbello_core::runtime::{normalize, JobState, Runtime, RuntimeEvent};
use gitbello_core::scan;
use support::rt::{finish, poll_until, result, succeed};
use support::{path_arg, TempDir, TestRepo};

fn runtime(repo: &TestRepo) -> Runtime {
    let mut config = Config::default();
    config.auto_fetch_minutes = 0;
    Runtime::with_runner(config, None, repo.app_runner())
}

/// A runtime whose library file is `library.toml` next to the repository.
fn runtime_with_library(repo: &TestRepo) -> (Runtime, PathBuf) {
    let mut rt = runtime(repo);
    let file = repo.sibling("dätä").join(FILE_NAME);
    assert!(rt.load_library(Some(file.clone())).is_none());
    (rt, file)
}

fn open_and_wait(rt: &mut Runtime, path: &Path) -> Vec<RuntimeEvent> {
    let key = rt.open(path);
    poll_until(rt, |rt, _| rt.repo(&key).is_some_and(|s| s.is_ready()))
}

fn same(a: &Path, b: &Path) -> bool {
    path_key(&normalize(a)) == path_key(&normalize(b))
}

fn entry_paths(rt: &Runtime) -> Vec<PathBuf> {
    rt.library()
        .entries()
        .iter()
        .map(|e| e.path.clone())
        .collect()
}

#[test]
fn opening_a_subfolder_or_linked_worktree_lists_its_repository() {
    let repo = TestRepo::init();
    repo.write("sub dir/a.txt", "a\n");
    repo.commit("a.txt", "a\n", "first");
    let worktree = repo.add_worktree("task", "wörktree");
    let (mut rt, file) = runtime_with_library(&repo);

    let events = open_and_wait(&mut rt, &repo.path().join("sub dir"));
    assert!(events
        .iter()
        .any(|e| matches!(e, RuntimeEvent::LibraryChanged { error: None })));
    open_and_wait(&mut rt, &worktree);
    let paths = entry_paths(&rt);
    assert_eq!(paths.len(), 1, "{paths:?}");
    assert!(same(&paths[0], repo.path()), "{paths:?}");
    assert!(rt.library().entries()[0].last_opened_at.is_some());

    // Saved: a new runtime reads the same entry.
    let mut other = runtime(&repo);
    assert!(other.load_library(Some(file)).is_none());
    assert_eq!(entry_paths(&other), paths);
}

#[test]
fn imports_the_old_recent_list_into_a_new_library() {
    let repo = TestRepo::init();
    let mut config = Config::default();
    config.known_repos = vec![repo.path().to_path_buf(), repo.sibling("gone")];
    let mut rt = Runtime::with_runner(config, None, repo.app_runner());
    let file = repo.sibling("data").join(FILE_NAME);
    assert!(rt.load_library(Some(file.clone())).is_none());
    let recent: Vec<String> = rt.library().recent(8).iter().map(|e| e.name()).collect();
    assert_eq!(recent, ["wörk tree", "gone"]);
    assert!(file.exists());
}

#[test]
fn library_edits_save_and_report() {
    let repo = TestRepo::init();
    let (mut rt, file) = runtime_with_library(&repo);
    let other = repo.non_repo_dir();
    assert!(rt.library_add(repo.path()));
    assert!(!rt.library_add(repo.path()));
    assert!(rt.library_add(&other));
    assert!(rt.library_rename(repo.path(), "Main repo"));
    assert!(rt.library_pin(repo.path(), true));
    assert!(rt.library_remove(&other));
    let events = rt.poll();
    let changes = events
        .iter()
        .filter(|e| matches!(e, RuntimeEvent::LibraryChanged { error: None }))
        .count();
    assert_eq!(changes, 5);
    assert_eq!(
        rt.library_undo_remove().map(|p| same(&p, &other)),
        Some(true)
    );
    let moved = repo.sibling("moved");
    assert!(rt.library_relocate(repo.path(), &moved));

    let mut loaded = runtime(&repo);
    assert!(loaded.load_library(Some(file)).is_none());
    let entry = loaded.library().get(&moved).expect("relocated entry");
    assert_eq!(entry.name(), "Main repo");
    assert!(entry.pinned);
    assert!(loaded.library().contains(&other));
    assert!(!loaded.library().contains(repo.path()));
}

#[test]
fn summaries_report_branch_changes_upstream_and_missing() {
    let repo = TestRepo::init();
    let root = repo.commit("a.txt", "a\n", "first");
    repo.add_remote();
    repo.commit("b.txt", "b\n", "second");
    repo.write("a.txt", "changed\n");
    repo.write("new.txt", "new\n");

    let unborn = repo.sibling("unborn");
    fs::create_dir_all(&unborn).unwrap();
    repo.command_in(&unborn)
        .args(["init", "--quiet", "--initial-branch=trunk"])
        .run()
        .unwrap();
    let detached = repo.clone_remote(&repo.sibling("remöte.git"), "detached");
    repo.command_in(&detached)
        .args(["checkout", "--quiet", "--detach"])
        .run()
        .unwrap();
    let missing = repo.sibling("missing");
    let plain = repo.non_repo_dir();

    let (mut rt, _) = runtime_with_library(&repo);
    for path in [repo.path(), &unborn, &detached, &missing, &plain] {
        rt.library_add(path);
    }
    let paths = entry_paths(&rt);
    rt.load_summaries(&paths);
    // Asking again while they run does not queue them twice.
    rt.load_summaries(&paths);
    let events = poll_until(&mut rt, |rt, _| {
        paths.iter().all(|p| rt.summary(p).is_some())
    });
    let loaded = events
        .iter()
        .filter(|e| matches!(e, RuntimeEvent::SummaryLoaded { .. }))
        .count();
    assert_eq!(loaded, paths.len());

    let main = rt.summary(repo.path()).unwrap();
    assert_eq!(main.branch.as_deref(), Some("main"));
    assert_eq!(
        (main.changes, main.upstream, main.ahead, main.behind),
        (2, true, 1, 0)
    );
    assert_eq!(main.root_commit.as_deref(), Some(root.as_str()));
    assert_eq!(
        rt.library()
            .get(repo.path())
            .unwrap()
            .root_commit
            .as_deref(),
        Some(root.as_str())
    );

    let unborn = rt.summary(&unborn).unwrap();
    assert_eq!(unborn.branch.as_deref(), Some("trunk"));
    assert_eq!((unborn.changes, unborn.root_commit.as_deref()), (0, None));

    let detached = rt.summary(&detached).unwrap();
    assert!(detached.detached && detached.branch.is_none());

    assert!(rt.summary(&missing).unwrap().missing);
    let plain = rt.summary(&plain).unwrap();
    assert!(!plain.missing);
    assert_eq!(
        plain.error.as_ref().map(|e| e.kind),
        Some(GitErrorKind::NotARepository)
    );
}

#[test]
fn location_checks_resolve_the_repository_and_compare_root_commits() {
    let repo = TestRepo::init();
    repo.write("deep/x.txt", "x\n");
    repo.commit("a.txt", "a\n", "first");
    let remote = repo.add_remote();
    let copy = repo.clone_remote(&remote, "cöpy");
    let worktree = repo.add_worktree("task", "task tree");
    let stranger = TestRepo::init();
    stranger.commit("s.txt", "s\n", "other history");

    let (mut rt, _) = runtime_with_library(&repo);
    rt.library_add(repo.path());
    // Record the root commit through a summary.
    rt.load_summaries(&entry_paths(&rt));
    poll_until(&mut rt, |rt, _| {
        rt.library().entries()[0].root_commit.is_some()
    });

    let check = |rt: &mut Runtime, path: &Path, expected_for: Option<&Path>| {
        let job = rt.check_location(path, expected_for);
        let events = poll_until(rt, |_, ev| result(ev, job).is_some());
        assert_eq!(result(&events, job), Some(None));
        rt.take_location(job).expect("a location result")
    };
    let sub = check(&mut rt, &repo.path().join("deep"), None);
    assert!(same(sub.root.as_deref().unwrap(), repo.path()));
    assert_eq!(sub.same_root, None);
    let linked = check(&mut rt, &worktree, None);
    assert!(same(linked.root.as_deref().unwrap(), repo.path()));

    let moved = check(&mut rt, &copy, Some(repo.path()));
    assert!(same(moved.root.as_deref().unwrap(), &copy));
    assert_eq!(moved.same_root, Some(true));
    let different = check(&mut rt, stranger.path(), Some(repo.path()));
    assert_eq!(different.same_root, Some(false));
    let none = check(&mut rt, &repo.non_repo_dir(), Some(repo.path()));
    assert_eq!((none.root, none.same_root), (None, None));
}

#[test]
fn scans_find_repositories_and_fold_worktrees() {
    let fixture = TestRepo::init();
    let dir = TempDir::new("scän");
    let root = dir.path();
    let init = |path: &Path, bare: bool| {
        fs::create_dir_all(path).unwrap();
        let mut cmd = fixture.command_in(path).args(["init", "--quiet"]);
        if bare {
            cmd = cmd.arg("--bare");
        }
        cmd.run().unwrap();
    };
    let alpha = root.join("älpha");
    init(&alpha, false);
    fs::write(alpha.join("f.txt"), "f\n").unwrap();
    fixture
        .command_in(&alpha)
        .args(["add", "f.txt"])
        .run()
        .unwrap();
    fixture
        .command_in(&alpha)
        .args(["commit", "--quiet", "-m", "f"])
        .run()
        .unwrap();
    let wt = root.join("trees").join("alpha task");
    fixture
        .command_in(&alpha)
        .args(["worktree", "add", "--quiet", "-b", "task", &path_arg(&wt)])
        .run()
        .unwrap();
    let nested = root.join("group").join("nested repo");
    init(&nested, false);
    // Not walked into: inside a repository, node_modules, hidden, too deep.
    init(&alpha.join("inner"), false);
    init(&root.join("node_modules").join("pkg"), false);
    init(&root.join(".hidden").join("r"), false);
    init(
        &root.join("one").join("two").join("three").join("deep"),
        false,
    );
    let bare = root.join("store.git");
    init(&bare, true);
    #[cfg(unix)]
    let _ = std::os::unix::fs::symlink(root, root.join("loop"));
    #[cfg(windows)]
    let _ = std::os::windows::fs::symlink_dir(root, root.join("loop"));

    let hits = scan::scan(root, scan::DEFAULT_DEPTH, &CancelToken::new(), |_, _| {});
    let found: Vec<(PathBuf, usize, bool)> = hits
        .iter()
        .map(|h| (h.path.clone(), h.worktrees.len(), h.bare))
        .collect();
    assert_eq!(found.len(), 3, "{found:#?}");
    let find = |path: &Path| hits.iter().find(|h| same(&h.path, path));
    let alpha_hit = find(&alpha).expect("alpha");
    assert_eq!(alpha_hit.worktrees.len(), 1);
    assert!(same(&alpha_hit.worktrees[0], &wt));
    assert!(find(&nested).is_some());
    assert!(find(&bare).is_some_and(|h| h.bare));

    // Deeper scans reach the deep one; a cancelled scan stops at once.
    let deeper = scan::scan(root, 4, &CancelToken::new(), |_, _| {});
    assert_eq!(deeper.len(), 4);
    let cancelled = CancelToken::new();
    cancelled.cancel();
    assert!(scan::scan(root, 4, &cancelled, |_, _| {}).is_empty());

    // Through the runtime, with progress and the hits taken once.
    let mut rt = runtime(&fixture);
    let job = rt.scan(root, scan::DEFAULT_DEPTH);
    let events = poll_until(&mut rt, |_, ev| result(ev, job).is_some());
    assert_eq!(result(&events, job), Some(None));
    assert!(events.iter().any(|e| matches!(
        e,
        RuntimeEvent::Job { job: j, state: JobState::Progress(_), .. } if *j == job
    )));
    assert_eq!(rt.take_scan(job).map(|h| h.len()), Some(3));
    assert!(rt.take_scan(job).is_none());
}

#[test]
fn creates_with_a_template_readme_and_first_commit() {
    let fixture = TestRepo::init();
    let (mut rt, _) = runtime_with_library(&fixture);
    let target = fixture.sibling("new répo");
    let mut options = CreateOptions::new("trunk");
    options.gitignore = Some("Rust".to_owned());
    options.readme = true;
    options.first_commit = true;
    let job = rt.create_repository(&target, options);
    let events = poll_until(&mut rt, |_, ev| result(ev, job).is_some());
    assert_eq!(result(&events, job), Some(None));
    assert!(events
        .iter()
        .any(|e| matches!(e, RuntimeEvent::LibraryChanged { error: None })));
    assert!(rt.library().contains(&target));

    let git = |args: &[&str]| {
        fixture
            .command_in(&target)
            .args(args)
            .run()
            .unwrap()
            .stdout_text()
            .trim()
            .to_owned()
    };
    assert_eq!(git(&["branch", "--show-current"]), "trunk");
    assert_eq!(git(&["log", "-1", "--format=%s"]), FIRST_COMMIT_MESSAGE);
    assert_eq!(git(&["ls-files"]), ".gitignore\nREADME.md");
    assert!(fs::read_to_string(target.join(".gitignore"))
        .unwrap()
        .contains("target/"));
    assert_eq!(
        fs::read_to_string(target.join("README.md")).unwrap(),
        "# new répo\n"
    );
}

#[test]
fn initializes_a_folder_with_files() {
    let fixture = TestRepo::init();
    let mut rt = runtime(&fixture);
    let folder = fixture.non_repo_dir();
    fs::write(folder.join("notes.txt"), "keep me\n").unwrap();
    fs::write(folder.join(".gitignore"), "mine\n").unwrap();
    let mut options = CreateOptions::new("main");
    options.existing = true;
    options.gitignore = Some("Node".to_owned());
    options.first_commit = true;
    let job = rt.create_repository(&folder, options.clone());
    assert!(finish(&mut rt, &folder, Some(job)).is_none());
    let files = fixture
        .command_in(&folder)
        .args(["ls-files"])
        .run()
        .unwrap()
        .stdout_text();
    assert_eq!(files.trim(), ".gitignore\nnotes.txt");
    // An existing .gitignore is left alone.
    assert_eq!(
        fs::read_to_string(folder.join(".gitignore")).unwrap(),
        "mine\n"
    );

    let job = rt.create_repository(&folder, options.clone());
    let error = finish(&mut rt, &folder, Some(job)).expect("a repository already");
    assert_eq!(error.kind, GitErrorKind::AlreadyExists);
    let missing = fixture.sibling("no such folder");
    let job = rt.create_repository(&missing, options);
    assert!(finish(&mut rt, &missing, Some(job)).is_some());
    assert!(!missing.exists());
}

#[test]
fn clones_a_branch_with_submodules() {
    let fixture = TestRepo::init();
    // Local submodules need the file protocol (off by default since git 2.38).
    fs::write(
        fixture.sibling("global.gitconfig"),
        "[protocol \"file\"]\n\tallow = always\n",
    )
    .unwrap();
    let module = fixture.sibling("mödule");
    fs::create_dir_all(&module).unwrap();
    for args in [
        vec!["init", "--quiet", "--initial-branch=main"],
        vec!["commit", "--quiet", "--allow-empty", "-m", "module"],
    ] {
        fixture.command_in(&module).args(args).run().unwrap();
    }
    fixture.commit("a.txt", "a\n", "first");
    fixture.branch("topic");
    fixture.checkout("topic");
    fixture.git(&["submodule", "--quiet", "add", &path_arg(&module), "sub"]);
    fixture.git(&["commit", "--quiet", "-m", "add submodule"]);
    fixture.checkout("main");

    let (mut rt, _) = runtime_with_library(&fixture);
    let target = fixture.sibling("clöne");
    let options = CloneOptions {
        branch: Some("topic".to_owned()),
        submodules: true,
    };
    let job = rt.clone_repository(&path_arg(fixture.path()), &target, options);
    succeed(&mut rt, &target, Some(job));
    let branch = fixture
        .command_in(&target)
        .args(["branch", "--show-current"])
        .run()
        .unwrap()
        .stdout_text();
    assert_eq!(branch.trim(), "topic");
    assert!(target.join("sub").join(".git").exists());
    assert!(rt.library().contains(&target));
}
