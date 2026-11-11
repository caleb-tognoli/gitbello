//! Blame (PLAN M8b): for each line of a file, the commit that last changed
//! it (`git blame --incremental`).
//!
//! git reports blame in blocks, in the order it finds them (newest commits
//! first), not in line order: `<hash> <original line> <final line> <count>`,
//! the commit's fields the first time that commit shows, then `previous
//! <hash> <path>` (when the lines existed before the commit) and `filename
//! <path>`, which ends the block. [`BlameParser`] reads that stream in
//! chunks.
//!
//! A [`BlameLoader`] reads the file's text first, so it can show at once,
//! then fills in the blocks on a job while readers take short read locks.

use std::collections::HashMap;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock, RwLockReadGuard};
use std::time::{Duration, Instant};

use crate::backend::GitBackend;
use crate::diff::looks_binary;
use crate::diff::minimap::{Mark, MiniLine, MiniRow, MinimapSource};
use crate::git::{CancelToken, GitError, GitErrorKind};
use crate::highlight::Language;
use crate::jobs::{JobId, JobOutput, JobScheduler, JobSpec};
use crate::repo::{git_path, ParseError};

/// Label of blame jobs on the scheduler.
pub const BLAME_JOB_LABEL: &str = "blame";

/// A file larger than this is not blamed.
pub const LARGE_BLAME_BYTES: usize = 8 * 1024 * 1024;

/// `git blame` arguments before the options, the revision and the path.
pub const BLAME_ARGS: &[&str] = &["blame", "--incremental", "--encoding=UTF-8"];

const WHAT: &str = "blame";
/// No block yet (in [`BlameTable`]'s line table).
const NONE: u32 = u32::MAX;

/// How lines are traced.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct BlameOptions {
    /// Skip changes that only touched whitespace (`-w`).
    pub ignore_whitespace: bool,
    /// Follow lines moved or copied within the file (`-M`).
    pub detect_moves: bool,
}

impl BlameOptions {
    /// The flags these options add to [`BLAME_ARGS`].
    pub fn args(self) -> Vec<&'static str> {
        let mut args = Vec::new();
        if self.ignore_whitespace {
            args.push("-w");
        }
        if self.detect_moves {
            args.push("-M");
        }
        args
    }
}

/// A commit lines are blamed on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlameCommit {
    pub oid: String,
    pub author: String,
    pub email: String,
    /// Author time, unix seconds.
    pub time: i64,
    pub summary: String,
    /// The history given to blame ends here: the lines may be older.
    pub boundary: bool,
}

impl BlameCommit {
    /// The lines are not committed yet (git's all-zero hash).
    pub fn is_working(&self) -> bool {
        is_null_oid(&self.oid)
    }
}

fn is_null_oid(oid: &str) -> bool {
    !oid.is_empty() && oid.bytes().all(|b| b == b'0')
}

/// A run of lines blamed on one commit, as git reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlameBlock {
    pub oid: String,
    /// First line of the run in the commit's file (1-based).
    pub orig_line: u32,
    /// First line of the run in the blamed file (1-based).
    pub final_line: u32,
    pub count: u32,
    /// The commit's fields, the first time git names it.
    pub commit: Option<BlameCommit>,
    /// The commit and the name the lines came from, when they existed
    /// before this commit.
    pub previous: Option<(String, PathBuf)>,
    /// The file's name in the commit.
    pub path: PathBuf,
}

#[derive(Debug, Default)]
struct Partial {
    oid: String,
    orig_line: u32,
    final_line: u32,
    count: u32,
    author: Option<String>,
    email: String,
    time: i64,
    summary: String,
    boundary: bool,
    previous: Option<(String, PathBuf)>,
}

/// Reads `git blame --incremental` output fed in chunks.
#[derive(Debug, Default)]
pub struct BlameParser {
    /// The bytes of a line not ended yet.
    rest: Vec<u8>,
    current: Option<Partial>,
}

impl BlameParser {
    pub fn new() -> Self {
        Self::default()
    }

    /// Takes the next bytes of the output; every block they complete goes
    /// to `sink`.
    pub fn feed(
        &mut self,
        bytes: &[u8],
        sink: &mut dyn FnMut(BlameBlock),
    ) -> Result<(), ParseError> {
        let mut bytes = bytes;
        while let Some(end) = bytes.iter().position(|&b| b == b'\n') {
            if self.rest.is_empty() {
                self.line(&bytes[..end], sink)?;
            } else {
                self.rest.extend_from_slice(&bytes[..end]);
                let line = std::mem::take(&mut self.rest);
                self.line(&line, sink)?;
            }
            bytes = &bytes[end + 1..];
        }
        self.rest.extend_from_slice(bytes);
        Ok(())
    }

