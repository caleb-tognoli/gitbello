//! The repository library (PLAN §3.8, D13): every repository the user added,
//! with its display name, pin and last-opened time, as a TOML file in the
//! app's data dir. Keys this version does not know are kept and written back.
//!
//! Entries are repositories, never linked worktrees or subfolders: see
//! [`library_root`]. Paths are stored normalised and compare by [`path_key`],
//! so `C:\a` and `C:/a/` are one entry.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use toml::{Table, Value};

use crate::backend::GitBackend;
use crate::config::ConfigError;
use crate::git::{CancelToken, GitError, GitErrorKind};
use crate::repo::{FileState, Head, RepoPaths};
use crate::runtime::normalize;

/// File name inside the data dir.
pub const FILE_NAME: &str = "library.toml";

/// Removals remembered for undo.
pub const MAX_UNDO: usize = 20;

#[derive(Debug, Clone, PartialEq)]
pub struct RepoEntry {
    pub path: PathBuf,
    /// Shown instead of the folder name; never renames the folder.
    pub display_name: Option<String>,
    pub pinned: bool,
    /// Unix seconds.
    pub added_at: i64,
    /// Unix seconds; `None` until it is opened (scanned repositories).
    pub last_opened_at: Option<i64>,
    /// The repository's first root commit, once read, to tell whether a
    /// new location holds the same repository.
    pub root_commit: Option<String>,
    extra: Table,
}

impl RepoEntry {
    pub fn new(path: &Path, now: i64) -> Self {
        Self {
            path: path.to_path_buf(),
            display_name: None,
            pinned: false,
            added_at: now,
            last_opened_at: None,
            root_commit: None,
            extra: Table::new(),
        }
    }

    /// The display name, or the folder name.
    pub fn name(&self) -> String {
        if let Some(name) = &self.display_name {
            return name.clone();
        }
        folder_name(&self.path)
    }

    fn parse(value: Value) -> Option<Self> {
        let Value::Table(mut table) = value else {
            return None;
        };
        let path = match table.remove("path") {
            Some(Value::String(path)) if !path.is_empty() => PathBuf::from(path),
            _ => return None,
        };
        let text = |table: &mut Table, key: &str| match table.remove(key) {
            Some(Value::String(s)) if !s.is_empty() => Some(s),
            _ => None,
        };
        let display_name = text(&mut table, "name");
        let root_commit = text(&mut table, "root_commit");
        let pinned = matches!(table.remove("pinned"), Some(Value::Boolean(true)));
        let added_at = table
            .remove("added")
            .and_then(|v| v.as_integer())
            .unwrap_or(0);
        let last_opened_at = table.remove("opened").and_then(|v| v.as_integer());
        Some(Self {
            path,
            display_name,
            pinned,
            added_at,
            last_opened_at,
            root_commit,
            extra: table,
        })
    }

    fn to_value(&self) -> Value {
        let mut table = Table::new();
        table.insert(
            "path".into(),
            Value::String(self.path.to_string_lossy().into_owned()),
        );
        if let Some(name) = &self.display_name {
            table.insert("name".into(), Value::String(name.clone()));
        }
        if self.pinned {
            table.insert("pinned".into(), Value::Boolean(true));
        }
        table.insert("added".into(), Value::Integer(self.added_at));
        if let Some(opened) = self.last_opened_at {
            table.insert("opened".into(), Value::Integer(opened));
        }
        if let Some(root) = &self.root_commit {
            table.insert("root_commit".into(), Value::String(root.clone()));
        }
        for (key, value) in &self.extra {
            table.entry(key.clone()).or_insert_with(|| value.clone());
        }
        Value::Table(table)
    }
}

#[derive(Debug, Default)]
pub struct RepoLibrary {
    /// `None` keeps the library in memory only.
    path: Option<PathBuf>,
    entries: Vec<RepoEntry>,
    /// Top-level keys this version does not know.
    extra: Table,
    /// Removed entries with their index, newest last.
    removed: Vec<(usize, RepoEntry)>,
}

