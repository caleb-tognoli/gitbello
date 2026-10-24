use std::env;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdout, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime};

use super::cancel::CancelToken;
use super::error::{GitError, GitErrorKind};
use super::log::{CommandLog, CommandOutcome};
use super::progress::{LineSplitter, Progress};
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

/// How often a running command checks its cancel token.
const POLL: Duration = Duration::from_millis(20);

/// How long to keep reading output after git itself has exited.
const EXIT_GRACE: Duration = Duration::from_millis(100);

/// Whether a command only reads the repository. Reads skip optional locks so
/// they never contend with the user's own git commands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    Read,
    Write,
}

/// The one place that spawns git (AGENTS rule 2, PLAN §3.2). Clones share the
/// same command log.
#[derive(Debug, Clone)]
pub struct GitRunner {
    git: PathBuf,
    version: GitVersion,
    log: CommandLog,
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

    /// Uses `git` if given (the settings override), otherwise searches `PATH`.
    pub fn from_override(git: Option<&Path>) -> Result<Self, GitError> {
        match git {
            Some(path) => Self::with_executable(path),
            None => Self::discover(),
        }
    }

    /// Uses a specific git executable and checks its version.
    pub fn with_executable(git: impl Into<PathBuf>) -> Result<Self, GitError> {
        let git = git.into();
        let output = base_command(&git, Access::Read)
            .arg("--version")
            .output()
            .map_err(|err| spawn_error("--version", err))?;
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
        Ok(Self {
            git,
            version,
            log: CommandLog::default(),
        })
    }

    pub fn executable(&self) -> &Path {
        &self.git
    }

    pub fn version(&self) -> GitVersion {
        self.version
    }

    /// Every command this runner (and its clones) ran, for the Git log panel.
    pub fn log(&self) -> &CommandLog {
        &self.log
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
            repo: repo.to_path_buf(),
            args: Vec::new(),
            stdin: None,
            cancel: None,
            progress: None,
            log: self.log.clone(),
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

type ProgressFn = Box<dyn FnMut(Progress) + Send>;

/// A git invocation being built. Run it with [`GitCommand::run`] or [`GitCommand::stream`].
pub struct GitCommand {
    cmd: Command,
    repo: PathBuf,
    args: Vec<OsString>,
    stdin: Option<Vec<u8>>,
    cancel: Option<CancelToken>,
    progress: Option<ProgressFn>,
    log: CommandLog,
}

impl fmt::Debug for GitCommand {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GitCommand")
            .field("repo", &self.repo)
            .field("args", &self.display())
            .finish_non_exhaustive()
    }
}

/// Output of a completed, successful git command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitOutput {
    pub stdout: Vec<u8>,
    pub stderr: String,
}

