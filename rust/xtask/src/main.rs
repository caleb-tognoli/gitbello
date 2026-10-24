//! Project tasks: `cargo xtask <command>`. Run `cargo xtask help` for the list.

use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};

const USAGE: &str = "usage: cargo xtask <command> [options]

commands:
  build [--release]       build gitbello-gdext and copy it into godot/bin
  run [--release] [-- <godot args>]
                          build, then launch the Godot project
  test [<cargo args>]     cargo test for the whole workspace
  check                   fmt --check + clippy -D warnings + test
  smoke                   build, import, then run headless Godot smoke tests
  bench-graph <path> [--ui] [--record]
                          time a graph load of <path> (read-only); --ui adds the
                          windowed scroll benchmark; --record appends to docs/perf.md

environment:
  GODOT                   path to the Godot executable (default: `godot` on PATH)";

/// Godot minor version the project and the gdext `api-*` feature target.
const GODOT_VERSION: &str = "4.7";

/// Printed by the smoke runner when every test passed.
const SMOKE_PASS_MARKER: &str = "SMOKE PASSED";

/// Output fragments that fail a smoke run even when Godot exits with 0.
const SMOKE_FAIL_MARKERS: &[&str] = &["SCRIPT ERROR", "Parse Error", "ERROR:"];

const SMOKE_TIMEOUT: Duration = Duration::from_secs(180);

fn main() -> Result<()> {
    let args: Vec<String> = env::args().skip(1).collect();
    let Some((command, rest)) = args.split_first() else {
        println!("{USAGE}");
        return Ok(());
    };
    match command.as_str() {
        "build" => build(Profile::from_args(rest)?),
        "run" => run(rest),
        "test" => cargo_test(rest),
        "check" => check(),
        "smoke" => smoke(),
        "bench-graph" => bench_graph(rest),
        "help" | "--help" | "-h" => {
            println!("{USAGE}");
            Ok(())
        }
        other => bail!("unknown command `{other}`\n\n{USAGE}"),
    }
}

#[derive(Clone, Copy)]
enum Profile {
    Debug,
    Release,
}

impl Profile {
    fn from_args(args: &[String]) -> Result<Self> {
        let mut profile = Profile::Debug;
        for arg in args {
            match arg.as_str() {
                "--release" | "-r" => profile = Profile::Release,
                other => bail!("unexpected argument `{other}`"),
            }
        }
        Ok(profile)
    }

    fn dir_name(self) -> &'static str {
        match self {
            Profile::Debug => "debug",
            Profile::Release => "release",
        }
    }
}

/// `rust/` (the Cargo workspace root).
fn workspace_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from(".."))
}

/// The repository root.
fn repo_dir() -> PathBuf {
    let workspace = workspace_dir();
    workspace
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or(workspace)
}

fn godot_project_dir() -> PathBuf {
    repo_dir().join("godot")
}

