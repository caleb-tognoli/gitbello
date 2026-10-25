//! Patches for partial staging (PLAN §3.10): the selected `+`/`-` lines of a
//! diff become a patch for `git apply`, with hunk headers recomputed.
//!
//! - **Stage** applies an unstaged diff's selected lines to the index.
//!   Unselected removals stay (as context); unselected additions are dropped.
//! - **Unstage** and **Discard** apply `-R`: the patch's new side must match
//!   the current content (index or working tree), so unselected additions
//!   stay (as context) and unselected removals are dropped.
//!
//! One side of the patch is always the file as it is (the old side when
//! staging, the new side otherwise); the other is the result. A line without
//! a final newline can only end the file, so when a result line that lacked
//! one is followed by other result lines, it gets its newline back (git gui
//! does the same). Line text is raw bytes, so CRLF endings pass through.

use std::collections::HashSet;
use std::fmt::Write as _;

use super::{FileDiff, LineKind};

const NO_NEWLINE: &[u8] = b"\\ No newline at end of file\n";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PatchMode {
    /// Selected lines of an unstaged diff go into the index.
    Stage,
    /// Selected lines of a staged diff come out of the index (`--cached -R`).
    Unstage,
    /// Selected lines of an unstaged diff are undone in the working tree (`-R`).
    Discard,
}

impl PatchMode {
    /// Whether the patch is applied with `-R`.
    pub fn is_reverse(self) -> bool {
        self != Self::Stage
    }

    /// Whether the patch is applied to the index (`--cached`).
    pub fn is_cached(self) -> bool {
        self != Self::Discard
    }
}

/// A line of the patch being built.
struct Out<'a> {
    text: &'a [u8],
    old: bool,
    new: bool,
    /// The line has no newline at the end of its file (per side, before the
    /// "only the last line" rule is applied).
    old_no_newline: bool,
    new_no_newline: bool,
}

/// The patch for `path` (`/`-separated, worktree-root relative) holding only
/// the selected changes; `selected` are indices into the diff's lines (hunk
/// headers select their whole hunk). `None` when no change is selected.
pub fn build_patch(
    diff: &FileDiff,
    path: &str,
    selected: &[usize],
    mode: PatchMode,
) -> Option<Vec<u8>> {
    let mut chosen: HashSet<usize> = HashSet::new();
    for (h, hunk) in diff.hunks.iter().enumerate() {
        let end = hunk_end(diff, h);
        if selected.contains(&hunk.line) {
            chosen.extend(hunk.line + 1..end);
        }
    }
    chosen.extend(selected.iter().copied());

    let reverse = mode.is_reverse();
    let mut body = Vec::new();
    // Lines added minus lines removed by the hunks emitted so far.
    let mut delta: i64 = 0;
    for (h, hunk) in diff.hunks.iter().enumerate() {
        let mut out: Vec<Out<'_>> = Vec::new();
        let mut changes = false;
        for i in hunk.line + 1..hunk_end(diff, h) {
            let entry = diff.lines[i];
            let text = &diff.text[entry.start..entry.end];
            let no_newline = entry.no_newline;
            let picked = chosen.contains(&i);
            let (old, new) = match entry.kind {
                LineKind::Hunk => continue,
                LineKind::Context => (true, true),
                LineKind::Removed if picked => (true, false),
                LineKind::Added if picked => (false, true),
                // Not picked: the line is in the file as it is, and stays.
                LineKind::Removed if !reverse => (true, true),
                LineKind::Added if reverse => (true, true),
                LineKind::Removed | LineKind::Added => continue,
            };
            changes |= picked && entry.kind != LineKind::Context;
            out.push(Out {
                text,
                old,
                new,
                old_no_newline: old && no_newline,
                new_no_newline: new && no_newline,
            });
        }
        if !changes {
            continue;
        }
        let last_old = out.iter().rposition(|l| l.old);
        let last_new = out.iter().rposition(|l| l.new);
        let mut lines = Vec::new();
        let (mut old_count, mut new_count) = (0i64, 0i64);
        for (i, line) in out.iter().enumerate() {
            let old_nl = line.old_no_newline && Some(i) == last_old;
            let new_nl = line.new_no_newline && Some(i) == last_new;
            if line.old && line.new && old_nl == new_nl {
                push_line(&mut lines, b' ', line.text, old_nl);
                old_count += 1;
                new_count += 1;
                continue;
            }
            if line.old {
                push_line(&mut lines, b'-', line.text, old_nl);
                old_count += 1;
            }
            if line.new {
                push_line(&mut lines, b'+', line.text, new_nl);
                new_count += 1;
            }
        }
        // The side that is the file as it is keeps its start; the other
        // side shifts by what the earlier emitted hunks added or removed.
        let (old_start, new_start) = if reverse {
            let new_start = i64::from(hunk.new_start);
            let at = first_line(new_start, new_count) - delta;
            (start_of(at, old_count), new_start)
        } else {
            let old_start = i64::from(hunk.old_start);
            let at = first_line(old_start, old_count) + delta;
            (old_start, start_of(at, new_count))
        };
        delta += new_count - old_count;
        let mut header = String::new();
        let _ = writeln!(
            header,
            "@@ -{old_start},{old_count} +{new_start},{new_count} @@"
        );
        body.extend_from_slice(header.as_bytes());
        body.extend_from_slice(&lines);
    }
    if body.is_empty() {
        return None;
    }
    let a = quote_path(&format!("a/{path}"));
    let b = quote_path(&format!("b/{path}"));
    // Added to an index that lacks the file: say it is new.
    let mut patch = if mode == PatchMode::Stage && diff.header.new_file {
        let file_mode = diff.header.new_mode.as_deref().unwrap_or("100644");
        format!("diff --git {a} {b}\nnew file mode {file_mode}\n--- /dev/null\n+++ {b}\n")
    } else {
        format!("diff --git {a} {b}\n--- {a}\n+++ {b}\n")
    }
    .into_bytes();
    patch.extend_from_slice(&body);
    Some(patch)
}

