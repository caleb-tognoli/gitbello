//! File history (PLAN M8a) on real repositories: the path log, the names a
//! file had, its versions and their diffs, and restoring a version.

mod support;

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::backend::{CliBackend, GitBackend};
use gitbello_core::diff::{DiffContent, LineKind};
use gitbello_core::file_history::{FileHistoryLoader, FileVersion, HistoryLoad};
use gitbello_core::git::{CancelToken, GitErrorKind};
use gitbello_core::path_log::PathCommit;
use gitbello_core::repo::Change;
use gitbello_core::runtime::{
    DiffSlot, FileHistoryRequest, FileHistoryState, FileSelection, Runtime, RuntimeEvent,
};
use support::rt::{ok, open, poll_until, settle};
use support::TestRepo;

const OLD: &str = "docs/old name.txt";
const NEW: &str = "docs/nuovo è.txt";

fn backend(repo: &TestRepo) -> CliBackend {
    CliBackend::new(repo.app_runner())
}

fn history(repo: &TestRepo, start: &str, path: &str) -> FileHistoryLoader {
    let loader = FileHistoryLoader::load(&backend(repo), repo.path(), start, Path::new(path));
    assert_eq!(loader.state(), HistoryLoad::Done, "history of {path}");
    loader
}

fn subjects(loader: &FileHistoryLoader) -> Vec<String> {
    loader.rows().iter().map(|v| v.subject.clone()).collect()
}

