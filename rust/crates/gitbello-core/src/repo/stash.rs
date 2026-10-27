//! `git stash list`, and shelves (PLAN §4 Shelves): stashes tied to a
//! branch, identified by their commit.

use std::collections::HashSet;
use std::path::PathBuf;

use super::{text, Change, ParseError};

pub const STASH_LIST_ARGS: &[&str] = &["stash", "list", "-z", "--format=%gd%x1f%H%x1f%ct%x1f%gs"];

const WHAT: &str = "stash list";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StashEntry {
    /// `n` in `stash@{n}`.
    pub index: usize,
    pub oid: String,
    /// Unix seconds.
    pub time: i64,
    /// The stash message (`On main: <message>`) without the prefix.
    pub message: String,
    /// Branch the stash was made on, when git recorded it.
    pub branch: Option<String>,
}

pub fn parse_stash_list(output: &[u8]) -> Result<Vec<StashEntry>, ParseError> {
    let mut entries = Vec::new();
    for record in output
        .split(|&b| b == 0)
        .map(|r| r.strip_prefix(b"\n").unwrap_or(r))
        .filter(|r| !r.is_empty())
    {
        let fields: Vec<String> = record.split(|&b| b == 0x1f).map(text).collect();
        let [selector, oid, time, subject] = fields.as_slice() else {
            return Err(ParseError::new(
                WHAT,
                format!("expected 4 fields in `{}`", text(record)),
            ));
        };
        let index = selector
            .strip_prefix("stash@{")
            .and_then(|s| s.strip_suffix('}'))
            .and_then(|n| n.parse().ok())
            .ok_or_else(|| ParseError::new(WHAT, format!("bad selector `{selector}`")))?;
        let time = time
            .parse()
            .map_err(|_| ParseError::new(WHAT, format!("bad time `{time}`")))?;
        let (branch, message) = split_subject(subject);
        entries.push(StashEntry {
            index,
            oid: oid.clone(),
            time,
            message,
            branch,
        });
    }
    Ok(entries)
}

/// `On <branch>: <message>` (named) or `WIP on <branch>: <hash> <subject>`.
fn split_subject(subject: &str) -> (Option<String>, String) {
    let rest = subject
        .strip_prefix("WIP on ")
        .or_else(|| subject.strip_prefix("On "));
    match rest.and_then(|r| r.split_once(": ")) {
        Some((branch, message)) => (Some(branch.to_owned()), message.to_owned()),
        None => (None, subject.to_owned()),
    }
}

/// Messages of shelves made by gitbello: `<prefix><branch>: <name>`.
pub const SHELF_PREFIX: &str = "gitbello-shelf: ";
/// Shelves made when switching branch with "leave them".
pub const AUTO_SHELF_PREFIX: &str = "gitbello-shelf (auto): ";

/// A stash seen as a shelf of a branch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Shelf {
    /// The stash commit: a shelf's identity (indices shift).
    pub oid: String,
    /// The branch it belongs to, when known.
    pub branch: Option<String>,
    pub name: String,
    /// Made automatically when switching branch.
    pub auto: bool,
    /// Made by gitbello (else a stash made elsewhere).
    pub made_here: bool,
    /// Unix seconds.
    pub time: i64,
    /// The stash's reflog message, to store it again (rename, undo).
    pub subject: String,
}

/// The stash message of a shelf of `branch` called `name`.
pub fn shelf_message(branch: &str, name: &str, auto: bool) -> String {
    let prefix = if auto {
        AUTO_SHELF_PREFIX
    } else {
        SHELF_PREFIX
    };
    format!("{prefix}{branch}: {name}")
}

