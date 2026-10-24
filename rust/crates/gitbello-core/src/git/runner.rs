use std::env;
use std::ffi::{OsStr, OsString};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdout, Command, Stdio};
use std::thread::{self, JoinHandle};

use super::error::{GitError, GitErrorKind};
use super::version::{GitVersion, MIN_GIT_VERSION};

/// Environment variables that would redirect git away from the repository we
/// pass with `-C` (for example when gitbello itself is launched from a hook).
const SCRUBBED_ENV: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_PREFIX",
];

/// Whether a command only reads the repository. Reads skip optional locks so
/// they never contend with the user's own git commands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    Read,
    Write,
}

/// The one place that spawns git (AGENTS rule 2, PLAN §3.2).
#[derive(Debug, Clone)]
pub struct GitRunner {
    git: PathBuf,
    version: GitVersion,
}

impl GitRunner {
    /// Finds `git` on `PATH` and checks its version.
    pub fn discover() -> Result<Self, GitError> {
        let git = find_on_path("git").ok_or_else(|| {
            GitError::new(
                "--version",
                GitErrorKind::GitNotFound,
                "git was not found on PATH",
            )
        })?;
        Self::with_executable(git)
    }

    /// Uses a specific git executable (for the settings override) and checks its version.
    pub fn with_executable(git: impl Into<PathBuf>) -> Result<Self, GitError> {
        let git = git.into();
        let output = base_command(&git, Access::Read)
            .arg("--version")
            .output()
            .map_err(|err| {
                let kind = if err.kind() == io::ErrorKind::NotFound {
                    GitErrorKind::GitNotFound
                } else {
                    GitErrorKind::Spawn
                };
                GitError::new("--version", kind, err.to_string())
            })?;
        let text = String::from_utf8_lossy(&output.stdout);
        let version = GitVersion::parse(&text).ok_or_else(|| {
            GitError::new(
                "--version",
                GitErrorKind::Other,
                format!("unrecognised `git --version` output: {}", text.trim()),
            )
        })?;
        if version < MIN_GIT_VERSION {
            return Err(GitError::new(
                "--version",
                GitErrorKind::VersionTooOld,
                format!("git {version} found; gitbello needs {MIN_GIT_VERSION} or newer"),
            ));
        }
        Ok(Self { git, version })
    }

    pub fn executable(&self) -> &Path {
        &self.git
    }

    pub fn version(&self) -> GitVersion {
        self.version
    }

    /// A read-only command in `repo`.
    pub fn read(&self, repo: &Path) -> GitCommand {
        self.command(repo, Access::Read)
    }

    /// A state-changing command in `repo`.
    pub fn write(&self, repo: &Path) -> GitCommand {
        self.command(repo, Access::Write)
    }

    pub fn command(&self, repo: &Path, access: Access) -> GitCommand {
        let mut cmd = base_command(&self.git, access);
        cmd.arg("-C")
            .arg(repo)
            .args(["-c", "core.quotepath=false", "-c", "color.ui=false"]);
        GitCommand {
            cmd,
            args: Vec::new(),
            stdin: None,
        }
    }
}

/// Command with the environment every git call gets, before any arguments.
fn base_command(git: &Path, access: Access) -> Command {
    let mut cmd = Command::new(git);
    for var in SCRUBBED_ENV {
        cmd.env_remove(var);
    }
    cmd.env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .env("GIT_PAGER", "cat")
        // git runs the editor through a shell, where `:` is a no-op.
        .env("GIT_EDITOR", ":")
        .env("GIT_SEQUENCE_EDITOR", ":")
        .stdin(Stdio::null());
    if access == Access::Read {
        cmd.env("GIT_OPTIONAL_LOCKS", "0");
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    env::split_paths(&path)
        .map(|dir| dir.join(format!("{name}{}", env::consts::EXE_SUFFIX)))
        .find(|candidate| candidate.is_file())
}

/// A git invocation being built. Run it with [`GitCommand::run`] or [`GitCommand::stream`].
#[derive(Debug)]
pub struct GitCommand {
    cmd: Command,
    args: Vec<OsString>,
    stdin: Option<Vec<u8>>,
}

/// Output of a completed, successful git command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitOutput {
    pub stdout: Vec<u8>,
    pub stderr: String,
}

