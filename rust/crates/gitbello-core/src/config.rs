//! User configuration (PLAN §3.8), stored as TOML in [`crate::paths::config_file`].
//!
//! Only the fields in use are modelled; keys this version does not know are
//! kept and written back unchanged, so older and newer versions can share a file.

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use thiserror::Error;
use toml::{Table, Value};

/// PLAN O3 suggestion; still open for confirmation.
pub const DEFAULT_WORKTREE_TEMPLATE: &str = "{repo_parent}/{repo_name}.worktrees/{branch_slug}";
pub const DEFAULT_AUTO_FETCH_MINUTES: u32 = 10;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("cannot read {path}: {source}")]
    Read {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("cannot write {path}: {source}")]
    Write {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("invalid TOML: {0}")]
    Syntax(String),
    #[error("`{key}` must be {expected}")]
    Invalid {
        key: &'static str,
        expected: &'static str,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    /// Overrides the git executable found on `PATH`.
    pub git_path: Option<PathBuf>,
    /// Repositories opened before, most recent first.
    pub known_repos: Vec<PathBuf>,
    /// Tabs to restore on launch, in order.
    pub open_tabs: Vec<PathBuf>,
    pub active_tab: Option<usize>,
    pub worktree_template: String,
    /// 0 disables auto-fetch.
    pub auto_fetch_minutes: u32,
    pub theme: ThemeChoice,
    /// Show diffs side by side instead of unified.
    pub diff_side_by_side: bool,
    /// Action id to shortcut text (`"Ctrl+Shift+P"`); overrides the defaults.
    pub keybindings: BTreeMap<String, String>,
    /// Keys this version does not model, kept as read.
    extra: Table,
}

/// Theme override; `System` follows the OS dark/light setting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ThemeChoice {
    #[default]
    System,
    Light,
    Dark,
}

impl ThemeChoice {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Light => "light",
            Self::Dark => "dark",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "system" => Some(Self::System),
            "light" => Some(Self::Light),
            "dark" => Some(Self::Dark),
            _ => None,
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            git_path: None,
            known_repos: Vec::new(),
            open_tabs: Vec::new(),
            active_tab: None,
            worktree_template: DEFAULT_WORKTREE_TEMPLATE.to_owned(),
            auto_fetch_minutes: DEFAULT_AUTO_FETCH_MINUTES,
            theme: ThemeChoice::System,
            diff_side_by_side: false,
            keybindings: BTreeMap::new(),
            extra: Table::new(),
        }
    }
}

const KEYS: &[&str] = &[
    "git_path",
    "known_repos",
    "open_tabs",
    "active_tab",
    "worktree_template",
    "auto_fetch_minutes",
    "theme",
    "diff_side_by_side",
    "keybindings",
];

impl Config {
    /// Loads `path`; a missing file gives the defaults.
    pub fn load(path: &Path) -> Result<Self, ConfigError> {
        match fs::read_to_string(path) {
            Ok(text) => Self::parse(&text),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(Self::default()),
            Err(source) => Err(ConfigError::Read {
                path: path.to_path_buf(),
                source,
            }),
        }
    }

