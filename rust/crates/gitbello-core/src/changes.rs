//! The Changes view's model (PLAN §4, §3.10): one list of changed files and
//! the commit selection, gitbello's own record of what the next commit
//! takes. The selection is seeded from the index and written to a temporary
//! index only at commit time.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use crate::diff::{build_patch, DiffKind, DiffTarget, FileDiff, LineKind, PatchMode};
use crate::repo::{Change, FileChange, FileState, RepoStatus};

/// Indices into [`RepoStatus::changes`]: conflicted files first, then the
/// rest, each sorted by path. Ignored files are left out.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ChangeList {
    indices: Vec<usize>,
}

impl ChangeList {
    pub fn new(status: &RepoStatus) -> Self {
        let mut indices: Vec<usize> = (0..status.changes.len())
            .filter(|&i| status.changes[i].state != FileState::Ignored)
            .collect();
        indices.sort_by(|&a, &b| {
            let (a, b) = (&status.changes[a], &status.changes[b]);
            (!is_conflicted(a), &a.path).cmp(&(!is_conflicted(b), &b.path))
        });
        Self { indices }
    }

    pub fn indices(&self) -> &[usize] {
        &self.indices
    }

    pub fn len(&self) -> usize {
        self.indices.len()
    }

    pub fn is_empty(&self) -> bool {
        self.indices.is_empty()
    }
}

pub fn is_conflicted(change: &FileChange) -> bool {
    matches!(change.state, FileState::Unmerged(_))
}

/// Whether the index holds a rename of `change.original_path` to its path.
fn is_staged_rename(change: &FileChange) -> bool {
    matches!(
        change.state,
        FileState::Tracked {
            index: Change::Renamed,
            ..
        }
    )
}

/// One-letter code of a file's change against HEAD (`M`, `A`, `D`, `R`,
/// `C`, `T`, `U` for conflicts, `?` for untracked files).
pub fn change_code(change: &FileChange) -> &'static str {
    match change.state {
        FileState::Unmerged(_) => "U",
        FileState::Untracked => "?",
        FileState::Ignored => "!",
        FileState::Tracked { index, worktree } => match (index, worktree) {
            (_, Change::Deleted) | (Change::Deleted, _) => "D",
            (Change::Renamed, _) => "R",
            (Change::Copied, _) => "C",
            (Change::Added, _) => "A",
            (Change::TypeChanged, _) | (_, Change::TypeChanged) => "T",
            _ => "M",
        },
    }
}

/// The diff the Changes view shows for `path`: the working tree against
/// HEAD (a staged rename compares against its source); an untracked file
/// in full; a conflicted file as git's combined diff.
pub fn diff_target(status: &RepoStatus, path: &Path) -> DiffTarget {
    let change = find(status, path);
    let kind = match change.map(|c| c.state) {
        Some(FileState::Untracked) => DiffKind::Untracked,
        Some(FileState::Unmerged(_)) => DiffKind::Unstaged,
        _ => DiffKind::Head,
    };
    DiffTarget {
        kind,
        path: path.to_path_buf(),
        original_path: change
            .filter(|c| is_staged_rename(c))
            .and_then(|c| c.original_path.clone()),
        commit: None,
    }
}

/// `paths` plus the sources of the staged renames among them, which go
/// along when a rename is unstaged, discarded or committed.
pub fn with_rename_sources(status: &RepoStatus, paths: &[PathBuf]) -> Vec<PathBuf> {
    let mut out = Vec::with_capacity(paths.len());
    for path in paths {
        out.push(path.clone());
        let source = find(status, path)
            .filter(|c| is_staged_rename(c))
            .and_then(|c| c.original_path.clone());
        out.extend(source);
    }
    out
}

fn find<'a>(status: &'a RepoStatus, path: &Path) -> Option<&'a FileChange> {
    status.changes.iter().find(|c| c.path == path)
}

/// A picked line, stable across reloads of the diff: a removed line by its
/// line number in HEAD, an added line by the HEAD line it follows plus its
/// text and its position among equal lines there.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LineKey {
    pub added: bool,
    pub old_line: u32,
    pub nth: u32,
    pub text: Box<[u8]>,
}

