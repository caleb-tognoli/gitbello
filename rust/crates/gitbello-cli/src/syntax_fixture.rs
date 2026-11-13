//! The syntax repository `fixture --syntax` adds (M7.13): `syntax`, for the
//! syntax sheet. Each core sample is committed in an older form (some lines
//! missing, some replaced by their neighbour) and the working tree holds the
//! sample itself, so every file's diff has context, added and removed lines.
//! `bin/tool` is the Python sample without an extension, found by its
//! shebang.

use std::fs;
use std::path::Path;

use anyhow::{Context, Result};

use crate::fixture::Git;
use crate::highlight_cmds::{samples, samples_dir};

/// The sample as committed: every fourth line from the second dropped, and
/// every sixth from the fourth replaced by the line before it.
fn older(text: &str) -> String {
    let mut out = String::new();
    let mut previous = "";
    for (i, line) in text.lines().enumerate() {
        if i % 4 == 1 {
            previous = line;
            continue;
        }
        out.push_str(if i % 6 == 3 { previous } else { line });
        out.push('\n');
        previous = line;
    }
    out
}

pub fn build(git: &Git<'_>, dir: &Path) -> Result<()> {
    let repo = dir.join("syntax");
    fs::create_dir_all(&repo)?;
    git.run(&repo, &["init", "--quiet", "--initial-branch=main"], None)?;
    git.run(&repo, &["config", "core.autocrlf", "false"], None)?;
    let mut files = Vec::new();
    for sample in samples(&samples_dir())? {
        let language = sample
            .parent()
            .and_then(Path::file_name)
            .context("sample folder")?;
        let name = sample.file_name().context("sample name")?;
        let text = fs::read_to_string(&sample)?.replace('\r', "");
        files.push((Path::new(language).join(name), text));
    }
    if let Some((_, python)) = files.iter().find(|(p, _)| p.starts_with("python")) {
        files.push((Path::new("bin").join("tool"), python.clone()));
    }
    for (path, text) in &files {
        let target = repo.join(path);
        fs::create_dir_all(target.parent().context("folder")?)?;
        fs::write(&target, older(text))?;
    }
    git.run(&repo, &["add", "--all"], None)?;
    git.run(
        &repo,
        &["commit", "--quiet", "-F", "-"],
        Some("Add the samples"),
    )?;
    for (path, text) in &files {
        fs::write(repo.join(path), text)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn older_drops_and_replaces_lines() {
        let text = "a\nb\nc\nd\ne\nf\ng\n";
        // b and f dropped (1, 5), d replaced by c (3).
        assert_eq!(older(text), "a\nc\nc\ne\ng\n");
    }
}
