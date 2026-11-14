//! Avatar sources against a local HTTP stub (never the network).

use crate::support;

use std::net::TcpListener;
use std::time::Duration;

use gitbello_core::avatars::{
    email_hash, AvatarRequest, AvatarSources, CurlRunner, Endpoints, GithubRemote, ImageFormat,
    Lookup, Provider, Providers, RemoteHosts, Source,
};
use gitbello_core::git::CancelToken;
use support::http_stub::{HttpStub, Reply};

const PNG: &[u8] = b"\x89PNG\r\n\x1a\nfake picture";
const JPEG: &[u8] = b"\xff\xd8\xff\xe0fake picture";

fn curl() -> CurlRunner {
    CurlRunner::discover()
        .expect("curl is needed for the avatar tests")
        .with_timeout(Duration::from_secs(5))
}

fn sources(stub: &HttpStub, token: Option<&str>) -> AvatarSources {
    AvatarSources::new(Some(curl()), Endpoints::under(stub.base()))
        .with_github_token(token.map(str::to_string))
}

fn request(email: &str) -> AvatarRequest {
    AvatarRequest {
        email: email.into(),
        ..AvatarRequest::default()
    }
}

fn github_hosts() -> RemoteHosts {
    RemoteHosts {
        github: Some(GithubRemote {
            remote: "origin".into(),
            repo: "owner/repo".into(),
        }),
        gitlab: Vec::new(),
    }
}

fn on_github(email: &str, commit: &str) -> AvatarRequest {
    AvatarRequest {
        email: email.into(),
        commit: Some(commit.into()),
        repo: None,
        hosts: github_hosts(),
        providers: Providers::ALL,
    }
}

fn found(source: Source, bytes: &[u8], format: ImageFormat) -> Lookup {
    Lookup::Found {
        bytes: bytes.to_vec(),
        format,
        source,
    }
}

fn lookup(sources: &AvatarSources, request: &AvatarRequest) -> Lookup {
    sources.lookup(request, &CancelToken::new())
}

/// A GitHub commit object authored by `email` (its avatar on the stub) and
/// committed by `committer` (`/pictures/committer`).
fn commit_object(base: &str, email: &str, committer: &str) -> String {
    format!(
        r#"{{"sha": "abc123",
             "commit": {{"author": {{"name": "Octo", "email": "{email}"}},
                         "committer": {{"name": "Hub", "email": "{committer}"}}}},
             "author": {{"login": "octo", "avatar_url": "{base}/pictures/octo?v=4"}},
             "committer": {{"login": "hub", "avatar_url": "{base}/pictures/committer"}}}}"#
    )
}

/// The commit API's answer for a commit authored by `email`.
fn commit_json(base: &str, email: &str) -> Reply {
    Reply::json(&commit_object(base, email, "noreply@github.com"))
}

const SEARCH: &str = "/github-api/search/commits";
/// gitlab.com's avatar API, asked for every email.
const GITLAB: &str = "/gitlab/api/v4/avatar";

#[test]
fn a_noreply_address_needs_no_lookup() {
    let stub = HttpStub::start(|req, _| match req.path() {
        "/github-avatars/u/583231" => Reply::png(PNG),
        "/github/octo-cat.png" => Reply::png(JPEG),
        _ => Reply::status(404),
    });
    let sources = sources(&stub, None);
    let result = lookup(
        &sources,
        &request("583231+Octo-Cat@users.noreply.github.com"),
    );
    assert_eq!(result, found(Source::GithubNoreply, PNG, ImageFormat::Png));
    assert_eq!(stub.paths(), vec!["/github-avatars/u/583231"]);
    assert_eq!(
        stub.requests()[0].target,
        "/github-avatars/u/583231?s=80&v=4"
    );

    let result = lookup(&sources, &request("octo-cat@users.noreply.github.com"));
    assert_eq!(
        result,
        found(Source::GithubNoreply, JPEG, ImageFormat::Jpeg)
    );
    assert_eq!(stub.requests()[1].target, "/github/octo-cat.png?size=80");
}