/// Per line of `diff`: the key of an added or removed line, `None` for hunk
/// headers and context.
pub fn line_keys(diff: &FileDiff) -> Vec<Option<LineKey>> {
    let mut keys = vec![None; diff.line_count()];
    let mut nth: HashMap<(u32, &[u8]), u32> = HashMap::new();
    for (h, hunk) in diff.hunks.iter().enumerate() {
        let end = diff.hunks.get(h + 1).map_or(diff.line_count(), |n| n.line);
        // An empty old range sits after `old_start`; a full one starts there.
        let mut anchor = if hunk.old_count == 0 {
            hunk.old_start
        } else {
            hunk.old_start.saturating_sub(1)
        };
        for (i, key) in keys.iter_mut().enumerate().take(end).skip(hunk.line + 1) {
            let Some(line) = diff.line(i) else {
                continue;
            };
            match line.kind {
                LineKind::Context => anchor = line.old_line.unwrap_or(anchor),
                LineKind::Removed => {
                    anchor = line.old_line.unwrap_or(anchor);
                    *key = Some(LineKey {
                        added: false,
                        old_line: anchor,
                        nth: 0,
                        text: line.text.into(),
                    });
                }
                LineKind::Added => {
                    let n = nth.entry((anchor, line.text)).or_insert(0);
                    *key = Some(LineKey {
                        added: true,
                        old_line: anchor,
                        nth: *n,
                        text: line.text.into(),
                    });
                    *n += 1;
                }
                LineKind::Hunk => {}
            }
        }
    }
    keys
}

/// What the next commit takes of one file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FilePick {
    Included,
    Excluded,
    /// Exactly what the index holds (staged in part outside gitbello, in a
    /// way the picked lines cannot express).
    AsStaged,
    /// These lines of the file's diff against HEAD (neither none nor all).
    Lines(Vec<LineKey>),
}

/// A file's checkbox, or a line's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PickState {
    All,
    None,
    Partial,
}

impl PickState {
    pub fn id(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::None => "none",
            Self::Partial => "partial",
        }
    }
}

#[derive(Debug, Clone)]
struct Entry {
    pick: FilePick,
    /// The index blob when the pick was seeded or last checked.
    seen_index: Option<String>,
}

/// The commit selection of one worktree (PLAN §3.10). Conflicted files have
/// no entry: they cannot be committed until resolved.
#[derive(Debug, Clone, Default)]
pub struct Selection {
    files: HashMap<PathBuf, Entry>,
    seeded: bool,
}

impl Selection {
    /// Brings the selection up to date with a new status. The first status
    /// seeds it: the staged files when anything is staged, else everything.
    /// Later, new files start picked (or as staged), files that went away
    /// are dropped, and a file whose index blob changed (staged or unstaged
    /// outside gitbello) is seeded again from the index.
    pub fn reconcile(&mut self, status: &RepoStatus) {
        let first = !self.seeded;
        self.seeded = true;
        let staged_only = first && status.changes.iter().any(FileChange::is_staged);
        let mut files = HashMap::new();
        for change in &status.changes {
            if matches!(change.state, FileState::Ignored | FileState::Unmerged(_)) {
                continue;
            }
            let pick = match self.files.remove(&change.path) {
                Some(entry) if entry.seen_index == change.index_oid => entry.pick,
                _ if staged_only && !change.is_staged() => FilePick::Excluded,
                _ => seed(change),
            };
            let entry = Entry {
                pick,
                seen_index: change.index_oid.clone(),
            };
            files.insert(change.path.clone(), entry);
        }
        self.files = files;
    }

    pub fn pick(&self, path: &Path) -> Option<&FilePick> {
        self.files.get(path).map(|e| &e.pick)
    }

    /// The checkbox of `path` (`None` for files without an entry).
    pub fn state(&self, path: &Path) -> PickState {
        match self.pick(path) {
            Some(FilePick::Included) => PickState::All,
            Some(FilePick::AsStaged | FilePick::Lines(_)) => PickState::Partial,
            Some(FilePick::Excluded) | None => PickState::None,
        }
    }

