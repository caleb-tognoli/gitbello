//! The git side of ignore rules (`crate::ignore`): which files a rule
//! matches, untracking them with an exact undo, and the ignore state the
//! rules viewer shows (which line decides each ignored path).

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use super::{pathspec_input, CliBackend, PATHSPEC_STDIN};
use crate::changes::IndexEntry;
use crate::git::{CancelToken, GitError};
use crate::ignore::{parse_check_ignore, IgnoreMatch};

/// Bytes of pathspecs per `ls-files` call, well under Windows' 32K command line.
const ARGV_BUDGET: usize = 24 * 1024;

impl CliBackend {
    pub(super) fn untracked_matching_impl(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        patterns: &[String],
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        if paths.is_empty() || patterns.is_empty() {
            return Ok(Vec::new());
        }
        let mut out = Vec::new();
        let mut batch: Vec<String> = Vec::new();
        let mut size = 0;
        let mut run = |batch: &mut Vec<String>| -> Result<(), GitError> {
            if batch.is_empty() {
                return Ok(());
            }
            let output = self
                .runner
                .read(toplevel)
                .env("GIT_LITERAL_PATHSPECS", "1")
                .args(["ls-files", "-z", "--others", "--ignored"])
                .args(patterns.iter().flat_map(|p| ["-x", p.as_str()]))
                .arg("--")
                .args(batch.iter())
                .cancel_token(cancel)
                .run()?;
            out.extend(split_paths(&output.stdout));
            batch.clear();
            Ok(())
        };
        for path in paths {
            let path = path.to_string_lossy().replace('\\', "/");
            size += path.len() + 3;
            batch.push(path);
            if size > ARGV_BUDGET {
                run(&mut batch)?;
                size = 0;
            }
        }
        run(&mut batch)?;
        Ok(out)
    }

    pub(super) fn tracked_matching_impl(
        &self,
        toplevel: &Path,
        patterns: &[String],
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        if patterns.is_empty() {
            return Ok(Vec::new());
        }
        let output = self
            .runner
            .read(toplevel)
            .args(["ls-files", "-z", "--cached", "--ignored"])
            .args(patterns.iter().flat_map(|p| ["-x", p.as_str()]))
            .cancel_token(cancel)
            .run()?;
        let mut paths = split_paths(&output.stdout);
        // A conflicted file is listed once per stage.
        paths.dedup();
        Ok(paths)
    }

    pub(super) fn index_entries_impl(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<Vec<IndexEntry>, GitError> {
        if paths.is_empty() {
            return Ok(Vec::new());
        }
        let wanted: HashSet<String> = paths
            .iter()
            .map(|p| p.to_string_lossy().replace('\\', "/"))
            .collect();
        let output = self
            .runner
            .read(toplevel)
            .args(["ls-files", "-z", "--stage"])
            .cancel_token(cancel)
            .run()?;
        Ok(parse_stage_entries(&output.stdout)
            .into_iter()
            .filter(|e| wanted.contains(&e.path.to_string_lossy().replace('\\', "/")))
            .collect())
    }

    pub(super) fn untrack_impl(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        if paths.is_empty() {
            return Ok(());
        }
        // Without -f, git refuses a file whose staged content matches
        // neither HEAD nor the working tree, which would otherwise be lost.
        self.runner
            .write(toplevel)
            .env("GIT_LITERAL_PATHSPECS", "1")
            .args(["rm", "--cached", "-r", "-q", "--ignore-unmatch"])
            .args(PATHSPEC_STDIN)
            .stdin(pathspec_input(paths))
            .cancel_token(cancel)
            .run()
            .map(drop)
    }

    pub(super) fn restore_index_entries_impl(
        &self,
        toplevel: &Path,
        entries: &[IndexEntry],
        cancel: &CancelToken,
    ) -> Result<(), GitError> {
        if entries.is_empty() {
            return Ok(());
        }
        let mut input = Vec::new();
        for entry in entries {
            let path = entry.path.to_string_lossy().replace('\\', "/");
            input.extend_from_slice(format!("{} {}\t{path}", entry.mode, entry.oid).as_bytes());
            input.push(0);
        }
        self.runner
            .write(toplevel)
            .args(["update-index", "-z", "--index-info"])
            .stdin(input)
            .cancel_token(cancel)
            .run()
            .map(drop)
    }
}

impl CliBackend {
    pub(super) fn ignored_entries_impl(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        let output = self
            .runner
            .read(toplevel)
            .args([
                "ls-files",
                "-z",
                "--others",
                "--ignored",
                "--exclude-standard",
            ])
            .arg("--directory")
            .cancel_token(cancel)
            .run()?;
        Ok(split_paths(&output.stdout))
    }

