//! Display models derived from repository state: tab and row badges, the
//! branch tree grouped by prefix, and ref labels for graph rows (PLAN §4).

use std::collections::{HashMap, HashSet};

use crate::repo::{FileState, Head, Operation, Ref, RefKind, RepoStatus};

/// Live status shown on tabs, worktree rows and branch rows.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Badge {
    /// Changed, staged, untracked and conflicted files (ignored excluded).
    pub changed: usize,
    pub conflicts: usize,
    pub ahead: u32,
    pub behind: u32,
    /// No upstream (or a gone one): `ahead` counts commits on no remote.
    pub unpublished: bool,
    pub operation: Option<Operation>,
    /// Branch name, `(detached)` or empty when unknown.
    pub head: String,
}

impl Badge {
    pub fn new(status: Option<&RepoStatus>, operation: Option<Operation>) -> Self {
        let Some(status) = status else {
            return Self {
                operation,
                ..Self::default()
            };
        };
        let changes = status
            .changes
            .iter()
            .filter(|c| c.state != FileState::Ignored);
        Self {
            changed: changes.clone().count(),
            conflicts: changes
                .filter(|c| matches!(c.state, FileState::Unmerged(_)))
                .count(),
            ahead: status.ahead,
            behind: status.behind,
            unpublished: status.unpublished,
            operation,
            head: match &status.head {
                Head::Branch(name) => name.clone(),
                Head::Detached => "(detached)".to_owned(),
                Head::Unknown => String::new(),
            },
        }
    }

    /// Compact text such as `3 ↑1 ↓2`, empty when there is nothing to show.
    pub fn summary(&self) -> String {
        let mut parts = Vec::new();
        if let Some(op) = self.operation {
            parts.push(operation_label(op).to_owned());
        }
        if self.conflicts > 0 {
            parts.push(format!("⚠{}", self.conflicts));
        }
        if self.changed > 0 {
            parts.push(self.changed.to_string());
        }
        if self.ahead > 0 {
            parts.push(format!("↑{}", self.ahead));
        }
        if self.behind > 0 {
            parts.push(format!("↓{}", self.behind));
        }
        parts.join(" ")
    }
}

pub fn operation_label(op: Operation) -> &'static str {
    match op {
        Operation::Merge => "merging",
        Operation::CherryPick => "cherry-picking",
        Operation::Revert => "reverting",
        Operation::Rebase { .. } => "rebasing",
        Operation::ApplyMailbox => "applying patches",
        Operation::Bisect => "bisecting",
    }
}

/// A node in a branch tree: a folder (`feature/`) or a branch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BranchNode {
    /// Last path segment, e.g. `login` for `feature/login`.
    pub name: String,
    /// Full ref name for branches, `None` for folders.
    pub ref_name: Option<String>,
    pub children: Vec<BranchNode>,
}

/// Groups names like `feature/a`, `feature/b`, `main` into folders. `items`
/// are `(display name, full ref name)` pairs. Folders sort before branches,
/// each alphabetically (case-insensitive).
pub fn group_by_prefix<'a>(items: impl IntoIterator<Item = (&'a str, &'a str)>) -> Vec<BranchNode> {
    let mut root: Vec<BranchNode> = Vec::new();
    for (display, ref_name) in items {
        let segments: Vec<&str> = display.split('/').collect();
        let mut level = &mut root;
        for (i, segment) in segments.iter().enumerate() {
            let is_leaf = i + 1 == segments.len();
            let pos = level
                .iter()
                .position(|n| n.name == *segment && n.ref_name.is_none() != is_leaf);
            let index = match pos {
                Some(index) => index,
                None => {
                    level.push(BranchNode {
                        name: (*segment).to_owned(),
                        ref_name: is_leaf.then(|| ref_name.to_owned()),
                        children: Vec::new(),
                    });
                    level.len() - 1
                }
            };
            level = &mut level[index].children;
        }
    }
    sort_nodes(&mut root);
    root
}