    /// Writes atomically: a temporary file next to `path`, then a rename.
    pub fn save(&self, path: &Path) -> Result<(), ConfigError> {
        let write_err = |source| ConfigError::Write {
            path: path.to_path_buf(),
            source,
        };
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).map_err(write_err)?;
        }
        let tmp = path.with_extension("toml.tmp");
        fs::write(&tmp, self.to_toml()).map_err(write_err)?;
        fs::rename(&tmp, path).map_err(write_err)
    }

    pub fn parse(text: &str) -> Result<Self, ConfigError> {
        let mut table: Table = text
            .parse()
            .map_err(|err: toml::de::Error| ConfigError::Syntax(err.to_string()))?;
        let defaults = Self::default();
        let config = Self {
            git_path: take_string(&mut table, "git_path")?.map(PathBuf::from),
            known_repos: take_paths(&mut table, "known_repos")?,
            open_tabs: take_paths(&mut table, "open_tabs")?,
            active_tab: take_index(&mut table, "active_tab")?,
            worktree_template: take_string(&mut table, "worktree_template")?
                .unwrap_or(defaults.worktree_template),
            auto_fetch_minutes: take_u32(&mut table, "auto_fetch_minutes")?
                .unwrap_or(defaults.auto_fetch_minutes),
            theme: match take_string(&mut table, "theme")? {
                None => ThemeChoice::System,
                Some(text) => ThemeChoice::parse(&text).ok_or(ConfigError::Invalid {
                    key: "theme",
                    expected: "\"system\", \"light\" or \"dark\"",
                })?,
            },
            diff_side_by_side: take_bool(&mut table, "diff_side_by_side")?.unwrap_or(false),
            keybindings: take_string_map(&mut table, "keybindings")?,
            extra: table,
        };
        Ok(config)
    }

    pub fn to_toml(&self) -> String {
        let mut table = Table::new();
        if let Some(git) = &self.git_path {
            table.insert("git_path".into(), path_value(git));
        }
        table.insert(
            "worktree_template".into(),
            Value::String(self.worktree_template.clone()),
        );
        table.insert(
            "auto_fetch_minutes".into(),
            Value::Integer(i64::from(self.auto_fetch_minutes)),
        );
        table.insert("known_repos".into(), paths_value(&self.known_repos));
        table.insert("open_tabs".into(), paths_value(&self.open_tabs));
        if let Some(active) = self.active_tab {
            table.insert(
                "active_tab".into(),
                Value::Integer(i64::try_from(active).unwrap_or(i64::MAX)),
            );
        }
        table.insert("theme".into(), Value::String(self.theme.as_str().into()));
        table.insert(
            "diff_side_by_side".into(),
            Value::Boolean(self.diff_side_by_side),
        );
        if !self.keybindings.is_empty() {
            let bindings: Table = self
                .keybindings
                .iter()
                .map(|(action, shortcut)| (action.clone(), Value::String(shortcut.clone())))
                .collect();
            table.insert("keybindings".into(), Value::Table(bindings));
        }
        for (key, value) in &self.extra {
            if !KEYS.contains(&key.as_str()) {
                table.insert(key.clone(), value.clone());
            }
        }
        table.to_string()
    }

    /// Moves `repo` to the front of the known list (capped at `max`).
    pub fn remember_repo(&mut self, repo: &Path, max: usize) {
        self.known_repos.retain(|known| known != repo);
        self.known_repos.insert(0, repo.to_path_buf());
        self.known_repos.truncate(max);
    }
}

fn path_value(path: &Path) -> Value {
    Value::String(path.to_string_lossy().into_owned())
}

fn paths_value(paths: &[PathBuf]) -> Value {
    Value::Array(paths.iter().map(|p| path_value(p)).collect())
}

fn take_string_map(
    table: &mut Table,
    key: &'static str,
) -> Result<BTreeMap<String, String>, ConfigError> {
    let invalid = || ConfigError::Invalid {
        key,
        expected: "a table of strings",
    };
    match table.remove(key) {
        None => Ok(BTreeMap::new()),
        Some(Value::Table(entries)) => entries
            .into_iter()
            .map(|(k, v)| match v {
                Value::String(s) => Ok((k, s)),
                _ => Err(invalid()),
            })
            .collect(),
        Some(_) => Err(invalid()),
    }
}

fn take_string(table: &mut Table, key: &'static str) -> Result<Option<String>, ConfigError> {
    match table.remove(key) {
        None => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        Some(_) => Err(ConfigError::Invalid {
            key,
            expected: "a string",
        }),
    }
}

fn take_paths(table: &mut Table, key: &'static str) -> Result<Vec<PathBuf>, ConfigError> {
    let invalid = ConfigError::Invalid {
        key,
        expected: "an array of strings",
    };
    match table.remove(key) {
        None => Ok(Vec::new()),
        Some(Value::Array(items)) => items
            .into_iter()
            .map(|item| match item {
                Value::String(s) => Ok(PathBuf::from(s)),
                _ => Err(ConfigError::Invalid {
                    key,
                    expected: "an array of strings",
                }),
            })
            .collect(),
        Some(_) => Err(invalid),
    }
}

fn take_bool(table: &mut Table, key: &'static str) -> Result<Option<bool>, ConfigError> {
    match table.remove(key) {
        None => Ok(None),
        Some(Value::Boolean(b)) => Ok(Some(b)),
        Some(_) => Err(ConfigError::Invalid {
            key,
            expected: "true or false",
        }),
    }
}

