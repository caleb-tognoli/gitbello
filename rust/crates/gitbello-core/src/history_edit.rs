//! History editing: reword, squash, fixup, move and drop commits of the
//! current branch, run as an interactive rebase whose todo gitbello writes
//! (git never opens an editor).
//!
//! [`Rewritable`] lists the commits that can be edited, newest first: HEAD
//! back to the first merge commit, the default branch (unless HEAD is on
//! it), the root or [`REWRITABLE_LIMIT`]. A one-shot action on one of them
//! becomes a [`RewritePlan`]: a base and the steps from the oldest commit it
//! touches up to HEAD. The same plan job serves a future planner view.

use std::collections::HashSet;

use crate::repo::text;

/// Commits listed in [`Rewritable`]; older ones cannot be edited.
pub const REWRITABLE_LIMIT: usize = 1000;

/// An edit that rewrites more commits than this, or any pushed one, asks first.
pub const REWRITE_CONFIRM_FROM: usize = 50;

/// `git log -z` format of [`parse_rewritable`].
pub const REWRITABLE_LOG_FORMAT: &str = "--format=%H%x00%P%x00%B";

/// A commit that can be edited.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RewritableCommit {
    pub oid: String,
    /// First parent; `None` for a root commit.
    pub parent: Option<String>,
    pub subject: String,
    pub body: String,
    /// On the upstream (or, with none, on a remote branch): rewriting it
    /// means a force push.
    pub pushed: bool,
}

/// What lies past the oldest listed commit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RewriteStop {
    /// The oldest listed commit is the root.
    Root,
    /// The default branch has the older commits.
    #[default]
    Base,
    /// A merge commit.
    Merge,
    /// [`REWRITABLE_LIMIT`] commits were listed.
    Limit,
}

/// The commits of the current branch that can be edited, newest first.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Rewritable {
    /// HEAD when this was read.
    pub head: String,
    pub commits: Vec<RewritableCommit>,
    pub stop: RewriteStop,
}

/// A one-shot edit of one commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RewriteAction {
    /// New message.
    Reword(String),
    /// Into its parent, with the message of the result.
    Squash(String),
    /// Into its parent, keeping the parent's message.
    Fixup,
    Drop,
    /// Swaps it with its child (newer).
    MoveUp,
    /// Swaps it with its parent (older).
    MoveDown,
}

impl RewriteAction {
    pub fn kind(&self) -> RewriteKind {
        match self {
            Self::Reword(_) => RewriteKind::Reword,
            Self::Squash(_) => RewriteKind::Squash,
            Self::Fixup => RewriteKind::Fixup,
            Self::Drop => RewriteKind::Drop,
            Self::MoveUp => RewriteKind::MoveUp,
            Self::MoveDown => RewriteKind::MoveDown,
        }
    }

    /// From the ids GDScript uses; `message` is for reword and squash.
    pub fn from_id(id: &str, message: &str) -> Option<Self> {
        Some(match id {
            "reword" => Self::Reword(message.to_owned()),
            "squash" => Self::Squash(message.to_owned()),
            "fixup" => Self::Fixup,
            "drop" => Self::Drop,
            "move_up" => Self::MoveUp,
            "move_down" => Self::MoveDown,
            _ => return None,
        })
    }
}

/// [`RewriteAction`] without its message.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RewriteKind {
    Reword,
    Squash,
    Fixup,
    Drop,
    MoveUp,
    MoveDown,
}

impl RewriteKind {
    pub fn id(self) -> &'static str {
        match self {
            Self::Reword => "reword",
            Self::Squash => "squash",
            Self::Fixup => "fixup",
            Self::Drop => "drop",
            Self::MoveUp => "move_up",
            Self::MoveDown => "move_down",
        }
    }
}

