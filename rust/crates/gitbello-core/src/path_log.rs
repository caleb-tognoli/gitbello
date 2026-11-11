//! The path-limited log (PLAN M8a): the commits that changed some paths,
//! each with what it did to them (`git log -z -M --raw --numstat -- <paths>`).
//!
//! It knows nothing of renames across names or of a single file: a file's
//! history ([`crate::file_history`]) runs it once per set of names, and a
//! folder's history or a search by path can read it as it is. The git read
//! is [`crate::backend::GitBackend::path_log`]; this module holds the model
//! and the parsing of the stream.
//!
//! A record is `\x1e` + the commit's fields (separated by `\x1f`) + NUL,
//! then git's diff output for that commit: a newline, the raw entries
//! (`:modes ids status` NUL path NUL, two paths for a rename) and the
//! numstat entries (`added TAB removed TAB path` NUL; a rename has an empty
//! path there and both names after it). Records are cut at NUL + `\x1e`,
//! which no field can contain, so a subject holding `\x1e` still parses.

use std::path::PathBuf;

use crate::repo::{distinct_coauthors, git_path, Change, ParseError};

/// Starts a commit's record.
const RECORD_MARK: u8 = 0x1e;
/// Between the fields of a commit (`%x1f`).
const FIELD_SEP: u8 = 0x1f;
/// Between the co-author trailer values (`%x1d`).
const COAUTHOR_SEP: char = '\x1d';
const WHAT: &str = "path log";

/// The fields of a commit: hash, parents, author name, author email,
/// author time, `Co-authored-by` trailer values, subject (last: it may hold
/// anything but NUL).
const FORMAT: &str = "--format=%x1e%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x1d)%x1f%s";

/// `git log` arguments before the start revision and the paths. git lists
/// a merge only when the paths differ from every parent (its history
/// simplification) and prints no diff for it: [`MERGE_DIFF_ARGS`] reads
/// those. (Asking `log` itself for merge diffs, `--diff-merges=first-parent`,
/// turns that simplification off: several times the commits and the time
/// on a large history.) `--no-follow` keeps `log.follow` from switching
/// git's own rename tracking on.
pub const PATH_LOG_ARGS: &[&str] = &[
    "log",
    "-z",
    "-M",
    "--raw",
    "--numstat",
    "--no-abbrev",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--no-show-signature",
    "--no-follow",
    "--encoding=UTF-8",
    FORMAT,
];

/// `git diff-tree` arguments that print the merges given on stdin (one
/// hash per line) as the same records, each diffed against its first
/// parent, as everywhere in the app; the paths follow `--`.
pub const MERGE_DIFF_ARGS: &[&str] = &[
    "diff-tree",
    "--stdin",
    "-r",
    "-z",
    "-M",
    "--raw",
    "--numstat",
    "--no-abbrev",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--encoding=UTF-8",
    "--diff-merges=first-parent",
    FORMAT,
];

/// What a commit did to one of the paths.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathFile {
    pub change: Change,
    /// The path after the commit (before it, for a deletion).
    pub path: PathBuf,
    /// Source of a rename or copy.
    pub original_path: Option<PathBuf>,
    /// Lines added and removed; `None` for a binary file.
    pub stats: Option<(u32, u32)>,
}

/// A commit that changed some of the paths.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathCommit {
    pub oid: String,
    pub parents: Vec<String>,
    pub author: String,
    pub email: String,
    /// `Co-authored-by` identities (name, email), without the author.
    pub coauthors: Vec<(String, String)>,
    /// Author time, unix seconds.
    pub time: i64,
    pub subject: String,
    /// What it changed among the paths, against its first parent (empty
    /// for a merge until its diff is read).
    pub files: Vec<PathFile>,
}

impl PathCommit {
    /// Whether git printed no diff for it (see [`MERGE_DIFF_ARGS`]).
    pub fn is_unread_merge(&self) -> bool {
        self.parents.len() > 1 && self.files.is_empty()
    }