fn take_u32(table: &mut Table, key: &'static str) -> Result<Option<u32>, ConfigError> {
    match table.remove(key) {
        None => Ok(None),
        Some(Value::Integer(n)) => u32::try_from(n)
            .map(Some)
            .map_err(|_| ConfigError::Invalid {
                key,
                expected: "a non-negative integer",
            }),
        Some(_) => Err(ConfigError::Invalid {
            key,
            expected: "a non-negative integer",
        }),
    }
}

fn take_index(table: &mut Table, key: &'static str) -> Result<Option<usize>, ConfigError> {
    Ok(take_u32(table, key)?.map(|n| n as usize))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_keys_use_defaults() {
        let config = Config::parse("").unwrap();
        assert_eq!(config, Config::default());
        assert_eq!(config.auto_fetch_minutes, 10);
        assert_eq!(config.worktree_template, DEFAULT_WORKTREE_TEMPLATE);
    }

    #[test]
    fn round_trips_every_field_with_unicode_paths() {
        let config = Config {
            git_path: Some(PathBuf::from("C:/Program Files/Git/bin/git.exe")),
            known_repos: vec![
                PathBuf::from("/home/ädä/my repo"),
                PathBuf::from("D:\\wörk\\x"),
            ],
            open_tabs: vec![PathBuf::from("/home/ädä/my repo")],
            active_tab: Some(0),
            worktree_template: "{repo_parent}/wt/{branch_slug}".into(),
            auto_fetch_minutes: 0,
            theme: ThemeChoice::Dark,
            diff_side_by_side: true,
            keybindings: [("palette".to_owned(), "Ctrl+Shift+K".to_owned())].into(),
            extra: Table::new(),
        };
        assert_eq!(Config::parse(&config.to_toml()).unwrap(), config);
    }

    #[test]
    fn keeps_unknown_keys_and_tables() {
        let text =
            "auto_fetch_minutes = 5\nfuture_flag = true\n\n[keybindings]\npalette = \"ctrl+k\"\n";
        let mut config = Config::parse(text).unwrap();
        config.auto_fetch_minutes = 7;
        let saved = config.to_toml();
        let reparsed: Table = saved.parse().unwrap();
        assert_eq!(reparsed["future_flag"], Value::Boolean(true));
        assert_eq!(
            reparsed["keybindings"]["palette"],
            Value::String("ctrl+k".into())
        );
        assert_eq!(reparsed["auto_fetch_minutes"], Value::Integer(7));
    }

    #[test]
    fn reports_invalid_values_by_key() {
        let err = Config::parse("auto_fetch_minutes = \"often\"").unwrap_err();
        assert!(matches!(
            err,
            ConfigError::Invalid {
                key: "auto_fetch_minutes",
                ..
            }
        ));
        let err = Config::parse("known_repos = [1, 2]").unwrap_err();
        assert!(matches!(
            err,
            ConfigError::Invalid {
                key: "known_repos",
                ..
            }
        ));
        assert!(matches!(
            Config::parse("auto_fetch_minutes = -1"),
            Err(ConfigError::Invalid { .. })
        ));
        assert!(matches!(
            Config::parse("this is not toml"),
            Err(ConfigError::Syntax(_))
        ));
        assert!(matches!(
            Config::parse("theme = \"purple\""),
            Err(ConfigError::Invalid { key: "theme", .. })
        ));
        assert!(matches!(
            Config::parse("[keybindings]\npalette = 3"),
            Err(ConfigError::Invalid {
                key: "keybindings",
                ..
            })
        ));
    }

    #[test]
    fn saves_atomically_and_loads_back() {
        let dir = std::env::temp_dir().join(format!("gitbello cönfig {}", std::process::id()));
        let path = dir.join("nested").join("config.toml");
        let _ = fs::remove_dir_all(&dir);
        assert_eq!(Config::load(&path).unwrap(), Config::default());

        let mut config = Config::default();
        config.remember_repo(Path::new("/a"), 2);
        config.remember_repo(Path::new("/b"), 2);
        config.remember_repo(Path::new("/a"), 2);
        config.remember_repo(Path::new("/c"), 2);
        assert_eq!(
            config.known_repos,
            [PathBuf::from("/c"), PathBuf::from("/a")]
        );
        config.save(&path).unwrap();
        assert!(!path.with_extension("toml.tmp").exists());
        assert_eq!(Config::load(&path).unwrap(), config);
        fs::remove_dir_all(&dir).unwrap();
    }
}