fn target_dir() -> PathBuf {
    env::var_os("CARGO_TARGET_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| workspace_dir().join("target"))
}

fn cargo() -> Command {
    let mut cmd = Command::new(env::var_os("CARGO").unwrap_or_else(|| OsString::from("cargo")));
    cmd.current_dir(workspace_dir());
    cmd
}

fn run_status(mut cmd: Command) -> Result<()> {
    let display = format!("{cmd:?}");
    eprintln!("$ {display}");
    let status = cmd
        .status()
        .with_context(|| format!("failed to start {display}"))?;
    if !status.success() {
        bail!("command failed ({status}): {display}");
    }
    Ok(())
}

fn build(profile: Profile) -> Result<()> {
    let mut cmd = cargo();
    cmd.args(["build", "--package", "gitbello-gdext"]);
    if let Profile::Release = profile {
        cmd.arg("--release");
    }
    run_status(cmd)?;

    let lib_name = format!(
        "{}gitbello_gdext{}",
        env::consts::DLL_PREFIX,
        env::consts::DLL_SUFFIX
    );
    let source = target_dir().join(profile.dir_name()).join(&lib_name);
    let dest_dir = godot_project_dir()
        .join("bin")
        .join(env::consts::OS)
        .join(profile.dir_name());
    fs::create_dir_all(&dest_dir)
        .with_context(|| format!("failed to create {}", dest_dir.display()))?;
    let dest = dest_dir.join(&lib_name);
    fs::copy(&source, &dest).with_context(|| {
        format!(
            "failed to copy {} to {} (is Godot holding the library open?)",
            source.display(),
            dest.display()
        )
    })?;
    eprintln!("copied {}", dest.display());
    Ok(())
}

fn run(args: &[String]) -> Result<()> {
    let (own, godot_args) = match args.iter().position(|a| a == "--") {
        Some(i) => (&args[..i], &args[i + 1..]),
        None => (args, &[][..]),
    };
    build(Profile::from_args(own)?)?;
    let godot = find_godot()?;
    if !godot_project_dir().join(".godot").exists() {
        import(&godot)?;
    }
    let mut cmd = Command::new(&godot);
    cmd.arg("--path").arg(godot_project_dir()).args(godot_args);
    run_status(cmd)
}

fn cargo_test(args: &[String]) -> Result<()> {
    let mut cmd = cargo();
    cmd.args(["test", "--workspace"]).args(args);
    run_status(cmd)
}

fn check() -> Result<()> {
    let mut fmt = cargo();
    fmt.args(["fmt", "--all", "--", "--check"]);
    run_status(fmt)?;

    let mut clippy = cargo();
    clippy.args([
        "clippy",
        "--workspace",
        "--all-targets",
        "--",
        "-D",
        "warnings",
    ]);
    run_status(clippy)?;

    cargo_test(&[])
}

fn smoke() -> Result<()> {
    build(Profile::Debug)?;
    let godot = find_godot()?;
    import(&godot)?;

    let mut cmd = Command::new(&godot);
    cmd.arg("--headless")
        .arg("--path")
        .arg(godot_project_dir())
        .arg("res://tests/smoke/smoke_runner.tscn");
    let output = run_captured(cmd, SMOKE_TIMEOUT)?;

    let failure = if output.timed_out {
        Some(format!(
            "smoke runner timed out after {}s",
            SMOKE_TIMEOUT.as_secs()
        ))
    } else if let Some(marker) = SMOKE_FAIL_MARKERS
        .iter()
        .find(|marker| output.text.contains(**marker))
    {
        Some(format!("smoke tests reported `{marker}`"))
    } else if !output.success {
        Some("smoke runner exited with failure".to_owned())
    } else if !output.text.contains(SMOKE_PASS_MARKER) {
        Some(format!("smoke runner did not print `{SMOKE_PASS_MARKER}`"))
    } else {
        None
    };
    match failure {
        Some(reason) => {
            annotate_failure(&reason, &output.text);
            bail!("{reason}")
        }
        None => Ok(()),
    }
}

/// On GitHub Actions, repeats the interesting output lines as an error
/// annotation so failures are readable without opening the job log.
fn annotate_failure(reason: &str, text: &str) {
    if env::var("GITHUB_ACTIONS").as_deref() != Ok("true") {
        return;
    }
    let lines: Vec<&str> = text.lines().collect();
    let mut picked: Vec<&str> = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let interesting = SMOKE_FAIL_MARKERS.iter().any(|m| line.contains(m))
            || line.starts_with("FAIL")
            || line.starts_with("  - ");
        if interesting {
            // Keep a little context (Godot prints the location on the next lines).
            picked.extend(lines.iter().skip(i).take(3));
        }
    }
    if picked.is_empty() {
        picked = lines.iter().rev().take(30).rev().copied().collect();
    }
    picked.dedup();
    picked.truncate(60);
    let body = picked.join("\n");
    let escape = |s: &str| {
        s.replace('%', "%25")
            .replace('\r', "%0D")
            .replace('\n', "%0A")
    };
    println!("::error title={}::{}", escape(reason), escape(&body));
}

fn bench_graph(args: &[String]) -> Result<()> {
    let mut path = None;
    let (mut ui, mut record) = (false, false);
    for arg in args {
        match arg.as_str() {
            "--ui" => ui = true,
            "--record" => record = true,
            other if path.is_none() => path = Some(other.to_owned()),
            other => bail!("unexpected argument `{other}`"),
        }
    }
    let path = path.context("bench-graph needs a repository path")?;

    let mut cli_build = cargo();
    cli_build.args(["build", "--release", "--package", "gitbello-cli"]);
    run_status(cli_build)?;
    let cli = target_dir()
        .join("release")
        .join(format!("gitbello-cli{}", env::consts::EXE_SUFFIX));
    let mut cmd = Command::new(cli);
    cmd.args(["graph-bench", &path]);
    let core = run_captured(cmd, SMOKE_TIMEOUT)?;
    if !core.success {
        bail!("graph-bench failed");
    }
    let mut report = core.text.trim_end().to_owned();

    if ui {
        build(Profile::Debug)?;
        let godot = find_godot()?;
        if !godot_project_dir().join(".godot").exists() {
            import(&godot)?;
        }
        let mut cmd = Command::new(&godot);
        cmd.arg("--path")
            .arg(godot_project_dir())
            .arg("res://tests/perf/scroll_bench.tscn")
            .arg("--")
            .arg(format!("--repo={path}"));
        let output = run_captured(cmd, SMOKE_TIMEOUT)?;
        let lines: Vec<&str> = output
            .text
            .lines()
            .filter_map(|line| line.strip_prefix("BENCH "))
            .collect();
        if !output.success || lines.is_empty() {
            bail!("scroll benchmark failed");
        }
        report.push_str(
            "

scroll benchmark (Godot ",
        );
        report.push_str(&godot_version(&godot));
        report.push_str(
            ", debug library)
",
        );
        report.push_str(&lines.join(
            "
",
        ));
    }

    if record {
        let perf = repo_dir().join("docs").join("perf.md");
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&perf)
            .with_context(|| format!("failed to open {}", perf.display()))?;
        let threads = thread::available_parallelism().map_or(0, usize::from);
        let cpu = env::var("PROCESSOR_IDENTIFIER").unwrap_or_default();
        writeln!(
            file,
            "
### {} · {} {} · {threads} threads {cpu}

```text
{report}
```",
            today(),
            env::consts::OS,
            env::consts::ARCH,
        )?;
        eprintln!("appended to {}", perf.display());
    }
    Ok(())
}

