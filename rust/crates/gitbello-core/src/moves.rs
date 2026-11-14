//! Uncommitted moves: a file deleted from the working tree and an untracked
//! file git sees as the same file moved (`git mv` not used). `git status`
//! pairs renames only in the index, so the backend asks git's rename
//! detection on a scratch index where the untracked files are intent-to-add,
//! and [`apply`] turns each pair into one change: the new path, renamed in
//! the working tree from the old one.

use std::collections::hash_map::DefaultHasher;
use std::collections::HashSet;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use crate::repo::{Change, FileChange, FileState, RepoStatus};

/// Above this many deleted or untracked files the pairing is skipped (each
/// refresh would pay for git's rename search).
pub const MAX_CANDIDATES: usize = 500;

/// A deleted file and the untracked file it moved to.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Move {
    pub from: PathBuf,
    pub to: PathBuf,
    /// Similarity (0–100).
    pub score: u8,
}

/// The files that can pair: deleted from the working tree with nothing
/// staged, and untracked. `None` when either side is empty or too long.
pub struct Candidates {
    pub deleted: Vec<PathBuf>,
    pub untracked: Vec<PathBuf>,
}

impl Candidates {
    pub fn of(status: &RepoStatus) -> Option<Self> {
        let mut deleted = Vec::new();
        let mut untracked = Vec::new();
        for change in &status.changes {
            match change.state {
                FileState::Tracked {
                    index: Change::Unmodified,
                    worktree: Change::Deleted,
                } if !change.submodule => deleted.push(change.path.clone()),
                FileState::Untracked => untracked.push(change.path.clone()),
                _ => {}
            }
        }
        let fits = |paths: &Vec<PathBuf>| !paths.is_empty() && paths.len() <= MAX_CANDIDATES;
        (fits(&deleted) && fits(&untracked)).then_some(Self { deleted, untracked })
    }

    /// Changes when a candidate path, blob or untracked file's size or
    /// modification time does: the last pairing still holds while it is the
    /// same. `toplevel` is the worktree the paths are relative to.
    pub fn fingerprint(&self, status: &RepoStatus, toplevel: &Path) -> u64 {
        let mut hasher = DefaultHasher::new();
        let blobs = status
            .changes
            .iter()
            .filter(|c| self.deleted.contains(&c.path))
            .map(|c| (&c.path, &c.index_oid));
        for blob in blobs {
            blob.hash(&mut hasher);
        }
        for path in &self.untracked {
            path.hash(&mut hasher);
            if let Ok(meta) = std::fs::metadata(toplevel.join(path)) {
                meta.len().hash(&mut hasher);
                let modified = meta
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok());
                modified.hash(&mut hasher);
            }
        }
        hasher.finish()
    }
}

/// The renames in `git diff --name-status -z -M` output whose source is in
/// `deleted` and destination in `untracked`.
pub fn parse_renames(bytes: &[u8], deleted: &[PathBuf], untracked: &[PathBuf]) -> Vec<Move> {
    let deleted: HashSet<&Path> = deleted.iter().map(PathBuf::as_path).collect();
    let untracked: HashSet<&Path> = untracked.iter().map(PathBuf::as_path).collect();
    let mut fields = bytes.split(|&b| b == 0).filter(|f| !f.is_empty());
    let mut moves = Vec::new();
    while let Some(code) = fields.next() {
        let renamed = code.first() == Some(&b'R');
        let copied = code.first() == Some(&b'C');
        let first = fields.next();
        let second = if renamed || copied {
            fields.next()
        } else {
            None
        };
        let (Some(from), Some(to), true) = (first, second, renamed) else {
            continue;
        };
        let from = crate::repo::git_path(from);
        let to = crate::repo::git_path(to);
        if !deleted.contains(from.as_path()) || !untracked.contains(to.as_path()) {
            continue;
        }
        let score = std::str::from_utf8(&code[1..])
            .ok()
            .and_then(|s| s.parse::<u8>().ok())
            .unwrap_or(0);
        moves.push(Move { from, to, score });
    }
    moves
}