impl RepoLibrary {
    /// Loads `path`. A missing file imports `known` (the config's old recent
    /// list, most recent first) and saves it. A broken file gives an empty
    /// library; it is kept as `<name>.broken` and its error returned, so the
    /// next save does not lose it silently.
    pub fn load(path: Option<PathBuf>, known: &[PathBuf]) -> (Self, Option<ConfigError>) {
        let mut library = Self {
            path: path.clone(),
            ..Self::default()
        };
        let Some(path) = path else {
            library.import(known, now());
            return (library, None);
        };
        let text = match fs::read_to_string(&path) {
            Ok(text) => text,
            Err(err) if err.kind() == io::ErrorKind::NotFound => {
                library.import(known, now());
                let error = if library.entries.is_empty() {
                    None
                } else {
                    library.save().err()
                };
                return (library, error);
            }
            Err(source) => return (library, Some(ConfigError::Read { path, source })),
        };
        match parse(&text) {
            Ok((entries, extra)) => {
                library.entries = entries;
                library.extra = extra;
                (library, None)
            }
            Err(error) => {
                let _ = fs::rename(&path, path.with_extension("toml.broken"));
                (library, Some(error))
            }
        }
    }

    /// Entries in the order they were added.
    pub fn entries(&self) -> &[RepoEntry] {
        &self.entries
    }

    pub fn get(&self, path: &Path) -> Option<&RepoEntry> {
        self.index(path).map(|i| &self.entries[i])
    }

    pub fn contains(&self, path: &Path) -> bool {
        self.index(path).is_some()
    }

    /// Opened entries, most recently opened first (at most `count`).
    pub fn recent(&self, count: usize) -> Vec<&RepoEntry> {
        let mut opened: Vec<&RepoEntry> = self
            .entries
            .iter()
            .filter(|e| e.last_opened_at.is_some())
            .collect();
        opened.sort_by_key(|e| std::cmp::Reverse(e.last_opened_at));
        opened.truncate(count);
        opened
    }

    /// Adds `path` unless it is there. Returns whether it was added.
    pub fn add(&mut self, path: &Path, now: i64) -> bool {
        if self.contains(path) {
            return false;
        }
        self.entries.push(RepoEntry::new(&normalize(path), now));
        true
    }

    /// Adds `path` if needed and marks it opened now.
    pub fn touch(&mut self, path: &Path, now: i64) {
        self.add(path, now);
        if let Some(i) = self.index(path) {
            self.entries[i].last_opened_at = Some(now);
        }
    }

    /// Removes `path`; [`RepoLibrary::undo_remove`] brings it back.
    pub fn remove(&mut self, path: &Path) -> bool {
        let Some(i) = self.index(path) else {
            return false;
        };
        let entry = self.entries.remove(i);
        self.removed.push((i, entry));
        if self.removed.len() > MAX_UNDO {
            self.removed.remove(0);
        }
        true
    }

    pub fn can_undo_remove(&self) -> bool {
        !self.removed.is_empty()
    }

    /// Puts the last removed entry back where it was. Returns its path, or
    /// `None` when there is nothing to undo (or it was added again since).
    pub fn undo_remove(&mut self) -> Option<PathBuf> {
        let (i, entry) = self.removed.pop()?;
        if self.contains(&entry.path) {
            return None;
        }
        let path = entry.path.clone();
        self.entries.insert(i.min(self.entries.len()), entry);
        Some(path)
    }

    /// Sets (or with an empty `name`, clears) the display name.
    pub fn rename(&mut self, path: &Path, name: &str) -> bool {
        let Some(i) = self.index(path) else {
            return false;
        };
        let name = name.trim();
        self.entries[i].display_name =
            (!name.is_empty() && name != folder_name(&self.entries[i].path)).then(|| name.into());
        true
    }

    pub fn set_pinned(&mut self, path: &Path, pinned: bool) -> bool {
        let Some(i) = self.index(path) else {
            return false;
        };
        self.entries[i].pinned = pinned;
        true
    }

    /// Records the root commit read for `path`. Returns whether it changed.
    pub fn set_root_commit(&mut self, path: &Path, root: &str) -> bool {
        let Some(i) = self.index(path) else {
            return false;
        };
        if self.entries[i].root_commit.as_deref() == Some(root) {
            return false;
        }
        self.entries[i].root_commit = Some(root.to_owned());
        true
    }

