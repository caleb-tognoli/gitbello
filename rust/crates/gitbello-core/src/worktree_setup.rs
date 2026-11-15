//! A new worktree's setup (UX.md New task): untracked files copied from
//! the main worktree (`.env`, editor settings), then a command such as
//! installing dependencies. Kept per repository in the library, never in a
//! committed file, so a cloned repository cannot run commands.

use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread;
use std::time::Duration;

use crate::git::{CancelToken, GitError, GitErrorKind};

/// The setup of one repository's new worktrees.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WorktreeSetup {
    /// gitignore-style patterns (`.env*`, `.vscode/`) of the main worktree's
    /// untracked files to copy.
    pub copy: Vec<String>,
    /// Run in the new worktree through the shell (`cmd /C`, `sh -c`); empty
    /// runs nothing.
    pub command: String,
}

impl WorktreeSetup {
    /// Blank patterns dropped and the command trimmed.
    pub fn cleaned(copy: &[String], command: &str) -> Self {
        Self {
            copy: copy
                .iter()
                .map(|p| p.trim())
                .filter(|p| !p.is_empty() && !p.starts_with('#'))
                .map(str::to_owned)
                .collect(),
            command: command.trim().to_owned(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.copy.is_empty() && self.command.is_empty()
    }
}

/// What a setup did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SetupOutcome {
    /// Files copied (those already in the new worktree are kept as they are).
    pub copied: usize,
    /// The command's output (stdout and stderr), cut to its last
    /// [`OUTPUT_LIMIT`] bytes.
    pub output: String,
}

/// Bytes of command output kept for the toast.
pub const OUTPUT_LIMIT: usize = 16 * 1024;

/// The label of the setup command's errors.
pub const SETUP_COMMAND: &str = "worktree setup";

/// Copies `entries` (paths relative to `from`, as `ls-files --directory`
/// lists them: a folder copies everything in it) into `to`. Files already
/// there are kept. Symbolic links are copied as the file they point to.
/// Returns the number of files copied.
pub fn copy_entries(
    from: &Path,
    to: &Path,
    entries: &[PathBuf],
    cancel: &CancelToken,
) -> Result<usize, GitError> {
    let mut copied = 0;
    for entry in entries {
        let source = from.join(entry);
        let target = to.join(entry);
        copy_path(&source, &target, &mut copied, cancel).map_err(|err| {
            GitError::new(
                format!("copy {}", entry.display()),
                GitErrorKind::Io,
                err.to_string(),
            )
        })?;
        if cancel.is_cancelled() {
            return Err(cancelled());
        }
    }
    Ok(copied)
}

fn copy_path(
    source: &Path,
    target: &Path,
    copied: &mut usize,
    cancel: &CancelToken,
) -> io::Result<()> {
    if cancel.is_cancelled() {
        return Ok(());
    }
    let meta = fs::metadata(source)?;
    if meta.is_dir() {
        fs::create_dir_all(target)?;
        for item in fs::read_dir(source)? {
            let item = item?;
            copy_path(&item.path(), &target.join(item.file_name()), copied, cancel)?;
        }
        return Ok(());
    }
    if fs::symlink_metadata(target).is_ok() {
        return Ok(());
    }
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(source, target)?;
    *copied += 1;
    Ok(())
}

fn cancelled() -> GitError {
    GitError::new(SETUP_COMMAND, GitErrorKind::Cancelled, "")
}

/// Runs `command` through the platform's shell in `dir`, without a window,
/// and waits for it. A cancel stops it and the programs it started. Fails
/// with the output when the command exits with an error.
pub fn run_command(dir: &Path, command: &str, cancel: &CancelToken) -> Result<String, GitError> {
    let mut cmd = shell(command);
    cmd.current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // npm and friends ask nothing when there is no terminal.
        .env("CI", "1");
    let mut child = cmd.spawn().map_err(|err| {
        GitError::new(
            format!("{SETUP_COMMAND}: {command}"),
            GitErrorKind::Spawn,
            err.to_string(),
        )
    })?;
    let output = Arc::new(Mutex::new(Vec::new()));
    let readers: Vec<_> = [
        child
            .stdout
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
        child
            .stderr
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
    ]
    .into_iter()
    .flatten()
    .map(|mut pipe| {
        let output = Arc::clone(&output);
        thread::spawn(move || {
            let mut chunk = [0u8; 4096];
            while let Ok(n) = pipe.read(&mut chunk) {
                if n == 0 {
                    break;
                }
                let mut out = output.lock().unwrap_or_else(PoisonError::into_inner);
                out.extend_from_slice(&chunk[..n]);
                let excess = out.len().saturating_sub(OUTPUT_LIMIT * 2);
                out.drain(..excess);
            }
        })
    })
    .collect();
    let status = loop {
        if cancel.is_cancelled() {
            kill_tree(&mut child);
            let _ = child.wait();
            for reader in readers {
                let _ = reader.join();
            }
            return Err(cancelled());
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => thread::sleep(Duration::from_millis(50)),
            Err(err) => {
                return Err(GitError::new(
                    SETUP_COMMAND,
                    GitErrorKind::Io,
                    err.to_string(),
                ))
            }
        }
    };
    for reader in readers {
        let _ = reader.join();
    }
    let bytes = output
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone();
    let text = tail(&String::from_utf8_lossy(&bytes), OUTPUT_LIMIT);
    if status.success() {
        return Ok(text);
    }
    let mut error = GitError::new(
        format!("{SETUP_COMMAND}: {command}"),
        GitErrorKind::Other,
        text,
    );
    error.exit_code = status.code();
    Err(error)
}

/// The last `limit` bytes of `text`, starting at a line when one starts
/// within them.
fn tail(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_owned();
    }
    let mut start = text.len() - limit;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    let rest = &text[start..];
    match rest.find('\n') {
        Some(nl) if nl + 1 < rest.len() => rest[nl + 1..].to_owned(),
        _ => rest.to_owned(),
    }
}

