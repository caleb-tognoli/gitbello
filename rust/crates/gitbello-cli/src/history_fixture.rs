//! The file-history repository `fixture --history` adds (M8a): `history`,
//! for the smoke test and screenshots of a file's history.
//!
//! `src/login/auth.rs` was `src/auth.rs` until `main` moved it; `side`,
//! split off before the move, edited it under the old name and was merged
//! afterwards, so its history is: Improve login (with a co-author), Merge
//! side, Handle empty passwords (on `side`, under the old name), Move auth
//! into login (the rename), Check tokens, Add auth. `gone.txt` was added
//! and deleted again. `topic`, not merged, has one more commit on the file
//! ("Try a longer timeout"). The working tree edits `src/login/auth.rs` and
//! has an untracked `notes.txt`.

use std::fs;
use std::path::Path;

use anyhow::Result;

use crate::fixture::Git;

const AUTH: [&str; 12] = [
    "use std::time::Duration;",
    "",
    "const TIMEOUT: Duration = Duration::from_secs(30);",
    "",
    "pub fn login(user: &str, password: &str) -> bool {",
    "    let known = lookup(user);",
    "    known == Some(hash(password))",
    "}",
    "",
    "fn lookup(user: &str) -> Option<u64> {",
    "    store().get(user).copied()",
    "}",
];

fn text(lines: &[&str]) -> String {
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

/// `lines` with line `at` (0-based) replaced by `with`.
fn replaced(lines: &[&str], at: usize, with: &[&str]) -> Vec<String> {
    let mut out: Vec<String> = lines[..at].iter().map(|l| (*l).to_owned()).collect();
    out.extend(with.iter().map(|l| (*l).to_owned()));
    out.extend(lines[at + 1..].iter().map(|l| (*l).to_owned()));
    out
}

fn write(repo: &Path, file: &str, lines: &[String]) -> Result<()> {
    let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
    let target = repo.join(file);
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(target, text(&refs))?;
    Ok(())
}

fn commit(git: &Git<'_>, repo: &Path, file: &str, lines: &[String], message: &str) -> Result<()> {
    write(repo, file, lines)?;
    git.run(repo, &["add", "--", file], None)?;
    git.run(repo, &["commit", "--quiet", "-F", "-"], Some(message))
}

pub(crate) fn build(git: &Git<'_>, dir: &Path) -> Result<()> {
    let repo = dir.join("history");
    fs::create_dir_all(&repo)?;
    git.run(&repo, &["init", "--quiet", "--initial-branch=main"], None)?;
    let first: Vec<String> = AUTH.iter().map(|l| (*l).to_owned()).collect();
    commit(git, &repo, "src/auth.rs", &first, "Add auth")?;
    commit(
        git,
        &repo,
        "README.md",
        &["# history".to_owned()],
        "Add readme",
    )?;
    commit(
        git,
        &repo,
        "gone.txt",
        &["short-lived".to_owned()],
        "Add a scratch file",
    )?;
    let checked = replaced(
        &AUTH,
        6,
        &[
            "    check_token(user);",
            "    known == Some(hash(password))",
        ],
    );
    commit(git, &repo, "src/auth.rs", &checked, "Check tokens")?;
    git.run(&repo, &["branch", "side"], None)?;

    // main moves the file and edits a line.
    fs::create_dir_all(repo.join("src/login"))?;
    git.run(&repo, &["mv", "src/auth.rs", "src/login/auth.rs"], None)?;
    let checked_refs: Vec<&str> = checked.iter().map(String::as_str).collect();
    let moved = replaced(
        &checked_refs,
        2,
        &["const TIMEOUT: Duration = Duration::from_secs(60);"],
    );
    commit(
        git,
        &repo,
        "src/login/auth.rs",
        &moved,
        "Move auth into login",
    )?;
    git.run(&repo, &["rm", "--quiet", "gone.txt"], None)?;
    git.run(
        &repo,
        &["commit", "--quiet", "-F", "-"],
        Some("Remove the scratch file"),
    )?;

    // side edits it under its old name; main merges that.
    git.run(&repo, &["checkout", "--quiet", "side"], None)?;
    let mut side = checked.clone();
    side.insert(5, "    if password.is_empty() {".to_owned());
    side.insert(6, "        return false;".to_owned());
    side.insert(7, "    }".to_owned());
    commit(git, &repo, "src/auth.rs", &side, "Handle empty passwords")?;
    git.run(&repo, &["checkout", "--quiet", "main"], None)?;
    git.run(
        &repo,
        &["merge", "--quiet", "--no-ff", "-m", "Merge side", "side"],
        None,
    )?;

    let merged = fs::read_to_string(repo.join("src/login/auth.rs"))?;
    let mut improved: Vec<String> = merged.lines().map(str::to_owned).collect();
    improved.push(String::new());
    improved.push("fn hash(password: &str) -> u64 {".to_owned());
    improved.push("    password.bytes().fold(7, |h, b| h * 31 + u64::from(b))".to_owned());
    improved.push("}".to_owned());
    commit(
        git,
        &repo,
        "src/login/auth.rs",
        &improved,
        "Improve login\n\nHash passwords in one place.\n\nCo-authored-by: Robin Example <robin@example.com>",
    )?;

    // topic, not merged: one more commit on the file.
    git.run(&repo, &["checkout", "--quiet", "-b", "topic"], None)?;
    let improved_refs: Vec<&str> = improved.iter().map(String::as_str).collect();
    let longer = replaced(
        &improved_refs,
        2,
        &["const TIMEOUT: Duration = Duration::from_secs(120);"],
    );
    commit(
        git,
        &repo,
        "src/login/auth.rs",
        &longer,
        "Try a longer timeout",
    )?;
    git.run(&repo, &["checkout", "--quiet", "main"], None)?;

    // Local changes: an edit of the file and an untracked one.
    let mut local = improved.clone();
    local.push(String::new());
    local.push("// TODO: rate limiting".to_owned());
    write(&repo, "src/login/auth.rs", &local)?;
    fs::write(repo.join("notes.txt"), "untracked\n")?;
    Ok(())
}
