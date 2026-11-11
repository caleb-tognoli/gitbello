//! Compare (PLAN M7.12): two states of a repository side by side. The left
//! side is the base and the right side what is compared, so diffs read
//! left → right. Either side is any revision git resolves; the right side can
//! also be the working copy (tracked changes and untracked files).
//!
//! *Since fork* diffs the sides' merge base against the right side (what it
//! added since it split off); *Exact* diffs the two trees. The git reads are
//! in [`crate::backend::GitBackend::compare`]; this module holds the model and
//! the parsing of their output.

use std::path::{Path, PathBuf};

use crate::diff::{CommitSide, DiffKind, DiffTarget};
use crate::repo::{git_path, Change};

/// The right side of a comparison.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum CompareSide {
    /// Any revision git resolves to a commit (branch, tag, hash, `HEAD~3`).
    Rev(String),
    /// The worktree's files: tracked changes and untracked files.
    WorkingCopy,
}

/// What the files and diffs of a comparison start from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CompareMode {
    /// From the merge base of the two sides.
    SinceFork,
    /// From the left side itself.
    Exact,
}

impl CompareMode {
    pub fn id(self) -> &'static str {
        match self {
            Self::SinceFork => "fork",
            Self::Exact => "exact",
        }
    }

    pub fn parse(id: &str) -> Option<Self> {
        match id {
            "fork" => Some(Self::SinceFork),
            "exact" => Some(Self::Exact),
            _ => None,
        }
    }
}

/// What to compare. `mode` `None` takes [`default_mode`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CompareRequest {
    pub left: String,
    pub right: CompareSide,
    pub mode: Option<CompareMode>,
}

/// What a side turned out to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SideKind {
    Branch,
    Remote,
    Tag,
    /// A hash or any other revision expression.
    Commit,
    WorkingCopy,
}

impl SideKind {
    pub fn id(self) -> &'static str {
        match self {
            Self::Branch => "branch",
            Self::Remote => "remote",
            Self::Tag => "tag",
            Self::Commit => "commit",
            Self::WorkingCopy => "working",
        }
    }

    /// The kind of a revision from its full ref name (`rev-parse
    /// --symbolic-full-name`; empty for hashes and expressions).
    pub fn from_full_name(name: &str) -> Self {
        if name.starts_with("refs/heads/") {
            Self::Branch
        } else if name.starts_with("refs/remotes/") {
            Self::Remote
        } else if name.starts_with("refs/tags/") {
            Self::Tag
        } else {
            Self::Commit
        }
    }
}

/// One resolved side.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedSide {
    /// As requested (empty for the working copy).
    pub spec: String,
    pub kind: SideKind,
    /// `refs/...` for a branch, remote branch or tag.
    pub full_name: Option<String>,
    /// The commit: the revision's, or HEAD's for the working copy (`None`
    /// on an unborn branch).
    pub oid: Option<String>,
    /// The commit's subject when the side is a plain commit (shown instead
    /// of its hash).
    pub subject: Option<String>,
}

impl ResolvedSide {
    /// A short name: the branch, `origin/x`, the tag, the revision as typed
    /// (a hash cut to 7 characters); empty for the working copy.
    pub fn name(&self) -> String {
        if let Some(full) = &self.full_name {
            for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] {
                if let Some(short) = full.strip_prefix(prefix) {
                    return short.to_owned();
                }
            }
        }
        if self.kind == SideKind::WorkingCopy {
            return String::new();
        }
        let spec = self.spec.trim();
        let is_hash = spec.len() >= 7 && spec.chars().all(|c| c.is_ascii_hexdigit());
        if is_hash {
            spec[..7].to_owned()
        } else {
            spec.to_owned()
        }
    }
}

/// Since the fork, whatever the sides (M7.12c: the view has no mode switch;
/// the full difference is asked for explicitly). Unrelated histories fall
/// back to exact when the comparison loads.
pub fn default_mode(_left: SideKind, _right: SideKind) -> CompareMode {
    CompareMode::SinceFork
}

/// A file that differs between the sides.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompareFile {
    pub change: Change,
    pub path: PathBuf,
    /// Source of a rename or copy.
    pub original_path: Option<PathBuf>,
    /// Lines added and removed; `None` for a binary file (or an untracked
    /// file too large to count).
    pub stats: Option<(u32, u32)>,
    /// A file git does not track yet (working copy only).
    pub untracked: bool,
}

