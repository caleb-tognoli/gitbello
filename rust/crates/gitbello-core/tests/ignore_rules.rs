//! The ignore rules viewer and "Show ignored files" (M7.7b): every ignore
//! file with what each line decides, removing a rule, untracking, Stop
//! ignoring, the global excludes file and templates, on real temporary
//! repositories.

use crate::support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::changes::ChangeFilter;
use gitbello_core::config::Config;
use gitbello_core::git::GitErrorKind;
use gitbello_core::ignore::{IgnoreRule, IgnoreRules, IgnoreTarget, SourceKind, Untrack};
use gitbello_core::repo::FileState;
use gitbello_core::runtime::{Runtime, RuntimeEvent};
use support::rt::{finish, open, poll_until, succeed};
use support::TestRepo;

/// Loads the rules and waits for them.
fn rules(rt: &mut Runtime, key: &Path) -> IgnoreRules {
    let job = rt.load_ignore_rules(key).expect("the rules load");
    poll_until(rt, |_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::IgnoreRulesLoaded { job: j, .. } if *j == job))
    });
    rt.ignore_rules(key).expect("rules").clone()
}

fn names(rules: &IgnoreRules) -> Vec<(&'static str, String)> {
    rules
        .sources
        .iter()
        .map(|s| (s.kind.id(), s.name.clone()))
        .collect()
}

fn source<'a>(
    rules: &'a IgnoreRules,
    name: &str,
) -> (usize, &'a gitbello_core::ignore::IgnoreSource) {
    rules
        .sources
        .iter()
        .enumerate()
        .find(|(_, s)| s.name == name || s.name.ends_with(name))
        .unwrap_or_else(|| panic!("no source {name}: {:?}", names(rules)))
}

/// Index of the line reading `text` in `source`.
fn line(rules: &IgnoreRules, name: &str, text: &str) -> (usize, usize) {
    let (at, src) = source(rules, name);
    let line = src
        .lines
        .iter()
        .position(|l| l.text == text)
        .unwrap_or_else(|| panic!("no line {text:?} in {name}"));
    (at, line)
}

fn slashed(paths: impl IntoIterator<Item = PathBuf>) -> Vec<String> {
    paths
        .into_iter()
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .collect()
}

/// A repository with rules in the root and a nested `.gitignore`,
/// `info/exclude` and a global file (set in the fixture's scratch global
/// config), a tracked file a rule matches and a negation.
fn project() -> (TestRepo, PathBuf) {
    let repo = TestRepo::init();
    let global = repo.sibling("global ignore é");
    fs::write(&global, "*.bak\n").expect("write the global file");
    repo.git(&[
        "config",
        "--global",
        "core.excludesFile",
        &support::path_arg(&global),
    ]);
    repo.write(
        ".gitignore",
        "*.log\n# build output\n/build/\n!keep.log\nunused/\n",
    );
    repo.write("src/.gitignore", "*.tmp\n");
    repo.write("src/main.rs", "fn main() {}\n");
    repo.write("tracked.log", "t\n");
    repo.git(&["add", ".gitignore", "src"]);
    repo.git(&["add", "-f", "tracked.log"]);
    repo.git(&["commit", "-q", "-m", "base"]);
    let exclude = repo.path().join(".git/info/exclude");
    let mut text = fs::read_to_string(&exclude).unwrap_or_default();
    text.push_str("docs/\n");
    fs::write(&exclude, text).expect("write info/exclude");
    for file in [
        "a.log",
        "keep.log",
        "build/out/o.o",
        "src/t.tmp",
        "docs/d.md",
        "z.bak",
        "mix/1.log",
        "mix/2.bak",
        "new.txt",
    ] {
        repo.write(file, "x\n");
    }
    (repo, global)
}

