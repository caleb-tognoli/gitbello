//! Write operations (PLAN §5, M5 and M6): syncing with remotes, branches,
//! tags, checkout, cherry-pick and worktrees. Plain data for the
//! [`crate::backend::GitBackend`] methods; the runtime decides what to run
//! and in which order.

use std::path::PathBuf;

use crate::repo::Operation;

/// How `git pull` integrates the upstream (the `pull_mode` setting).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PullMode {
    /// Refuses to pull diverged branches (the default).
    #[default]
    FastForwardOnly,
    Merge,
    Rebase,
}

impl PullMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::FastForwardOnly => "ff-only",
            Self::Merge => "merge",
            Self::Rebase => "rebase",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "ff-only" => Some(Self::FastForwardOnly),
            "merge" => Some(Self::Merge),
            "rebase" => Some(Self::Rebase),
            _ => None,
        }
    }
}

/// Talking to remotes. Each reports `--progress` lines while it runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncOp {
    /// `git fetch --prune` of one remote, or of all of them.
    Fetch {
        remote: Option<String>,
    },
    /// `git pull` of the current branch's upstream; local changes are
    /// stashed around it (`--autostash`).
    Pull {
        mode: PullMode,
    },
    Push(PushSpec),
}

/// One `git push` invocation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushSpec {
    pub remote: String,
    /// Full refspecs, such as `refs/heads/topic:refs/heads/topic` or `refs/tags/v1`.
    pub refspecs: Vec<String>,
    /// `-u`: make the pushed branch track its remote counterpart.
    pub set_upstream: bool,
    /// Force push, refused unless the remote branch is still at this commit
    /// (empty: it must not exist). Pinned to what the user saw, so a
    /// background fetch cannot widen it as plain `--force-with-lease` would.
    pub force_with_lease: Option<String>,
}

impl PushSpec {
    /// Pushes local `branch` to `remote`: to `upstream_branch` (the branch
    /// name on the remote) when it has one, otherwise to the same name with
    /// the upstream set.
    pub fn branch(
        remote: &str,
        branch: &str,
        upstream_branch: Option<&str>,
        force_with_lease: Option<&str>,
    ) -> Self {
        let target = upstream_branch.unwrap_or(branch);
        Self {
            remote: remote.to_owned(),
            refspecs: vec![format!("refs/heads/{branch}:refs/heads/{target}")],
            set_upstream: upstream_branch.is_none(),
            force_with_lease: force_with_lease.map(str::to_owned),
        }
    }

    pub fn tag(remote: &str, tag: &str) -> Self {
        Self {
            remote: remote.to_owned(),
            refspecs: vec![format!("refs/tags/{tag}")],
            set_upstream: false,
            force_with_lease: None,
        }
    }

    /// `--force-with-lease=<remote ref>:<expected>` for the first refspec's
    /// destination.
    pub fn lease_arg(&self) -> Option<String> {
        let expected = self.force_with_lease.as_deref()?;
        let destination = self.refspecs.first()?.rsplit(':').next()?;
        Some(format!("--force-with-lease={destination}:{expected}"))
    }
}

/// Branch names others usually build on; Sync never makes a force push of
/// these its main action.
pub fn is_shared_branch_name(name: &str) -> bool {
    matches!(
        name,
        "main" | "master" | "develop" | "development" | "trunk"
    ) || name.starts_with("release/")
}

/// The current branch diverged from its upstream only because you rewrote
/// commits you had pushed (see [`crate::merge::HeadInfo::rewritten`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UpstreamRewrite {
    /// The branch is the remote's default branch or a shared-looking one
    /// ([`is_shared_branch_name`]).
    pub shared: bool,
}

/// What to check out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckoutTarget {
    /// A local branch (short name).
    Branch(String),
    /// Creates local branch `local` tracking `remote_ref` (`refs/remotes/...`).
    Track { remote_ref: String, local: String },
    /// A commit, detaching HEAD.
    Detach(String),
}

impl CheckoutTarget {
    /// Name shown to the user (`topic`, `origin/topic`, `abc1234`).
    pub fn display_name(&self) -> String {
        match self {
            Self::Branch(name) => name.clone(),
            Self::Track { remote_ref, .. } => remote_ref
                .strip_prefix("refs/remotes/")
                .unwrap_or(remote_ref)
                .to_owned(),
            Self::Detach(oid) => oid.chars().take(7).collect(),
        }
    }
}

/// What a checkout does with local changes (PLAN §4 Shelves).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckoutChanges {
    /// Nothing: git switches if the changes do not get in the way.
    Keep,
    /// Stash them, switch, and re-apply them on the new branch.
    Bring,
    /// Leave them on the current branch as an automatic shelf, then switch.
    Leave,
}

impl CheckoutChanges {
    pub fn from_id(id: &str) -> Option<Self> {
        match id {
            "keep" => Some(Self::Keep),
            "bring" => Some(Self::Bring),
            "leave" => Some(Self::Leave),
            _ => None,
        }
    }
}

