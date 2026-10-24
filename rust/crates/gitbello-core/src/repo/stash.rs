//! `git stash list`.

use super::{text, ParseError};

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
}