    /// The output ended: nothing may be left half read.
    pub fn finish(self) -> Result<(), ParseError> {
        if self.current.is_some() || !self.rest.is_empty() {
            return Err(ParseError::new(WHAT, "the output ends inside a block"));
        }
        Ok(())
    }

    fn line(&mut self, line: &[u8], sink: &mut dyn FnMut(BlameBlock)) -> Result<(), ParseError> {
        let Some(current) = self.current.as_mut() else {
            self.current = Some(parse_header(line)?);
            return Ok(());
        };
        let (key, value) = match line.iter().position(|&b| b == b' ') {
            Some(at) => (&line[..at], &line[at + 1..]),
            None => (line, &b""[..]),
        };
        let text = || String::from_utf8_lossy(value).into_owned();
        match key {
            b"author" => current.author = Some(text()),
            b"author-mail" => {
                let mail = text();
                current.email = mail
                    .strip_prefix('<')
                    .and_then(|m| m.strip_suffix('>'))
                    .map(str::to_owned)
                    .unwrap_or(mail);
            }
            b"author-time" => {
                current.time = text()
                    .parse()
                    .map_err(|_| ParseError::new(WHAT, format!("bad author time `{}`", text())))?;
            }
            b"summary" => current.summary = text(),
            b"boundary" => current.boundary = true,
            b"previous" => {
                let at = value
                    .iter()
                    .position(|&b| b == b' ')
                    .ok_or_else(|| ParseError::new(WHAT, "a previous line without a path"))?;
                current.previous = Some((
                    String::from_utf8_lossy(&value[..at]).into_owned(),
                    unquote_path(&value[at + 1..]),
                ));
            }
            b"filename" => {
                let done = self.current.take().unwrap_or_default();
                let commit = done.author.map(|author| BlameCommit {
                    oid: done.oid.clone(),
                    author,
                    email: done.email,
                    time: done.time,
                    summary: done.summary,
                    boundary: done.boundary,
                });
                sink(BlameBlock {
                    oid: done.oid,
                    orig_line: done.orig_line,
                    final_line: done.final_line,
                    count: done.count,
                    commit,
                    previous: done.previous,
                    path: unquote_path(value),
                });
            }
            // The committer, time zones and anything a later git adds.
            _ => {}
        }
        Ok(())
    }
}

fn parse_header(line: &[u8]) -> Result<Partial, ParseError> {
    let bad = || {
        ParseError::new(
            WHAT,
            format!("bad block header `{}`", String::from_utf8_lossy(line)),
        )
    };
    let text = std::str::from_utf8(line).map_err(|_| bad())?;
    let mut parts = text.split(' ');
    let oid = parts
        .next()
        .filter(|oid| oid.len() >= 40 && oid.bytes().all(|b| b.is_ascii_hexdigit()));
    let mut number = || parts.next().and_then(|n| n.parse::<u32>().ok());
    match (oid, number(), number(), number()) {
        (Some(oid), Some(orig_line), Some(final_line), Some(count)) => Ok(Partial {
            oid: oid.to_owned(),
            orig_line,
            final_line,
            count,
            ..Partial::default()
        }),
        _ => Err(bad()),
    }
}

/// A path as blame prints it: as it is, or in double quotes with C escapes
/// when it holds a quote, a backslash or a control character.
fn unquote_path(bytes: &[u8]) -> PathBuf {
    let quoted = bytes.len() >= 2 && bytes[0] == b'"' && bytes[bytes.len() - 1] == b'"';
    if !quoted {
        return git_path(bytes);
    }
    let inner = &bytes[1..bytes.len() - 1];
    let mut out = Vec::with_capacity(inner.len());
    let mut i = 0;
    while i < inner.len() {
        let b = inner[i];
        i += 1;
        if b != b'\\' || i >= inner.len() {
            out.push(b);
            continue;
        }
        let escape = inner[i];
        i += 1;
        match escape {
            b'a' => out.push(0x07),
            b'b' => out.push(0x08),
            b'f' => out.push(0x0c),
            b'n' => out.push(b'\n'),
            b'r' => out.push(b'\r'),
            b't' => out.push(b'\t'),
            b'v' => out.push(0x0b),
            b'0'..=b'7' => {
                let mut value = u32::from(escape - b'0');
                let mut digits = 1;
                while digits < 3 && i < inner.len() && (b'0'..=b'7').contains(&inner[i]) {
                    value = value * 8 + u32::from(inner[i] - b'0');
                    i += 1;
                    digits += 1;
                }
                out.push(u8::try_from(value & 0xff).unwrap_or(b'?'));
            }
            other => out.push(other),
        }
    }
    git_path(&out)
}