/// Two sides, what the diffs start from and the files that differ.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Comparison {
    pub left: ResolvedSide,
    pub right: ResolvedSide,
    /// The mode in effect: Since fork falls back to Exact without a merge base.
    pub mode: CompareMode,
    pub default_mode: CompareMode,
    pub merge_base: Option<String>,
    /// The commit the diffs start from: the merge base or the left side.
    pub base: String,
    /// Commits reachable from only one side.
    pub only_right: u32,
    pub only_left: u32,
    /// Sorted by path.
    pub files: Vec<CompareFile>,
    pub additions: u64,
    pub deletions: u64,
    /// The commits only on the right side, then those only on the left,
    /// each newest first; at most [`COMMIT_LIST_LIMIT`].
    pub commits: Vec<CompareCommit>,
    /// More commits than listed.
    pub commits_truncated: bool,
}

impl Comparison {
    /// Whether Since fork can be chosen (the sides have a merge base).
    pub fn can_fork(&self) -> bool {
        self.merge_base.is_some()
    }

    /// The diff of `file`: the base against the right side's commit or the
    /// working tree.
    pub fn target(&self, file: &CompareFile) -> DiffTarget {
        let base = self.base.clone();
        let (kind, commit) = match (&self.right.kind, file.untracked) {
            (_, true) => (DiffKind::Untracked, None),
            (SideKind::WorkingCopy, false) => (
                DiffKind::Working,
                Some(CommitSide {
                    oid: base.clone(),
                    parent: Some(base),
                }),
            ),
            _ => (
                DiffKind::Commit,
                Some(CommitSide {
                    oid: self.right.oid.clone().unwrap_or_default(),
                    parent: Some(base),
                }),
            ),
        };
        DiffTarget {
            kind,
            path: file.path.clone(),
            original_path: file.original_path.clone(),
            commit,
        }
    }

    pub fn file(&self, path: &Path) -> Option<&CompareFile> {
        self.files.iter().find(|f| f.path == path)
    }

    /// Sums the files' line counts into the totals.
    pub fn count_lines(&mut self) {
        let (added, removed) = self
            .files
            .iter()
            .filter_map(|f| f.stats)
            .fold((0u64, 0u64), |(a, r), (fa, fr)| {
                (a + u64::from(fa), r + u64::from(fr))
            });
        self.additions = added;
        self.deletions = removed;
    }
}

/// Which side alone has a commit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OnlyOn {
    Left,
    Right,
}

/// A commit reachable from one side only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompareCommit {
    pub oid: String,
    pub subject: String,
    pub author: String,
    pub email: String,
    /// `Co-authored-by` identities (name, email), without the author.
    pub coauthors: Vec<(String, String)>,
    /// Author time, unix seconds.
    pub time: i64,
    pub only: OnlyOn,
    pub parents: u32,
    /// Reachable from HEAD (so cherry-picking it would apply nothing new).
    pub in_head: bool,
}

/// Commits listed per comparison (both sides together).
pub const COMMIT_LIST_LIMIT: usize = 2000;

/// The `git log` format [`parse_side_log`] reads: side mark, hash, parents,
/// author, author email, author time, `Co-authored-by` values (separated by
/// `\x1e`), subject.
pub const SIDE_LOG_FORMAT: &str = "--format=%m%x1f%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x1e)%x1f%s";

/// Commits from `git log -z --left-right` with [`SIDE_LOG_FORMAT`], right
/// side first (each in log order); boundary commits are left out.
/// `in_head` is false: the caller marks it.
pub fn parse_side_log(output: &[u8]) -> Vec<CompareCommit> {
    let mut right = Vec::new();
    let mut left = Vec::new();
    for record in output.split(|&b| b == 0) {
        let text = String::from_utf8_lossy(record);
        let text = text.trim_start_matches('\n');
        let fields: Vec<&str> = text.splitn(8, '\x1f').collect();
        let &[mark, oid, parents, author, email, time, trailers, subject] = fields.as_slice()
        else {
            continue;
        };
        let only = match mark {
            ">" => OnlyOn::Right,
            "<" => OnlyOn::Left,
            _ => continue,
        };
        let commit = CompareCommit {
            oid: oid.to_owned(),
            subject: subject.trim_end().to_owned(),
            author: author.to_owned(),
            email: email.to_owned(),
            coauthors: crate::repo::distinct_coauthors(trailers.split('\x1e'), email)
                .into_iter()
                .map(|(name, email)| (name.to_owned(), email.to_owned()))
                .collect(),
            time: time.trim().parse().unwrap_or(0),
            only,
            parents: u32::try_from(parents.split_whitespace().count()).unwrap_or(u32::MAX),
            in_head: false,
        };
        match only {
            OnlyOn::Right => right.push(commit),
            OnlyOn::Left => left.push(commit),
        }
    }
    right.extend(left);
    right
}

