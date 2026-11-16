//! Creating and cloning repositories before a RepoState exists.

use crate::support;

use gitbello_core::config::Config;
use gitbello_core::git::GitErrorKind;
use gitbello_core::new_repo::{CloneOptions, CreateOptions};
use gitbello_core::runtime::{
    JobState, Runtime, RuntimeEvent, COMMIT_GRAPH_JOB_LABEL, FALLBACK_DEFAULT_BRANCH,
};
use support::rt::{finish, poll_until, result, succeed};
use support::TestRepo;

fn runtime(repo: &TestRepo) -> Runtime {
    let mut config = Config::default();
    config.auto_fetch_minutes = 0;
    Runtime::with_runner(config, None, repo.app_runner())
}

#[test]
fn creates_and_opens_a_repository_on_the_requested_branch() {
    let fixture = TestRepo::init();
    let target = fixture.path().with_file_name("new répo with spaces");
    let mut rt = runtime(&fixture);
    let job = rt.create_repository(&target, CreateOptions::new("trunk"));
    succeed(&mut rt, &target, Some(job));

    assert_eq!(
        fixture
            .command_in(&target)
            .args(["branch", "--show-current"])
            .run()
            .unwrap()
            .stdout_text()
            .trim(),
        "trunk"
    );
    let key = rt.open(&target);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).is_some_and(|repo| repo.status().is_some())
    });
}

#[test]
fn clones_with_progress_before_opening_a_repo_state() {
    let fixture = TestRepo::init();
    for i in 0..20 {
        fixture.commit(
            &format!("f{i}.txt"),
            &"x".repeat(1000 + i),
            &format!("c{i}"),
        );
    }
    let target = fixture.path().with_file_name("cloned répo");
    let mut rt = runtime(&fixture);
    let job = rt.clone_repository(
        &fixture.path().to_string_lossy(),
        &target,
        CloneOptions::default(),
    );
    let events = poll_until(&mut rt, |_, events| result(events, job).is_some());
    assert_eq!(result(&events, job), Some(None));
    assert!(rt.repo(&target).is_none());
    assert!(events.iter().any(|event| matches!(
        event,
        RuntimeEvent::Job { job: id, state: JobState::Started, .. } if *id == job
    )));
    assert!(events.iter().any(|event| matches!(
        event,
        RuntimeEvent::Job { job: id, state: JobState::Progress(_), .. } if *id == job
    )));
    assert_eq!(
        fixture
            .command_in(&target)
            .args(["rev-parse", "HEAD"])
            .run()
            .unwrap()
            .stdout_text()
            .trim(),
        fixture.head()
    );
}

#[test]
fn rejects_nonempty_destinations_and_missing_clone_sources() {
    let fixture = TestRepo::init();
    fixture.commit("a.txt", "a\n", "first");
    let mut rt = runtime(&fixture);

    let job = rt.create_repository(fixture.path(), CreateOptions::new("main"));
    let error = finish(&mut rt, fixture.path(), Some(job)).expect("nonempty init must fail");
    assert_eq!(error.kind, GitErrorKind::AlreadyExists);

    let job = rt.clone_repository(
        &fixture.path().to_string_lossy(),
        fixture.path(),
        CloneOptions::default(),
    );
    let error = finish(&mut rt, fixture.path(), Some(job)).expect("nonempty clone must fail");
    assert_eq!(error.kind, GitErrorKind::AlreadyExists);

    let target = fixture.path().with_file_name("missing source target");
    let missing = fixture.path().with_file_name("missing source");
    let job = rt.clone_repository(&missing.to_string_lossy(), &target, CloneOptions::default());
    let error = finish(&mut rt, &target, Some(job)).expect("missing clone source must fail");
    assert!(!error.stderr.is_empty());
    assert!(rt.repo(&target).is_none());
}

