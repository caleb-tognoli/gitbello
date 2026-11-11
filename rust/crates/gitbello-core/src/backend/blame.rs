//! Blame's git reads (PLAN M8b): the text to blame, the blocks
//! `git blame --incremental` reports, and the last commit that changed
//! some paths before a revision.

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use super::{read_limited, unexpected, CliBackend, Limited};
use crate::blame::{BlameBlock, BlameOptions, BlameParser, BlameSource, BLAME_ARGS};
use crate::git::{CancelToken, GitError, GitErrorKind};

const READ_CHUNK: usize = 64 * 1024;

fn slashed(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

/// A revision never reaches git as a flag.
fn checked_rev<'a>(command: &str, rev: &'a str) -> Result<&'a str, GitError> {
    let rev = rev.trim();
    if rev.is_empty() || rev.starts_with('-') {
        return Err(GitError::new(
            format!("{command} {rev}"),
            GitErrorKind::UnknownRevision,
            format!("unknown revision `{rev}`"),
        ));
    }
    Ok(rev)
}

impl CliBackend {
    pub(super) fn read_blame_source(
        &self,
        toplevel: &Path,
        rev: Option<&str>,
        path: &Path,
        limit: usize,
        cancel: &CancelToken,
    ) -> Result<BlameSource, GitError> {
        let Some(rev) = rev else {
            let file = toplevel.join(path);
            let io_error = |err: std::io::Error| {
                GitError::new(
                    format!("read {}", file.display()),
                    GitErrorKind::Io,
                    err.to_string(),
                )
            };
            let meta = match fs::metadata(&file) {
                Ok(meta) if meta.is_file() => meta,
                Ok(_) => return Ok(BlameSource::Missing),
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                    return Ok(BlameSource::Missing)
                }
                Err(err) => return Err(io_error(err)),
            };
            if meta.len() > limit as u64 {
                return Ok(BlameSource::TooLarge(meta.len()));
            }
            return fs::read(&file).map(BlameSource::Text).map_err(io_error);
        };
        let rev = checked_rev("cat-file", rev)?;
        let object = format!("{rev}:{}", slashed(path));
        let stream = self
            .runner
            .read(toplevel)
            .args(["cat-file", "blob", &object])
            .stream()?;
        Ok(match read_limited(stream, limit, cancel)? {
            Limited::Read(text) => BlameSource::Text(text),
            Limited::TooLarge(bytes) => BlameSource::TooLarge(bytes as u64),
            Limited::Cancelled => {
                return Err(GitError::new(
                    "cat-file",
                    GitErrorKind::Cancelled,
                    "cancelled",
                ))
            }
        })
    }

    pub(super) fn stream_blame(
        &self,
        toplevel: &Path,
        rev: Option<&str>,
        path: &Path,
        options: BlameOptions,
        cancel: &CancelToken,
        sink: &mut dyn FnMut(BlameBlock),
    ) -> Result<(), GitError> {
        let mut cmd = self
            .runner
            .read(toplevel)
            .env("GIT_LITERAL_PATHSPECS", "1")
            .args(BLAME_ARGS)
            .args(options.args());
        if let Some(rev) = rev {
            cmd = cmd.arg(checked_rev("blame", rev)?);
        }
        let mut stream = cmd.arg("--").arg(path).stream()?;
        let command = stream.command().to_owned();
        let mut parser = BlameParser::new();
        let mut buf = vec![0u8; READ_CHUNK];
        loop {
            if cancel.is_cancelled() {
                stream.kill();
                return stream.finish();
            }
            let n = match stream.read(&mut buf) {
                Ok(n) => n,
                Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(err) => return Err(GitError::new(&command, GitErrorKind::Io, err.to_string())),
            };
            if n == 0 {
                break;
            }
            if let Err(err) = parser.feed(&buf[..n], sink) {
                stream.kill();
                return Err(unexpected(&[command.as_str()], err));
            }
        }
        // git's own error first: a failed blame ends mid-block.
        stream.finish()?;
        parser
            .finish()
            .map_err(|err| unexpected(&[command.as_str()], err))
    }

    pub(super) fn find_last_change(
        &self,
        toplevel: &Path,
        rev: &str,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError> {
        let rev = checked_rev("log", rev)?;
        if paths.is_empty() {
            return Ok(None);
        }
        let mut cmd = self
            .runner
            .read(toplevel)
            .env("GIT_LITERAL_PATHSPECS", "1")
            .args(["log", "-1", "--format=%H", "--no-follow", rev, "--"]);
        for path in paths {
            cmd = cmd.arg(path);
        }
        let out = cmd.cancel_token(cancel).run()?;
        let oid = out.stdout_text().trim().to_owned();
        Ok((!oid.is_empty()).then_some(oid))
    }
}
