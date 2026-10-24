//! Compact, append-only index of the commit graph (PLAN §3.9).
//!
//! Rows are stored column-wise in flat vectors. Lane layouts are not stored per
//! row: the lane state is checkpointed every [`CHECKPOINT_INTERVAL`] rows and a
//! requested slice is replayed from the nearest checkpoint.

use std::collections::HashMap;
use std::mem::size_of;

use super::lanes::{LaneState, NodeId, RowLayout};
use super::log::{LogParseError, LogRecord};

/// Rows between lane-state checkpoints. A slice query replays at most this many
/// extra rows.
pub const CHECKPOINT_INTERVAL: usize = 256;

const NO_ROW: u32 = u32::MAX;

/// Raw object id bytes (20 for SHA-1, 32 for SHA-256).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct Oid {
    len: u8,
    bytes: [u8; 32],
}

impl Oid {
    fn from_hex(hex: &str) -> Result<Self, LogParseError> {
        let bad = || LogParseError::BadObjectId(hex.to_owned());
        let len = hex.len() / 2;
        if !hex.len().is_multiple_of(2) || !(len == 20 || len == 32) {
            return Err(bad());
        }
        let mut bytes = [0u8; 32];
        let (pairs, _) = hex.as_bytes().as_chunks::<2>();
        for (i, [hi, lo]) in pairs.iter().enumerate() {
            let hi = hex_digit(*hi).ok_or_else(bad)?;
            let lo = hex_digit(*lo).ok_or_else(bad)?;
            bytes[i] = (hi << 4) | lo;
        }
        Ok(Self {
            len: len as u8,
            bytes,
        })
    }

    fn as_bytes(&self) -> &[u8] {
        &self.bytes[..usize::from(self.len)]
    }
}

fn hex_digit(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// One commit, borrowed from the index.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitRow<'a> {
    pub row: usize,
    pub hash: &'a [u8],
    pub author_name: &'a str,
    pub author_email: &'a str,
    pub author_time: i64,
    pub subject: &'a str,
    /// Rows of the parents that are loaded (missing ones are not loaded yet or
    /// lie outside a shallow clone).
    pub parent_rows: Vec<usize>,
}

impl CommitRow<'_> {
    pub fn hash_hex(&self) -> String {
        to_hex(self.hash)
    }

    pub fn short_hash(&self) -> String {
        let mut hex = self.hash_hex();
        hex.truncate(7);
        hex
    }
}

pub fn to_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(char::from(DIGITS[usize::from(b >> 4)]));
        out.push(char::from(DIGITS[usize::from(b & 0xf)]));
    }
    out
}

/// Heap usage, split as in the PLAN §3.9 memory target.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct IndexMemory {
    /// Commit table, parents, checkpoints and build state.
    pub index_bytes: usize,
    /// Subjects and interned author identities.
    pub string_bytes: usize,
}

#[derive(Debug, Default)]
pub struct GraphIndex {
    hash_len: usize,
    /// `hash_len` bytes per row.
    hashes: Vec<u8>,
    /// Node id of each row.
    row_node: Vec<NodeId>,
    /// Row of each node id, or `NO_ROW` until the commit is loaded.
    node_row: Vec<u32>,
    /// `parent_start[row]..parent_start[row + 1]` indexes `parents`.
    parent_start: Vec<u32>,
    parents: Vec<NodeId>,
    author: Vec<u32>,
    author_time: Vec<i64>,
    /// `subject_start[row]..subject_start[row + 1]` indexes `subjects`.
    subject_start: Vec<u32>,
    subjects: String,
    identities: Interner,

    /// Hashes seen as parents whose commit has not been loaded yet. In topological
    /// order a commit never appears after its own row, so this is only the frontier.
    pending: HashMap<Oid, NodeId>,
    lanes: LaneState,
    /// `checkpoints[i]` is the lane state before row `i * CHECKPOINT_INTERVAL`.
    checkpoints: Vec<LaneState>,
    max_width: usize,
}

impl GraphIndex {
    pub fn new() -> Self {
        Self {
            parent_start: vec![0],
            subject_start: vec![0],
            ..Self::default()
        }
    }

    pub fn row_count(&self) -> usize {
        self.row_node.len()
    }