#[test]
fn reads_the_default_branch_from_the_global_config() {
    let fixture = TestRepo::init();
    let mut rt = runtime(&fixture);
    assert_eq!(rt.default_branch(), FALLBACK_DEFAULT_BRANCH);

    // The fixture's global config is empty: the fallback stays.
    let job = rt.load_default_branch();
    let events = poll_until(&mut rt, |_, events| result(events, job).is_some());
    assert_eq!(result(&events, job), Some(None));
    assert_eq!(rt.default_branch(), "main");

    // `--global` writes the fixture's scratch `GIT_CONFIG_GLOBAL`.
    fixture
        .command()
        .args(["config", "--global", "init.defaultBranch", "trunk"])
        .run()
        .unwrap();
    let job = rt.load_default_branch();
    poll_until(&mut rt, |_, events| result(events, job).is_some());
    assert_eq!(rt.default_branch(), "trunk");

    fixture
        .command()
        .args(["config", "--global", "--unset", "init.defaultBranch"])
        .run()
        .unwrap();
    let job = rt.load_default_branch();
    poll_until(&mut rt, |_, events| result(events, job).is_some());
    assert_eq!(rt.default_branch(), "main");
}

fn commit_graph_events(events: &[RuntimeEvent]) -> Vec<(usize, &JobState)> {
    events
        .iter()
        .enumerate()
        .filter_map(|(i, event)| match event {
            RuntimeEvent::Job { label, state, .. } if label == COMMIT_GRAPH_JOB_LABEL => {
                Some((i, state))
            }
            _ => None,
        })
        .collect()
}

#[test]
fn writes_the_commit_graph_after_a_clone_has_reported() {
    let fixture = TestRepo::init();
    for i in 0..5 {
        fixture.commit(
            &format!("f{i}.txt"),
            &format!(
                "{i}
"
            ),
            &format!("c{i}"),
        );
    }
    let target = fixture.path().with_file_name("graph clöne");
    let mut rt = runtime(&fixture);
    let job = rt.clone_repository(
        &fixture.path().to_string_lossy(),
        &target,
        CloneOptions::default(),
    );
    let events = poll_until(&mut rt, |_, events| {
        commit_graph_events(events)
            .iter()
            .any(|(_, state)| matches!(state, JobState::Finished(_)))
    });
    let clone_done = events
        .iter()
        .position(|event| {
            matches!(event, RuntimeEvent::Job { job: id, state: JobState::Finished(None), .. } if *id == job)
        })
        .expect("the clone finished");
    let graph = commit_graph_events(&events);
    assert!(
        graph.iter().all(|(i, _)| *i > clone_done),
        "the clone reports before the commit-graph job: {events:#?}"
    );
    assert!(matches!(graph.last(), Some((_, JobState::Finished(None)))));
    let file = target.join(".git/objects/info/commit-graph");
    assert!(file.is_file(), "{} exists", file.display());
    // Changed-path filters are in it (`BIDX`/`BDAT` chunks).
    let bytes = std::fs::read(&file).unwrap();
    assert!(bytes.windows(4).any(|w| w == b"BDAT"));
}

#[test]
fn writes_no_commit_graph_for_created_repositories() {
    let fixture = TestRepo::init();
    let target = fixture.path().with_file_name("created");
    let mut rt = runtime(&fixture);
    let mut options = CreateOptions::new("main");
    options.readme = true;
    options.first_commit = true;
    let job = rt.create_repository(&target, options);
    let events = poll_until(&mut rt, |_, events| result(events, job).is_some());
    assert_eq!(result(&events, job), Some(None));
    // Anything queued after the create has had time to start by now.
    let later = poll_until(&mut rt, {
        let start = std::time::Instant::now();
        move |_, _| start.elapsed() > std::time::Duration::from_millis(300)
    });
    assert!(commit_graph_events(&events).is_empty());
    assert!(commit_graph_events(&later).is_empty());
    assert!(!target.join(".git/objects/info/commit-graph").exists());
}