    /// Moves the entry of `old` to `new`, keeping its name, pin and times. An
    /// entry already at `new` is merged into it (the later opening wins).
    pub fn relocate(&mut self, old: &Path, new: &Path) -> bool {
        let Some(i) = self.index(old) else {
            return false;
        };
        let new = normalize(new);
        if path_key(old) == path_key(&new) {
            self.entries[i].path = new;
            return true;
        }
        let mut entry = self.entries.remove(i);
        if let Some(j) = self.index(&new) {
            let other = self.entries.remove(j);
            entry.last_opened_at = entry.last_opened_at.max(other.last_opened_at);
            entry.added_at = entry.added_at.min(other.added_at);
            entry.pinned |= other.pinned;
            entry.display_name = entry.display_name.or(other.display_name);
        }
        entry.path = new;
        // A different repository's root commit is read again.
        entry.root_commit = None;
        let at = i.min(self.entries.len());
        self.entries.insert(at, entry);
        true
    }

    /// Writes the file (atomically: a temporary file, then a rename).
    pub fn save(&self) -> Result<(), ConfigError> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        let write_err = |source| ConfigError::Write {
            path: path.clone(),
            source,
        };
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).map_err(write_err)?;
        }
        let tmp = path.with_extension("toml.tmp");
        fs::write(&tmp, self.to_toml()).map_err(write_err)?;
        fs::rename(&tmp, path).map_err(write_err)
    }

    fn to_toml(&self) -> String {
        let mut table = Table::new();
        table.insert(
            "repo".into(),
            Value::Array(self.entries.iter().map(RepoEntry::to_value).collect()),
        );
        for (key, value) in &self.extra {
            table.entry(key.clone()).or_insert_with(|| value.clone());
        }
        table.to_string()
    }

    fn import(&mut self, known: &[PathBuf], now: i64) {
        // Most recent first: older entries get earlier times.
        for (age, path) in (0i64..).zip(known) {
            if self.add(path, now) {
                self.touch(path, now - age);
            }
        }
    }

    fn index(&self, path: &Path) -> Option<usize> {
        let key = path_key(&normalize(path));
        self.entries.iter().position(|e| path_key(&e.path) == key)
    }
}

fn parse(text: &str) -> Result<(Vec<RepoEntry>, Table), ConfigError> {
    let mut table: Table = text
        .parse()
        .map_err(|err: toml::de::Error| ConfigError::Syntax(err.to_string()))?;
    let entries = match table.remove("repo") {
        None => Vec::new(),
        Some(Value::Array(items)) => items.into_iter().filter_map(RepoEntry::parse).collect(),
        Some(_) => {
            return Err(ConfigError::Invalid {
                key: "repo",
                expected: "an array of tables",
            })
        }
    };
    Ok((entries, table))
}

/// The folder a repository is listed under: the main worktree of a linked
/// worktree, the repository itself otherwise (a bare repository's own
/// folder, a submodule's worktree).
pub fn library_root(toplevel: &Path, paths: &RepoPaths) -> PathBuf {
    if paths.bare {
        return paths.common_dir.clone();
    }
    if paths.git_dir == paths.common_dir {
        return toplevel.to_path_buf();
    }
    // A linked worktree: the common dir is `<main>/.git`, or a bare
    // repository that the worktree belongs to.
    if paths.common_dir.file_name().is_some_and(|n| n == ".git") {
        if let Some(main) = paths.common_dir.parent() {
            return main.to_path_buf();
        }
    }
    paths.common_dir.clone()
}

/// What Home shows of a repository without a tab (PLAN §4 Home): read with
/// [`read_summary`], never fetched or watched.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RepoSummary {
    /// The folder is gone.
    pub missing: bool,
    /// Why it could not be read (not a repository any more, for example).
    pub error: Option<GitError>,
    pub branch: Option<String>,
    pub detached: bool,
    pub changes: usize,
    pub conflicts: bool,
    pub upstream: bool,
    pub ahead: u32,
    pub behind: u32,
    pub root_commit: Option<String>,
}