    pub fn is_empty(&self) -> bool {
        self.row_node.is_empty()
    }

    /// Widest the lane set has been, in columns.
    pub fn max_width(&self) -> usize {
        self.max_width
    }

    /// Appends the next commit in topological order.
    pub fn push(&mut self, record: &LogRecord<'_>) -> Result<(), LogParseError> {
        let oid = Oid::from_hex(record.hash)?;
        self.check_hash_len(&oid)?;
        let mut parent_oids = Vec::with_capacity(2);
        for hex in record.parent_hashes() {
            let parent = Oid::from_hex(hex)?;
            self.check_hash_len(&parent)?;
            parent_oids.push(parent);
        }

        let row = self.row_node.len();
        if row.is_multiple_of(CHECKPOINT_INTERVAL) {
            self.checkpoints.push(self.lanes.clone());
        }

        let node = match self.pending.remove(&oid) {
            Some(node) => node,
            None => self.new_node(),
        };
        self.node_row[node as usize] = u32::try_from(row).unwrap_or(NO_ROW);
        let first_parent = self.parents.len();
        for parent in &parent_oids {
            let id = match self.pending.get(parent) {
                Some(&id) => id,
                None => {
                    let id = self.new_node();
                    self.pending.insert(*parent, id);
                    id
                }
            };
            self.parents.push(id);
        }

        self.hashes.extend_from_slice(oid.as_bytes());
        self.row_node.push(node);
        self.parent_start.push(offset(self.parents.len()));
        self.author.push(
            self.identities
                .intern(&record.author_name, &record.author_email),
        );
        self.author_time.push(record.author_time);
        self.subjects.push_str(&record.subject);
        self.subject_start.push(offset(self.subjects.len()));

        self.lanes.step(node, &self.parents[first_parent..], None);
        self.max_width = self.max_width.max(self.lanes.width());
        Ok(())
    }

    pub fn commit(&self, row: usize) -> Option<CommitRow<'_>> {
        if row >= self.row_count() {
            return None;
        }
        let (author_name, author_email) = self.identities.get(self.author[row]);
        Some(CommitRow {
            row,
            hash: &self.hashes[row * self.hash_len..(row + 1) * self.hash_len],
            author_name,
            author_email,
            author_time: self.author_time[row],
            subject: &self.subjects
                [self.subject_start[row] as usize..self.subject_start[row + 1] as usize],
            parent_rows: self
                .parent_nodes(row)
                .iter()
                .filter_map(|&node| match self.node_row[node as usize] {
                    NO_ROW => None,
                    r => Some(r as usize),
                })
                .collect(),
        })
    }

    /// Lane layouts for `start..start + count`, clamped to the loaded rows.
    pub fn layouts(&self, start: usize, count: usize) -> Vec<RowLayout> {
        let end = start.saturating_add(count).min(self.row_count());
        if start >= end {
            return Vec::new();
        }
        let checkpoint = start / CHECKPOINT_INTERVAL;
        let mut state = self.checkpoints[checkpoint].clone();
        for row in checkpoint * CHECKPOINT_INTERVAL..start {
            state.step(self.row_node[row], self.parent_nodes(row), None);
        }
        (start..end)
            .map(|row| {
                let mut layout = RowLayout::default();
                state.step(
                    self.row_node[row],
                    self.parent_nodes(row),
                    Some(&mut layout),
                );
                layout
            })
            .collect()
    }

    pub fn memory(&self) -> IndexMemory {
        let vec_bytes = |len: usize, elem: usize| len * elem;
        let checkpoints: usize = self
            .checkpoints
            .iter()
            .map(|state| size_of::<LaneState>() + state.heap_bytes())
            .sum();
        let index_bytes = self.hashes.capacity()
            + vec_bytes(self.row_node.capacity(), size_of::<NodeId>())
            + vec_bytes(self.node_row.capacity(), size_of::<u32>())
            + vec_bytes(self.parent_start.capacity(), size_of::<u32>())
            + vec_bytes(self.parents.capacity(), size_of::<NodeId>())
            + vec_bytes(self.author.capacity(), size_of::<u32>())
            + vec_bytes(self.author_time.capacity(), size_of::<i64>())
            + vec_bytes(self.subject_start.capacity(), size_of::<u32>())
            // hashbrown: one control byte plus the entry per bucket.
            + self.pending.capacity() * (size_of::<(Oid, NodeId)>() + 1)
            + checkpoints;
        IndexMemory {
            index_bytes,
            string_bytes: self.subjects.capacity() + self.identities.heap_bytes(),
        }
    }

    /// Releases spare capacity once loading is complete.
    pub fn shrink_to_fit(&mut self) {
        self.hashes.shrink_to_fit();
        self.row_node.shrink_to_fit();
        self.node_row.shrink_to_fit();
        self.parent_start.shrink_to_fit();
        self.parents.shrink_to_fit();
        self.author.shrink_to_fit();
        self.author_time.shrink_to_fit();
        self.subject_start.shrink_to_fit();
        self.subjects.shrink_to_fit();
        self.pending.shrink_to_fit();
        self.checkpoints.shrink_to_fit();
    }

    fn parent_nodes(&self, row: usize) -> &[NodeId] {
        &self.parents[self.parent_start[row] as usize..self.parent_start[row + 1] as usize]
    }

    fn new_node(&mut self) -> NodeId {
        let id = NodeId::try_from(self.node_row.len()).unwrap_or(NodeId::MAX);
        self.node_row.push(NO_ROW);
        id
    }

    fn check_hash_len(&mut self, oid: &Oid) -> Result<(), LogParseError> {
        let len = usize::from(oid.len);
        if self.hash_len == 0 {
            self.hash_len = len;
        }
        if self.hash_len == len {
            Ok(())
        } else {
            Err(LogParseError::MixedHashLength {
                expected: self.hash_len,
                found: len,
            })
        }
    }
}