    /// Parses one record, with or without its leading mark.
    pub fn parse(record: &[u8]) -> Result<Self, ParseError> {
        let record = record.strip_prefix(&[RECORD_MARK]).unwrap_or(record);
        let (header, diff) = match record.iter().position(|&b| b == 0) {
            Some(end) => (&record[..end], &record[end + 1..]),
            None => (record, &[][..]),
        };
        let fields: Vec<&[u8]> = header.splitn(7, |&b| b == FIELD_SEP).collect();
        let &[oid, parents, author, email, time, trailers, subject] = fields.as_slice() else {
            return Err(ParseError::new(
                WHAT,
                format!("commit record has {} fields, expected 7", fields.len()),
            ));
        };
        let oid = String::from_utf8_lossy(oid).into_owned();
        if oid.is_empty() || !oid.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(ParseError::new(WHAT, format!("invalid object id `{oid}`")));
        }
        let email = String::from_utf8_lossy(email).into_owned();
        let trailers = String::from_utf8_lossy(trailers);
        let coauthors = distinct_coauthors(trailers.split(COAUTHOR_SEP), &email)
            .into_iter()
            .map(|(name, email)| (name.to_owned(), email.to_owned()))
            .collect();
        Ok(Self {
            oid,
            parents: String::from_utf8_lossy(parents)
                .split_whitespace()
                .map(str::to_owned)
                .collect(),
            author: String::from_utf8_lossy(author).into_owned(),
            email,
            coauthors,
            time: String::from_utf8_lossy(time).trim().parse().unwrap_or(0),
            subject: String::from_utf8_lossy(subject).trim_end().to_owned(),
            files: parse_files(diff)?,
        })
    }
}

/// The raw and numstat entries after a commit's fields.
fn parse_files(diff: &[u8]) -> Result<Vec<PathFile>, ParseError> {
    let start = diff.iter().position(|&b| b != b'\n').unwrap_or(diff.len());
    let mut files: Vec<PathFile> = Vec::new();
    let mut tokens = diff[start..].split(|&b| b == 0).filter(|t| !t.is_empty());
    while let Some(token) = tokens.next() {
        let mut path = |what: &str| {
            tokens
                .next()
                .map(git_path)
                .ok_or_else(|| ParseError::new(WHAT, format!("{what} without a path")))
        };
        if token.first() == Some(&b':') {
            let status = token.rsplit(|&b| b == b' ').next().unwrap_or_default();
            let change = match status.first() {
                Some(b'M') => Change::Modified,
                Some(b'A') => Change::Added,
                Some(b'D') => Change::Deleted,
                Some(b'R') => Change::Renamed,
                Some(b'C') => Change::Copied,
                Some(b'T') => Change::TypeChanged,
                _ => {
                    return Err(ParseError::new(
                        WHAT,
                        format!("unknown file status `{}`", String::from_utf8_lossy(token)),
                    ))
                }
            };
            let (original_path, path) = if matches!(change, Change::Renamed | Change::Copied) {
                let from = path("file status")?;
                (Some(from), path("file status")?)
            } else {
                (None, path("file status")?)
            };
            files.push(PathFile {
                change,
                path,
                original_path,
                stats: None,
            });
            continue;
        }
        let mut parts = token.splitn(3, |&b| b == b'\t');
        let (Some(added), Some(removed), Some(name)) = (parts.next(), parts.next(), parts.next())
        else {
            return Err(ParseError::new(
                WHAT,
                format!("unexpected entry `{}`", String::from_utf8_lossy(token)),
            ));
        };
        let name = if name.is_empty() {
            path("line counts")?;
            path("line counts")?
        } else {
            git_path(name)
        };
        let count = |bytes: &[u8]| String::from_utf8_lossy(bytes).parse::<u32>().ok();
        let stats = count(added).zip(count(removed));
        if let Some(file) = files.iter_mut().find(|f| f.path == name) {
            file.stats = stats;
        }
    }
    Ok(files)
}