#[test]
fn the_github_commit_api_gives_the_author_s_picture_with_the_token() {
    let stub = HttpStub::start(|req, base| match req.path() {
        "/github-api/repos/owner/repo/commits/abc123" => commit_json(base, "Dev@Example.com"),
        "/pictures/octo" => Reply {
            content_type: "image/jpeg",
            ..Reply::png(JPEG)
        },
        _ => Reply::status(404),
    });
    let sources = sources(&stub, Some("secret-token"));
    let result = lookup(&sources, &on_github("dev@example.com", "abc123"));
    assert_eq!(result, found(Source::GithubCommit, JPEG, ImageFormat::Jpeg));
    let requests = stub.requests();
    assert_eq!(
        requests[0].header("authorization"),
        Some("Bearer secret-token")
    );
    assert_eq!(requests[0].header("user-agent"), Some("gitbello"));
    assert_eq!(requests[1].target, "/pictures/octo?v=4&s=80");
    assert_eq!(
        requests[1].header("authorization"),
        None,
        "the token stays with the API"
    );
}

#[test]
fn a_co_author_is_not_given_the_commit_author_s_picture() {
    let stub = HttpStub::start(|req, base| match req.path() {
        "/github-api/repos/owner/repo/commits/abc123" => commit_json(base, "author@example.com"),
        "/pictures/octo" => Reply::png(PNG),
        _ => Reply::status(404),
    });
    let sources = sources(&stub, None);
    let result = lookup(&sources, &on_github("coauthor@example.com", "abc123"));
    assert_eq!(result, Lookup::Missing);
    let hash = email_hash("coauthor@example.com");
    assert_eq!(
        stub.paths(),
        vec![
            "/github-api/repos/owner/repo/commits/abc123".to_string(),
            GITLAB.to_string(),
            format!("/gravatar/{hash}"),
            format!("/libravatar/{hash}"),
            SEARCH.to_string(),
        ]
    );
    assert_eq!(stub.requests()[0].header("authorization"), None);
}

#[test]
fn the_commit_api_gives_the_committer_s_picture_too() {
    let stub = HttpStub::start(|req, base| match req.path() {
        "/github-api/repos/owner/repo/commits/abc123" => Reply::json(&commit_object(
            base,
            "author@example.com",
            "Merger@Example.com",
        )),
        "/pictures/committer" => Reply::png(PNG),
        _ => Reply::status(404),
    });
    let sources = sources(&stub, None);
    let result = lookup(&sources, &on_github("merger@example.com", "abc123"));
    assert_eq!(result, found(Source::GithubCommit, PNG, ImageFormat::Png));
    assert_eq!(stub.requests()[1].target, "/pictures/committer?s=80");
}

#[test]
fn github_s_commit_search_answers_last_for_anyone_else() {
    let stub = HttpStub::start(|req, base| match req.path() {
        SEARCH => Reply::json(&format!(
            r#"{{"total_count": 2, "incomplete_results": false, "items": [{}, {}]}}"#,
            commit_object(base, "co+author@example.org", "noreply@github.com")
                .replace("/pictures/octo", "/pictures/wrong"),
            commit_object(base, "Co+Author@Example.com", "noreply@github.com"),
        )),
        "/pictures/octo" => Reply::png(PNG),
        _ => Reply::status(404),
    });
    let sources = sources(&stub, Some("token"));
    let result = lookup(&sources, &on_github("co+author@example.com", "abc123"));
    assert_eq!(result, found(Source::GithubSearch, PNG, ImageFormat::Png));
    let requests = stub.requests();
    let search = requests
        .iter()
        .find(|r| r.path() == SEARCH)
        .expect("searched");
    assert_eq!(
        search.target,
        format!("{SEARCH}?q=author-email:co%2Bauthor%40example.com&per_page=5")
    );
    assert_eq!(search.header("authorization"), Some("Bearer token"));
    let order: Vec<String> = stub.paths();
    assert_eq!(order[0], "/github-api/repos/owner/repo/commits/abc123");
    assert_eq!(order[1], GITLAB);
    assert!(order[2].starts_with("/gravatar/") && order[3].starts_with("/libravatar/"));
    assert_eq!(&order[4..], [SEARCH, "/pictures/octo"]);
}

