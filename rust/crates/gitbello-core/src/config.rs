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

use crate::diff::viewer::{DiffMode, Viewer};
use crate::ops::PullMode;

/// PLAN O3: worktrees go in the repository's locally ignored `.worktrees` folder.
pub const DEFAULT_WORKTREE_TEMPLATE: &str = ".worktrees/{branch_slug}";
const LEGACY_DEFAULT_WORKTREE_TEMPLATE: &str = "{repo_parent}/{repo_name}.worktrees/{branch_slug}";
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
    /// Repositories opened before, most recent first: no longer written, only
    /// imported once into the repository library (`crate::library`).
    pub known_repos: Vec<PathBuf>,
    /// Tabs to restore on launch, in order.
    pub open_tabs: Vec<PathBuf>,
    pub active_tab: Option<usize>,
    pub worktree_template: String,
    /// Put in front of new branch names (`caleb/`); may be empty.
    pub branch_prefix: String,
    /// 0 disables auto-fetch.
    pub auto_fetch_minutes: u32,
    /// How `pull` integrates the upstream.
    pub pull_mode: PullMode,
    /// Command for "Open terminal here" (`{path}` as above); `None` uses the
    /// platform's terminal.
    pub terminal_command: Option<String>,
    /// Where Clone puts repositories (Settings); `None` uses
    /// `last_clone_folder`, then the documents folder.
    pub clone_folder: Option<PathBuf>,
    /// The parent folder of the last clone.
    pub last_clone_folder: Option<PathBuf>,
    pub theme: ThemeChoice,
    /// UI language; `System` follows the OS locale.
    pub language: LanguageChoice,
    /// Accent colour as `#rrggbb` (see [`parse_accent`]); `None` uses the
    /// app's default.
    pub accent: Option<String>,
    /// Colours of added and removed lines as `#rrggbb` (see
    /// [`parse_accent`]), the same in both themes; `None` uses each theme's.
    pub added_color: Option<String>,
    pub removed_color: Option<String>,
    /// How text diffs show (`unified` or `split`); `diff_side_by_side = true`
    /// from older versions reads as `split`.
    pub diff_text_mode: DiffMode,
    /// How image diffs show (`split`, `onion`, `swipe` or `difference`).
    pub diff_image_mode: DiffMode,
    /// Show the minimap beside diffs (else only its strip of change marks).
    pub diff_minimap: bool,
    /// History rows on one line (no author line), as before M7.10.
    pub history_compact: bool,
    /// Draw the commit graph beside History's rows.
    pub history_graph: bool,
    /// Blame skips changes that only touched whitespace (`git blame -w`).
    pub blame_ignore_whitespace: bool,
    /// Blame follows lines moved within the file (`git blame -M`).
    pub blame_detect_moves: bool,
    /// Offer to ignore a folder such as `node_modules/` that fills Changes.
    pub ignore_hint: bool,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LanguageChoice {
    #[default]
    System,
    English,
    Italian,
}

impl LanguageChoice {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::English => "en",
            Self::Italian => "it",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "system" => Some(Self::System),
            "en" => Some(Self::English),
            "it" => Some(Self::Italian),
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
            branch_prefix: String::new(),
            auto_fetch_minutes: DEFAULT_AUTO_FETCH_MINUTES,
            pull_mode: PullMode::FastForwardOnly,
            terminal_command: None,
            clone_folder: None,
            last_clone_folder: None,
            theme: ThemeChoice::System,
            language: LanguageChoice::System,
            accent: None,
            added_color: None,
            removed_color: None,
            diff_text_mode: Viewer::Text.default_mode(),
            diff_image_mode: Viewer::Image.default_mode(),
            diff_minimap: true,
            history_compact: false,
            history_graph: true,
            blame_ignore_whitespace: false,
            blame_detect_moves: false,
            ignore_hint: true,
            keybindings: BTreeMap::new(),
            extra: Table::new(),
        }
    }
}

/// `#rrggbb` (lower case) from `#rrggbb`, `rrggbb`, `#rgb` or `rgb` in any
/// case, or `None` when `text` is not such a colour.
pub fn parse_accent(text: &str) -> Option<String> {
    let hex = text.trim();
    let hex = hex.strip_prefix('#').unwrap_or(hex);
    if !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let full: String = match hex.len() {
        6 => hex.to_ascii_lowercase(),
        3 => hex
            .chars()
            .flat_map(|c| [c, c])
            .collect::<String>()
            .to_ascii_lowercase(),
        _ => return None,
    };
    Some(format!("#{full}"))
}