/// A comparison opened before, for the picker's Recent list (kept per
/// repository in its UI state).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecentComparison {
    pub left: String,
    pub right: CompareSide,
    pub mode: Option<CompareMode>,
    /// What to call each side when it is not its spec (a commit's subject),
    /// or empty.
    pub left_name: String,
    pub right_name: String,
}

/// Recent comparisons kept per repository.
pub const RECENT_LIMIT: usize = 5;

impl RecentComparison {
    /// One line: `left<US>right<US>mode<US>left name<US>right name`, the
    /// right side empty for the working copy and the mode empty for the
    /// default. Refs cannot hold control characters, so the separator never
    /// appears in a side; names have theirs replaced by spaces. Lines
    /// without the names (saved before them) still decode.
    pub fn encode(&self) -> String {
        let right = match &self.right {
            CompareSide::Rev(spec) => spec.as_str(),
            CompareSide::WorkingCopy => "",
        };
        let mode = self.mode.map_or("", CompareMode::id);
        let clean = |name: &str| name.replace(char::is_control, " ");
        format!(
            "{}\x1f{}\x1f{}\x1f{}\x1f{}",
            self.left,
            right,
            mode,
            clean(&self.left_name),
            clean(&self.right_name)
        )
    }

    pub fn decode(text: &str) -> Option<Self> {
        let parts: Vec<&str> = text.split('\x1f').collect();
        let (left, right, mode, left_name, right_name) = match parts[..] {
            [left, right, mode] => (left, right, mode, "", ""),
            [left, right, mode, left_name, right_name] => {
                (left, right, mode, left_name, right_name)
            }
            _ => return None,
        };
        if left.is_empty() {
            return None;
        }
        Some(Self {
            left: left.to_owned(),
            right: if right.is_empty() {
                CompareSide::WorkingCopy
            } else {
                CompareSide::Rev(right.to_owned())
            },
            mode: CompareMode::parse(mode),
            left_name: left_name.to_owned(),
            right_name: right_name.to_owned(),
        })
    }
}

/// `list` with `entry` first (moved there when already listed), at most
/// [`RECENT_LIMIT`] long.
pub fn push_recent(list: &[String], entry: &RecentComparison) -> Vec<String> {
    let line = entry.encode();
    let same_sides = |text: &String| {
        RecentComparison::decode(text)
            .is_some_and(|r| r.left == entry.left && r.right == entry.right)
    };
    std::iter::once(line)
        .chain(list.iter().filter(|t| !same_sides(t)).cloned())
        .take(RECENT_LIMIT)
        .collect()
}

/// Indices of the files whose path (or original path) contains `query`, in
/// any case; all of them for an empty query. A query in double quotes
/// (`"src/auth.rs"`) names one path: only the file at exactly that path, or
/// renamed from it, matches (File history's Compare versions).
pub fn filter_files(files: &[CompareFile], query: &str) -> Vec<usize> {
    let query = query.trim();
    let exact = exact_path(query);
    // An opening quote alone is a path still being typed.
    let needle = query.trim_start_matches('"').to_lowercase();
    files
        .iter()
        .enumerate()
        .filter(|(_, file)| {
            let mut paths = std::iter::once(&file.path)
                .chain(file.original_path.as_ref())
                .map(|p| p.to_string_lossy().replace('\\', "/"));
            match &exact {
                Some(path) => paths.any(|p| p == *path),
                None => needle.is_empty() || paths.any(|p| p.to_lowercase().contains(&needle)),
            }
        })
        .map(|(i, _)| i)
        .collect()
}

/// The path a quoted filter names (`"a/b.rs"` -> `a/b.rs`), `/`-separated;
/// `None` for any other query.
fn exact_path(query: &str) -> Option<String> {
    let inner = query.strip_prefix('"')?.strip_suffix('"')?;
    (!inner.is_empty()).then(|| inner.replace('\\', "/"))
}