#[test]
fn a_refused_token_is_dropped_and_the_api_asked_without_it() {
    let stub = HttpStub::start(|req, base| match req.path() {
        "/github-api/repos/owner/repo/commits/abc123" if req.header("authorization").is_some() => {
            Reply::status(401)
        }
        "/github-api/repos/owner/repo/commits/abc123" => commit_json(base, "dev@example.com"),
        "/pictures/octo" => Reply::png(PNG),
        _ => Reply::status(404),
    });
    let sources = sources(&stub, Some("expired"));
    let result = lookup(&sources, &on_github("dev@example.com", "abc123"));
    assert_eq!(result, found(Source::GithubCommit, PNG, ImageFormat::Png));
    let auth: Vec<bool> = stub
        .requests()
        .iter()
        .map(|r| r.header("authorization").is_some())
        .collect();
    assert_eq!(auth, vec![true, false, false]);
}

#[test]
fn a_rate_limit_leaves_github_alone_and_caches_no_miss() {
    let stub = HttpStub::start(|req, _| match req.path() {
        p if p.starts_with("/github-api/") => Reply::status(403),
        _ => Reply::status(404),
    });
    let sources = sources(&stub, None);
    assert_eq!(
        lookup(&sources, &on_github("dev@example.com", "abc123")),
        Lookup::Unavailable
    );
    assert!(stub.paths().contains(&SEARCH.to_string()));
    let before = stub.paths().len();
    assert_eq!(
        lookup(&sources, &on_github("other@example.com", "def456")),
        Lookup::Unavailable
    );
    let after = stub.paths();
    assert_eq!(
        after.len(),
        before + 3,
        "GitLab, Gravatar and Libravatar only (the commit API and search wait): {after:?}"
    );
    assert!(after[before..]
        .iter()
        .all(|p| !p.starts_with("/github-api/")));
}