fn slashed(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn version(loader: &FileHistoryLoader, subject: &str) -> FileVersion {
    loader
        .rows()
        .iter()
        .find(|v| v.subject == subject)
        .cloned()
        .unwrap_or_else(|| panic!("no version `{subject}`"))
}

/// `main` renames the file and edits it; `side`, split off before the
/// rename, edits it under its old name and is merged afterwards.
fn renamed_with_side_edit() -> TestRepo {
    let repo = TestRepo::init();
    repo.commit(OLD, "a\nb\nc\n", "Add file");
    repo.commit("other.txt", "x\n", "Unrelated");
    repo.commit(OLD, "a\nb\nc\nd\n", "Edit");
    repo.branch("side");
    repo.git(&["mv", OLD, NEW]);
    repo.commit(NEW, "a\nB\nc\nd\n", "Rename and edit");
    repo.checkout("side");
    repo.commit(OLD, "a\nb\nc\nd\nside\n", "Side edit");
    repo.checkout("main");
    repo.merge("side", "Merge side");
    repo.commit(NEW, "a\nB\nc\nd\nside\nlast\n", "Last");
    repo
}

#[test]
fn path_log_lists_the_commits_of_the_given_paths() {
    let repo = renamed_with_side_edit();
    let mut commits: Vec<PathCommit> = Vec::new();
    backend(&repo)
        .path_log(
            repo.path(),
            "HEAD",
            &[PathBuf::from("other.txt")],
            &CancelToken::new(),
            &mut |commit| commits.push(commit),
        )
        .expect("path log");
    assert_eq!(commits.len(), 1);
    assert_eq!(commits[0].subject, "Unrelated");
    assert_eq!(commits[0].author, "Ada Lövelace");
    assert_eq!(commits[0].files.len(), 1);
    assert_eq!(commits[0].files[0].change, Change::Added);
    assert_eq!(commits[0].files[0].stats, Some((1, 0)));
}

#[test]
fn path_log_takes_a_folder_and_several_paths() {
    let repo = renamed_with_side_edit();
    let mut subjects: Vec<String> = Vec::new();
    backend(&repo)
        .path_log(
            repo.path(),
            "HEAD",
            &[PathBuf::from("docs"), PathBuf::from("other.txt")],
            &CancelToken::new(),
            &mut |commit| subjects.push(commit.subject),
        )
        .expect("path log");
    assert_eq!(
        subjects,
        [
            "Last",
            "Merge side",
            "Side edit",
            "Rename and edit",
            "Edit",
            "Unrelated",
            "Add file"
        ]
    );
}

#[test]
fn path_log_refuses_options_and_unknown_revisions() {
    let repo = renamed_with_side_edit();
    let backend = backend(&repo);
    let paths = [PathBuf::from(NEW)];
    let cancel = CancelToken::new();
    let err = backend
        .path_log(repo.path(), "--all", &paths, &cancel, &mut |_| {})
        .expect_err("an option is not a revision");
    assert_eq!(err.kind, GitErrorKind::UnknownRevision);
    // A revision git does not know lists nothing, like an unborn branch.
    let mut count = 0;
    backend
        .path_log(repo.path(), "no-such-branch", &paths, &cancel, &mut |_| {
            count += 1
        })
        .expect("unknown revision");
    assert_eq!(count, 0);
}

#[test]
fn a_rename_keeps_the_commits_made_under_the_old_name() {
    let repo = renamed_with_side_edit();
    let loader = history(&repo, "HEAD", NEW);
    assert_eq!(
        subjects(&loader),
        [
            "Last",
            "Merge side",
            "Side edit",
            "Rename and edit",
            "Edit",
            "Add file"
        ]
    );
    assert_eq!(loader.names(), [PathBuf::from(NEW), PathBuf::from(OLD)]);
    assert_eq!(loader.progress().passes, 2);

    let rename = version(&loader, "Rename and edit");
    assert_eq!(rename.change, Change::Renamed);
    assert_eq!(slashed(&rename.path), NEW);
    assert_eq!(
        rename.original_path.as_deref().map(slashed).as_deref(),
        Some(OLD)
    );
    assert_eq!(rename.stats, Some((1, 1)));

    let side = version(&loader, "Side edit");
    assert_eq!(side.change, Change::Modified);
    assert_eq!(slashed(&side.path), OLD);
    assert_eq!(side.stats, Some((1, 0)));

    let added = version(&loader, "Add file");
    assert_eq!(added.change, Change::Added);
    assert_eq!(slashed(&added.path), OLD);
    assert_eq!(added.stats, Some((3, 0)));
    assert!(added.parents.is_empty());
}

#[test]
fn a_merge_row_is_diffed_against_its_first_parent() {
    let repo = renamed_with_side_edit();
    let loader = history(&repo, "HEAD", NEW);
    let merge = version(&loader, "Merge side");
    assert_eq!(merge.parents.len(), 2);
    assert_eq!(merge.change, Change::Modified);
    assert_eq!(slashed(&merge.path), NEW);
    // The side's line arrives on main with the merge.
    assert_eq!(merge.stats, Some((1, 0)));
    let diff = backend(&repo)
        .diff(repo.path(), &merge.target(), None, &CancelToken::new())
        .expect("merge diff");
    assert_eq!(diff.content, DiffContent::Text);
    let added: Vec<&[u8]> = diff
        .lines(0, 99)
        .filter(|l| l.kind == LineKind::Added)
        .map(|l| l.text)
        .collect();
    assert_eq!(added, [&b"side"[..]]);
}

#[test]
fn a_version_diff_follows_the_rename() {
    let repo = renamed_with_side_edit();
    let loader = history(&repo, "HEAD", NEW);
    let rename = version(&loader, "Rename and edit");
    let diff = backend(&repo)
        .diff(repo.path(), &rename.target(), None, &CancelToken::new())
        .expect("rename diff");
    assert_eq!(diff.content, DiffContent::Text);
    let changed: Vec<(LineKind, &[u8])> = diff
        .lines(0, 99)
        .filter(|l| matches!(l.kind, LineKind::Added | LineKind::Removed))
        .map(|l| (l.kind, l.text))
        .collect();
    assert_eq!(
        changed,
        [(LineKind::Removed, &b"b"[..]), (LineKind::Added, &b"B"[..])]
    );
}

#[test]
fn two_renames_in_a_row_are_followed() {
    let repo = TestRepo::init();
    repo.commit("one.txt", "1\n2\n3\n4\n5\n", "Add one");
    repo.git(&["mv", "one.txt", "two.txt"]);
    repo.commit("two.txt", "1\n2\n3\n4\n5\n6\n", "One becomes two");
    repo.commit("two.txt", "1\n2\n3\n4\n5\n6\n7\n", "Edit two");
    repo.git(&["mv", "two.txt", "thrée.txt"]);
    repo.commit("thrée.txt", "1\n2\n3\n4\n5\n6\n7\n8\n", "Two becomes three");
    let loader = history(&repo, "HEAD", "thrée.txt");
    assert_eq!(
        subjects(&loader),
        [
            "Two becomes three",
            "Edit two",
            "One becomes two",
            "Add one"
        ]
    );
    assert_eq!(
        loader.names(),
        [
            PathBuf::from("thrée.txt"),
            PathBuf::from("two.txt"),
            PathBuf::from("one.txt")
        ]
    );
    assert_eq!(loader.progress().passes, 3);
    assert_eq!(slashed(&version(&loader, "Edit two").path), "two.txt");
}

#[test]
fn a_file_deleted_since_has_its_history_from_an_older_start() {
    let repo = TestRepo::init();
    repo.commit("gone.txt", "a\n", "Add gone");
    let kept = repo.commit("gone.txt", "a\nb\n", "Edit gone");
    repo.git(&["rm", "--quiet", "gone.txt"]);
    repo.commit("other.txt", "x\n", "Delete gone");

    let from_head = history(&repo, "HEAD", "gone.txt");
    assert_eq!(
        subjects(&from_head),
        ["Delete gone", "Edit gone", "Add gone"]
    );
    let deleted = version(&from_head, "Delete gone");
    assert_eq!(deleted.change, Change::Deleted);
    assert!(!deleted.exists());
    assert_eq!(deleted.stats, Some((0, 2)));

    let from_older = history(&repo, &kept, "gone.txt");
    assert_eq!(subjects(&from_older), ["Edit gone", "Add gone"]);
}

#[test]
fn an_unknown_file_and_an_unborn_branch_have_no_history() {
    let repo = TestRepo::init();
    let unborn = history(&repo, "HEAD", "a.txt");
    assert_eq!(unborn.row_count(), 0);
    repo.commit("a.txt", "a\n", "Add a");
    let unknown = history(&repo, "HEAD", "no such file.txt");
    assert_eq!(unknown.row_count(), 0);
    assert_eq!(unknown.names(), [PathBuf::from("no such file.txt")]);
}

#[test]
fn git_s_own_follow_setting_changes_nothing() {
    let repo = renamed_with_side_edit();
    repo.git(&["config", "log.follow", "true"]);
    let loader = history(&repo, "HEAD", NEW);
    assert_eq!(loader.row_count(), 6);
}

#[test]
fn a_binary_file_has_no_line_counts() {
    let repo = TestRepo::init();
    fs::write(repo.path().join("pic.bin"), [0u8, 159, 146, 150, 0, 1]).expect("write");
    repo.git(&["add", "pic.bin"]);
    repo.commit("note.txt", "n\n", "Add a picture");
    let loader = history(&repo, "HEAD", "pic.bin");
    assert_eq!(subjects(&loader), ["Add a picture"]);
    assert_eq!(loader.rows()[0].stats, None);
}

#[test]
fn a_cancelled_load_stops() {
    let repo = renamed_with_side_edit();
    let cancel = CancelToken::new();
    cancel.cancel();
    let err = backend(&repo)
        .path_log(
            repo.path(),
            "HEAD",
            &[PathBuf::from(NEW)],
            &cancel,
            &mut |_| {},
        )
        .expect_err("cancelled");
    assert_eq!(err.kind, GitErrorKind::Cancelled);
}

#[test]
fn restoring_a_version_of_a_renamed_file_writes_the_current_name() {
    let repo = renamed_with_side_edit();
    let loader = history(&repo, "HEAD", NEW);
    let edit = version(&loader, "Edit");
    assert_eq!(slashed(&edit.path), OLD);
    let backend = backend(&repo);
    let cancel = CancelToken::new();
    let backups = backend
        .restore_file_as(repo.path(), &edit.oid, &edit.path, Path::new(NEW), &cancel)
        .expect("restore");
    assert_eq!(
        fs::read_to_string(repo.path().join(NEW)).expect("read"),
        "a\nb\nc\nd\n"
    );
    assert!(!repo.path().join(OLD).exists(), "the old name stays gone");
    assert_eq!(backups.len(), 1);
    assert_eq!(slashed(&backups[0].0), NEW);
    assert!(!backups[0].1.is_empty());
    // Not staged: the index still has HEAD's file.
    assert_eq!(repo.git(&["diff", "--cached", "--name-only"]), "");

    backend
        .restore_backup(repo.path(), &backups, &cancel)
        .expect("undo");
    assert_eq!(
        fs::read_to_string(repo.path().join(NEW)).expect("read"),
        "a\nB\nc\nd\nside\nlast\n"
    );
}

#[test]
fn restoring_under_the_same_name_restores_in_place() {
    let repo = renamed_with_side_edit();
    let loader = history(&repo, "HEAD", NEW);
    let rename = version(&loader, "Rename and edit");
    let backups = backend(&repo)
        .restore_file_as(
            repo.path(),
            &rename.oid,
            &rename.path,
            Path::new(NEW),
            &CancelToken::new(),
        )
        .expect("restore");
    assert_eq!(
        fs::read_to_string(repo.path().join(NEW)).expect("read"),
        "a\nB\nc\nd\n"
    );
    assert_eq!(backups.len(), 1);
}

fn request(path: &str, start: Option<&str>) -> FileHistoryRequest {
    FileHistoryRequest {
        path: PathBuf::from(path),
        start: start.map(str::to_owned),
        start_name: start.map(|_| "a commit".to_owned()).unwrap_or_default(),
    }
}

/// Opens the history and waits until it is loaded.
fn open_history(rt: &mut Runtime, key: &Path, request: FileHistoryRequest) {
    rt.open_file_history(key, request);
    wait_loaded(rt, key);
}

fn wait_loaded(rt: &mut Runtime, key: &Path) {
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .and_then(|s| s.file_history())
            .is_some_and(|h| !h.is_loading())
    });
}