impl GitCommand {
    pub fn arg(mut self, arg: impl AsRef<OsStr>) -> Self {
        self.cmd.arg(arg.as_ref());
        self.args.push(arg.as_ref().to_owned());
        self
    }

    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        for arg in args {
            self = self.arg(arg);
        }
        self
    }

    pub fn env(mut self, key: impl AsRef<OsStr>, value: impl AsRef<OsStr>) -> Self {
        self.cmd.env(key, value);
        self
    }

    /// Bytes written to git's stdin (commit messages, patches). Never use an editor.
    pub fn stdin(mut self, data: impl Into<Vec<u8>>) -> Self {
        self.stdin = Some(data.into());
        self
    }

    /// The arguments as shown in logs and errors.
    pub fn display(&self) -> String {
        self.args
            .iter()
            .map(|arg| arg.to_string_lossy())
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// Runs to completion and returns stdout, or a classified error.
    pub fn run(mut self) -> Result<GitOutput, GitError> {
        let display = self.display();
        if self.stdin.is_some() {
            self.cmd.stdin(Stdio::piped());
        }
        let mut child = self
            .cmd
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|err| spawn_error(&display, err))?;
        let writer = spawn_stdin_writer(&mut child, self.stdin.take());
        let output = child
            .wait_with_output()
            .map_err(|err| GitError::new(&display, GitErrorKind::Io, err.to_string()))?;
        if let Some(writer) = writer {
            // A write error here means git exited early; its exit status says why.
            let _ = writer.join();
        }
        if !output.status.success() {
            return Err(GitError::from_exit(
                display,
                output.status.code(),
                &output.stdout,
                &output.stderr,
            ));
        }
        Ok(GitOutput {
            stdout: output.stdout,
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }

    /// Starts git and returns its stdout as a stream, for long output (log, diff).
    /// Call [`GitStream::finish`] after reading to learn whether git succeeded.
    pub fn stream(mut self) -> Result<GitStream, GitError> {
        let display = self.display();
        if self.stdin.is_some() {
            self.cmd.stdin(Stdio::piped());
        }
        let mut child = self
            .cmd
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|err| spawn_error(&display, err))?;
        let writer = spawn_stdin_writer(&mut child, self.stdin.take());
        let stdout = child.stdout.take().ok_or_else(|| {
            GitError::new(&display, GitErrorKind::Io, "git stdout was not captured")
        })?;
        let stderr = child.stderr.take().map(|mut stderr| {
            thread::spawn(move || {
                let mut buf = Vec::new();
                let _ = stderr.read_to_end(&mut buf);
                buf
            })
        });
        Ok(GitStream {
            child,
            stdout,
            stderr,
            writer,
            display,
            finished: false,
        })
    }
}

fn spawn_error(display: &str, err: io::Error) -> GitError {
    let kind = if err.kind() == io::ErrorKind::NotFound {
        GitErrorKind::GitNotFound
    } else {
        GitErrorKind::Spawn
    };
    GitError::new(display, kind, err.to_string())
}

fn spawn_stdin_writer(child: &mut Child, data: Option<Vec<u8>>) -> Option<JoinHandle<()>> {
    let data = data?;
    let mut stdin = child.stdin.take()?;
    Some(thread::spawn(move || {
        let _ = stdin.write_all(&data);
    }))
}

/// Running git process whose stdout is read incrementally. Dropping it before
/// [`GitStream::finish`] kills the process.
#[derive(Debug)]
pub struct GitStream {
    child: Child,
    stdout: ChildStdout,
    stderr: Option<JoinHandle<Vec<u8>>>,
    writer: Option<JoinHandle<()>>,
    display: String,
    finished: bool,
}

impl GitStream {
    pub fn command(&self) -> &str {
        &self.display
    }

    /// Kills the process; the stream then ends and `finish` reports `Cancelled`.
    pub fn kill(&mut self) {
        let _ = self.child.kill();
    }

    /// Waits for git to exit and returns its error, if any.
    pub fn finish(mut self) -> Result<(), GitError> {
        self.finished = true;
        // Drain whatever is left so git is not blocked on a full pipe.
        let _ = io::copy(&mut self.stdout, &mut io::sink());
        let status = self
            .child
            .wait()
            .map_err(|err| GitError::new(&self.display, GitErrorKind::Io, err.to_string()))?;
        if let Some(writer) = self.writer.take() {
            let _ = writer.join();
        }
        let stderr = self
            .stderr
            .take()
            .and_then(|handle| handle.join().ok())
            .unwrap_or_default();
        if status.success() {
            Ok(())
        } else {
            Err(GitError::from_exit(
                self.display.clone(),
                status.code(),
                b"",
                &stderr,
            ))
        }
    }
}

impl Read for GitStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.stdout.read(buf)
    }
}

impl Drop for GitStream {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}
