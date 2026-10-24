//! Line and hunk staging, unstaging and discarding (M4b acceptance), applied
//! with real `git apply` on temporary repositories.

mod support;

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use gitbello_core::backend::{CliBackend, GitBackend, PatchGuard};
use gitbello_core::config::Config;
use gitbello_core::diff::{build_patch, DiffKind, DiffTarget, FileDiff, LineKind, PatchMode};
use gitbello_core::git::{CancelToken, GitErrorKind};
use gitbello_core::runtime::{JobState, Runtime, RuntimeEvent};
use support::TestRepo;

const WAIT: Duration = Duration::from_secs(10);

fn backend(repo: &TestRepo) -> CliBackend {
    CliBackend::new(repo.app_runner())
}

fn diff_of(repo: &TestRepo, kind: DiffKind, path: &str) -> FileDiff {
    let target = DiffTarget {
        kind,
        path: PathBuf::from(path),
        original_path: None,
        commit: None,
    };
    backend(repo)
        .diff(repo.path(), &target, None, &CancelToken::new())
        .expect("diff")
}

/// Index of the first line of `kind` whose text is `text`.
fn line(diff: &FileDiff, kind: LineKind, text: &str) -> usize {
    (0..diff.line_count())
        .find(|&i| {
            let l = diff.line(i).expect("line");
            l.kind == kind && l.text == text.as_bytes()
        })
        .unwrap_or_else(|| panic!("no {kind:?} line {text:?}"))
}

fn apply(repo: &TestRepo, path: &str, lines: &[usize], mode: PatchMode) {
    let kind = if mode == PatchMode::Unstage {
        DiffKind::Staged
    } else {
        DiffKind::Unstaged
    };
    let diff = diff_of(repo, kind, path);
    let patch = build_patch(&diff, path, lines, mode).expect("a change is selected");
    let guard = PatchGuard {
        path: PathBuf::from(path),
        ..PatchGuard::default()
    };
    if let Err(err) =
        backend(repo).apply_patch(repo.path(), &patch, mode, &guard, &CancelToken::new())
    {
        panic!("{err}\npatch:\n{}", String::from_utf8_lossy(&patch));
    }
}

fn index(repo: &TestRepo, path: &str) -> Vec<u8> {
    repo.try_git(&["show", &format!(":{path}")])
        .expect("index blob")
        .stdout
}

fn worktree(repo: &TestRepo, path: &str) -> Vec<u8> {
    fs::read(repo.path().join(path)).expect("read worktree file")
}

#[test]
fn stage_middle_first_and_last_lines() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "one\ntwo\nthree\nfour\nfive\n", "base");
    repo.write("f.txt", "ONE\ntwo\nthree\nfour\nFIVE\nsix\n");

    // First line only: the change of line 1.
    let d = diff_of(&repo, DiffKind::Unstaged, "f.txt");
    apply(
        &repo,
        "f.txt",
        &[
            line(&d, LineKind::Removed, "one"),
            line(&d, LineKind::Added, "ONE"),
        ],
        PatchMode::Stage,
    );
    assert_eq!(index(&repo, "f.txt"), b"ONE\ntwo\nthree\nfour\nfive\n");

    // Last line only: the added `six`.
    let d = diff_of(&repo, DiffKind::Unstaged, "f.txt");
    apply(
        &repo,
        "f.txt",
        &[line(&d, LineKind::Added, "six")],
        PatchMode::Stage,
    );
    assert_eq!(index(&repo, "f.txt"), b"ONE\ntwo\nthree\nfour\nfive\nsix\n");

    // The rest: the index now matches the working tree.
    let d = diff_of(&repo, DiffKind::Unstaged, "f.txt");
    apply(&repo, "f.txt", &[d.hunks[0].line], PatchMode::Stage);
    assert_eq!(index(&repo, "f.txt"), worktree(&repo, "f.txt"));
}