impl GitOutput {
    pub fn stdout_text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }
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

    /// Kills git shortly after `token` is cancelled; the result is then
    /// [`GitErrorKind::Cancelled`].
    pub fn cancel_token(mut self, token: &CancelToken) -> Self {
        self.cancel = Some(token.clone());
        self
    }

    /// Reports `--progress` lines from stderr as they arrive. The caller adds
    /// `--progress` to the arguments.
    pub fn on_progress(mut self, callback: impl FnMut(Progress) + Send + 'static) -> Self {
        self.progress = Some(Box::new(callback));
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
        let started_at = SystemTime::now();
        let started = Instant::now();
        let result = self.execute(&display);
        let duration = started.elapsed();
        let (exit_code, outcome) = match &result {
            Ok(_) => (Some(0), CommandOutcome::Succeeded),
            Err(err) if err.kind == GitErrorKind::Cancelled => (None, CommandOutcome::Cancelled),
            Err(err) => (err.exit_code, CommandOutcome::Failed(err.kind)),
        };
        self.log.push(
            self.repo.clone(),
            display,
            started_at,
            duration,
            exit_code,
            outcome,
        );
        result
    }

    fn execute(&mut self, display: &str) -> Result<GitOutput, GitError> {
        if self.stdin.is_some() {
            self.cmd.stdin(Stdio::piped());
        }
        let mut child = self
            .cmd
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|err| spawn_error(display, err))?;
        let writer = spawn_stdin_writer(&mut child, self.stdin.take());
        let (tx, rx) = mpsc::channel::<Chunk>();
        let mut open_pipes = 0;
        if let Some(stdout) = child.stdout.take() {
            spawn_reader(stdout, tx.clone(), Chunk::Out);
            open_pipes += 1;
        }
        if let Some(stderr) = child.stderr.take() {
            spawn_reader(stderr, tx.clone(), Chunk::Err);
            open_pipes += 1;
        }
        drop(tx);

        // Collect output (feeding progress) while checking the cancel token.
        // Processes git starts (ssh, credential helpers, aliases) can inherit
        // the pipes and keep them open after git exits, so once git has exited
        // we only wait EXIT_GRACE for the rest of the output.
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let mut lines = LineSplitter::default();
        let mut cancelled = false;
        let mut exited: Option<(ExitStatus, Instant)> = None;
        loop {
            match rx.recv_timeout(POLL) {
                Ok(Chunk::Out(Some(bytes))) => stdout.extend_from_slice(&bytes),
                Ok(Chunk::Err(Some(bytes))) => {
                    if let Some(progress) = self.progress.as_mut() {
                        lines.feed(&bytes, |line| {
                            if let Some(update) = Progress::parse(line) {
                                progress(update);
                            }
                        });
                    }
                    stderr.extend_from_slice(&bytes);
                }
                Ok(Chunk::Out(None) | Chunk::Err(None)) => open_pipes -= 1,
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => open_pipes = 0,
            }
            if !cancelled && self.cancel.as_ref().is_some_and(CancelToken::is_cancelled) {
                cancelled = true;
                let _ = child.kill();
            }
            if exited.is_none() {
                if let Some(status) = child
                    .try_wait()
                    .map_err(|err| GitError::new(display, GitErrorKind::Io, err.to_string()))?
                {
                    exited = Some((status, Instant::now()));
                }
            }
            match exited {
                Some(_) if open_pipes == 0 => break,
                Some((_, at)) if at.elapsed() > EXIT_GRACE => break,
                _ => {}
            }
        }
        if let Some(progress) = self.progress.as_mut() {
            lines.finish(|line| {
                if let Some(update) = Progress::parse(line) {
                    progress(update);
                }
            });
        }
        let status = match exited {
            Some((status, _)) => status,
            None => child
                .wait()
                .map_err(|err| GitError::new(display, GitErrorKind::Io, err.to_string()))?,
        };
        if let Some(writer) = writer {
            // A write error here means git exited early; its exit status says why.
            if writer.is_finished() {
                let _ = writer.join();
            }
        }
        if cancelled {
            return Err(GitError::new(
                display,
                GitErrorKind::Cancelled,
                String::from_utf8_lossy(&stderr),
            ));
        }
        if !status.success() {
            return Err(GitError::from_exit(
                display,
                status.code(),
                &stdout,
                &stderr,
            ));
        }
        Ok(GitOutput {
            stdout,
            stderr: String::from_utf8_lossy(&stderr).into_owned(),
        })
    }

    /// Starts git and returns its stdout as a stream, for long output (log, diff).
    /// Call [`GitStream::finish`] after reading to learn whether git succeeded.
    pub fn stream(mut self) -> Result<GitStream, GitError> {
        let display = self.display();
        if self.stdin.is_some() {
            self.cmd.stdin(Stdio::piped());
        }
        let started_at = SystemTime::now();
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
            repo: self.repo,
            log: self.log,
            started_at,
            started: Instant::now(),
            killed: false,
            finished: false,
        })
    }
}

/// Output from one of the child's pipes; `None` marks the end of that pipe.
enum Chunk {
    Out(Option<Vec<u8>>),
    Err(Option<Vec<u8>>),
}

fn spawn_reader(
    mut pipe: impl Read + Send + 'static,
    tx: mpsc::Sender<Chunk>,
    wrap: fn(Option<Vec<u8>>) -> Chunk,
) {
    thread::spawn(move || {
        let mut buf = [0u8; 16 * 1024];
        loop {
            match pipe.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if tx.send(wrap(Some(buf[..n].to_vec()))).is_err() {
                        return;
                    }
                }
            }
        }
        let _ = tx.send(wrap(None));
    });
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
    repo: PathBuf,
    log: CommandLog,
    started_at: SystemTime,
    started: Instant,
    killed: bool,
    finished: bool,
}

impl GitStream {
    pub fn command(&self) -> &str {
        &self.display
    }

    /// Kills the process; `finish` then reports `Cancelled`.
    pub fn kill(&mut self) {
        self.killed = true;
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
            .map_err(|err| GitError::new(&self.display, GitErrorKind::Io, err.to_string()));
        if let Some(writer) = self.writer.take() {
            let _ = writer.join();
        }
        let stderr = self
            .stderr
            .take()
            .and_then(|handle| handle.join().ok())
            .unwrap_or_default();
        let result = match status {
            Err(err) => Err(err),
            Ok(_) if self.killed => Err(GitError::new(
                &self.display,
                GitErrorKind::Cancelled,
                String::from_utf8_lossy(&stderr),
            )),
            Ok(status) if status.success() => Ok(()),
            Ok(status) => Err(GitError::from_exit(
                self.display.clone(),
                status.code(),
                b"",
                &stderr,
            )),
        };
        self.record(match &result {
            Ok(()) => (Some(0), CommandOutcome::Succeeded),
            Err(err) if err.kind == GitErrorKind::Cancelled => (None, CommandOutcome::Cancelled),
            Err(err) => (err.exit_code, CommandOutcome::Failed(err.kind)),
        });
        result
    }

    fn record(&self, (exit_code, outcome): (Option<i32>, CommandOutcome)) {
        self.log.push(
            self.repo.clone(),
            self.display.clone(),
            self.started_at,
            self.started.elapsed(),
            exit_code,
            outcome,
        );
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
            self.record((None, CommandOutcome::Cancelled));
        }
    }
}
