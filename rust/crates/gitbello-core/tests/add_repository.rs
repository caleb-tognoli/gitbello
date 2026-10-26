//! Creating and cloning repositories before a RepoState exists.

mod support;

use gitbello_core::config::Config;
use gitbello_core::git::GitErrorKind;
use gitbello_core::runtime::{JobState, Runtime, RuntimeEvent};
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
    let job = rt.create_repository(&target, "trunk");
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
    let job = rt.clone_repository(&fixture.path().to_string_lossy(), &target);
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

    let job = rt.create_repository(fixture.path(), "main");
    let error = finish(&mut rt, fixture.path(), Some(job)).expect("nonempty init must fail");
    assert_eq!(error.kind, GitErrorKind::AlreadyExists);

    let job = rt.clone_repository(&fixture.path().to_string_lossy(), fixture.path());
    let error = finish(&mut rt, fixture.path(), Some(job)).expect("nonempty clone must fail");
    assert_eq!(error.kind, GitErrorKind::AlreadyExists);

    let target = fixture.path().with_file_name("missing source target");
    let missing = fixture.path().with_file_name("missing source");
    let job = rt.clone_repository(&missing.to_string_lossy(), &target);
    let error = finish(&mut rt, &target, Some(job)).expect("missing clone source must fail");
    assert!(!error.stderr.is_empty());
    assert!(rt.repo(&target).is_none());
}