fn offset(len: usize) -> u32 {
    u32::try_from(len).unwrap_or(u32::MAX)
}

/// Interned `(name, email)` pairs, keyed as `name  email`.
#[derive(Debug, Default)]
struct Interner {
    ids: HashMap<Box<str>, u32>,
    /// Key and the byte length of the name part.
    entries: Vec<(Box<str>, usize)>,
    scratch: String,
}

impl Interner {
    fn intern(&mut self, name: &str, email: &str) -> u32 {
        self.scratch.clear();
        self.scratch.push_str(name);
        self.scratch.push('');
        self.scratch.push_str(email);
        if let Some(&id) = self.ids.get(self.scratch.as_str()) {
            return id;
        }
        let id = u32::try_from(self.entries.len()).unwrap_or(u32::MAX);
        let key: Box<str> = self.scratch.as_str().into();
        self.entries.push((key.clone(), name.len()));
        self.ids.insert(key, id);
        id
    }

    fn get(&self, id: u32) -> (&str, &str) {
        self.entries
            .get(id as usize)
            .map_or(("", ""), |(key, name_len)| {
                (&key[..*name_len], &key[*name_len + 1..])
            })
    }

    fn heap_bytes(&self) -> usize {
        let strings: usize = self.entries.iter().map(|(key, _)| key.len()).sum();
        // Keys are stored twice (map and entries).
        2 * strings
            + self.scratch.capacity()
            + self.entries.capacity() * size_of::<(Box<str>, usize)>()
            + self.ids.capacity() * (size_of::<(Box<str>, u32)>() + 1)
    }
}

#[cfg(test)]
mod tests {
    use std::borrow::Cow;

    use super::*;

    fn hex_id(i: usize) -> String {
        format!("{i:040x}")
    }