/// Index of the line after hunk `h`.
fn hunk_end(diff: &FileDiff, h: usize) -> usize {
    diff.hunks
        .get(h + 1)
        .map_or(diff.lines.len(), |next| next.line)
}

/// First line a range covers; a count of 0 means "after line `start`".
fn first_line(start: i64, count: i64) -> i64 {
    if count > 0 {
        start
    } else {
        start + 1
    }
}

fn start_of(first: i64, count: i64) -> i64 {
    if count > 0 {
        first
    } else {
        first - 1
    }
}

fn push_line(out: &mut Vec<u8>, prefix: u8, text: &[u8], no_newline: bool) {
    out.push(prefix);
    out.extend_from_slice(text);
    out.push(b'\n');
    if no_newline {
        out.extend_from_slice(NO_NEWLINE);
    }
}

/// Quotes a patch path the way git does when it holds `"`, `\` or control
/// characters (spaces and non-ASCII stay as they are).
fn quote_path(path: &str) -> String {
    if !path
        .chars()
        .any(|c| c == '"' || c == '\\' || c.is_control())
    {
        return path.to_owned();
    }
    let mut out = String::from("\"");
    for c in path.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c if c.is_control() => {
                let _ = write!(out, "\\{:03o}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::parse_diff;

    fn patch(diff: &[u8], selected: &[usize], mode: PatchMode) -> String {
        let diff = parse_diff(diff).unwrap();
        String::from_utf8(build_patch(&diff, "f.txt", selected, mode).unwrap()).unwrap()
    }

    const TWO_HUNKS: &[u8] = b"diff --git a/f.txt b/f.txt
--- a/f.txt
+++ b/f.txt
@@ -1,4 +1,4 @@
 a
-b
+B
 c
 d
@@ -10,3 +10,4 @@
 j
 k
+k2
 l
";

    #[test]
    fn stage_one_line_keeps_unselected_removals_as_context() {
        // Lines: 0 hunk, 1 a, 2 -b, 3 +B, 4 c, 5 d, 6 hunk, 7 j, 8 k, 9 +k2, 10 l.
        let only_add = patch(TWO_HUNKS, &[3], PatchMode::Stage);
        assert_eq!(
            only_add,
            "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n\
             @@ -1,4 +1,5 @@\n a\n b\n+B\n c\n d\n"
        );
        let only_remove = patch(TWO_HUNKS, &[2], PatchMode::Stage);
        assert!(
            only_remove.ends_with("@@ -1,4 +1,3 @@\n a\n-b\n c\n d\n"),
            "{only_remove}"
        );
    }

    #[test]
    fn later_hunks_shift_by_earlier_ones() {
        let both = patch(TWO_HUNKS, &[3, 9], PatchMode::Stage);
        assert!(both.contains("@@ -1,4 +1,5 @@"), "{both}");
        // The first hunk added a line: the second starts one line later.
        assert!(
            both.contains("@@ -10,3 +11,4 @@\n j\n k\n+k2\n l\n"),
            "{both}"
        );
        let second_only = patch(TWO_HUNKS, &[9], PatchMode::Stage);
        assert!(!second_only.contains("@@ -1,"), "{second_only}");
        assert!(second_only.contains("@@ -10,3 +10,4 @@"), "{second_only}");
    }

    #[test]
    fn hunk_header_selects_the_whole_hunk() {
        let hunk = patch(TWO_HUNKS, &[0], PatchMode::Stage);
        assert!(
            hunk.contains("@@ -1,4 +1,4 @@\n a\n-b\n+B\n c\n d\n"),
            "{hunk}"
        );
        assert!(!hunk.contains("k2"));
        let diff = parse_diff(TWO_HUNKS).unwrap();
        assert!(build_patch(&diff, "f.txt", &[1, 4], PatchMode::Stage).is_none());
    }

    #[test]
    fn reverse_patches_keep_unselected_additions_as_context() {
        // Unstaging only the removal of `b`: `+B` stays in the index.
        let unstage = patch(TWO_HUNKS, &[2], PatchMode::Unstage);
        assert!(
            unstage.ends_with("@@ -1,5 +1,4 @@\n a\n-b\n B\n c\n d\n"),
            "{unstage}"
        );
        // Discarding only the second hunk's addition.
        let discard = patch(TWO_HUNKS, &[9], PatchMode::Discard);
        assert!(
            discard.contains("@@ -10,3 +10,4 @@\n j\n k\n+k2\n l\n"),
            "{discard}"
        );
        // Discarding the first hunk's `+B` alone: `-b` is dropped (not in the file).
        let first = patch(TWO_HUNKS, &[3, 9], PatchMode::Discard);
        assert!(
            first.contains("@@ -1,3 +1,4 @@\n a\n+B\n c\n d\n"),
            "{first}"
        );
        assert!(first.contains("@@ -9,3 +10,4 @@"), "{first}");
    }

    const NO_NL: &[u8] = b"diff --git a/f.txt b/f.txt
--- a/f.txt
+++ b/f.txt
@@ -1,2 +1,3 @@
 x
-a
\\ No newline at end of file
+a
+b
\\ No newline at end of file
";

    #[test]
    fn missing_final_newlines_end_the_file_only() {
        // Lines: 0 hunk, 1 x, 2 -a (no newline), 3 +a, 4 +b (no newline).
        // Staging `+b` alone: `a` stays but is no longer last, so it gets a newline.
        let b_only = patch(NO_NL, &[4], PatchMode::Stage);
        assert!(
            b_only.ends_with("@@ -1,2 +1,3 @@\n x\n-a\n\\ No newline at end of file\n+a\n+b\n\\ No newline at end of file\n"),
            "{b_only}"
        );
        // Staging the newline fix (`-a`, `+a`) without `b`.
        let fix = patch(NO_NL, &[2, 3], PatchMode::Stage);
        assert!(
            fix.ends_with("@@ -1,2 +1,2 @@\n x\n-a\n\\ No newline at end of file\n+a\n"),
            "{fix}"
        );
        // Discarding `+b`: the worktree's last line `b` goes; `a` keeps its newline.
        let discard = patch(NO_NL, &[4], PatchMode::Discard);
        assert!(
            discard.ends_with("@@ -1,2 +1,3 @@\n x\n a\n+b\n\\ No newline at end of file\n"),
            "{discard}"
        );
    }

    #[test]
    fn crlf_lines_pass_through() {
        let diff = b"diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+c\r\n";
        let p = patch(diff, &[3], PatchMode::Stage);
        assert!(p.ends_with("@@ -1,2 +1,3 @@\n a\r\n b\r\n+c\r\n"), "{p:?}");
    }

    #[test]
    fn new_files_and_odd_paths() {
        let diff = parse_diff(
            b"diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1,3 @@\n+1\n+2\n+3\n",
        )
        .unwrap();
        let p =
            String::from_utf8(build_patch(&diff, "n", &[2], PatchMode::Unstage).unwrap()).unwrap();
        assert!(p.ends_with("@@ -1,2 +1,3 @@\n 1\n+2\n 3\n"), "{p}");
        let staged =
            String::from_utf8(build_patch(&diff, "n", &[1], PatchMode::Stage).unwrap()).unwrap();
        assert!(
            staged
                .starts_with("diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n"),
            "{staged}"
        );
        assert!(
            staged.ends_with("@@ -0,0 +1 @@\n+1\n") || staged.ends_with("@@ -0,0 +1,1 @@\n+1\n"),
            "{staged}"
        );

        assert_eq!(quote_path("a/dir/ünï space.txt"), "a/dir/ünï space.txt");
        assert_eq!(quote_path("a/tab\there\"q"), "\"a/tab\\there\\\"q\"");
    }
}