/// Why an action cannot run on a commit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RewriteBlock {
    /// No branch checked out, or the list is not read yet.
    NoBranch,
    /// A merge commit sits between it and HEAD (or it is one).
    PastMerge,
    /// The default branch has it.
    OnBase,
    /// Older than [`REWRITABLE_LIMIT`] commits.
    TooFar,
    /// Squash, fixup or move down on a commit whose parent cannot be edited.
    NoParent,
    /// Move up on HEAD.
    AtHead,
    /// Reword or squash with an empty message.
    NoMessage,
}

impl RewriteBlock {
    pub fn id(self) -> &'static str {
        match self {
            Self::NoBranch => "no_branch",
            Self::PastMerge => "past_merge",
            Self::OnBase => "on_base",
            Self::TooFar => "too_far",
            Self::NoParent => "no_parent",
            Self::AtHead => "at_head",
            Self::NoMessage => "no_message",
        }
    }
}

/// One line of the rebase todo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RewriteStep {
    Pick(String),
    Reword {
        oid: String,
        message: String,
    },
    /// Fixed up into the step before, then that commit gets `message`.
    Squash {
        oid: String,
        message: String,
    },
    Fixup(String),
    Drop(String),
}

impl RewriteStep {
    pub fn oid(&self) -> &str {
        match self {
            Self::Pick(oid) | Self::Fixup(oid) | Self::Drop(oid) => oid,
            Self::Reword { oid, .. } | Self::Squash { oid, .. } => oid,
        }
    }

    fn message(&self) -> Option<&str> {
        match self {
            Self::Reword { message, .. } | Self::Squash { message, .. } => Some(message),
            _ => None,
        }
    }
}

/// A rebase of everything after `base` (`None`: from the root), steps in
/// order, oldest first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RewritePlan {
    pub base: Option<String>,
    pub steps: Vec<RewriteStep>,
}

impl RewritePlan {
    /// How many messages the todo reads (see [`RewritePlan::todo`]).
    pub fn message_count(&self) -> usize {
        self.steps.iter().filter(|s| s.message().is_some()).count()
    }

    /// The messages, in the order [`RewritePlan::todo`] numbers them.
    pub fn messages(&self) -> impl Iterator<Item = &str> {
        self.steps.iter().filter_map(RewriteStep::message)
    }

    /// The todo for `git rebase -i`; message `n` (0-based) is read from
    /// `message_file(n)` (an absolute path) by an `exec` line that amends
    /// the commit just made.
    pub fn todo(&self, message_file: impl Fn(usize) -> String) -> String {
        let mut out = String::new();
        let mut n = 0;
        for step in &self.steps {
            let (command, oid) = match step {
                RewriteStep::Pick(oid) | RewriteStep::Reword { oid, .. } => ("pick", oid),
                RewriteStep::Squash { oid, .. } | RewriteStep::Fixup(oid) => ("fixup", oid),
                RewriteStep::Drop(oid) => ("drop", oid),
            };
            out.push_str(&format!("{command} {oid}\n"));
            if step.message().is_some() {
                out.push_str(&format!(
                    "exec git commit --amend --allow-empty --no-verify -q -F {}\n",
                    sh_quote(&message_file(n))
                ));
                n += 1;
            }
        }
        out
    }
}

/// `value` in single quotes for the shell git runs `exec` lines and the
/// sequence editor with (Windows paths with forward slashes).
pub fn sh_quote(value: &str) -> String {
    format!("'{}'", value.replace('\\', "/").replace('\'', r"'\''"))
}

impl Rewritable {
    pub fn index(&self, oid: &str) -> Option<usize> {
        self.commits.iter().position(|c| c.oid == oid)
    }

    pub fn commit(&self, oid: &str) -> Option<&RewritableCommit> {
        self.commits.iter().find(|c| c.oid == oid)
    }

    /// Why a commit that is in HEAD but not listed cannot be edited.
    fn past_stop(&self) -> RewriteBlock {
        match self.stop {
            RewriteStop::Merge => RewriteBlock::PastMerge,
            RewriteStop::Limit => RewriteBlock::TooFar,
            RewriteStop::Base | RewriteStop::Root => RewriteBlock::OnBase,
        }
    }

