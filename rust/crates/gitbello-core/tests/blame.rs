//! Blame (PLAN M8b) on real repositories: the blocks git reports, the
//! loader's table, and the runtime's blame of a file history's versions.

mod support;

use std::path::{Path, PathBuf};

use gitbello_core::backend::{CliBackend, GitBackend};
use gitbello_core::blame::{
    BlameLoad, BlameLoader, BlameMinimap, BlameOptions, BlameRequest, BlameSource,
};
use gitbello_core::diff::minimap::{Mark, MinimapSource};
use gitbello_core::git::{CancelToken, GitErrorKind};
use gitbello_core::highlight::LineState;
use gitbello_core::runtime::{FileHistoryRequest, FileSelection, Runtime, RuntimeEvent};
use support::rt::{open, poll_until, settle};
use support::TestRepo;

const OLD: &str = "docs/old name.txt";
const NEW: &str = "docs/nuovo è.txt";

fn backend(repo: &TestRepo) -> CliBackend {
    CliBackend::new(repo.app_runner())
}

fn request(rev: Option<&str>, path: &str, options: BlameOptions) -> BlameRequest {
    BlameRequest {
        rev: rev.map(str::to_owned),
        path: PathBuf::from(path),
        options,
    }
}

fn blame(repo: &TestRepo, rev: Option<&str>, path: &str) -> BlameLoader {
    blame_with(repo, rev, path, BlameOptions::default())
}

fn blame_with(
    repo: &TestRepo,
    rev: Option<&str>,
    path: &str,
    options: BlameOptions,
) -> BlameLoader {
    let loader = BlameLoader::load(&backend(repo), repo.path(), &request(rev, path, options));
    assert_eq!(loader.state(), BlameLoad::Done, "blame of {path}");
    loader
}

/// The subject each line is blamed on.
fn subjects(loader: &BlameLoader) -> Vec<String> {
    let table = loader.table();
    (0..table.line_count())
        .map(|line| {
            table
                .commit_of(line)
                .map(|c| {
                    if c.is_working() {
                        "(uncommitted)".to_owned()
                    } else {
                        c.summary.clone()
                    }
                })
                .unwrap_or_default()
        })
        .collect()
}

/// A file written by three commits and renamed by the last.
fn renamed() -> TestRepo {
    let repo = TestRepo::init();
    repo.commit(OLD, "a\nb\nc\n", "Add file");
    repo.commit("other.txt", "x\n", "Unrelated");
    repo.commit(OLD, "a\nb\nc\nd\n", "Add d");
    repo.git(&["mv", OLD, NEW]);
    repo.commit(NEW, "a\nB\nc\nd\n", "Rename and edit");
    repo
}

#[test]
fn each_line_is_blamed_on_the_commit_that_last_changed_it() {
    let repo = renamed();
    let loader = blame(&repo, Some("HEAD"), NEW);
    assert_eq!(
        subjects(&loader),
        ["Add file", "Rename and edit", "Add file", "Add d"]
    );
    let table = loader.table();
    assert_eq!(table.line_count(), 4);
    assert_eq!(table.blamed_count(), 4);
    assert_eq!(table.line_text(1), b"B");
    // The lines written before the rename carry the old name.
    let first = table.block_of(0).expect("blamed");
    assert_eq!(first.path, PathBuf::from(OLD));
    assert_eq!(first.previous, None);
    // The edited line names the version before it.
    let edited = table.block_of(1).expect("blamed");
    assert_eq!(edited.path, PathBuf::from(NEW));
    let (previous, path) = edited.previous.clone().expect("the line existed before");
    assert_eq!(previous, repo.git(&["rev-parse", "HEAD~1"]).trim());
    assert_eq!(path, PathBuf::from(OLD));
    assert_eq!(table.orig_line(3), Some(4));
    let progress = loader.progress();
    assert_eq!(
        (progress.lines, progress.blamed, progress.commits),
        (4, 4, 3)
    );
    assert!(progress.text.is_some() && progress.first_block.is_some());
}

#[test]
fn an_older_version_is_blamed_under_the_name_it_had() {
    let repo = renamed();
    let loader = blame(&repo, Some("HEAD~1"), OLD);
    assert_eq!(
        subjects(&loader),
        ["Add file", "Add file", "Add file", "Add d"]
    );
}

#[test]
fn the_working_copy_has_uncommitted_lines() {
    let repo = renamed();
    repo.write(NEW, "a\nB\nc\nd\nnew\n");
    let loader = blame(&repo, None, NEW);
    assert_eq!(
        subjects(&loader),
        [
            "Add file",
            "Rename and edit",
            "Add file",
            "Add d",
            "(uncommitted)"
        ]
    );
    let table = loader.table();
    let working = table.commit_of(4).expect("blamed");
    assert!(working.is_working());
    assert_eq!(table.age(working), 1.0);
}

