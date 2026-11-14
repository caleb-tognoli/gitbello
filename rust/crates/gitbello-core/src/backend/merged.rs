//! Merged by content: a branch whose commits are not in the base but whose
//! changes are, because the base got them squashed into one commit or
//! rebased (GitHub's "Squash and merge" and "Rebase and merge"). Read-only:
//! it compares `git patch-id`s and writes no objects.

use std::collections::HashSet;
use std::path::Path;

use super::CliBackend;
use crate::git::{CancelToken, GitError};

/// The newest non-merge commits of the base the check looks at: a squash or
/// rebase merge older than these is not found (the branch then shows as not
/// merged), which keeps the check well under a second on busy repositories.
pub const CONTENT_MERGE_LIMIT: usize = 500;

/// How a branch's commits that the base does not reach are in it anyway.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ContentMerge {
    /// Commits (merges left out) whose change the base does not have.
    pub missing: u32,
    /// The base has the branch's whole change in one commit (a squash
    /// merge) but not its commits one by one; `missing` is then 0.
    pub squashed: bool,
}

/// Flags that keep the patches the same whatever the user's config.
const PATCH_ARGS: &[&str] = &[
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--no-renames",
];

impl CliBackend {
    pub(super) fn merged_by_content_impl(
        &self,
        repo: &Path,
        bases: &[String],
        tips: &[String],
        limit: usize,
        cancel: &CancelToken,
    ) -> Result<Vec<ContentMerge>, GitError> {
        let mut out = Vec::with_capacity(tips.len());
        if bases.is_empty() {
            for tip in tips {
                out.push(ContentMerge {
                    missing: self.count_missing(repo, bases, tip, cancel)?,
                    squashed: false,
                });
            }
            return Ok(out);
        }
        let mut base_ids: Option<HashSet<String>> = None;
        for tip in tips {
            let missing = self.count_missing(repo, bases, tip, cancel)?;
            if missing == 0 {
                out.push(ContentMerge::default());
                continue;
            }
            if base_ids.is_none() {
                base_ids = Some(self.base_patch_ids(repo, bases, limit, cancel)?);
            }
            let Some(ids) = base_ids.as_ref() else {
                continue;
            };
            out.push(self.tip_content_merge(repo, bases, tip, missing, limit, ids, cancel)?);
        }
        Ok(out)
    }

    /// Commits of `tip` no base reaches, merges left out.
    fn count_missing(
        &self,
        repo: &Path,
        bases: &[String],
        tip: &str,
        cancel: &CancelToken,
    ) -> Result<u32, GitError> {
        let excluded: Vec<String> = bases.iter().map(|b| format!("^{b}")).collect();
        let mut args = vec!["rev-list", "--count", "--no-merges", tip];
        args.extend(excluded.iter().map(String::as_str));
        args.push("--");
        let out = self.read(repo, &args, cancel)?;
        Ok(out.stdout_text().trim().parse().unwrap_or(0))
    }

    /// Patch ids of the bases' newest `limit` non-merge commits.
    fn base_patch_ids(
        &self,
        repo: &Path,
        bases: &[String],
        limit: usize,
        cancel: &CancelToken,
    ) -> Result<HashSet<String>, GitError> {
        let count = format!("--max-count={limit}");
        let mut args = vec!["log", "-p", "--no-merges", "--format=commit %H", &count];
        args.extend_from_slice(PATCH_ARGS);
        args.extend(bases.iter().map(String::as_str));
        args.push("--");
        let patches = self.read(repo, &args, cancel)?;
        Ok(self
            .patch_ids(repo, patches.stdout, cancel)?
            .into_iter()
            .map(|(id, _)| id)
            .collect())
    }

    #[allow(clippy::too_many_arguments)]
    fn tip_content_merge(
        &self,
        repo: &Path,
        bases: &[String],
        tip: &str,
        missing: u32,
        limit: usize,
        base_ids: &HashSet<String>,
        cancel: &CancelToken,
    ) -> Result<ContentMerge, GitError> {
        let not_found = ContentMerge {
            missing,
            squashed: false,
        };
        if base_ids.is_empty() || missing as usize > limit {
            return Ok(not_found);
        }
        // Each commit on its own (a rebase merge, or picked one by one).
        let excluded: Vec<String> = bases.iter().map(|b| format!("^{b}")).collect();
        let mut args = vec!["log", "-p", "--no-merges", "--format=commit %H"];
        args.extend_from_slice(PATCH_ARGS);
        args.push(tip);
        args.extend(excluded.iter().map(String::as_str));
        args.push("--");
        let patches = self.read(repo, &args, cancel)?;
        let found = self
            .patch_ids(repo, patches.stdout, cancel)?
            .iter()
            .filter(|(id, _)| base_ids.contains(id))
            .count();
        let left = missing.saturating_sub(u32::try_from(found).unwrap_or(u32::MAX));
        if left == 0 {
            return Ok(ContentMerge::default());
        }
        // Else the whole change since the branch left the base, as one patch.
        for base in bases {
            let Some(fork) = self.fork_point(repo, base, tip, cancel)? else {
                continue;
            };
            let mut args = vec!["diff", "-p"];
            args.extend_from_slice(PATCH_ARGS);
            args.extend([fork.as_str(), tip, "--"]);
            let patch = self.read(repo, &args, cancel)?;
            let whole = self.patch_ids(repo, patch.stdout, cancel)?;
            if whole.iter().any(|(id, _)| base_ids.contains(id)) {
                return Ok(ContentMerge {
                    missing: 0,
                    squashed: true,
                });
            }
        }
        Ok(ContentMerge {
            missing: left,
            squashed: false,
        })
    }

    /// Where `tip` left `base`, or `None` when they share no history.
    fn fork_point(
        &self,
        repo: &Path,
        base: &str,
        tip: &str,
        cancel: &CancelToken,
    ) -> Result<Option<String>, GitError> {
        match self.read(repo, &["merge-base", base, tip], cancel) {
            Ok(out) => Ok(Some(out.stdout_text().trim().to_owned()).filter(|s| !s.is_empty())),
            Err(err) if err.exit_code == Some(1) => Ok(None),
            Err(err) => Err(err),
        }
    }

    /// `(patch id, commit)` of each patch in `patches` (`git patch-id
    /// --stable`; a plain diff's commit is zeros). An empty patch has none.
    fn patch_ids(
        &self,
        repo: &Path,
        patches: Vec<u8>,
        cancel: &CancelToken,
    ) -> Result<Vec<(String, String)>, GitError> {
        if patches.is_empty() {
            return Ok(Vec::new());
        }
        let out = self
            .runner
            .read(repo)
            .args(["patch-id", "--stable"])
            .stdin(patches)
            .cancel_token(cancel)
            .run()?;
        Ok(parse_patch_ids(&out.stdout_text()))
    }
}

/// `git patch-id` lines: `<patch id> <commit>`.
fn parse_patch_ids(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| {
            let (id, commit) = line.split_once(' ')?;
            Some((id.to_owned(), commit.trim().to_owned()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn patch_id_lines_parse() {
        let text = "1111 aaaa\n2222 0000\n\n";
        assert_eq!(
            parse_patch_ids(text),
            [
                ("1111".to_owned(), "aaaa".to_owned()),
                ("2222".to_owned(), "0000".to_owned())
            ]
        );
    }
}
