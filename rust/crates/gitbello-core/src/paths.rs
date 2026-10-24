//! Per-user directories for config and app data (PLAN §3.8).
//!
//! Written out by hand instead of using the `directories` crate, whose
//! Windows dependency cannot be built by the GNU toolchain without extra
//! binutils. The locations match what `directories` returns.

use std::env;
use std::path::PathBuf;

const APP: &str = "gitbello";

/// Where `config.toml` lives:
/// - Windows: `%APPDATA%\gitbello`
/// - macOS: `~/Library/Application Support/gitbello`
/// - Linux and others: `$XDG_CONFIG_HOME/gitbello` or `~/.config/gitbello`
pub fn config_dir() -> Option<PathBuf> {
    if cfg!(windows) {
        env_dir("APPDATA")
    } else if cfg!(target_os = "macos") {
        home().map(|h| h.join("Library").join("Application Support"))
    } else {
        env_dir("XDG_CONFIG_HOME").or_else(|| home().map(|h| h.join(".config")))
    }
    .map(|dir| dir.join(APP))
}

/// Where per-repository app state lives (never inside the repository):
/// - Windows: `%LOCALAPPDATA%\gitbello`
/// - macOS: `~/Library/Application Support/gitbello`
/// - Linux and others: `$XDG_DATA_HOME/gitbello` or `~/.local/share/gitbello`
pub fn data_dir() -> Option<PathBuf> {
    if cfg!(windows) {
        env_dir("LOCALAPPDATA")
    } else if cfg!(target_os = "macos") {
        home().map(|h| h.join("Library").join("Application Support"))
    } else {
        env_dir("XDG_DATA_HOME").or_else(|| home().map(|h| h.join(".local").join("share")))
    }
    .map(|dir| dir.join(APP))
}

/// Default config file path.
pub fn config_file() -> Option<PathBuf> {
    config_dir().map(|dir| dir.join("config.toml"))
}

/// An absolute directory from an environment variable (relative values are
/// ignored, as the XDG spec requires).
fn env_dir(var: &str) -> Option<PathBuf> {
    env::var_os(var)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
}

fn home() -> Option<PathBuf> {
    env_dir("HOME").or_else(|| env_dir("USERPROFILE"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dirs_are_absolute_and_named_after_the_app() {
        for dir in [config_dir(), data_dir()].into_iter().flatten() {
            assert!(dir.is_absolute(), "{dir:?}");
            assert!(dir.ends_with(APP), "{dir:?}");
        }
        assert!(config_file().is_some_and(|f| f.ends_with("gitbello/config.toml")));
    }
}