/// Reads the summary of `path`; `root` also reads its root commit.
pub fn read_summary(
    backend: &dyn GitBackend,
    path: &Path,
    root: bool,
    cancel: &CancelToken,
) -> RepoSummary {
    if !path.is_dir() {
        return RepoSummary {
            missing: true,
            ..RepoSummary::default()
        };
    }
    let status = match backend.status(path, cancel) {
        Ok(status) => status,
        Err(error) => {
            return RepoSummary {
                error: Some(error),
                ..RepoSummary::default()
            }
        }
    };
    let (branch, detached) = match &status.head {
        Head::Branch(name) => (Some(name.clone()), false),
        Head::Detached => (None, true),
        Head::Unknown => (None, false),
    };
    RepoSummary {
        missing: false,
        error: None,
        branch,
        detached,
        changes: status
            .changes
            .iter()
            .filter(|c| !matches!(c.state, FileState::Ignored))
            .count(),
        conflicts: status.has_conflicts(),
        upstream: status.upstream.is_some(),
        ahead: status.ahead,
        behind: status.behind,
        root_commit: if root {
            backend.root_commit(path, cancel).ok().flatten()
        } else {
            None
        },
    }
}

/// Where a folder chosen for Add existing folder or Change location leads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocationCheck {
    /// The folder as chosen.
    pub path: PathBuf,
    /// The repository it belongs to ([`library_root`]); `None` when it is
    /// not in a repository.
    pub root: Option<PathBuf>,
    /// Whether the repository has the expected root commit; `None` when
    /// there was nothing to compare.
    pub same_root: Option<bool>,
}

/// Resolves `path` (see [`LocationCheck`]), comparing root commits with
/// `expected` when given.
pub fn check_location(
    backend: &dyn GitBackend,
    path: &Path,
    expected: Option<&str>,
    cancel: &CancelToken,
) -> Result<LocationCheck, GitError> {
    let mut check = LocationCheck {
        path: path.to_path_buf(),
        root: None,
        same_root: None,
    };
    let paths = match backend.repo_paths(path, cancel) {
        Ok(paths) => paths,
        Err(err) if err.kind == GitErrorKind::NotARepository => return Ok(check),
        Err(err) => return Err(err),
    };
    let toplevel = if paths.bare {
        path.to_path_buf()
    } else {
        backend.toplevel(path, cancel)?
    };
    let root = normalize(&library_root(&toplevel, &paths));
    if let Some(expected) = expected {
        check.same_root = backend
            .root_commit(&root, cancel)?
            .map(|found| found == expected);
    }
    check.root = Some(root);
    Ok(check)
}

/// How paths compare: forward slashes, no trailing slash, and on Windows
/// in any case. No file system access (stored paths are normalised already).
pub fn path_key(path: &Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    let trimmed = text.trim_end_matches('/');
    let key = if trimmed.is_empty() {
        text.as_str()
    } else {
        trimmed
    };
    if cfg!(windows) {
        key.to_lowercase()
    } else {
        key.to_owned()
    }
}

/// Unix seconds now.
pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