#[test]
fn gitlab_is_asked_on_gitlab_remotes_and_its_gravatar_answer_skipped() {
    let stub = HttpStub::start(|req, base| match req.path() {
        "/lab/api/v4/avatar" if req.target.contains("email=dev%2Bx%40example.com") => Reply::json(
            &format!(r#"{{"avatar_url": "{base}/lab/uploads/dev.png"}}"#),
        ),
        "/lab/api/v4/avatar" => Reply::json(
            r#"{"avatar_url": "https://secure.gravatar.com/avatar/abc?s=80&d=identicon"}"#,
        ),
        "/lab/uploads/dev.png" => Reply::png(PNG),
        _ => Reply::status(404),
    });
    let sources = sources(&stub, None);
    let on_gitlab = |email: &str| AvatarRequest {
        email: email.into(),
        commit: Some("abc123".into()),
        repo: None,
        hosts: RemoteHosts {
            github: None,
            gitlab: vec![format!("{}/lab", stub.base())],
        },
        providers: Providers::ALL,
    };
    assert_eq!(
        lookup(&sources, &on_gitlab("dev+x@example.com")),
        found(Source::Gitlab, PNG, ImageFormat::Png)
    );
    assert_eq!(
        stub.requests()[0].target,
        "/lab/api/v4/avatar?email=dev%2Bx%40example.com&size=80"
    );

    assert_eq!(
        lookup(&sources, &on_gitlab("unknown@example.com")),
        Lookup::Missing
    );
    let paths = stub.paths();
    assert_eq!(paths[2], "/lab/api/v4/avatar");
    assert_eq!(paths[3], GITLAB, "then gitlab.com");
    assert!(paths[4].starts_with("/gravatar/"), "{paths:?}");
}

#[test]
fn gitlab_com_is_asked_without_a_gitlab_remote() {
    let stub = HttpStub::start(|req, base| match req.path() {
        GITLAB => Reply::json(&format!(
            r#"{{"avatar_url": "{base}/gitlab/uploads/-/system/user/avatar/7/me.png"}}"#
        )),
        "/gitlab/uploads/-/system/user/avatar/7/me.png" => Reply::png(PNG),
        _ => Reply::status(404),
    });
    let sources = sources(&stub, None);
    assert_eq!(
        lookup(&sources, &request("me@example.com")),
        found(Source::Gitlab, PNG, ImageFormat::Png)
    );
    assert_eq!(
        stub.requests()[0].target,
        format!("{GITLAB}?email=me%40example.com&size=80")
    );
    // A gitlab.com remote is not asked twice.
    let mut on_gitlab_com = request("other@example.com");
    on_gitlab_com.hosts.gitlab = vec![format!("{}/gitlab/", stub.base())];
    assert_eq!(
        lookup(&sources, &on_gitlab_com),
        found(Source::Gitlab, PNG, ImageFormat::Png)
    );
    let asked = stub.paths().iter().filter(|p| *p == GITLAB).count();
    assert_eq!(asked, 2, "{:?}", stub.paths());
}

#[test]
fn providers_turned_off_are_not_asked() {
    let stub = HttpStub::start(|_, _| Reply::status(404));
    let sources = sources(&stub, None);
    let mut only_libravatar = on_github("dev@example.com", "abc123");
    only_libravatar.providers = Providers::NONE.with(Provider::Libravatar, true);
    assert_eq!(lookup(&sources, &only_libravatar), Lookup::Missing);
    let hash = email_hash("dev@example.com");
    assert_eq!(stub.paths(), vec![format!("/libravatar/{hash}")]);

    let mut github_only = request("123+octo@users.noreply.github.com");
    github_only.providers = Providers::NONE.with(Provider::Gravatar, true);
    assert_eq!(lookup(&sources, &github_only), Lookup::Missing);
    assert!(
        stub.paths()[1].starts_with("/gravatar/"),
        "GitHub off skips the noreply address: {:?}",
        stub.paths()
    );

    // With every provider off nothing is asked, and that is no sign of
    // being offline.
    let mut none = request("dev@example.com");
    none.providers = Providers::NONE;
    assert_eq!(lookup(&sources, &none), Lookup::Missing);
    assert_eq!(stub.paths().len(), 2);
    assert_eq!(
        lookup(&sources, &request("dev@example.com")),
        Lookup::Missing
    );
    assert_eq!(stub.paths().len(), 6);
}

#[test]
fn gravatar_then_libravatar_by_hash() {
    let hash = email_hash("Dev@Example.com ");
    let libravatar = format!("/libravatar/{hash}");
    let stub = HttpStub::start(move |req, _| {
        if req.path() == libravatar {
            Reply::png(PNG)
        } else {
            Reply::status(404)
        }
    });
    let sources = sources(&stub, None);
    let result = lookup(&sources, &request(" dev@example.COM"));
    assert_eq!(result, found(Source::Libravatar, PNG, ImageFormat::Png));
    let requests = stub.requests();
    assert_eq!(requests[0].path(), GITLAB);
    assert_eq!(requests[1].target, format!("/gravatar/{hash}?s=80&d=404"));
    assert_eq!(requests[2].target, format!("/libravatar/{hash}?s=80&d=404"));
}

#[test]
fn an_answer_that_is_not_a_picture_is_a_miss() {
    let stub = HttpStub::start(|_, _| Reply {
        status: 200,
        content_type: "text/html",
        body: b"<html>default picture page</html>".to_vec(),
    });
    let sources = sources(&stub, None);
    assert_eq!(
        lookup(&sources, &request("dev@example.com")),
        Lookup::Missing
    );
}

#[test]
fn a_server_error_is_asked_again_later() {
    let stub = HttpStub::start(|req, _| {
        if req.path().starts_with("/gravatar/") {
            Reply::status(503)
        } else {
            Reply::status(404)
        }
    });
    let sources = sources(&stub, None);
    assert_eq!(
        lookup(&sources, &request("dev@example.com")),
        Lookup::Unavailable
    );
}

#[test]
fn without_an_answer_lookups_wait_a_while() {
    // A server that hangs up without answering. (A port nothing listens on
    // fails the same way, but Windows retries a refused connection for
    // about two seconds, once per source.)
    let listener = TcpListener::bind("127.0.0.1:0").expect("free port");
    let port = listener.local_addr().expect("port").port();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            drop(stream);
        }
    });
    let sources = AvatarSources::new(
        Some(curl()),
        Endpoints::under(&format!("http://127.0.0.1:{port}")),
    )
    .with_github_token(None);
    assert_eq!(
        lookup(&sources, &request("dev@example.com")),
        Lookup::Unavailable
    );

    // Meanwhile nothing is asked, even of a source that would answer.
    let stub = HttpStub::start(|_, _| Reply::png(PNG));
    let mut next = request("other@example.com");
    next.hosts.gitlab = vec![stub.base().to_string()];
    assert_eq!(lookup(&sources, &next), Lookup::Unavailable);
    assert!(stub.paths().is_empty());
}

