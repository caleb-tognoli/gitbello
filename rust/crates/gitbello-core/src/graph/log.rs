//! Parsing of the streamed `git log` output used for the history graph.

use std::borrow::Cow;

use thiserror::Error;

/// Field separator inside one commit record (`%x1f`, ASCII unit separator).
const FIELD_SEP: u8 = 0x1f;
/// Record separator between commits (`-z`).
const RECORD_SEP: u8 = 0;

/// Arguments for the graph log (PLAN §3.3). Fields: hash, parents, author name,
/// author email, author time, subject.
pub const LOG_ARGS: &[&str] = &[
    "log",
    "--all",
    "--topo-order",
    "-z",
    "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s",
];

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum LogParseError {
    #[error("commit record has {0} fields, expected 6")]
    FieldCount(usize),
    #[error("invalid object id `{0}`")]
    BadObjectId(String),
    #[error("invalid author time `{0}`")]
    BadTime(String),
    #[error("object id length changed from {expected} to {found} bytes")]
    MixedHashLength { expected: usize, found: usize },
}

/// One commit as printed by [`LOG_ARGS`]. Borrows from the read buffer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogRecord<'a> {
    pub hash: &'a str,
    /// Space-separated parent hashes; empty for a root commit.
    pub parents: &'a str,
    pub author_name: Cow<'a, str>,
    pub author_email: Cow<'a, str>,
    pub author_time: i64,
    pub subject: Cow<'a, str>,
}

impl<'a> LogRecord<'a> {
    pub fn parse(record: &'a [u8]) -> Result<Self, LogParseError> {
        let mut fields = record.split(|&b| b == FIELD_SEP);
        let mut next = || fields.next();
        let (Some(hash), Some(parents), Some(name), Some(email), Some(time), Some(subject)) =
            (next(), next(), next(), next(), next(), next())
        else {
            return Err(LogParseError::FieldCount(
                record.split(|&b| b == FIELD_SEP).count(),
            ));
        };
        if next().is_some() {
            return Err(LogParseError::FieldCount(
                record.split(|&b| b == FIELD_SEP).count(),
            ));
        }
        let ascii = |bytes: &'a [u8]| {
            std::str::from_utf8(bytes)
                .map_err(|_| LogParseError::BadObjectId(String::from_utf8_lossy(bytes).into()))
        };
        let time_text = String::from_utf8_lossy(time);
        let author_time = if time.is_empty() {
            0
        } else {
            time_text
                .parse()
                .map_err(|_| LogParseError::BadTime(time_text.clone().into_owned()))?
        };
        Ok(Self {
            hash: ascii(hash)?,
            parents: ascii(parents)?,
            author_name: String::from_utf8_lossy(name),
            author_email: String::from_utf8_lossy(email),
            author_time,
            subject: String::from_utf8_lossy(subject),
        })
    }

    pub fn parent_hashes(&self) -> impl Iterator<Item = &'a str> {
        self.parents.split(' ').filter(|p| !p.is_empty())
    }
}

/// Splits a byte stream into commit records, across arbitrary chunk boundaries.
#[derive(Debug, Default)]
pub struct RecordSplitter {
    pending: Vec<u8>,
}

impl RecordSplitter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feeds a chunk and calls `on_record` for every complete record in it.
    pub fn feed<E>(
        &mut self,
        chunk: &[u8],
        mut on_record: impl FnMut(&[u8]) -> Result<(), E>,
    ) -> Result<(), E> {
        let mut rest = chunk;
        while let Some(pos) = rest.iter().position(|&b| b == RECORD_SEP) {
            let (head, tail) = rest.split_at(pos);
            if self.pending.is_empty() {
                emit(head, &mut on_record)?;
            } else {
                self.pending.extend_from_slice(head);
                let record = std::mem::take(&mut self.pending);
                emit(&record, &mut on_record)?;
            }
            rest = &tail[1..];
        }
        self.pending.extend_from_slice(rest);
        Ok(())
    }

    /// Flushes a final record that had no trailing separator.
    pub fn finish<E>(
        &mut self,
        mut on_record: impl FnMut(&[u8]) -> Result<(), E>,
    ) -> Result<(), E> {
        let record = std::mem::take(&mut self.pending);
        emit(&record, &mut on_record)
    }
}