fn shown<'a>(rt: &'a Runtime, key: &Path) -> &'a FileHistoryState {
    rt.repo(key)
        .and_then(|s| s.file_history())
        .expect("an open file history")
}

fn listed(rt: &Runtime, key: &Path) -> Vec<String> {
    let history = shown(rt, key);
    history
        .rows(0, usize::MAX)
        .into_iter()
        .map(|v| v.subject)
        .collect()
}

fn oid_of(rt: &Runtime, key: &Path, subject: &str) -> String {
    let history = shown(rt, key);
    history
        .rows(0, usize::MAX)
        .into_iter()
        .find(|v| v.subject == subject)
        .unwrap_or_else(|| panic!("no version `{subject}`"))
        .oid
}

/// Selects and waits for the file diff to load.
fn select(rt: &mut Runtime, key: &Path, selection: FileSelection) {
    rt.select_file_version(key, Some(selection), false);
    poll_until(rt, |rt, ev| {
        ev.iter().any(|e| {
            matches!(
                e,
                RuntimeEvent::DiffChanged {
                    slot: DiffSlot::File,
                    ..
                }
            )
        }) && rt
            .repo(key)
            .and_then(|s| s.file_diff())
            .is_some_and(|d| d.diff().is_some() && !d.is_loading())
    });
}