/// Local ref and history changes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefOp {
    Checkout(CheckoutTarget),
    /// `start` is any commit-ish (a branch name, `refs/remotes/...`, a hash).
    CreateBranch {
        name: String,
        start: String,
        checkout: bool,
    },
    RenameBranch {
        old: String,
        new: String,
    },
    /// `force` deletes a branch that is not merged.
    DeleteBranch {
        name: String,
        force: bool,
    },
    /// `upstream` is a remote-tracking short name (`origin/topic`); `None` unsets it.
    SetUpstream {
        branch: String,
        upstream: Option<String>,
    },
    /// Annotated when `message` is given.
    CreateTag {
        name: String,
        target: String,
        message: Option<String>,
    },
    DeleteTag {
        name: String,
    },
    /// Deletes ref `name` (full name), such as a stale remote branch.
    DeleteRef {
        name: String,
    },
    AddRemote {
        name: String,
        url: String,
    },
    RenameRemote {
        old: String,
        new: String,
    },
    RemoveRemote {
        name: String,
    },
    /// Sets the fetch and push URL.
    SetRemoteUrl {
        name: String,
        url: String,
    },
    /// Merge commits are picked against their first parent.
    /// Several commits are applied oldest first, as listed (git's
    /// sequencer); a merge commit only alone.
    CherryPick {
        commits: Vec<String>,
    },
    /// Aborts the operation in progress.
    Abort(Operation),
}

impl RefOp {
    /// Job label, also used by the UI to match results to requests.
    pub fn label(&self) -> &'static str {
        match self {
            Self::Checkout(_) => CHECKOUT_JOB_LABEL,
            Self::CreateBranch { .. } => "create branch",
            Self::RenameBranch { .. } => "rename branch",
            Self::DeleteBranch { .. } => "delete branch",
            Self::SetUpstream { .. } => "set upstream",
            Self::CreateTag { .. } => "create tag",
            Self::DeleteTag { .. } => "delete tag",
            Self::DeleteRef { .. } => "delete ref",
            Self::AddRemote { .. } => "add remote",
            Self::RenameRemote { .. } => "rename remote",
            Self::RemoveRemote { .. } => "remove remote",
            Self::SetRemoteUrl { .. } => "set remote URL",
            Self::CherryPick { .. } => "cherry-pick",
            Self::Abort(_) => "abort",
        }
    }
}

/// Worktree changes (`git worktree ...`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorktreeOp {
    /// Checks out `branch` in a new worktree at `path`; with `start`, creates
    /// `branch` there first (without tracking `start`).
    Add {
        path: PathBuf,
        branch: String,
        start: Option<String>,
    },
    /// `force` also removes a worktree with local changes or a lock.
    Remove {
        path: PathBuf,
        force: bool,
    },
    Lock {
        path: PathBuf,
        reason: String,
    },
    Unlock {
        path: PathBuf,
    },
    /// Forgets worktrees whose folders are gone.
    Prune,
}

impl WorktreeOp {
    pub fn label(&self) -> &'static str {
        match self {
            Self::Add { .. } => "add worktree",
            Self::Remove { .. } => "remove worktree",
            Self::Lock { .. } => "lock worktree",
            Self::Unlock { .. } => "unlock worktree",
            Self::Prune => "prune worktrees",
        }
    }
}

/// The new-task flow (PLAN §4): a branch from `base` in a new worktree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewTask {
    pub branch: String,
    /// Commit-ish to start from, such as `origin/main`.
    pub base: String,
    pub path: PathBuf,
    /// Fetched first so the base is current.
    pub fetch_remote: Option<String>,
    /// The branch tracks `base`, a remote-tracking branch of the same name
    /// (checking out a remote branch), instead of starting from it.
    pub track_base: bool,
}

pub const NEW_TASK_JOB_LABEL: &str = "new task";
pub const CLEANUP_JOB_LABEL: &str = "clean up worktrees";
pub const FETCH_JOB_LABEL: &str = "fetch";
pub const AUTO_FETCH_JOB_LABEL: &str = "auto-fetch";
pub const PULL_JOB_LABEL: &str = "pull";
pub const PUSH_JOB_LABEL: &str = "push";
pub const CHECKOUT_JOB_LABEL: &str = "checkout";

