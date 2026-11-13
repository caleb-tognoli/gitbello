//! Which language a file is: by its whole name, then its extension, then
//! the interpreter its first line names (`#!/usr/bin/env python3`).

use std::path::Path;

use super::languages::{Language, ALL};

/// The language of `path`, or `None` for plain text. `first_line` is the
/// file's first line when known; it is only read when the name and the
/// extension say nothing.
pub fn detect(path: &Path, first_line: Option<&str>) -> Option<Language> {
    by_name(path).or_else(|| first_line.and_then(by_shebang))
}

/// The language `path`'s name or extension gives, without reading it.
pub fn by_name(path: &Path) -> Option<Language> {
    let name = path.file_name()?.to_string_lossy().to_lowercase();
    if let Some(def) = ALL.iter().find(|d| d.file_names.contains(&name.as_str())) {
        return Language::by_id(def.id);
    }
    let ext = path.extension()?.to_string_lossy().to_lowercase();
    ALL.iter()
        .find(|d| d.extensions.contains(&ext.as_str()))
        .and_then(|d| Language::by_id(d.id))
}

/// The language a shebang line names.
pub fn by_shebang(line: &str) -> Option<Language> {
    let interpreter = shebang_interpreter(line)?;
    ALL.iter()
        .find(|d| d.shebangs.contains(&interpreter.as_str()))
        .and_then(|d| Language::by_id(d.id))
}

/// The interpreter a shebang line runs, lowercase and without its version
/// or `.exe` (`#!/usr/bin/env -S python3.12 -u` → `python`).
pub fn shebang_interpreter(line: &str) -> Option<String> {
    let line = line.trim_start_matches('\u{feff}');
    let rest = line.strip_prefix("#!")?.trim();
    let mut words = rest.split_whitespace();
    let mut program = base_name(words.next()?);
    if program == "env" {
        // Skip env's options and VAR=value assignments.
        program = words
            .find(|w| !w.starts_with('-') && !w.contains('='))
            .map(base_name)?;
    }
    let program = program.strip_suffix(".exe").unwrap_or(&program).to_owned();
    let name = program.trim_end_matches(|c: char| c.is_ascii_digit() || c == '.');
    (!name.is_empty()).then(|| name.to_owned())
}

fn base_name(word: &str) -> String {
    word.rsplit(['/', '\\'])
        .next()
        .unwrap_or(word)
        .to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(path: &str, first: Option<&str>) -> Option<&'static str> {
        detect(Path::new(path), first).map(Language::id)
    }

    #[test]
    fn names_and_extensions() {
        assert_eq!(id("src/main.rs", None), Some("rust"));
        assert_eq!(id("app/x.GD", None), Some("gdscript"));
        assert_eq!(id("Makefile", None), Some("makefile"));
        assert_eq!(id("GNUmakefile", None), Some("makefile"));
        assert_eq!(id("sub dir/Dockerfile", None), Some("dockerfile"));
        assert_eq!(id("web.dockerfile", None), Some("dockerfile"));
        assert_eq!(id("include/x.h", None), Some("cpp"));
        assert_eq!(id("x.c", None), Some("c"));
        assert_eq!(id("a.tsx", None), Some("typescript"));
        assert_eq!(id("main.tscn", None), Some("godot_resource"));
        assert_eq!(id("project.godot", None), Some("godot_resource"));
        assert_eq!(id("x.gdshader", None), Some("godot_shader"));
        assert_eq!(id(".editorconfig", None), Some("ini"));
        assert_eq!(id("Cargo.lock", None), Some("toml"));
        assert_eq!(id("go.mod", None), Some("go"));
        assert_eq!(id(".bashrc", None), Some("shell"));
        assert_eq!(id("setup.PS1", None), Some("powershell"));
        assert_eq!(id(".clang-format", None), Some("yaml"));
        assert_eq!(id("run", Some("#!/usr/bin/env pwsh")), Some("powershell"));
        assert_eq!(id("index.HTML", None), Some("html"));
        assert_eq!(id("icons/a.svg", None), Some("xml"));
        assert_eq!(id("App.csproj", None), Some("xml"));
        assert_eq!(id("a.scss", None), Some("scss"));
        assert_eq!(id("a.less", None), Some("less"));
        assert_eq!(id("data.csv", None), Some("csv"));
        assert_eq!(id("data.tab", None), Some("tsv"));
        assert_eq!(id("schema.sql", None), Some("sql"));
        assert_eq!(id(".env", None), Some("dotenv"));
        assert_eq!(id("app/.env.local", None), Some("dotenv"));
        assert_eq!(id("prod.env", None), Some("dotenv"));
        assert_eq!(id(".gitignore", None), Some("ignore"));
        assert_eq!(id("templates/Node.gitignore", None), Some("ignore"));
        assert_eq!(id(".dockerignore", None), Some("ignore"));
        assert_eq!(id(".gitattributes", None), Some("gitattributes"));
        assert_eq!(id("fix.patch", None), Some("diff"));
        assert_eq!(id("init.lua", None), Some("lua"));
        assert_eq!(id("app.rb", None), Some("ruby"));
        assert_eq!(id("Gemfile", None), Some("ruby"));
        assert_eq!(id("lib/tasks/db.rake", None), Some("ruby"));
        assert_eq!(id("x.gemspec", None), Some("ruby"));
        assert_eq!(id("index.php", None), Some("php"));
        assert_eq!(id("Counter.razor", None), Some("razor"));
        assert_eq!(id("Views/Index.cshtml", None), Some("razor"));
        assert_eq!(id("Counter.razor.cs", None), Some("csharp"));
        assert_eq!(id("Index.cshtml.cs", None), Some("csharp"));
        assert_eq!(id("Counter.razor.css", None), Some("css"));
        assert_eq!(id("view.phtml", None), Some("php"));
        assert_eq!(id("build.BAT", None), Some("batch"));
        assert_eq!(id("setup.cmd", None), Some("batch"));
        assert_eq!(id("main.dart", None), Some("dart"));
        assert_eq!(id("build.zig", None), Some("zig"));
        assert_eq!(id("build.zig.zon", None), Some("zig"));
        assert_eq!(id("README", None), None);
        assert_eq!(id("dossier é/données.json", None), Some("json"));
        assert_eq!(id(".rs", None), None);
        // The name decides before the shebang.
        assert_eq!(id("x.py", Some("#!/bin/bash")), Some("python"));
    }

    #[test]
    fn shebangs() {
        let cases = [
            ("#!/bin/bash", Some("shell")),
            ("#!/usr/bin/env bash", Some("shell")),
            ("#! /bin/sh -e", Some("shell")),
            ("#!/usr/bin/env -S python3.12 -u", Some("python")),
            ("#!/usr/bin/env -i PATH=/bin python3", Some("python")),
            ("#!/usr/bin/python2.7", Some("python")),
            ("\u{feff}#!/usr/bin/env node", Some("javascript")),
            ("#!C:\\Python311\\python.exe", Some("python")),
            ("#!/usr/bin/env\r", None),
            ("#!/usr/bin/env ruby", Some("ruby")),
            ("#!/usr/bin/lua5.4", Some("lua")),
            ("#!/usr/bin/env luajit", Some("lua")),
            ("#!/usr/bin/php -q", Some("php")),
            ("#!/usr/bin/env perl", None),
            ("#!", None),
            ("# not a shebang", None),
        ];
        for (line, want) in cases {
            assert_eq!(id("script", Some(line)), want, "{line:?}");
        }
        assert_eq!(
            shebang_interpreter("#!/usr/bin/env -S deno run").as_deref(),
            Some("deno")
        );
    }
}