/// Splits the stream into records, across arbitrary chunk boundaries.
#[derive(Debug, Default)]
pub struct PathLogSplitter {
    pending: Vec<u8>,
    /// Bytes of `pending` already searched for a boundary.
    scanned: usize,
}

impl PathLogSplitter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds `chunk` and hands every complete record to `sink`.
    pub fn feed<E>(
        &mut self,
        chunk: &[u8],
        mut sink: impl FnMut(&[u8]) -> Result<(), E>,
    ) -> Result<(), E> {
        self.pending.extend_from_slice(chunk);
        let mut start = 0;
        // A boundary is NUL then the mark; the NUL may be the last byte seen.
        let mut at = self.scanned.max(1);
        while at < self.pending.len() {
            if self.pending[at] == RECORD_MARK && self.pending[at - 1] == 0 {
                sink(&self.pending[start..at])?;
                start = at;
            }
            at += 1;
        }
        self.pending.drain(..start);
        self.scanned = self.pending.len();
        Ok(())
    }

    /// Hands over the last record, once the stream ended.
    pub fn finish<E>(self, mut sink: impl FnMut(&[u8]) -> Result<(), E>) -> Result<(), E> {
        if self.pending.iter().any(|&b| b != b'\n') {
            sink(&self.pending)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const C: &str = "cccccccccccccccccccccccccccccccccccccccc";

    /// A record as git prints it: the fields, then the diff entries.
    fn record(fields: &[&str], diff: &[&str]) -> Vec<u8> {
        let mut out = vec![RECORD_MARK];
        out.extend_from_slice(fields.join("\x1f").as_bytes());
        out.push(0);
        if !diff.is_empty() {
            out.push(b'\n');
            for entry in diff {
                out.extend_from_slice(entry.as_bytes());
                out.push(0);
            }
        }
        out
    }

    fn raw(status: &str) -> String {
        format!(":100644 100644 {A} {B} {status}")
    }

    fn parse_all(stream: &[u8], chunk: usize) -> Vec<PathCommit> {
        let mut commits = Vec::new();
        let mut splitter = PathLogSplitter::new();
        let mut push = |record: &[u8]| {
            commits.push(PathCommit::parse(record)?);
            Ok::<(), ParseError>(())
        };
        for part in stream.chunks(chunk) {
            splitter.feed(part, &mut push).expect("feed");
        }
        splitter.finish(&mut push).expect("finish");
        commits
    }

    #[test]
    fn parses_a_modification_with_its_line_counts() {
        let bytes = record(
            &[
                A,
                B,
                "Ann",
                "ann@example.com",
                "1700000000",
                "",
                "Edit the file",
            ],
            &[&raw("M"), "src/a b.rs", "12\t3\tsrc/a b.rs"],
        );
        let commit = PathCommit::parse(&bytes).expect("parse");
        assert_eq!(commit.oid, A);
        assert_eq!(commit.parents, vec![B.to_owned()]);
        assert_eq!(commit.author, "Ann");
        assert_eq!(commit.email, "ann@example.com");
        assert_eq!(commit.time, 1_700_000_000);
        assert_eq!(commit.subject, "Edit the file");
        assert_eq!(
            commit.files,
            vec![PathFile {
                change: Change::Modified,
                path: PathBuf::from("src/a b.rs"),
                original_path: None,
                stats: Some((12, 3)),
            }]
        );
    }

    #[test]
    fn parses_a_rename_with_both_names() {
        let bytes = record(
            &[A, B, "Ann", "ann@example.com", "1", "", "Move it"],
            &[
                &raw("R075"),
                "old name.txt",
                "nuovo è.txt",
                "1\t1\t",
                "old name.txt",
                "nuovo è.txt",
            ],
        );
        let commit = PathCommit::parse(&bytes).expect("parse");
        assert_eq!(
            commit.files,
            vec![PathFile {
                change: Change::Renamed,
                path: PathBuf::from("nuovo è.txt"),
                original_path: Some(PathBuf::from("old name.txt")),
                stats: Some((1, 1)),
            }]
        );
    }

    #[test]
    fn a_binary_file_has_no_line_counts() {
        let bytes = record(
            &[A, "", "Ann", "ann@example.com", "1", "", "Add a picture"],
            &[&raw("A"), "logo.png", "-\t-\tlogo.png"],
        );
        let commit = PathCommit::parse(&bytes).expect("parse");
        assert!(commit.parents.is_empty());
        assert_eq!(commit.files[0].change, Change::Added);
        assert_eq!(commit.files[0].stats, None);
    }

    #[test]
    fn a_merge_keeps_both_parents_and_its_first_parent_diff() {
        let parents = format!("{B} {C}");
        let bytes = record(
            &[A, &parents, "Ann", "ann@example.com", "1", "", "Merge side"],
            &[&raw("M"), "a.txt", "2\t0\ta.txt"],
        );
        let commit = PathCommit::parse(&bytes).expect("parse");
        assert_eq!(commit.parents, vec![B.to_owned(), C.to_owned()]);
        assert_eq!(commit.files[0].stats, Some((2, 0)));
    }

    #[test]
    fn co_authors_leave_the_author_out() {
        let trailers = "Bo <bo@example.com>\x1dAnn <ann@example.com>\x1dCy <cy@example.com>";
        let bytes = record(
            &[A, B, "Ann", "ann@example.com", "1", trailers, "Pair up"],
            &[],
        );
        let commit = PathCommit::parse(&bytes).expect("parse");
        assert_eq!(
            commit.coauthors,
            vec![
                ("Bo".to_owned(), "bo@example.com".to_owned()),
                ("Cy".to_owned(), "cy@example.com".to_owned()),
            ]
        );
        assert!(commit.files.is_empty());
    }

    #[test]
    fn several_entries_of_one_commit_are_all_listed() {
        let bytes = record(
            &[A, B, "Ann", "ann@example.com", "1", "", "Two files"],
            &[
                &raw("M"),
                "a.txt",
                &raw("D"),
                "b.txt",
                "1\t0\ta.txt",
                "0\t9\tb.txt",
            ],
        );
        let commit = PathCommit::parse(&bytes).expect("parse");
        let got: Vec<_> = commit.files.iter().map(|f| (f.change, f.stats)).collect();
        assert_eq!(
            got,
            vec![
                (Change::Modified, Some((1, 0))),
                (Change::Deleted, Some((0, 9)))
            ]
        );
    }

    #[test]
    fn records_split_across_chunks_parse_the_same() {
        let mut stream = record(
            &[
                A,
                B,
                "Ann",
                "ann@example.com",
                "3",
                "",
                "Third \x1e odd subject",
            ],
            &[&raw("M"), "a.txt", "1\t0\ta.txt"],
        );
        stream.extend(record(
            &[B, C, "Bo", "bo@example.com", "2", "", "Second"],
            &[],
        ));
        stream.extend(record(
            &[C, "", "Cy", "cy@example.com", "1", "", "First"],
            &[&raw("A"), "a.txt", "3\t0\ta.txt"],
        ));
        let whole = parse_all(&stream, stream.len());
        assert_eq!(whole.len(), 3);
        assert_eq!(whole[0].subject, "Third \x1e odd subject");
        assert_eq!(whole[1].subject, "Second");
        assert!(whole[1].files.is_empty());
        assert_eq!(whole[2].files[0].change, Change::Added);
        for chunk in [1, 2, 3, 7, 64] {
            assert_eq!(parse_all(&stream, chunk), whole, "chunks of {chunk}");
        }
    }

    #[test]
    fn an_empty_stream_has_no_records() {
        assert!(parse_all(b"", 8).is_empty());
    }

    #[test]
    fn a_short_record_is_an_error() {
        let bytes = record(&[A, B, "Ann"], &[]);
        assert!(PathCommit::parse(&bytes).is_err());
        let bytes = record(
            &[
                "not a hash",
                B,
                "Ann",
                "ann@example.com",
                "1",
                "",
                "Subject",
            ],
            &[],
        );
        assert!(PathCommit::parse(&bytes).is_err());
    }
}