/// What blame reads.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct BlameRequest {
    /// The commit whose file is blamed; `None` for the working copy.
    pub rev: Option<String>,
    /// The file's name there, relative to the worktree root.
    pub path: PathBuf,
    pub options: BlameOptions,
}

/// The text to blame, as read before blame runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlameSource {
    Text(Vec<u8>),
    /// Larger than the limit, by this many bytes at least.
    TooLarge(u64),
    /// The working copy has no such file.
    Missing,
}

/// Where a blame stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlameLoad {
    /// The text or more blocks are still to come.
    Loading,
    Done,
    Cancelled,
    Failed(GitError),
    /// Not text: nothing to blame line by line.
    Binary,
    TooLarge(u64),
    Missing,
}

/// A block of the table: a run of lines of one commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TableBlock {
    /// Index into the table's commits.
    pub commit: u32,
    pub orig_line: u32,
    pub final_line: u32,
    pub count: u32,
    pub path: PathBuf,
    pub previous: Option<(String, PathBuf)>,
}

/// The blamed file: its lines, and for each the block git put it in.
#[derive(Debug, Default)]
pub struct BlameTable {
    text: Vec<u8>,
    /// Each line's bytes in `text`, without its newline.
    lines: Vec<Range<usize>>,
    /// Per line: its block, or [`NONE`].
    line_block: Vec<u32>,
    blocks: Vec<TableBlock>,
    commits: Vec<BlameCommit>,
    by_oid: HashMap<String, u32>,
    blamed: usize,
    /// Author times of the oldest and newest commit seen (committed ones).
    times: Option<(i64, i64)>,
}

impl BlameTable {
    fn set_text(&mut self, text: Vec<u8>) {
        let mut lines = Vec::new();
        let mut start = 0;
        for (at, &byte) in text.iter().enumerate() {
            if byte == b'\n' {
                lines.push(start..at);
                start = at + 1;
            }
        }
        if start < text.len() {
            lines.push(start..text.len());
        }
        self.line_block = vec![NONE; lines.len()];
        self.lines = lines;
        self.text = text;
    }

    fn apply(&mut self, block: BlameBlock) {
        let commit = match self.by_oid.get(&block.oid) {
            Some(&index) => index,
            None => {
                let Ok(index) = u32::try_from(self.commits.len()) else {
                    return;
                };
                let commit = block.commit.unwrap_or_else(|| BlameCommit {
                    oid: block.oid.clone(),
                    author: String::new(),
                    email: String::new(),
                    time: 0,
                    summary: String::new(),
                    boundary: false,
                });
                if !commit.is_working() {
                    self.times = Some(match self.times {
                        Some((oldest, newest)) => {
                            (oldest.min(commit.time), newest.max(commit.time))
                        }
                        None => (commit.time, commit.time),
                    });
                }
                self.by_oid.insert(block.oid.clone(), index);
                self.commits.push(commit);
                index
            }
        };
        let Ok(index) = u32::try_from(self.blocks.len()) else {
            return;
        };
        let first = block.final_line.saturating_sub(1) as usize;
        let end = first
            .saturating_add(block.count as usize)
            .min(self.line_block.len());
        for slot in self.line_block.get_mut(first..end).unwrap_or_default() {
            if *slot == NONE {
                self.blamed += 1;
            }
            *slot = index;
        }
        self.blocks.push(TableBlock {
            commit,
            orig_line: block.orig_line,
            final_line: block.final_line,
            count: block.count,
            path: block.path,
            previous: block.previous,
        });
    }

    pub fn line_count(&self) -> usize {
        self.lines.len()
    }

    /// Lines git has reported a block for so far.
    pub fn blamed_count(&self) -> usize {
        self.blamed
    }

