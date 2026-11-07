//! The line-endings repository `fixture --eol` adds (M7.9): `eol`, for the
//! smoke test and screenshots of the marker rows, the header chip and the
//! endings-only card. Its local config turns `core.autocrlf` off, so git
//! compares the endings as written.
//!
//! Two commits: the text files, then `notes.txt` converted from LF to CRLF.
//! The working tree then converts `crlf.txt` to LF (endings only), edits
//! two lines of `edit.txt` and inserts one, all with CRLF endings in an LF
//! file, adds the final newline of `nonl.txt` (only that), converts
//! `both.txt` to LF and adds its final newline, and changes the last line of
//! `tail.txt` and drops its final newline.

use std::fs;
use std::path::Path;

use anyhow::Result;

use crate::fixture::Git;

/// `lines` joined with `ending` after each, the last one without it when
/// `final_newline` is false.
fn text(lines: &[&str], ending: &str, final_newline: bool) -> String {
    let mut out = lines.join(ending);
    if final_newline {
        out.push_str(ending);
    }
    out
}

const CRLF_LINES: [&str; 6] = [
    "[build]",
    "target = \"release\"",
    "jobs = 4",
    "",
    "[paths]",
    "out = \"dist\"",
];

const EDIT_LINES: [&str; 8] = [
    "fn main() {",
    "    let name = \"gitbello\";",
    "    let count = 3;",
    "    greet(name, count);",
    "}",
    "",
    "fn greet(name: &str, count: u32) {",
    "    println!(\"{name} x{count}\");",
];

pub fn build(git: &Git<'_>, dir: &Path) -> Result<()> {
    let repo = dir.join("eol");
    fs::create_dir_all(&repo)?;
    git.run(&repo, &["init", "--quiet", "--initial-branch=main"], None)?;
    git.run(&repo, &["config", "core.autocrlf", "false"], None)?;
    let put = |file: &str, content: String| fs::write(repo.join(file), content);
    put("crlf.txt", text(&CRLF_LINES, "\r\n", true))?;
    put("edit.txt", text(&EDIT_LINES, "\n", true))?;
    put("nonl.txt", text(&["alpha", "beta", "gamma"], "\n", false))?;
    put("both.txt", text(&["one", "two", "three"], "\r\n", false))?;
    put(
        "tail.txt",
        text(&["first", "second", "third", "last"], "\n", true),
    )?;
    put(
        "notes.txt",
        text(&["Notes", "", "- endings", "- newlines"], "\n", true),
    )?;
    git.run(&repo, &["add", "--all"], None)?;
    git.run(
        &repo,
        &["commit", "--quiet", "-F", "-"],
        Some("Add text files"),
    )?;
    put(
        "notes.txt",
        text(&["Notes", "", "- endings", "- newlines"], "\r\n", true),
    )?;
    git.run(&repo, &["add", "--all"], None)?;
    git.run(
        &repo,
        &["commit", "--quiet", "-F", "-"],
        Some("Convert the notes to CRLF"),
    )?;

    put("crlf.txt", text(&CRLF_LINES, "\n", true))?;
    let mut edit = text(&EDIT_LINES[..2], "\n", true);
    edit.push_str("    let count = 5;\r\n    greet(name, count * 2);\r\n");
    edit.push_str(&text(&EDIT_LINES[4..7], "\n", true));
    edit.push_str("    // Says hello.\r\n");
    edit.push_str(&text(&EDIT_LINES[7..], "\n", true));
    put("edit.txt", edit)?;
    put("nonl.txt", text(&["alpha", "beta", "gamma"], "\n", true))?;
    put("both.txt", text(&["one", "two", "three"], "\n", true))?;
    put(
        "tail.txt",
        text(&["first", "second", "third", "final"], "\n", false),
    )?;
    Ok(())
}