#[test]
fn a_cancelled_lookup_stops() {
    let stub = HttpStub::start(|_, _| Reply::status(404));
    let sources = sources(&stub, None);
    let cancel = CancelToken::new();
    cancel.cancel();
    assert_eq!(
        sources.lookup(&request("dev@example.com"), &cancel),
        Lookup::Unavailable
    );
    assert!(stub.paths().is_empty());
}

mod runtime {
    use std::fs::File;
    use std::time::{Duration, Instant, SystemTime};

    use gitbello_core::avatars::{
        email_hash, AvatarCache, AvatarRequest, AvatarSources, Endpoints, ImageFormat, Provider,
        Providers,
    };
    use gitbello_core::backend::{CliBackend, GitBackend};
    use gitbello_core::git::CancelToken;
    use gitbello_core::runtime::{Runtime, RuntimeEvent};

    use super::support::http_stub::{HttpStub, Reply};
    use super::support::{rt, TempDir, TestRepo};
    use super::{curl, github_hosts, GITLAB, JPEG, PNG, SEARCH};

    /// The fixture's identity (author and committer of `TestRepo::commit`).
    const ADA: &str = "ada@example.com";

    fn changed(events: &[RuntimeEvent], email: &str) -> usize {
        events
            .iter()
            .filter(|e| matches!(e, RuntimeEvent::AvatarChanged { email: e } if e == email))
            .count()
    }

    fn use_stub(rt: &mut Runtime, stub: &HttpStub, cache: &TempDir) {
        let sources =
            AvatarSources::new(Some(curl()), Endpoints::under(stub.base())).with_github_token(None);
        rt.set_avatar_sources(sources, Some(cache.path().to_path_buf()));
    }

    /// Polls for a while, for things that must not happen.
    fn idle(rt: &mut Runtime) -> Vec<RuntimeEvent> {
        let until = Instant::now() + Duration::from_millis(400);
        rt::poll_until(rt, |_, _| Instant::now() > until)
    }

    /// A repository whose `origin` is on github.com and has its one commit.
    fn github_repo() -> TestRepo {
        let repo = TestRepo::init();
        repo.commit("a.txt", "a", "first");
        repo.git(&[
            "remote",
            "add",
            "origin",
            "https://github.com/owner/repo.git",
        ]);
        repo.git(&["update-ref", "refs/remotes/origin/main", "HEAD"]);
        repo
    }