    /// The bytes of line `line` (0-based), without its newline.
    pub fn line_text(&self, line: usize) -> &[u8] {
        self.lines
            .get(line)
            .and_then(|range| self.text.get(range.clone()))
            .unwrap_or_default()
    }

    /// The block line `line` (0-based) is in, once git reported it.
    pub fn block_of(&self, line: usize) -> Option<&TableBlock> {
        let index = *self.line_block.get(line)?;
        self.blocks.get(index as usize)
    }

    /// The commit line `line` (0-based) is blamed on, once known.
    pub fn commit_of(&self, line: usize) -> Option<&BlameCommit> {
        self.commits.get(self.block_of(line)?.commit as usize)
    }

    fn commit_index_of(&self, line: usize) -> Option<u32> {
        self.block_of(line).map(|block| block.commit)
    }

    /// Whether `line` starts a run of lines of one commit: the line before
    /// is another commit's, or not blamed yet.
    pub fn starts_run(&self, line: usize) -> bool {
        match self.commit_index_of(line) {
            Some(commit) => line == 0 || self.commit_index_of(line - 1) != Some(commit),
            None => false,
        }
    }

    /// The line in the commit's file that `line` (0-based) was (1-based).
    pub fn orig_line(&self, line: usize) -> Option<u32> {
        let block = self.block_of(line)?;
        let offset = u32::try_from(line + 1)
            .ok()?
            .checked_sub(block.final_line)?;
        Some(block.orig_line + offset)
    }

    pub fn commits(&self) -> &[BlameCommit] {
        &self.commits
    }

    pub fn commit(&self, oid: &str) -> Option<&BlameCommit> {
        self.commits.get(*self.by_oid.get(oid)? as usize)
    }

    /// Whether line `line` (0-based) is blamed on commit `oid`.
    pub fn line_is_of(&self, line: usize, oid: &str) -> bool {
        self.commit_of(line).is_some_and(|commit| commit.oid == oid)
    }

    /// How recent `commit` is among the commits seen: 0 for the oldest, 1
    /// for the newest and for lines not committed yet.
    pub fn age(&self, commit: &BlameCommit) -> f32 {
        if commit.is_working() {
            return 1.0;
        }
        match self.times {
            Some((oldest, newest)) if newest > oldest => {
                let span = (newest - oldest) as f64;
                (((commit.time - oldest) as f64 / span).clamp(0.0, 1.0)) as f32
            }
            _ => 1.0,
        }
    }

    /// The first line (0-based) of the next run of commit `oid` after line
    /// `from` (`forward`) or before it, wrapping; `None` when no line is
    /// blamed on it.
    pub fn next_run_of(&self, oid: &str, from: usize, forward: bool) -> Option<usize> {
        let count = self.line_count();
        let target = *self.by_oid.get(oid)?;
        let starts = |line: usize| {
            self.commit_index_of(line) == Some(target)
                && (line == 0 || self.commit_index_of(line - 1) != Some(target))
        };
        let from = from.min(count.saturating_sub(1));
        (1..=count)
            .map(|step| {
                if forward {
                    (from + step) % count
                } else {
                    (from + count - step % count) % count
                }
            })
            .find(|&line| starts(line))
    }
}

/// The blamed file as minimap rows: its lines as context, the lines of
/// the focused commit marked (as lines just written are: the accent).
pub struct BlameMinimap<'a> {
    table: &'a BlameTable,
    /// The focused commit's index among the table's commits.
    focus: Option<u32>,
    language: Option<Language>,
}

impl<'a> BlameMinimap<'a> {
    pub fn new(table: &'a BlameTable, focus: Option<&str>, language: Option<Language>) -> Self {
        Self {
            table,
            focus: focus.and_then(|oid| table.by_oid.get(oid).copied()),
            language,
        }
    }
}

impl MinimapSource for BlameMinimap<'_> {
    fn row_count(&self) -> usize {
        self.table.line_count()
    }

    fn row(&self, row: usize) -> MiniRow<'_> {
        let focused = self.focus.is_some() && self.table.commit_index_of(row) == self.focus;
        MiniRow {
            left: Some(MiniLine {
                mark: if focused {
                    Mark::Resolved
                } else {
                    Mark::Context
                },
                text: self.table.line_text(row),
                left_out: false,
            }),
            right: None,
            divider: false,
        }
    }

    fn split(&self) -> bool {
        false
    }

    fn language(&self) -> Option<Language> {
        self.language
    }
}

