//! Lane assignment for the history graph (PLAN §3.9).
//!
//! Commits arrive in topological order (children before parents). Each active
//! lane waits for one commit; a commit takes the first lane waiting for it, or a
//! free column if none is. Rows are laid out with three kinds of segments, in a
//! cell whose top, center and bottom are at y = 0, 0.5 and 1:
//!
//! - `Pass`: a lane that continues straight through the row (top to bottom).
//! - `In`: a lane that ends at this commit (top of `from` to the center of `to`).
//! - `Out`: an edge to a parent (center of `from` to the bottom of `to`).
//!
//! A row's layout depends only on the rows above it, so rows never change once
//! appended.

/// Dense id of a commit, assigned when its hash is first seen.
pub type NodeId = u32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Lane {
    /// The commit this lane leads to.
    pub expects: NodeId,
    /// Color index; the UI maps it onto its palette with a modulo.
    pub color: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum SegmentKind {
    Pass = 0,
    In = 1,
    Out = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Segment {
    pub kind: SegmentKind,
    pub from: u16,
    pub to: u16,
    pub color: u16,
}

/// Everything needed to draw one row of the graph.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RowLayout {
    pub column: u16,
    pub color: u16,
    pub segments: Vec<Segment>,
}

impl RowLayout {
    /// Number of columns the row touches (for sizing the graph area).
    pub fn width(&self) -> u16 {
        self.segments
            .iter()
            .map(|s| s.from.max(s.to))
            .chain(std::iter::once(self.column))
            .max()
            .map_or(0, |max| max + 1)
    }
}

/// Active lanes between two rows.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LaneState {
    lanes: Vec<Option<Lane>>,
    next_color: u16,
}

impl LaneState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Number of columns in use, including holes left by finished lanes.
    pub fn width(&self) -> usize {
        self.lanes.len()
    }

    pub(crate) fn heap_bytes(&self) -> usize {
        self.lanes.capacity() * std::mem::size_of::<Option<Lane>>()
    }

    /// Advances past one commit. When `out` is given it receives the row's layout.
    pub fn step(&mut self, node: NodeId, parents: &[NodeId], out: Option<&mut RowLayout>) {
        let mut out = out;
        if let Some(layout) = out.as_deref_mut() {
            layout.segments.clear();
        }

        // A commit no lane is waiting for is a branch tip and starts a new lane.
        let (column, is_tip) = match self
            .lanes
            .iter()
            .position(|lane| lane.is_some_and(|l| l.expects == node))
        {
            Some(column) => (column, false),
            None => {
                let column = self.free_column();
                let color = self.take_color();
                self.lanes[column] = Some(Lane {
                    expects: node,
                    color,
                });
                (column, true)
            }
        };
        let color = self.lanes[column].map_or(0, |lane| lane.color);

        if let Some(layout) = out.as_deref_mut() {
            layout.column = to_u16(column);
            layout.color = color;
            for (i, lane) in self.lanes.iter().enumerate() {
                let Some(lane) = lane else { continue };
                let (kind, to) = if lane.expects == node {
                    // A tip's lane starts at the dot, so nothing comes in from above.
                    if i == column && is_tip {
                        continue;
                    }
                    (SegmentKind::In, column)
                } else {
                    (SegmentKind::Pass, i)
                };
                layout.segments.push(Segment {
                    kind,
                    from: to_u16(i),
                    to: to_u16(to),
                    color: lane.color,
                });
            }
        }

        for lane in &mut self.lanes {
            if lane.is_some_and(|l| l.expects == node) {
                *lane = None;
            }
        }

        if let Some((&first, rest)) = parents.split_first() {
            // If a lane to the left already leads to the first parent, join it
            // instead of keeping a parallel lane open (topics forked from the same
            // old base would otherwise each hold a column down to that base).
            let joined = self
                .lanes
                .iter()
                .take(column)
                .position(|lane| lane.is_some_and(|l| l.expects == first));
            let (target, target_color) = match joined {
                Some(j) => (j, self.lanes[j].map_or(color, |lane| lane.color)),
                None => {
                    self.lanes[column] = Some(Lane {
                        expects: first,
                        color,
                    });
                    (column, color)
                }
            };
            if let Some(layout) = out.as_deref_mut() {
                layout.segments.push(Segment {
                    kind: SegmentKind::Out,
                    from: to_u16(column),
                    to: to_u16(target),
                    color: target_color,
                });
            }
            for &parent in rest {
                let existing = self
                    .lanes
                    .iter()
                    .position(|lane| lane.is_some_and(|l| l.expects == parent));
                let (target, lane_color) = match existing {
                    Some(j) => (j, self.lanes[j].map_or(0, |lane| lane.color)),
                    None => {
                        let j = self.free_column();
                        let lane_color = self.take_color();
                        self.lanes[j] = Some(Lane {
                            expects: parent,
                            color: lane_color,
                        });
                        (j, lane_color)
                    }
                };
                if let Some(layout) = out.as_deref_mut() {
                    layout.segments.push(Segment {
                        kind: SegmentKind::Out,
                        from: to_u16(column),
                        to: to_u16(target),
                        color: lane_color,
                    });
                }
            }
        }

        while self.lanes.last().is_some_and(Option::is_none) {
            self.lanes.pop();
        }
    }

    fn free_column(&mut self) -> usize {
        match self.lanes.iter().position(Option::is_none) {
            Some(i) => i,
            None => {
                self.lanes.push(None);
                self.lanes.len() - 1
            }
        }
    }

    fn take_color(&mut self) -> u16 {
        let color = self.next_color;
        self.next_color = self.next_color.wrapping_add(1);
        color
    }
}

