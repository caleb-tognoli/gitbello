//! Parsing of git's `--progress` output on stderr (fetch, pull, push, clone).

/// One progress update, such as `Receiving objects:  45% (450/1000)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Progress {
    /// Phase name without the `remote: ` prefix, e.g. `Receiving objects`.
    pub phase: String,
    pub percent: Option<u8>,
    pub current: Option<u64>,
    pub total: Option<u64>,
    /// Whether the line came from the remote side (`remote: ...`).
    pub remote: bool,
    /// The whole line, trimmed.
    pub text: String,
}

impl Progress {
    /// Parses one progress line; returns `None` for lines that are not progress
    /// (errors, hints, ref update summaries).
    pub fn parse(line: &str) -> Option<Self> {
        let text = line.trim();
        let (remote, body) = match text.strip_prefix("remote:") {
            Some(rest) => (true, rest.trim_start()),
            None => (false, text),
        };
        let (phase, rest) = body.split_once(':')?;
        let phase = phase.trim();
        if phase.is_empty() || phase.contains(['[', ']', '/', '\'']) || phase.len() > 40 {
            return None;
        }
        let rest = rest.trim_start();
        let percent = rest
            .split_once('%')
            .and_then(|(num, _)| num.trim().parse::<u8>().ok())
            .filter(|p| *p <= 100);
        let (current, total) = match (rest.find('('), rest.find(')')) {
            (Some(open), Some(close)) if open < close => {
                let inner = &rest[open + 1..close];
                match inner.split_once('/') {
                    Some((a, b)) => (a.trim().parse().ok(), b.trim().parse().ok()),
                    None => (None, None),
                }
            }
            _ => {
                // `Enumerating objects: 5, done.`
                let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
                (digits.parse().ok(), None)
            }
        };
        if percent.is_none() && current.is_none() {
            return None;
        }
        Some(Self {
            phase: phase.to_owned(),
            percent,
            current,
            total,
            remote,
            text: text.to_owned(),
        })
    }
}

/// Splits a byte stream into lines on `\n` or `\r` (git redraws progress lines
/// with `\r`), across chunk boundaries.
#[derive(Debug, Default)]
pub struct LineSplitter {
    pending: Vec<u8>,
}

impl LineSplitter {
    pub fn feed(&mut self, chunk: &[u8], mut on_line: impl FnMut(&str)) {
        for &byte in chunk {
            if byte == b'\n' || byte == b'\r' {
                if !self.pending.is_empty() {
                    on_line(&String::from_utf8_lossy(&self.pending));
                    self.pending.clear();
                }
            } else {
                self.pending.push(byte);
            }
        }
    }

    pub fn finish(&mut self, mut on_line: impl FnMut(&str)) {
        if !self.pending.is_empty() {
            on_line(&String::from_utf8_lossy(&self.pending));
            self.pending.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_captured_fetch_progress() {
        let p = Progress::parse("Receiving objects:  45% (450/1000), 1.20 MiB | 2.00 MiB/s").unwrap();
        assert_eq!(p.phase, "Receiving objects");
        assert_eq!((p.percent, p.current, p.total), (Some(45), Some(450), Some(1000)));
        assert!(!p.remote);

        let p = Progress::parse("remote: Counting objects: 100% (5/5), done.").unwrap();
        assert_eq!(p.phase, "Counting objects");
        assert_eq!(p.percent, Some(100));
        assert!(p.remote);

        let p = Progress::parse("remote: Enumerating objects: 5, done.").unwrap();
        assert_eq!((p.percent, p.current, p.total), (None, Some(5), None));

        let p = Progress::parse("Resolving deltas:   0% (0/2)").unwrap();
        assert_eq!((p.percent, p.current, p.total), (Some(0), Some(0), Some(2)));
    }

    #[test]
    fn ignores_non_progress_lines() {
        for line in [
            "From ../remote",
            " * [new branch]      main       -> origin/main",
            "fatal: could not read Username for 'https://x': terminal prompts disabled",
            "hint: Updates were rejected because the tip of your current branch is behind",
            "To ../remote.git",
            "",
        ] {
            assert_eq!(Progress::parse(line), None, "{line}");
        }
    }

    #[test]
    fn splits_carriage_return_redraws_across_chunks() {
        let input = b"Receiving objects:  10% (1/10)\rReceiving objects: 100% (10/10), done.\nResolv";
        let mut lines = Vec::new();
        let mut splitter = LineSplitter::default();
        for chunk in input.chunks(7) {
            splitter.feed(chunk, |l| lines.push(l.to_owned()));
        }
        splitter.feed(b"ing deltas: 100% (2/2)", |l| lines.push(l.to_owned()));
        splitter.finish(|l| lines.push(l.to_owned()));
        assert_eq!(
            lines,
            [
                "Receiving objects:  10% (1/10)",
                "Receiving objects: 100% (10/10), done.",
                "Resolving deltas: 100% (2/2)",
            ]
        );
    }
}
