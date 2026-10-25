//! Find in the history (PLAN M6.5 P5): which loaded commits match a query
//! by subject, author name or email (ignoring case), or by hash prefix.
//!
//! It reads only what the graph index holds, so there is no git call. A
//! [`CommitSearch`] scans the index in chunks of [`SEARCH_CHUNK_ROWS`] under
//! short read locks (loading and the UI's slice reads go on in between) as
//! read jobs on the scheduler; while the graph is still loading, the owner
//! submits another job whenever rows arrived that are not searched yet.

use std::ops::Range;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use super::index::GraphIndex;
use super::loader::GraphReader;
use crate::git::CancelToken;
use crate::jobs::{JobId, JobOutput, JobScheduler, JobSpec};

/// Label of search jobs on the scheduler.
pub const SEARCH_JOB_LABEL: &str = "search commits";

/// Rows scanned per read lock.
pub const SEARCH_CHUNK_ROWS: usize = 4096;

/// Shortest query that also matches hash prefixes (shorter hex runs are
/// common words and numbers in subjects).
const MIN_HASH_DIGITS: usize = 4;

/// Matches rows of a graph index against one query. Remembers which author
/// identities match, so each is checked once.
#[derive(Debug, Clone)]
pub struct CommitMatcher {
    /// The query, trimmed and lowercased.
    text: String,
    /// The query's hex digit values, when it can be a hash prefix.
    hash_digits: Option<Vec<u8>>,
    /// Per identity: 0 not checked yet, 1 no match, 2 match.
    authors: Vec<u8>,
}

impl CommitMatcher {
    /// `None` for a blank query.
    pub fn new(query: &str) -> Option<Self> {
        let text = query.trim().to_lowercase();
        if text.is_empty() {
            return None;
        }
        let hash_digits = (text.len() >= MIN_HASH_DIGITS)
            .then(|| {
                text.bytes()
                    .map(|c| (c as char).to_digit(16).map(|d| d as u8))
                    .collect::<Option<Vec<u8>>>()
            })
            .flatten();
        Some(Self {
            text,
            hash_digits,
            authors: Vec::new(),
        })
    }

    /// The query as matched (trimmed, lowercased).
    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn matches(&mut self, index: &GraphIndex, row: usize) -> bool {
        if self
            .hash_digits
            .as_ref()
            .is_some_and(|digits| hash_starts_with(index.hash(row), digits))
        {
            return true;
        }
        if contains_folded(index.subject(row), &self.text) {
            return true;
        }
        let id = index.author_id(row) as usize;
        if id >= self.authors.len() {
            self.authors.resize(id + 1, 0);
        }
        if self.authors[id] == 0 {
            let (name, email) = index.identity(id as u32);
            let hit = contains_folded(name, &self.text) || contains_folded(email, &self.text);
            self.authors[id] = if hit { 2 } else { 1 };
        }
        self.authors[id] == 2
    }

    /// Appends the matching rows of `rows` (clamped to the loaded rows) to `out`.
    pub fn scan(&mut self, index: &GraphIndex, rows: Range<usize>, out: &mut Vec<u32>) {
        let end = rows.end.min(index.row_count());
        for row in rows.start..end {
            if self.matches(index, row) {
                out.push(u32::try_from(row).unwrap_or(u32::MAX));
            }
        }
    }
}

/// Whether the hex form of `hash` starts with `digits` (nibble values).
fn hash_starts_with(hash: &[u8], digits: &[u8]) -> bool {
    digits.len() <= hash.len() * 2
        && digits.iter().enumerate().all(|(i, &digit)| {
            let byte = hash[i / 2];
            let nibble = if i % 2 == 0 { byte >> 4 } else { byte & 0xf };
            nibble == digit
        })
}

/// Whether `haystack` contains `needle` (already lowercase), ignoring case.
fn contains_folded(haystack: &str, needle: &str) -> bool {
    if needle.is_ascii() {
        // No allocation: non-ASCII bytes never equal an ASCII needle's.
        let needle = needle.as_bytes();
        haystack.len() >= needle.len()
            && haystack
                .as_bytes()
                .windows(needle.len())
                .any(|window| window.eq_ignore_ascii_case(needle))
    } else {
        haystack.to_lowercase().contains(needle)
    }
}

