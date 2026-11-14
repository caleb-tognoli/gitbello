use crate::support;

use gitbello_core::backend::{CliBackend, GitBackend};
use gitbello_core::git::CancelToken;
use gitbello_core::graph::{HistoryScope, LoadState};
use gitbello_core::runtime::RuntimeEvent;
use support::rt::{open, poll_until, settle};
use support::TestRepo;

#[test]
fn outgoing_is_relative_to_the_configured_upstream_not_any_remote() {
    let repo = TestRepo::init();
    let base = repo.commit("base", "base", "base");
    repo.add_remote();
    let first = repo.commit("a", "a", "first outgoing");
    let second = repo.commit("b", "b", "second outgoing");
    repo.git(&["update-ref", "refs/remotes/elsewhere/main", &second]);
    let backend = CliBackend::new(repo.app_runner());
    let info = backend.head_info(repo.path(), &CancelToken::new()).unwrap();
    assert_eq!(info.upstream.as_deref(), Some("refs/remotes/origin/main"));
    assert!(!info.upstream_gone);
    assert_eq!(info.outgoing.len(), 2);
    assert!(info.outgoing.contains(&first) && info.outgoing.contains(&second));
    assert!(!info.outgoing.contains(&base));

    repo.git(&["push", "origin", "main"]);
    let info = backend.head_info(repo.path(), &CancelToken::new()).unwrap();
    assert!(info.outgoing.is_empty());
}

#[test]
fn without_a_remote_branch_detached_or_empty_nothing_is_outgoing() {
    let repo = TestRepo::init();
    let backend = CliBackend::new(repo.app_runner());
    assert!(backend
        .head_info(repo.path(), &CancelToken::new())
        .unwrap()
        .outgoing
        .is_empty());
    // No remote branches at all: not the whole history.
    let head = repo.commit("base", "base", "base");
    let info = backend.head_info(repo.path(), &CancelToken::new()).unwrap();
    assert!(info.upstream.is_none() && info.outgoing.is_empty());
    repo.add_remote();
    let local = repo.commit("local", "local", "local");
    repo.git(&["checkout", "--quiet", "--detach", &local]);
    let info = backend.head_info(repo.path(), &CancelToken::new()).unwrap();
    assert!(info.upstream.is_none() && !info.upstream_gone && info.outgoing.is_empty());
    assert_ne!(head, local);
}

#[test]
fn unpublished_and_gone_upstream_branches_count_commits_on_no_remote() {
    let repo = TestRepo::init();
    let base = repo.commit("base", "base", "base");
    repo.add_remote();
    repo.git(&["checkout", "--quiet", "-b", "topic"]);
    let first = repo.commit("a", "a", "first unpublished");
    let second = repo.commit("b", "b", "second unpublished");
    let backend = CliBackend::new(repo.app_runner());
    let info = backend.head_info(repo.path(), &CancelToken::new()).unwrap();
    assert!(info.upstream.is_none());
    assert_eq!(info.outgoing.len(), 2);
    assert!(info.outgoing.contains(&first) && info.outgoing.contains(&second));
    assert!(!info.outgoing.contains(&base));
    let status = backend.status(repo.path(), &CancelToken::new()).unwrap();
    assert!(status.unpublished);
    assert_eq!((status.ahead, status.behind), (2, 0));

    // On another remote branch counts as published.
    repo.git(&["update-ref", "refs/remotes/elsewhere/topic", &first]);
    let info = backend.head_info(repo.path(), &CancelToken::new()).unwrap();
    assert_eq!(info.outgoing.len(), 1);
    assert!(info.outgoing.contains(&second));
    assert_eq!(
        backend
            .status(repo.path(), &CancelToken::new())
            .unwrap()
            .ahead,
        1
    );

    // Pushed, then every remote copy is deleted: the upstream is gone and
    // both commits are unpublished again.
    repo.git(&["push", "--quiet", "-u", "origin", "topic"]);
    repo.git(&["update-ref", "-d", "refs/remotes/origin/topic"]);
    repo.git(&["update-ref", "-d", "refs/remotes/elsewhere/topic"]);
    let info = backend.head_info(repo.path(), &CancelToken::new()).unwrap();
    assert!(info.upstream_gone);
    assert_eq!(info.outgoing.len(), 2);
    let status = backend.status(repo.path(), &CancelToken::new()).unwrap();
    assert!(status.unpublished && status.upstream.is_some());
    assert_eq!(status.ahead, 2);
}