/// Timings and counts of a blame, for the CLI and `docs/perf.md`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlameProgress {
    pub lines: usize,
    pub blamed: usize,
    pub commits: usize,
    pub state: BlameLoad,
    /// Time from the start until the text was read.
    pub text: Option<Duration>,
    /// Time from the start until the first block.
    pub first_block: Option<Duration>,
    /// Time from the start until blame ended.
    pub total: Option<Duration>,
}

#[derive(Debug)]
struct Status {
    state: BlameLoad,
    text: Option<Duration>,
    first_block: Option<Duration>,
    total: Option<Duration>,
}

#[derive(Debug)]
struct Shared {
    table: RwLock<BlameTable>,
    /// Bumped whenever the table or the state change.
    version: AtomicU64,
    status: Mutex<Status>,
    cancel: CancelToken,
    started: Instant,
}

impl Shared {
    fn status(&self) -> std::sync::MutexGuard<'_, Status> {
        self.status.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn table_mut(&self) -> std::sync::RwLockWriteGuard<'_, BlameTable> {
        self.table.write().unwrap_or_else(PoisonError::into_inner)
    }

    fn bump(&self) {
        self.version.fetch_add(1, Ordering::AcqRel);
    }
}

/// Handle to a running or finished blame. Dropping it cancels the blame.
#[derive(Debug)]
pub struct BlameLoader {
    shared: Arc<Shared>,
}

impl BlameLoader {
    /// Blames `request` as a read job on `scheduler`.
    pub fn submit(
        scheduler: &JobScheduler,
        key: &Path,
        toplevel: PathBuf,
        request: BlameRequest,
    ) -> (Self, JobId) {
        let loader = Self::unstarted();
        let shared = Arc::clone(&loader.shared);
        let spec = JobSpec::read(key, BLAME_JOB_LABEL, move |ctx| {
            run(ctx.backend(), &toplevel, &request, &shared);
            Ok(JobOutput::Done)
        })
        .with_cancel(loader.shared.cancel.clone());
        let id = scheduler.submit(spec);
        (loader, id)
    }

    /// Blames on the calling thread. For the CLI and tests, never the UI.
    pub fn load(backend: &dyn GitBackend, toplevel: &Path, request: &BlameRequest) -> Self {
        let loader = Self::unstarted();
        run(backend, toplevel, request, &loader.shared);
        loader
    }

    fn unstarted() -> Self {
        Self {
            shared: Arc::new(Shared {
                table: RwLock::new(BlameTable::default()),
                version: AtomicU64::new(0),
                status: Mutex::new(Status {
                    state: BlameLoad::Loading,
                    text: None,
                    first_block: None,
                    total: None,
                }),
                cancel: CancelToken::new(),
                started: Instant::now(),
            }),
        }
    }

    /// Read access to the lines and their blocks. Keep the guard
    /// short-lived: blame waits on it.
    pub fn table(&self) -> RwLockReadGuard<'_, BlameTable> {
        self.shared
            .table
            .read()
            .unwrap_or_else(PoisonError::into_inner)
    }

    /// Changes whenever the table or the state do.
    pub fn version(&self) -> u64 {
        self.shared.version.load(Ordering::Acquire)
    }

    pub fn state(&self) -> BlameLoad {
        self.shared.status().state.clone()
    }

    pub fn is_loading(&self) -> bool {
        self.state() == BlameLoad::Loading
    }

    pub fn progress(&self) -> BlameProgress {
        let (lines, blamed, commits) = {
            let table = self.table();
            (
                table.line_count(),
                table.blamed_count(),
                table.commits().len(),
            )
        };
        let status = self.shared.status();
        BlameProgress {
            lines,
            blamed,
            commits,
            state: status.state.clone(),
            text: status.text,
            first_block: status.first_block,
            total: status.total,
        }
    }

    pub fn cancel(&self) {
        self.shared.cancel.cancel();
    }
}

impl Drop for BlameLoader {
    fn drop(&mut self) {
        self.cancel();
    }
}

fn run(backend: &dyn GitBackend, toplevel: &Path, request: &BlameRequest, shared: &Shared) {
    let state = match load(backend, toplevel, request, shared) {
        Ok(_) if shared.cancel.is_cancelled() => BlameLoad::Cancelled,
        Ok(state) => state,
        Err(err) if err.kind == GitErrorKind::Cancelled => BlameLoad::Cancelled,
        Err(err) => BlameLoad::Failed(err),
    };
    let mut status = shared.status();
    status.state = state;
    status.total = Some(shared.started.elapsed());
    drop(status);
    shared.bump();
}

