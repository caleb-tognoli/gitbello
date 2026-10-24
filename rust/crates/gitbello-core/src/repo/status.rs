//! `git status --porcelain=v2 -z --branch --show-stash`.

use std::path::PathBuf;

use super::{git_path, text, ParseError};

pub const STATUS_ARGS: &[&str] = &[
    "status",
    "--porcelain=v2",
    "-z",
    "--branch",
    "--show-stash",
    "--untracked-files=all",
];

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Head {
    Branch(String),
    Detached,
    /// No `# branch.head` header (should not happen with `--branch`).
    #[default]
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RepoStatus {
    pub head: Head,
    /// Commit HEAD points at; `None` on an unborn branch.
    pub oid: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    pub stash_count: u32,
    pub changes: Vec<FileChange>,
}

impl RepoStatus {
    pub fn is_clean(&self) -> bool {
        self.changes
            .iter()
            .all(|c| matches!(c.state, FileState::Ignored))
    }

    pub fn has_conflicts(&self) -> bool {
        self.changes
            .iter()
            .any(|c| matches!(c.state, FileState::Unmerged(_)))
    }
}

/// One side of a tracked change (index or working tree), from the `XY` codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Change {
    Unmodified,
    Modified,
    TypeChanged,
    Added,
    Deleted,
    Renamed,
    Copied,
}

impl Change {
    fn from_code(code: u8) -> Option<Self> {
        Some(match code {
            b'.' => Self::Unmodified,
            b'M' => Self::Modified,
            b'T' => Self::TypeChanged,
            b'A' => Self::Added,
            b'D' => Self::Deleted,
            b'R' => Self::Renamed,
            b'C' => Self::Copied,
            _ => return None,
        })
    }
}

/// Kind of unmerged entry, from the `XY` codes of a `u` line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Conflict {
    BothDeleted,
    AddedByUs,
    DeletedByThem,
    AddedByThem,
    DeletedByUs,
    BothAdded,
    BothModified,
}