    /// Deterministic DAG with several branches and merges, returned children
    /// first (a valid topological order).
    fn synthetic_history(commits: usize) -> Vec<(String, Vec<String>)> {
        let mut seed: u64 = 0x9e37_79b9_7f4a_7c15;
        let mut rand = move |n: usize| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            (seed % n as u64) as usize
        };
        let mut heads: Vec<usize> = Vec::new();
        let mut created = Vec::with_capacity(commits);
        for i in 0..commits {
            let mut parents = Vec::new();
            if !heads.is_empty() {
                let branch = rand(heads.len());
                parents.push(heads[branch]);
                if heads.len() > 1 && rand(5) == 0 {
                    let other = (branch + 1 + rand(heads.len() - 1)) % heads.len();
                    parents.push(heads[other]);
                }
                if rand(6) == 0 {
                    heads.push(i);
                } else {
                    heads[branch] = i;
                }
                if let Some(merged) = parents
                    .get(1)
                    .and_then(|p| heads.iter().position(|h| h == p))
                {
                    heads.swap_remove(merged);
                }
            } else {
                heads.push(i);
            }
            created.push((hex_id(i), parents.iter().map(|&p| hex_id(p)).collect()));
        }
        created.reverse();
        created
    }

    fn build(history: &[(String, Vec<String>)]) -> GraphIndex {
        let mut index = GraphIndex::new();
        for (i, (hash, parents)) in history.iter().enumerate() {
            let parents = parents.join(" ");
            let record = LogRecord {
                hash,
                parents: &parents,
                author_name: Cow::Owned(format!("Author {}", i % 7)),
                author_email: Cow::Borrowed("a@example.com"),
                author_time: 1_700_000_000 - i as i64,
                subject: Cow::Owned(format!("commit {i}")),
            };
            index.push(&record).unwrap();
        }
        index
    }

    #[test]
    fn slices_match_a_full_layout_from_any_start() {
        let history = synthetic_history(3 * CHECKPOINT_INTERVAL + 41);
        let index = build(&history);
        let full = index.layouts(0, index.row_count());
        assert_eq!(full.len(), history.len());
        for start in (0..index.row_count()).step_by(37) {
            for count in [1, 13, 50, CHECKPOINT_INTERVAL + 3] {
                let slice = index.layouts(start, count);
                let end = (start + count).min(full.len());
                assert_eq!(slice, full[start..end], "start {start} count {count}");
            }
        }
        assert!(index.layouts(index.row_count(), 10).is_empty());
        assert!(index.max_width() > 1, "fixture should branch");
    }

    #[test]
    fn commit_rows_resolve_parents_and_strings() {
        let history = synthetic_history(500);
        let index = build(&history);
        for (row, (hash, parents)) in history.iter().enumerate() {
            let commit = index.commit(row).unwrap();
            assert_eq!(&commit.hash_hex(), hash);
            assert_eq!(commit.subject, format!("commit {row}"));
            assert_eq!(commit.author_name, format!("Author {}", row % 7));
            assert_eq!(commit.author_email, "a@example.com");
            let expected: Vec<usize> = parents
                .iter()
                .map(|p| history.iter().position(|(h, _)| h == p).unwrap())
                .collect();
            assert_eq!(commit.parent_rows, expected);
        }
        assert!(index.commit(500).is_none());
    }

    #[test]
    fn every_row_has_a_dot_inside_its_segments() {
        let index = build(&synthetic_history(800));
        for (row, layout) in index.layouts(0, 800).iter().enumerate() {
            let touches = layout.segments.iter().any(|s| {
                (s.kind != super::super::lanes::SegmentKind::Pass)
                    && (s.from == layout.column || s.to == layout.column)
            });
            let is_lone_root = layout.segments.is_empty();
            assert!(touches || is_lone_root, "row {row}: {layout:?}");
        }
    }

    #[test]
    fn index_stays_under_the_memory_target() {
        let mut index = build(&synthetic_history(20_000));
        index.shrink_to_fit();
        let memory = index.memory();
        let per_commit = memory.index_bytes as f64 / index.row_count() as f64;
        assert!(per_commit < 150.0, "{per_commit:.1} bytes per commit");
    }

    #[test]
    fn rejects_bad_and_mixed_hashes() {
        let mut index = GraphIndex::new();
        let record = |hash: &'static str| LogRecord {
            hash,
            parents: "",
            author_name: Cow::Borrowed("n"),
            author_email: Cow::Borrowed("e"),
            author_time: 0,
            subject: Cow::Borrowed("s"),
        };
        assert!(matches!(
            index.push(&record("xyz")),
            Err(LogParseError::BadObjectId(_))
        ));
        index.push(&record("aa".repeat(20).leak())).unwrap();
        assert_eq!(
            index.push(&record("bb".repeat(32).leak())),
            Err(LogParseError::MixedHashLength {
                expected: 20,
                found: 32
            })
        );
    }
}