    /// The plan for `action` on `oid`, or why it cannot run. `oid` must be
    /// in HEAD (the caller checks: commits of other branches are not listed).
    pub fn plan(&self, oid: &str, action: &RewriteAction) -> Result<RewritePlan, RewriteBlock> {
        if self.head.is_empty() {
            return Err(RewriteBlock::NoBranch);
        }
        let i = self.index(oid).ok_or_else(|| self.past_stop())?;
        if let RewriteAction::Reword(m) | RewriteAction::Squash(m) = action {
            if m.trim().is_empty() {
                return Err(RewriteBlock::NoMessage);
            }
        }
        let parent_listed = i + 1 < self.commits.len();
        let needs_parent = matches!(
            action,
            RewriteAction::Squash(_) | RewriteAction::Fixup | RewriteAction::MoveDown
        );
        if needs_parent && !parent_listed {
            return Err(if self.commits[i].parent.is_none() {
                RewriteBlock::NoParent
            } else {
                match self.past_stop() {
                    RewriteBlock::OnBase => RewriteBlock::NoParent,
                    other => other,
                }
            });
        }
        if *action == RewriteAction::MoveUp && i == 0 {
            return Err(RewriteBlock::AtHead);
        }
        // The oldest commit the plan replays.
        let oldest = if needs_parent { i + 1 } else { i };
        let base = self.commits[oldest].parent.clone();
        // Oldest first.
        let mut order: Vec<usize> = (0..=oldest).rev().collect();
        match action {
            RewriteAction::MoveUp => {
                // [i, i-1] becomes [i-1, i].
                let at = order.iter().position(|&x| x == i).unwrap_or(0);
                order.swap(at, at + 1);
            }
            RewriteAction::MoveDown => order.swap(0, 1),
            _ => {}
        }
        let steps = order
            .into_iter()
            .map(|x| {
                let commit = self.commits[x].oid.clone();
                if x != i {
                    return RewriteStep::Pick(commit);
                }
                match action {
                    RewriteAction::Reword(message) => RewriteStep::Reword {
                        oid: commit,
                        message: message.clone(),
                    },
                    RewriteAction::Squash(message) => RewriteStep::Squash {
                        oid: commit,
                        message: message.clone(),
                    },
                    RewriteAction::Fixup => RewriteStep::Fixup(commit),
                    RewriteAction::Drop => RewriteStep::Drop(commit),
                    RewriteAction::MoveUp | RewriteAction::MoveDown => RewriteStep::Pick(commit),
                }
            })
            .collect();
        Ok(RewritePlan { base, steps })
    }

    /// What `action` on `oid` would rewrite: `(commits, pushed)`.
    pub fn reach(&self, oid: &str, action: &RewriteAction) -> Result<(usize, usize), RewriteBlock> {
        let plan = self.plan(oid, action)?;
        let oids: HashSet<&str> = plan.steps.iter().map(RewriteStep::oid).collect();
        let pushed = self
            .commits
            .iter()
            .filter(|c| c.pushed && oids.contains(c.oid.as_str()))
            .count();
        Ok((plan.steps.len(), pushed))
    }
}

/// Whether an edit that rewrites `commits`, `pushed` of them pushed, asks first.
pub fn needs_confirm(commits: usize, pushed: usize) -> bool {
    pushed > 0 || commits > REWRITE_CONFIRM_FROM
}