fn to_u16(value: usize) -> u16 {
    u16::try_from(value).unwrap_or(u16::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use SegmentKind::{In, Out, Pass};

    fn seg(kind: SegmentKind, from: u16, to: u16, color: u16) -> Segment {
        Segment {
            kind,
            from,
            to,
            color,
        }
    }

    /// Lays out `(node, parents)` rows in order.
    fn layout(rows: &[(NodeId, &[NodeId])]) -> (Vec<RowLayout>, LaneState) {
        let mut state = LaneState::new();
        let layouts = rows
            .iter()
            .map(|(node, parents)| {
                let mut row = RowLayout::default();
                state.step(*node, parents, Some(&mut row));
                row
            })
            .collect();
        (layouts, state)
    }

    #[test]
    fn linear_history_stays_in_one_column() {
        let (rows, state) = layout(&[(0, &[1]), (1, &[2]), (2, &[])]);
        assert_eq!(rows[0].segments, vec![seg(Out, 0, 0, 0)]);
        assert_eq!(rows[1].segments, vec![seg(In, 0, 0, 0), seg(Out, 0, 0, 0)]);
        assert_eq!(rows[2].segments, vec![seg(In, 0, 0, 0)]);
        assert!(rows.iter().all(|r| r.column == 0 && r.color == 0));
        assert_eq!(state.width(), 0, "all lanes end at the root");
    }

    #[test]
    fn merge_opens_a_lane_that_rejoins_at_the_base() {
        // M=0 merges B=1 and C=2, both based on A=3. Order: M, C, B, A.
        let (rows, state) = layout(&[(0, &[1, 2]), (2, &[3]), (1, &[3]), (3, &[])]);
        assert_eq!(rows[0].column, 0);
        assert_eq!(rows[0].segments, vec![seg(Out, 0, 0, 0), seg(Out, 0, 1, 1)]);

        assert_eq!((rows[1].column, rows[1].color), (1, 1));
        assert_eq!(
            rows[1].segments,
            vec![seg(Pass, 0, 0, 0), seg(In, 1, 1, 1), seg(Out, 1, 1, 1)]
        );

        assert_eq!(rows[2].column, 0);
        assert_eq!(
            rows[2].segments,
            vec![seg(In, 0, 0, 0), seg(Pass, 1, 1, 1), seg(Out, 0, 0, 0)]
        );

        assert_eq!(rows[3].column, 0);
        assert_eq!(rows[3].segments, vec![seg(In, 0, 0, 0), seg(In, 1, 0, 1)]);
        assert_eq!(state.width(), 0);
    }

    #[test]
    fn merge_into_an_existing_lane_reuses_it() {
        // Tips X=0 (parent P=2) and M=1 (parents Q=3, P=2): M's second parent is
        // already expected by X's lane, so no new lane is opened.
        let (rows, _) = layout(&[(0, &[2]), (1, &[3, 2])]);
        assert_eq!(rows[1].column, 1);
        assert_eq!(
            rows[1].segments,
            vec![seg(Pass, 0, 0, 0), seg(Out, 1, 1, 1), seg(Out, 1, 0, 0)]
        );
    }

    #[test]
    fn new_tips_fill_holes_before_widening() {
        // A=0 and B=1 are tips; A is a root, so column 0 frees up for B, and
        // C=2 (with a different parent) needs a second column.
        let (rows, state) = layout(&[(0, &[]), (1, &[3]), (2, &[4])]);
        assert_eq!(
            rows.iter().map(|r| r.column).collect::<Vec<_>>(),
            vec![0, 0, 1]
        );
        assert_eq!(
            rows.iter().map(|r| r.color).collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
        assert_eq!(state.width(), 2);
    }

    #[test]
    fn first_parent_joins_a_lane_to_the_left() {
        // Tips X=0 and Y=1 share parent P=2: Y joins X's lane instead of
        // keeping its own column open down to P.
        let (rows, state) = layout(&[(0, &[2]), (1, &[2]), (2, &[])]);
        assert_eq!(rows[1].column, 1);
        assert_eq!(
            rows[1].segments,
            vec![seg(Pass, 0, 0, 0), seg(Out, 1, 0, 0)]
        );
        assert_eq!(rows[2].segments, vec![seg(In, 0, 0, 0)]);
        assert_eq!(state.width(), 0);
    }

    #[test]
    fn first_parent_keeps_its_lane_when_the_other_is_to_the_right() {
        // M=0 merges B=1 and C=2; C (column 1) reaches base A=3 first, then B
        // (column 0) keeps its own lane: the left lane is never rerouted right.
        let (rows, _) = layout(&[(0, &[1, 2]), (2, &[3]), (1, &[3]), (3, &[])]);
        assert_eq!(rows[2].segments.last(), Some(&seg(Out, 0, 0, 0)));
    }

    #[test]
    fn octopus_merge_opens_one_lane_per_extra_parent() {
        let (rows, state) = layout(&[(0, &[1, 2, 3])]);
        assert_eq!(
            rows[0].segments,
            vec![seg(Out, 0, 0, 0), seg(Out, 0, 1, 1), seg(Out, 0, 2, 2)]
        );
        assert_eq!(rows[0].width(), 3);
        assert_eq!(state.width(), 3);
    }

    #[test]
    fn layout_is_independent_of_whether_it_is_recorded() {
        let rows: &[(NodeId, &[NodeId])] = &[(0, &[1, 2]), (2, &[3]), (1, &[3]), (3, &[])];
        let mut recorded = LaneState::new();
        let mut silent = LaneState::new();
        for (node, parents) in rows {
            let mut row = RowLayout::default();
            recorded.step(*node, parents, Some(&mut row));
            silent.step(*node, parents, None);
            assert_eq!(recorded, silent);
        }
    }
}