#[cfg(windows)]
fn shell(command: &str) -> Command {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let comspec = std::env::var_os("ComSpec").unwrap_or_else(|| "cmd.exe".into());
    let mut cmd = Command::new(comspec);
    // `/S /C "<command>"`: cmd strips the outer quotes and runs the rest as typed.
    cmd.raw_arg(format!("/D /S /C \"{command}\""))
        .creation_flags(CREATE_NO_WINDOW);
    cmd
}

#[cfg(not(windows))]
fn shell(command: &str) -> Command {
    use std::os::unix::process::CommandExt;
    let mut cmd = Command::new("sh");
    // Its own process group, so a cancel stops what it started too.
    cmd.arg("-c").arg(command).process_group(0);
    cmd
}

/// Stops `child` and every program it started.
fn kill_tree(child: &mut Child) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let _ = Command::new("taskkill")
            .args(["/T", "/F", "/PID", &child.id().to_string()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW)
            .status();
    }
    #[cfg(not(windows))]
    {
        let _ = Command::new("kill")
            .args(["-KILL", "--", &format!("-{}", child.id())])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    let _ = child.kill();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_patterns_and_the_command() {
        let setup = WorktreeSetup::cleaned(
            &[
                " .env* ".into(),
                "".into(),
                "# note".into(),
                ".vscode/".into(),
            ],
            "  npm ci \n",
        );
        assert_eq!(setup.copy, [".env*", ".vscode/"]);
        assert_eq!(setup.command, "npm ci");
        assert!(WorktreeSetup::cleaned(&["  ".into()], " ").is_empty());
    }

    #[test]
    fn keeps_the_tail_of_long_output_from_a_line_start() {
        assert_eq!(tail("short", 10), "short");
        assert_eq!(tail("aaaa\nbbbb\ncccc\n", 8), "cccc\n");
        assert_eq!(tail("ééééé", 3), "é");
    }
}
