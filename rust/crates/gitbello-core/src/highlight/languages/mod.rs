//! The language registry. A language is a [`LanguageDef`] in its own file,
//! listed once in [`ALL`].

use std::fmt;
use std::hash::{Hash, Hasher};

use super::hints::FileHints;
use super::lexer::Lexer;

mod batch;
mod c;
mod cpp;
mod csharp;
mod css;
mod csv;
mod dart;
mod dockerfile;
mod dotenv;
mod gdscript;
mod glsl;
mod go;
mod godot_resource;
mod godot_shader;
mod ini;
mod java;
mod javascript;
mod json;
mod kotlin;
mod lua;
mod makefile;
mod markdown;
mod markup;
mod patch;
mod patterns;
mod php;
mod powershell;
mod python;
mod razor;
mod ruby;
mod rust;
mod shell;
mod sql;
mod swift;
mod toml;
mod typescript;
mod yaml;
mod zig;

/// A language: how files are recognised and how they are lexed.
pub struct LanguageDef {
    /// Stable id (`rust`), also the folder of its test sample.
    pub id: &'static str,
    /// Display name.
    pub name: &'static str,
    /// Lowercase extensions without the dot.
    pub extensions: &'static [&'static str],
    /// Lowercase whole file names (`makefile`, `.bashrc`).
    pub file_names: &'static [&'static str],
    /// Interpreter names a shebang line may give (`python`, `bash`),
    /// version numbers stripped.
    pub shebangs: &'static [&'static str],
    pub lexer: &'static dyn Lexer,
    /// Settings derived once per file from some of its lines.
    pub hints: fn(&[String]) -> FileHints,
}

/// Every language, in detection order (the first match wins).
pub static ALL: &[&LanguageDef] = &[
    &rust::RUST,
    &gdscript::GDSCRIPT,
    &python::PYTHON,
    &javascript::JAVASCRIPT,
    &typescript::TYPESCRIPT,
    &c::C,
    &cpp::CPP,
    &csharp::CSHARP,
    &java::JAVA,
    &kotlin::KOTLIN,
    &swift::SWIFT,
    &glsl::GLSL,
    &godot_shader::GODOT_SHADER,
    &go::GO,
    &json::JSON,
    &toml::TOML,
    &yaml::YAML,
    &ini::INI,
    &godot_resource::GODOT_RESOURCE,
    &shell::SHELL,
    &powershell::POWERSHELL,
    &batch::BATCH,
    &dockerfile::DOCKERFILE,
    &makefile::MAKEFILE,
    &markdown::MARKDOWN,
    &markup::HTML,
    &markup::XML,
    &css::CSS,
    &css::SCSS,
    &css::LESS,
    &csv::CSV,
    &csv::TSV,
    &sql::SQL,
    &dotenv::DOTENV,
    &patterns::IGNORE,
    &patterns::GITATTRIBUTES,
    &patch::PATCH,
    &lua::LUA,
    &ruby::RUBY,
    &php::PHP,
    &razor::RAZOR,
    &dart::DART,
    &zig::ZIG,
];

/// No hints.
pub fn no_hints(_lines: &[String]) -> FileHints {
    FileHints::default()
}

/// A handle to a registered language.
#[derive(Clone, Copy)]
pub struct Language(&'static LanguageDef);

impl Language {
    pub fn id(self) -> &'static str {
        self.0.id
    }

    pub fn name(self) -> &'static str {
        self.0.name
    }

    pub fn def(self) -> &'static LanguageDef {
        self.0
    }

    pub fn lexer(self) -> &'static dyn Lexer {
        self.0.lexer
    }

    /// The language with id `id`.
    pub fn by_id(id: &str) -> Option<Self> {
        ALL.iter().find(|d| d.id == id).map(|d| Self(d))
    }

    /// Every registered language.
    pub fn all() -> impl Iterator<Item = Self> {
        ALL.iter().map(|d| Self(d))
    }

    /// The language's index in the registry.
    pub fn index(self) -> usize {
        ALL.iter()
            .position(|d| std::ptr::eq(*d, self.0))
            .unwrap_or_default()
    }

    /// The language at `index` in the registry.
    pub fn by_index(index: usize) -> Option<Self> {
        ALL.get(index).map(|d| Self(d))
    }
}

impl PartialEq for Language {
    fn eq(&self, other: &Self) -> bool {
        self.0.id == other.0.id
    }
}

impl Eq for Language {}

impl Hash for Language {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.0.id.hash(state);
    }
}

impl fmt::Debug for Language {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Language({})", self.0.id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_is_consistent() {
        let mut ids: Vec<&str> = ALL.iter().map(|d| d.id).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), ALL.len(), "duplicate language ids");
        for def in ALL {
            let lower = |s: &&str| s.chars().all(|c| !c.is_uppercase());
            assert!(def.extensions.iter().all(lower), "{}", def.id);
            assert!(def.file_names.iter().all(lower), "{}", def.id);
            assert!(
                def.extensions.iter().all(|e| !e.starts_with('.')),
                "{}",
                def.id
            );
            assert_eq!(Language::by_id(def.id).map(Language::id), Some(def.id));
        }
        // An extension, a name or a shebang belongs to one language only.
        for claims in [
            (|d: &LanguageDef| d.extensions) as fn(&LanguageDef) -> &'static [&'static str],
            |d| d.file_names,
            |d| d.shebangs,
        ] {
            let mut seen = std::collections::HashMap::new();
            for def in ALL {
                for key in claims(def) {
                    if let Some(other) = seen.insert(*key, def.id) {
                        panic!("{key} is claimed by {other} and {}", def.id);
                    }
                }
            }
        }
    }
}