/// Commits from `git log -z --first-parent` with [`REWRITABLE_LOG_FORMAT`],
/// newest first, read with `-n` one past [`REWRITABLE_LIMIT`]. `outgoing`
/// holds the commits not pushed.
/// Stops before the first merge, after the root or at the limit.
pub fn parse_rewritable(output: &[u8], head: &str, outgoing: &HashSet<String>) -> Rewritable {
    let fields: Vec<&[u8]> = output.split(|&b| b == 0).collect();
    let mut out = Rewritable {
        head: head.to_owned(),
        ..Rewritable::default()
    };
    for chunk in fields.chunks(3).filter(|c| c.len() == 3) {
        // `log -z` separates commits with a NUL: the next hash may start
        // with a newline left from the message.
        let oid = text(chunk[0]).trim().to_owned();
        if oid.is_empty() {
            continue;
        }
        let parents: Vec<String> = text(chunk[1])
            .split_whitespace()
            .map(str::to_owned)
            .collect();
        if parents.len() > 1 {
            out.stop = RewriteStop::Merge;
            return out;
        }
        if out.commits.len() == REWRITABLE_LIMIT {
            out.stop = RewriteStop::Limit;
            return out;
        }
        let (subject, body) = crate::changes::split_message(&text(chunk[2]));
        let root = parents.is_empty();
        out.commits.push(RewritableCommit {
            pushed: !outgoing.contains(&oid),
            oid,
            parent: parents.into_iter().next(),
            subject,
            body,
        });
        if root {
            out.stop = RewriteStop::Root;
            return out;
        }
    }
    out.stop = RewriteStop::Base;
    out
}