#[test]
fn divergent_upstream_and_merged_work_are_classified_by_reachability() {
    let repo = TestRepo::init();
    let base = repo.commit("base", "base", "base");
    repo.add_remote();
    repo.branch("feature");
    let main = repo.commit("main", "main", "local work");
    repo.checkout("feature");
    let feature = repo.commit("feature", "feature", "merged work");
    repo.checkout("main");
    let merge = repo.merge("feature", "merge feature");
    repo.branch("remote-work");
    repo.checkout("remote-work");
    repo.git(&["reset", "--hard", &base]);
    let remote = repo.commit("remote", "remote", "incoming work");
    repo.checkout("main");
    repo.git(&["update-ref", "refs/remotes/origin/main", &remote]);
    let backend = CliBackend::new(repo.app_runner());
    let info = backend.head_info(repo.path(), &CancelToken::new()).unwrap();
    assert_eq!(info.outgoing.len(), 3);
    for oid in [main, feature, merge] {
        assert!(info.outgoing.contains(&oid));
    }
    assert!(!info.outgoing.contains(&remote) && !info.outgoing.contains(&base));
}

#[test]
fn switching_scope_rebuilds_the_graph_and_search_without_checkout() {
    let repo = TestRepo::init();
    repo.commit("base", "base", "base");
    repo.branch("other");
    let head = repo.commit("main", "main", "current work");
    repo.checkout("other");
    let other = repo.commit("other", "other", "unrelated work");
    repo.checkout("main");
    let (mut rt, key) = open(&repo);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .unwrap()
            .graph()
            .is_some_and(|g| g.progress().state == LoadState::Done)
    });
    assert_eq!(rt.repo(&key).unwrap().graph().unwrap().row_count(), 2);
    rt.search_commits(&key, "unrelated");
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).unwrap().search().is_some_and(|s| s.is_done())
    });
    assert_eq!(rt.repo(&key).unwrap().search().unwrap().match_count(), 0);
    rt.set_history_scope(&key, HistoryScope::AllBranches);
    poll_until(&mut rt, |rt, events| {
        events
            .iter()
            .any(|e| matches!(e, RuntimeEvent::GraphReset { .. }))
            && rt
                .repo(&key)
                .unwrap()
                .graph()
                .is_some_and(|g| g.progress().state == LoadState::Done)
            && rt
                .repo(&key)
                .unwrap()
                .search()
                .is_some_and(|s| s.is_done() && s.match_count() == 1)
    });
    let state = rt.repo(&key).unwrap();
    assert_eq!(state.graph().unwrap().row_count(), 3);
    assert!(state.graph().unwrap().index().row_for_oid(&other).is_some());
    assert_eq!(repo.head(), head);
    rt.set_history_scope(&key, HistoryScope::CurrentBranch);
    poll_until(&mut rt, |rt, events| {
        events
            .iter()
            .any(|e| matches!(e, RuntimeEvent::GraphReset { .. }))
            && rt
                .repo(&key)
                .unwrap()
                .graph()
                .is_some_and(|g| g.progress().state == LoadState::Done)
            && rt
                .repo(&key)
                .unwrap()
                .search()
                .is_some_and(|s| s.is_done() && s.match_count() == 0)
    });
    assert_eq!(rt.repo(&key).unwrap().graph().unwrap().row_count(), 2);
    assert_eq!(repo.head(), head);
}

#[test]
fn runtime_refreshes_outgoing_after_upstream_moves() {
    let repo = TestRepo::init();
    repo.commit("base", "base", "base");
    repo.add_remote();
    let head = repo.commit("local", "local", "outgoing");
    let (mut rt, key) = open(&repo);
    poll_until(&mut rt, |rt, _| rt.repo(&key).unwrap().is_outgoing(&head));
    repo.git(&["push", "origin", "main"]);
    settle(&mut rt, &key);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .unwrap()
            .history_tracking()
            .is_some_and(|i| i.outgoing.is_empty())
    });
    assert!(!rt.repo(&key).unwrap().is_outgoing(&head));
}