fn changed_lines(rt: &Runtime, key: &Path) -> Vec<(LineKind, String)> {
    let diff = rt
        .repo(key)
        .and_then(|s| s.file_diff())
        .and_then(|d| d.diff())
        .expect("a loaded file diff");
    diff.lines(0, 999)
        .filter(|l| matches!(l.kind, LineKind::Added | LineKind::Removed))
        .map(|l| (l.kind, String::from_utf8_lossy(l.text).into_owned()))
        .collect()
}

#[test]
fn the_runtime_lists_a_history_and_shows_a_version() {
    let repo = renamed_with_side_edit();
    let (mut rt, key) = open(&repo);
    rt.open_file_history(&key, request(NEW, None));
    let events = poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.file_history())
            .is_some_and(|h| !h.is_loading())
    });
    assert!(events
        .iter()
        .any(|e| matches!(e, RuntimeEvent::FileHistoryChanged { .. })));
    assert!(
        !events
            .iter()
            .any(|e| matches!(e, RuntimeEvent::Job { label, .. } if label == "file history")),
        "the load reports through FileHistoryChanged only"
    );
    assert_eq!(listed(&rt, &key).len(), 6);
    let state = rt.repo(&key).unwrap();
    let history = state.file_history().unwrap();
    assert_eq!(history.names(), [PathBuf::from(NEW), PathBuf::from(OLD)]);
    assert!(history.error().is_none());
    assert!(!state.file_history_has_working());
    assert_eq!(history.rows(1, 2).len(), 2);
    assert_eq!(history.rows(5, 10).len(), 1);
    assert!(history.rows(9, 3).is_empty());

    let rename = oid_of(&rt, &key, "Rename and edit");
    assert_eq!(history.index_of(&rename), Some(3));
    select(&mut rt, &key, FileSelection::Version(rename.clone()));
    assert_eq!(
        changed_lines(&rt, &key),
        [
            (LineKind::Removed, "b".to_owned()),
            (LineKind::Added, "B".to_owned())
        ]
    );
    let state = rt.repo(&key).unwrap();
    assert_eq!(
        state.file_history().unwrap().selected(),
        Some(&FileSelection::Version(rename))
    );
    // The other diffs are untouched.
    assert!(state.diff().is_none());
    assert!(state.commit_diff().is_none());
    assert!(state.compare_diff().is_none());

    rt.select_file_version(&key, None, false);
    assert!(rt.repo(&key).unwrap().file_diff().is_none());
    rt.close_file_history(&key);
    assert!(rt.repo(&key).unwrap().file_history().is_none());
}

