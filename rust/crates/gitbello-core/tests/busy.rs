//! What keeps a busy machine usable: refreshes that find nothing new cost no
//! UI work, the shown diff loads again only when its file changed, and a
//! hidden history waits until it is shown, then reloads behind the shown rows.

use crate::support;

use std::path::Path;

use gitbello_core::graph::HistoryScope;
use gitbello_core::jobs::{RefreshKind, RefreshSet};
use gitbello_core::runtime::{Runtime, RuntimeEvent};
use support::rt::{open, poll_until};
use support::TestRepo;

fn status_only() -> RefreshSet {
    RefreshSet::EMPTY.with(RefreshKind::Status)
}

/// Requests a status refresh and polls until it has landed; returns the
/// events seen meanwhile.
fn refresh_status(rt: &mut Runtime, key: &Path) -> Vec<RuntimeEvent> {
    rt.refresh(key, status_only());
    let mut seen = poll_until(rt, |rt, _| {
        rt.repo(key)
            .is_some_and(|s| s.refreshing().contains(RefreshKind::Status))
    });
    seen.extend(poll_until(rt, |rt, _| {
        rt.repo(key)
            .is_some_and(|s| !s.refreshing().contains(RefreshKind::Status))
    }));
    // Whatever the refresh started (a diff load) reports within a few polls.
    for _ in 0..50 {
        seen.extend(rt.poll());
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    seen
}

fn diff_shows(rt: &Runtime, key: &Path, text: &str) -> bool {
    rt.repo(key)
        .and_then(|s| s.diff())
        .filter(|d| !d.is_loading())
        .and_then(|d| d.diff())
        .is_some_and(|d| {
            (0..d.line_count())
                .filter_map(|i| d.line(i))
                .any(|l| l.text == text.as_bytes())
        })
}

#[test]
fn an_unchanged_status_sends_no_events_and_keeps_the_diff() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "one\n", "first");
    repo.write("a.txt", "one\ntwo\n");
    let (mut rt, key) = open(&repo);
    rt.select_change(&key, Path::new("a.txt"), false);
    poll_until(&mut rt, |rt, _| diff_shows(rt, &key, "two"));

    let events = refresh_status(&mut rt, &key);
    let noisy: Vec<&RuntimeEvent> = events
        .iter()
        .filter(|e| {
            matches!(
                e,
                RuntimeEvent::Updated { .. }
                    | RuntimeEvent::SelectionChanged { .. }
                    | RuntimeEvent::DiffChanged { .. }
            )
        })
        .collect();
    assert!(noisy.is_empty(), "{noisy:#?}");

    // The file changes but its status does not: the diff loads again.
    repo.write("a.txt", "one\ntwo\nthree\n");
    rt.refresh(&key, status_only());
    poll_until(&mut rt, |rt, _| diff_shows(rt, &key, "three"));
}

#[test]
fn a_hidden_history_waits_and_a_shown_one_reloads_behind_its_rows() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "1\n", "first");
    let (mut rt, key) = open(&repo);
    rt.set_history_scope(&key, HistoryScope::AllBranches);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.graph())
            .is_some_and(|g| g.progress().is_finished() && g.row_count() == 1)
            && !rt.repo(&key).is_some_and(|s| s.graph_stale())
    });

    rt.set_history_visible(&key, false);
    let second = repo.commit("a.txt", "2\n", "second");
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.status())
            .is_some_and(|s| s.oid.as_deref() == Some(second.as_str()))
    });
    // Well past the reload delay: still the old rows, marked stale.
    let events = poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .is_some_and(|s| s.graph_stale() && !s.graph_reloading())
    });
    std::thread::sleep(std::time::Duration::from_millis(400));
    let mut events = [events, rt.poll()].concat();
    let state = rt.repo(&key).unwrap();
    assert_eq!(state.graph().unwrap().row_count(), 1);
    assert!(!events
        .iter()
        .any(|e| matches!(e, RuntimeEvent::GraphReset { .. })));

    // Shown: it reloads with the old rows in place, then swaps once.
    rt.set_history_visible(&key, true);
    events.extend(poll_until(&mut rt, |rt, _| {
        rt.repo(&key).is_some_and(|s| s.graph_reloading())
    }));
    assert_eq!(rt.repo(&key).unwrap().graph().unwrap().row_count(), 1);
    events.extend(poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.graph())
            .is_some_and(|g| g.progress().is_finished() && g.row_count() == 2)
    }));
    let state = rt.repo(&key).unwrap();
    assert!(state.graph().unwrap().is_incremental());
    let top = state.graph().unwrap().index().commit(0).unwrap().hash_hex();
    assert_eq!(top, second);
    let resets = events
        .iter()
        .filter(|e| matches!(e, RuntimeEvent::GraphReset { .. }))
        .count();
    assert_eq!(resets, 1);
}

#[test]
fn a_status_refresh_is_reported_while_it_runs() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "1\n", "first");
    let (mut rt, key) = open(&repo);
    let events = refresh_status(&mut rt, &key);
    let reports = events
        .iter()
        .filter(|e| matches!(e, RuntimeEvent::Refreshing { repo } if *repo == key))
        .count();
    assert!(reports >= 2, "started and ended: {events:#?}");
}

#[test]
fn a_hidden_history_still_reads_head_for_the_undo_strip() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "1\n", "first");
    let (mut rt, key) = open(&repo);
    rt.set_history_visible(&key, false);
    let second = repo.commit("a.txt", "2\n", "second");
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.undoable_commit())
            .is_some_and(|c| c.oid == second)
    });
    assert!(rt.repo(&key).is_some_and(|s| s.graph_stale()));
}
