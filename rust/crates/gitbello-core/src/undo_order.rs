//! Which file-level undo is the newest: Edit → Undo (Ctrl+Z) takes
//! back the latest of a discard, an ignore rule, a shelf discard and a
//! conflict choice. Each kind keeps its own stack in the repository's state;
//! this records the order the entries were pushed in, and the job whose
//! result pushed each one (a toast's Undo closes once its entry is gone).

use crate::jobs::JobId;

/// A kind of file-level undo.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UndoKind {
    Discard,
    IgnoreRule,
    ShelfDiscard,
    ConflictChoice,
}

impl UndoKind {
    pub const ALL: [UndoKind; 4] = [
        UndoKind::Discard,
        UndoKind::IgnoreRule,
        UndoKind::ShelfDiscard,
        UndoKind::ConflictChoice,
    ];

    /// The id GDScript maps to the kind's action.
    pub fn id(self) -> &'static str {
        match self {
            UndoKind::Discard => "discard",
            UndoKind::IgnoreRule => "ignore_rule",
            UndoKind::ShelfDiscard => "shelf_discard",
            UndoKind::ConflictChoice => "conflict_choice",
        }
    }

    pub(crate) fn index(self) -> usize {
        match self {
            UndoKind::Discard => 0,
            UndoKind::IgnoreRule => 1,
            UndoKind::ShelfDiscard => 2,
            UndoKind::ConflictChoice => 3,
        }
    }
}

/// The undo entries, oldest first: each one's kind and the job whose result
/// pushed it.
///
/// The stacks themselves stay the source of truth: an entry undone is
/// [`popped`](Self::popped) here too, while entries a stack drops on its own
/// (its size cap, a conflict reopened) are found stale by
/// [`newest`](Self::newest) and [`is_live`](Self::is_live): of a kind's
/// recorded entries, only as many as its stack still holds count, newest
/// first.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UndoOrder {
    entries: Vec<(UndoKind, JobId)>,
}

impl UndoOrder {
    /// An entry of `kind` was pushed onto its stack by the result of `job`.
    pub fn pushed(&mut self, kind: UndoKind, job: JobId) {
        self.entries.push((kind, job));
    }

    /// The newest entry of `kind` was taken off its stack.
    pub fn popped(&mut self, kind: UndoKind) {
        if let Some(at) = self.entries.iter().rposition(|(k, _)| *k == kind) {
            self.entries.remove(at);
        }
    }

    /// The kind of the newest entry still on its stack, given each kind's
    /// stack length; `None` when every stack is empty.
    pub fn newest(&self, len: impl Fn(UndoKind) -> usize) -> Option<UndoKind> {
        if let Some((kind, _)) = self.live(&len).next() {
            return Some(kind);
        }
        // Entries pushed before the order was kept (none today): any kind left.
        UndoKind::ALL.into_iter().find(|k| len(*k) > 0)
    }

    /// Whether the entry `job` pushed is still on its stack (false once it
    /// was undone or dropped, or when `job` pushed none).
    pub fn is_live(&self, job: JobId, len: impl Fn(UndoKind) -> usize) -> bool {
        self.live(&len).any(|(_, j)| j == job)
    }

    /// Forgets recorded entries that no stack holds any more, so the record
    /// stays as short as the stacks.
    pub fn trim(&mut self, len: impl Fn(UndoKind) -> usize) {
        let mut kept: Vec<(UndoKind, JobId)> = self.live(&len).collect();
        kept.reverse();
        self.entries = kept;
    }