#[test]
fn whitespace_changes_can_be_ignored() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "one\ntwo\n", "Add");
    repo.commit("a.txt", "one\n    two\n", "Indent");
    let plain = blame(&repo, Some("HEAD"), "a.txt");
    assert_eq!(subjects(&plain), ["Add", "Indent"]);
    let ignoring = blame_with(
        &repo,
        Some("HEAD"),
        "a.txt",
        BlameOptions {
            ignore_whitespace: true,
            detect_moves: false,
        },
    );
    assert_eq!(subjects(&ignoring), ["Add", "Add"]);
}

#[test]
fn moved_lines_can_be_followed() {
    let repo = TestRepo::init();
    let block: String = (1..=30)
        .map(|n| format!("moved line number {n}\n"))
        .collect();
    let rest: String = (1..=10).map(|n| format!("fixed line {n}\n")).collect();
    repo.commit("a.txt", &format!("{block}{rest}"), "Add");
    repo.commit("a.txt", &format!("{rest}{block}"), "Move");
    let plain = blame(&repo, Some("HEAD"), "a.txt");
    assert!(subjects(&plain).iter().any(|s| s == "Move"));
    let following = blame_with(
        &repo,
        Some("HEAD"),
        "a.txt",
        BlameOptions {
            ignore_whitespace: false,
            detect_moves: true,
        },
    );
    assert!(subjects(&following).iter().all(|s| s == "Add"));
}

#[test]
fn a_binary_file_a_missing_one_and_an_empty_one_are_states() {
    let repo = TestRepo::init();
    repo.commit("bin.dat", "a\0b\0c", "Add binary");
    repo.commit("empty.txt", "", "Add empty");
    let be = backend(&repo);
    let load = |rev: Option<&str>, path: &str| {
        BlameLoader::load(
            &be,
            repo.path(),
            &request(rev, path, BlameOptions::default()),
        )
        .state()
    };
    assert_eq!(load(Some("HEAD"), "bin.dat"), BlameLoad::Binary);
    assert_eq!(load(None, "nowhere.txt"), BlameLoad::Missing);
    assert_eq!(load(Some("HEAD"), "empty.txt"), BlameLoad::Done);
    assert!(matches!(
        load(Some("HEAD"), "nowhere.txt"),
        BlameLoad::Failed(_)
    ));
    // A revision never reaches git as a flag.
    let refused = be.blame_source(
        repo.path(),
        Some("--help"),
        Path::new("bin.dat"),
        1024,
        &CancelToken::new(),
    );
    assert!(refused.is_err_and(|e| e.kind == GitErrorKind::UnknownRevision));
    let large = be
        .blame_source(
            repo.path(),
            Some("HEAD"),
            Path::new("bin.dat"),
            2,
            &CancelToken::new(),
        )
        .expect("read");
    assert!(matches!(large, BlameSource::TooLarge(_)));
}

#[test]
fn a_cancelled_blame_stops() {
    let repo = renamed();
    let cancel = CancelToken::new();
    cancel.cancel();
    let result = backend(&repo).blame(
        repo.path(),
        Some("HEAD"),
        Path::new(NEW),
        BlameOptions::default(),
        &cancel,
        &mut |_| {},
    );
    assert!(result.is_err_and(|e| e.kind == GitErrorKind::Cancelled));
}

#[test]
fn last_change_finds_the_version_a_commit_holds() {
    let repo = renamed();
    let be = backend(&repo);
    let names = [PathBuf::from(NEW), PathBuf::from(OLD)];
    let find = |rev: &str| {
        be.last_change(repo.path(), rev, &names, &CancelToken::new())
            .expect("log")
    };
    let rev = |rev: &str| repo.git(&["rev-parse", rev]).trim().to_owned();
    assert_eq!(find("HEAD"), Some(rev("HEAD")));
    assert_eq!(find("HEAD~1"), Some(rev("HEAD~1")));
    // "Unrelated" did not change the file: its version is "Add file"'s.
    assert_eq!(find("HEAD~2"), Some(rev("HEAD~3")));
    let none = be
        .last_change(
            repo.path(),
            "HEAD",
            &[PathBuf::from("nowhere")],
            &CancelToken::new(),
        )
        .expect("log");
    assert_eq!(none, None);
}