#[test]
fn unstage_and_discard_single_lines() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "a\nb\nc\n", "base");
    repo.write("f.txt", "a\nB\nc\nd\n");
    repo.git(&["add", "f.txt"]);

    let d = diff_of(&repo, DiffKind::Staged, "f.txt");
    apply(
        &repo,
        "f.txt",
        &[line(&d, LineKind::Added, "d")],
        PatchMode::Unstage,
    );
    assert_eq!(index(&repo, "f.txt"), b"a\nB\nc\n");
    assert_eq!(worktree(&repo, "f.txt"), b"a\nB\nc\nd\n");

    let d = diff_of(&repo, DiffKind::Unstaged, "f.txt");
    apply(
        &repo,
        "f.txt",
        &[line(&d, LineKind::Added, "d")],
        PatchMode::Discard,
    );
    assert_eq!(worktree(&repo, "f.txt"), b"a\nB\nc\n");
    assert_eq!(index(&repo, "f.txt"), b"a\nB\nc\n");
}

#[test]
fn files_without_a_final_newline() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "x\na", "base");
    repo.write("f.txt", "x\na\nb");

    // Only `b`: `a` gets its newline in the index so `b` can follow it.
    let d = diff_of(&repo, DiffKind::Unstaged, "f.txt");
    apply(
        &repo,
        "f.txt",
        &[line(&d, LineKind::Added, "b")],
        PatchMode::Stage,
    );
    assert_eq!(index(&repo, "f.txt"), b"x\na\nb");

    // Back out `b` from the index alone: `a` keeps its newline.
    let d = diff_of(&repo, DiffKind::Staged, "f.txt");
    apply(
        &repo,
        "f.txt",
        &[line(&d, LineKind::Added, "b")],
        PatchMode::Unstage,
    );
    assert_eq!(index(&repo, "f.txt"), b"x\na\n");

    // Discard the remaining `+b` in the working tree.
    let d = diff_of(&repo, DiffKind::Unstaged, "f.txt");
    apply(
        &repo,
        "f.txt",
        &[line(&d, LineKind::Added, "b")],
        PatchMode::Discard,
    );
    assert_eq!(worktree(&repo, "f.txt"), b"x\na\n");

    // A newline added at the end on its own.
    repo.commit("g.txt", "only", "no newline");
    repo.write("g.txt", "only\n");
    let d = diff_of(&repo, DiffKind::Unstaged, "g.txt");
    apply(&repo, "g.txt", &[d.hunks[0].line], PatchMode::Stage);
    assert_eq!(index(&repo, "g.txt"), b"only\n");
}

#[test]
fn crlf_files_keep_their_line_endings() {
    let repo = TestRepo::init();
    repo.commit("w.txt", "one\r\ntwo\r\nthree\r\n", "crlf");
    repo.write("w.txt", "one\r\nTWO\r\nthree\r\nfour\r\n");
    let d = diff_of(&repo, DiffKind::Unstaged, "w.txt");
    apply(
        &repo,
        "w.txt",
        &[line(&d, LineKind::Added, "four\r")],
        PatchMode::Stage,
    );
    assert_eq!(index(&repo, "w.txt"), b"one\r\ntwo\r\nthree\r\nfour\r\n");
    let d = diff_of(&repo, DiffKind::Unstaged, "w.txt");
    apply(
        &repo,
        "w.txt",
        &[line(&d, LineKind::Added, "TWO\r")],
        PatchMode::Discard,
    );
    assert_eq!(worktree(&repo, "w.txt"), b"one\r\nthree\r\nfour\r\n");
}

#[test]
fn second_hunk_alone_and_odd_paths() {
    let repo = TestRepo::init();
    let base: String = (1..=30).map(|i| format!("{i}\n")).collect();
    repo.commit("dir/spaced ünï.txt", &base, "base");
    // Line 3 changed (first hunk) and line 27 changed (second hunk).
    let rewrite = |with_three: bool| -> String {
        (1..=30)
            .map(|i| match i {
                3 if with_three => "three\n".to_owned(),
                27 => "twenty-seven\n".to_owned(),
                i => format!("{i}\n"),
            })
            .collect()
    };
    let changed = rewrite(true);
    repo.write("dir/spaced ünï.txt", &changed);
    let path = "dir/spaced ünï.txt";
    let d = diff_of(&repo, DiffKind::Unstaged, path);
    assert_eq!(d.hunks.len(), 2);
    apply(&repo, path, &[d.hunks[1].line], PatchMode::Stage);
    assert_eq!(index(&repo, path), rewrite(false).as_bytes());
}

