//! Runtime: opening, refreshing, watching and graph reloads on real repos.

mod support;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use gitbello_core::config::Config;
use gitbello_core::git::GitErrorKind;
use gitbello_core::jobs::RefreshKind;
use gitbello_core::runtime::{normalize, Runtime, RuntimeEvent};
use gitbello_core::sidebar::LabelKind;
use support::TestRepo;

const WAIT: Duration = Duration::from_secs(10);

fn runtime() -> Runtime {
    Runtime::new(Config::default(), None).expect("git available")
}

/// Polls until `done` returns true for an event (or the runtime state);
/// returns every event seen.
fn poll_until(
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

fn updated(events: &[RuntimeEvent], repo: &Path, kind: RefreshKind) -> bool {
    events
        .iter()
        .any(|e| matches!(e, RuntimeEvent::Updated { repo: r, kind: k } if r == repo && *k == kind))
}

fn open_ready(rt: &mut Runtime, path: &Path) -> PathBuf {
    let key = rt.open(path);
    poll_until(rt, |rt, _| {
        rt.repo(&key).is_some_and(|s| {
            s.status().is_some()
                && s.refs().is_some()
                && s.worktrees().is_some()
                && s.stashes().is_some()
                && s.graph().is_some_and(|g| g.progress().is_finished())
        })
    });
    key
}

#[test]
fn opening_resolves_and_loads_everything() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    repo.git(&["tag", "v1"]);
    repo.write("dirty.txt", "x");
    let mut rt = runtime();
    let key = rt.open(repo.path());
    assert_eq!(key, normalize(repo.path()));
    let events = poll_until(&mut rt, |_, ev| {
        ev.iter().any(|e| matches!(e, RuntimeEvent::Opened { .. }))
            && RefreshKind::ALL.iter().all(|k| updated(ev, &key, *k))
    });
    assert!(events.contains(&RuntimeEvent::CommandsLogged));

    let key = open_ready(&mut rt, repo.path());
    let state = rt.repo(&key).unwrap();
    assert_eq!(state.display_name(), "wörk tree");
    let badge = state.badge();
    assert_eq!((badge.changed, badge.head.as_str()), (1, "main"));
    assert_eq!(state.graph().unwrap().row_count(), 1);
    let head = state.status().unwrap().oid.clone().unwrap();
    let labels: Vec<_> = state
        .labels(&head)
        .iter()
        .map(|l| (l.name.as_str(), l.kind))
        .collect();
    assert_eq!(
        labels,
        [("main", LabelKind::Branch), ("v1", LabelKind::Tag)]
    );
    assert_eq!(rt.config().known_repos.first(), Some(&key));
}

#[test]
fn opening_twice_returns_the_same_key() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let mut rt = runtime();
    let a = rt.open(repo.path());
    let b = rt.open(repo.path());
    assert_eq!(a, b);
    assert_eq!(rt.repos().count(), 1);
}

#[test]
fn opening_a_plain_folder_fails_with_a_classified_error() {
    let repo = TestRepo::init();
    let mut rt = runtime();
    let key = rt.open(&repo.non_repo_dir());
    let events = poll_until(&mut rt, |_, ev| {
        ev.iter()
            .any(|e| matches!(e, RuntimeEvent::OpenFailed { .. }))
    });
    let error = events.iter().find_map(|e| match e {
        RuntimeEvent::OpenFailed { repo, error } if *repo == key => Some(error.clone()),
        _ => None,
    });
    assert_eq!(error.map(|e| e.kind), Some(GitErrorKind::NotARepository));
    assert!(rt.repo(&key).unwrap().open_error().is_some());
}

#[test]
fn outside_changes_arrive_through_the_watcher() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let mut rt = runtime();
    let key = open_ready(&mut rt, repo.path());
    std::thread::sleep(Duration::from_millis(300));
    rt.poll();

    repo.write("a.txt", "changed outside\n");
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).is_some_and(|s| s.badge().changed == 1)
    });
}

#[test]
fn a_new_commit_reloads_the_graph_once() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let mut rt = runtime();
    let key = open_ready(&mut rt, repo.path());
    std::thread::sleep(Duration::from_millis(300));
    rt.poll();

    repo.commit("a.txt", "b\n", "second");
    let events = poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.graph())
            .is_some_and(|g| g.progress().is_finished() && g.row_count() == 2)
    });
    // Status (HEAD moved) and refs (branch moved) both changed; one reload.
    std::thread::sleep(Duration::from_millis(400));
    let mut events = events;
    events.extend(rt.poll());
    let resets = events
        .iter()
        .filter(|e| matches!(e, RuntimeEvent::GraphReset { .. }))
        .count();
    assert_eq!(resets, 1, "{events:#?}");
}

#[test]
fn focus_refresh_picks_up_changes_and_close_forgets_the_repo() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let mut rt = runtime();
    let key = open_ready(&mut rt, repo.path());
    rt.on_focus(&key);
    let events = poll_until(&mut rt, |_, ev| updated(ev, &key, RefreshKind::Status));
    assert!(updated(&events, &key, RefreshKind::Status));

    rt.close(&key);
    assert!(rt.repo(&key).is_none());
    repo.write("a.txt", "after close\n");
    std::thread::sleep(Duration::from_millis(600));
    let late: Vec<_> = rt
        .poll()
        .into_iter()
        .filter(|e| !matches!(e, RuntimeEvent::CommandsLogged))
        .collect();
    assert!(late.is_empty(), "{late:#?}");
}

#[test]
fn saves_config_with_recent_repos() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let config_path = repo.sibling("cönfig").join("config.toml");
    let mut rt = Runtime::new(Config::default(), Some(config_path.clone())).unwrap();
    let key = rt.open(repo.path());
    rt.config_mut().open_tabs = vec![key.clone()];
    rt.save_config().unwrap();
    let (loaded, error) = Runtime::load_config(Some(&config_path));
    assert!(error.is_none());
    assert_eq!(loaded.known_repos, vec![key.clone()]);
    assert_eq!(loaded.open_tabs, vec![key]);
}
