//! gitbello core.
//!
//! All git logic, parsing, models, graph layout, watching and job scheduling
//! live here. This crate must never depend on Godot.

pub mod backend;
pub mod git;
pub mod graph;
pub mod jobs;
pub mod repo;
pub mod watch;

/// Version of the core crate, as reported to the UI and CLI.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Short greeting used by the M0 hello-world path through gdext.
pub fn greeting(name: &str) -> String {
    format!("Hello, {name}, from gitbello-core {VERSION}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_set() {
        assert!(!VERSION.is_empty());
    }

    #[test]
    fn greeting_includes_name_and_version() {
        let text = greeting("Godot");
        assert!(text.contains("Godot"));
        assert!(text.contains(VERSION));
    }
}
