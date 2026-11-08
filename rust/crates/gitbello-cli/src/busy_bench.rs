//! `busy-bench <source repo> --work <empty dir>`: how long the runtime takes
//! to show changes, diffs and history while files keep changing, as on a
//! busy machine. It clones the source into `<work>` (the source is only
//! read) and changes only that clone. Run it under CPU load (see
//! `tools/cpu_burn.ps1`) to see what a slow machine sees.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use gitbello_core::config::Config;
use gitbello_core::graph::{to_hex, HistoryScope, LoadState};
use gitbello_core::runtime::{Runtime, RuntimeEvent};

use crate::fixture::Git;

const POLL: Duration = Duration::from_millis(5);
const TIMEOUT: Duration = Duration::from_secs(600);

struct Bench {
    rt: Runtime,
    /// Longest single `poll` (what a frame spends in core).
    max_poll: Duration,
    graph_resets: usize,
}

impl Bench {
    fn poll(&mut self) -> Vec<RuntimeEvent> {
        let started = Instant::now();
        let events = self.rt.poll();
        self.max_poll = self.max_poll.max(started.elapsed());
        self.graph_resets += events
            .iter()
            .filter(|e| matches!(e, RuntimeEvent::GraphReset { .. }))
            .count();
        events
    }

    /// Polls until `done` holds; returns how long that took.
    fn until(&mut self, what: &str, mut done: impl FnMut(&Runtime) -> bool) -> Result<Duration> {
        let started = Instant::now();
        loop {
            self.poll();
            if done(&self.rt) {
                return Ok(started.elapsed());
            }
            if started.elapsed() > TIMEOUT {
                bail!("timed out waiting for {what}");
            }
            thread::sleep(POLL);
        }
    }
}

fn graph_done(rt: &Runtime, key: &Path) -> bool {
    rt.repo(key)
        .and_then(|s| s.graph())
        .is_some_and(|g| g.progress().state == LoadState::Done)
}

fn graph_top(rt: &Runtime, key: &Path) -> Option<String> {
    let graph = rt.repo(key)?.graph()?;
    if graph.progress().state != LoadState::Done {
        return None;
    }
    let index = graph.index();
    index.commit(0).map(|c| to_hex(c.hash))
}

fn diff_shows(rt: &Runtime, key: &Path, path: &Path, marker: Option<&str>) -> bool {
    let Some(diff) = rt.repo(key).and_then(|s| s.diff()) else {
        return false;
    };
    if diff.target().path != path || diff.is_loading() {
        return false;
    }
    let Some(file) = diff.diff() else {
        return false;
    };
    match marker {
        None => true,
        Some(marker) => (0..file.line_count())
            .filter_map(|i| file.line(i))
            .any(|line| line.text == marker.as_bytes()),
    }
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1e3
}

fn summary(name: &str, times: &[Duration]) {
    let mut sorted = times.to_vec();
    sorted.sort();
    let median = sorted.get(sorted.len() / 2).copied().unwrap_or_default();
    let max = sorted.last().copied().unwrap_or_default();
    println!(
        "{name:<28} median {:>8.0} ms   max {:>8.0} ms   ({} runs)",
        ms(median),
        ms(max),
        times.len()
    );
}

fn append(path: &Path, line: &str) -> Result<()> {
    use std::io::Write;
    let mut file = fs::OpenOptions::new().append(true).open(path)?;
    writeln!(file, "{line}")?;
    Ok(())
}

