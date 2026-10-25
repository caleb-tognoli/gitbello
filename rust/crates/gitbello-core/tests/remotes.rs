//! Remotes (M6.5 P2): listed with their URLs, added, renamed, re-pointed and
//! removed through the runtime, on temporary repositories.

mod support;

use std::path::Path;

use gitbello_core::ops::RefOp;
use gitbello_core::repo::Remote;
use gitbello_core::runtime::Runtime;
use support::rt::{finish, ok, open, settle};
use support::TestRepo;

fn remotes(rt: &Runtime, key: &Path) -> Vec<Remote> {
    rt.repo(key).expect("open").remote_list().to_vec()
}

#[test]
fn lists_adds_renames_repoints_and_removes_remotes() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let origin = support::path_arg(&repo.add_remote());
    let (mut rt, key) = open(&repo);
    settle(&mut rt, &key);
    let listed = remotes(&rt, &key);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].name, "origin");
    assert_eq!(listed[0].fetch_url, origin);
    assert_eq!(listed[0].push_url, origin);

    let mirror = support::path_arg(&repo.sibling("mïrror with space.git"));
    let add = RefOp::AddRemote {
        name: "team/backup".into(),
        url: mirror.clone(),
    };
    ok(&mut rt, &key, |rt| rt.ref_op(&key, add));
    let names: Vec<String> = remotes(&rt, &key).into_iter().map(|r| r.name).collect();
    assert_eq!(names, ["origin", "team/backup"]);
    assert_eq!(
        rt.repo(&key).expect("open").remotes(),
        ["origin", "team/backup"]
    );

    let job = rt.ref_op(
        &key,
        RefOp::AddRemote {
            name: "origin".into(),
            url: mirror.clone(),
        },
    );
    assert!(
        finish(&mut rt, &key, job).is_some(),
        "an existing name is refused"
    );

    let rename = RefOp::RenameRemote {
        old: "team/backup".into(),
        new: "backup".into(),
    };
    ok(&mut rt, &key, |rt| rt.ref_op(&key, rename));
    let elsewhere = support::path_arg(&repo.sibling("elsewhere.git"));
    let repoint = RefOp::SetRemoteUrl {
        name: "backup".into(),
        url: elsewhere.clone(),
    };
    ok(&mut rt, &key, |rt| rt.ref_op(&key, repoint));
    let backup = remotes(&rt, &key)
        .into_iter()
        .find(|r| r.name == "backup")
        .expect("renamed");
    assert_eq!(
        (backup.fetch_url.as_str(), backup.push_url.as_str()),
        (elsewhere.as_str(), elsewhere.as_str())
    );

    // Removing origin also drops its remote-tracking branches and main's upstream.
    let remove = RefOp::RemoveRemote {
        name: "origin".into(),
    };
    ok(&mut rt, &key, |rt| rt.ref_op(&key, remove));
    let state = rt.repo(&key).expect("open");
    assert_eq!(state.remotes(), ["backup"]);
    assert!(state
        .refs()
        .expect("refs read")
        .iter()
        .all(|r| !r.name.starts_with("refs/remotes/origin/")));
    assert_eq!(state.branch("main").and_then(|r| r.upstream.clone()), None);
}

#[test]
fn refs_carry_their_commit_date() {
    let repo = TestRepo::init();
    repo.commit("a.txt", "a\n", "first");
    let (mut rt, key) = open(&repo);
    settle(&mut rt, &key);
    let expected: i64 = repo
        .git(&["log", "-1", "--format=%ct"])
        .trim()
        .parse()
        .unwrap();
    let main = rt
        .repo(&key)
        .expect("open")
        .branch("main")
        .cloned()
        .expect("main");
    assert_eq!(main.committed_at, Some(expected));
}
