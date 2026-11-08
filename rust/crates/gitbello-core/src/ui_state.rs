//! Per-repository UI state, such as panel widths (PLAN §3.8): a TOML file in
//! the app's data dir with one table per repository, keyed by its normalised
//! path. Nothing is ever written into the repository.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use toml::{Table, Value};

use crate::config::ConfigError;
use crate::runtime::normalize;

/// File name inside the data dir.
pub const FILE_NAME: &str = "repos.toml";

#[derive(Debug, Default)]
pub struct UiState {
    /// `None` keeps the state in memory only.
    path: Option<PathBuf>,
    repos: BTreeMap<String, BTreeMap<String, i64>>,
    /// Lists of strings per repository (Compare's recent comparisons).
    lists: BTreeMap<String, BTreeMap<String, Vec<String>>>,
}

impl UiState {
    /// Loads `path`; a missing or unreadable file gives an empty state (it is
    /// only a convenience, so a broken file is replaced on the next save).
    pub fn load(path: Option<PathBuf>) -> Self {
        let table = path
            .as_deref()
            .and_then(|p| fs::read_to_string(p).ok())
            .and_then(|text| text.parse::<Table>().ok())
            .unwrap_or_default();
        let mut repos = BTreeMap::new();
        let mut lists = BTreeMap::new();
        for (repo, values) in table {
            let Value::Table(values) = values else {
                continue;
            };
            let mut numbers = BTreeMap::new();
            let mut strings = BTreeMap::new();
            for (name, value) in values {
                match value {
                    Value::Integer(n) => {
                        numbers.insert(name, n);
                    }
                    Value::Array(items) => {
                        let items: Vec<String> = items
                            .into_iter()
                            .filter_map(|v| v.as_str().map(str::to_owned))
                            .collect();
                        strings.insert(name, items);
                    }
                    _ => {}
                }
            }
            if !numbers.is_empty() {
                repos.insert(repo.clone(), numbers);
            }
            if !strings.is_empty() {
                lists.insert(repo, strings);
            }
        }
        Self { path, repos, lists }
    }

    /// The list `name` saved for `repo` (empty when none).
    pub fn list(&self, repo: &Path, name: &str) -> Vec<String> {
        self.lists
            .get(&key(repo))
            .and_then(|lists| lists.get(name))
            .cloned()
            .unwrap_or_default()
    }

    /// Sets the list `name` for `repo` and saves the file.
    pub fn set_list(
        &mut self,
        repo: &Path,
        name: &str,
        items: Vec<String>,
    ) -> Result<(), ConfigError> {
        self.lists
            .entry(key(repo))
            .or_default()
            .insert(name.to_owned(), items);
        self.save()
    }

    /// The values saved for `repo` (empty when none).
    pub fn get(&self, repo: &Path) -> BTreeMap<String, i64> {
        self.repos.get(&key(repo)).cloned().unwrap_or_default()
    }

    /// Sets one value for `repo` and saves the file (atomically: a temporary
    /// file, then a rename).
    pub fn set(&mut self, repo: &Path, name: &str, value: i64) -> Result<(), ConfigError> {
        self.repos
            .entry(key(repo))
            .or_default()
            .insert(name.to_owned(), value);
        self.save()
    }

    /// Moves the values of `old` to `new` (a repository moved on disk) and
    /// saves; values already saved for `new` win.
    pub fn rename(&mut self, old: &Path, new: &Path) -> Result<(), ConfigError> {
        let values = self.repos.remove(&key(old));
        let lists = self.lists.remove(&key(old));
        if values.is_none() && lists.is_none() {
            return Ok(());
        }
        let target = self.repos.entry(key(new)).or_default();
        for (name, value) in values.unwrap_or_default() {
            target.entry(name).or_insert(value);
        }
        let target = self.lists.entry(key(new)).or_default();
        for (name, items) in lists.unwrap_or_default() {
            target.entry(name).or_insert(items);
        }
        self.save()
    }

