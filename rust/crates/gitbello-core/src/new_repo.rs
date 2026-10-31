//! Options of the Create, Initialize folder and Clone flows (PLAN §4 Home)
//! and the starter files they write.

use std::fs;
use std::io;
use std::path::Path;

/// Message of the first commit Create and Initialize folder can make.
pub const FIRST_COMMIT_MESSAGE: &str = "Initial commit";

/// Bundled `.gitignore` templates (see `templates/gitignore/README.md`).
pub const GITIGNORE_TEMPLATES: &[(&str, &str)] = &[
    (
        "Godot",
        include_str!("../templates/gitignore/Godot.gitignore"),
    ),
    (
        "Node",
        include_str!("../templates/gitignore/Node.gitignore"),
    ),
    (
        "Python",
        include_str!("../templates/gitignore/Python.gitignore"),
    ),
    (
        "Rust",
        include_str!("../templates/gitignore/Rust.gitignore"),
    ),
    (
        "Unity",
        include_str!("../templates/gitignore/Unity.gitignore"),
    ),
    (
        "Visual Studio",
        include_str!("../templates/gitignore/VisualStudio.gitignore"),
    ),
];

pub fn gitignore_template(name: &str) -> Option<&'static str> {
    GITIGNORE_TEMPLATES
        .iter()
        .find(|(n, _)| *n == name)
        .map(|(_, text)| *text)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateOptions {
    pub initial_branch: String,
    /// Name of a [`GITIGNORE_TEMPLATES`] entry.
    pub gitignore: Option<String>,
    /// Writes `README.md` with the folder name as its title.
    pub readme: bool,
    /// Commits every file after `git init` (when there is any).
    pub first_commit: bool,
    /// Initializes a folder that has files (Initialize folder) instead of a
    /// missing or empty one (Create).
    pub existing: bool,
}

impl CreateOptions {
    pub fn new(initial_branch: &str) -> Self {
        Self {
            initial_branch: initial_branch.to_owned(),
            gitignore: None,
            readme: false,
            first_commit: false,
            existing: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CloneOptions {
    /// Checks out this branch instead of the remote's default.
    pub branch: Option<String>,
    pub submodules: bool,
}

/// Why `path` cannot be initialized in place, or `None`: it must be an
/// existing folder that is not a repository yet.
pub fn init_folder_error(path: &Path) -> Option<&'static str> {
    if path.as_os_str().is_empty() {
        return Some("Choose a folder.");
    }
    if !path.is_dir() {
        return Some("Choose an existing folder.");
    }
    if path.join(".git").exists() {
        return Some("This folder is already a git repository.");
    }
    None
}

/// Writes the template and README that `options` asks for, leaving files
/// that exist alone.
pub fn write_starter_files(path: &Path, options: &CreateOptions) -> io::Result<()> {
    if let Some(text) = options.gitignore.as_deref().and_then(gitignore_template) {
        write_new(&path.join(".gitignore"), text)?;
    }
    if options.readme {
        let name = path
            .file_name()
            .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
        write_new(&path.join("README.md"), &format!("# {name}\n"))?;
    }
    Ok(())
}

/// Whether `path` has anything besides `.git` to commit.
pub fn has_files(path: &Path) -> bool {
    fs::read_dir(path).is_ok_and(|entries| {
        entries
            .filter_map(Result::ok)
            .any(|e| e.file_name() != ".git")
    })
}

fn write_new(path: &Path, text: &str) -> io::Result<()> {
    if path.exists() {
        return Ok(());
    }
    fs::write(path, text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_template_has_content() {
        for (name, text) in GITIGNORE_TEMPLATES {
            assert!(text.lines().count() > 5, "{name}");
            assert_eq!(gitignore_template(name), Some(*text));
        }
        assert_eq!(gitignore_template("Cobol"), None);
    }
}
