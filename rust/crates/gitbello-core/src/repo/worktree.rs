//! `git worktree list --porcelain -z`.

use std::path::PathBuf;

use super::{git_path, text, ParseError};

pub const WORKTREES_ARGS: &[&str] = &["worktree", "list", "--porcelain", "-z"];

const WHAT: &str = "worktree list";

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Worktree {
    pub path: PathBuf,
    /// Checked-out commit; `None` for a bare repository or an unborn branch.
    pub head: Option<String>,
    /// Full branch ref, e.g. `refs/heads/main`.
    pub branch: Option<String>,
    pub bare: bool,
    pub detached: bool,
    /// `Some` when locked; the string is the reason (may be empty).
    pub locked: Option<String>,
    /// `Some` when git considers it prunable (its folder is gone); the reason.
    pub prunable: Option<String>,
    /// The main worktree (always listed first).
    pub is_main: bool,
}

impl Worktree {
    pub fn branch_name(&self) -> Option<&str> {
        self.branch
            .as_deref()
            .map(|b| b.strip_prefix("refs/heads/").unwrap_or(b))
    }
}

pub fn parse_worktrees(output: &[u8]) -> Result<Vec<Worktree>, ParseError> {
    let mut worktrees: Vec<Worktree> = Vec::new();
    let mut current: Option<Worktree> = None;
    for field in output.split(|&b| b == 0) {
        if field.is_empty() {
            // An empty field ends a record.
            if let Some(done) = current.take() {
                worktrees.push(done);
            }
            continue;
        }
        let (key, value) = match field.iter().position(|&b| b == b' ') {
            Some(i) => (&field[..i], Some(&field[i + 1..])),
            None => (field, None),
        };
        if key == b"worktree" {
            if let Some(done) = current.take() {
                worktrees.push(done);
            }
            let path = value.ok_or_else(|| ParseError::new(WHAT, "worktree without path"))?;
            current = Some(Worktree {
                path: git_path(path),
                is_main: worktrees.is_empty(),
                ..Worktree::default()
            });
            continue;
        }
        let worktree = current.as_mut().ok_or_else(|| {
            ParseError::new(WHAT, format!("`{}` before any worktree", text(field)))
        })?;
        match key {
            b"HEAD" => worktree.head = value.map(text),
            b"branch" => worktree.branch = value.map(text),
            b"bare" => worktree.bare = true,
            b"detached" => worktree.detached = true,
            b"locked" => worktree.locked = Some(value.map(text).unwrap_or_default()),
            b"prunable" => worktree.prunable = Some(value.map(text).unwrap_or_default()),
            // Newer git versions may add attributes; ignore unknown ones.
            _ => {}
        }
    }
    if let Some(done) = current.take() {
        worktrees.push(done);
    }
    Ok(worktrees)
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "1111111111111111111111111111111111111111";

    #[test]
    fn parses_main_linked_detached_locked_and_prunable() {
        let out = format!(
            "worktree /home/a/my repo\0HEAD {A}\0branch refs/heads/main\0\0\
             worktree /home/a/my repo.worktrees/fëature\0HEAD {A}\0branch refs/heads/feature/x\0locked\0\0\
             worktree /tmp/detached\0HEAD {A}\0detached\0locked moved to usb disk\0\0\
             worktree /tmp/gone\0HEAD {A}\0branch refs/heads/gone\0prunable gitdir file points to non-existent location\0\0"
        );
        let wts = parse_worktrees(out.as_bytes()).unwrap();
        assert_eq!(wts.len(), 4);
        assert!(wts[0].is_main && !wts[1].is_main);
        assert_eq!(wts[0].path, PathBuf::from("/home/a/my repo"));
        assert_eq!(wts[0].branch_name(), Some("main"));
        assert_eq!(
            wts[1].path,
            PathBuf::from("/home/a/my repo.worktrees/fëature")
        );
        assert_eq!(wts[1].branch_name(), Some("feature/x"));
        assert_eq!(wts[1].locked.as_deref(), Some(""));
        assert!(wts[2].detached && wts[2].branch.is_none());
        assert_eq!(wts[2].locked.as_deref(), Some("moved to usb disk"));
        assert!(wts[3].prunable.as_deref().unwrap().contains("non-existent"));
    }

    #[test]
    fn parses_bare_and_missing_terminator() {
        let wts = parse_worktrees(
            b"worktree /srv/repo.git\0bare\0\0worktree /w\0HEAD abc\0branch refs/heads/x",
        )
        .unwrap();
        assert!(wts[0].bare && wts[0].head.is_none());
        assert_eq!(wts[1].head.as_deref(), Some("abc"));
    }

    #[test]
    fn rejects_attributes_before_a_worktree() {
        assert!(parse_worktrees(b"HEAD abc\0\0").is_err());
        assert!(parse_worktrees(b"worktree\0\0").is_err());
        assert!(parse_worktrees(b"").unwrap().is_empty());
    }
}