pub fn run(args: &[String]) -> Result<()> {
    let mut source: Option<PathBuf> = None;
    let mut work: Option<PathBuf> = None;
    let mut worktrees = 2usize;
    let mut rounds = 4usize;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--work" => work = Some(PathBuf::from(iter.next().context("--work needs a folder")?)),
            "--worktrees" => {
                worktrees = iter.next().context("--worktrees needs a number")?.parse()?
            }
            "--rounds" => rounds = iter.next().context("--rounds needs a number")?.parse()?,
            other if source.is_none() => source = Some(PathBuf::from(other)),
            other => bail!("unexpected argument `{other}`"),
        }
    }
    let source = source.context("busy-bench needs a source repository")?;
    let work = work.context("busy-bench needs --work <empty folder>")?;
    fs::create_dir_all(&work)?;
    if fs::read_dir(&work)?.next().is_some() {
        bail!("{} is not empty", work.display());
    }

    let runner = crate::repo_cmds::runner()?;
    let global_config = work.join("gitconfig");
    fs::write(&global_config, "")?;
    let git = Git {
        runner: &runner,
        global_config: &global_config,
        clock: std::cell::Cell::new(1_800_000_000),
    };
    let repo = work.join("repo");
    let started = Instant::now();
    git.run(
        &work,
        &[
            "clone",
            "--quiet",
            &source.to_string_lossy(),
            &repo.to_string_lossy(),
        ],
        None,
    )?;
    let mut keys_paths = vec![repo.clone()];
    for n in 0..worktrees {
        let path = work.join(format!("wt-{n}"));
        git.run(
            &repo,
            &[
                "worktree",
                "add",
                "--quiet",
                "-b",
                &format!("bench-{n}"),
                &path.to_string_lossy(),
            ],
            None,
        )?;
        keys_paths.push(path);
    }
    println!(
        "setup                        {:>8.0} ms",
        ms(started.elapsed())
    );

    // Two tracked text files to flip between, and one the churn edits.
    let tracked = runner
        .read(&repo)
        .args(["ls-files", "-z", "--", "*.c"])
        .run()?;
    let files: Vec<PathBuf> = tracked
        .stdout_text()
        .split('\0')
        .filter(|p| !p.is_empty() && !p.contains('/'))
        .take(3)
        .map(PathBuf::from)
        .collect();
    let [a, b, c] = files.as_slice() else {
        bail!("the source needs three .c files at its root");
    };
    for file in [a, b] {
        append(&repo.join(file), "/* bench edit */")?;
    }

    let mut config = Config::default();
    config.auto_fetch_minutes = 0;
    let mut bench = Bench {
        rt: Runtime::with_runner(config, None, runner.clone()),
        max_poll: Duration::ZERO,
        graph_resets: 0,
    };
    let keys: Vec<PathBuf> = keys_paths.iter().map(|p| bench.rt.open(p)).collect();
    for key in &keys {
        bench.rt.set_history_scope(key, HistoryScope::AllBranches);
    }
    let main = keys[0].clone();
    // As in the app: one History view shows, the other worktrees' are hidden
    // (shown once, below, to load and to catch up after the commits).
    let t = bench.until("the status", |rt| {
        rt.repo(&main).is_some_and(|s| s.status().is_some())
    })?;
    println!("open → status                {:>8.0} ms", ms(t));
    let t2 = bench.until("the history", |rt| keys.iter().all(|k| graph_done(rt, k)))?;
    println!("open → every history         {:>8.0} ms", ms(t + t2));
    for key in &keys[1..] {
        bench.rt.set_history_visible(key, false);
    }

    // A busy machine: something keeps writing in the worktree.
    let stop = Arc::new(AtomicBool::new(false));
    let churn = {
        let stop = Arc::clone(&stop);
        let (log, tracked) = (repo.join("bench-churn.log"), repo.join(c));
        fs::write(&log, "")?;
        thread::spawn(move || {
            let mut n = 0u64;
            while !stop.load(Ordering::Relaxed) {
                let _ = append(&log, &format!("line {n}"));
                if n.is_multiple_of(8) {
                    let _ = append(&tracked, &format!("/* churn {n} */"));
                }
                n += 1;
                thread::sleep(Duration::from_millis(200));
            }
        })
    };
    bench.max_poll = Duration::ZERO;

    let mut selects = Vec::new();
    for round in 0..rounds * 2 {
        let file = if round % 2 == 0 { a } else { b };
        bench.rt.select_change(&main, file, false);
        let path = file.clone();
        selects.push(bench.until("a diff", |rt| diff_shows(rt, &main, &path, None))?);
    }
    summary("select file → diff shown", &selects);

    let mut edits = Vec::new();
    bench.rt.select_change(&main, a, false);
    bench.until("a diff", |rt| diff_shows(rt, &main, a, None))?;
    for round in 0..rounds {
        let marker = format!("/* edit {round} */");
        append(&repo.join(a), &marker)?;
        edits.push(bench.until("an edit", |rt| diff_shows(rt, &main, a, Some(&marker)))?);
    }
    summary("edit → diff shows it", &edits);

    let mut commits = Vec::new();
    let mut histories = Vec::new();
    for round in 0..rounds.min(3) {
        let file = repo.join(format!("bench-commit-{round}.txt"));
        fs::write(&file, format!("{round}\n"))?;
        let name = file
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        git.run(&repo, &["add", "--", &name], None)?;
        git.run(
            &repo,
            &["commit", "--quiet", "-F", "-"],
            Some("bench commit"),
        )?;
        let head = runner
            .read(&repo)
            .args(["rev-parse", "HEAD"])
            .run()?
            .stdout_text()
            .trim()
            .to_owned();
        let started = Instant::now();
        commits.push(bench.until("the commit in status", |rt| {
            rt.repo(&main)
                .and_then(|s| s.status())
                .is_some_and(|s| s.oid.as_deref() == Some(head.as_str()))
        })?);
        bench.until("the commit in history", |rt| {
            graph_top(rt, &main).as_deref() == Some(head.as_str())
        })?;
        histories.push(started.elapsed());
        if let Some(graph) = bench.rt.repo(&main).and_then(|s| s.graph()) {
            println!(
                "  history load {:>6.0} ms ({})",
                graph.progress().total.map_or(0.0, ms),
                if graph.is_incremental() {
                    "new commits only"
                } else {
                    "in full"
                }
            );
        }
    }
    summary("commit → status", &commits);
    summary("commit → history top", &histories);
    // Show the other worktrees' histories: they catch up now.
    let head = graph_top(&bench.rt, &main);
    for key in &keys[1..] {
        bench.rt.set_history_visible(key, true);
    }
    let settle = bench.until("every history", |rt| {
        keys.iter()
            .all(|k| graph_done(rt, k) && graph_top(rt, k) == head)
    })?;
    println!("show other worktrees' history {:>7.0} ms", ms(settle));
    println!(
        "graph reloads                {:>8}   (all sessions)",
        bench.graph_resets
    );
    println!(
        "longest poll (core per frame) {:>7.1} ms",
        ms(bench.max_poll)
    );

    stop.store(true, Ordering::Relaxed);
    let _ = churn.join();
    for key in &keys {
        bench.rt.close(key);
    }
    Ok(())
}