    /// The check-all box: `All` when every file is included whole, `None`
    /// when none is picked (or there are no files), else `Partial`.
    pub fn overall_state(&self) -> PickState {
        let mut states = self.files.values().map(|e| match e.pick {
            FilePick::Included => PickState::All,
            FilePick::Excluded => PickState::None,
            FilePick::AsStaged | FilePick::Lines(_) => PickState::Partial,
        });
        let Some(first) = states.next() else {
            return PickState::None;
        };
        if states.all(|s| s == first) {
            first
        } else {
            PickState::Partial
        }
    }

    /// Files the next commit takes something of.
    pub fn picked_count(&self) -> usize {
        self.files
            .values()
            .filter(|e| e.pick != FilePick::Excluded)
            .count()
    }

    /// Includes or excludes whole files. Returns whether any had an entry.
    pub fn pick_files(&mut self, paths: &[PathBuf], include: bool) -> bool {
        let mut any = false;
        for path in paths {
            if let Some(entry) = self.files.get_mut(path) {
                entry.pick = whole(include);
                any = true;
            }
        }
        any
    }

    pub fn pick_all(&mut self, include: bool) {
        for entry in self.files.values_mut() {
            entry.pick = whole(include);
        }
    }

    /// Picks or unpicks `lines` (indices into `diff`, the file's diff
    /// against HEAD; a hunk header stands for its whole hunk). All lines
    /// picked makes the file included, none excluded. Returns false when
    /// the file has no entry or the diff no changed lines.
    pub fn pick_lines(
        &mut self,
        path: &Path,
        diff: &FileDiff,
        lines: &[usize],
        include: bool,
    ) -> bool {
        let Some(entry) = self.files.get_mut(path) else {
            return false;
        };
        let keys = line_keys(diff);
        let total = keys.iter().flatten().count();
        if total == 0 {
            return false;
        }
        let mut picked: HashSet<LineKey> = picked_keys(&entry.pick, &keys);
        for i in expand_hunks(diff, lines) {
            if let Some(Some(key)) = keys.get(i) {
                if include {
                    picked.insert(key.clone());
                } else {
                    picked.remove(key);
                }
            }
        }
        entry.pick = from_keys(picked, total);
        true
    }

    /// Per line of `diff` (the file's diff against HEAD): `All` for a picked
    /// changed line, `None` for the rest; a hunk header is `All`, `None` or
    /// `Partial` after its changed lines.
    pub fn line_states(&self, path: &Path, diff: &FileDiff) -> Vec<PickState> {
        let keys = line_keys(diff);
        let picked = self
            .pick(path)
            .map(|p| picked_keys(p, &keys))
            .unwrap_or_default();
        let mut states: Vec<PickState> = keys
            .iter()
            .map(|k| match k {
                Some(key) if picked.contains(key) => PickState::All,
                _ => PickState::None,
            })
            .collect();
        for (h, hunk) in diff.hunks.iter().enumerate() {
            let end = diff.hunks.get(h + 1).map_or(diff.line_count(), |n| n.line);
            let changed = (hunk.line + 1..end).filter(|&i| keys[i].is_some());
            let (mut on, mut off) = (0, 0);
            for i in changed {
                if states[i] == PickState::All {
                    on += 1;
                } else {
                    off += 1;
                }
            }
            if let Some(state) = states.get_mut(hunk.line) {
                *state = match (on, off) {
                    (0, _) => PickState::None,
                    (_, 0) => PickState::All,
                    _ => PickState::Partial,
                };
            }
        }
        states
    }

    /// Turns an [`FilePick::AsStaged`] file into a line pick when every line
    /// the index changes (`staged`, HEAD against the index) is a line of
    /// `head` (HEAD against the working tree). Returns whether it did.
    pub fn resolve_as_staged(&mut self, path: &Path, head: &FileDiff, staged: &FileDiff) -> bool {
        let Some(entry) = self
            .files
            .get_mut(path)
            .filter(|e| e.pick == FilePick::AsStaged)
        else {
            return false;
        };
        let head_keys: HashSet<LineKey> = line_keys(head).into_iter().flatten().collect();
        let staged_keys: HashSet<LineKey> = line_keys(staged).into_iter().flatten().collect();
        if staged_keys.is_empty() || !staged_keys.is_subset(&head_keys) {
            return false;
        }
        entry.pick = from_keys(staged_keys, head_keys.len());
        true
    }

