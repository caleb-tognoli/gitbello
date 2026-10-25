//! Dev-only headless harness for `gitbello-core`.

mod fixture;
mod repo_cmds;

use std::ops::Range;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use gitbello_core::graph::{
    CommitMatcher, CommitSearch, GraphIndex, GraphLoader, LoadState, RowLayout, SegmentKind,
    SEARCH_CHUNK_ROWS,
};

const USAGE: &str = "usage: gitbello-cli <command>

commands:
  version                          print the core version
  graph <path> [--rows a..b]       print graph rows (default 0..50)
  graph-bench <path>               time a full graph load and print metrics
  status <path>                    working tree status
  refs <path>                      branches, remote branches, tags
  worktrees <path>                 worktrees of the repository
  stashes <path>                   stash list
  diff <root> <file> [--staged|--untracked] [--full]
                                   one file's diff (root = worktree root)
  op-state <path>                  git dirs and in-progress operation
  watch <path>                     print refreshes file changes would trigger
  config                           print the config file path and contents
  fixture <dir> [--repos N]        create throwaway repos for UI smoke tests

Set GITBELLO_LOG=1 to print the git commands a command ran.";

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let rest = args.get(1..).unwrap_or_default();
    match args.first().map(String::as_str) {
        Some("version" | "--version" | "-V") => {
            println!("gitbello-core {}", gitbello_core::VERSION);
            Ok(())
        }
        Some("graph") => graph(rest),
        Some("graph-bench") => graph_bench(rest),
        Some("status") => repo_cmds::status(rest),
        Some("refs") => repo_cmds::refs(rest),
        Some("worktrees") => repo_cmds::worktrees(rest),
        Some("stashes") => repo_cmds::stashes(rest),
        Some("diff") => repo_cmds::diff(rest),
        Some("op-state") => repo_cmds::op_state(rest),
        Some("watch") => repo_cmds::watch(rest),
        Some("config") => repo_cmds::config(rest),
        Some("fixture") => fixture::run(rest),
        Some("help" | "--help" | "-h") | None => {
            println!("{USAGE}");
            Ok(())
        }
        Some(other) => bail!("unknown command `{other}`\n\n{USAGE}"),
    }
}

fn load(path: PathBuf) -> Result<(GraphLoader, Duration)> {
    let runner = repo_cmds::runner()?;
    let started = Instant::now();
    let loader = GraphLoader::start(runner, path);
    loop {
        let progress = loader.progress();
        match progress.state {
            LoadState::Loading => std::thread::sleep(Duration::from_millis(1)),
            LoadState::Done => return Ok((loader, started.elapsed())),
            LoadState::Cancelled => bail!("graph load was cancelled"),
            LoadState::Failed(err) => return Err(err).context("graph load failed"),
        }
    }
}

fn graph(args: &[String]) -> Result<()> {
    let mut path = None;
    let mut rows: Range<usize> = 0..50;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--rows" => {
                let spec = iter.next().context("--rows needs a range like 0..50")?;
                rows = parse_range(spec)?;
            }
            other if path.is_none() => path = Some(PathBuf::from(other)),
            other => bail!("unexpected argument `{other}`"),
        }
    }
    let path = path.context("graph needs a repository path")?;
    let (loader, _) = load(path)?;
    let index = loader.index();
    let count = rows.end.saturating_sub(rows.start);
    let layouts = index.layouts(rows.start, count);
    let width = layouts.iter().map(RowLayout::width).max().unwrap_or(0);
    for (offset, layout) in layouts.iter().enumerate() {
        let row = rows.start + offset;
        let Some(commit) = index.commit(row) else {
            break;
        };
        println!(
            "{row:>7}  {:<width$}  {}  {}  ({})",
            ascii_row(layout),
            commit.short_hash(),
            commit.subject,
            commit.author_name,
            width = usize::from(width) * 2,
        );
    }
    eprintln!(
        "{} rows loaded, showing {}..{}",
        index.row_count(),
        rows.start,
        rows.start + layouts.len()
    );
    Ok(())
}

fn parse_range(spec: &str) -> Result<Range<usize>> {
    let (a, b) = spec
        .split_once("..")
        .with_context(|| format!("invalid range `{spec}`, expected a..b"))?;
    let start: usize = a.parse().with_context(|| format!("invalid start `{a}`"))?;
    let end: usize = b.parse().with_context(|| format!("invalid end `{b}`"))?;
    if end < start {
        bail!("range end {end} is before start {start}");
    }
    Ok(start..end)
}

/// Rough one-line picture of a row: `*` commit, `|` lane, `/` `\` joins and forks.
fn ascii_row(layout: &RowLayout) -> String {
    let width = usize::from(layout.width());
    let mut cells = vec![' '; width * 2];
    for segment in &layout.segments {
        let from = usize::from(segment.from) * 2;
        let to = usize::from(segment.to) * 2;
        let mark = match segment.kind {
            SegmentKind::Pass => '|',
            _ if from == to => '|',
            SegmentKind::In if from > to => '/',
            SegmentKind::In => '\\',
            SegmentKind::Out if to > from => '\\',
            SegmentKind::Out => '/',
        };
        let cell = if from == to { from } else { from.max(to) - 1 };
        if cells[cell] == ' ' {
            cells[cell] = mark;
        }
    }
    cells[usize::from(layout.column) * 2] = '*';
    cells.into_iter().collect::<String>().trim_end().to_owned()
}

