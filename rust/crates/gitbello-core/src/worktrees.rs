//! Worktree helpers for the new-task and cleanup flows (PLAN §4): where a
//! new task's worktree goes, which branch tasks start from, and which
//! worktrees cleanup offers to remove.

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::repo::{Ref, RefKind, Worktree};
use crate::sidebar::Badge;

/// `feature/Login page` → `feature-Login-page`: one folder name, keeping
/// letters, digits, `.`, `_` and `-`; anything else becomes a single `-`.
pub fn branch_slug(branch: &str) -> String {
    let mut out = String::new();
    for c in branch.chars() {
        if c.is_alphanumeric() || c == '.' || c == '_' || c == '-' {
            out.push(c);
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push('-');
        }
    }
    let slug = out.trim_matches(|c| c == '-' || c == '.');
    if slug.is_empty() {
        "worktree".to_owned()
    } else {
        slug.to_owned()
    }
}

/// Expands the `worktree_template` setting for a task on `branch`. `main`
/// is the main worktree (or the bare repository). Keys: `{repo_parent}`,
/// `{repo_name}` (without a `.git` suffix), `{repo}`, `{branch_slug}` and
/// `{branch}`. A relative result is taken relative to `main`.
pub fn worktree_path(template: &str, main: &Path, branch: &str) -> PathBuf {
    let name = main
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let name = name.strip_suffix(".git").unwrap_or(&name).to_owned();
    let parent = main.parent().unwrap_or(main);
    let text = template
        .replace("{repo_parent}", &parent.to_string_lossy())
        .replace("{repo_name}", &name)
        .replace("{repo}", &main.to_string_lossy())
        .replace("{branch_slug}", &branch_slug(branch))
        .replace("{branch}", branch);
    // Templates use `/`; show native separators.
    let text = if cfg!(windows) {
        text.replace('/', "\\")
    } else {
        text
    };
    let path = PathBuf::from(text);
    if path.is_relative() {
        main.join(path)
    } else {
        path
    }
}

/// Why a new worktree cannot be created at `path` (it must be missing or an
/// empty folder), or `None`.
pub fn new_worktree_path_error(path: &Path) -> Option<&'static str> {
    if path.as_os_str().is_empty() {
        return Some("Enter a folder.");
    }
    match fs::read_dir(path) {
        Ok(mut entries) => entries
            .next()
            .is_some()
            .then_some("That folder already exists and is not empty."),
        Err(err) if err.kind() == io::ErrorKind::NotFound => None,
        Err(_) if path.exists() => Some("Something that is not an empty folder is there."),
        Err(_) => Some("That folder cannot be used."),
    }
}

/// Where new tasks start and what cleanup compares against, as a short ref
/// name: `remote`'s default branch (its `HEAD`, else `main` or `master`),
/// else a local `main` or `master`.
pub fn default_base(refs: &[Ref], remote: Option<&str>) -> Option<String> {
    let find = |name: &str| refs.iter().find(|r| r.name == name);
    if let Some(remote) = remote {
        let head = format!("refs/remotes/{remote}/HEAD");
        if let Some(target) = find(&head).and_then(|r| r.symref_target.as_deref()) {
            if let Some(short) = target.strip_prefix("refs/remotes/") {
                return Some(short.to_owned());
            }
        }
        for branch in ["main", "master"] {
            if find(&format!("refs/remotes/{remote}/{branch}")).is_some() {
                return Some(format!("{remote}/{branch}"));
            }
        }
    }
    ["main", "master"]
        .into_iter()
        .find(|b| find(&format!("refs/heads/{b}")).is_some())
        .map(str::to_owned)
}

/// Why cleanup offers a worktree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CleanupReason {
    /// Its branch is merged into the base.
    Merged,
    /// Its branch's upstream was deleted (often after a squash merge).
    UpstreamGone,
}

/// A worktree the cleanup flow offers to remove.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CleanupCandidate {
    pub path: PathBuf,
    /// Short branch name.
    pub branch: String,
    pub reason: CleanupReason,
    /// Changed files, when known (removing it discards them).
    pub changed: Option<usize>,
    /// Commits not on the upstream (when it still has one).
    pub ahead: u32,
    pub locked: bool,
}