    /// The entries their stacks still hold, newest first.
    fn live<'a>(
        &'a self,
        len: &'a impl Fn(UndoKind) -> usize,
    ) -> impl Iterator<Item = (UndoKind, JobId)> + 'a {
        let mut seen = [0usize; 4];
        self.entries.iter().rev().copied().filter(move |(kind, _)| {
            let live = seen[kind.index()] < len(*kind);
            seen[kind.index()] += 1;
            live
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn lens(map: &HashMap<UndoKind, usize>) -> impl Fn(UndoKind) -> usize + '_ {
        move |k| map.get(&k).copied().unwrap_or(0)
    }

    #[test]
    fn the_newest_push_wins() {
        let mut order = UndoOrder::default();
        let mut stacks = HashMap::new();
        assert_eq!(order.newest(lens(&stacks)), None);
        order.pushed(UndoKind::Discard, 1);
        stacks.insert(UndoKind::Discard, 1);
        order.pushed(UndoKind::IgnoreRule, 2);
        stacks.insert(UndoKind::IgnoreRule, 1);
        assert_eq!(order.newest(lens(&stacks)), Some(UndoKind::IgnoreRule));
    }

    #[test]
    fn undoing_one_uncovers_the_one_before() {
        let mut order = UndoOrder::default();
        let mut stacks = HashMap::new();
        order.pushed(UndoKind::Discard, 3);
        order.pushed(UndoKind::ConflictChoice, 4);
        order.pushed(UndoKind::Discard, 5);
        stacks.insert(UndoKind::Discard, 2);
        stacks.insert(UndoKind::ConflictChoice, 1);
        assert_eq!(order.newest(lens(&stacks)), Some(UndoKind::Discard));
        order.popped(UndoKind::Discard);
        stacks.insert(UndoKind::Discard, 1);
        assert_eq!(order.newest(lens(&stacks)), Some(UndoKind::ConflictChoice));
        order.popped(UndoKind::ConflictChoice);
        stacks.insert(UndoKind::ConflictChoice, 0);
        assert_eq!(order.newest(lens(&stacks)), Some(UndoKind::Discard));
    }

    #[test]
    fn entries_a_stack_dropped_on_its_own_are_skipped() {
        let mut order = UndoOrder::default();
        let mut stacks = HashMap::new();
        order.pushed(UndoKind::ShelfDiscard, 6);
        order.pushed(UndoKind::ConflictChoice, 7);
        stacks.insert(UndoKind::ShelfDiscard, 1);
        // The conflict was reopened: its choices were dropped.
        stacks.insert(UndoKind::ConflictChoice, 0);
        assert_eq!(order.newest(lens(&stacks)), Some(UndoKind::ShelfDiscard));
        order.trim(lens(&stacks));
        assert_eq!(order.entries, vec![(UndoKind::ShelfDiscard, 6)]);
    }

    #[test]
    fn a_capped_stack_keeps_its_newest_entries() {
        let mut order = UndoOrder::default();
        let mut stacks = HashMap::new();
        order.pushed(UndoKind::Discard, 8);
        order.pushed(UndoKind::IgnoreRule, 9);
        order.pushed(UndoKind::Discard, 10);
        // The discard stack holds one: the newer one.
        stacks.insert(UndoKind::Discard, 1);
        stacks.insert(UndoKind::IgnoreRule, 1);
        assert_eq!(order.newest(lens(&stacks)), Some(UndoKind::Discard));
        order.popped(UndoKind::Discard);
        stacks.insert(UndoKind::Discard, 0);
        assert_eq!(order.newest(lens(&stacks)), Some(UndoKind::IgnoreRule));
    }

    #[test]
    fn an_entry_is_live_until_undone_or_dropped() {
        let mut order = UndoOrder::default();
        let mut stacks = HashMap::new();
        order.pushed(UndoKind::Discard, 11);
        order.pushed(UndoKind::IgnoreRule, 12);
        order.pushed(UndoKind::Discard, 13);
        stacks.insert(UndoKind::Discard, 2);
        stacks.insert(UndoKind::IgnoreRule, 1);
        assert!([11, 12, 13]
            .iter()
            .all(|j| order.is_live(*j, lens(&stacks))));
        // A job that pushed nothing has no entry.
        assert!(!order.is_live(99, lens(&stacks)));
        // Undoing a discard takes the newer one.
        order.popped(UndoKind::Discard);
        stacks.insert(UndoKind::Discard, 1);
        assert!(!order.is_live(13, lens(&stacks)));
        assert!(order.is_live(11, lens(&stacks)));
        // The ignore stack dropped its entry on its own.
        stacks.insert(UndoKind::IgnoreRule, 0);
        assert!(!order.is_live(12, lens(&stacks)));
        assert!(order.is_live(11, lens(&stacks)));
    }
}
