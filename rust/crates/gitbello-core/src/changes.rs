//! The changes panel's lists (PLAN §4): status entries split into conflicted,
//! unstaged, staged and untracked files, each sorted by path. A file with
//! both staged and unstaged edits is in both lists.

use std::path::{Path, PathBuf};

use crate::diff::{DiffKind, DiffTarget};
use crate::repo::{Change, FileChange, FileState, RepoStatus};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ChangeGroup {
    Conflicted,
    Unstaged,
    Staged,
    Untracked,
}

impl ChangeGroup {
    pub const ALL: [ChangeGroup; 4] = [
        Self::Conflicted,
        Self::Unstaged,
        Self::Staged,
        Self::Untracked,
    ];

    /// Stable id for the UI.
    pub fn id(self) -> &'static str {
        match self {
            Self::Conflicted => "conflicted",
            Self::Unstaged => "unstaged",
            Self::Staged => "staged",
            Self::Untracked => "untracked",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|g| g.id() == id)
    }

    /// Whether files in this group get staged (as opposed to unstaged).
    pub fn stages(self) -> bool {
        self != Self::Staged
    }

    /// The diff shown for a file selected in this group.
    pub fn diff_kind(self) -> DiffKind {
        match self {
            Self::Conflicted | Self::Unstaged => DiffKind::Unstaged,
            Self::Staged => DiffKind::Staged,
            Self::Untracked => DiffKind::Untracked,
        }
    }

    fn contains(self, change: &FileChange) -> bool {
        match (self, change.state) {
            (Self::Conflicted, FileState::Unmerged(_)) => true,
            (Self::Untracked, FileState::Untracked) => true,
            (Self::Staged, FileState::Tracked { index, .. }) => index != Change::Unmodified,
            (Self::Unstaged, FileState::Tracked { worktree, .. }) => worktree != Change::Unmodified,
            _ => false,
        }
    }
}

/// Indices into [`RepoStatus::changes`] per group.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ChangeLists {
    groups: [Vec<usize>; 4],
}

impl ChangeLists {
    pub fn new(status: &RepoStatus) -> Self {
        let mut lists = Self::default();
        for (slot, group) in lists.groups.iter_mut().zip(ChangeGroup::ALL) {
            slot.extend(
                status
                    .changes
                    .iter()
                    .enumerate()
                    .filter(|(_, c)| group.contains(c))
                    .map(|(i, _)| i),
            );
            slot.sort_by(|&a, &b| status.changes[a].path.cmp(&status.changes[b].path));
        }
        lists
    }

    pub fn indices(&self, group: ChangeGroup) -> &[usize] {
        &self.groups[group as usize]
    }

    pub fn len(&self, group: ChangeGroup) -> usize {
        self.indices(group).len()
    }

    pub fn is_empty(&self, group: ChangeGroup) -> bool {
        self.indices(group).is_empty()
    }
}

/// The side of a change a group shows.
pub fn group_change(change: &FileChange, group: ChangeGroup) -> Option<Change> {
    match (group, change.state) {
        (ChangeGroup::Staged, FileState::Tracked { index, .. }) => Some(index),
        (ChangeGroup::Unstaged, FileState::Tracked { worktree, .. }) => Some(worktree),
        _ => None,
    }
}

/// One-letter code shown next to a file (`M`, `A`, `D`, `R`, `C`, `T`, `U`, `?`).
pub fn change_code(change: &FileChange, group: ChangeGroup) -> &'static str {
    match group {
        ChangeGroup::Conflicted => "U",
        ChangeGroup::Untracked => "?",
        _ => match group_change(change, group) {
            Some(Change::Modified) => "M",
            Some(Change::Added) => "A",
            Some(Change::Deleted) => "D",
            Some(Change::Renamed) => "R",
            Some(Change::Copied) => "C",
            Some(Change::TypeChanged) => "T",
            Some(Change::Unmodified) | None => "",
        },
    }
}

/// The diff to show for `path` selected in `group`. A staged rename also
/// compares against its source.
pub fn diff_target(status: &RepoStatus, group: ChangeGroup, path: &Path) -> DiffTarget {
    let original_path = (group == ChangeGroup::Staged)
        .then(|| find(status, path))
        .flatten()
        .filter(|c| group_change(c, group) == Some(Change::Renamed))
        .and_then(|c| c.original_path.clone());
    DiffTarget {
        kind: group.diff_kind(),
        path: path.to_path_buf(),
        original_path,
    }
}

/// Paths to pass to `git reset` when unstaging `paths`: a staged rename also
/// needs its source, or the deletion of the source stays staged.
pub fn unstage_paths(status: &RepoStatus, paths: &[PathBuf]) -> Vec<PathBuf> {
    let mut out = Vec::with_capacity(paths.len());
    for path in paths {
        out.push(path.clone());
        let source = find(status, path)
            .filter(|c| group_change(c, ChangeGroup::Staged) == Some(Change::Renamed))
            .and_then(|c| c.original_path.clone());
        out.extend(source);
    }
    out
}

fn find<'a>(status: &'a RepoStatus, path: &Path) -> Option<&'a FileChange> {
    status.changes.iter().find(|c| c.path == path)
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
    use crate::repo::parse_status;

    fn status() -> RepoStatus {
        let out = b"# branch.oid 1111111111111111111111111111111111111111\0\
# branch.head main\0\
1 .M N... 100644 100644 100644 a a z.txt\0\
1 MM N... 100644 100644 100644 a b both.txt\0\
2 R. N... 100644 100644 100644 a a R100 new.txt\0old.txt\0\
1 A. N... 000000 100644 100644 0 a added.txt\0\
u UU N... 100644 100644 100644 100644 a b c clash.txt\0\
? notes.txt\0\
! build/out.o\0";
        parse_status(out).unwrap()
    }

    fn paths(status: &RepoStatus, lists: &ChangeLists, group: ChangeGroup) -> Vec<String> {
        lists
            .indices(group)
            .iter()
            .map(|&i| {
                let c = &status.changes[i];
                format!("{} {}", change_code(c, group), c.path.display())
            })
            .collect()
    }

    #[test]
    fn groups_changes_by_list() {
        let status = status();
        let lists = ChangeLists::new(&status);
        use ChangeGroup::*;
        assert_eq!(paths(&status, &lists, Conflicted), ["U clash.txt"]);
        assert_eq!(paths(&status, &lists, Unstaged), ["M both.txt", "M z.txt"]);
        assert_eq!(
            paths(&status, &lists, Staged),
            ["A added.txt", "M both.txt", "R new.txt"]
        );
        assert_eq!(paths(&status, &lists, Untracked), ["? notes.txt"]);
        assert_eq!(ChangeGroup::from_id("staged"), Some(Staged));
        assert!(!Staged.stages() && Untracked.stages());
    }

    #[test]
    fn renames_bring_their_source() {
        let status = status();
        let target = diff_target(&status, ChangeGroup::Staged, Path::new("new.txt"));
        assert_eq!(target.original_path, Some(PathBuf::from("old.txt")));
        assert_eq!(target.kind, DiffKind::Staged);
        let unstaged = diff_target(&status, ChangeGroup::Unstaged, Path::new("z.txt"));
        assert_eq!(unstaged.original_path, None);
        assert_eq!(
            unstage_paths(
                &status,
                &[PathBuf::from("new.txt"), PathBuf::from("both.txt")]
            ),
            [
                PathBuf::from("new.txt"),
                PathBuf::from("old.txt"),
                PathBuf::from("both.txt")
            ]
        );
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