#[test]
fn the_minimap_marks_the_focused_commit() {
    let repo = renamed();
    let loader = blame(&repo, Some("HEAD"), NEW);
    let table = loader.table();
    let focus = table.commit_of(1).expect("blamed").oid.clone();
    let source = BlameMinimap::new(&table, Some(&focus));
    assert_eq!(source.row_count(), 4);
    let marks: Vec<Mark> = (0..4)
        .map(|row| source.row(row).left.expect("a line").mark)
        .collect();
    assert_eq!(
        marks,
        [Mark::Context, Mark::Resolved, Mark::Context, Mark::Context]
    );
    let plain = BlameMinimap::new(&table, None);
    assert!((0..4).all(|row| plain.row(row).left.is_some_and(|l| l.mark == Mark::Context)));
}

#[test]
fn the_blamed_text_is_coloured_with_its_line_states() {
    let repo = TestRepo::init();
    repo.commit(
        "bin/tool",
        "#!/usr/bin/env python3\n'''opens\nstill a string'''\nx = 1\n",
        "Add tool",
    );
    repo.commit(
        "src/lib.rs",
        "/* a comment\nover two lines */\nfn f() {}\n",
        "Add lib",
    );
    let rust = blame(&repo, Some("HEAD"), "src/lib.rs");
    let table = rust.table();
    assert_eq!(table.syntax().language.map(|l| l.id()), Some("rust"));
    assert_eq!(table.line_state(0), LineState::default());
    assert_ne!(
        table.line_state(1),
        LineState::default(),
        "inside the comment"
    );
    assert_eq!(table.line_state(2), LineState::default());
    let source = BlameMinimap::new(&table, None);
    assert_eq!(source.syntax().language.map(|l| l.id()), Some("rust"));
    assert_eq!(
        source.row(1).left.expect("a line").state,
        table.line_state(1)
    );
    // No extension: the shebang names the language.
    let python = blame(&repo, Some("HEAD"), "bin/tool");
    let table = python.table();
    assert_eq!(table.syntax().language.map(|l| l.id()), Some("python"));
    assert_ne!(
        table.line_state(2),
        LineState::default(),
        "inside the string"
    );
}

// --- Runtime ------------------------------------------------------------------

fn open_history(rt: &mut Runtime, key: &Path, path: &str) {
    rt.open_file_history(
        key,
        FileHistoryRequest {
            path: PathBuf::from(path),
            start: None,
            start_name: String::new(),
        },
    );
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .and_then(|s| s.file_history())
            .is_some_and(|h| !h.is_loading())
    });
}

fn oid_of(rt: &Runtime, key: &Path, subject: &str) -> String {
    let history = rt.repo(key).and_then(|s| s.file_history()).expect("open");
    history
        .rows(0, usize::MAX)
        .into_iter()
        .find(|v| v.subject == subject)
        .unwrap_or_else(|| panic!("no version `{subject}`"))
        .oid
}

fn blame_version(rt: &mut Runtime, key: &Path, selection: FileSelection) {
    rt.blame_file_version(key, &selection, BlameOptions::default());
    wait_blamed(rt, key);
}

fn wait_blamed(rt: &mut Runtime, key: &Path) {
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .and_then(|s| s.blame())
            .is_some_and(|b| b.load() != BlameLoad::Loading)
    });
}

fn blamed(rt: &Runtime, key: &Path) -> Vec<String> {
    let blame = rt.repo(key).and_then(|s| s.blame()).expect("a blame");
    assert_eq!(blame.load(), BlameLoad::Done);
    let table = blame.table();
    (0..table.line_count())
        .map(|line| {
            table
                .commit_of(line)
                .map(|c| {
                    if c.is_working() {
                        "(uncommitted)".to_owned()
                    } else {
                        c.summary.clone()
                    }
                })
                .unwrap_or_default()
        })
        .collect()
}