/// Why `name` cannot be a branch or tag name (git's `check-ref-format`
/// rules, plus the names `git branch` refuses), or `None` when it can.
pub fn ref_name_error(name: &str) -> Option<&'static str> {
    if name.is_empty() {
        return Some("Enter a name.");
    }
    if name.starts_with('-') {
        return Some("A name cannot start with “-”.");
    }
    if name == "@" || name == "HEAD" {
        return Some("This name is reserved by git.");
    }
    if name
        .chars()
        .any(|c| c.is_ascii_control() || c == ' ' || "~^:?*[\\".contains(c))
    {
        return Some("A name cannot contain spaces or any of ~ ^ : ? * [ \\.");
    }
    if name.contains("..") || name.contains("@{") {
        return Some("A name cannot contain “..” or “@{”.");
    }
    if name.starts_with('/') || name.ends_with('/') || name.contains("//") {
        return Some("Slashes must separate non-empty parts.");
    }
    if name.ends_with('.') {
        return Some("A name cannot end with “.”.");
    }
    for part in name.split('/') {
        if part.starts_with('.') {
            return Some("No part of a name can start with “.”.");
        }
        if part.ends_with(".lock") {
            return Some("No part of a name can end with “.lock”.");
        }
    }
    None
}

/// Why `prefix` cannot start branch names (`caleb/`, `fix-`), or `None`
/// when it can; empty means no prefix.
pub fn branch_prefix_error(prefix: &str) -> Option<&'static str> {
    if prefix.is_empty() {
        return None;
    }
    ref_name_error(&format!("{prefix}x")).map(|_| "Branch names cannot start with that prefix.")
}

/// What the user typed, made closer to a valid name: trimmed, with runs of
/// whitespace turned into `-`.
pub fn ref_name_from_input(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join("-")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn branch_prefixes_must_start_a_valid_name() {
        for prefix in ["", "caleb/", "fix-", "wörk/team/"] {
            assert_eq!(branch_prefix_error(prefix), None, "{prefix}");
        }
        for prefix in ["/", "a//", "a b/", "-", ".x/", "a..", "a.lock/"] {
            assert!(branch_prefix_error(prefix).is_some(), "{prefix}");
        }
    }

    #[test]
    fn accepts_usual_branch_names() {
        for name in [
            "main",
            "feature/login",
            "fix-123",
            "wörk/ünïcode",
            "v1.0",
            "a.b/c",
        ] {
            assert_eq!(ref_name_error(name), None, "{name}");
        }
    }

    #[test]
    fn rejects_what_git_rejects() {
        for name in [
            "",
            "-x",
            "@",
            "HEAD",
            "a b",
            "a~1",
            "a^",
            "a:b",
            "a?",
            "a*",
            "a[b",
            "a\\b",
            "a..b",
            "a@{1}",
            "/a",
            "a/",
            "a//b",
            "a.",
            ".a",
            "a/.b",
            "a.lock",
            "a.lock/b",
            "tab\there",
        ] {
            assert!(
                ref_name_error(name).is_some(),
                "{name:?} should be rejected"
            );
        }
    }

    #[test]
    fn input_whitespace_becomes_dashes() {
        assert_eq!(ref_name_from_input("  my new\tfeature  "), "my-new-feature");
        assert_eq!(ref_name_from_input("x"), "x");
    }

    #[test]
    fn push_specs_for_branches_and_tags() {
        let new = PushSpec::branch("origin", "topic", None, None);
        assert_eq!(new.refspecs, ["refs/heads/topic:refs/heads/topic"]);
        assert!(new.set_upstream);
        assert_eq!(new.lease_arg(), None);
        let tracked = PushSpec::branch("up", "local", Some("remote-name"), Some("abc"));
        assert_eq!(
            tracked.refspecs,
            ["refs/heads/local:refs/heads/remote-name"]
        );
        assert!(!tracked.set_upstream);
        assert_eq!(
            tracked.lease_arg().as_deref(),
            Some("--force-with-lease=refs/heads/remote-name:abc")
        );
        let absent = PushSpec::branch("origin", "topic", None, Some(""));
        assert_eq!(
            absent.lease_arg().as_deref(),
            Some("--force-with-lease=refs/heads/topic:")
        );
        assert_eq!(PushSpec::tag("origin", "v1").refspecs, ["refs/tags/v1"]);
    }

    #[test]
    fn shared_branch_names() {
        for name in ["main", "master", "develop", "trunk", "release/2.0"] {
            assert!(is_shared_branch_name(name), "{name}");
        }
        for name in ["feature/main", "mainline", "releases", "topic"] {
            assert!(!is_shared_branch_name(name), "{name}");
        }
    }

    #[test]
    fn pull_modes_round_trip() {
        for mode in [PullMode::FastForwardOnly, PullMode::Merge, PullMode::Rebase] {
            assert_eq!(PullMode::parse(mode.as_str()), Some(mode));
        }
        assert_eq!(PullMode::parse("squash"), None);
    }

    #[test]
    fn checkout_targets_have_display_names() {
        let track = CheckoutTarget::Track {
            remote_ref: "refs/remotes/origin/topic".into(),
            local: "topic".into(),
        };
        assert_eq!(track.display_name(), "origin/topic");
        assert_eq!(
            CheckoutTarget::Detach("0123456789abcdef".into()).display_name(),
            "0123456"
        );
    }
}