#[test]
fn a_history_from_a_fixed_commit_names_the_file_as_it_was() {
    let repo = renamed_with_side_edit();
    let before_rename = repo.git(&["rev-parse", "main~2^1"]);
    let (mut rt, key) = open(&repo);
    open_history(&mut rt, &key, request(OLD, Some(&before_rename)));
    assert_eq!(listed(&rt, &key), ["Edit", "Add file"]);
    // A commit moves HEAD: a fixed start does not reload.
    repo.commit("other.txt", "y\n", "Elsewhere");
    settle(&mut rt, &key);
    assert_eq!(listed(&rt, &key), ["Edit", "Add file"]);
    assert!(!rt.repo(&key).unwrap().file_history_has_working());
}

#[test]
fn the_uncommitted_changes_row_follows_the_status() {
    let repo = renamed_with_side_edit();
    let (mut rt, key) = open(&repo);
    open_history(&mut rt, &key, request(NEW, None));
    assert!(!rt.repo(&key).unwrap().file_history_has_working());

    repo.write(NEW, "a\nB\nc\nd\nside\nlast\nlocal\n");
    settle(&mut rt, &key);
    assert!(rt.repo(&key).unwrap().file_history_has_working());
    select(&mut rt, &key, FileSelection::Working);
    assert_eq!(
        changed_lines(&rt, &key),
        [(LineKind::Added, "local".to_owned())]
    );

    // Edited again: the shown diff is read again.
    repo.write(NEW, "a\nB\nc\nd\nside\nlast\nlocal\nmore\n");
    settle(&mut rt, &key);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.file_diff())
            .is_some_and(|d| !d.is_loading())
    });
    assert_eq!(changed_lines(&rt, &key).len(), 2);

    // Reverted: the row and its diff go.
    repo.git(&["checkout", "--", NEW]);
    settle(&mut rt, &key);
    let state = rt.repo(&key).unwrap();
    assert!(!state.file_history_has_working());
    assert!(state.file_diff().is_none());
    assert!(state.file_history().unwrap().selected().is_none());
}

#[test]
fn a_history_from_head_reloads_when_head_moves_and_keeps_the_selection() {
    let repo = renamed_with_side_edit();
    let (mut rt, key) = open(&repo);
    open_history(&mut rt, &key, request(NEW, None));
    let edit = oid_of(&rt, &key, "Edit");
    select(&mut rt, &key, FileSelection::Version(edit.clone()));

    repo.commit(NEW, "a\nB\nc\nd\nside\nlast\nnewer\n", "Newer");
    settle(&mut rt, &key);
    poll_until(&mut rt, |rt, _| listed(rt, &key).len() == 7);
    wait_loaded(&mut rt, &key);
    assert_eq!(listed(&rt, &key)[0], "Newer");
    let state = rt.repo(&key).unwrap();
    assert_eq!(
        state.file_history().unwrap().selected(),
        Some(&FileSelection::Version(edit))
    );
    assert!(state.file_diff().is_some());

    // The selected commit leaves the history: its diff goes.
    let newer = oid_of(&rt, &key, "Newer");
    select(&mut rt, &key, FileSelection::Version(newer));
    repo.git(&["reset", "--quiet", "--hard", "HEAD~1"]);
    settle(&mut rt, &key);
    poll_until(&mut rt, |rt, _| listed(rt, &key).len() == 6);
    wait_loaded(&mut rt, &key);
    let state = rt.repo(&key).unwrap();
    assert!(state.file_history().unwrap().selected().is_none());
    assert!(state.file_diff().is_none());
}