    pub(super) fn tracked_ignored_impl(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        let output = self
            .runner
            .read(toplevel)
            .args([
                "ls-files",
                "-z",
                "--cached",
                "--ignored",
                "--exclude-standard",
            ])
            .cancel_token(cancel)
            .run()?;
        let mut paths = split_paths(&output.stdout);
        paths.dedup();
        Ok(paths)
    }

    pub(super) fn ignore_matches_impl(
        &self,
        toplevel: &Path,
        paths: &[PathBuf],
        tracked: bool,
        cancel: &CancelToken,
    ) -> Result<Vec<IgnoreMatch>, GitError> {
        if paths.is_empty() {
            return Ok(Vec::new());
        }
        let mut command = self.runner.read(toplevel).args([
            "check-ignore",
            "--verbose",
            "--non-matching",
            "-z",
            "--stdin",
        ]);
        if tracked {
            // Without it, check-ignore reports no rule for a tracked file.
            command = command.arg("--no-index");
        }
        let result = command
            .stdin(super::pathspec_input(paths))
            .cancel_token(cancel)
            .run();
        match result {
            Ok(out) => Ok(parse_check_ignore(&out.stdout)),
            // Exit code 1: none of the paths is ignored.
            Err(err) if err.exit_code == Some(1) => Ok(Vec::new()),
            Err(err) => Err(err),
        }
    }

    pub(super) fn ignore_files_impl(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Vec<PathBuf>, GitError> {
        let output = self
            .runner
            .read(toplevel)
            .args([
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
            ])
            .args(["--", ":(glob)**/.gitignore"])
            .cancel_token(cancel)
            .run()?;
        let mut paths = split_paths(&output.stdout);
        paths.sort();
        paths.dedup();
        Ok(paths)
    }

    pub(super) fn global_excludes_file_impl(
        &self,
        toplevel: &Path,
        cancel: &CancelToken,
    ) -> Result<Option<PathBuf>, GitError> {
        let result = self
            .runner
            .read(toplevel)
            .args(["config", "--path", "--get", "core.excludesFile"])
            .cancel_token(cancel)
            .run();
        match result {
            Ok(out) => {
                let text = String::from_utf8_lossy(&out.stdout);
                let text = text.trim_end_matches(['\r', '\n']);
                Ok((!text.is_empty()).then(|| PathBuf::from(text)))
            }
            // Not set: git reads `$XDG_CONFIG_HOME/git/ignore`, or
            // `$HOME/.config/git/ignore`.
            Err(err) if err.exit_code == Some(1) => Ok(default_global_excludes()),
            Err(err) => Err(err),
        }
    }
}

fn default_global_excludes() -> Option<PathBuf> {
    let non_empty = |name: &str| std::env::var_os(name).filter(|v| !v.is_empty());
    if let Some(xdg) = non_empty("XDG_CONFIG_HOME") {
        return Some(PathBuf::from(xdg).join("git").join("ignore"));
    }
    let home = non_empty("HOME").or_else(|| non_empty("USERPROFILE"))?;
    Some(
        PathBuf::from(home)
            .join(".config")
            .join("git")
            .join("ignore"),
    )
}

fn split_paths(output: &[u8]) -> Vec<PathBuf> {
    output
        .split(|&b| b == 0)
        .filter(|p| !p.is_empty())
        .map(crate::repo::git_path)
        .collect()
}

/// Stage-0 entries of `git ls-files -z --stage` (`mode oid stage\tpath`).
fn parse_stage_entries(output: &[u8]) -> Vec<IndexEntry> {
    output
        .split(|&b| b == 0)
        .filter_map(|record| {
            let tab = record.iter().position(|&b| b == b'\t')?;
            let head = String::from_utf8_lossy(&record[..tab]);
            let mut fields = head.split(' ');
            let (mode, oid, stage) = (fields.next()?, fields.next()?, fields.next()?);
            (stage == "0").then(|| IndexEntry {
                mode: mode.to_owned(),
                oid: oid.to_owned(),
                path: crate::repo::git_path(&record[tab + 1..]),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_stage_zero_entries() {
        let out =
            b"100644 aaaa 0\ta b.txt\x00100644 bbbb 1\tc.txt\x00100755 cccc 0\td/\xc3\xa9.sh\x00";
        let entries = parse_stage_entries(out);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].path, PathBuf::from("a b.txt"));
        assert_eq!(entries[1].mode, "100755");
        assert_eq!(entries[1].path, PathBuf::from("d/é.sh"));
    }
}
