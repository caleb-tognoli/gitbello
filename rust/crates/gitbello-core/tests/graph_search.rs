//! History search (PLAN M6.5 P5) over real graph loads: following a load in
//! progress, cancelling, and through the runtime (new queries, graph reloads).

mod support;

use std::fmt::Write as _;
use std::time::{Duration, Instant};

use gitbello_core::graph::{CommitMatcher, CommitSearch, GraphLoader, SEARCH_CHUNK_ROWS};
use gitbello_core::runtime::RuntimeEvent;
use support::rt::{open, poll_until};
use support::TestRepo;

/// A fast-import stream of `commits` linear commits, "Change N", by three
/// authors in turn.
fn linear_history(commits: usize) -> String {
    let mut out = String::new();
    for i in 1..=commits {
        let time = 1_700_000_000 + i as i64 * 60;
        let author = [
            "Ada <ada@example.com>",
            "Grace <grace@navy.mil>",
            "Linus <linus@kernel.org>",
        ][i % 3];
        _ = writeln!(out, "commit refs/heads/main\nmark :{i}");
        _ = writeln!(out, "author {author} {time} +0000");
        _ = writeln!(out, "committer {author} {time} +0000");
        let msg = format!("Change {i}");
        _ = writeln!(out, "data {}\n{msg}", msg.len());
        if i > 1 {
            _ = writeln!(out, "from :{}", i - 1);
        }
        _ = writeln!(
            out,
            "M 644 inline f.txt\ndata {}\n{i}\n",
            i.to_string().len() + 1
        );
    }
    out
}

/// Runs `search` to the end on this thread, following the load.
fn finish(search: &CommitSearch) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !search.is_done() {
        search.run_now();
        assert!(Instant::now() < deadline, "search did not finish");
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn search_follows_a_load_in_progress_and_matches_a_full_scan() {
    let repo = TestRepo::init();
    let commits = 2 * SEARCH_CHUNK_ROWS + 300;
    repo.fast_import(&linear_history(commits));
    let loader = GraphLoader::start(repo.runner().clone(), repo.path().to_path_buf());
    // Started right away, so (on most runs) rows are still arriving.
    let search = CommitSearch::new("change 1", loader.reader()).expect("a query");
    finish(&search);
    assert_eq!(search.searched(), commits);

    let mut expected = Vec::new();
    let index = loader.index();
    CommitMatcher::new("change 1")
        .expect("a query")
        .scan(&index, 0..commits, &mut expected);
    let expected: Vec<usize> = expected.iter().map(|&row| row as usize).collect();
    assert_eq!(search.match_count(), expected.len());
    assert_eq!(search.matches(0, usize::MAX), expected);
    // Newest first: "Change 8492" ... down to "Change 1".
    assert_eq!(
        index
            .commit(*expected.last().expect("matches"))
            .map(|c| c.subject),
        Some("Change 1")
    );

    // Stepping wraps around and works from rows that are not matches.
    let first = expected[0];
    let last = *expected.last().expect("matches");
    assert_eq!(search.next_match(last, true), Some(first));
    assert_eq!(search.next_match(first, false), Some(last));
    assert_eq!(search.next_match(first, true), Some(expected[1]));
    assert_eq!(search.next_match(first + 1, false), Some(first));
    assert_eq!(search.match_index(expected[1]), Some(1));
    assert!(search.is_match(first));
    assert!(!search.is_match(first + 1) || expected.contains(&(first + 1)));

    // Authors and hash prefixes.
    let grace = CommitSearch::new("NAVY.MIL", loader.reader()).expect("a query");
    finish(&grace);
    assert_eq!(
        grace.match_count(),
        (1..=commits).filter(|i| i % 3 == 1).count()
    );
    let hash = index.commit(5).expect("row 5").hash_hex();
    let by_hash = CommitSearch::new(&hash[..8], loader.reader()).expect("a query");
    finish(&by_hash);
    assert_eq!(by_hash.matches(0, 10), [5]);
}

#[test]
fn a_cancelled_search_stops() {
    let repo = TestRepo::init();
    repo.fast_import(&linear_history(50));
    let loader = GraphLoader::start(repo.runner().clone(), repo.path().to_path_buf());
    let search = CommitSearch::new("change", loader.reader()).expect("a query");
    search.cancel();
    search.run_now();
    assert_eq!(search.searched(), 0);
    assert_eq!(search.match_count(), 0);
    assert!(CommitSearch::new("  ", loader.reader()).is_none());
}

fn search_changed(events: &[RuntimeEvent]) -> bool {
    events
        .iter()
        .any(|e| matches!(e, RuntimeEvent::SearchChanged { .. }))
}

#[test]
fn runtime_searches_reruns_after_a_reload_and_clears() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "1\n", "Add parser");
    repo.commit("a.txt", "2\n", "Fix typo");
    repo.commit("a.txt", "3\n", "Parser: handle tabs");
    let (mut rt, key) = open(&repo);
    let done = |rt: &gitbello_core::runtime::Runtime| {
        rt.repo(&key)
            .and_then(|s| s.search())
            .is_some_and(CommitSearch::is_done)
    };

    rt.search_commits(&key, "PARSER");
    let events = poll_until(&mut rt, |rt, _| done(rt));
    assert!(search_changed(&events));
    let search = rt.repo(&key).and_then(|s| s.search()).expect("a search");
    assert_eq!(search.matches(0, 10), [0, 2]);
    assert_eq!(rt.repo(&key).map(|s| s.search_query()), Some("PARSER"));

    // A new commit reloads the graph; the search runs again on it.
    repo.commit("a.txt", "4\n", "Parser docs");
    rt.refresh(&key, gitbello_core::jobs::RefreshSet::all());
    poll_until(&mut rt, |rt, _| {
        done(rt)
            && rt
                .repo(&key)
                .and_then(|s| s.search())
                .is_some_and(|s| s.match_count() == 3)
    });
    let search = rt.repo(&key).and_then(|s| s.search()).expect("a search");
    assert_eq!(search.matches(0, 10), [0, 1, 3]);

    // A blank query ends the search, and says so.
    rt.search_commits(&key, "");
    let events = poll_until(&mut rt, |_, ev| search_changed(ev));
    assert!(search_changed(&events));
    assert!(rt.repo(&key).and_then(|s| s.search()).is_none());
}
