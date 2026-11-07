//! Ignore rules from the Changes view (M7.7a): previews, writing rules to
//! `.gitignore` and `info/exclude`, untracking and undo, on real temporary
//! repositories.

mod support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::changes::PickState;
use gitbello_core::config::Config;
use gitbello_core::git::GitErrorKind;
use gitbello_core::ignore::{IgnorePreview, IgnoreRule, IgnoreTarget, Untrack};
use gitbello_core::repo::FileState;
use gitbello_core::runtime::{Runtime, RuntimeEvent};
use support::rt::{finish, open, poll_until, settle, succeed};
use support::TestRepo;

fn shared(pattern: &str) -> IgnoreRule {
    IgnoreRule {
        pattern: pattern.to_owned(),
        target: IgnoreTarget::Shared {
            dir: PathBuf::new(),
        },
    }
}

fn preview(rt: &mut Runtime, key: &Path, rule: IgnoreRule) -> IgnorePreview {
    let job = rt.load_ignore_preview(key, rule).expect("preview starts");
    poll_until(rt, |_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::IgnorePreviewLoaded { job: j, .. } if *j == job))
    });
    rt.ignore_preview(key).expect("preview").clone()
}

/// Paths status lists (ignored ones left out).
fn listed(rt: &Runtime, key: &Path) -> Vec<String> {
    rt.repo(key)
        .and_then(|s| s.status())
        .map(|s| {
            s.changes
                .iter()
                .filter(|c| c.state != FileState::Ignored)
                .map(|c| c.path.to_string_lossy().replace('\\', "/"))
                .collect()
        })
        .unwrap_or_default()
}

fn index_has(repo: &TestRepo, path: &str) -> bool {
    !repo.git(&["ls-files", "--", path]).trim().is_empty()
}

/// A repository with tracked build output, plus untracked logs and assets.
fn project() -> TestRepo {
    let repo = TestRepo::init();
    repo.write("build/a.o", "object a\n");
    repo.commit("src/main.c", "int main;\n", "base");
    repo.git(&["add", "-f", "build/a.o"]);
    repo.git(&["commit", "-q", "-m", "track build output"]);
    repo.write("build/b.o", "object b\n");
    repo.write("logs/x.log", "log\n");
    repo.write("src/game/assets/hero.import", "import\n");
    repo.write("hero.import", "root import\n");
    repo
}

#[test]
fn preview_counts_hidden_changes_and_tracked_matches() {
    let repo = project();
    let (mut rt, key) = open(&repo);

    let build = preview(&mut rt, &key, shared("/build/"));
    assert_eq!(build.hidden_sample, vec![PathBuf::from("build/b.o")]);
    assert_eq!(build.tracked_sample, vec![PathBuf::from("build/a.o")]);
    assert!(!build.exists);
    assert_eq!(build.warning, None);

    let logs = preview(&mut rt, &key, shared("*.log"));
    assert_eq!((logs.hidden_count, logs.tracked_count), (1, 0));

    let below = preview(&mut rt, &key, shared("/src/game/**/*.import"));
    assert_eq!(
        below.hidden_sample,
        vec![PathBuf::from("src/game/assets/hero.import")]
    );
    let everywhere = preview(&mut rt, &key, shared("*.import"));
    assert_eq!(everywhere.hidden_count, 2);

    let everything = preview(&mut rt, &key, shared("*"));
    assert_eq!(
        everything.warning.map(|w| w.id()),
        Some("matches_everything")
    );
}

#[test]
fn adds_a_rule_and_undo_takes_it_back() {
    let repo = project();
    let (mut rt, key) = open(&repo);
    assert!(listed(&rt, &key).contains(&"logs/x.log".to_owned()));

    let job = rt.add_ignore_rule(&key, shared("*.log"), Untrack::Keep);
    succeed(&mut rt, &key, job);
    assert_eq!(
        fs::read_to_string(repo.path().join(".gitignore")).unwrap(),
        "*.log\n"
    );
    assert!(!listed(&rt, &key).contains(&"logs/x.log".to_owned()));
    assert!(listed(&rt, &key).contains(&".gitignore".to_owned()));
    assert!(preview(&mut rt, &key, shared("*.log")).exists);

    // The same rule again writes nothing and leaves no undo behind it.
    let job = rt.add_ignore_rule(&key, shared("*.log"), Untrack::Keep);
    succeed(&mut rt, &key, job);
    assert_eq!(
        fs::read_to_string(repo.path().join(".gitignore")).unwrap(),
        "*.log\n"
    );

    assert!(rt.can_undo_ignore(&key));
    let job = rt.undo_ignore(&key);
    succeed(&mut rt, &key, job);
    assert!(!repo.path().join(".gitignore").exists());
    assert!(listed(&rt, &key).contains(&"logs/x.log".to_owned()));
    assert!(!rt.can_undo_ignore(&key));
}