    /// A stub whose commit API knows `oid`, authored by `email`.
    fn api_stub(oid: &str, email: &'static str) -> HttpStub {
        let api = format!("/github-api/repos/owner/repo/commits/{oid}");
        HttpStub::start(move |req, base| {
            if req.path() == api {
                super::commit_json(base, email)
            } else if req.path() == "/pictures/octo" {
                Reply::png(PNG)
            } else {
                Reply::status(404)
            }
        })
    }

    fn published_commit(repo: &TestRepo, remote: &str, email: &str) -> Option<String> {
        CliBackend::new(repo.runner().clone())
            .published_commit_by(repo.path(), remote, email, &CancelToken::new())
            .expect("git log")
    }

    #[test]
    fn a_person_s_published_commit_is_found_as_author_or_committer() {
        let repo = github_repo();
        let first = repo.head();
        assert_eq!(
            published_commit(&repo, "origin", " ADA@example.com"),
            Some(first.clone())
        );
        // Newer, but not on the remote.
        repo.commit("b.txt", "b", "local");
        assert_eq!(published_commit(&repo, "origin", ADA), Some(first));
        // Bob authored it and Cy committed it, both pushed.
        repo.command()
            .env("GIT_COMMITTER_NAME", "Cy")
            .env("GIT_COMMITTER_EMAIL", "cy@example.com")
            .args(["commit", "--allow-empty", "--quiet", "-m", "by bob"])
            .arg("--author=Bob <bob@example.com>")
            .run()
            .expect("commit as bob");
        let bobs = repo.head();
        repo.git(&["update-ref", "refs/remotes/origin/main", "HEAD"]);
        assert_eq!(
            published_commit(&repo, "origin", "bob@example.com"),
            Some(bobs.clone())
        );
        assert_eq!(
            published_commit(&repo, "origin", "cy@example.com"),
            Some(bobs),
            "as the committer"
        );
        assert_eq!(
            published_commit(&repo, "origin", ADA),
            Some(repo.git(&["rev-parse", "HEAD~1"])),
            "as an author before as a committer"
        );
        // A shorter address inside a longer one is someone else.
        assert_eq!(published_commit(&repo, "origin", "ob@example.com"), None);
        assert_eq!(
            published_commit(&repo, "origin", "nobody@example.com"),
            None
        );
        assert_eq!(
            published_commit(&repo, "upstream", ADA),
            None,
            "a remote without branches has no commits"
        );
        assert_eq!(published_commit(&repo, "--all", ADA), None);

        let mut request = AvatarRequest {
            email: ADA.into(),
            repo: Some(repo.path().to_path_buf()),
            hosts: github_hosts(),
            ..AvatarRequest::default()
        };
        request.find_commit(&CliBackend::new(repo.runner().clone()), &CancelToken::new());
        assert!(request.commit.is_some());
    }

    #[test]
    fn a_picture_is_looked_up_once_and_then_read_from_the_cache() {
        let repo = github_repo();
        let pushed = repo.head();
        // The newest commit is not on GitHub: the pushed one is asked.
        repo.commit("b.txt", "b", "local");
        let stub = api_stub(&pushed, ADA);
        let cache = TempDir::new("avatar cache ü");
        let (mut rt, key) = rt::open(&repo);
        use_stub(&mut rt, &stub, &cache);

        rt.request_avatar(Some(&key), " Ada@Example.com");
        rt::poll_until(&mut rt, |_, ev| changed(ev, ADA) == 1);
        let picture = rt.avatar(ADA).expect("picture");
        assert_eq!((&*picture.bytes, picture.format), (PNG, ImageFormat::Png));
        assert_eq!(
            stub.paths(),
            vec![
                format!("/github-api/repos/owner/repo/commits/{pushed}"),
                "/pictures/octo".to_string()
            ]
        );

        // Asked again: nothing new.
        rt.request_avatar(Some(&key), ADA);
        idle(&mut rt);
        assert_eq!(stub.paths().len(), 2);

        // A new start reads it from the cache.
        use_stub(&mut rt, &stub, &cache);
        rt.request_avatar(None, ADA);
        rt::poll_until(&mut rt, |_, ev| changed(ev, ADA) == 1);
        assert_eq!(&*rt.avatar(ADA).expect("cached").bytes, PNG);
        assert_eq!(stub.paths().len(), 2);
    }

