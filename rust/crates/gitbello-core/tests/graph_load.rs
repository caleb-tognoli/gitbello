mod support;

use std::fmt::Write as _;

use gitbello_core::git::GitErrorKind;
use gitbello_core::graph::{
    GraphLoadError, GraphLoader, LoadState, SegmentKind, CHECKPOINT_INTERVAL,
};
use support::TestRepo;

fn load(repo: &TestRepo) -> GraphLoader {
    let loader = GraphLoader::start(repo.runner().clone(), repo.path().to_path_buf());
    let progress = loader.progress();
    assert!(matches!(
        progress.state,
        LoadState::Loading | LoadState::Done
    ));
    loader
}

fn wait_done(loader: GraphLoader) -> GraphLoader {
    // Polls instead of `wait` so the caller keeps the handle to read the index.
    let progress = {
        let mut progress = loader.progress();
        while progress.state == LoadState::Loading {
            std::thread::sleep(std::time::Duration::from_millis(5));
            progress = loader.progress();
        }
        progress
    };
    assert_eq!(progress.state, LoadState::Done, "{progress:?}");
    assert!(progress.total.is_some() && progress.first_page.is_some());
    loader
}

#[test]
fn loads_linear_history_newest_first() {
    let repo = TestRepo::init();
    let hashes: Vec<String> = (0..5)
        .map(|i| repo.commit("f.txt", &format!("{i}\n"), &format!("commit {i}")))
        .collect();

    let loader = wait_done(load(&repo));
    let index = loader.index();
    assert_eq!(index.row_count(), 5);
    for row in 0..5 {
        let commit = index.commit(row).unwrap();
        assert_eq!(commit.hash_hex(), hashes[4 - row]);
        assert_eq!(commit.subject, format!("commit {}", 4 - row));
        assert_eq!(commit.author_name, "Ada Lövelace");
    }
    assert!(index.layouts(0, 5).iter().all(|row| row.column == 0));
    assert_eq!(index.max_width(), 1);
}

#[test]
fn lays_out_a_feature_branch_merge() {
    let repo = TestRepo::init();
    repo.commit("base.txt", "base\n", "base");
    repo.branch("feature");
    repo.commit("main.txt", "main\n", "main work");
    repo.checkout("feature");
    repo.commit("feature.txt", "feature\n", "feature work");
    repo.checkout("main");
    let merge = repo.merge("feature", "Merge feature");

    let loader = wait_done(load(&repo));
    let index = loader.index();
    assert_eq!(index.row_count(), 4);
    let top = index.commit(0).unwrap();
    assert_eq!(top.hash_hex(), merge);
    assert_eq!(top.parent_rows.len(), 2);

    let layouts = index.layouts(0, 4);
    let merge_outs = layouts[0]
        .segments
        .iter()
        .filter(|s| s.kind == SegmentKind::Out)
        .count();
    assert_eq!(merge_outs, 2, "{:?}", layouts[0]);
    assert_eq!(index.max_width(), 2);
    // The base commit closes both lanes.
    let base_ins = layouts[3]
        .segments
        .iter()
        .filter(|s| s.kind == SegmentKind::In)
        .count();
    assert_eq!(base_ins, 2, "{:?}", layouts[3]);
}

#[test]
fn empty_repository_loads_zero_rows() {
    let repo = TestRepo::init();
    let loader = wait_done(load(&repo));
    assert_eq!(loader.index().row_count(), 0);
}

#[test]
fn non_repository_fails_with_a_classified_error() {
    let repo = TestRepo::init();
    let loader = GraphLoader::start(repo.runner().clone(), repo.non_repo_dir());
    let progress = loader.wait();
    match progress.state {
        LoadState::Failed(GraphLoadError::Git(err)) => {
            assert_eq!(err.kind, GitErrorKind::NotARepository)
        }
        other => panic!("unexpected state {other:?}"),
    }
}

