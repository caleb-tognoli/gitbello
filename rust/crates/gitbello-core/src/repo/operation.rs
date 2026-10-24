//! Repository directories and the in-progress operation (merge, rebase, ...).

use std::path::{Path, PathBuf};

use super::{git_path, text, ParseError};

/// `git rev-parse` for the per-worktree git dir, the shared common dir and
/// whether the repository is bare. Run `--show-toplevel` separately when not
/// bare (it fails in bare repositories).
pub const REPO_PATHS_ARGS: &[&str] = &[
    "rev-parse",
    "--path-format=absolute",
    "--git-dir",
    "--git-common-dir",
    "--is-bare-repository",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepoPaths {
    /// Per-worktree git dir (`.git`, or `.git/worktrees/<name>` for a linked worktree).
    pub git_dir: PathBuf,
    /// Shared dir with objects and refs.
    pub common_dir: PathBuf,
    pub bare: bool,
}

pub fn parse_repo_paths(output: &[u8]) -> Result<RepoPaths, ParseError> {
    let lines: Vec<&[u8]> = output
        .split(|&b| b == b'\n')
        .map(|l| l.strip_suffix(b"\r").unwrap_or(l))
        .filter(|l| !l.is_empty())
        .collect();
    let [git_dir, common_dir, bare] = lines.as_slice() else {
        return Err(ParseError::new(
            "rev-parse",
            format!("expected 3 lines, got `{}`", text(output)),
        ));
    };
    Ok(RepoPaths {
        git_dir: git_path(git_dir),
        common_dir: git_path(common_dir),
        bare: *bare == b"true",
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Operation {
    Merge,
    CherryPick,
    Revert,
    Rebase { interactive: bool },
    /// `git am`.
    ApplyMailbox,
    Bisect,
}

/// Detects an in-progress operation from marker files in the per-worktree git
/// dir, the same files git itself checks.
pub fn detect_operation(git_dir: &Path) -> Option<Operation> {
    let exists = |name: &str| git_dir.join(name).exists();
    if exists("rebase-merge") {
        return Some(Operation::Rebase {
            interactive: exists("rebase-merge/interactive"),
        });
    }
    if exists("rebase-apply") {
        return Some(if exists("rebase-apply/applying") {
            Operation::ApplyMailbox
        } else {
            Operation::Rebase { interactive: false }
        });
    }
    if exists("MERGE_HEAD") {
        return Some(Operation::Merge);
    }
    if exists("CHERRY_PICK_HEAD") {
        return Some(Operation::CherryPick);
    }
    if exists("REVERT_HEAD") {
        return Some(Operation::Revert);
    }
    if exists("BISECT_LOG") {
        return Some(Operation::Bisect);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_rev_parse_paths() {
        let paths = parse_repo_paths(b"/r/.git/worktrees/x\n/r/.git\nfalse\n").unwrap();
        assert_eq!(paths.git_dir, PathBuf::from("/r/.git/worktrees/x"));
        assert_eq!(paths.common_dir, PathBuf::from("/r/.git"));
        assert!(!paths.bare);
        assert!(parse_repo_paths(b"C:/r.git\r\nC:/r.git\r\ntrue\r\n").unwrap().bare);
        assert!(parse_repo_paths(b"/r/.git\n").is_err());
    }

    #[test]
    fn detects_operations_from_marker_files() {
        let dir = std::env::temp_dir().join(format!("gitbello-op-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let touch = |name: &str| {
            let path = dir.join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, "").unwrap();
        };
        assert_eq!(detect_operation(&dir), None);
        touch("BISECT_LOG");
        assert_eq!(detect_operation(&dir), Some(Operation::Bisect));
        touch("REVERT_HEAD");
        assert_eq!(detect_operation(&dir), Some(Operation::Revert));
        touch("CHERRY_PICK_HEAD");
        assert_eq!(detect_operation(&dir), Some(Operation::CherryPick));
        touch("MERGE_HEAD");
        assert_eq!(detect_operation(&dir), Some(Operation::Merge));
        touch("rebase-apply/applying");
        assert_eq!(detect_operation(&dir), Some(Operation::ApplyMailbox));
        touch("rebase-merge/interactive");
        assert_eq!(
            detect_operation(&dir),
            Some(Operation::Rebase { interactive: true })
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