/// Action ids renamed since a version that saved shortcuts for them.
const RENAMED_ACTIONS: &[(&str, &str)] = &[
    ("diff.toggle_side_by_side", "diff.cycle_mode"),
    ("changes.open_file", "diff.open_file"),
];

/// Moves shortcuts saved for renamed actions to their new ids (an existing
/// shortcut of the new id wins).
fn migrate_keybindings(mut bindings: BTreeMap<String, String>) -> BTreeMap<String, String> {
    for (old, new) in RENAMED_ACTIONS {
        if let Some(shortcut) = bindings.remove(*old) {
            bindings.entry((*new).to_owned()).or_insert(shortcut);
        }
    }
    bindings
}

/// An optional mode of `viewer` at `key` (see [`Viewer::all_modes`]).
fn take_mode(
    table: &mut Table,
    key: &'static str,
    viewer: Viewer,
) -> Result<Option<DiffMode>, ConfigError> {
    let expected = match viewer {
        Viewer::Image => "\"split\", \"onion\", \"swipe\" or \"difference\"",
        Viewer::Text | Viewer::None => "\"unified\" or \"split\"",
    };
    match take_string(table, key)? {
        None => Ok(None),
        Some(text) => DiffMode::parse(&text)
            .filter(|mode| viewer.all_modes().contains(mode))
            .map(Some)
            .ok_or(ConfigError::Invalid { key, expected }),
    }
}

/// An optional `#rrggbb` colour at `key` (see [`parse_accent`]).
fn take_color(table: &mut Table, key: &'static str) -> Result<Option<String>, ConfigError> {
    match take_string(table, key)? {
        None => Ok(None),
        Some(text) => parse_accent(&text).map(Some).ok_or(ConfigError::Invalid {
            key,
            expected: "a colour like \"#4c9cff\"",
        }),
    }
}