/// The stash list as shelves, newest first; an entry stored twice (in the
/// middle of a rename) is listed once.
pub fn shelves(entries: &[StashEntry]) -> Vec<Shelf> {
    let mut seen = HashSet::new();
    let mut out = Vec::with_capacity(entries.len());
    for entry in entries {
        if !seen.insert(entry.oid.as_str()) {
            continue;
        }
        let subject = match &entry.branch {
            Some(branch) => format!("On {branch}: {}", entry.message),
            None => entry.message.clone(),
        };
        let ours = [(AUTO_SHELF_PREFIX, true), (SHELF_PREFIX, false)]
            .into_iter()
            .find_map(|(prefix, auto)| Some((entry.message.strip_prefix(prefix)?, auto)));
        let shelf = match ours.and_then(|(rest, auto)| Some((rest.split_once(": ")?, auto))) {
            Some(((branch, name), auto)) => Shelf {
                oid: entry.oid.clone(),
                branch: Some(branch.to_owned()),
                name: name.to_owned(),
                auto,
                made_here: true,
                time: entry.time,
                subject,
            },
            None => Shelf {
                oid: entry.oid.clone(),
                branch: entry.branch.clone(),
                name: entry.message.clone(),
                auto: false,
                made_here: false,
                time: entry.time,
                subject,
            },
        };
        out.push(shelf);
    }
    out
}

/// A file in a shelf.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShelfFile {
    pub change: Change,
    pub path: PathBuf,
    pub original_path: Option<PathBuf>,
    /// Untracked when shelved (stored in the stash's third parent).
    pub untracked: bool,
    /// The worktree matches base; preview the staged version instead.
    pub index_only: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_named_and_wip_stashes() {
        let out = "stash@{0}\x1faaaa\x1f1700000100\x1fOn feature/x: half-done refactor\0\
                   stash@{1}\x1fbbbb\x1f1700000000\x1fWIP on main: 1234567 Add parser\0";
        let entries = parse_stash_list(out.as_bytes()).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].index, 0);
        assert_eq!(entries[0].branch.as_deref(), Some("feature/x"));
        assert_eq!(entries[0].message, "half-done refactor");
        assert_eq!(entries[1].index, 1);
        assert_eq!(entries[1].branch.as_deref(), Some("main"));
        assert_eq!(entries[1].message, "1234567 Add parser");
        assert_eq!(entries[1].time, 1_700_000_000);
    }

    #[test]
    fn keeps_unrecognised_subjects_and_rejects_bad_records() {
        let entries = parse_stash_list(b"stash@{3}\x1fcc\x1f1\x1fautostash\0").unwrap();
        assert_eq!(
            (entries[0].branch.as_ref(), entries[0].message.as_str()),
            (None, "autostash")
        );
        assert!(parse_stash_list(b"").unwrap().is_empty());
        assert!(parse_stash_list(b"stash@{x}\x1fa\x1f1\x1fs\0").is_err());
        assert!(parse_stash_list(b"stash@{0}\x1fa\0").is_err());
    }

    fn entry(index: usize, oid: &str, subject: &str) -> StashEntry {
        let (branch, message) = split_subject(subject);
        StashEntry {
            index,
            oid: oid.into(),
            time: 1,
            message,
            branch,
        }
    }

    #[test]
    fn reads_shelves_and_stashes_made_elsewhere() {
        let list = [
            entry(
                0,
                "aa",
                &format!("On main: {}", shelf_message("main", "half done", false)),
            ),
            entry(
                1,
                "bb",
                &shelf_message("feature/x", "Left when switching to main", true),
            ),
            entry(2, "aa", "On main: older copy"),
            entry(3, "cc", "WIP on main: 1234567 Add parser"),
            entry(4, "dd", "autostash"),
        ];
        let shelves = shelves(&list);
        assert_eq!(shelves.len(), 4, "an entry stored twice is listed once");
        assert_eq!(
            (
                shelves[0].branch.as_deref(),
                shelves[0].name.as_str(),
                shelves[0].auto,
                shelves[0].made_here
            ),
            (Some("main"), "half done", false, true)
        );
        assert_eq!(
            (
                shelves[1].branch.as_deref(),
                shelves[1].auto,
                shelves[1].subject.as_str()
            ),
            (
                Some("feature/x"),
                true,
                "gitbello-shelf (auto): feature/x: Left when switching to main"
            )
        );
        assert_eq!(
            (
                shelves[2].branch.as_deref(),
                shelves[2].name.as_str(),
                shelves[2].made_here
            ),
            (Some("main"), "1234567 Add parser", false)
        );
        assert_eq!(shelves[2].subject, "On main: 1234567 Add parser");
        assert_eq!(
            (shelves[3].branch.as_deref(), shelves[3].name.as_str()),
            (None, "autostash")
        );
    }
}