#[test]
fn an_uncommitted_rename_reads_the_history_of_the_old_name() {
    let repo = TestRepo::init();
    repo.commit("before.txt", "1\n2\n3\n", "Add before");
    repo.commit("before.txt", "1\n2\n3\n4\n", "Edit before");
    repo.git(&["mv", "before.txt", "áfter.txt"]);
    let (mut rt, key) = open(&repo);
    open_history(&mut rt, &key, request("áfter.txt", None));
    assert_eq!(listed(&rt, &key), ["Edit before", "Add before"]);
    assert!(rt.repo(&key).unwrap().file_history_has_working());
}

#[test]
fn an_untracked_file_has_only_its_uncommitted_changes() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "Add a");
    repo.write("new file.txt", "one\ntwo\n");
    let (mut rt, key) = open(&repo);
    open_history(&mut rt, &key, request("new file.txt", None));
    assert!(listed(&rt, &key).is_empty());
    assert!(rt.repo(&key).unwrap().file_history_has_working());
    select(&mut rt, &key, FileSelection::Working);
    assert_eq!(changed_lines(&rt, &key).len(), 2);
}

#[test]
fn the_runtime_restores_a_version_and_undoes_it() {
    let repo = renamed_with_side_edit();
    let (mut rt, key) = open(&repo);
    open_history(&mut rt, &key, request(NEW, None));
    let edit = oid_of(&rt, &key, "Edit");
    ok(&mut rt, &key, |rt| rt.restore_file_version(&key, &edit));
    assert_eq!(
        fs::read_to_string(repo.path().join(NEW)).expect("read"),
        "a\nb\nc\nd\n"
    );
    let state = rt.repo(&key).unwrap();
    assert!(state.file_history_has_working());
    assert!(state.can_undo_discard());
    ok(&mut rt, &key, |rt| rt.undo_discard(&key));
    assert_eq!(
        fs::read_to_string(repo.path().join(NEW)).expect("read"),
        "a\nB\nc\nd\nside\nlast\n"
    );
    assert!(!rt.repo(&key).unwrap().file_history_has_working());
    assert!(rt.restore_file_version(&key, "0000").is_none());
}

#[test]
fn a_deleting_commit_cannot_be_restored() {
    let repo = TestRepo::init();
    repo.commit("gone.txt", "a\n", "Add gone");
    repo.git(&["rm", "--quiet", "gone.txt"]);
    let deleted = repo.commit("other.txt", "x\n", "Delete gone");
    let (mut rt, key) = open(&repo);
    open_history(&mut rt, &key, request("gone.txt", None));
    assert_eq!(listed(&rt, &key), ["Delete gone", "Add gone"]);
    assert!(rt.restore_file_version(&key, &deleted).is_none());
}

#[test]
fn opening_another_file_replaces_the_history() {
    let repo = renamed_with_side_edit();
    let (mut rt, key) = open(&repo);
    rt.open_file_history(&key, request(NEW, None));
    rt.open_file_history(&key, request("other.txt", None));
    wait_loaded(&mut rt, &key);
    assert_eq!(listed(&rt, &key), ["Unrelated"]);
    let state = rt.repo(&key).unwrap();
    assert_eq!(
        state.file_history().unwrap().request().path,
        PathBuf::from("other.txt")
    );
    settle(&mut rt, &key);
    assert_eq!(rt.pending_jobs(), 0);
}

/// Waits for the uncommitted changes' line counts.
fn working_stats(rt: &mut Runtime, key: &Path, expected: Option<(u32, u32)>) {
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .and_then(|s| s.file_history_working())
            .is_some_and(|w| w.stats == expected)
    });
}

#[test]
fn the_uncommitted_changes_row_counts_its_lines() {
    let repo = renamed_with_side_edit();
    let (mut rt, key) = open(&repo);
    open_history(&mut rt, &key, request(NEW, None));
    assert!(rt.repo(&key).unwrap().file_history_working().is_none());

    // One line replaced and one added, part of it staged.
    repo.write(NEW, "a\nB\nc\nD\nside\nlast\n");
    repo.git(&["add", NEW]);
    repo.write(NEW, "a\nB\nc\nD\nside\nlast\nlocal\n");
    settle(&mut rt, &key);
    working_stats(&mut rt, &key, Some((2, 1)));
    let row = rt.repo(&key).unwrap().file_history_working().unwrap();
    assert_eq!(row.code, "M");
    assert_eq!(row.original_path, None);

    // Edited again without a change of status: counted again.
    repo.write(NEW, "a\nB\nc\nD\nside\nlast\nlocal\nmore\n");
    settle(&mut rt, &key);
    working_stats(&mut rt, &key, Some((3, 1)));

    // Deleted.
    fs::remove_file(repo.path().join(NEW)).expect("remove");
    settle(&mut rt, &key);
    working_stats(&mut rt, &key, Some((0, 6)));
    assert_eq!(
        rt.repo(&key).unwrap().file_history_working().unwrap().code,
        "D"
    );
}