#[test]
fn stale_diffs_are_refused() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "a\nb\n", "base");
    repo.write("f.txt", "a\nb\nc\n");
    let d = diff_of(&repo, DiffKind::Unstaged, "f.txt");
    let patch = build_patch(
        &d,
        "f.txt",
        &[line(&d, LineKind::Added, "c")],
        PatchMode::Stage,
    )
    .expect("patch");
    let guard = PatchGuard {
        path: PathBuf::from("f.txt"),
        index_oid: d.header.old_oid.clone(),
        worktree_oid: None,
    };
    // Someone else stages a different version meanwhile.
    fs::write(repo.path().join("f.txt"), "a\nX\n").expect("write");
    repo.git(&["add", "f.txt"]);
    let err = backend(&repo)
        .apply_patch(
            repo.path(),
            &patch,
            PatchMode::Stage,
            &guard,
            &CancelToken::new(),
        )
        .expect_err("stale");
    assert_eq!(err.kind, GitErrorKind::Stale);
    assert_eq!(index(&repo, "f.txt"), b"a\nX\n");
}

/// Tiny deterministic generator (no extra crates).
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

/// What the index should hold after staging `selected` lines of `diff`
/// over `old` (every line ends in a newline here).
fn expected_stage(old: &[u8], diff: &FileDiff, selected: &[usize]) -> Vec<u8> {
    let old_lines: Vec<&[u8]> = old.split_inclusive(|&b| b == b'\n').collect();
    let mut out = Vec::new();
    let mut next_old = 1usize;
    for (h, hunk) in diff.hunks.iter().enumerate() {
        let start = if hunk.old_count == 0 {
            hunk.old_start as usize + 1
        } else {
            hunk.old_start as usize
        };
        while next_old < start {
            out.extend_from_slice(old_lines[next_old - 1]);
            next_old += 1;
        }
        let end = diff.hunks.get(h + 1).map_or(diff.line_count(), |n| n.line);
        for i in hunk.line + 1..end {
            let l = diff.line(i).expect("line");
            let picked = selected.contains(&i);
            match l.kind {
                LineKind::Context => {
                    out.extend_from_slice(old_lines[next_old - 1]);
                    next_old += 1;
                }
                LineKind::Removed => {
                    if !picked {
                        out.extend_from_slice(old_lines[next_old - 1]);
                    }
                    next_old += 1;
                }
                LineKind::Added => {
                    if picked {
                        out.extend_from_slice(l.text);
                        out.push(b'\n');
                    }
                }
                LineKind::Hunk => {}
            }
        }
    }
    while next_old <= old_lines.len() {
        out.extend_from_slice(old_lines[next_old - 1]);
        next_old += 1;
    }
    out
}

#[test]
fn random_selections_stage_exactly_what_was_picked() {
    let repo = TestRepo::init();
    let mut rng = Lcg(0x5eed);
    for round in 0..30 {
        let count = 5 + rng.below(40) as usize;
        let base: Vec<String> = (0..count).map(|i| format!("line {round}.{i}")).collect();
        let old: String = base.iter().map(|l| format!("{l}\n")).collect();
        repo.commit("r.txt", &old, &format!("round {round}"));
        let mut new_lines = Vec::new();
        for (i, l) in base.iter().enumerate() {
            match rng.below(6) {
                0 => {}
                1 => new_lines.push(format!("{l} changed")),
                2 => {
                    new_lines.push(l.clone());
                    new_lines.push(format!("inserted after {i}"));
                }
                _ => new_lines.push(l.clone()),
            }
        }
        if rng.below(2) == 0 {
            new_lines.insert(0, "new first".into());
        }
        let new: String = new_lines.iter().map(|l| format!("{l}\n")).collect();
        if new == old {
            continue;
        }
        repo.write("r.txt", &new);

        let diff = diff_of(&repo, DiffKind::Unstaged, "r.txt");
        let changes: Vec<usize> = (0..diff.line_count())
            .filter(|&i| {
                let k = diff.line(i).expect("line").kind;
                k == LineKind::Added || k == LineKind::Removed
            })
            .collect();
        let selected: Vec<usize> = changes
            .iter()
            .copied()
            .filter(|_| rng.below(2) == 0)
            .collect();
        if selected.is_empty() {
            continue;
        }
        apply(&repo, "r.txt", &selected, PatchMode::Stage);
        let expected = expected_stage(old.as_bytes(), &diff, &selected);
        assert_eq!(
            String::from_utf8_lossy(&index(&repo, "r.txt")),
            String::from_utf8_lossy(&expected),
            "round {round}, selected {selected:?}"
        );

        // Unstaging everything staged brings the index back to HEAD.
        let staged = diff_of(&repo, DiffKind::Staged, "r.txt");
        if !staged.hunks.is_empty() {
            let all: Vec<usize> = staged.hunks.iter().map(|h| h.line).collect();
            apply(&repo, "r.txt", &all, PatchMode::Unstage);
        }
        assert_eq!(
            index(&repo, "r.txt"),
            old.as_bytes(),
            "round {round} unstage"
        );
        repo.git(&["checkout", "--", "r.txt"]);
    }
}