#[test]
fn the_runtime_blames_a_version_and_focuses_a_commit() {
    let repo = renamed();
    let (mut rt, key) = open(&repo);
    open_history(&mut rt, &key, NEW);
    let head = oid_of(&rt, &key, "Rename and edit");
    blame_version(&mut rt, &key, FileSelection::Version(head.clone()));
    assert_eq!(
        blamed(&rt, &key),
        ["Add file", "Rename and edit", "Add file", "Add d"]
    );
    let request = rt
        .repo(&key)
        .and_then(|s| s.blame())
        .expect("open")
        .request()
        .clone();
    assert_eq!(request.rev.as_deref(), Some(head.as_str()));
    assert_eq!(request.path, PathBuf::from(NEW));

    // Focusing a commit loads its details.
    let added = oid_of(&rt, &key, "Add file");
    rt.focus_blame_commit(&key, Some(&added));
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.blame())
            .is_some_and(|b| b.details().is_some())
    });
    let blame = rt.repo(&key).and_then(|s| s.blame()).expect("open");
    assert_eq!(blame.focus(), Some(added.as_str()));
    assert_eq!(blame.details().map(|d| d.summary()), Some("Add file"));

    // An older version is blamed under its old name; the focus stays.
    let older = oid_of(&rt, &key, "Add d");
    blame_version(&mut rt, &key, FileSelection::Version(older));
    assert_eq!(
        blamed(&rt, &key),
        ["Add file", "Add file", "Add file", "Add d"]
    );
    let blame = rt.repo(&key).and_then(|s| s.blame()).expect("open");
    assert_eq!(blame.request().path, PathBuf::from(OLD));
    assert_eq!(blame.focus(), Some(added.as_str()));

    // Closing the history ends the blame.
    rt.close_file_history(&key);
    assert!(rt.repo(&key).and_then(|s| s.blame()).is_none());
}

#[test]
fn blame_before_finds_the_version_the_line_came_from() {
    let repo = renamed();
    let (mut rt, key) = open(&repo);
    open_history(&mut rt, &key, NEW);
    let head = oid_of(&rt, &key, "Rename and edit");
    blame_version(&mut rt, &key, FileSelection::Version(head));
    // Line 2 was edited by the rename: before it, the file was "Add d"'s.
    let job = rt.blame_before(&key, 1).expect("the line existed before");
    let events = poll_until(&mut rt, |_, events| {
        events
            .iter()
            .any(|e| matches!(e, RuntimeEvent::BlameVersionFound { .. }))
    });
    let found = events.iter().find_map(|e| match e {
        RuntimeEvent::BlameVersionFound { oid, .. } => Some(oid.clone()),
        _ => None,
    });
    assert_eq!(found, Some(Some(oid_of(&rt, &key, "Add d"))));
    assert!(job > 0);
    // A line its commit added with the file has no version before.
    assert!(rt.blame_before(&key, 0).is_none());
}

#[test]
fn the_working_copy_s_blame_follows_the_file() {
    let repo = renamed();
    let (mut rt, key) = open(&repo);
    repo.write(NEW, "a\nB\nc\nd\nnew\n");
    settle(&mut rt, &key);
    open_history(&mut rt, &key, NEW);
    blame_version(&mut rt, &key, FileSelection::Working);
    assert_eq!(
        blamed(&rt, &key),
        [
            "Add file",
            "Rename and edit",
            "Add file",
            "Add d",
            "(uncommitted)"
        ]
    );
    // The file changes: the next status refresh blames it again.
    repo.write(NEW, "a\nB\nc\nd\nnew\nand more\n");
    settle(&mut rt, &key);
    wait_blamed(&mut rt, &key);
    assert_eq!(blamed(&rt, &key).len(), 6);
    // A commit's blame does not run again.
    let head = oid_of(&rt, &key, "Rename and edit");
    blame_version(&mut rt, &key, FileSelection::Version(head));
    repo.write(NEW, "a\n");
    settle(&mut rt, &key);
    let events = rt.poll();
    assert!(!events
        .iter()
        .any(|e| matches!(e, RuntimeEvent::BlameChanged { .. })));
    assert_eq!(blamed(&rt, &key).len(), 4);
}

#[test]
fn a_deleting_commit_has_nothing_to_blame() {
    let repo = TestRepo::init();
    repo.commit("gone.txt", "a\n", "Add");
    repo.git(&["rm", "gone.txt"]);
    repo.git(&["commit", "-m", "Delete"]);
    let (mut rt, key) = open(&repo);
    let add = repo.git(&["rev-parse", "HEAD~1"]).trim().to_owned();
    rt.open_file_history(
        &key,
        FileHistoryRequest {
            path: PathBuf::from("gone.txt"),
            start: Some("HEAD".to_owned()),
            start_name: "main".to_owned(),
        },
    );
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.file_history())
            .is_some_and(|h| !h.is_loading())
    });
    let deleted = oid_of(&rt, &key, "Delete");
    rt.blame_file_version(
        &key,
        &FileSelection::Version(deleted),
        BlameOptions::default(),
    );
    assert!(rt.repo(&key).and_then(|s| s.blame()).is_none());
    // A history read from a fixed commit has no working copy to blame.
    rt.blame_file_version(&key, &FileSelection::Working, BlameOptions::default());
    assert!(rt.repo(&key).and_then(|s| s.blame()).is_none());
    blame_version(&mut rt, &key, FileSelection::Version(add));
    assert_eq!(blamed(&rt, &key), ["Add"]);
}
