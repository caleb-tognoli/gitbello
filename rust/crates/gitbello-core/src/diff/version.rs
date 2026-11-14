//! Open (M7.8 P3): one version of a diff's file, as a file another app can
//! open. The working copy is opened where it is; a version from the index or
//! a commit is written under the versions folder (`<hash>/<file name>`,
//! named by its bytes so opening it again reuses the file), which the app
//! clears at startup.

use std::collections::hash_map::DefaultHasher;
use std::fs;
use std::hash::Hasher;
use std::path::{Path, PathBuf};

use crate::backend::GitBackend;
use crate::diff::{DiffKind, DiffTarget};
use crate::git::{CancelToken, GitError, GitErrorKind};

/// Which version of a file to open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VersionSide {
    /// The new side, or the old one when the file was deleted.
    Shown,
    Old,
    New,
}

impl VersionSide {
    pub fn parse(id: &str) -> Option<Self> {
        match id {
            "shown" => Some(Self::Shown),
            "old" => Some(Self::Old),
            "new" => Some(Self::New),
            _ => None,
        }
    }
}

/// Where a version comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VersionSource {
    /// The file in the working tree (repository-relative).
    Working(PathBuf),
    /// A blob, as `<rev>:<path>` (`:<path>` for the index).
    Blob(String),
}

/// The new side of `target`: the working tree, the index or the commit.
pub fn new_source(target: &DiffTarget) -> Option<VersionSource> {
    let path = slashed(&target.path);
    match target.kind {
        DiffKind::Unstaged
        | DiffKind::Untracked
        | DiffKind::Head
        | DiffKind::Amend
        | DiffKind::Working => Some(VersionSource::Working(target.path.clone())),
        DiffKind::Staged => Some(VersionSource::Blob(format!(":{path}"))),
        DiffKind::ConflictSide { stage } => Some(VersionSource::Blob(format!(":{stage}:{path}"))),
        DiffKind::Commit | DiffKind::AmendStaged => target
            .commit
            .as_ref()
            .map(|c| VersionSource::Blob(format!("{}:{path}", c.oid))),
    }
}

/// The old side of `target` (under its original name when renamed): the
/// index, HEAD or the commit's parent; none for an untracked file or a root
/// commit.
pub fn old_source(target: &DiffTarget) -> Option<VersionSource> {
    let path = slashed(target.original_path.as_deref().unwrap_or(&target.path));
    match target.kind {
        DiffKind::Untracked => None,
        DiffKind::Unstaged => Some(VersionSource::Blob(format!(":{path}"))),
        DiffKind::Staged | DiffKind::Head => Some(VersionSource::Blob(format!("HEAD:{path}"))),
        DiffKind::ConflictSide { .. } => Some(VersionSource::Blob(format!(":1:{path}"))),
        DiffKind::Commit | DiffKind::Amend | DiffKind::AmendStaged | DiffKind::Working => target
            .commit
            .as_ref()
            .and_then(|c| c.parent.as_ref())
            .map(|parent| VersionSource::Blob(format!("{parent}:{path}"))),
    }
}

/// The file to open for `side` of `target` in `toplevel`: the working copy
/// itself, or the version written under `dir`. `Shown` falls back to the old
/// side when the new one does not exist (a deleted file).
pub fn open_version(
    backend: &dyn GitBackend,
    toplevel: &Path,
    target: &DiffTarget,
    side: VersionSide,
    dir: &Path,
    cancel: &CancelToken,
) -> Result<PathBuf, GitError> {
    let sources = match side {
        VersionSide::New => vec![new_source(target)],
        VersionSide::Old => vec![old_source(target)],
        VersionSide::Shown => vec![new_source(target), old_source(target)],
    };
    let name = target
        .path
        .file_name()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("file"));
    let mut last = None;
    for source in sources.into_iter().flatten() {
        match source {
            VersionSource::Working(path) => {
                let path = toplevel.join(path);
                if path.is_file() {
                    return Ok(path);
                }
            }
            VersionSource::Blob(spec) => match backend.blob(toplevel, &spec, usize::MAX, cancel) {
                Ok(Some(bytes)) => return write_version(dir, &name, &bytes),
                Ok(None) => return Err(cancelled()),
                Err(err) if err.kind == GitErrorKind::Cancelled => return Err(err),
                Err(err) => last = Some(err),
            },
        }
    }
    Err(last.unwrap_or_else(|| {
        GitError::new(
            "cat-file",
            GitErrorKind::Other,
            "this version of the file does not exist",
        )
    }))
}

