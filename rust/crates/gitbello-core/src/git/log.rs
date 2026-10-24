//! In-memory log of every git command, for the "Git log" panel (PLAN §3.2).

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, SystemTime};

use super::error::GitErrorKind;

const DEFAULT_CAPACITY: usize = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandOutcome {
    Succeeded,
    Failed(GitErrorKind),
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandRecord {
    /// Increases by one per command; use it to fetch only new records.
    pub seq: u64,
    pub repo: PathBuf,
    /// The git arguments (without the global flags).
    pub command: String,
    pub started: SystemTime,
    pub duration: Duration,
    pub exit_code: Option<i32>,
    pub outcome: CommandOutcome,
}

/// Bounded, shared command log. Clones share the same log.
#[derive(Debug, Clone)]
pub struct CommandLog {
    inner: Arc<Mutex<Inner>>,
}

#[derive(Debug)]
struct Inner {
    capacity: usize,
    next_seq: u64,
    records: VecDeque<CommandRecord>,
}

impl Default for CommandLog {
    fn default() -> Self {
        Self::with_capacity(DEFAULT_CAPACITY)
    }
}

impl CommandLog {
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner {
                capacity: capacity.max(1),
                next_seq: 1,
                records: VecDeque::new(),
            })),
        }
    }

    /// Records with `seq > after`, oldest first. Pass 0 for everything kept.
    pub fn records_since(&self, after: u64) -> Vec<CommandRecord> {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        inner
            .records
            .iter()
            .filter(|record| record.seq > after)
            .cloned()
            .collect()
    }

    pub(crate) fn push(
        &self,
        repo: PathBuf,
        command: String,
        started: SystemTime,
        duration: Duration,
        exit_code: Option<i32>,
        outcome: CommandOutcome,
    ) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let seq = inner.next_seq;
        inner.next_seq += 1;
        if inner.records.len() == inner.capacity {
            inner.records.pop_front();
        }
        inner.records.push_back(CommandRecord {
            seq,
            repo,
            command,
            started,
            duration,
            exit_code,
            outcome,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_newest_records_and_numbers_them() {
        let log = CommandLog::with_capacity(2);
        for i in 0..3 {
            log.push(
                PathBuf::from("r"),
                format!("cmd {i}"),
                SystemTime::UNIX_EPOCH,
                Duration::ZERO,
                Some(0),
                CommandOutcome::Succeeded,
            );
        }
        let all = log.records_since(0);
        assert_eq!(
            all.iter().map(|r| (r.seq, r.command.as_str())).collect::<Vec<_>>(),
            [(2, "cmd 1"), (3, "cmd 2")]
        );
        assert_eq!(log.records_since(2).len(), 1);
        assert!(log.records_since(3).is_empty());
    }
}