/// `(path, added, removed)` from `git diff --numstat -z -M` output, `None`
/// counts for binary files (`-`). A rename or copy reads
/// `added<TAB>removed<TAB><NUL>old<NUL>new<NUL>`; it is keyed by the new path.
pub fn parse_numstat(output: &[u8]) -> Vec<(PathBuf, Option<(u32, u32)>)> {
    let mut stats = Vec::new();
    let mut fields = output.split(|&b| b == 0);
    while let Some(record) = fields.next() {
        if record.is_empty() {
            continue;
        }
        let mut parts = record.splitn(3, |&b| b == b'\t');
        let (Some(added), Some(removed), Some(path)) = (parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        let number = |field: &[u8]| std::str::from_utf8(field).ok()?.parse::<u32>().ok();
        let counts = number(added).zip(number(removed));
        let path = if path.is_empty() {
            let _old = fields.next();
            match fields.next() {
                Some(new) => git_path(new),
                None => break,
            }
        } else {
            git_path(path)
        };
        stats.push((path, counts));
    }
    stats
}

/// Lines in an untracked file's bytes, as git's numstat counts them; `None`
/// for binary content (a NUL in the first 8000 bytes).
pub fn count_untracked_lines(bytes: &[u8]) -> Option<u32> {
    if bytes[..bytes.len().min(8000)].contains(&0) {
        return None;
    }
    let newlines = bytes.iter().filter(|&&b| b == b'\n').count();
    let last = usize::from(!bytes.is_empty() && !bytes.ends_with(b"\n"));
    u32::try_from(newlines + last).ok()
}

/// Untracked files larger than this are listed without a line count.
pub const UNTRACKED_COUNT_LIMIT: u64 = 1024 * 1024;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numstat_with_renames_and_binaries() {
        let out = b"1\t0\t\0f.txt\0g.txt\0-\t-\tpic.png\x003\t2\tsrc/a b.rs\0";
        let stats = parse_numstat(out);
        assert_eq!(
            stats,
            vec![
                (PathBuf::from("g.txt"), Some((1, 0))),
                (PathBuf::from("pic.png"), None),
                (PathBuf::from("src/a b.rs"), Some((3, 2))),
            ]
        );
    }

    #[test]
    fn side_log_lists_right_then_left() {
        let out = b">\x1faaa\x1fp1\x1fAnn\x1fann@x\x1f100\x1fBo <bo@x>\x1eAnn <ann@x>\x1fAdd login\n\0\n<\x1fbbb\x1fp2 p3\x1fBo\x1fbo@x\x1f90\x1f\x1fMerge x\0\n-\x1fccc\x1f\x1fCy\x1fcy@x\x1f80\x1f\x1fBoundary\0>\x1fddd\x1f\x1fDi\x1fdi@x\x1f70\x1f\x1fRoot\0";
        let commits = parse_side_log(out);
        let ids: Vec<(&str, OnlyOn, u32)> = commits
            .iter()
            .map(|c| (c.oid.as_str(), c.only, c.parents))
            .collect();
        assert_eq!(
            ids,
            vec![
                ("aaa", OnlyOn::Right, 1),
                ("ddd", OnlyOn::Right, 0),
                ("bbb", OnlyOn::Left, 2),
            ]
        );
        assert_eq!(commits[0].subject, "Add login");
        assert_eq!((commits[0].author.as_str(), commits[0].time), ("Ann", 100));
        assert_eq!(commits[0].email, "ann@x");
        assert_eq!(
            commits[0].coauthors,
            vec![("Bo".to_owned(), "bo@x".to_owned())]
        );
        assert!(commits[2].coauthors.is_empty());
    }

    #[test]
    fn recent_comparisons_round_trip_and_stay_unique() {
        let entry = |left: &str, right: Option<&str>, mode: Option<CompareMode>| RecentComparison {
            left: left.to_owned(),
            right: right.map_or(CompareSide::WorkingCopy, |r| CompareSide::Rev(r.to_owned())),
            mode,
            left_name: String::new(),
            right_name: String::new(),
        };
        let a = entry("main", Some("feature/x"), None);
        let b = entry("main", None, Some(CompareMode::Exact));
        assert_eq!(RecentComparison::decode(&a.encode()), Some(a.clone()));
        assert_eq!(RecentComparison::decode(&b.encode()), Some(b.clone()));
        assert_eq!(RecentComparison::decode("only-one"), None);
        // Commit sides keep their subjects; older lines have none.
        let named = RecentComparison {
            left: "1234abcd".to_owned(),
            right: CompareSide::Rev("5678ef01".to_owned()),
            mode: None,
            left_name: "Fix the\tparser".to_owned(),
            right_name: "Add a test".to_owned(),
        };
        let decoded = RecentComparison::decode(&named.encode()).expect("decodes");
        assert_eq!(decoded.left_name, "Fix the parser");
        assert_eq!(decoded.right_name, "Add a test");
        let old = RecentComparison::decode("main\x1ffeature/x\x1f").expect("decodes");
        assert_eq!((old.left.as_str(), old.left_name.as_str()), ("main", ""));
        let list = push_recent(&[], &a);
        let list = push_recent(&list, &b);
        // The same sides again move to the top, with the new mode.
        let again = entry("main", Some("feature/x"), Some(CompareMode::Exact));
        let list = push_recent(&list, &again);
        assert_eq!(list, vec![again.encode(), b.encode()]);
        let mut long = list.clone();
        for n in 0..10 {
            long = push_recent(&long, &entry(&format!("b{n}"), Some("main"), None));
        }
        assert_eq!(long.len(), RECENT_LIMIT);
        assert!(long[0].starts_with("b9"));
    }

    #[test]
    fn numstat_empty() {
        assert!(parse_numstat(b"").is_empty());
    }

    #[test]
    fn every_kind_defaults_to_since_the_fork() {
        use SideKind::*;
        for (left, right) in [
            (Branch, Branch),
            (Remote, Branch),
            (Tag, Branch),
            (Branch, Commit),
            (Commit, WorkingCopy),
        ] {
            assert_eq!(default_mode(left, right), CompareMode::SinceFork);
        }
    }

    #[test]
    fn side_names() {
        let side = |spec: &str, full: Option<&str>| ResolvedSide {
            spec: spec.to_owned(),
            kind: full.map_or(SideKind::Commit, SideKind::from_full_name),
            full_name: full.map(str::to_owned),
            oid: None,
            subject: None,
        };
        assert_eq!(side("main", Some("refs/heads/main")).name(), "main");
        assert_eq!(
            side("origin/x", Some("refs/remotes/origin/x")).name(),
            "origin/x"
        );
        assert_eq!(side("v1", Some("refs/tags/v1")).name(), "v1");
        assert_eq!(side("cf0f077a394ee2d652", None).name(), "cf0f077");
        assert_eq!(side("HEAD~2", None).name(), "HEAD~2");
    }

    #[test]
    fn untracked_line_counts() {
        assert_eq!(count_untracked_lines(b""), Some(0));
        assert_eq!(count_untracked_lines(b"a\nb\n"), Some(2));
        assert_eq!(count_untracked_lines(b"a\nb"), Some(2));
        assert_eq!(count_untracked_lines(b"a\0b"), None);
    }

    #[test]
    fn filter_matches_paths_in_any_case() {
        let file = |path: &str, original: Option<&str>| CompareFile {
            change: Change::Modified,
            path: PathBuf::from(path),
            original_path: original.map(PathBuf::from),
            stats: None,
            untracked: false,
        };
        let files = vec![
            file("src/Auth.rs", None),
            file("docs/new.md", Some("docs/old.md")),
            file("README.md", None),
        ];
        assert_eq!(filter_files(&files, ""), vec![0, 1, 2]);
        assert_eq!(filter_files(&files, "auth"), vec![0]);
        assert_eq!(filter_files(&files, "OLD"), vec![1]);
        assert_eq!(filter_files(&files, ".md"), vec![1, 2]);
    }

    #[test]
    fn quoted_filter_matches_one_path() {
        let file = |path: &str, original: Option<&str>| CompareFile {
            change: Change::Modified,
            path: PathBuf::from(path),
            original_path: original.map(PathBuf::from),
            stats: None,
            untracked: false,
        };
        let files = vec![
            file("src/auth.rs", None),
            file("src/auth.rs.bak", None),
            file("lib/src/auth.rs", None),
            file("src/login/auth.rs", Some("src/old auth \u{e8}.rs")),
        ];
        assert_eq!(filter_files(&files, "src/auth.rs"), vec![0, 1, 2]);
        assert_eq!(filter_files(&files, "\"src/auth.rs\""), vec![0]);
        assert_eq!(filter_files(&files, " \"src/auth.rs\" "), vec![0]);
        // The path is exact: its case too.
        assert_eq!(filter_files(&files, "\"SRC/auth.rs\""), Vec::<usize>::new());
        // A rename matches under either name.
        assert_eq!(filter_files(&files, "\"src/old auth \u{e8}.rs\""), vec![3]);
        assert_eq!(filter_files(&files, "\"src/login/auth.rs\""), vec![3]);
        // An opening quote alone is a path being typed; `""` filters nothing.
        assert_eq!(filter_files(&files, "\"src/auth.rs"), vec![0, 1, 2]);
        assert_eq!(filter_files(&files, "\"\""), vec![0, 1, 2, 3]);
    }
}