    /// What committing the selection writes, for the files in `status`.
    pub fn plan(&self, status: &RepoStatus) -> CommitPlan {
        let mut plan = CommitPlan::default();
        for change in &status.changes {
            let Some(pick) = self.pick(&change.path) else {
                continue;
            };
            let source = change
                .original_path
                .clone()
                .filter(|_| is_staged_rename(change));
            match pick {
                FilePick::Excluded => {}
                FilePick::Included => {
                    plan.whole.push(change.path.clone());
                    plan.whole.extend(source);
                }
                FilePick::AsStaged => {
                    let (Some(mode), Some(oid)) = (&change.index_mode, &change.index_oid) else {
                        continue;
                    };
                    let removed = mode.chars().all(|c| c == '0');
                    plan.staged.push(IndexEntry {
                        mode: if removed { "0".into() } else { mode.clone() },
                        oid: oid.clone(),
                        path: change.path.clone(),
                    });
                    if let Some(source) = source {
                        plan.staged.push(IndexEntry {
                            mode: "0".into(),
                            oid: "0".repeat(oid.len()),
                            path: source,
                        });
                    }
                }
                FilePick::Lines(keys) => {
                    plan.lines
                        .push((diff_target(status, &change.path), keys.clone()));
                }
            }
        }
        plan
    }
}

/// The pick of a file seen for the first time or whose index changed.
fn seed(change: &FileChange) -> FilePick {
    match change.state {
        FileState::Tracked { index, worktree } if index != Change::Unmodified => {
            if worktree == Change::Unmodified {
                FilePick::Included
            } else {
                FilePick::AsStaged
            }
        }
        _ => FilePick::Included,
    }
}

fn whole(include: bool) -> FilePick {
    if include {
        FilePick::Included
    } else {
        FilePick::Excluded
    }
}

/// The keys of `keys` (one diff's) that `pick` takes.
fn picked_keys(pick: &FilePick, keys: &[Option<LineKey>]) -> HashSet<LineKey> {
    match pick {
        FilePick::Included => keys.iter().flatten().cloned().collect(),
        FilePick::Lines(picked) => {
            let picked: HashSet<&LineKey> = picked.iter().collect();
            keys.iter()
                .flatten()
                .filter(|k| picked.contains(k))
                .cloned()
                .collect()
        }
        FilePick::Excluded | FilePick::AsStaged => HashSet::new(),
    }
}

fn from_keys(picked: HashSet<LineKey>, total: usize) -> FilePick {
    if picked.is_empty() {
        FilePick::Excluded
    } else if picked.len() >= total {
        FilePick::Included
    } else {
        let mut keys: Vec<LineKey> = picked.into_iter().collect();
        keys.sort();
        FilePick::Lines(keys)
    }
}

/// The patch that adds the `keys` lines of `diff` (a file's diff against
/// HEAD, `path` `/`-separated) to HEAD's version. `None` when a key is no
/// longer in the diff (the file changed since the lines were picked).
pub fn lines_patch(diff: &FileDiff, path: &str, keys: &[LineKey]) -> Option<Vec<u8>> {
    let lines = line_keys(diff);
    let index: HashMap<&LineKey, usize> = lines
        .iter()
        .enumerate()
        .filter_map(|(i, k)| Some((k.as_ref()?, i)))
        .collect();
    let picked: Option<Vec<usize>> = keys.iter().map(|k| index.get(k).copied()).collect();
    build_patch(diff, path, &picked?, PatchMode::Stage)
}

/// `lines` with each hunk header replaced by its hunk's lines.
fn expand_hunks(diff: &FileDiff, lines: &[usize]) -> Vec<usize> {
    let mut out = Vec::new();
    for &line in lines {
        match diff.hunks.iter().position(|h| h.line == line) {
            Some(h) => {
                let end = diff.hunks.get(h + 1).map_or(diff.line_count(), |n| n.line);
                out.extend(line + 1..end);
            }
            None => out.push(line),
        }
    }
    out
}