/// A fast-import stream with `commits` commits on a few branches that merge
/// back into `main` regularly.
fn branchy_history(commits: usize) -> String {
    let mut out = String::new();
    let mut branch_tips: Vec<Option<usize>> = vec![None; 4];
    let mut main_tip: Option<usize> = None;
    for i in 1..=commits {
        let branch = i % 5;
        let time = 1_700_000_000 + i as i64 * 60;
        let ref_name = if branch == 0 {
            "refs/heads/main".to_owned()
        } else {
            format!("refs/heads/topic-{branch}")
        };
        _ = writeln!(out, "commit {ref_name}\nmark :{i}");
        _ = writeln!(out, "committer Ada <ada@example.com> {time} +0000");
        let msg = format!("commit {i}");
        _ = writeln!(out, "data {}\n{msg}", msg.len());
        if branch == 0 {
            if let Some(tip) = main_tip {
                _ = writeln!(out, "from :{tip}");
            }
            for tip in branch_tips.iter_mut() {
                if let Some(t) = tip.take() {
                    _ = writeln!(out, "merge :{t}");
                }
            }
            main_tip = Some(i);
        } else {
            let slot = &mut branch_tips[branch - 1];
            match (*slot, main_tip) {
                (Some(t), _) | (None, Some(t)) => _ = writeln!(out, "from :{t}"),
                (None, None) => {}
            }
            *slot = Some(i);
        }
        _ = writeln!(
            out,
            "M 644 inline f{branch}.txt\ndata {}\n{i}\n",
            i.to_string().len() + 1
        );
    }
    out
}

#[test]
fn large_history_slices_match_and_parents_resolve() {
    let repo = TestRepo::init();
    let commits = 3 * CHECKPOINT_INTERVAL + 17;
    repo.fast_import(&branchy_history(commits));
    let expected = repo.git(&["rev-list", "--all", "--count"]);

    let loader = wait_done(load(&repo));
    let index = loader.index();
    assert_eq!(index.row_count().to_string(), expected);

    let full = index.layouts(0, index.row_count());
    for start in (0..index.row_count()).step_by(53) {
        assert_eq!(
            index.layouts(start, 40),
            full[start..(start + 40).min(full.len())]
        );
    }
    // Topological order: every parent appears below its child.
    for row in 0..index.row_count() {
        let commit = index.commit(row).unwrap();
        assert!(commit.parent_rows.iter().all(|&p| p > row), "row {row}");
    }
    assert!(index.max_width() >= 3);
}

#[test]
fn loads_as_a_scheduler_job_and_reports_events() {
    use gitbello_core::backend::CliBackend;
    use gitbello_core::jobs::{EventKind, JobOutput, JobScheduler};
    use std::sync::Arc;
    use std::time::Duration;

    let repo = TestRepo::init();
    for i in 0..3 {
        repo.commit("f.txt", &format!("{i}\n"), &format!("c{i}"));
    }
    let (scheduler, events) =
        JobScheduler::new(Arc::new(CliBackend::new(repo.runner().clone())), 2);
    let (loader, job) =
        GraphLoader::submit(&scheduler, repo.runner().clone(), repo.path().to_path_buf());
    let finished = loop {
        let event = events.recv_timeout(Duration::from_secs(10)).unwrap();
        if event.job == job && !matches!(event.kind, EventKind::Started) {
            break event.kind;
        }
    };
    assert_eq!(finished, EventKind::Finished(Ok(JobOutput::Done)));
    assert_eq!(loader.index().row_count(), 3);
    assert_eq!(loader.progress().state, LoadState::Done);
}

#[test]
fn scheduler_graph_job_reports_git_errors() {
    use gitbello_core::backend::CliBackend;
    use gitbello_core::jobs::{EventKind, JobScheduler};
    use std::sync::Arc;
    use std::time::Duration;

    let repo = TestRepo::init();
    let (scheduler, events) =
        JobScheduler::new(Arc::new(CliBackend::new(repo.runner().clone())), 1);
    let (loader, job) = GraphLoader::submit(&scheduler, repo.runner().clone(), repo.non_repo_dir());
    let finished = loop {
        let event = events.recv_timeout(Duration::from_secs(10)).unwrap();
        if event.job == job && !matches!(event.kind, EventKind::Started) {
            break event.kind;
        }
    };
    assert!(
        matches!(&finished, EventKind::Finished(Err(err)) if err.kind == GitErrorKind::NotARepository),
        "{finished:?}"
    );
    assert!(matches!(loader.progress().state, LoadState::Failed(_)));
}