#[test]
fn lists_every_source_and_what_each_line_decides() {
    let (repo, global) = project();
    let (mut rt, key) = open(&repo);
    let rules = rules(&mut rt, &key);
    let kinds: Vec<&str> = rules.sources.iter().map(|s| s.kind.id()).collect();
    assert_eq!(kinds, ["root", "nested", "local", "global"]);
    assert_eq!(rules.sources[1].name, "src/.gitignore");
    assert_eq!(rules.sources[2].name, "info/exclude");
    assert_eq!(
        PathBuf::from(&rules.sources[3].name),
        global,
        "{:?}",
        names(&rules)
    );

    let root = &rules.sources[0];
    let log = &root.lines[0];
    assert_eq!(
        slashed(log.hidden.iter().map(|h| h.path.clone())),
        ["a.log", "mix/1.log"]
    );
    assert_eq!(slashed(log.tracked.clone()), ["tracked.log"]);
    assert_eq!(root.lines[1].kind.id(), "comment");
    assert_eq!(
        (root.lines[2].hidden_folders(), root.lines[2].hidden_files()),
        (1, 0)
    );
    assert_eq!(root.lines[3].kind.id(), "negation");
    assert_eq!(root.lines[3].reincluded, 1, "keep.log is brought back");
    assert!(root.lines[4].unused());
    assert!(!root.lines[0].unused());
    assert_eq!(rules.sources[1].hidden_count(), 1);
    assert_eq!(rules.sources[2].hidden_count(), 1, "docs/ in info/exclude");
    assert_eq!(rules.sources[3].hidden_count(), 2, "z.bak and mix/2.bak");
    // `mix/` is listed by `--directory` but no line ignores it as a folder.
    assert!(rules
        .ignored
        .iter()
        .all(|(e, _)| e.path != Path::new("mix")));
    assert!(rules.ignored.iter().all(|(_, at)| at.is_some()));
}

#[test]
fn show_ignored_files_lists_them_last_with_their_rule() {
    let (repo, _) = project();
    let (mut rt, key) = open(&repo);
    rt.set_change_filter(
        &key,
        ChangeFilter {
            ignored: true,
            ..ChangeFilter::default()
        },
    );
    poll_until(&mut rt, |rt, _| rt.ignore_rules(&key).is_some());
    let state = rt.repo(&key).unwrap();
    let status = state.changes_status().unwrap();
    let rows: Vec<(String, bool)> = state
        .changes()
        .indices()
        .iter()
        .map(|&i| {
            let c = &status.changes[i];
            (
                c.path.to_string_lossy().replace('\\', "/"),
                c.state == FileState::Ignored,
            )
        })
        .collect();
    let first_ignored = rows.iter().position(|r| r.1).expect("ignored rows");
    assert!(
        rows[first_ignored..].iter().all(|r| r.1),
        "ignored rows come last: {rows:?}"
    );
    assert!(rows.contains(&("new.txt".into(), false)));
    assert!(rows.contains(&("build".into(), true)));
    assert_eq!(
        state.changes().total(),
        rows.len() - rows[first_ignored..].len()
    );
    let (src, line) = state.ignored_by(Path::new("src/t.tmp")).unwrap();
    assert_eq!(
        (src.name.as_str(), line.number, line.text.as_str()),
        ("src/.gitignore", 1, "*.tmp")
    );

    // A new file is picked up with the next status.
    repo.write("later.log", "l\n");
    rt.refresh(
        &key,
        gitbello_core::jobs::RefreshSet::EMPTY.with(gitbello_core::jobs::RefreshKind::Status),
    );
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.ignored_by(Path::new("later.log")))
            .is_some()
    });

    // A path that is a change is listed once, as the change: here a file
    // just untracked, which is also ignored on disk.
    repo.git(&["rm", "-q", "--cached", "--", "tracked.log"]);
    rt.refresh(
        &key,
        gitbello_core::jobs::RefreshSet::EMPTY.with(gitbello_core::jobs::RefreshKind::Status),
    );
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.ignored_by(Path::new("tracked.log")))
            .is_some()
    });
    let status = rt.repo(&key).unwrap().changes_status().unwrap();
    let rows: Vec<FileState> = status
        .changes
        .iter()
        .filter(|c| c.path == Path::new("tracked.log"))
        .map(|c| c.state)
        .collect();
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_ne!(rows[0], FileState::Ignored);

    rt.set_change_filter(&key, ChangeFilter::default());
    let state = rt.repo(&key).unwrap();
    assert!(state.ignore_rules().is_none(), "the rules are let go");
    let status = state.changes_status().unwrap();
    assert!(status.changes.iter().all(|c| c.state != FileState::Ignored));
}

