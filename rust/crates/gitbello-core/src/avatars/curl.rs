//! HTTP through the system `curl` (PLAN M7.10, decided 2026-11-07): the
//! only network access besides git. Windows 10+ and macOS ship curl and Git
//! for Windows bundles one; without it avatars stay initials.

use std::env;
use std::ffi::OsStr;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use thiserror::Error;

use crate::git::CancelToken;

/// How often a running request checks its cancel token.
const POLL: Duration = Duration::from_millis(20);

/// Ends `-w`'s trailer after the body: the status and content type follow it.
const TRAILER: &[u8] = b"\n\x1fgitbello-http\x1f";

/// Avatars are small; anything bigger is not one.
pub const MAX_BODY: u64 = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum HttpError {
    /// curl could not be started (missing).
    #[error("curl was not found: {0}")]
    NoCurl(String),
    /// No answer: offline, a name that does not resolve, a timeout, TLS.
    #[error("request failed: {0}")]
    Network(String),
    #[error("cancelled")]
    Cancelled,
}

/// An answer, whatever its status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    pub content_type: String,
    pub body: Vec<u8>,
}

/// The one place that spawns curl, with the same no-console, no-prompt and
/// cancel handling as `GitRunner`.
#[derive(Debug, Clone)]
pub struct CurlRunner {
    curl: PathBuf,
    timeout: Duration,
}

impl CurlRunner {
    /// curl on `PATH`, then where Windows and Git for Windows put it; `None`
    /// without one.
    pub fn discover() -> Option<Self> {
        let exe = format!("curl{}", env::consts::EXE_SUFFIX);
        let path = env::var_os("PATH").unwrap_or_default();
        env::split_paths(&path)
            .filter(|dir| !dir.as_os_str().is_empty())
            .map(|dir| dir.join(&exe))
            .chain(usual_curl_paths())
            .find(|candidate| candidate.is_file())
            .map(Self::with_executable)
    }

    pub fn with_executable(curl: impl Into<PathBuf>) -> Self {
        Self {
            curl: curl.into(),
            timeout: Duration::from_secs(15),
        }
    }

    /// The longest a request may take (connecting included).
    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn executable(&self) -> &Path {
        &self.curl
    }

    /// GETs `url`, following redirects. `headers` (`Name: value`) go
    /// through stdin, never the command line, so tokens do not show in
    /// process lists.
    pub fn get(
        &self,
        url: &str,
        headers: &[String],
        cancel: &CancelToken,
    ) -> Result<HttpResponse, HttpError> {
        let mut cmd = Command::new(&self.curl);
        // `-q` first: ignore the user's .curlrc.
        cmd.args(["-q", "-s", "-S", "-L", "--max-redirs", "5"])
            .args(["--proto", "=http,https", "--proto-redir", "=https"])
            .arg("--max-time")
            .arg(self.timeout.as_secs().max(1).to_string())
            .arg("--max-filesize")
            .arg(MAX_BODY.to_string())
            .args(["-o", "-", "-w"])
            .arg(trailer_format());
        if !headers.is_empty() {
            cmd.args(["-H", "@-"]);
        }
        cmd.arg("--").arg(url);
        let stdin = (!headers.is_empty()).then(|| {
            let mut text = headers.join("\n");
            text.push('\n');
            text.into_bytes()
        });
        let output = run(cmd, stdin, cancel, self.timeout + Duration::from_secs(5))?;
        if !output.success {
            return Err(HttpError::Network(
                String::from_utf8_lossy(&output.stderr).trim().to_string(),
            ));
        }
        parse_output(output.stdout)
            .ok_or_else(|| HttpError::Network("unexpected curl output".into()))
    }
}

/// `-w`'s format: the trailer, then `<status> <content type>`.
fn trailer_format() -> String {
    let mut format = String::from_utf8_lossy(TRAILER).into_owned();
    format.push_str("%{http_code} %{content_type}");
    format
}

/// Splits curl's stdout into the body and the `-w` trailer.
fn parse_output(mut stdout: Vec<u8>) -> Option<HttpResponse> {
    let at = stdout
        .windows(TRAILER.len())
        .rposition(|window| window == TRAILER)?;
    let trailer = String::from_utf8_lossy(&stdout[at + TRAILER.len()..]).into_owned();
    stdout.truncate(at);
    let (status, content_type) = trailer.split_once(' ').unwrap_or((&trailer, ""));
    Some(HttpResponse {
        status: status.trim().parse().ok()?,
        content_type: content_type.trim().to_ascii_lowercase(),
        body: stdout,
    })
}

