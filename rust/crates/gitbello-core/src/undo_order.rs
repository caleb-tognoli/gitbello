//! Which file-level undo is the newest (M7.17): Edit → Undo (Ctrl+Z) takes
//! back the latest of a discard, an ignore rule, a shelf discard and a
//! conflict choice. Each kind keeps its own stack in the repository's state;
//! this records the order the entries were pushed in.

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

/// The kinds of the undo entries, oldest first.
///
/// The stacks themselves stay the source of truth: an entry undone is
/// [`popped`](Self::popped) here too, while entries a stack drops on its own
/// (its size cap, a conflict reopened) are found stale by
/// [`newest`](Self::newest): of a kind's recorded entries, only as many as
/// its stack still holds count, newest first.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UndoOrder {
    kinds: Vec<UndoKind>,
}

impl UndoOrder {
    /// An entry of `kind` was pushed onto its stack.
    pub fn pushed(&mut self, kind: UndoKind) {
        self.kinds.push(kind);
    }

    /// The newest entry of `kind` was taken off its stack.
    pub fn popped(&mut self, kind: UndoKind) {
        if let Some(at) = self.kinds.iter().rposition(|k| *k == kind) {
            self.kinds.remove(at);
        }
    }

    /// The kind of the newest entry still on its stack, given each kind's
    /// stack length; `None` when every stack is empty.
    pub fn newest(&self, len: impl Fn(UndoKind) -> usize) -> Option<UndoKind> {
        let mut seen = [0usize; 4];
        for kind in self.kinds.iter().rev() {
            if seen[kind.index()] < len(*kind) {
                return Some(*kind);
            }
            seen[kind.index()] += 1;
        }
        // Entries pushed before the order was kept (none today): any kind left.
        UndoKind::ALL.into_iter().find(|k| len(*k) > 0)
    }

    /// Forgets recorded entries that no stack holds any more, so the record
    /// stays as short as the stacks.
    pub fn trim(&mut self, len: impl Fn(UndoKind) -> usize) {
        let mut seen = [0usize; 4];
        let mut kept: Vec<UndoKind> = Vec::with_capacity(self.kinds.len());
        for kind in self.kinds.iter().rev() {
            if seen[kind.index()] < len(*kind) {
                kept.push(*kind);
            }
            seen[kind.index()] += 1;
        }
        kept.reverse();
        self.kinds = kept;
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
        order.pushed(UndoKind::Discard);
        stacks.insert(UndoKind::Discard, 1);
        order.pushed(UndoKind::IgnoreRule);
        stacks.insert(UndoKind::IgnoreRule, 1);
        assert_eq!(order.newest(lens(&stacks)), Some(UndoKind::IgnoreRule));
    }

    #[test]
    fn undoing_one_uncovers_the_one_before() {
        let mut order = UndoOrder::default();
        let mut stacks = HashMap::new();
        order.pushed(UndoKind::Discard);
        order.pushed(UndoKind::ConflictChoice);
        order.pushed(UndoKind::Discard);
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
        order.pushed(UndoKind::ShelfDiscard);
        order.pushed(UndoKind::ConflictChoice);
        stacks.insert(UndoKind::ShelfDiscard, 1);
        // The conflict was reopened: its choices were dropped.
        stacks.insert(UndoKind::ConflictChoice, 0);
        assert_eq!(order.newest(lens(&stacks)), Some(UndoKind::ShelfDiscard));
        order.trim(lens(&stacks));
        assert_eq!(order.kinds, vec![UndoKind::ShelfDiscard]);
    }

    #[test]
    fn a_capped_stack_keeps_its_newest_entries() {
        let mut order = UndoOrder::default();
        let mut stacks = HashMap::new();
        order.pushed(UndoKind::Discard);
        order.pushed(UndoKind::IgnoreRule);
        order.pushed(UndoKind::Discard);
        // The discard stack holds one: the newer one.
        stacks.insert(UndoKind::Discard, 1);
        stacks.insert(UndoKind::IgnoreRule, 1);
        assert_eq!(order.newest(lens(&stacks)), Some(UndoKind::Discard));
        order.popped(UndoKind::Discard);
        stacks.insert(UndoKind::Discard, 0);
        assert_eq!(order.newest(lens(&stacks)), Some(UndoKind::IgnoreRule));
    }
}