/// Linked worktrees whose branch is merged into `base` (`merged` lists the
/// full names of local branches merged into it) or whose upstream is gone.
/// The main worktree, `current`, detached or missing worktrees and the
/// base's own branch are never offered.
pub fn cleanup_candidates(
    worktrees: &[Worktree],
    refs: &[Ref],
    merged: &[String],
    base: &str,
    badges: &HashMap<PathBuf, Badge>,
    current: &Path,
) -> Vec<CleanupCandidate> {
    let base_branch = base.rsplit('/').next().unwrap_or(base);
    let same = |a: &Path, b: &Path| a.components().eq(b.components());
    worktrees
        .iter()
        .filter(|wt| !wt.is_main && !wt.bare && wt.prunable.is_none() && !same(&wt.path, current))
        .filter_map(|wt| {
            let full = wt.branch.as_deref()?;
            let branch = wt.branch_name()?;
            if branch == base || branch == base_branch {
                return None;
            }
            let r = refs
                .iter()
                .find(|r| r.kind == RefKind::Branch && r.name == full);
            let reason = if merged.iter().any(|m| m == full) {
                CleanupReason::Merged
            } else if r.is_some_and(|r| r.tracking.gone) {
                CleanupReason::UpstreamGone
            } else {
                return None;
            };
            Some(CleanupCandidate {
                path: wt.path.clone(),
                branch: branch.to_owned(),
                reason,
                changed: badges.get(&wt.path).map(|b| b.changed),
                ahead: r.map_or(0, |r| r.tracking.ahead),
                locked: wt.locked.is_some(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::repo::Tracking;

    #[test]
    fn slugs_keep_one_folder_name() {
        assert_eq!(branch_slug("feature/login"), "feature-login");
        assert_eq!(branch_slug("fix  spaces//x"), "fix-spaces-x");
        assert_eq!(branch_slug("wörk_1.2"), "wörk_1.2");
        assert_eq!(branch_slug("/.-x-./"), "x");
        assert_eq!(branch_slug("///"), "worktree");
    }

    #[test]
    fn expands_the_template() {
        let main = Path::new("/home/ädä/dev/my repo");
        let path = worktree_path(crate::config::DEFAULT_WORKTREE_TEMPLATE, main, "feature/x");
        assert_eq!(path, main.join(".worktrees").join("feature-x"));
        let bare = worktree_path(
            "{repo_parent}/{repo_name}-{branch}",
            Path::new("/srv/proj.git"),
            "b",
        );
        assert!(bare.ends_with("proj-b"), "{}", bare.display());
        let relative = worktree_path("wt/{branch_slug}", main, "a/b");
        assert!(relative.starts_with(main) && relative.ends_with("a-b"));
    }

    #[test]
    fn new_worktree_paths_must_be_missing_or_empty() {
        let dir = std::env::temp_dir().join(format!("gitbello wörktrees {}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        assert_eq!(new_worktree_path_error(&dir), None);
        fs::create_dir_all(&dir).unwrap();
        assert_eq!(new_worktree_path_error(&dir), None);
        fs::write(dir.join("f"), "x").unwrap();
        assert!(new_worktree_path_error(&dir).is_some());
        assert!(new_worktree_path_error(&dir.join("f")).is_some());
        assert!(new_worktree_path_error(Path::new("")).is_some());
        fs::remove_dir_all(&dir).unwrap();
    }

    fn reference(name: &str, kind: RefKind, symref: Option<&str>, gone: bool, ahead: u32) -> Ref {
        Ref {
            name: name.to_owned(),
            kind,
            short_name: name
                .trim_start_matches("refs/heads/")
                .trim_start_matches("refs/remotes/")
                .to_owned(),
            target: "a".into(),
            peeled: None,
            upstream: None,
            tracking: Tracking {
                ahead,
                behind: 0,
                gone,
            },
            is_head: false,
            symref_target: symref.map(str::to_owned),
            worktree: None,
            committed_at: None,
        }
    }

    #[test]
    fn default_base_prefers_the_remote_head() {
        let origin = || RefKind::RemoteBranch {
            remote: "origin".into(),
        };
        let mut refs = vec![
            reference("refs/heads/master", RefKind::Branch, None, false, 0),
            reference("refs/remotes/origin/main", origin(), None, false, 0),
        ];
        assert_eq!(
            default_base(&refs, Some("origin")).as_deref(),
            Some("origin/main")
        );
        refs.push(reference(
            "refs/remotes/origin/develop",
            origin(),
            None,
            false,
            0,
        ));
        refs.push(reference(
            "refs/remotes/origin/HEAD",
            origin(),
            Some("refs/remotes/origin/develop"),
            false,
            0,
        ));
        assert_eq!(
            default_base(&refs, Some("origin")).as_deref(),
            Some("origin/develop")
        );
        assert_eq!(default_base(&refs, None).as_deref(), Some("master"));
        assert_eq!(default_base(&[], None), None);
    }

    #[test]
    fn cleanup_offers_merged_and_gone_linked_worktrees() {
        let wt = |path: &str, branch: Option<&str>| Worktree {
            path: PathBuf::from(path),
            head: Some("a".into()),
            branch: branch.map(|b| format!("refs/heads/{b}")),
            ..Worktree::default()
        };
        let mut main = wt("/r", Some("main"));
        main.is_main = true;
        let mut locked = wt("/w/locked", Some("done-too"));
        locked.locked = Some(String::new());
        let mut missing = wt("/w/missing", Some("merged-missing"));
        missing.prunable = Some("gone".into());
        let worktrees = vec![
            main,
            wt("/w/done", Some("done")),
            wt("/w/squashed", Some("squashed")),
            wt("/w/active", Some("active")),
            wt("/w/detached", None),
            wt("/w/main-copy", Some("main")),
            locked,
            missing,
            wt("/w/current", Some("current-merged")),
        ];
        let refs = vec![
            reference("refs/heads/done", RefKind::Branch, None, false, 0),
            reference("refs/heads/squashed", RefKind::Branch, None, true, 2),
            reference("refs/heads/active", RefKind::Branch, None, false, 1),
        ];
        let merged: Vec<String> = [
            "done",
            "done-too",
            "main",
            "merged-missing",
            "current-merged",
        ]
        .iter()
        .map(|b| format!("refs/heads/{b}"))
        .collect();
        let badges: HashMap<PathBuf, Badge> = [(
            PathBuf::from("/w/done"),
            Badge {
                changed: 3,
                ..Badge::default()
            },
        )]
        .into();
        let found = cleanup_candidates(
            &worktrees,
            &refs,
            &merged,
            "origin/main",
            &badges,
            Path::new("/w/current"),
        );
        let summary: Vec<(&str, CleanupReason, Option<usize>, u32, bool)> = found
            .iter()
            .map(|c| (c.branch.as_str(), c.reason, c.changed, c.ahead, c.locked))
            .collect();
        assert_eq!(
            summary,
            [
                ("done", CleanupReason::Merged, Some(3), 0, false),
                ("squashed", CleanupReason::UpstreamGone, None, 2, false),
                ("done-too", CleanupReason::Merged, None, 0, true),
            ]
        );
    }
}