const KEYS: &[&str] = &[
    "git_path",
    "known_repos",
    "open_tabs",
    "active_tab",
    "worktree_template",
    "branch_prefix",
    "auto_fetch_minutes",
    "pull_mode",
    // Open in editor's command (until M7.8): read and dropped.
    "editor_command",
    "terminal_command",
    "clone_folder",
    "last_clone_folder",
    "theme",
    "language",
    "accent",
    "added_color",
    "removed_color",
    "diff_side_by_side",
    "diff_text_mode",
    "diff_image_mode",
    "diff_minimap",
    "history_compact",
    "history_graph",
    "blame_ignore_whitespace",
    "blame_detect_moves",
    "ignore_hint",
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
            worktree_template: match take_string(&mut table, "worktree_template")? {
                None => defaults.worktree_template,
                Some(template) if template == LEGACY_DEFAULT_WORKTREE_TEMPLATE => {
                    DEFAULT_WORKTREE_TEMPLATE.to_owned()
                }
                Some(template) => template,
            },
            branch_prefix: take_string(&mut table, "branch_prefix")?.unwrap_or_default(),
            auto_fetch_minutes: take_u32(&mut table, "auto_fetch_minutes")?
                .unwrap_or(defaults.auto_fetch_minutes),
            pull_mode: match take_string(&mut table, "pull_mode")? {
                None => defaults.pull_mode,
                Some(text) => PullMode::parse(&text).ok_or(ConfigError::Invalid {
                    key: "pull_mode",
                    expected: "\"ff-only\", \"merge\" or \"rebase\"",
                })?,
            },
            terminal_command: take_string(&mut table, "terminal_command")?
                .filter(|c| !c.trim().is_empty()),
            clone_folder: take_string(&mut table, "clone_folder")?
                .filter(|c| !c.trim().is_empty())
                .map(PathBuf::from),
            last_clone_folder: take_string(&mut table, "last_clone_folder")?
                .filter(|c| !c.trim().is_empty())
                .map(PathBuf::from),
            theme: match take_string(&mut table, "theme")? {
                None => ThemeChoice::System,
                Some(text) => ThemeChoice::parse(&text).ok_or(ConfigError::Invalid {
                    key: "theme",
                    expected: "\"system\", \"light\" or \"dark\"",
                })?,
            },
            language: match take_string(&mut table, "language")? {
                None => LanguageChoice::System,
                Some(text) => LanguageChoice::parse(&text).ok_or(ConfigError::Invalid {
                    key: "language",
                    expected: "\"system\", \"en\" or \"it\"",
                })?,
            },
            accent: take_color(&mut table, "accent")?,
            added_color: take_color(&mut table, "added_color")?,
            removed_color: take_color(&mut table, "removed_color")?,
            diff_text_mode: match take_mode(&mut table, "diff_text_mode", Viewer::Text)? {
                Some(mode) => mode,
                None if take_bool(&mut table, "diff_side_by_side")? == Some(true) => {
                    DiffMode::Split
                }
                None => Viewer::Text.default_mode(),
            },
            diff_image_mode: take_mode(&mut table, "diff_image_mode", Viewer::Image)?
                .unwrap_or(Viewer::Image.default_mode()),
            diff_minimap: take_bool(&mut table, "diff_minimap")?.unwrap_or(true),
            history_compact: take_bool(&mut table, "history_compact")?.unwrap_or(false),
            history_graph: take_bool(&mut table, "history_graph")?.unwrap_or(true),
            blame_ignore_whitespace: take_bool(&mut table, "blame_ignore_whitespace")?
                .unwrap_or(false),
            blame_detect_moves: take_bool(&mut table, "blame_detect_moves")?.unwrap_or(false),
            ignore_hint: take_bool(&mut table, "ignore_hint")?.unwrap_or(true),
            keybindings: migrate_keybindings(take_string_map(&mut table, "keybindings")?),
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
        if !self.branch_prefix.is_empty() {
            table.insert(
                "branch_prefix".into(),
                Value::String(self.branch_prefix.clone()),
            );
        }
        table.insert(
            "auto_fetch_minutes".into(),
            Value::Integer(i64::from(self.auto_fetch_minutes)),
        );
        table.insert(
            "pull_mode".into(),
            Value::String(self.pull_mode.as_str().into()),
        );
        if let Some(terminal) = &self.terminal_command {
            table.insert("terminal_command".into(), Value::String(terminal.clone()));
        }
        for (key, folder) in [
            ("clone_folder", &self.clone_folder),
            ("last_clone_folder", &self.last_clone_folder),
        ] {
            if let Some(folder) = folder {
                table.insert(key.into(), path_value(folder));
            }
        }
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
            "language".into(),
            Value::String(self.language.as_str().into()),
        );
        for (key, color) in [
            ("accent", &self.accent),
            ("added_color", &self.added_color),
            ("removed_color", &self.removed_color),
        ] {
            if let Some(color) = color {
                table.insert(key.into(), Value::String(color.clone()));
            }
        }
        for (key, mode) in [
            ("diff_text_mode", self.diff_text_mode),
            ("diff_image_mode", self.diff_image_mode),
        ] {
            table.insert(key.into(), Value::String(mode.id().into()));
        }
        table.insert("diff_minimap".into(), Value::Boolean(self.diff_minimap));
        table.insert(
            "history_compact".into(),
            Value::Boolean(self.history_compact),
        );
        table.insert("history_graph".into(), Value::Boolean(self.history_graph));
        table.insert(
            "blame_ignore_whitespace".into(),
            Value::Boolean(self.blame_ignore_whitespace),
        );
        table.insert(
            "blame_detect_moves".into(),
            Value::Boolean(self.blame_detect_moves),
        );
        table.insert("ignore_hint".into(), Value::Boolean(self.ignore_hint));
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
    fn migrates_only_the_old_default_worktree_template() {
        let old = format!("worktree_template = \"{LEGACY_DEFAULT_WORKTREE_TEMPLATE}\"");
        assert_eq!(
            Config::parse(&old).unwrap().worktree_template,
            DEFAULT_WORKTREE_TEMPLATE
        );
        let custom =
            Config::parse("worktree_template = \"{repo_parent}/wt/{branch_slug}\"").unwrap();
        assert_eq!(custom.worktree_template, "{repo_parent}/wt/{branch_slug}");
    }

    #[test]
    fn drops_the_old_editor_command() {
        let old = Config::parse("editor_command = \"subl -n {path}\"").unwrap();
        assert!(!old.to_toml().contains("editor_command"));
    }

    #[test]
    fn migrates_side_by_side_to_the_text_mode() {
        let old = Config::parse("diff_side_by_side = true").unwrap();
        assert_eq!(old.diff_text_mode, DiffMode::Split);
        assert!(!old.to_toml().contains("diff_side_by_side"));
        assert_eq!(
            Config::parse("diff_side_by_side = false")
                .unwrap()
                .diff_text_mode,
            DiffMode::Unified
        );
        // The new key wins over the old one.
        let both = Config::parse("diff_side_by_side = true\ndiff_text_mode = \"unified\"").unwrap();
        assert_eq!(both.diff_text_mode, DiffMode::Unified);
        assert_eq!(Config::default().diff_image_mode, DiffMode::Split);
        let keys =
            Config::parse("[keybindings]\n\"diff.toggle_side_by_side\" = \"Ctrl+Alt+S\"").unwrap();
        assert_eq!(
            keys.keybindings.get("diff.cycle_mode").map(String::as_str),
            Some("Ctrl+Alt+S")
        );
        assert!(!keys.keybindings.contains_key("diff.toggle_side_by_side"));
        for (text, key) in [
            ("diff_text_mode = \"onion\"", "diff_text_mode"),
            ("diff_image_mode = \"unified\"", "diff_image_mode"),
            ("diff_image_mode = \"single\"", "diff_image_mode"),
        ] {
            assert!(
                matches!(Config::parse(text), Err(ConfigError::Invalid { key: k, .. }) if k == key),
                "{text}"
            );
        }
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
            branch_prefix: "ädä/".into(),
            auto_fetch_minutes: 0,
            pull_mode: PullMode::Rebase,
            terminal_command: Some("wt -d \"{path}\"".into()),
            clone_folder: Some(PathBuf::from("D:\\cödé")),
            last_clone_folder: Some(PathBuf::from("/home/ädä/src")),
            theme: ThemeChoice::Dark,
            language: LanguageChoice::Italian,
            accent: Some("#e0569a".into()),
            added_color: Some("#2bb5a0".into()),
            removed_color: Some("#d2691e".into()),
            diff_text_mode: DiffMode::Split,
            diff_image_mode: DiffMode::Swipe,
            diff_minimap: false,
            history_compact: true,
            history_graph: false,
            blame_ignore_whitespace: true,
            blame_detect_moves: true,
            ignore_hint: false,
            keybindings: [("palette".to_owned(), "Ctrl+Shift+K".to_owned())].into(),
            extra: Table::new(),
        };
        assert_eq!(Config::parse(&config.to_toml()).unwrap(), config);
    }

    #[test]
    fn accents_are_normalised_hex_colours() {
        assert_eq!(parse_accent("#4C9CFF").as_deref(), Some("#4c9cff"));
        assert_eq!(parse_accent(" 4c9cff ").as_deref(), Some("#4c9cff"));
        assert_eq!(parse_accent("#F0a").as_deref(), Some("#ff00aa"));
        for bad in [
            "",
            "#",
            "#12345",
            "#1234567",
            "#ggg000",
            "blue",
            "#4c9cff80",
        ] {
            assert_eq!(parse_accent(bad), None, "{bad}");
        }
        let config = Config::parse("accent = \"#ABC\"").unwrap();
        assert_eq!(config.accent.as_deref(), Some("#aabbcc"));
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
            Config::parse("pull_mode = \"squash\""),
            Err(ConfigError::Invalid {
                key: "pull_mode",
                ..
            })
        ));
        assert!(matches!(
            Config::parse("theme = \"purple\""),
            Err(ConfigError::Invalid { key: "theme", .. })
        ));
        assert!(matches!(
            Config::parse("language = \"fr\""),
            Err(ConfigError::Invalid {
                key: "language",
                ..
            })
        ));
        assert!(matches!(
            Config::parse("accent = \"blue\""),
            Err(ConfigError::Invalid { key: "accent", .. })
        ));
        assert!(matches!(
            Config::parse("removed_color = \"#12\""),
            Err(ConfigError::Invalid {
                key: "removed_color",
                ..
            })
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

        let config = Config {
            known_repos: vec![PathBuf::from("/c"), PathBuf::from("/a")],
            ..Config::default()
        };
        config.save(&path).unwrap();
        assert!(!path.with_extension("toml.tmp").exists());
        assert_eq!(Config::load(&path).unwrap(), config);
        fs::remove_dir_all(&dir).unwrap();
    }
}
