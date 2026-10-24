# gitbello

A fast, open-source, cross-platform Git GUI for people who work across many repositories and worktrees. Native Rust core, Godot 4 UI, system `git` underneath.

> **Status:** early development (milestone M0, skeleton). Not usable yet. See [docs/PLAN.md](docs/PLAN.md) for the design and roadmap.

## Building

Requirements:

- Rust via rustup (the pinned version in `rust-toolchain.toml` is installed automatically)
- Godot **4.7.x** (standard build, not .NET)
- git **2.40** or newer

Point `GODOT` at the Godot executable, or put `godot` on your `PATH`:

```sh
export GODOT=/path/to/Godot_v4.7.2-stable   # PowerShell: $env:GODOT = "C:\path\to\Godot_v4.7.2-stable_win64.exe"
```

Then, from the repository root:

```sh
cargo xtask run      # build the native library and launch the app
cargo xtask check    # fmt + clippy + tests
cargo xtask smoke    # headless Godot smoke tests
```

`cargo xtask help` lists every task.

## Layout

- `rust/crates/gitbello-core`: all git logic, models and scheduling (no Godot dependency)
- `rust/crates/gitbello-gdext`: thin GDExtension bindings
- `rust/crates/gitbello-cli`: headless dev harness for the core
- `rust/xtask`: build and test tasks
- `godot/`: the Godot project (typed GDScript UI)

Contributor and agent rules are in [AGENTS.md](AGENTS.md).

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in this project by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