/// What a helper process printed.
pub(crate) struct ToolOutput {
    pub success: bool,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// Runs `cmd` without a console window or a prompt, killing it when
/// `cancel` is set or after `limit`.
pub(crate) fn run(
    mut cmd: Command,
    stdin: Option<Vec<u8>>,
    cancel: &CancelToken,
    limit: Duration,
) -> Result<ToolOutput, HttpError> {
    cmd.stdin(if stdin.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    })
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .env("GIT_TERMINAL_PROMPT", "0")
    .env("GH_PROMPT_DISABLED", "1");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let program = cmd.get_program().to_string_lossy().into_owned();
    let mut child = cmd.spawn().map_err(|err| match err.kind() {
        io::ErrorKind::NotFound => HttpError::NoCurl(program.clone()),
        _ => HttpError::Network(format!("{program}: {err}")),
    })?;
    if let (Some(data), Some(mut pipe)) = (stdin, child.stdin.take()) {
        thread::spawn(move || {
            let _ = pipe.write_all(&data);
        });
    }
    let stdout = reader(child.stdout.take());
    let stderr = reader(child.stderr.take());
    let started = Instant::now();
    let status = loop {
        if cancel.is_cancelled() {
            kill(&mut child);
            return Err(HttpError::Cancelled);
        }
        if started.elapsed() > limit {
            kill(&mut child);
            return Err(HttpError::Network(format!("{program} timed out")));
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => thread::sleep(POLL),
            Err(err) => return Err(HttpError::Network(err.to_string())),
        }
    };
    Ok(ToolOutput {
        success: status.success(),
        stdout: join(stdout),
        stderr: join(stderr),
    })
}

fn reader(pipe: Option<impl Read + Send + 'static>) -> Option<JoinHandle<Vec<u8>>> {
    pipe.map(|mut pipe| {
        thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = pipe.read_to_end(&mut buf);
            buf
        })
    })
}

fn join(handle: Option<JoinHandle<Vec<u8>>>) -> Vec<u8> {
    handle
        .and_then(|handle| handle.join().ok())
        .unwrap_or_default()
}

fn kill(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// Where Windows and Git for Windows put curl.
fn usual_curl_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if cfg!(windows) {
        if let Some(root) = env::var_os("SystemRoot") {
            paths.push(PathBuf::from(root).join("System32").join("curl.exe"));
        }
        for (var, sub) in [("ProgramFiles", "Git"), ("LOCALAPPDATA", "Programs/Git")] {
            if let Some(base) = env::var_os(var) {
                let git = PathBuf::from(base).join(sub);
                paths.push(git.join("mingw64").join("bin").join("curl.exe"));
            }
        }
    } else {
        paths.push(PathBuf::from("/usr/bin/curl"));
    }
    paths
}

/// `program` found on `PATH` (for helpers such as `gh`).
pub(crate) fn find_on_path(program: &str) -> Option<PathBuf> {
    let exe = format!("{program}{}", env::consts::EXE_SUFFIX);
    let path = env::var_os("PATH").unwrap_or_default();
    env::split_paths(&path)
        .filter(|dir| !dir.as_os_str().is_empty())
        .map(|dir| dir.join(OsStr::new(&exe)))
        .find(|candidate| candidate.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_splits_at_the_last_trailer() {
        let mut stdout = b"PNG\nbody with a newline".to_vec();
        stdout.extend_from_slice(TRAILER);
        stdout.extend_from_slice(b"200 image/PNG");
        let response = parse_output(stdout).unwrap();
        assert_eq!(response.status, 200);
        assert_eq!(response.content_type, "image/png");
        assert_eq!(response.body, b"PNG\nbody with a newline");
    }

    #[test]
    fn output_without_a_content_type_or_trailer() {
        let mut stdout = TRAILER.to_vec();
        stdout.extend_from_slice(b"404 ");
        let response = parse_output(stdout).unwrap();
        assert_eq!((response.status, response.content_type.as_str()), (404, ""));
        assert!(response.body.is_empty());
        assert!(parse_output(b"no trailer".to_vec()).is_none());
    }
}