/// A history edit made here, for the undo strip.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RewriteDone {
    pub kind: RewriteKind,
    /// The edited commit's subject (the new one after a reword or squash).
    pub subject: String,
    /// The branch's upstream commit when the edit ran: the undo is offered
    /// until it moves (a push).
    pub upstream: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn commit(oid: &str, parent: Option<&str>, pushed: bool) -> RewritableCommit {
        RewritableCommit {
            oid: oid.to_owned(),
            parent: parent.map(str::to_owned),
            subject: format!("subject {oid}"),
            body: String::new(),
            pushed,
        }
    }

    /// d (HEAD) → c → b → a, `a`'s parent `base` on the default branch;
    /// `a` and `b` pushed.
    fn list() -> Rewritable {
        Rewritable {
            head: "d".to_owned(),
            commits: vec![
                commit("d", Some("c"), false),
                commit("c", Some("b"), false),
                commit("b", Some("a"), true),
                commit("a", Some("base"), true),
            ],
            stop: RewriteStop::Base,
        }
    }

    fn oids(plan: &RewritePlan) -> Vec<String> {
        plan.steps
            .iter()
            .map(|s| {
                let tag = match s {
                    RewriteStep::Pick(_) => "pick",
                    RewriteStep::Reword { .. } => "reword",
                    RewriteStep::Squash { .. } => "squash",
                    RewriteStep::Fixup(_) => "fixup",
                    RewriteStep::Drop(_) => "drop",
                };
                format!("{tag} {}", s.oid())
            })
            .collect()
    }

    #[test]
    fn plans_each_action() {
        let list = list();
        let plan = list
            .plan("c", &RewriteAction::Reword("new".into()))
            .unwrap();
        assert_eq!(plan.base.as_deref(), Some("b"));
        assert_eq!(oids(&plan), ["reword c", "pick d"]);
        let plan = list.plan("c", &RewriteAction::Drop).unwrap();
        assert_eq!(oids(&plan), ["drop c", "pick d"]);
        let plan = list.plan("c", &RewriteAction::Fixup).unwrap();
        assert_eq!(plan.base.as_deref(), Some("a"));
        assert_eq!(oids(&plan), ["pick b", "fixup c", "pick d"]);
        let plan = list
            .plan("c", &RewriteAction::Squash("both".into()))
            .unwrap();
        assert_eq!(oids(&plan), ["pick b", "squash c", "pick d"]);
        let plan = list.plan("b", &RewriteAction::MoveUp).unwrap();
        assert_eq!(plan.base.as_deref(), Some("a"));
        assert_eq!(oids(&plan), ["pick c", "pick b", "pick d"]);
        let plan = list.plan("b", &RewriteAction::MoveDown).unwrap();
        assert_eq!(plan.base.as_deref(), Some("base"));
        assert_eq!(oids(&plan), ["pick b", "pick a", "pick c", "pick d"]);
        let plan = list.plan("d", &RewriteAction::Drop).unwrap();
        assert_eq!(oids(&plan), ["drop d"]);
    }

    #[test]
    fn blocks_what_cannot_run() {
        let list = list();
        assert_eq!(
            list.plan("d", &RewriteAction::MoveUp),
            Err(RewriteBlock::AtHead)
        );
        assert_eq!(
            list.plan("a", &RewriteAction::Fixup),
            Err(RewriteBlock::NoParent)
        );
        assert_eq!(
            list.plan("a", &RewriteAction::MoveDown),
            Err(RewriteBlock::NoParent)
        );
        assert_eq!(
            list.plan("base", &RewriteAction::Drop),
            Err(RewriteBlock::OnBase)
        );
        assert_eq!(
            list.plan("c", &RewriteAction::Reword("  ".into())),
            Err(RewriteBlock::NoMessage)
        );
        let merged = Rewritable {
            stop: RewriteStop::Merge,
            ..list.clone()
        };
        assert_eq!(
            merged.plan("old", &RewriteAction::Drop),
            Err(RewriteBlock::PastMerge)
        );
        assert_eq!(
            merged.plan("a", &RewriteAction::Fixup),
            Err(RewriteBlock::PastMerge)
        );
        assert_eq!(
            Rewritable::default().plan("a", &RewriteAction::Drop),
            Err(RewriteBlock::NoBranch)
        );
    }

    #[test]
    fn plans_from_the_root() {
        let list = Rewritable {
            head: "b".into(),
            commits: vec![commit("b", Some("a"), false), commit("a", None, false)],
            stop: RewriteStop::Root,
        };
        let plan = list.plan("b", &RewriteAction::Fixup).unwrap();
        assert_eq!(plan.base, None);
        assert_eq!(oids(&plan), ["pick a", "fixup b"]);
        assert_eq!(
            list.plan("a", &RewriteAction::Fixup),
            Err(RewriteBlock::NoParent)
        );
    }

    #[test]
    fn counts_what_is_rewritten() {
        let list = list();
        assert_eq!(list.reach("d", &RewriteAction::Drop), Ok((1, 0)));
        assert_eq!(list.reach("c", &RewriteAction::Fixup), Ok((3, 1)));
        assert_eq!(list.reach("a", &RewriteAction::Drop), Ok((4, 2)));
        assert!(!needs_confirm(3, 0));
        assert!(needs_confirm(3, 1));
        assert!(needs_confirm(51, 0));
    }

    #[test]
    fn writes_the_todo() {
        let list = list();
        let plan = list
            .plan("c", &RewriteAction::Squash("both".into()))
            .unwrap();
        let todo = plan.todo(|n| format!("C:\\it's\\msg-{n}"));
        assert_eq!(
            todo,
            "pick b\nfixup c\nexec git commit --amend --allow-empty --no-verify -q -F 'C:/it'\\''s/msg-0'\npick d\n"
        );
        assert_eq!(plan.messages().collect::<Vec<_>>(), ["both"]);
    }

    #[test]
    fn parses_the_log() {
        let outgoing: HashSet<String> = ["d".to_owned()].into();
        let log = b"d\0c\0Fix it\n\nBody\n\0\nc\0b\0Two\n\0\nb\0m1 m2\0Merge\n\0";
        let list = parse_rewritable(log, "d", &outgoing);
        assert_eq!(list.stop, RewriteStop::Merge);
        assert_eq!(list.commits.len(), 2);
        assert_eq!(list.commits[0].subject, "Fix it");
        assert_eq!(list.commits[0].body, "Body");
        assert!(!list.commits[0].pushed);
        assert!(list.commits[1].pushed);
        let root = parse_rewritable(b"a\0\0Root\n\0", "a", &outgoing);
        assert_eq!(root.stop, RewriteStop::Root);
        assert_eq!(root.commits[0].parent, None);
        let base = parse_rewritable(b"a\0z\0One\n\0", "a", &outgoing);
        assert_eq!(base.stop, RewriteStop::Base);
    }
}