/// Writes `bytes` as `<dir>/<hash>/<name>`, or reuses it when it is there.
pub fn write_version(dir: &Path, name: &Path, bytes: &[u8]) -> Result<PathBuf, GitError> {
    let mut hasher = DefaultHasher::new();
    hasher.write(bytes);
    let folder = dir.join(format!("{:016x}", hasher.finish()));
    let path = folder.join(name);
    if fs::metadata(&path).is_ok_and(|m| m.len() == bytes.len() as u64) {
        return Ok(path);
    }
    fs::create_dir_all(&folder)
        .and_then(|()| fs::write(&path, bytes))
        .map_err(|err| GitError::new("write version", GitErrorKind::Io, err.to_string()))?;
    Ok(path)
}

/// Deletes the versions written before (at startup, when no app has them
/// open from this run). Files another app still holds stay.
pub fn clear_versions(dir: &Path) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let _ = fs::remove_dir_all(entry.path());
    }
}

fn slashed(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn cancelled() -> GitError {
    GitError::new("cat-file", GitErrorKind::Cancelled, "cancelled")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::CommitSide;

    fn target(kind: DiffKind, commit: Option<(&str, Option<&str>)>) -> DiffTarget {
        DiffTarget {
            kind,
            path: PathBuf::from("dir/ä b.txt"),
            original_path: None,
            commit: commit.map(|(oid, parent)| CommitSide {
                oid: oid.to_owned(),
                parent: parent.map(str::to_owned),
            }),
        }
    }

    #[test]
    fn sources_follow_the_diff_kind() {
        let unstaged = target(DiffKind::Unstaged, None);
        assert_eq!(
            new_source(&unstaged),
            Some(VersionSource::Working(PathBuf::from("dir/ä b.txt")))
        );
        assert_eq!(
            old_source(&unstaged),
            Some(VersionSource::Blob(":dir/ä b.txt".into()))
        );
        let staged = target(DiffKind::Staged, None);
        assert_eq!(
            new_source(&staged),
            Some(VersionSource::Blob(":dir/ä b.txt".into()))
        );
        assert_eq!(
            old_source(&staged),
            Some(VersionSource::Blob("HEAD:dir/ä b.txt".into()))
        );
        assert_eq!(old_source(&target(DiffKind::Untracked, None)), None);
        let commit = target(DiffKind::Commit, Some(("abc", Some("def"))));
        assert_eq!(
            new_source(&commit),
            Some(VersionSource::Blob("abc:dir/ä b.txt".into()))
        );
        assert_eq!(
            old_source(&commit),
            Some(VersionSource::Blob("def:dir/ä b.txt".into()))
        );
        assert_eq!(
            old_source(&target(DiffKind::Commit, Some(("abc", None)))),
            None
        );
        let mut renamed = commit;
        renamed.original_path = Some(PathBuf::from("old name.txt"));
        assert_eq!(
            old_source(&renamed),
            Some(VersionSource::Blob("def:old name.txt".into()))
        );
    }

    #[test]
    fn versions_are_written_once_by_content_and_cleared() {
        let dir = std::env::temp_dir().join(format!("gitbello versiöns {}", std::process::id()));
        let name = Path::new("ä b.txt");
        let first = write_version(&dir, name, b"one").unwrap();
        assert_eq!(fs::read(&first).unwrap(), b"one");
        assert!(first.ends_with(name));
        assert_eq!(write_version(&dir, name, b"one").unwrap(), first);
        let second = write_version(&dir, name, b"two").unwrap();
        assert_ne!(second, first);
        clear_versions(&dir);
        assert!(!first.exists() && !second.exists());
        fs::remove_dir_all(&dir).unwrap();
    }
}