#[derive(Debug)]
struct Shared {
    matcher: Mutex<CommitMatcher>,
    /// Matching rows, ascending.
    matches: Mutex<Vec<u32>>,
    /// Rows `0..searched` are searched.
    searched: AtomicUsize,
    /// A job is queued or running.
    running: AtomicBool,
    /// Bumped whenever `matches` or `searched` change.
    version: AtomicU64,
    cancel: CancelToken,
}

/// A search of one graph load, filled by read jobs. Dropping it cancels them.
#[derive(Debug)]
pub struct CommitSearch {
    query: String,
    graph: GraphReader,
    shared: Arc<Shared>,
}

impl CommitSearch {
    /// A search for `query` over `graph`; `None` for a blank query. Nothing
    /// is searched until [`CommitSearch::submit_if_behind`] or [`CommitSearch::run_now`].
    pub fn new(query: &str, graph: GraphReader) -> Option<Self> {
        let matcher = CommitMatcher::new(query)?;
        Some(Self {
            query: query.to_owned(),
            graph,
            shared: Arc::new(Shared {
                matcher: Mutex::new(matcher),
                matches: Mutex::new(Vec::new()),
                searched: AtomicUsize::new(0),
                running: AtomicBool::new(false),
                version: AtomicU64::new(0),
                cancel: CancelToken::new(),
            }),
        })
    }

    /// The query as given.
    pub fn query(&self) -> &str {
        &self.query
    }

    /// Rows searched so far (from the top).
    pub fn searched(&self) -> usize {
        self.shared.searched.load(Ordering::Acquire)
    }

    /// Whether every row is searched and the graph has finished loading.
    pub fn is_done(&self) -> bool {
        // Read `running` first: a job clears it only after storing `searched`.
        !self.shared.running.load(Ordering::Acquire)
            && self.graph.is_finished()
            && self.searched() >= self.graph.row_count()
    }

    /// Changes whenever matches or progress change.
    pub fn version(&self) -> u64 {
        self.shared.version.load(Ordering::Acquire)
    }

    pub fn match_count(&self) -> usize {
        self.lock_matches().len()
    }

    /// Matching rows `start..start + count` of all matches, ascending.
    pub fn matches(&self, start: usize, count: usize) -> Vec<usize> {
        self.lock_matches()
            .iter()
            .skip(start)
            .take(count)
            .map(|&row| row as usize)
            .collect()
    }

    pub fn is_match(&self, row: usize) -> bool {
        u32::try_from(row).is_ok_and(|row| self.lock_matches().binary_search(&row).is_ok())
    }

    /// Position of `row` among the matches, if it is one.
    pub fn match_index(&self, row: usize) -> Option<usize> {
        let row = u32::try_from(row).ok()?;
        self.lock_matches().binary_search(&row).ok()
    }

    /// The first match after `row` (or before it when not `forward`),
    /// wrapping around; `None` without matches. `row` need not be a match.
    pub fn next_match(&self, row: usize, forward: bool) -> Option<usize> {
        let matches = self.lock_matches();
        let row = u32::try_from(row).unwrap_or(u32::MAX);
        let found = if forward {
            let after = matches.partition_point(|&m| m <= row);
            matches.get(after).or_else(|| matches.first())
        } else {
            let before = matches.partition_point(|&m| m < row);
            before
                .checked_sub(1)
                .and_then(|i| matches.get(i))
                .or_else(|| matches.last())
        };
        found.map(|&m| m as usize)
    }

    /// Submits a read job for the loaded rows not searched yet, unless one is
    /// queued or running or nothing is left. Call each poll while loading.
    pub fn submit_if_behind(&self, scheduler: &JobScheduler, repo: PathBuf) -> Option<JobId> {
        if self.shared.cancel.is_cancelled()
            || self.searched() >= self.graph.row_count()
            || self.shared.running.swap(true, Ordering::AcqRel)
        {
            return None;
        }
        let shared = Arc::clone(&self.shared);
        let graph = self.graph.clone();
        let spec = JobSpec::read(repo, SEARCH_JOB_LABEL, move |_| {
            run(&shared, &graph);
            Ok(JobOutput::Done)
        })
        .with_cancel(self.shared.cancel.clone());
        Some(scheduler.submit(spec))
    }