fn sort_nodes(nodes: &mut [BranchNode]) {
    nodes.sort_by(|a, b| {
        a.ref_name
            .is_some()
            .cmp(&b.ref_name.is_some())
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    for node in nodes {
        sort_nodes(&mut node.children);
    }
}

/// Local branches grouped by prefix.
pub fn local_branch_tree(refs: &[Ref]) -> Vec<BranchNode> {
    group_by_prefix(
        refs.iter()
            .filter(|r| r.kind == RefKind::Branch)
            .map(|r| (r.short_name.as_str(), r.name.as_str())),
    )
}

/// Remote branches: one folder per remote, branches grouped inside. The
/// symbolic `<remote>/HEAD` is left out.
pub fn remote_branch_tree(refs: &[Ref]) -> Vec<BranchNode> {
    let mut remotes: Vec<&str> = refs
        .iter()
        .filter_map(|r| match &r.kind {
            RefKind::RemoteBranch { remote } => Some(remote.as_str()),
            _ => None,
        })
        .collect();
    remotes.sort_unstable();
    remotes.dedup();
    remotes
        .into_iter()
        .map(|remote| BranchNode {
            name: remote.to_owned(),
            ref_name: None,
            children: group_by_prefix(
                refs.iter()
                    .filter(|r| r.symref_target.is_none())
                    .filter(
                        |r| matches!(&r.kind, RefKind::RemoteBranch { remote: rr } if rr == remote),
                    )
                    .filter_map(|r| r.remote_branch_name().map(|b| (b, r.name.as_str()))),
            ),
        })
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LabelKind {
    Branch,
    RemoteBranch,
    Tag,
}

/// A ref label drawn on a graph row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefLabel {
    pub name: String,
    pub kind: LabelKind,
    /// The branch checked out in this worktree.
    pub is_head: bool,
    /// A remote branch's remote (`origin`), so its prefix can be drawn apart.
    pub remote: Option<String>,
    /// For a local branch, the remote branches at the same commit that it
    /// tracks (or that share its name, without an upstream), such as
    /// `origin/main`. They get no label of their own.
    pub remotes: Vec<String>,
}

/// Labels per commit hash (hex), for decorating graph rows. Within a commit:
/// the checked-out branch first, then branches, remote branches, tags. A
/// local branch and its remote branch at the same commit are one label.
pub fn labels_by_commit(refs: &[Ref]) -> HashMap<String, Vec<RefLabel>> {
    let mut by_commit: HashMap<&str, Vec<&Ref>> = HashMap::new();
    for r in refs {
        if r.symref_target.is_some() || matches!(r.kind, RefKind::Stash | RefKind::Other) {
            continue;
        }
        by_commit.entry(r.commit()).or_default().push(r);
    }
    by_commit
        .into_iter()
        .map(|(commit, refs)| (commit.to_owned(), commit_labels(&refs)))
        .collect()
}

/// The labels of the refs at one commit, sorted for display.
fn commit_labels(refs: &[&Ref]) -> Vec<RefLabel> {
    let mut merged: HashSet<&str> = HashSet::new();
    let mut labels = Vec::with_capacity(refs.len());
    for local in refs.iter().filter(|r| r.kind == RefKind::Branch) {
        let mut remotes = Vec::new();
        for remote in refs {
            if !merged.contains(remote.name.as_str()) && tracks(local, remote) {
                merged.insert(remote.name.as_str());
                remotes.push(remote.short_name.clone());
            }
        }
        remotes.sort_by_key(|name| name.to_lowercase());
        labels.push(RefLabel {
            name: local.short_name.clone(),
            kind: LabelKind::Branch,
            is_head: local.is_head,
            remote: None,
            remotes,
        });
    }
    for r in refs {
        let (kind, remote) = match &r.kind {
            RefKind::RemoteBranch { remote } if !merged.contains(r.name.as_str()) => {
                (LabelKind::RemoteBranch, Some(remote.clone()))
            }
            RefKind::Tag => (LabelKind::Tag, None),
            _ => continue,
        };
        labels.push(RefLabel {
            name: r.short_name.clone(),
            kind,
            is_head: false,
            remote,
            remotes: Vec::new(),
        });
    }
    labels.sort_by_key(|l| (!l.is_head, l.kind as u8, l.name.to_lowercase()));
    labels
}

/// Whether `remote` is `local`'s remote branch: its upstream, or one with the
/// same name when it has none.
fn tracks(local: &Ref, remote: &Ref) -> bool {
    match &local.upstream {
        Some(upstream) => *upstream == remote.name,
        None => remote.remote_branch_name() == Some(local.short_name.as_str()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::repo::{Change, FileChange, Tracking};
    use std::path::PathBuf;

    fn branch(name: &str, kind: RefKind, commit: &str, head: bool) -> Ref {
        let short = name
            .strip_prefix("refs/heads/")
            .or_else(|| name.strip_prefix("refs/remotes/"))
            .or_else(|| name.strip_prefix("refs/tags/"))
            .unwrap_or(name);
        Ref {
            name: name.to_owned(),
            kind,
            short_name: short.to_owned(),
            target: commit.to_owned(),
            peeled: None,
            upstream: None,
            tracking: Tracking::default(),
            is_head: head,
            symref_target: None,
            worktree: None,
            committed_at: None,
        }
    }

    fn names(nodes: &[BranchNode]) -> Vec<String> {
        nodes
            .iter()
            .map(|n| {
                if n.children.is_empty() {
                    n.name.clone()
                } else {
                    format!("{}/[{}]", n.name, names(&n.children).join(","))
                }
            })
            .collect()
    }

    #[test]
    fn groups_branches_by_prefix_with_folders_first() {
        let tree = group_by_prefix([
            ("main", "refs/heads/main"),
            ("feature/login", "refs/heads/feature/login"),
            ("Bugfix/x", "refs/heads/Bugfix/x"),
            ("feature/deep/one", "refs/heads/feature/deep/one"),
            ("develop", "refs/heads/develop"),
        ]);
        assert_eq!(
            names(&tree),
            [
                "Bugfix/[x]",
                "feature/[deep/[one],login]",
                "develop",
                "main"
            ]
        );
        assert_eq!(tree[2].ref_name.as_deref(), Some("refs/heads/develop"));
        assert_eq!(tree[1].ref_name, None);
    }

    #[test]
    fn remote_tree_has_one_folder_per_remote_without_head() {
        let origin = |_branch: &str| RefKind::RemoteBranch {
            remote: "origin".into(),
        };
        let mut head = branch("refs/remotes/origin/HEAD", origin("HEAD"), "a", false);
        head.symref_target = Some("refs/remotes/origin/main".into());
        let refs = vec![
            head,
            branch("refs/remotes/origin/main", origin("main"), "a", false),
            branch("refs/remotes/origin/feature/x", origin("x"), "b", false),
            branch(
                "refs/remotes/up/main",
                RefKind::RemoteBranch {
                    remote: "up".into(),
                },
                "c",
                false,
            ),
            branch("refs/heads/main", RefKind::Branch, "a", true),
        ];
        let tree = remote_branch_tree(&refs);
        assert_eq!(names(&tree), ["origin/[feature/[x],main]", "up/[main]"]);
        assert_eq!(names(&local_branch_tree(&refs)), ["main"]);
    }

    #[test]
    fn labels_group_refs_per_commit_with_head_first() {
        let refs = vec![
            branch("refs/tags/v1", RefKind::Tag, "a", false),
            branch(
                "refs/remotes/origin/main",
                RefKind::RemoteBranch {
                    remote: "origin".into(),
                },
                "a",
                false,
            ),
            branch("refs/heads/zeta", RefKind::Branch, "a", false),
            branch("refs/heads/main", RefKind::Branch, "a", true),
            branch("refs/stash", RefKind::Stash, "s", false),
            branch("refs/heads/other", RefKind::Branch, "b", false),
        ];
        let labels = labels_by_commit(&refs);
        let names: Vec<&str> = labels["a"].iter().map(|l| l.name.as_str()).collect();
        assert_eq!(names, ["main", "zeta", "v1"]);
        assert!(labels["a"][0].is_head);
        assert_eq!(labels["a"][0].remotes, ["origin/main"]);
        assert!(!labels.contains_key("s"));
        assert_eq!(labels["b"].len(), 1);
    }

    #[test]
    fn a_local_branch_and_its_remote_branch_at_the_same_commit_are_one_label() {
        let remote = |name: &str, remote: &str, commit: &str| {
            branch(
                &format!("refs/remotes/{remote}/{name}"),
                RefKind::RemoteBranch {
                    remote: remote.into(),
                },
                commit,
                false,
            )
        };
        let mut renamed = branch("refs/heads/topic", RefKind::Branch, "a", false);
        renamed.upstream = Some("refs/remotes/origin/feature/topic".into());
        let mut tracked = branch("refs/heads/main", RefKind::Branch, "a", true);
        tracked.upstream = Some("refs/remotes/origin/main".into());
        let refs = vec![
            tracked,
            renamed,
            // No upstream: the same name on any remote counts.
            branch("refs/heads/docs", RefKind::Branch, "a", false),
            remote("main", "origin", "a"),
            remote("main", "upstream", "a"),
            remote("feature/topic", "origin", "a"),
            remote("docs", "origin", "a"),
            remote("docs", "fork", "a"),
            // Its remote branch moved on: two labels.
            branch("refs/heads/stale", RefKind::Branch, "a", false),
            remote("stale", "origin", "b"),
        ];
        let labels = labels_by_commit(&refs);
        let at_a: Vec<(&str, Vec<String>, Option<String>)> = labels["a"]
            .iter()
            .map(|l| (l.name.as_str(), l.remotes.clone(), l.remote.clone()))
            .collect();
        assert_eq!(
            at_a,
            [
                ("main", vec!["origin/main".to_owned()], None),
                ("docs", vec!["fork/docs".into(), "origin/docs".into()], None),
                ("stale", vec![], None),
                ("topic", vec!["origin/feature/topic".into()], None),
                // Not main's upstream, so its own label.
                ("upstream/main", vec![], Some("upstream".into())),
            ]
        );
        assert_eq!(labels["b"][0].name, "origin/stale");
        assert_eq!(labels["b"][0].kind, LabelKind::RemoteBranch);
    }

    #[test]
    fn badge_counts_changes_conflicts_and_tracking() {
        let change = |path: &str, state| FileChange {
            path: PathBuf::from(path),
            original_path: None,
            state,
            score: None,
            submodule: false,
            index_mode: None,
            index_oid: None,
        };
        let status = RepoStatus {
            head: Head::Branch("main".into()),
            oid: Some("a".into()),
            upstream: Some("origin/main".into()),
            ahead: 2,
            behind: 1,
            unpublished: false,
            stash_count: 0,
            changes: vec![
                change(
                    "a",
                    FileState::Tracked {
                        index: Change::Modified,
                        worktree: Change::Unmodified,
                    },
                ),
                change("b", FileState::Untracked),
                change("c", FileState::Ignored),
                change(
                    "d",
                    FileState::Unmerged(crate::repo::Conflict::BothModified),
                ),
            ],
        };
        let badge = Badge::new(Some(&status), Some(Operation::Merge));
        assert_eq!(
            (badge.changed, badge.conflicts, badge.head.as_str()),
            (3, 1, "main")
        );
        assert_eq!(badge.summary(), "merging ⚠1 3 ↑2 ↓1");
        assert_eq!(Badge::new(None, None).summary(), "");
    }
}