#[test]
fn removes_a_rule_and_undo_puts_it_back() {
    let (repo, _) = project();
    let (mut rt, key) = open(&repo);
    let rules = rules(&mut rt, &key);
    let before = fs::read(repo.path().join(".gitignore")).unwrap();
    let (src, at) = line(&rules, ".gitignore", "/build/");
    let job = rt.remove_ignore_rule(&key, src, at);
    succeed(&mut rt, &key, job);
    assert_eq!(
        fs::read_to_string(repo.path().join(".gitignore")).unwrap(),
        "*.log\n# build output\n!keep.log\nunused/\n"
    );
    assert!(rt
        .repo(&key)
        .unwrap()
        .status()
        .unwrap()
        .changes
        .iter()
        .any(|c| c.path == Path::new("build/out/o.o")));
    assert!(rt.can_undo_ignore(&key));
    let job = rt.undo_ignore(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(fs::read(repo.path().join(".gitignore")).unwrap(), before);

    // A comment is not a rule; a file edited since the load is refused.
    let rules = self::rules(&mut rt, &key);
    let (src, comment) = line(&rules, ".gitignore", "# build output");
    assert!(rt.remove_ignore_rule(&key, src, comment).is_none());
    let (src, at) = line(&rules, ".gitignore", "unused/");
    repo.write(".gitignore", "*.log\n");
    let job = rt.remove_ignore_rule(&key, src, at);
    let err = finish(&mut rt, &key, job).expect("refused");
    assert_eq!(err.kind, GitErrorKind::Stale);
    assert_eq!(
        fs::read_to_string(repo.path().join(".gitignore")).unwrap(),
        "*.log\n"
    );
}

#[test]
fn removing_from_a_crlf_file_keeps_its_endings() {
    let repo = TestRepo::init();
    repo.commit("readme.txt", "r\n", "base");
    repo.write(".gitignore", "\u{feff}*.log\r\n*.tmp\r\n");
    repo.write("a.tmp", "t\n");
    let (mut rt, key) = open(&repo);
    let rules = rules(&mut rt, &key);
    let (src, at) = line(&rules, ".gitignore", "*.log");
    assert!(rules.sources[src].lines[at].unused());
    let job = rt.remove_ignore_rule(&key, src, at);
    succeed(&mut rt, &key, job);
    assert_eq!(
        fs::read(repo.path().join(".gitignore")).unwrap(),
        "\u{feff}*.tmp\r\n".as_bytes()
    );
}

#[test]
fn stop_tracking_the_files_a_rule_matches() {
    let (repo, _) = project();
    let (mut rt, key) = open(&repo);
    let rules = rules(&mut rt, &key);
    let (src, at) = line(&rules, ".gitignore", "*.log");
    let job = rt.untrack_ignored(&key, src, at);
    succeed(&mut rt, &key, job);
    assert!(repo
        .git(&["ls-files", "--", "tracked.log"])
        .trim()
        .is_empty());
    assert!(repo.path().join("tracked.log").exists());
    let state = rt.repo(&key).unwrap();
    assert_ne!(
        state.pick_state(Path::new("tracked.log")),
        gitbello_core::changes::PickState::None,
        "the removal is included in the commit"
    );
    let job = rt.undo_ignore(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(
        repo.git(&["ls-files", "--", "tracked.log"]).trim(),
        "tracked.log"
    );
}

#[test]
fn stop_ignoring_removes_an_exact_rule_or_negates() {
    let (repo, _) = project();
    let (mut rt, key) = open(&repo);
    rules(&mut rt, &key);
    // `/build/` names exactly that folder: the line goes.
    let job = rt.stop_ignoring(&key, Path::new("build"));
    succeed(&mut rt, &key, job);
    let text = fs::read_to_string(repo.path().join(".gitignore")).unwrap();
    assert!(!text.contains("/build/"), "{text}");
    // `*.log` covers more than a.log: a negation is added after it.
    rules(&mut rt, &key);
    let job = rt.stop_ignoring(&key, Path::new("a.log"));
    succeed(&mut rt, &key, job);
    let text = fs::read_to_string(repo.path().join(".gitignore")).unwrap();
    assert!(text.ends_with("!/a.log\n"), "{text}");
    let listed = |rt: &Runtime, path: &str| {
        rt.repo(&key)
            .unwrap()
            .status()
            .unwrap()
            .changes
            .iter()
            .any(|c| c.path == Path::new(path) && c.state == FileState::Untracked)
    };
    assert!(listed(&rt, "a.log"));
    // In a nested file, the negation is relative to it.
    rules(&mut rt, &key);
    let job = rt.stop_ignoring(&key, Path::new("src/t.tmp"));
    succeed(&mut rt, &key, job);
    assert_eq!(
        fs::read_to_string(repo.path().join("src/.gitignore")).unwrap(),
        "*.tmp\n!/t.tmp\n"
    );
    // A global rule is negated in info/exclude, not in the global file.
    rules(&mut rt, &key);
    let job = rt.stop_ignoring(&key, Path::new("z.bak"));
    succeed(&mut rt, &key, job);
    let exclude = fs::read_to_string(repo.path().join(".git/info/exclude")).unwrap();
    assert!(exclude.ends_with("docs/\n!/z.bak\n"), "{exclude}");
    assert!(listed(&rt, "z.bak"));
    // Each step is undone in turn.
    let job = rt.undo_ignore(&key);
    succeed(&mut rt, &key, job);
    assert!(!listed(&rt, "z.bak"));
}

#[test]
fn rules_go_to_the_global_file_and_every_repository_sees_them() {
    let (repo, global) = project();
    let other = TestRepo::init();
    other.commit("readme.txt", "r\n", "base");
    other.write("notes.swp", "s\n");
    let mut config = Config::default();
    config.auto_fetch_minutes = 0;
    let mut rt = Runtime::with_runner(config, None, repo.app_runner());
    let key = rt.open(repo.path());
    let other_key = rt.open(other.path());
    poll_until(&mut rt, |rt, _| {
        [&key, &other_key]
            .iter()
            .all(|k| rt.repo(k).is_some_and(|s| s.status().is_some()))
    });
    let swp = |rt: &Runtime| {
        rt.repo(&other_key)
            .and_then(|s| s.status())
            .is_some_and(|s| s.changes.iter().any(|c| c.path == Path::new("notes.swp")))
    };
    assert!(swp(&rt), "{:?}", rt.repo(&other_key).unwrap().status());
    let rule = IgnoreRule {
        pattern: "*.swp".into(),
        target: IgnoreTarget::Global,
    };
    let job = rt.add_ignore_rule(&key, rule, Untrack::Keep);
    succeed(&mut rt, &key, job);
    assert_eq!(fs::read_to_string(&global).unwrap(), "*.bak\n*.swp\n");
    poll_until(&mut rt, |rt, _| !swp(rt));
    let job = rt.undo_ignore(&key);
    succeed(&mut rt, &key, job);
    assert_eq!(fs::read_to_string(&global).unwrap(), "*.bak\n");
    poll_until(&mut rt, |rt, _| swp(rt));
}

#[test]
fn the_global_file_is_created_where_git_reads_it() {
    let repo = TestRepo::init();
    repo.commit("readme.txt", "r\n", "base");
    let global = repo.sibling("config").join("git").join("ignore");
    repo.git(&[
        "config",
        "--global",
        "core.excludesFile",
        &support::path_arg(&global),
    ]);
    repo.write("x.swp", "s\n");
    let (mut rt, key) = open(&repo);
    let rules = rules(&mut rt, &key);
    let src = rules
        .sources
        .iter()
        .find(|s| s.kind == SourceKind::Global)
        .expect("global");
    assert_eq!(PathBuf::from(&src.name), global);
    assert!(!src.exists);
    let rule = IgnoreRule {
        pattern: "*.swp".into(),
        target: IgnoreTarget::Global,
    };
    let job = rt.add_ignore_rule(&key, rule, Untrack::Keep);
    succeed(&mut rt, &key, job);
    assert_eq!(fs::read_to_string(&global).unwrap(), "*.swp\n");
    assert!(rt
        .repo(&key)
        .unwrap()
        .status()
        .unwrap()
        .changes
        .iter()
        .all(|c| c.path != Path::new("x.swp")));
}

#[test]
fn template_lines_the_root_file_lacks() {
    let repo = TestRepo::init();
    repo.write(".gitignore", ".godot/\n");
    repo.commit("project.godot", "p\n", "base");
    let (mut rt, key) = open(&repo);
    assert_eq!(
        rt.ignore_template_lines(&key, "Godot"),
        None,
        "before the rules load"
    );
    rules(&mut rt, &key);
    let missing = rt.ignore_template_lines(&key, "Godot").unwrap();
    assert!(!missing.is_empty());
    assert!(
        missing
            .lines()
            .all(|l| l != ".godot/" && !l.starts_with('#')),
        "{missing}"
    );
    assert_eq!(rt.ignore_template_lines(&key, "Cobol"), None);
}

#[test]
fn hints_at_a_folder_of_build_output() {
    let repo = TestRepo::init();
    repo.commit("readme.txt", "r\n", "base");
    repo.write("node_modules/left-pad/index.js", "x\n");
    repo.write("node_modules/left-pad/package.json", "{}\n");
    let (rt, key) = open(&repo);
    assert_eq!(
        rt.ignore_hint(&key),
        Some((PathBuf::from("node_modules"), 2))
    );
}

#[test]
fn a_linked_worktree_attributes_info_exclude() {
    let (repo, _) = project();
    let linked = repo.add_worktree("topic", "linked é");
    fs::create_dir_all(linked.join("docs")).unwrap();
    fs::write(linked.join("docs/x.md"), "x\n").unwrap();
    let mut config = Config::default();
    config.auto_fetch_minutes = 0;
    let mut rt = Runtime::with_runner(config, None, repo.app_runner());
    let key = rt.open(&linked);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).is_some_and(|s| s.status().is_some())
    });
    let rules = rules(&mut rt, &key);
    let (src, at) = line(&rules, "info/exclude", "docs/");
    assert_eq!(rules.sources[src].lines[at].hidden_folders(), 1);
}