#[test]
fn quick_rules_refuse_when_tracked_files_match() {
    let repo = project();
    let (mut rt, key) = open(&repo);
    let job = rt.add_ignore_rule(&key, shared("/build/"), Untrack::RefuseIfTracked);
    let error = finish(&mut rt, &key, job).expect("refused");
    assert_eq!(error.kind, GitErrorKind::TrackedMatches);
    assert!(!repo.path().join(".gitignore").exists());
    assert!(!rt.can_undo_ignore(&key));

    // Without tracked matches the quick rule goes through.
    let job = rt.add_ignore_rule(&key, shared("/logs/"), Untrack::RefuseIfTracked);
    succeed(&mut rt, &key, job);
    assert_eq!(
        fs::read_to_string(repo.path().join(".gitignore")).unwrap(),
        "/logs/\n"
    );
}

#[test]
fn untracking_keeps_the_file_and_the_commit_removes_it() {
    let repo = project();
    let (mut rt, key) = open(&repo);
    // Leave .gitignore out first: untracking includes it again.
    fs::write(repo.path().join(".gitignore"), "*.tmp\n").unwrap();
    settle(&mut rt, &key);
    rt.pick_files(&key, &[PathBuf::from(".gitignore")], false);

    let job = rt.add_ignore_rule(&key, shared("/build/"), Untrack::Remove);
    succeed(&mut rt, &key, job);
    assert!(
        repo.path().join("build/a.o").is_file(),
        "the file stays on disk"
    );
    assert!(!index_has(&repo, "build/a.o"));
    assert_eq!(
        fs::read_to_string(repo.path().join(".gitignore")).unwrap(),
        "*.tmp\n/build/\n"
    );
    let state = rt.repo(&key).unwrap();
    assert_eq!(
        state.selection().state(Path::new(".gitignore")),
        PickState::All
    );
    assert_eq!(
        state.selection().state(Path::new("build/a.o")),
        PickState::All
    );
    assert!(!listed(&rt, &key).contains(&"build/b.o".to_owned()));

    let job = rt.commit(&key, "Stop tracking build output\n".into(), false);
    succeed(&mut rt, &key, job);
    let tree = repo.git(&["ls-tree", "-r", "--name-only", "HEAD"]);
    assert!(!tree.contains("build/a.o"), "{tree}");
    assert!(tree.contains(".gitignore"), "{tree}");
    assert!(repo.path().join("build/a.o").is_file());
    assert!(listed(&rt, &key).iter().all(|p| !p.starts_with("build/")));
}