fn godot_version(godot: &Path) -> String {
    Command::new(godot)
        .arg("--version")
        .output()
        .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
        .unwrap_or_default()
}

/// Today's UTC date as `YYYY-MM-DD` (civil-from-days, H. Hinnant).
fn today() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let days = i64::try_from(secs / 86_400).unwrap_or(0) + 719_468;
    let era = days.div_euclid(146_097);
    let doe = days.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}

/// Runs a headless editor import so the class cache and extension list exist.
fn import(godot: &Path) -> Result<()> {
    let import_cmd = || {
        let mut cmd = Command::new(godot);
        cmd.arg("--headless")
            .arg("--path")
            .arg(godot_project_dir())
            .arg("--import");
        cmd
    };
    let first_import = !godot_project_dir()
        .join(".godot")
        .join("extension_list.cfg")
        .exists();
    let mut output = run_captured(import_cmd(), SMOKE_TIMEOUT)?;
    if !output.success && first_import {
        // Godot 4.7.1 crashes on exit from the import that first discovers the
        // extension (also with a minimal project). The next import is clean.
        eprintln!("note: first-time import crashed on exit; retrying once");
        output = run_captured(import_cmd(), SMOKE_TIMEOUT)?;
    }
    if !output.success {
        annotate_failure("Godot import failed", &output.text);
        bail!("Godot import failed");
    }
    if let Some(marker) = ["SCRIPT ERROR", "Parse Error"]
        .iter()
        .find(|marker| output.text.contains(**marker))
    {
        bail!("Godot import reported `{marker}`");
    }
    Ok(())
}

fn find_godot() -> Result<PathBuf> {
    let godot = match env::var_os("GODOT") {
        Some(path) => PathBuf::from(path),
        None => find_on_path(&["godot", "godot4"])
            .context("Godot not found: set GODOT to the Godot executable or put `godot` on PATH")?,
    };
    let output = Command::new(&godot)
        .arg("--version")
        .output()
        .with_context(|| format!("failed to run {} --version", godot.display()))?;
    let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !version.starts_with(&format!("{GODOT_VERSION}.")) {
        eprintln!(
            "warning: Godot {version} found at {}; the project targets {GODOT_VERSION}.x",
            godot.display()
        );
    }
    Ok(godot)
}

fn find_on_path(names: &[&str]) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    env::split_paths(&path).find_map(|dir| {
        names.iter().find_map(|name| {
            let candidate = dir.join(format!("{name}{}", env::consts::EXE_SUFFIX));
            candidate.is_file().then_some(candidate)
        })
    })
}

struct Captured {
    success: bool,
    timed_out: bool,
    /// stdout followed by stderr.
    text: String,
}

/// Runs `cmd`, echoing and capturing its output, and kills it after `timeout`.
fn run_captured(mut cmd: Command, timeout: Duration) -> Result<Captured> {
    let display = format!("{cmd:?}");
    eprintln!("$ {display}");
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to start {display}"))?;

    let stdout = child.stdout.take().map(|s| thread::spawn(move || tee(s)));
    let stderr = child.stderr.take().map(|s| thread::spawn(move || tee(s)));

    let started = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if started.elapsed() > timeout {
            child.kill().ok();
            eprintln!("timed out after {}s: {display}", timeout.as_secs());
            break child.wait()?;
        }
        thread::sleep(Duration::from_millis(50));
    };
    let timed_out = started.elapsed() > timeout;

    let mut text = String::new();
    for handle in [stdout, stderr].into_iter().flatten() {
        text.push_str(&handle.join().unwrap_or_default());
    }
    Ok(Captured {
        success: status.success() && !timed_out,
        timed_out,
        text,
    })
}

/// Copies a child stream to our stderr while collecting it.
fn tee(mut stream: impl Read) -> String {
    let mut collected = Vec::new();
    let mut buf = [0u8; 8192];
    loop {
        match stream.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let chunk = &buf[..n];
                std::io::stderr().write_all(chunk).ok();
                collected.extend_from_slice(chunk);
            }
        }
    }
    String::from_utf8_lossy(&collected).into_owned()
}