    fn save(&self) -> Result<(), ConfigError> {
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
        let mut table = Table::new();
        for (repo, values) in &self.repos {
            let values: Table = values
                .iter()
                .map(|(k, v)| (k.clone(), Value::Integer(*v)))
                .collect();
            table.insert(repo.clone(), Value::Table(values));
        }
        for (repo, lists) in &self.lists {
            let entry = table
                .entry(repo.clone())
                .or_insert_with(|| Value::Table(Table::new()));
            if let Value::Table(values) = entry {
                for (name, items) in lists {
                    let items = items.iter().cloned().map(Value::String).collect();
                    values.insert(name.clone(), Value::Array(items));
                }
            }
        }
        let tmp = path.with_extension("toml.tmp");
        fs::write(&tmp, table.to_string()).map_err(write_err)?;
        fs::rename(&tmp, path).map_err(write_err)
    }
}

/// The repository's normalised path with forward slashes, so `C:\a` and
/// `C:/a/` share one entry.
fn key(repo: &Path) -> String {
    let text = normalize(repo).to_string_lossy().replace('\\', "/");
    let trimmed = text.trim_end_matches('/');
    if trimmed.is_empty() {
        text
    } else {
        trimmed.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saves_and_loads_values_per_repository() {
        let dir = std::env::temp_dir().join(format!("gitbello ui stäte {}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let repo = dir.join("my repö");
        fs::create_dir_all(&repo).unwrap();
        let file = dir.join("data").join(FILE_NAME);

        let mut state = UiState::load(Some(file.clone()));
        assert!(state.get(&repo).is_empty());
        state.set(&repo, "history_width", 420).unwrap();
        state.set(&repo, "changes_width", 360).unwrap();
        state.set(&repo, "history_width", 440).unwrap();
        assert!(!file.with_extension("toml.tmp").exists());

        let loaded = UiState::load(Some(file.clone()));
        let values = loaded.get(&repo);
        assert_eq!(values.get("history_width"), Some(&440));
        assert_eq!(values.get("changes_width"), Some(&360));
        // The same folder written differently finds the same entry.
        let slashed = PathBuf::from(format!("{}/", repo.display()));
        assert_eq!(loaded.get(&slashed), values);
        assert!(loaded.get(&dir).is_empty());

        fs::write(&file, "not [toml").unwrap();
        assert!(UiState::load(Some(file)).get(&repo).is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn moves_values_with_a_relocated_repository() {
        let mut state = UiState::load(None);
        state.set(Path::new("/old/repo"), "w", 1).unwrap();
        state.set(Path::new("/old/repo"), "h", 2).unwrap();
        state.set(Path::new("/new/repo"), "h", 3).unwrap();
        state
            .rename(Path::new("/old/repo"), Path::new("/new/repo"))
            .unwrap();
        assert!(state.get(Path::new("/old/repo")).is_empty());
        let moved = state.get(Path::new("/new/repo"));
        assert_eq!((moved.get("w"), moved.get("h")), (Some(&1), Some(&3)));
    }

    #[test]
    fn saves_lists_beside_values() {
        let dir = std::env::temp_dir().join(format!("gitbello ui lists {}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let file = dir.join(FILE_NAME);
        let repo = Path::new("/some/repö");
        let mut state = UiState::load(Some(file.clone()));
        state.set(repo, "w", 3).unwrap();
        let items = vec![
            "main\u{1f}feature x\u{1f}".to_owned(),
            "a\u{1f}\u{1f}exact".to_owned(),
        ];
        state
            .set_list(repo, "compare_recent", items.clone())
            .unwrap();
        let loaded = UiState::load(Some(file));
        assert_eq!(loaded.list(repo, "compare_recent"), items);
        assert_eq!(loaded.get(repo).get("w"), Some(&3));
        assert!(loaded.list(repo, "other").is_empty());
        let mut moved = loaded;
        moved.rename(repo, Path::new("/new/place")).unwrap();
        assert_eq!(moved.list(Path::new("/new/place"), "compare_recent"), items);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn keeps_state_in_memory_without_a_file() {
        let mut state = UiState::load(None);
        state.set(Path::new("/nowhere/repo"), "w", 1).unwrap();
        assert_eq!(state.get(Path::new("/nowhere/repo")).get("w"), Some(&1));
    }
}