#[test]
fn untracked_and_renamed_files_count_their_uncommitted_lines() {
    let repo = TestRepo::init();
    repo.commit("before.txt", "1\n2\n3\n", "Add before");
    repo.write("new file.txt", "one\ntwo\n");
    repo.write("data.bin", "a\0b\n");
    let (mut rt, key) = open(&repo);
    open_history(&mut rt, &key, request("new file.txt", None));
    working_stats(&mut rt, &key, Some((2, 0)));
    assert_eq!(
        rt.repo(&key).unwrap().file_history_working().unwrap().code,
        "?"
    );

    // A binary file has no counts.
    open_history(&mut rt, &key, request("data.bin", None));
    settle(&mut rt, &key);
    working_stats(&mut rt, &key, None);

    // A rename that is not committed yet, with an edit.
    repo.git(&["mv", "before.txt", "áfter.txt"]);
    repo.write("áfter.txt", "1\n2\n3\n4\n");
    settle(&mut rt, &key);
    open_history(&mut rt, &key, request("áfter.txt", None));
    working_stats(&mut rt, &key, Some((1, 0)));
    let row = rt.repo(&key).unwrap().file_history_working().unwrap();
    assert_eq!(row.code, "R");
    assert_eq!(row.original_path, Some(PathBuf::from("before.txt")));
}

#[test]
fn a_filter_narrows_the_history_and_hides_the_uncommitted_changes() {
    let repo = renamed_with_side_edit();
    repo.write(NEW, "a\nB\nc\nd\nside\nlast\nlocal\n");
    let (mut rt, key) = open(&repo);
    open_history(&mut rt, &key, request(NEW, None));
    assert_eq!(listed(&rt, &key).len(), 6);
    assert!(rt.repo(&key).unwrap().file_history_has_working());
    let rename = oid_of(&rt, &key, "Rename and edit");
    let last = oid_of(&rt, &key, "Last");

    // By subject, any case.
    rt.set_file_history_filter(&key, "  EDIT ");
    let events = rt.poll();
    assert!(events
        .iter()
        .any(|e| matches!(e, RuntimeEvent::FileHistoryChanged { .. })));
    assert_eq!(listed(&rt, &key), ["Side edit", "Rename and edit", "Edit"]);
    let state = rt.repo(&key).unwrap();
    let history = state.file_history().unwrap();
    assert_eq!(history.filter(), "EDIT");
    assert_eq!((history.row_count(), history.total_count()), (3, 6));
    assert_eq!(history.index_of(&rename), Some(1));
    assert_eq!(history.index_of(&last), None);
    assert_eq!(history.rows(1, 5).len(), 2);
    assert!(history.version_of(&last).is_some());
    assert!(!state.file_history_has_working());

    // By the start of a hash, and by author.
    rt.set_file_history_filter(&key, &rename[..7]);
    assert_eq!(listed(&rt, &key), ["Rename and edit"]);
    rt.set_file_history_filter(&key, "lövelace");
    assert_eq!(listed(&rt, &key).len(), 6);
    rt.set_file_history_filter(&key, "nothing like this");
    assert!(listed(&rt, &key).is_empty());

    // A reload keeps the filter.
    rt.set_file_history_filter(&key, "edit");
    repo.git(&["checkout", "--", NEW]);
    repo.commit(NEW, "a\nB\nc\nd\nside\nlast\nnewer\n", "Newer edit");
    settle(&mut rt, &key);
    poll_until(&mut rt, |rt, _| listed(rt, &key).len() == 4);
    assert_eq!(listed(&rt, &key)[0], "Newer edit");

    // Cleared: everything shows again.
    rt.set_file_history_filter(&key, " ");
    assert_eq!(listed(&rt, &key).len(), 7);
    assert_eq!(shown(&rt, &key).filter(), "");
}