    /// Searches the loaded rows not searched yet on this thread (CLI, tests).
    pub fn run_now(&self) {
        if !self.shared.running.swap(true, Ordering::AcqRel) {
            run(&self.shared, &self.graph);
        }
    }

    pub fn cancel(&self) {
        self.shared.cancel.cancel();
    }

    fn lock_matches(&self) -> std::sync::MutexGuard<'_, Vec<u32>> {
        self.shared
            .matches
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }
}

impl Drop for CommitSearch {
    fn drop(&mut self) {
        self.cancel();
    }
}

/// Scans from `searched` to the rows loaded now, one chunk per read lock,
/// then clears `running`.
fn run(shared: &Shared, graph: &GraphReader) {
    let mut matcher = shared
        .matcher
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    let mut found = Vec::new();
    loop {
        if shared.cancel.is_cancelled() {
            break;
        }
        let start = shared.searched.load(Ordering::Acquire);
        let end = {
            let index = graph.index();
            let end = index.row_count().min(start + SEARCH_CHUNK_ROWS);
            found.clear();
            matcher.scan(&index, start..end, &mut found);
            end
        };
        if end <= start {
            break;
        }
        shared
            .matches
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .extend_from_slice(&found);
        shared.searched.store(end, Ordering::Release);
        shared.version.fetch_add(1, Ordering::AcqRel);
    }
    shared.running.store(false, Ordering::Release);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::LogRecord;
    use std::borrow::Cow;

    fn index(commits: &[(&str, &str, &str, &str)]) -> GraphIndex {
        let mut index = GraphIndex::new();
        let mut parent = String::new();
        for (hash, name, email, subject) in commits {
            let hash = format!("{hash:0<40}");
            index
                .push(&LogRecord {
                    hash: &hash,
                    parents: &parent,
                    author_name: Cow::Borrowed(name),
                    author_email: Cow::Borrowed(email),
                    author_time: 0,
                    subject: Cow::Borrowed(subject),
                })
                .expect("valid record");
            parent = hash;
        }
        index
    }

    fn found(index: &GraphIndex, query: &str) -> Vec<u32> {
        let mut out = Vec::new();
        if let Some(mut matcher) = CommitMatcher::new(query) {
            matcher.scan(index, 0..usize::MAX, &mut out);
        }
        out
    }

    #[test]
    fn matches_subject_author_and_hash_prefix() {
        let index = index(&[
            ("ab12", "Ada Lovelace", "ada@example.com", "Fix the Parser"),
            ("cd34", "Grace", "grace@navy.mil", "Add cafe menu"),
            (
                "ef56",
                "Ada Lovelace",
                "ada@example.com",
                "Résumé: ÉTÉ notes",
            ),
            ("ab99", "Linus", "linus@kernel.org", "Merge branch 'dead'"),
        ]);
        assert_eq!(found(&index, "  parser "), [0]);
        assert_eq!(found(&index, "ADA"), [0, 2]);
        assert_eq!(found(&index, "navy.mil"), [1]);
        assert_eq!(found(&index, "été"), [2]);
        // Four or more hex digits also match hash prefixes ("cafe" and
        // "dead" are words in subjects too).
        assert_eq!(found(&index, "ab12"), [0]);
        assert_eq!(found(&index, "AB9"), Vec::<u32>::new());
        assert_eq!(found(&index, "cafe"), [1]);
        assert_eq!(found(&index, "dead"), [3]);
        assert_eq!(found(&index, "ab990000"), [3]);
        assert!(CommitMatcher::new("   ").is_none());
    }

    #[test]
    fn hash_prefixes_compare_nibbles() {
        let hash = [0xab, 0xc0];
        assert!(hash_starts_with(&hash, &[0xa, 0xb, 0xc]));
        assert!(!hash_starts_with(&hash, &[0xa, 0xc]));
        assert!(!hash_starts_with(&hash, &[0xa, 0xb, 0xc, 0x0, 0x0]));
        assert!(contains_folded("Hello World", "lo w"));
        assert!(!contains_folded("Hi", "hello"));
    }
}