/// What committing a selection writes into the temporary index.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CommitPlan {
    /// Taken whole from the working tree (`git add -A`).
    pub whole: Vec<PathBuf>,
    /// Taken as the index holds them (mode `0` removes the path).
    pub staged: Vec<IndexEntry>,
    /// Taken in part: the file's diff against HEAD and the picked lines.
    pub lines: Vec<(DiffTarget, Vec<LineKey>)>,
}

impl CommitPlan {
    pub fn is_empty(&self) -> bool {
        self.whole.is_empty() && self.staged.is_empty() && self.lines.is_empty()
    }

    /// Every path the commit writes.
    pub fn paths(&self) -> Vec<PathBuf> {
        let mut paths = self.whole.clone();
        paths.extend(self.staged.iter().map(|e| e.path.clone()));
        paths.extend(self.lines.iter().map(|(t, _)| t.path.clone()));
        paths
    }
}

/// One `git update-index --index-info` line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexEntry {
    pub mode: String,
    pub oid: String,
    pub path: PathBuf,
}

/// `summary`, then a blank line and `body` when there is one. Surrounding
/// blank lines are dropped; `None` when the summary is empty.
pub fn commit_message(summary: &str, body: &str) -> Option<String> {
    let summary = summary.trim();
    if summary.is_empty() {
        return None;
    }
    let body = body
        .trim_matches(|c: char| c == '\n' || c == '\r')
        .trim_end();
    Some(if body.is_empty() {
        format!("{summary}\n")
    } else {
        format!("{summary}\n\n{body}\n")
    })
}