    #[test]
    fn a_miss_without_github_is_looked_up_again_from_a_repository_on_github() {
        let plain = TestRepo::init();
        plain.commit("a.txt", "a", "first");
        let on_github = github_repo();
        let stub = api_stub(&on_github.head(), ADA);
        let cache = TempDir::new("avatar github misses");
        let (mut rt, plain_key) = rt::open(&plain);
        let github_key = rt.open(on_github.path());
        rt::poll_until(&mut rt, |rt, _| {
            rt.repo(&github_key)
                .is_some_and(|s| !s.remote_list().is_empty())
        });
        use_stub(&mut rt, &stub, &cache);

        rt.request_avatar(Some(&plain_key), ADA);
        rt::poll_until(&mut rt, |_, _| stub.paths().len() == 4);
        idle(&mut rt);
        assert!(rt.avatar(ADA).is_none());
        assert_eq!(stub.paths()[3], SEARCH);

        rt.request_avatar(Some(&github_key), ADA);
        rt::poll_until(&mut rt, |_, ev| changed(ev, ADA) == 1);
        assert_eq!(stub.paths().len(), 6, "{:?}", stub.paths());

        // A miss asked of GitHub stays a miss, from any repository.
        let other = "nobody@example.com";
        rt.request_avatar(Some(&github_key), other);
        rt::poll_until(&mut rt, |_, _| stub.paths().len() == 10);
        idle(&mut rt);
        rt.request_avatar(Some(&github_key), other);
        rt.request_avatar(Some(&plain_key), other);
        idle(&mut rt);
        assert_eq!(stub.paths().len(), 10, "{:?}", stub.paths());

        // So does the cached one, after a restart.
        use_stub(&mut rt, &stub, &cache);
        rt.request_avatar(Some(&github_key), other);
        idle(&mut rt);
        assert_eq!(stub.paths().len(), 10);
    }

    #[test]
    fn a_miss_is_cached_and_initials_stay() {
        let repo = TestRepo::init();
        repo.commit("a.txt", "a", "first");
        let stub = HttpStub::start(|_, _| Reply::status(404));
        let cache = TempDir::new("avatar misses");
        let (mut rt, key) = rt::open(&repo);
        use_stub(&mut rt, &stub, &cache);

        rt.request_avatar(Some(&key), "nobody@example.com");
        rt::poll_until(&mut rt, |_, _| stub.paths().len() == 4);
        let events = idle(&mut rt);
        assert_eq!(changed(&events, "nobody@example.com"), 0);
        assert!(rt.avatar("nobody@example.com").is_none());

        use_stub(&mut rt, &stub, &cache);
        rt.request_avatar(Some(&key), "nobody@example.com");
        idle(&mut rt);
        assert_eq!(stub.paths().len(), 4, "the miss was read from the cache");
    }

    #[test]
    fn an_old_picture_shows_until_its_refresh_arrives() {
        let repo = TestRepo::init();
        repo.commit("a.txt", "a", "first");
        let stub = HttpStub::start(|req, _| {
            if req.path().starts_with("/gravatar/") {
                Reply::png(JPEG)
            } else {
                Reply::status(404)
            }
        });
        let cache = TempDir::new("avatar refresh");
        let key_file = email_hash("old@example.com");
        AvatarCache::new(cache.path())
            .store_picture(&key_file, PNG, ImageFormat::Png, Provider::Gravatar)
            .expect("seed the cache");
        File::options()
            .write(true)
            .open(cache.path().join(format!("{key_file}.gravatar.png")))
            .and_then(|f| f.set_modified(SystemTime::now() - Duration::from_secs(40 * 86_400)))
            .expect("age the picture");
        let (mut rt, key) = rt::open(&repo);
        use_stub(&mut rt, &stub, &cache);

        rt.request_avatar(Some(&key), "old@example.com");
        let events = rt::poll_until(&mut rt, |_, ev| changed(ev, "old@example.com") == 2);
        assert!(events
            .iter()
            .any(|e| matches!(e, RuntimeEvent::AvatarChanged { .. })));
        assert_eq!(
            &*rt.avatar("old@example.com").expect("refreshed").bytes,
            JPEG
        );
        assert!(cache
            .path()
            .join(format!("{key_file}.gravatar.jpg"))
            .is_file());
        assert!(!cache
            .path()
            .join(format!("{key_file}.gravatar.png"))
            .exists());
    }