fn folder_name(path: &Path) -> String {
    path.file_name().map_or_else(
        || path.display().to_string(),
        |n| n.to_string_lossy().into_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(label: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gitbello librärY {label} {}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn round_trips_entries_and_unknown_keys() {
        let dir = temp("round trip");
        let file = dir.join("data").join(FILE_NAME);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(
            &file,
            "future = 3\n\n[[repo]]\npath = \"/r/a\"\nname = \"Alpha\"\npinned = true\nadded = 5\nopened = 9\ncolour = \"red\"\n\n[[repo]]\npath = \"/r/b\"\nadded = 6\n",
        )
        .unwrap();
        let (mut library, error) = RepoLibrary::load(Some(file.clone()), &[]);
        assert!(error.is_none());
        assert_eq!(library.entries().len(), 2);
        let a = library.get(Path::new("/r/a/")).unwrap();
        assert_eq!(a.name(), "Alpha");
        assert!(a.pinned);
        assert_eq!((a.added_at, a.last_opened_at), (5, Some(9)));
        assert_eq!(library.get(Path::new("/r/b")).unwrap().name(), "b");

        library.touch(Path::new("/r/c"), 20);
        library.save().unwrap();
        assert!(!file.with_extension("toml.tmp").exists());
        let text = fs::read_to_string(&file).unwrap();
        assert!(text.contains("future = 3"), "{text}");
        assert!(text.contains("colour = \"red\""), "{text}");
        let (loaded, _) = RepoLibrary::load(Some(file), &[]);
        assert_eq!(loaded.entries(), library.entries());
        let recent: Vec<String> = loaded.recent(5).iter().map(|e| e.name()).collect();
        assert_eq!(recent, ["c", "Alpha"]);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn imports_the_old_recent_list_once() {
        let dir = temp("import");
        let file = dir.join(FILE_NAME);
        let known = [PathBuf::from("/r/new"), PathBuf::from("/r/old")];
        let (library, error) = RepoLibrary::load(Some(file.clone()), &known);
        assert!(error.is_none());
        let recent: Vec<String> = library.recent(5).iter().map(|e| e.name()).collect();
        assert_eq!(recent, ["new", "old"]);
        assert!(file.exists());

        // Later loads read the file; the old list is not imported again.
        let mut library = library;
        library.remove(Path::new("/r/old"));
        library.save().unwrap();
        let (loaded, _) = RepoLibrary::load(Some(file), &known);
        assert_eq!(loaded.entries().len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn keeps_a_broken_file_aside() {
        let dir = temp("broken");
        let file = dir.join(FILE_NAME);
        fs::write(&file, "not [toml").unwrap();
        let (library, error) = RepoLibrary::load(Some(file.clone()), &[PathBuf::from("/x")]);
        assert!(matches!(error, Some(ConfigError::Syntax(_))));
        assert!(library.entries().is_empty());
        assert!(file.with_extension("toml.broken").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn removes_with_undo_renames_pins_and_relocates() {
        let mut library = RepoLibrary::default();
        for (i, name) in ["a", "b", "c"].iter().enumerate() {
            library.touch(&Path::new("/r").join(name), i64::try_from(i).unwrap());
        }
        assert!(library.remove(Path::new("/r/b")));
        assert!(!library.remove(Path::new("/r/b")));
        assert_eq!(library.undo_remove(), Some(PathBuf::from("/r/b")));
        let names: Vec<String> = library.entries().iter().map(RepoEntry::name).collect();
        assert_eq!(names, ["a", "b", "c"]);
        assert!(!library.can_undo_remove());

        library.rename(Path::new("/r/a"), "  Alpha ");
        assert_eq!(library.get(Path::new("/r/a")).unwrap().name(), "Alpha");
        library.rename(Path::new("/r/a"), "a");
        assert_eq!(library.get(Path::new("/r/a")).unwrap().display_name, None);
        library.set_pinned(Path::new("/r/c"), true);
        library.set_root_commit(Path::new("/r/c"), "abc");

        // Moved: name, pin and times follow; the root commit is read again.
        assert!(library.relocate(Path::new("/r/c"), Path::new("/moved/c")));
        let moved = library.get(Path::new("/moved/c")).unwrap();
        assert!(moved.pinned);
        assert_eq!(moved.last_opened_at, Some(2));
        assert_eq!(moved.root_commit, None);
        assert!(!library.contains(Path::new("/r/c")));

        // Onto an existing entry: one entry remains.
        assert!(library.relocate(Path::new("/r/a"), Path::new("/r/b")));
        assert_eq!(library.entries().len(), 2);
        assert_eq!(
            library.get(Path::new("/r/b")).unwrap().last_opened_at,
            Some(1)
        );
    }

    #[test]
    fn lists_linked_worktrees_under_their_repository() {
        let plain = RepoPaths {
            git_dir: PathBuf::from("/r/a/.git"),
            common_dir: PathBuf::from("/r/a/.git"),
            bare: false,
        };
        assert_eq!(library_root(Path::new("/r/a"), &plain), Path::new("/r/a"));
        let linked = RepoPaths {
            git_dir: PathBuf::from("/r/a/.git/worktrees/task"),
            common_dir: PathBuf::from("/r/a/.git"),
            bare: false,
        };
        assert_eq!(
            library_root(Path::new("/r/a/.worktrees/task"), &linked),
            Path::new("/r/a")
        );
        let of_bare = RepoPaths {
            git_dir: PathBuf::from("/r/b.git/worktrees/main"),
            common_dir: PathBuf::from("/r/b.git"),
            bare: false,
        };
        assert_eq!(
            library_root(Path::new("/r/main"), &of_bare),
            Path::new("/r/b.git")
        );
        let submodule = RepoPaths {
            git_dir: PathBuf::from("/r/a/.git/modules/sub"),
            common_dir: PathBuf::from("/r/a/.git/modules/sub"),
            bare: false,
        };
        assert_eq!(
            library_root(Path::new("/r/a/sub"), &submodule),
            Path::new("/r/a/sub")
        );
    }
}
