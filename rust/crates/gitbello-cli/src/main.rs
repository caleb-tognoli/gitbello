//! Dev-only headless harness for `gitbello-core`.

use anyhow::{bail, Result};

const USAGE: &str = "usage: gitbello-cli <command>

commands:
  version    print the core version";

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("version" | "--version" | "-V") => {
            println!("gitbello-core {}", gitbello_core::VERSION);
            Ok(())
        }
        Some("help" | "--help" | "-h") | None => {
            println!("{USAGE}");
            Ok(())
        }
        Some(other) => bail!("unknown command `{other}`\n\n{USAGE}"),
    }
}
