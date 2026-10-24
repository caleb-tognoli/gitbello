//! One commit's details: `git show -s --format=...` for the header and
//! `git diff-tree -r -z -M --name-status` for its files.

use std::path::PathBuf;

use super::Change;
use super::{git_path, text, ParseError};

/// `git show -s -z` format: NUL-separated fields, the raw message last.
pub const COMMIT_SHOW_FORMAT: &str =
    "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%B";

const WHAT: &str = "commit";

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CommitDetails {
    pub oid: String,
    pub parents: Vec<String>,
    pub author_name: String,
    pub author_email: String,
    /// Unix seconds.
    pub author_time: i64,
    pub committer_name: String,
    pub committer_email: String,
    pub committer_time: i64,
    /// Full message as written (summary, blank line, body).
    pub message: String,
    /// Files changed against the first parent (all files for a root commit).
    pub files: Vec<CommitFile>,
}

impl CommitDetails {
    /// First line of the message.
    pub fn summary(&self) -> &str {
        self.message.lines().next().unwrap_or_default().trim_end()
    }

    /// The message after the summary, without surrounding blank lines.
    pub fn body(&self) -> &str {
        let mut parts = self.message.splitn(2, '\n');
        parts.next();
        parts
            .next()
            .unwrap_or_default()
            .trim_matches(|c: char| c == '\n' || c == '\r')
            .trim_end()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitFile {
    pub change: Change,
    pub path: PathBuf,
    /// Source of a rename or copy.
    pub original_path: Option<PathBuf>,
}

/// Parses `git show -s` output in [`COMMIT_SHOW_FORMAT`] (files left empty).
pub fn parse_commit_header(output: &[u8]) -> Result<CommitDetails, ParseError> {
    let mut fields = output.splitn(9, |&b| b == 0);
    let mut next = |name: &str| {
        fields
            .next()
            .map(text)
            .ok_or_else(|| ParseError::new(WHAT, format!("missing {name}")))
    };
    let oid = next("hash")?;
    let parents = next("parents")?;
    let author_name = next("author")?;
    let author_email = next("author email")?;
    let author_time = next("author time")?;
    let committer_name = next("committer")?;
    let committer_email = next("committer email")?;
    let committer_time = next("committer time")?;
    let message = next("message")?;
    let time = |t: &str| {
        t.trim()
            .parse::<i64>()
            .map_err(|_| ParseError::new(WHAT, format!("bad time `{t}`")))
    };
    Ok(CommitDetails {
        oid: oid.trim().to_owned(),
        parents: parents.split_whitespace().map(str::to_owned).collect(),
        author_name,
        author_email,
        author_time: time(&author_time)?,
        committer_name,
        committer_email,
        committer_time: time(&committer_time)?,
        message: message.trim_end_matches('\0').to_owned(),
        files: Vec::new(),
    })
}

/// Parses `git diff-tree -r -z --name-status` output.
pub fn parse_name_status(output: &[u8]) -> Result<Vec<CommitFile>, ParseError> {
    let mut files = Vec::new();
    let mut fields = output.split(|&b| b == 0).filter(|f| !f.is_empty());
    while let Some(status) = fields.next() {
        let code = status.first().copied().unwrap_or(b'?');
        let change = match code {
            b'M' => Change::Modified,
            b'A' => Change::Added,
            b'D' => Change::Deleted,
            b'R' => Change::Renamed,
            b'C' => Change::Copied,
            b'T' => Change::TypeChanged,
            _ => {
                return Err(ParseError::new(
                    WHAT,
                    format!("unknown file status `{}`", text(status)),
                ))
            }
        };
        let mut path = || {
            fields
                .next()
                .map(git_path)
                .ok_or_else(|| ParseError::new(WHAT, "file status without a path"))
        };
        let (original_path, path) = if matches!(change, Change::Renamed | Change::Copied) {
            let from = path()?;
            (Some(from), path()?)
        } else {
            (None, path()?)
        };
        files.push(CommitFile {
            change,
            path,
            original_path,
        });
    }
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Joins fields with NUL, as `%x00` in the format does.
    fn fields(parts: &[&str]) -> Vec<u8> {
        parts.join("\u{0}").into_bytes()
    }

    #[test]
    fn parses_the_header() {
        let out = fields(&[
            "abc123",
            "p1 p2",
            "Ada Lövelace",
            "ada@example.com",
            "1700000000",
            "Bob",
            "bob@example.com",
            "1700000060",
            "Fix it\n\nWhy it broke.\nMore.\n\n",
        ]);
        let c = parse_commit_header(&out).unwrap();
        assert_eq!(c.oid, "abc123");
        assert_eq!(c.parents, ["p1", "p2"]);
        assert_eq!(c.author_name, "Ada Lövelace");
        assert_eq!(
            (c.author_time, c.committer_time),
            (1_700_000_000, 1_700_000_060)
        );
        assert_eq!(c.summary(), "Fix it");
        assert_eq!(c.body(), "Why it broke.\nMore.");
        let root = parse_commit_header(&fields(&[
            "abc", "", "a", "a@x", "1", "a", "a@x", "1", "Only\n",
        ]))
        .unwrap();
        assert!(root.parents.is_empty());
        assert_eq!(root.body(), "");
        assert!(parse_commit_header(&fields(&["abc", "p", "a"])).is_err());
    }

    #[test]
    fn parses_name_status() {
        let out = fields(&[
            "M",
            "src/a.rs",
            "R087",
            "old name.txt",
            "new name.txt",
            "A",
            "dïr/n.txt",
            "D",
            "gone",
            "",
        ]);
        let files = parse_name_status(&out).unwrap();
        assert_eq!(files.len(), 4);
        assert_eq!(files[0].change, Change::Modified);
        assert_eq!(files[1].change, Change::Renamed);
        assert_eq!(files[1].original_path, Some(PathBuf::from("old name.txt")));
        assert_eq!(files[1].path, PathBuf::from("new name.txt"));
        assert_eq!(files[2].path, PathBuf::from("dïr/n.txt"));
        assert_eq!(files[3].change, Change::Deleted);
        assert!(parse_name_status(&fields(&["X", "f"])).is_err());
        assert!(parse_name_status(&fields(&["R100", "only-one"])).is_err());
        assert!(parse_name_status(b"").unwrap().is_empty());
    }
}