fn graph_bench(args: &[String]) -> Result<()> {
    let [path] = args else {
        bail!("graph-bench needs exactly one repository path");
    };
    let path = PathBuf::from(path);
    let git = repo_cmds::runner()?.version();
    let (loader, wall) = load(path.clone())?;
    let progress = loader.progress();
    let index = loader.index();
    let memory = index.memory();
    let rows = index.row_count();
    let slice = time_slices(&index);

    println!("repo            {}", path.display());
    println!("git             {git}");
    println!("commits         {rows}");
    println!(
        "first page      {:.1} ms ({} rows)",
        ms(progress.first_page),
        gitbello_core::graph::FIRST_PAGE_ROWS
    );
    println!("full index      {:.1} ms", ms(progress.total));
    println!("wall            {:.1} ms", wall.as_secs_f64() * 1e3);
    println!("max lanes       {}", index.max_width());
    println!(
        "index memory    {:.2} MiB ({:.1} bytes/commit, target < 150)",
        memory.index_bytes as f64 / MIB,
        memory.index_bytes as f64 / rows.max(1) as f64
    );
    println!(
        "string memory   {:.2} MiB",
        memory.string_bytes as f64 / MIB
    );
    println!(
        "50-row slice    avg {:.1} us, max {:.1} us ({} samples)",
        slice.avg_us, slice.max_us, slice.samples
    );
    let hash = index
        .commit(rows / 2)
        .map(|c| c.hash_hex())
        .unwrap_or_default();
    let max_chunk = max_chunk_us(&index, "fix");
    drop(index);
    for query in ["fix", "Junio", "zzzqqqxx", &hash[..hash.len().min(8)]] {
        let (matches, took) = time_search(&loader, query);
        println!(
            "search {query:<9} {matches} matches in {:.1} ms",
            took.as_secs_f64() * 1e3
        );
    }
    println!(
        "search chunk    max {:.1} us per {SEARCH_CHUNK_ROWS} rows (read lock held)",
        max_chunk
    );
    Ok(())
}

/// A whole search of the loaded graph, as one job runs it.
fn time_search(loader: &GraphLoader, query: &str) -> (usize, Duration) {
    let Some(search) = CommitSearch::new(query, loader.reader()) else {
        return (0, Duration::ZERO);
    };
    let began = Instant::now();
    search.run_now();
    (search.match_count(), began.elapsed())
}

/// The longest single chunk of a search for `query`: how long the read lock
/// is held at most.
fn max_chunk_us(index: &GraphIndex, query: &str) -> f64 {
    let Some(mut matcher) = CommitMatcher::new(query) else {
        return 0.0;
    };
    let mut max = Duration::ZERO;
    let mut found = Vec::new();
    for start in (0..index.row_count()).step_by(SEARCH_CHUNK_ROWS) {
        found.clear();
        let began = Instant::now();
        matcher.scan(index, start..start + SEARCH_CHUNK_ROWS, &mut found);
        max = max.max(began.elapsed());
    }
    std::hint::black_box(found);
    max.as_secs_f64() * 1e6
}

const MIB: f64 = 1024.0 * 1024.0;

fn ms(duration: Option<Duration>) -> f64 {
    duration.map_or(f64::NAN, |d| d.as_secs_f64() * 1e3)
}

struct SliceTiming {
    avg_us: f64,
    max_us: f64,
    samples: usize,
}

/// Times `layouts` + `commit` for 50-row windows spread over the history, as
/// the UI does when scrolling.
fn time_slices(index: &GraphIndex) -> SliceTiming {
    const WINDOW: usize = 50;
    let rows = index.row_count();
    let samples = 400.min(rows.max(1));
    let step = (rows / samples).max(1);
    let mut total = Duration::ZERO;
    let mut max = Duration::ZERO;
    let mut sink = 0usize;
    for i in 0..samples {
        let start = (i * step + i % 7 * 31) % rows.max(1);
        let began = Instant::now();
        let layouts = index.layouts(start, WINDOW);
        for row in start..start + layouts.len() {
            if let Some(commit) = index.commit(row) {
                sink = sink.wrapping_add(commit.subject.len());
            }
        }
        sink = sink.wrapping_add(layouts.iter().map(|l| l.segments.len()).sum::<usize>());
        let took = began.elapsed();
        total += took;
        max = max.max(took);
    }
    std::hint::black_box(sink);
    SliceTiming {
        avg_us: total.as_secs_f64() * 1e6 / samples as f64,
        max_us: max.as_secs_f64() * 1e6,
        samples,
    }
}
