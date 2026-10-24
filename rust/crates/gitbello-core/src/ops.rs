//! Write operations of M5 (PLAN §5): syncing with remotes, branches, tags,
//! checkout and cherry-pick. Plain data for the [`crate::backend::GitBackend`]
//! methods; the runtime decides what to run and in which order.

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
    pub force_with_lease: bool,
}

impl PushSpec {
    /// Pushes local `branch` to `remote`: to `upstream_branch` (the branch
    /// name on the remote) when it has one, otherwise to the same name with
    /// the upstream set.
    pub fn branch(
        remote: &str,
        branch: &str,
        upstream_branch: Option<&str>,
        force_with_lease: bool,
    ) -> Self {
        let target = upstream_branch.unwrap_or(branch);
        Self {
            remote: remote.to_owned(),
            refspecs: vec![format!("refs/heads/{branch}:refs/heads/{target}")],
            set_upstream: upstream_branch.is_none(),
            force_with_lease,
        }
    }

    pub fn tag(remote: &str, tag: &str) -> Self {
        Self {
            remote: remote.to_owned(),
            refspecs: vec![format!("refs/tags/{tag}")],
            set_upstream: false,
            force_with_lease: false,
        }
    }
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
    /// Merge commits are picked against their first parent.
    CherryPick {
        commit: String,
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
            Self::CherryPick { .. } => "cherry-pick",
            Self::Abort(_) => "abort",
        }
    }
}

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

/// What the user typed, made closer to a valid name: trimmed, with runs of
/// whitespace turned into `-`.
pub fn ref_name_from_input(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join("-")
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let new = PushSpec::branch("origin", "topic", None, false);
        assert_eq!(new.refspecs, ["refs/heads/topic:refs/heads/topic"]);
        assert!(new.set_upstream);
        let tracked = PushSpec::branch("up", "local", Some("remote-name"), true);
        assert_eq!(
            tracked.refspecs,
            ["refs/heads/local:refs/heads/remote-name"]
        );
        assert!(!tracked.set_upstream && tracked.force_with_lease);
        assert_eq!(PushSpec::tag("origin", "v1").refspecs, ["refs/tags/v1"]);
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
