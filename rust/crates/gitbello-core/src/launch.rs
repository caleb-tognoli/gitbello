//! "Open in editor" and "Open terminal here" (PLAN §3.8, and the §3.13
//! fallback): user command templates such as `code {path}`, split into
//! arguments and started without a shell, in the folder they open.

use std::env;
use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum LaunchError {
    #[error("the command is empty")]
    Empty,
    #[error("unmatched quote in `{0}`")]
    UnmatchedQuote(String),
    #[error("`{0}` was not found; check the command in the settings")]
    NotFound(String),
    #[error("no terminal program found; set `terminal_command` in the settings")]
    NoTerminal,
    #[error("cannot start `{program}`: {source}")]
    Spawn {
        program: String,
        #[source]
        source: io::Error,
    },
}

/// Splits `template` into arguments (whitespace separates them; `"..."` or
/// `'...'` keep spaces) and replaces `{path}` in each with `path`. Paths are
/// substituted after splitting, so they never need quoting.
pub fn expand(template: &str, path: &Path) -> Result<Vec<String>, LaunchError> {
    let mut args = Vec::new();
    let mut current = String::new();
    let mut in_arg = false;
    let mut quote: Option<char> = None;
    for c in template.chars() {
        match quote {
            Some(q) if c == q => quote = None,
            Some(_) => current.push(c),
            None if c == '"' || c == '\'' => {
                quote = Some(c);
                in_arg = true;
            }
            None if c.is_whitespace() => {
                if in_arg {
                    args.push(std::mem::take(&mut current));
                    in_arg = false;
                }
            }
            None => {
                current.push(c);
                in_arg = true;
            }
        }
    }
    if quote.is_some() {
        return Err(LaunchError::UnmatchedQuote(template.to_owned()));
    }
    if in_arg {
        args.push(current);
    }
    if args.is_empty() {
        return Err(LaunchError::Empty);
    }
    let path = path.to_string_lossy();
    Ok(args
        .into_iter()
        .map(|a| a.replace("{path}", &path))
        .collect())
}

/// What is being opened; terminals that need a console get a new one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaunchKind {
    Editor,
    Terminal,
}

/// Starts `template` for `dir` (also its working directory) and returns
/// without waiting for it.
pub fn launch(template: &str, dir: &Path, kind: LaunchKind) -> Result<(), LaunchError> {
    let args = expand(template, dir)?;
    let program = find_program(&args[0]).ok_or_else(|| LaunchError::NotFound(args[0].clone()))?;
    let mut cmd = Command::new(&program);
    cmd.args(&args[1..])
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let stem = program
            .file_stem()
            .map(|s| s.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        let console_shell = matches!(stem.as_str(), "cmd" | "powershell" | "pwsh");
        cmd.creation_flags(if kind == LaunchKind::Terminal && console_shell {
            CREATE_NEW_CONSOLE
        } else {
            CREATE_NO_WINDOW
        });
    }
    #[cfg(not(windows))]
    let _ = kind;
    let mut child = cmd.spawn().map_err(|source| LaunchError::Spawn {
        program: args[0].clone(),
        source,
    })?;
    // Reap the process when it exits; nobody waits for its result.
    thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

/// Starts the configured terminal, or the platform's when `template` is `None`.
pub fn launch_terminal(template: Option<&str>, dir: &Path) -> Result<(), LaunchError> {
    match template {
        Some(template) => launch(template, dir, LaunchKind::Terminal),
        None => {
            let template = default_terminal().ok_or(LaunchError::NoTerminal)?;
            launch(&template, dir, LaunchKind::Terminal)
        }
    }
}

/// The platform's terminal as a template, if one is installed.
pub fn default_terminal() -> Option<String> {
    if cfg!(windows) {
        return Some(if find_program("wt").is_some() {
            "wt -d {path}".to_owned()
        } else {
            "cmd".to_owned()
        });
    }
    if cfg!(target_os = "macos") {
        return Some("open -a Terminal {path}".to_owned());
    }
    // Started in the folder, these open there.
    [
        "x-terminal-emulator",
        "gnome-terminal",
        "konsole",
        "xfce4-terminal",
        "kitty",
        "alacritty",
        "xterm",
    ]
    .into_iter()
    .find(|name| find_program(name).is_some())
    .map(str::to_owned)
}

/// Resolves `name` like a shell would: a path is used as is, a bare name is
/// looked up on `PATH`. On Windows, names without an extension also try the
/// `PATHEXT` ones (so `code` finds `code.cmd`).
pub fn find_program(name: &str) -> Option<PathBuf> {
    let candidates = |base: PathBuf| -> Vec<PathBuf> {
        let mut out = vec![base.clone()];
        if cfg!(windows) && base.extension().is_none() {
            let exts = env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into());
            for ext in exts.split(';').filter(|e| !e.is_empty()) {
                let mut with_ext = OsString::from(base.as_os_str());
                with_ext.push(ext.to_lowercase());
                out.push(PathBuf::from(with_ext));
            }
        }
        out
    };
    let path = Path::new(name);
    if path.components().count() > 1 || path.is_absolute() {
        return candidates(path.to_path_buf())
            .into_iter()
            .find(|c| c.is_file());
    }
    let dirs = env::var_os("PATH")?;
    env::split_paths(&dirs)
        .flat_map(|dir| candidates(dir.join(name)))
        .find(|c| c.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn expands_templates_with_quotes_and_paths_with_spaces() {
        let dir = Path::new("/home/ädä/my repo");
        assert_eq!(
            expand("code {path}", dir).unwrap(),
            ["code", "/home/ädä/my repo"]
        );
        assert_eq!(
            expand("  \"C:/Program Files/Sublime/subl.exe\"  -n '{path}' ", dir).unwrap(),
            [
                "C:/Program Files/Sublime/subl.exe",
                "-n",
                "/home/ädä/my repo"
            ]
        );
        assert_eq!(
            expand("gnome-terminal --working-directory={path}", dir).unwrap(),
            ["gnome-terminal", "--working-directory=/home/ädä/my repo"]
        );
        assert_eq!(expand("x \"\"", dir).unwrap(), ["x", ""]);
    }

    #[test]
    fn rejects_empty_templates_and_open_quotes() {
        let dir = Path::new("/r");
        assert!(matches!(expand("   ", dir), Err(LaunchError::Empty)));
        assert!(matches!(
            expand("code \"{path}", dir),
            Err(LaunchError::UnmatchedQuote(_))
        ));
    }

    #[test]
    fn finds_programs_by_path_and_reports_missing_ones() {
        let dir = env::temp_dir().join(format!("gitbello lauñch {}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let file = if cfg!(windows) { "tool.cmd" } else { "tool" };
        fs::write(dir.join(file), "").unwrap();
        let bare = dir.join("tool");
        assert_eq!(
            find_program(&bare.to_string_lossy()).map(|p| p.file_name().unwrap().to_owned()),
            Some(OsString::from(file))
        );
        assert_eq!(find_program(&dir.join("nope").to_string_lossy()), None);
        let missing = launch(
            "gitbello-no-such-program-x {path}",
            &dir,
            LaunchKind::Editor,
        );
        assert!(
            matches!(missing, Err(LaunchError::NotFound(p)) if p == "gitbello-no-such-program-x")
        );
        fs::remove_dir_all(&dir).unwrap();
    }
}
