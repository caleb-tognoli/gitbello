use std::process::Command;

fn cli() -> Command {
    Command::new(env!("CARGO_BIN_EXE_gitbello-cli"))
}

#[test]
fn version_prints_core_version() {
    let output = cli().arg("version").output().unwrap();
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains(gitbello_core::VERSION));
}

#[test]
fn unknown_command_fails() {
    let output = cli().arg("no-such-command").output().unwrap();
    assert!(!output.status.success());
}

/// A fresh repository in a temp dir with a space and non-ASCII in its path.
fn temp_repo(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("gitbello clï {name} {}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create temp dir");
    gitbello_core::git::GitRunner::discover()
        .expect("git on PATH")
        .write(&dir)
        .args(["init", "--quiet", "--initial-branch=main"])
        .run()
        .expect("git init");
    dir
}

#[test]
fn status_refs_worktrees_and_op_state_work_on_a_new_repo() {
    let repo = temp_repo("cmds");
    std::fs::write(repo.join("new file.txt"), "x").unwrap();
    let run = |cmd: &str| {
        let out = cli().arg(cmd).arg(&repo).output().unwrap();
        assert!(
            out.status.success(),
            "{cmd}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap()
    };
    let status = run("status");
    assert!(
        status.contains("On branch main (no commits yet)"),
        "{status}"
    );
    assert!(status.contains("new file.txt"), "{status}");
    assert!(run("worktrees").contains("main"));
    assert!(run("op-state").contains("operation   none"));
    assert!(run("stashes").contains("No stashes"));
    run("refs");
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn repo_commands_fail_outside_a_repository() {
    let dir = std::env::temp_dir();
    let out = cli()
        .args(["status"])
        .arg(dir.join("gitbello-definitely-missing"))
        .output()
        .unwrap();
    assert!(!out.status.success());
}