/// Trims the newline git may put between records and skips empty ones.
fn emit<E>(record: &[u8], on_record: &mut impl FnMut(&[u8]) -> Result<(), E>) -> Result<(), E> {
    let start = record
        .iter()
        .position(|&b| b != b'\n')
        .unwrap_or(record.len());
    let end = record
        .iter()
        .rposition(|&b| b != b'\n')
        .map_or(start, |i| i + 1);
    if start < end {
        on_record(&record[start..end])
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Captured from `git log` with LOG_ARGS (fields joined by \x1f, records by \0).
    const CAPTURED: &[u8] = b"9f2c7c1d0e5a8b3f4c6d7e8f9a0b1c2d3e4f5a6b\x1f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b 2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c\x1fJ\xc3\xa9r\xc3\xb4me\x1fjerome@example.com\x1f1700000000\x1fMerge branch 'topic'\x00\
1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b\x1f\x1fAda\x1fada@example.com\x1f1699990000\x1fInitial commit\x00";

    fn split_all(input: &[u8], chunk: usize) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let mut splitter = RecordSplitter::new();
        for piece in input.chunks(chunk) {
            splitter
                .feed::<()>(piece, |r| {
                    out.push(r.to_vec());
                    Ok(())
                })
                .unwrap();
        }
        splitter
            .finish::<()>(|r| {
                out.push(r.to_vec());
                Ok(())
            })
            .unwrap();
        out
    }

    #[test]
    fn splits_records_across_any_chunk_boundary() {
        let whole = split_all(CAPTURED, CAPTURED.len());
        assert_eq!(whole.len(), 2);
        for chunk in 1..CAPTURED.len() {
            assert_eq!(split_all(CAPTURED, chunk), whole, "chunk size {chunk}");
        }
    }

    #[test]
    fn handles_missing_trailing_separator_and_newlines() {
        let records = split_all(b"\na\x00\nb\n", 3);
        assert_eq!(records, vec![b"a".to_vec(), b"b".to_vec()]);
        assert!(split_all(b"", 4).is_empty());
        assert!(split_all(b"\x00\n\x00", 1).is_empty());
    }

    #[test]
    fn parses_merge_and_root_records() {
        let records = split_all(CAPTURED, 7);
        let merge = LogRecord::parse(&records[0]).unwrap();
        assert_eq!(merge.hash, "9f2c7c1d0e5a8b3f4c6d7e8f9a0b1c2d3e4f5a6b");
        assert_eq!(merge.parent_hashes().count(), 2);
        assert_eq!(merge.author_name, "Jérôme");
        assert_eq!(merge.author_email, "jerome@example.com");
        assert_eq!(merge.author_time, 1_700_000_000);
        assert_eq!(merge.subject, "Merge branch 'topic'");

        let root = LogRecord::parse(&records[1]).unwrap();
        assert_eq!(root.parent_hashes().count(), 0);
        assert_eq!(root.subject, "Initial commit");
    }

    #[test]
    fn keeps_subject_with_odd_characters_and_invalid_utf8() {
        let record = b"aa\x1f\x1fN\x1fe\x1f1\x1fsubject with \xff and \ttab";
        let parsed = LogRecord::parse(record).unwrap();
        assert_eq!(parsed.subject, "subject with \u{fffd} and \ttab");
    }

    #[test]
    fn rejects_malformed_records() {
        assert_eq!(
            LogRecord::parse(b"aa\x1fbb"),
            Err(LogParseError::FieldCount(2))
        );
        assert_eq!(
            LogRecord::parse(b"a\x1f\x1fn\x1fe\x1f1\x1fs\x1fextra"),
            Err(LogParseError::FieldCount(7))
        );
        assert!(matches!(
            LogRecord::parse(b"a\x1f\x1fn\x1fe\x1fnot-a-time\x1fs"),
            Err(LogParseError::BadTime(_))
        ));
    }
}