#[test]
fn undo_restores_untracked_files_with_their_staged_content() {
    let repo = project();
    repo.commit("conf/app.cfg", "v1\n", "config");
    repo.write("conf/app.cfg", "v2\n");
    repo.git(&["add", "conf/app.cfg"]);
    let staged = repo.git(&["ls-files", "-s", "--", "conf/app.cfg"]);
    let (mut rt, key) = open(&repo);

    let job = rt.add_ignore_rule(&key, shared("/conf/"), Untrack::Remove);
    succeed(&mut rt, &key, job);
    assert!(!index_has(&repo, "conf/app.cfg"));

    let job = rt.undo_ignore(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(repo.git(&["ls-files", "-s", "--", "conf/app.cfg"]), staged);
    assert!(!repo.path().join(".gitignore").exists());
    assert_eq!(
        fs::read_to_string(repo.path().join("conf/app.cfg")).unwrap(),
        "v2\n"
    );
}

#[test]
fn untracking_refuses_staged_content_that_would_be_lost() {
    let repo = project();
    repo.commit("conf/app.cfg", "v1\n", "config");
    repo.write("conf/app.cfg", "v2\n");
    repo.git(&["add", "conf/app.cfg"]);
    repo.write("conf/app.cfg", "v3\n");
    let (mut rt, key) = open(&repo);

    let job = rt.add_ignore_rule(&key, shared("/conf/"), Untrack::Remove);
    assert!(finish(&mut rt, &key, job).is_some());
    assert!(index_has(&repo, "conf/app.cfg"));
    assert!(
        !repo.path().join(".gitignore").exists(),
        "the rule is taken back"
    );
}

#[test]
fn undo_after_an_outside_edit_removes_only_the_rules_lines() {
    let repo = project();
    let (mut rt, key) = open(&repo);
    let job = rt.add_ignore_rule(&key, shared("*.log\n/build/"), Untrack::Keep);
    succeed(&mut rt, &key, job);
    let gitignore = repo.path().join(".gitignore");
    fs::write(&gitignore, "# mine\n*.log\n/build/\nnode_modules/\n").unwrap();

    let job = rt.undo_ignore(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(
        fs::read_to_string(&gitignore).unwrap(),
        "# mine\nnode_modules/\n"
    );

    let job = rt.add_ignore_rule(&key, shared("*.log"), Untrack::Keep);
    succeed(&mut rt, &key, job);
    fs::write(&gitignore, "node_modules/\n").unwrap();
    let job = rt.undo_ignore(&key);
    let error = finish(&mut rt, &key, job).expect("refused");
    assert_eq!(error.kind, GitErrorKind::Stale);
    assert_eq!(fs::read_to_string(&gitignore).unwrap(), "node_modules/\n");
}

#[test]
fn nested_gitignore_keeps_crlf_and_scopes_the_rule() {
    let repo = project();
    fs::write(repo.path().join("src/.gitignore"), "*.bak\r\n").unwrap();
    let (mut rt, key) = open(&repo);
    assert_eq!(
        rt.ignore_files(&key, &[PathBuf::from("src/game/assets/hero.import")]),
        vec![PathBuf::new(), PathBuf::from("src")]
    );
    assert_eq!(
        rt.ignore_files(&key, &[PathBuf::from("hero.import")]),
        vec![PathBuf::new()]
    );

    let rule = IgnoreRule {
        pattern: "*.import".into(),
        target: IgnoreTarget::Shared { dir: "src".into() },
    };
    let seen = preview(&mut rt, &key, rule.clone());
    assert_eq!(
        seen.hidden_sample,
        vec![PathBuf::from("src/game/assets/hero.import")]
    );
    let job = rt.add_ignore_rule(&key, rule, Untrack::Keep);
    succeed(&mut rt, &key, job);
    assert_eq!(
        fs::read(repo.path().join("src/.gitignore")).unwrap(),
        b"*.bak\r\n*.import\r\n"
    );
    let shown = listed(&rt, &key);
    assert!(!shown.contains(&"src/game/assets/hero.import".to_owned()));
    assert!(shown.contains(&"hero.import".to_owned()));
}

#[test]
fn local_rules_go_to_the_shared_exclude_file() {
    let repo = project();
    repo.git(&["add", "logs/x.log"]);
    repo.git(&["commit", "-q", "-m", "log"]);
    repo.write("logs/y.log", "y\n");
    let linked = repo.add_worktree("topic", "linked worktree é");
    fs::write(linked.join("notes.tmp"), "n\n").unwrap();
    let mut config = Config::default();
    config.auto_fetch_minutes = 0;
    let mut rt = Runtime::with_runner(config, None, repo.app_runner());
    let key = rt.open(&linked);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).is_some_and(|s| s.status().is_some())
    });

    let rule = IgnoreRule {
        pattern: "*.tmp".into(),
        target: IgnoreTarget::Local,
    };
    let job = rt.add_ignore_rule(&key, rule, Untrack::Keep);
    succeed(&mut rt, &key, job);
    let exclude = fs::read_to_string(repo.path().join(".git/info/exclude")).unwrap();
    assert!(
        exclude.ends_with("\n*.tmp\n") || exclude == "*.tmp\n",
        "{exclude:?}"
    );
    assert!(!listed(&rt, &key).contains(&"notes.tmp".to_owned()));
    assert!(!linked.join(".gitignore").exists());
    // The main worktree sees it too.
    fs::write(repo.path().join("main.tmp"), "m\n").unwrap();
    assert!(repo
        .git(&["status", "--porcelain"])
        .lines()
        .all(|l| !l.contains("main.tmp")));
}

#[test]
fn paths_with_spaces_and_non_ascii() {
    let repo = TestRepo::init();
    repo.commit("readme.txt", "r\n", "base");
    repo.write("dir é/a b [1].log", "x\n");
    repo.write("dir é/keep.log", "k\n");
    let (mut rt, key) = open(&repo);
    let list =
        gitbello_core::ignore::suggestions(&[PathBuf::from("dir é/a b [1].log")], Path::new(""));
    let file_rule = shared(&list[0].pattern);
    assert_eq!(file_rule.pattern, "/dir é/a b \\[1].log");
    let seen = preview(&mut rt, &key, file_rule.clone());
    assert_eq!(seen.hidden_sample, vec![PathBuf::from("dir é/a b [1].log")]);
    let job = rt.add_ignore_rule(&key, file_rule, Untrack::Keep);
    succeed(&mut rt, &key, job);
    let shown = listed(&rt, &key);
    assert!(
        !shown.contains(&"dir é/a b [1].log".to_owned()),
        "{shown:?}"
    );
    assert!(shown.contains(&"dir é/keep.log".to_owned()), "{shown:?}");
}