fn poll_until(rt: &mut Runtime, mut done: impl FnMut(&Runtime, &[RuntimeEvent]) -> bool) {
    let deadline = Instant::now() + WAIT;
    let mut seen = Vec::new();
    loop {
        seen.extend(rt.poll());
        if done(rt, &seen) {
            return;
        }
        assert!(Instant::now() < deadline, "timed out; events: {seen:#?}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn finished(events: &[RuntimeEvent], job: u64) -> bool {
    events.iter().any(|e| {
        matches!(e, RuntimeEvent::Job { job: j, state: JobState::Finished(None), .. } if *j == job)
    })
}

fn loaded_diff(rt: &Runtime, key: &Path) -> Option<FileDiff> {
    let state = rt.repo(key)?.diff()?;
    (!state.is_loading())
        .then(|| state.diff().cloned())
        .flatten()
}

#[test]
fn runtime_line_staging_discard_and_undo() {
    let repo = TestRepo::init();
    repo.commit("f.txt", "a\nb\nc\n", "base");
    repo.write("f.txt", "a\nB\nc\nd\n");
    let mut rt = Runtime::with_runner(Config::default(), None, repo.app_runner());
    let key = rt.open(repo.path());
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key).is_some_and(|s| s.status().is_some())
    });
    let target = |kind| DiffTarget {
        kind,
        path: PathBuf::from("f.txt"),
        original_path: None,
        commit: None,
    };
    rt.select_diff(&key, Some(target(DiffKind::Unstaged)), false);
    poll_until(&mut rt, |rt, _| loaded_diff(rt, &key).is_some());
    let state = rt.repo(&key).expect("state");
    assert!(state.can_apply_lines(PatchMode::Stage));
    assert!(!state.can_apply_lines(PatchMode::Unstage));

    let diff = loaded_diff(&rt, &key).expect("diff");
    let job = rt
        .apply_lines(&key, &[line(&diff, LineKind::Added, "d")], PatchMode::Stage)
        .expect("job");
    poll_until(&mut rt, |_, ev| finished(ev, job));
    assert_eq!(index(&repo, "f.txt"), b"a\nb\nc\nd\n");

    // The diff reloads after the status refresh; discard `B` from it.
    poll_until(&mut rt, |rt, _| {
        loaded_diff(rt, &key).is_some_and(|d| d.additions == 1)
    });
    let diff = loaded_diff(&rt, &key).expect("diff");
    let job = rt
        .apply_lines(
            &key,
            &[
                line(&diff, LineKind::Removed, "b"),
                line(&diff, LineKind::Added, "B"),
            ],
            PatchMode::Discard,
        )
        .expect("job");
    poll_until(&mut rt, |rt, ev| {
        finished(ev, job) && rt.repo(&key).is_some_and(|s| s.can_undo_discard())
    });
    assert_eq!(worktree(&repo, "f.txt"), b"a\nb\nc\nd\n");

    let job = rt.undo_discard(&key).expect("undo job");
    poll_until(&mut rt, |_, ev| finished(ev, job));
    assert_eq!(worktree(&repo, "f.txt"), b"a\nB\nc\nd\n");

    // Whole-file discard, then undo.
    let job = rt
        .discard_files(&key, vec![PathBuf::from("f.txt")])
        .expect("job");
    poll_until(&mut rt, |_, ev| finished(ev, job));
    assert_eq!(worktree(&repo, "f.txt"), b"a\nb\nc\nd\n");
    let job = rt.undo_discard(&key).expect("undo job");
    poll_until(&mut rt, |_, ev| finished(ev, job));
    assert_eq!(worktree(&repo, "f.txt"), b"a\nB\nc\nd\n");
    assert!(!rt.repo(&key).expect("state").can_undo_discard());
}