impl Conflict {
    fn from_codes(xy: &[u8]) -> Option<Self> {
        Some(match xy {
            b"DD" => Self::BothDeleted,
            b"AU" => Self::AddedByUs,
            b"UD" => Self::DeletedByThem,
            b"UA" => Self::AddedByThem,
            b"DU" => Self::DeletedByUs,
            b"AA" => Self::BothAdded,
            b"UU" => Self::BothModified,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FileState {
    Tracked { index: Change, worktree: Change },
    Unmerged(Conflict),
    Untracked,
    Ignored,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileChange {
    /// Repository-relative path, `/`-separated as git prints it.
    pub path: PathBuf,
    /// Source path of a rename or copy.
    pub original_path: Option<PathBuf>,
    pub state: FileState,
    /// Similarity score of a rename or copy (0–100).
    pub score: Option<u8>,
    pub submodule: bool,
}

impl FileChange {
    /// Has changes staged in the index.
    pub fn is_staged(&self) -> bool {
        matches!(self.state, FileState::Tracked { index, .. } if index != Change::Unmodified)
    }

    /// Has working-tree changes not yet staged (including untracked files).
    pub fn is_unstaged(&self) -> bool {
        match self.state {
            FileState::Tracked { worktree, .. } => worktree != Change::Unmodified,
            FileState::Untracked => true,
            FileState::Unmerged(_) | FileState::Ignored => false,
        }
    }
}

const WHAT: &str = "status";

pub fn parse_status(output: &[u8]) -> Result<RepoStatus, ParseError> {
    let mut status = RepoStatus::default();
    let mut records = output.split(|&b| b == 0).filter(|r| !r.is_empty());
    while let Some(record) = records.next() {
        match record.first() {
            Some(b'#') => parse_header(record, &mut status)?,
            Some(b'1') => status.changes.push(parse_ordinary(record)?),
            Some(b'2') => {
                let mut change = parse_renamed(record)?;
                let original = records
                    .next()
                    .ok_or_else(|| ParseError::new(WHAT, "rename without original path"))?;
                change.original_path = Some(git_path(original));
                status.changes.push(change);
            }
            Some(b'u') => status.changes.push(parse_unmerged(record)?),
            Some(b'?') => status.changes.push(simple(record, FileState::Untracked)?),
            Some(b'!') => status.changes.push(simple(record, FileState::Ignored)?),
            _ => {
                return Err(ParseError::new(
                    WHAT,
                    format!("unknown entry `{}`", text(record)),
                ))
            }
        }
    }
    Ok(status)
}

fn parse_header(record: &[u8], status: &mut RepoStatus) -> Result<(), ParseError> {
    let line = text(record);
    let mut parts = line.splitn(3, ' ');
    let _hash = parts.next();
    let key = parts.next().unwrap_or_default();
    let value = parts.next().unwrap_or_default();
    match key {
        "branch.oid" => status.oid = (value != "(initial)").then(|| value.to_owned()),
        "branch.head" => {
            status.head = if value == "(detached)" {
                Head::Detached
            } else {
                Head::Branch(value.to_owned())
            }
        }
        "branch.upstream" => status.upstream = Some(value.to_owned()),
        "branch.ab" => {
            let mut nums = value.split(' ');
            let ahead = nums.next().and_then(|a| a.strip_prefix('+'));
            let behind = nums.next().and_then(|b| b.strip_prefix('-'));
            match (ahead.map(str::parse), behind.map(str::parse)) {
                (Some(Ok(a)), Some(Ok(b))) => {
                    status.ahead = a;
                    status.behind = b;
                }
                _ => return Err(ParseError::new(WHAT, format!("bad branch.ab `{value}`"))),
            }
        }
        "stash" => {
            status.stash_count = value
                .parse()
                .map_err(|_| ParseError::new(WHAT, format!("bad stash count `{value}`")))?
        }
        // Unknown headers are allowed by the format; ignore them.
        _ => {}
    }
    Ok(())
}

/// Splits `record` into `n` space-separated fields; the last keeps any spaces
/// (it is the path).
fn fields(record: &[u8], n: usize) -> Result<Vec<&[u8]>, ParseError> {
    let parts: Vec<&[u8]> = record.splitn(n, |&b| b == b' ').collect();
    if parts.len() == n {
        Ok(parts)
    } else {
        Err(ParseError::new(
            WHAT,
            format!("expected {n} fields in `{}`", text(record)),
        ))
    }
}

fn tracked_state(xy: &[u8]) -> Result<FileState, ParseError> {
    match xy {
        [x, y] => match (Change::from_code(*x), Change::from_code(*y)) {
            (Some(index), Some(worktree)) => Ok(FileState::Tracked { index, worktree }),
            _ => Err(ParseError::new(WHAT, format!("bad XY `{}`", text(xy)))),
        },
        _ => Err(ParseError::new(WHAT, format!("bad XY `{}`", text(xy)))),
    }
}

fn is_submodule(sub: &[u8]) -> bool {
    sub.first() == Some(&b'S')
}

// 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
fn parse_ordinary(record: &[u8]) -> Result<FileChange, ParseError> {
    let f = fields(record, 9)?;
    Ok(FileChange {
        path: git_path(f[8]),
        original_path: None,
        state: tracked_state(f[1])?,
        score: None,
        submodule: is_submodule(f[2]),
    })
}

// 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>
fn parse_renamed(record: &[u8]) -> Result<FileChange, ParseError> {
    let f = fields(record, 10)?;
    let score = text(f[8].get(1..).unwrap_or_default()).parse().ok();
    Ok(FileChange {
        path: git_path(f[9]),
        original_path: None,
        state: tracked_state(f[1])?,
        score,
        submodule: is_submodule(f[2]),
    })
}

// u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
fn parse_unmerged(record: &[u8]) -> Result<FileChange, ParseError> {
    let f = fields(record, 11)?;
    let conflict = Conflict::from_codes(f[1])
        .ok_or_else(|| ParseError::new(WHAT, format!("bad unmerged XY `{}`", text(f[1]))))?;
    Ok(FileChange {
        path: git_path(f[10]),
        original_path: None,
        state: FileState::Unmerged(conflict),
        score: None,
        submodule: is_submodule(f[2]),
    })
}

// ? <path> / ! <path>
fn simple(record: &[u8], state: FileState) -> Result<FileChange, ParseError> {
    let path = record
        .get(2..)
        .filter(|p| !p.is_empty())
        .ok_or_else(|| ParseError::new(WHAT, format!("missing path in `{}`", text(record))))?;
    Ok(FileChange {
        path: git_path(path),
        original_path: None,
        state,
        score: None,
        submodule: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const Z: &str = "0000000000000000000000000000000000000000";

    fn captured() -> Vec<u8> {
        // Shape of `git status --porcelain=v2 -z --branch --show-stash` output.
        let records = [
            "# branch.oid 1f2e3d4c5b6a79881f2e3d4c5b6a79881f2e3d4c".to_owned(),
            "# branch.head feature/wörk".to_owned(),
            "# branch.upstream origin/feature/wörk".to_owned(),
            "# branch.ab +3 -1".to_owned(),
            "# stash 2".to_owned(),
            format!("1 .M N... 100644 100644 100644 {Z} {Z} src/main.rs"),
            format!("1 A. N... 000000 100644 100644 {Z} {Z} new file.txt"),
            format!("1 MD N... 100644 100644 000000 {Z} {Z} gone.txt"),
            format!("2 R. N... 100644 100644 100644 {Z} {Z} R87 dir/renamed name.txt"),
            "dir/old name.txt".to_owned(),
            format!("1 .M SC.. 160000 160000 160000 {Z} {Z} vendor/lib"),
            format!("u UU N... 100644 100644 100644 100644 {Z} {Z} {Z} both.txt"),
            format!("u DU N... 100644 000000 100644 100644 {Z} {Z} {Z} deleted by us.txt"),
            "? untracked/ünïcode.txt".to_owned(),
            "! target/".to_owned(),
        ];
        let mut out = Vec::new();
        for record in records {
            out.extend_from_slice(record.as_bytes());
            out.push(0);
        }
        out
    }

    #[test]
    fn parses_headers() {
        let status = parse_status(&captured()).unwrap();
        assert_eq!(status.head, Head::Branch("feature/wörk".into()));
        assert_eq!(status.oid.as_deref().map(str::len), Some(40));
        assert_eq!(status.upstream.as_deref(), Some("origin/feature/wörk"));
        assert_eq!((status.ahead, status.behind), (3, 1));
        assert_eq!(status.stash_count, 2);
    }

    #[test]
    fn parses_every_entry_kind() {
        let status = parse_status(&captured()).unwrap();
        let by_path = |p: &str| {
            status
                .changes
                .iter()
                .find(|c| c.path == std::path::Path::new(p))
                .unwrap_or_else(|| panic!("missing {p}"))
        };
        let tracked = |index, worktree| FileState::Tracked { index, worktree };

        assert_eq!(
            by_path("src/main.rs").state,
            tracked(Change::Unmodified, Change::Modified)
        );
        assert!(by_path("src/main.rs").is_unstaged() && !by_path("src/main.rs").is_staged());
        assert_eq!(
            by_path("new file.txt").state,
            tracked(Change::Added, Change::Unmodified)
        );
        assert_eq!(
            by_path("gone.txt").state,
            tracked(Change::Modified, Change::Deleted)
        );

        let renamed = by_path("dir/renamed name.txt");
        assert_eq!(renamed.state, tracked(Change::Renamed, Change::Unmodified));
        assert_eq!(
            renamed.original_path,
            Some(PathBuf::from("dir/old name.txt"))
        );
        assert_eq!(renamed.score, Some(87));

        assert!(by_path("vendor/lib").submodule);
        assert_eq!(
            by_path("both.txt").state,
            FileState::Unmerged(Conflict::BothModified)
        );
        assert_eq!(
            by_path("deleted by us.txt").state,
            FileState::Unmerged(Conflict::DeletedByUs)
        );
        assert_eq!(by_path("untracked/ünïcode.txt").state, FileState::Untracked);
        assert_eq!(by_path("target/").state, FileState::Ignored);
        assert_eq!(status.changes.len(), 9);
        assert!(status.has_conflicts() && !status.is_clean());
    }

    #[test]
    fn parses_unborn_and_detached_heads() {
        let unborn = parse_status(b"# branch.oid (initial)\0# branch.head main\0").unwrap();
        assert_eq!(unborn.oid, None);
        assert_eq!(unborn.head, Head::Branch("main".into()));
        assert!(unborn.is_clean());

        let detached = parse_status(b"# branch.oid abc\0# branch.head (detached)\0").unwrap();
        assert_eq!(detached.head, Head::Detached);
        assert_eq!(detached.upstream, None);
    }

    #[test]
    fn rejects_malformed_output() {
        assert!(parse_status(b"1 .M N... 100644\0").is_err());
        assert!(parse_status(format!("2 R. N... 1 1 1 {Z} {Z} R100 a").as_bytes()).is_err());
        assert!(parse_status(b"x what\0").is_err());
        assert!(parse_status(b"# branch.ab 3 1\0").is_err());
        assert!(parse_status(format!("u ZZ N... 1 1 1 1 {Z} {Z} {Z} a\0").as_bytes()).is_err());
    }
}
