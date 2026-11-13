//! `highlight <file>`: a file's syntax tokens; `highlight-bench <dir>`:
//! lexing speed per language over the samples in `<dir>` (by default the
//! core's `tests/highlight`).

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{bail, Context, Result};
use gitbello_core::diff::display_text;
use gitbello_core::highlight::{
    detect, dump, Language, LineStates, Syntax, TokenKind, MAX_LEXED_CHARS,
};

/// The core's syntax samples, for the bench and the fixture.
pub fn samples_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../gitbello-core/tests/highlight")
}

/// The sample files under `dir`, one folder per language.
pub fn samples(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    for entry in fs::read_dir(dir).with_context(|| format!("reading {}", dir.display()))? {
        let folder = entry?.path();
        if !folder.is_dir() {
            continue;
        }
        for file in fs::read_dir(&folder)? {
            let file = file?.path();
            let name = file.file_name().map(|n| n.to_string_lossy().into_owned());
            if name.is_some_and(|n| n.starts_with("sample") && !n.ends_with(".tokens")) {
                out.push(file);
            }
        }
    }
    out.sort();
    Ok(out)
}

/// `highlight <file> [--language <id>]`.
pub fn highlight(args: &[String]) -> Result<()> {
    let mut file = None;
    let mut forced = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--language" => {
                let id = iter.next().context("--language needs an id")?;
                forced = Some(Language::by_id(id).with_context(|| {
                    let ids: Vec<&str> = Language::all().map(Language::id).collect();
                    format!("unknown language `{id}` (known: {})", ids.join(", "))
                })?);
            }
            other if file.is_none() => file = Some(PathBuf::from(other)),
            other => bail!("unexpected argument `{other}`"),
        }
    }
    let file = file.context("highlight needs a file")?;
    let text = fs::read(&file).with_context(|| format!("reading {}", file.display()))?;
    let first = text.split(|&b| b == b'\n').next().map(display_text);
    let Some(language) = forced.or_else(|| detect(&file, first.as_deref())) else {
        bail!("no language for {} (try --language)", file.display());
    };
    eprintln!("{} ({})", language.name(), language.id());
    print!("{}", dump(language, &text));
    Ok(())
}

/// `highlight-bench [<dir>] [--rounds N]`.
pub fn bench(args: &[String]) -> Result<()> {
    let mut dir = None;
    let mut rounds = 200usize;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--rounds" => {
                rounds = iter
                    .next()
                    .context("--rounds needs a number")?
                    .parse()
                    .context("--rounds needs a number")?;
            }
            other if dir.is_none() => dir = Some(PathBuf::from(other)),
            other => bail!("unexpected argument `{other}`"),
        }
    }
    let dir = dir.unwrap_or_else(samples_dir);
    println!(
        "{:<12} {:>6} {:>12} {:>14} {:>16} {:>15}",
        "language", "lines", "lines/s", "us/100 lines", "us/long line", "states us/100"
    );
    let mut total_lines = 0usize;
    let mut total_secs = 0f64;
    let mut ten_thousand = None;
    for sample in samples(&dir)? {
        let text = fs::read(&sample)?;
        let lines: Vec<String> = text.split(|&b| b == b'\n').map(display_text).collect();
        let Some(language) = detect(&sample, lines.first().map(String::as_str)) else {
            continue;
        };
        let syntax = Syntax::new(Some(language), &lines);
        let started = Instant::now();
        let mut tokens = 0usize;
        for _ in 0..rounds {
            for line in &lines {
                tokens += syntax.highlight(line).len();
            }
        }
        let secs = started.elapsed().as_secs_f64();
        let lexed = lines.len() * rounds;
        // A minified line: the sample's lines without comments joined up to
        // the lexing limit (a comment would end the lexing early).
        let code: Vec<&String> = lines
            .iter()
            .filter(|l| {
                let tokens = syntax.highlight(l);
                !l.trim().is_empty() && tokens.iter().all(|t| t.kind != TokenKind::Comment)
            })
            .collect();
        let long: String = code
            .iter()
            .flat_map(|l| l.chars().chain(std::iter::once(' ')))
            .cycle()
            .take(MAX_LEXED_CHARS)
            .collect();
        let long_rounds = rounds.clamp(1, 50);
        let started = Instant::now();
        for _ in 0..long_rounds {
            tokens += syntax.highlight(&long).len();
        }
        let long_us = started.elapsed().as_secs_f64() * 1e6 / long_rounds as f64;
        // The line states of the whole file, as the states job finds them.
        let started = Instant::now();
        for _ in 0..rounds {
            let states = LineStates::of_text(&syntax, &text, || false);
            tokens += states.map_or(0, |s| s.kept());
        }
        let states_us = started.elapsed().as_secs_f64() * 1e6 / lexed as f64 * 100.0;
        std::hint::black_box(tokens);
        println!(
            "{:<12} {:>6} {:>12.0} {:>14.1} {:>16.0} {:>15.1}",
            language.id(),
            lines.len(),
            lexed as f64 / secs,
            secs * 1e6 / lexed as f64 * 100.0,
            long_us,
            states_us
        );
        if language.id() == "rust" {
            // A 10,000-line file, the size the states budget is set for.
            let mut big = Vec::new();
            while big.iter().filter(|&&b| b == b'\n').count() < 10_000 {
                big.extend_from_slice(&text);
            }
            let started = Instant::now();
            let states = LineStates::of_text(&syntax, &big, || false);
            let ms = started.elapsed().as_secs_f64() * 1e3;
            ten_thousand = Some((states.map_or(0, |s| s.line_count()), ms));
        }
        total_lines += lexed;
        total_secs += secs;
    }
    if total_lines > 0 {
        println!(
            "{:<12} {:>6} {:>12.0} {:>14.1}",
            "all",
            "",
            total_lines as f64 / total_secs,
            total_secs * 1e6 / total_lines as f64 * 100.0
        );
    }
    if let Some((lines, ms)) = ten_thousand {
        println!("states of {lines} lines of Rust: {ms:.1} ms");
    }
    Ok(())
}
