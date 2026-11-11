//! The path log's git reads (PLAN M8a): the commits that changed some
//! paths, where a name a commit added came from, writing a file of a
//! commit into the working tree under another name, and the line counts of
//! a file's uncommitted changes.

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use super::compare::{untracked_stats, WORKING_DIFF_ARGS};
use super::{unexpected, CliBackend, GitBackend};
use crate::compare::parse_numstat;
use crate::diff::{DiffKind, DiffTarget};
use crate::git::{CancelToken, GitError, GitErrorKind};
use crate::path_log::{PathCommit, PathLogSplitter, MERGE_DIFF_ARGS, PATH_LOG_ARGS};
use crate::repo::{parse_name_status, Change, ParseError};

const READ_CHUNK: usize = 64 * 1024;

fn slashed(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

impl CliBackend {
    pub(super) fn stream_path_log(
        &self,
        toplevel: &Path,
        start: &str,
        paths: &[PathBuf],
        cancel: &CancelToken,
        sink: &mut dyn FnMut(PathCommit),
    ) -> Result<(), GitError> {
        let start = start.trim();
        // A revision never reaches git as a flag.
        if start.is_empty() || start.starts_with('-') || paths.is_empty() {
            return Err(GitError::new(
                format!("log {start}"),
                GitErrorKind::UnknownRevision,
                format!("unknown revision `{start}`"),
            ));
        }
        // An unborn branch has no history yet.
        let Some(tip) = self.resolve(toplevel, start, cancel)? else {
            return Ok(());
        };
        let mut cmd = self
            .runner
            .read(toplevel)
            .env("GIT_LITERAL_PATHSPECS", "1")
            .args(PATH_LOG_ARGS)
            .arg(&tip)
            .arg("--");
        for path in paths {
            cmd = cmd.arg(path);
        }
        let mut stream = cmd.stream()?;
        let command = stream.command().to_owned();
        let mut splitter = PathLogSplitter::new();
        let mut buf = vec![0u8; READ_CHUNK];
        let mut ended = false;
        while !ended {
            if cancel.is_cancelled() {
                stream.kill();
                return stream.finish();
            }
            let n = match stream.read(&mut buf) {
                Ok(n) => n,
                Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(err) => return Err(GitError::new(&command, GitErrorKind::Io, err.to_string())),
            };
            // The commits of this chunk, handed over in order once the
            // merges among them have their diffs.
            let mut batch: Vec<PathCommit> = Vec::new();
            let mut push = |record: &[u8]| -> Result<(), ParseError> {
                batch.push(PathCommit::parse(record)?);
                Ok(())
            };
            let parsed = if n == 0 {
                ended = true;
                std::mem::take(&mut splitter).finish(&mut push)
            } else {
                splitter.feed(&buf[..n], &mut push)
            };
            if let Err(err) = parsed {
                stream.kill();
                return Err(unexpected(&[command.as_str()], err));
            }
            if let Err(err) = self.read_merge_diffs(toplevel, paths, &mut batch, cancel) {
                stream.kill();
                return Err(err);
            }
            batch.into_iter().for_each(&mut *sink);
        }
        stream.finish()
    }

    /// Fills in what the merges of `batch` changed against their first
    /// parent (`git log` prints no diff for a merge).
    fn read_merge_diffs(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        batch: &mut [PathCommit],
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        let mut input = String::new();
        for commit in batch.iter().filter(|c| c.is_unread_merge()) {
            input.push_str(&commit.oid);
            input.push('\n');
        }
        if input.is_empty() {
            return Ok(());
        }
        let mut cmd = self
            .runner
            .read(toplevel)
            .env("GIT_LITERAL_PATHSPECS", "1")
            .args(MERGE_DIFF_ARGS)
            .arg("--");
        for path in paths {
            cmd = cmd.arg(path);
        }
        let command = cmd.display();
        let out = cmd.stdin(input).cancel_token(cancel).run()?;
        let mut splitter = PathLogSplitter::new();
        let mut merges: Vec<PathCommit> = Vec::new();
        let mut push = |record: &[u8]| -> Result<(), ParseError> {
            merges.push(PathCommit::parse(record)?);
            Ok(())
        };
        splitter
            .feed(&out.stdout, &mut push)
            .and_then(|()| splitter.finish(&mut push))
            .map_err(|err| unexpected(&[command.as_str()], err))?;
        for merge in merges {
            if let Some(commit) = batch.iter_mut().find(|c| c.oid == merge.oid) {
                commit.files = merge.files;
            }
        }
        Ok(())
    }

    pub(super) fn find_rename_source(
        &self,
        toplevel: &Path,
        commit: &str,
        parent: &str,
        path: &Path,
        cancel: &CancelToken,
    ) -> Result<Option<PathBuf>, GitError> {
        let args = [
            "diff-tree",
            "-r",
            "-z",
            "-M",
            "--no-commit-id",
            "--name-status",
            "--diff-filter=R",
            parent,
            commit,
            "--",
        ];
        let out = self.read(toplevel, &args, cancel)?;
        let files = parse_name_status(&out.stdout).map_err(|e| unexpected(&args, e))?;
        Ok(files
            .into_iter()
            .find(|f| f.change == Change::Renamed && f.path == path)
            .and_then(|f| f.original_path))
    }

    pub(super) fn restore_file_to(
        &self,
        toplevel: &Path,
        oid: &str,
        source: &Path,
        dest: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<(PathBuf, String)>, GitError> {
        if source == dest {
            return self.restore_paths_from(toplevel, oid, &[dest.to_path_buf()], cancel);
        }
        let entry = self
            .runner
            .read(toplevel)
            .env("GIT_LITERAL_PATHSPECS", "1")
            .args(["ls-tree", "-z", oid, "--"])
            .arg(source)
            .cancel_token(cancel)
            .run()?;
        // `<mode> <type> <id>\t<path>`: only regular files are written.
        let mode = entry.stdout_text();
        let mode = mode.split(' ').next().unwrap_or_default().to_owned();
        if !mode.starts_with("100") {
            return Err(GitError::new(
                format!("restore {}", slashed(source)),
                GitErrorKind::Other,
                format!("`{}` is not a regular file in {oid}", slashed(source)),
            ));
        }
        // The bytes as a checkout would write them at `dest` (line endings
        // and filters follow the destination's attributes).
        let spec = format!("{oid}:{}", slashed(source));
        let content = self
            .runner
            .read(toplevel)
            .args(["cat-file", "--filters"])
            .arg(format!("--path={}", slashed(dest)))
            .arg(&spec)
            .cancel_token(cancel)
            .run()?;
        let mut backups = self.backup(toplevel, &[dest.to_path_buf()], cancel)?;
        if backups.is_empty() {
            backups.push((dest.to_path_buf(), String::new()));
        }
        let target = toplevel.join(dest);
        let io = |err: std::io::Error| {
            GitError::new(
                format!("write {}", target.display()),
                GitErrorKind::Io,
                err.to_string(),
            )
        };
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(io)?;
        }
        fs::write(&target, &content.stdout).map_err(io)?;
        #[cfg(unix)]
        if mode == "100755" {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&target).map_err(io)?.permissions();
            perms.set_mode(perms.mode() | 0o111);
            fs::set_permissions(&target, perms).map_err(io)?;
        }
        Ok(backups)
    }

    pub(super) fn count_working_lines(
        &self,
        toplevel: &Path,
        target: &DiffTarget,
        cancel: &CancelToken,
    ) -> Result<Option<(u32, u32)>, GitError> {
        match target.kind {
            DiffKind::Untracked => Ok(untracked_stats(&toplevel.join(&target.path))),
            DiffKind::Head => {
                let base = match self.resolve(toplevel, "HEAD", cancel)? {
                    Some(head) => head,
                    None => self.empty_tree(toplevel, cancel)?,
                };
                let mut cmd = self
                    .runner
                    .read(toplevel)
                    .env("GIT_LITERAL_PATHSPECS", "1")
                    .args(WORKING_DIFF_ARGS)
                    .args(["--numstat", &base, "--"]);
                if let Some(original) = &target.original_path {
                    cmd = cmd.arg(original);
                }
                let out = cmd.arg(&target.path).cancel_token(cancel).run()?;
                Ok(parse_numstat(&out.stdout)
                    .into_iter()
                    .find(|(path, _)| path == &target.path)
                    .and_then(|(_, stats)| stats))
            }
            _ => Ok(None),
        }
    }
}
