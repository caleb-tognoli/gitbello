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