/// Splits a commit message into its summary (first line) and body.
pub fn split_message(message: &str) -> (String, String) {
    let message = message.trim_start_matches(['\n', '\r']);
    let (summary, body) = message.split_once('\n').unwrap_or((message, ""));
    (
        summary.trim_end().to_owned(),
        body.trim_matches(|c: char| c == '\n' || c == '\r')
            .trim_end()
            .to_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::parse_diff;
    use crate::repo::parse_status;

    fn status_of(entries: &str) -> RepoStatus {
        let out = format!(
            "# branch.oid 1111111111111111111111111111111111111111\0# branch.head main\0{entries}"
        );
        parse_status(out.as_bytes()).unwrap()
    }

    fn status() -> RepoStatus {
        status_of(
            "1 .M N... 100644 100644 100644 a a z.txt\0\
1 MM N... 100644 100644 100644 a b both.txt\0\
2 R. N... 100644 100644 100644 a a R100 new.txt\0old.txt\0\
1 A. N... 000000 100644 100644 0 c added.txt\0\
u UU N... 100644 100644 100644 100644 a b c clash.txt\0\
? notes.txt\0\
! build/out.o\0",
        )
    }

    fn listed(status: &RepoStatus) -> Vec<String> {
        ChangeList::new(status)
            .indices()
            .iter()
            .map(|&i| {
                let c = &status.changes[i];
                format!("{} {}", change_code(c), c.path.display())
            })
            .collect()
    }

    #[test]
    fn lists_conflicts_first_then_by_path() {
        assert_eq!(
            listed(&status()),
            [
                "U clash.txt",
                "A added.txt",
                "M both.txt",
                "R new.txt",
                "? notes.txt",
                "M z.txt"
            ]
        );
    }

    #[test]
    fn diffs_against_head_and_renames_bring_their_source() {
        let status = status();
        let target = diff_target(&status, Path::new("new.txt"));
        assert_eq!(target.kind, DiffKind::Head);
        assert_eq!(target.original_path, Some(PathBuf::from("old.txt")));
        assert_eq!(
            diff_target(&status, Path::new("notes.txt")).kind,
            DiffKind::Untracked
        );
        assert_eq!(
            with_rename_sources(&status, &[PathBuf::from("new.txt"), PathBuf::from("z.txt")]),
            [
                PathBuf::from("new.txt"),
                PathBuf::from("old.txt"),
                PathBuf::from("z.txt")
            ]
        );
    }

    fn states(selection: &Selection, status: &RepoStatus) -> Vec<String> {
        ChangeList::new(status)
            .indices()
            .iter()
            .map(|&i| {
                let path = &status.changes[i].path;
                format!("{} {}", path.display(), selection.state(path).id())
            })
            .collect()
    }

    #[test]
    fn seeds_from_the_index_when_something_is_staged() {
        let status = status();
        let mut selection = Selection::default();
        selection.reconcile(&status);
        assert_eq!(
            states(&selection, &status),
            [
                "clash.txt none",
                "added.txt all",
                "both.txt partial",
                "new.txt all",
                "notes.txt none",
                "z.txt none"
            ]
        );
        assert_eq!(
            selection.pick(Path::new("both.txt")),
            Some(&FilePick::AsStaged)
        );
        assert_eq!(selection.picked_count(), 3);
        assert_eq!(selection.overall_state(), PickState::Partial);
        selection.pick_all(true);
        assert_eq!(selection.overall_state(), PickState::All);
        selection.pick_all(false);
        assert_eq!(selection.overall_state(), PickState::None);
    }

    #[test]
    fn seeds_everything_when_nothing_is_staged() {
        let status = status_of("1 .M N... 100644 100644 100644 a a z.txt\0? notes.txt\0");
        let mut selection = Selection::default();
        selection.reconcile(&status);
        assert_eq!(selection.picked_count(), 2);

        // Unpicked files stay unpicked; new ones start picked.
        selection.pick_files(&[PathBuf::from("z.txt")], false);
        let later =
            status_of("1 .M N... 100644 100644 100644 a a z.txt\0? notes.txt\0? later.txt\0");
        selection.reconcile(&later);
        assert_eq!(selection.state(Path::new("z.txt")), PickState::None);
        assert_eq!(selection.state(Path::new("later.txt")), PickState::All);

        // Staging z.txt outside gitbello changes its index blob: reseeded.
        let staged = status_of("1 M. N... 100644 100644 100644 a d z.txt\0? notes.txt\0");
        selection.reconcile(&staged);
        assert_eq!(selection.state(Path::new("z.txt")), PickState::All);
        assert_eq!(
            selection.pick(Path::new("later.txt")),
            None,
            "gone files drop out"
        );
    }

    const DIFF: &[u8] = b"diff --git a/f.txt b/f.txt
--- a/f.txt
+++ b/f.txt
@@ -1,4 +1,4 @@
 a
-b
+B
 c
 d
@@ -10,3 +10,5 @@
 j
 k
+x
+x
 l
";

    #[test]
    fn line_keys_survive_shifts_and_tell_equal_lines_apart() {
        let diff = parse_diff(DIFF).unwrap();
        let keys = line_keys(&diff);
        let key = |i: usize| keys[i].clone().unwrap();
        assert_eq!((key(2).added, key(2).old_line), (false, 2));
        assert_eq!((key(3).added, key(3).old_line), (true, 2));
        assert_eq!((key(9).old_line, key(9).nth), (11, 0));
        assert_eq!((key(10).old_line, key(10).nth), (11, 1));
        assert!(keys[0].is_none() && keys[1].is_none());

        // The same second hunk after an edit above it in the working tree.
        let shifted = parse_diff(
            b"diff --git a/f.txt b/f.txt
--- a/f.txt
+++ b/f.txt
@@ -1,4 +1,5 @@
 a
-b
+B
+B2
 c
 d
@@ -10,3 +11,5 @@
 j
 k
+x
+x
 l
",
        )
        .unwrap();
        let moved = line_keys(&shifted);
        assert_eq!(moved[10], keys[9]);
        assert_eq!(moved[11], keys[10]);
    }

    #[test]
    fn picking_lines_makes_files_partial_whole_or_excluded() {
        let status = status_of("1 .M N... 100644 100644 100644 a a f.txt\0");
        let diff = parse_diff(DIFF).unwrap();
        let path = Path::new("f.txt");
        let mut selection = Selection::default();
        selection.reconcile(&status);
        assert_eq!(selection.state(path), PickState::All);

        assert!(
            selection.pick_lines(path, &diff, &[6], false),
            "unpick the second hunk"
        );
        assert_eq!(selection.state(path), PickState::Partial);
        let lines = selection.line_states(path, &diff);
        assert_eq!(lines[0], PickState::All);
        assert_eq!(lines[6], PickState::None);
        assert_eq!(
            (lines[2], lines[3], lines[9]),
            (PickState::All, PickState::All, PickState::None)
        );

        selection.pick_lines(path, &diff, &[3], false);
        assert_eq!(selection.line_states(path, &diff)[0], PickState::Partial);
        selection.pick_lines(path, &diff, &[2], false);
        assert_eq!(selection.state(path), PickState::None);
        selection.pick_lines(path, &diff, &[0, 6], true);
        assert_eq!(selection.pick(path), Some(&FilePick::Included));

        selection.pick_lines(path, &diff, &[9], false);
        let plan = selection.plan(&status);
        assert!(plan.whole.is_empty());
        assert_eq!(plan.lines.len(), 1);
        assert_eq!(plan.lines[0].1.len(), 3);
    }

    #[test]
    fn as_staged_files_resolve_to_lines_when_every_staged_line_matches() {
        let status = status_of("1 MM N... 100644 100644 100644 a b f.txt\0");
        let path = Path::new("f.txt");
        let head = parse_diff(DIFF).unwrap();
        // The index has only the first hunk's change.
        let staged = parse_diff(
            b"diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,4 +1,4 @@\n a\n-b\n+B\n c\n d\n",
        )
        .unwrap();
        let mut selection = Selection::default();
        selection.reconcile(&status);
        assert_eq!(selection.pick(path), Some(&FilePick::AsStaged));
        let plan = selection.plan(&status);
        assert_eq!(plan.staged[0].oid, "b");
        assert_eq!(plan.staged[0].mode, "100644");

        assert!(selection.resolve_as_staged(path, &head, &staged));
        let lines = selection.line_states(path, &head);
        assert_eq!(
            (lines[2], lines[3], lines[9]),
            (PickState::All, PickState::All, PickState::None)
        );

        // Staged content the working tree no longer has stays as staged.
        let mut other = Selection::default();
        other.reconcile(&status);
        let edited = parse_diff(
            b"diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,4 +1,4 @@\n a\n-b\n+Z\n c\n d\n",
        )
        .unwrap();
        assert!(!other.resolve_as_staged(path, &edited, &staged));
        assert_eq!(other.pick(path), Some(&FilePick::AsStaged));
    }

    #[test]
    fn plans_renames_and_staged_deletions() {
        let status = status_of(
            "2 RM N... 100644 100644 100644 a e R90 new.txt\0old.txt\0\
1 D. N... 100644 000000 000000 a 0000 gone.txt\0\
2 R. N... 100644 100644 100644 a a R100 moved.txt\0from.txt\0",
        );
        let mut selection = Selection::default();
        selection.reconcile(&status);
        let plan = selection.plan(&status);
        assert_eq!(
            plan.whole,
            [
                PathBuf::from("gone.txt"),
                PathBuf::from("moved.txt"),
                PathBuf::from("from.txt")
            ]
        );
        let staged: Vec<(&str, &str, &str)> = plan
            .staged
            .iter()
            .map(|e| {
                (
                    e.mode.as_str(),
                    e.oid.as_str(),
                    e.path.to_str().unwrap_or(""),
                )
            })
            .collect();
        assert_eq!(staged, [("100644", "e", "new.txt"), ("0", "0", "old.txt")]);
        assert_eq!(plan.paths().len(), 5);
    }

    #[test]
    fn builds_and_splits_messages() {
        assert_eq!(commit_message("  Fix it ", ""), Some("Fix it\n".into()));
        assert_eq!(
            commit_message("Fix it", "\n\nWhy.\n\nMore.  \n\n"),
            Some("Fix it\n\nWhy.\n\nMore.\n".into())
        );
        assert_eq!(commit_message("  ", "body"), None);
        assert_eq!(
            split_message("Fix it\n\nWhy.\n\nMore.\n"),
            ("Fix it".into(), "Why.\n\nMore.".into())
        );
        assert_eq!(split_message("Only\n"), ("Only".into(), String::new()));
    }
}
