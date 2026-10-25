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
}

impl UiState {
    /// Loads `path`; a missing or unreadable file gives an empty state (it is
    /// only a convenience, so a broken file is replaced on the next save).
    pub fn load(path: Option<PathBuf>) -> Self {
        let repos = path
            .as_deref()
            .and_then(|p| fs::read_to_string(p).ok())
            .and_then(|text| text.parse::<Table>().ok())
            .map(|table| {
                table
                    .into_iter()
                    .filter_map(|(repo, values)| {
                        let Value::Table(values) = values else {
                            return None;
                        };
                        let values = values
                            .into_iter()
                            .filter_map(|(k, v)| v.as_integer().map(|n| (k, n)))
                            .collect();
                        Some((repo, values))
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self { path, repos }
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
        let table: Table = self
            .repos
            .iter()
            .map(|(repo, values)| {
                let values: Table = values
                    .iter()
                    .map(|(k, v)| (k.clone(), Value::Integer(*v)))
                    .collect();
                (repo.clone(), Value::Table(values))
            })
            .collect();
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
    fn keeps_state_in_memory_without_a_file() {
        let mut state = UiState::load(None);
        state.set(Path::new("/nowhere/repo"), "w", 1).unwrap();
        assert_eq!(state.get(Path::new("/nowhere/repo")).get("w"), Some(&1));
    }
}