fn load(
    backend: &dyn GitBackend,
    toplevel: &Path,
    request: &BlameRequest,
    shared: &Shared,
) -> Result<BlameLoad, GitError> {
    let source = backend.blame_source(
        toplevel,
        request.rev.as_deref(),
        &request.path,
        LARGE_BLAME_BYTES,
        &shared.cancel,
    )?;
    let text = match source {
        BlameSource::Text(text) => text,
        BlameSource::TooLarge(bytes) => return Ok(BlameLoad::TooLarge(bytes)),
        BlameSource::Missing => return Ok(BlameLoad::Missing),
    };
    if looks_binary(&text) {
        return Ok(BlameLoad::Binary);
    }
    shared.table_mut().set_text(text);
    shared.status().text = Some(shared.started.elapsed());
    shared.bump();
    if shared.table.read().map_or(true, |t| t.line_count() == 0) {
        return Ok(BlameLoad::Done);
    }
    backend.blame(
        toplevel,
        request.rev.as_deref(),
        &request.path,
        request.options,
        &shared.cancel,
        &mut |block| {
            shared.table_mut().apply(block);
            let mut status = shared.status();
            if status.first_block.is_none() {
                status.first_block = Some(shared.started.elapsed());
            }
            drop(status);
            shared.bump();
        },
    )?;
    Ok(BlameLoad::Done)
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "fc1bac6b57a99cefe2c0febbe57bd19bd3e03ab9";
    const B: &str = "c50fbb2dd225e7e82abba4380423ae105089f4d7";
    const ZERO: &str = "0000000000000000000000000000000000000000";

    fn output() -> String {
        format!(
            "{A} 1 1 2\n\
             author Patrick Steinhardt\n\
             author-mail <ps@pks.im>\n\
             author-time 1783319036\n\
             author-tz +0200\n\
             committer Junio C Hamano\n\
             committer-mail <gitster@pobox.com>\n\
             committer-time 1783347717\n\
             committer-tz -0700\n\
             summary README: add GitLab CI badge\n\
             previous e9019fcafe0040228b8631c30f97ae1adb61bcdc README.md\n\
             filename README.md\n\
             {B} 20 3 1\n\
             author Todd Zullinger\n\
             author-mail <tmz@pobox.com>\n\
             author-time 1741034643\n\
             author-tz -0500\n\
             committer Junio C Hamano\n\
             committer-mail <gitster@pobox.com>\n\
             committer-time 1741038559\n\
             committer-tz -0800\n\
             summary README: *.txt -> *.adoc fixes\n\
             boundary\n\
             filename old name.md\n\
             {A} 7 4 1\n\
             previous e9019fcafe0040228b8631c30f97ae1adb61bcdc README.md\n\
             filename README.md\n\
             {ZERO} 5 5 1\n\
             author Not Committed Yet\n\
             author-mail <not.committed.yet>\n\
             author-time 1783400000\n\
             author-tz +0100\n\
             committer Not Committed Yet\n\
             committer-mail <not.committed.yet>\n\
             committer-time 1783400000\n\
             committer-tz +0100\n\
             summary Version of README.md from README.md\n\
             previous {A} README.md\n\
             filename \"caf\\303\\251 \\\"x\\\"\\t.md\"\n"
        )
    }

    fn parse(chunks: &[&[u8]]) -> Vec<BlameBlock> {
        let mut blocks = Vec::new();
        let mut parser = BlameParser::new();
        for chunk in chunks {
            parser
                .feed(chunk, &mut |block| blocks.push(block))
                .expect("parses");
        }
        parser.finish().expect("complete");
        blocks
    }

    #[test]
    fn parses_blocks_with_the_commit_fields_once() {
        let text = output();
        let blocks = parse(&[text.as_bytes()]);
        assert_eq!(blocks.len(), 4);
        let first = &blocks[0];
        assert_eq!(
            (
                first.oid.as_str(),
                first.orig_line,
                first.final_line,
                first.count
            ),
            (A, 1, 1, 2)
        );
        let commit = first.commit.as_ref().expect("fields the first time");
        assert_eq!(commit.author, "Patrick Steinhardt");
        assert_eq!(commit.email, "ps@pks.im");
        assert_eq!(commit.time, 1_783_319_036);
        assert_eq!(commit.summary, "README: add GitLab CI badge");
        assert!(!commit.boundary);
        assert_eq!(
            first.previous,
            Some((
                "e9019fcafe0040228b8631c30f97ae1adb61bcdc".to_owned(),
                PathBuf::from("README.md")
            ))
        );
        assert_eq!(first.path, PathBuf::from("README.md"));
        // A boundary commit, a name with a space, no previous.
        let second = &blocks[1];
        assert!(second.commit.as_ref().is_some_and(|c| c.boundary));
        assert_eq!(second.previous, None);
        assert_eq!(second.path, PathBuf::from("old name.md"));
        // The same commit again: no fields, its own previous and filename.
        let third = &blocks[2];
        assert_eq!(third.oid, A);
        assert!(third.commit.is_none());
        assert!(third.previous.is_some());
        // Lines not committed yet, a quoted name.
        let last = &blocks[3];
        assert!(last.commit.as_ref().is_some_and(BlameCommit::is_working));
        assert_eq!(last.path, PathBuf::from("café \"x\"\t.md"));
    }

    #[test]
    fn parses_output_split_anywhere() {
        let text = output();
        let whole = parse(&[text.as_bytes()]);
        let bytes = text.as_bytes();
        for size in [1, 2, 7, 64] {
            let chunks: Vec<&[u8]> = bytes.chunks(size).collect();
            assert_eq!(parse(&chunks), whole, "chunks of {size}");
        }
    }

    #[test]
    fn rejects_broken_output() {
        let mut parser = BlameParser::new();
        assert!(parser.feed(b"not a header\n", &mut |_| {}).is_err());
        let mut parser = BlameParser::new();
        parser
            .feed(format!("{A} 1 1 1\nauthor X\n").as_bytes(), &mut |_| {})
            .expect("parses so far");
        assert!(parser.finish().is_err());
    }

    #[test]
    fn the_table_places_blocks_on_lines() {
        let mut table = BlameTable::default();
        table.set_text(b"one\ntwo\r\nthree\nfour\nfive".to_vec());
        assert_eq!(table.line_count(), 5);
        assert_eq!(table.line_text(1), b"two\r");
        assert_eq!(table.line_text(4), b"five");
        assert_eq!(table.blamed_count(), 0);
        assert!(table.commit_of(0).is_none());
        for block in parse(&[output().as_bytes()]) {
            table.apply(block);
        }
        assert_eq!(table.blamed_count(), 5);
        assert_eq!(table.commits().len(), 3);
        let oids: Vec<&str> = (0..5)
            .map(|line| table.commit_of(line).map_or("", |c| c.oid.as_str()))
            .collect();
        assert_eq!(oids, [A, A, B, A, ZERO]);
        let starts: Vec<bool> = (0..5).map(|line| table.starts_run(line)).collect();
        assert_eq!(starts, [true, false, true, true, true]);
        assert_eq!(table.orig_line(1), Some(2));
        assert_eq!(table.orig_line(3), Some(7));
        assert!(table.line_is_of(3, A));
        // The newest commit is 1, the oldest 0, uncommitted lines 1.
        let age = |oid: &str| table.age(table.commit(oid).expect("listed"));
        assert_eq!(age(A), 1.0);
        assert_eq!(age(B), 0.0);
        assert_eq!(age(ZERO), 1.0);
        // The runs of a commit, wrapping.
        assert_eq!(table.next_run_of(A, 0, true), Some(3));
        assert_eq!(table.next_run_of(A, 3, true), Some(0));
        assert_eq!(table.next_run_of(A, 3, false), Some(0));
        assert_eq!(table.next_run_of(A, 0, false), Some(3));
        assert_eq!(table.next_run_of("ffff", 0, true), None);
    }

    #[test]
    fn a_block_past_the_text_is_clamped() {
        let mut table = BlameTable::default();
        table.set_text(b"one\n".to_vec());
        table.apply(BlameBlock {
            oid: A.to_owned(),
            orig_line: 1,
            final_line: 1,
            count: 5,
            commit: None,
            previous: None,
            path: PathBuf::from("a"),
        });
        assert_eq!(table.blamed_count(), 1);
        assert_eq!(table.line_count(), 1);
    }
}
