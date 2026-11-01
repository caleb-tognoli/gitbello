//! Finding repositories under a folder (PLAN §4 Home, Scan folder…).
//!
//! A plain walk of the file system, without git: a folder with a `.git`
//! folder is a repository, a `.git` file points at a linked worktree's or a
//! submodule's git dir, and `HEAD` + `objects` + `refs` make a bare
//! repository. The walk stops at a repository, never follows links and
//! skips hidden folders and [`SKIPPED`].

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::git::CancelToken;
use crate::library::path_key;
use crate::runtime::normalize;

/// Folder names never walked into.
pub const SKIPPED: &[&str] = &["node_modules", "$RECYCLE.BIN", "System Volume Information"];

/// How deep a scan goes by default (the root's children are depth 1).
pub const DEFAULT_DEPTH: usize = 3;

/// Progress is reported every this many folders.
const PROGRESS_EVERY: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScanHit {
    /// The repository's folder (the main worktree, or a bare repository).
    pub path: PathBuf,
    /// Linked worktrees found in the scan that belong to it.
    pub worktrees: Vec<PathBuf>,
    pub bare: bool,
}

/// Walks `root` down to `depth` levels. `progress` gets `(folders, found)`
/// now and then. A cancelled scan returns what it found so far.
pub fn scan(
    root: &Path,
    depth: usize,
    cancel: &CancelToken,
    mut progress: impl FnMut(usize, usize),
) -> Vec<ScanHit> {
    let mut hits: BTreeMap<String, ScanHit> = BTreeMap::new();
    // Walk from the real path: a worktree's `.git` file names its main
    // repository by the path git saw, so both must take the same form
    // (macOS `/var` is `/private/var`, Windows has 8.3 names and links).
    let mut stack: Vec<(PathBuf, usize)> = vec![(normalize(root), 0)];
    let mut folders = 0usize;
    while let Some((dir, level)) = stack.pop() {
        if cancel.is_cancelled() {
            break;
        }
        folders += 1;
        if folders.is_multiple_of(PROGRESS_EVERY) {
            progress(folders, hits.len());
        }
        match classify(&dir) {
            Some(Found::Repo { bare }) => {
                hit(&mut hits, &dir, bare);
                continue;
            }
            Some(Found::Worktree { main, bare }) => {
                hit(&mut hits, &normalize(&main), bare).worktrees.push(dir);
                continue;
            }
            None => {}
        }
        if level >= depth {
            continue;
        }
        let Ok(children) = fs::read_dir(&dir) else {
            continue;
        };
        let mut subdirs: Vec<PathBuf> = children
            .filter_map(Result::ok)
            .filter(|child| child.file_type().is_ok_and(|t| t.is_dir()))
            .filter(|child| {
                let name = child.file_name();
                let name = name.to_string_lossy();
                !name.starts_with('.') && !SKIPPED.contains(&name.as_ref())
            })
            .map(|child| child.path())
            .collect();
        // Popped in name order.
        subdirs.sort_by(|a, b| b.cmp(a));
        stack.extend(subdirs.into_iter().map(|d| (d, level + 1)));
    }
    progress(folders, hits.len());
    hits.into_values().collect()
}

fn hit<'a>(hits: &'a mut BTreeMap<String, ScanHit>, path: &Path, bare: bool) -> &'a mut ScanHit {
    hits.entry(path_key(path)).or_insert_with(|| ScanHit {
        path: path.to_path_buf(),
        worktrees: Vec::new(),
        bare,
    })
}

#[derive(Debug, PartialEq, Eq)]
enum Found {
    Repo {
        bare: bool,
    },
    /// A linked worktree of the repository at `main`.
    Worktree {
        main: PathBuf,
        bare: bool,
    },
}

fn classify(dir: &Path) -> Option<Found> {
    let dot_git = dir.join(".git");
    // `DirEntry::file_type` above does not follow links; neither does this.
    match fs::symlink_metadata(&dot_git) {
        Ok(meta) if meta.is_dir() => return Some(Found::Repo { bare: false }),
        Ok(meta) if meta.is_file() => {
            let git_dir = read_git_file(&dot_git)?;
            return Some(match worktree_main(&git_dir) {
                Some((main, bare)) => Found::Worktree { main, bare },
                // A submodule or a separate git dir: its own repository.
                None => Found::Repo { bare: false },
            });
        }
        _ => {}
    }
    let is_bare =
        dir.join("HEAD").is_file() && dir.join("objects").is_dir() && dir.join("refs").is_dir();
    is_bare.then_some(Found::Repo { bare: true })
}

/// The git dir a `.git` file points at (`gitdir: <path>`, relative to the
/// file's folder when not absolute).
fn read_git_file(file: &Path) -> Option<PathBuf> {
    let text = fs::read_to_string(file).ok()?;
    let target = text.lines().next()?.strip_prefix("gitdir:")?.trim();
    let target = PathBuf::from(target);
    Some(if target.is_absolute() {
        target
    } else {
        file.parent()?.join(target)
    })
}

/// For a linked worktree's git dir (`<common>/worktrees/<name>`), the main
/// repository's folder and whether it is bare.
fn worktree_main(git_dir: &Path) -> Option<(PathBuf, bool)> {
    let worktrees = git_dir.parent()?;
    if worktrees.file_name()? != "worktrees" {
        return None;
    }
    let common = worktrees.parent()?;
    if common.file_name()? == ".git" {
        return Some((common.parent()?.to_path_buf(), false));
    }
    Some((common.to_path_buf(), true))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_main_repository_of_a_linked_worktree() {
        assert_eq!(
            worktree_main(Path::new("/r/a/.git/worktrees/task")),
            Some((PathBuf::from("/r/a"), false))
        );
        assert_eq!(
            worktree_main(Path::new("/r/b.git/worktrees/main")),
            Some((PathBuf::from("/r/b.git"), true))
        );
        assert_eq!(worktree_main(Path::new("/r/a/.git/modules/sub")), None);
    }
}