    #[test]
    fn turning_a_provider_off_hides_its_pictures_and_on_asks_it_again() {
        let repo = TestRepo::init();
        repo.commit("a.txt", "a", "first");
        let stub = HttpStub::start(|req, _| {
            if req.path().starts_with("/gravatar/") {
                Reply::png(JPEG)
            } else {
                Reply::status(404)
            }
        });
        let cache = TempDir::new("avatar providers");
        AvatarCache::new(cache.path())
            .store_picture(&email_hash(ADA), PNG, ImageFormat::Png, Provider::Gravatar)
            .expect("seed the cache");
        let (mut rt, key) = rt::open(&repo);
        use_stub(&mut rt, &stub, &cache);

        rt.request_avatar(Some(&key), ADA);
        rt::poll_until(&mut rt, |_, ev| changed(ev, ADA) == 1);
        assert!(stub.paths().is_empty(), "read from the cache");

        // Off: the cached picture is not shown and Gravatar is not asked.
        rt.set_avatar_providers(Providers::ALL.with(Provider::Gravatar, false));
        rt.request_avatar(Some(&key), ADA);
        rt::poll_until(&mut rt, |_, _| stub.paths().len() == 3);
        let events = idle(&mut rt);
        assert_eq!(changed(&events, ADA), 0);
        assert!(rt.avatar(ADA).is_none());
        assert!(stub.paths().iter().all(|p| !p.starts_with("/gravatar/")));
        assert_eq!(stub.paths()[0], GITLAB);

        // On again: that miss did not ask Gravatar, so it is asked now.
        rt.set_avatar_providers(Providers::ALL);
        rt.request_avatar(Some(&key), ADA);
        rt::poll_until(&mut rt, |_, ev| changed(ev, ADA) == 1);
        assert_eq!(&*rt.avatar(ADA).expect("found").bytes, JPEG);
        assert!(stub.paths()[3..]
            .iter()
            .any(|p| p.starts_with("/gravatar/")));

        // Every provider off: nothing is asked.
        rt.set_avatar_providers(Providers::NONE);
        let before = stub.paths().len();
        rt.request_avatar(Some(&key), "new@example.com");
        idle(&mut rt);
        assert_eq!(stub.paths().len(), before);
    }

    #[test]
    fn nothing_is_looked_up_while_pictures_are_off() {
        let repo = TestRepo::init();
        repo.commit("a.txt", "a", "first");
        let stub = HttpStub::start(|_, _| Reply::png(PNG));
        let cache = TempDir::new("avatars off");
        let (mut rt, key) = rt::open(&repo);
        use_stub(&mut rt, &stub, &cache);
        rt.set_avatars_enabled(false);

        rt.request_avatar(Some(&key), "dev@example.com");
        rt.request_avatar(Some(&key), "not an email");
        idle(&mut rt);
        assert!(stub.paths().is_empty());
        assert!(rt.avatar("dev@example.com").is_none());

        rt.set_avatars_enabled(true);
        rt.request_avatar(Some(&key), "dev@example.com");
        rt::poll_until(&mut rt, |_, ev| changed(ev, "dev@example.com") == 1);
    }
}