/// Replaces each pair's deleted and untracked changes in `status` with one
/// change at the new path, renamed in the working tree from the old one.
pub fn apply(status: &mut RepoStatus, moves: &[Move]) {
    for found in moves {
        let has = |path: &Path, state: fn(&FileState) -> bool| {
            status
                .changes
                .iter()
                .any(|c| c.path == path && state(&c.state))
        };
        let deleted = |s: &FileState| {
            matches!(
                s,
                FileState::Tracked {
                    index: Change::Unmodified,
                    worktree: Change::Deleted
                }
            )
        };
        if !has(&found.from, deleted) || !has(&found.to, |s| *s == FileState::Untracked) {
            continue;
        }
        status
            .changes
            .retain(|c| c.path != found.from && c.path != found.to);
        status.changes.push(FileChange {
            path: found.to.clone(),
            original_path: Some(found.from.clone()),
            state: FileState::Tracked {
                index: Change::Unmodified,
                worktree: Change::Renamed,
            },
            score: Some(found.score),
            submodule: false,
            index_mode: None,
            index_oid: None,
        });
    }
}

/// Whether `change` is a move [`apply`] paired (renamed in the working tree,
/// its new path untracked).
pub fn is_worktree_move(change: &FileChange) -> bool {
    matches!(
        change.state,
        FileState::Tracked {
            index: Change::Unmodified,
            worktree: Change::Renamed,
        }
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn change(path: &str, state: FileState) -> FileChange {
        FileChange {
            path: PathBuf::from(path),
            original_path: None,
            state,
            score: None,
            submodule: false,
            index_mode: Some("100644".into()),
            index_oid: Some("abc".into()),
        }
    }

    fn status() -> RepoStatus {
        let deleted = FileState::Tracked {
            index: Change::Unmodified,
            worktree: Change::Deleted,
        };
        RepoStatus {
            changes: vec![
                change("src/util.rs", deleted),
                change("gone.txt", deleted),
                change("lib/util.rs", FileState::Untracked),
                change("notes.txt", FileState::Untracked),
            ],
            ..RepoStatus::default()
        }
    }

    #[test]
    fn candidates_need_both_sides() {
        let found = Candidates::of(&status()).unwrap();
        assert_eq!(found.deleted.len(), 2);
        assert_eq!(found.untracked.len(), 2);
        let mut only_deleted = status();
        only_deleted
            .changes
            .retain(|c| c.state != FileState::Untracked);
        assert!(Candidates::of(&only_deleted).is_none());
    }

    #[test]
    fn too_many_untracked_files_skip_the_pairing() {
        let mut many = status();
        for i in 0..=MAX_CANDIDATES {
            many.changes
                .push(change(&format!("build/{i}.o"), FileState::Untracked));
        }
        assert!(Candidates::of(&many).is_none());
    }

    #[test]
    fn parses_only_renames_between_candidates() {
        let out = b"R098\0src/util.rs\0lib/util.rs\0M\0other.rs\0R100\0kept.rs\0moved.rs\0C075\0gone.txt\0copy.txt\0";
        let found = Candidates::of(&status()).unwrap();
        let moves = parse_renames(out, &found.deleted, &found.untracked);
        assert_eq!(
            moves,
            [Move {
                from: PathBuf::from("src/util.rs"),
                to: PathBuf::from("lib/util.rs"),
                score: 98,
            }]
        );
    }

    #[test]
    fn a_move_becomes_one_renamed_change() {
        let mut status = status();
        apply(
            &mut status,
            &[Move {
                from: PathBuf::from("src/util.rs"),
                to: PathBuf::from("lib/util.rs"),
                score: 98,
            }],
        );
        let paths: Vec<&Path> = status.changes.iter().map(|c| c.path.as_path()).collect();
        assert_eq!(
            paths,
            [
                Path::new("gone.txt"),
                Path::new("notes.txt"),
                Path::new("lib/util.rs")
            ]
        );
        let moved = &status.changes[2];
        assert!(is_worktree_move(moved));
        assert_eq!(moved.original_path, Some(PathBuf::from("src/util.rs")));
        assert_eq!(moved.score, Some(98));
        assert_eq!(crate::changes::change_code(moved), "R");
    }

    #[test]
    fn a_stale_move_is_left_out() {
        let mut status = status();
        let before = status.clone();
        apply(
            &mut status,
            &[Move {
                from: PathBuf::from("src/util.rs"),
                to: PathBuf::from("elsewhere.rs"),
                score: 90,
            }],
        );
        assert_eq!(status, before);
    }
}
