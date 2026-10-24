# gitbello

A fast, open-source, cross-platform Git GUI focused on working across many repositories and worktrees. It is meant to replace GitHub Desktop and Fork for daily use.

- **App/UI:** Godot 4 (latest stable 4.x, pinned), typed GDScript, used as a thin view layer.
- **Core:** Rust, exposed to Godot through GDExtension using the `godot` crate (gdext).
- **Git:** the system `git` executable (CLI) behind a backend trait. `gix` may replace hot read paths later.
- **Targets:** Windows, Linux, macOS.

The full design and milestone plan is in `docs/PLAN.md`. Read it before starting any milestone.

## Repository layout

```
gitbello/
├─ AGENTS.md
├─ docs/PLAN.md               # architecture + milestones (source of truth)
├─ rust/
│  ├─ Cargo.toml              # workspace
│  ├─ crates/
│  │  ├─ gitbello-core/       # pure Rust. NO godot dependency.
│  │  ├─ gitbello-gdext/      # cdylib: thin Godot bindings over core
│  │  └─ gitbello-cli/        # dev-only headless harness for core
│  └─ xtask/                  # build/copy/run tasks (cargo xtask ...)
├─ godot/
│  ├─ project.godot
│  ├─ gitbello.gdextension
│  ├─ bin/                    # built native libs (gitignored)
│  ├─ app/                    # scenes + scripts, grouped by feature
│  ├─ ui/                     # reusable controls (virtual list, graph, diff view)
│  └─ themes/                 # light.tres, dark.tres
└─ .github/workflows/ci.yml
```

## Commands

```
cargo xtask build            # build gdext (debug) and copy into godot/bin
cargo xtask build --release
cargo xtask run              # build + launch Godot project
cargo xtask test             # cargo test for the whole workspace
cargo xtask check            # fmt --check + clippy -D warnings + test
cargo xtask smoke            # headless Godot smoke scripts
cargo xtask bench-graph <repo> [--ui] [--record]   # graph load + scroll benchmark (read-only)
```

Run `cargo xtask check` before declaring any task done.

## Golden rules

1. **The core has no Godot dependency.** All git logic, parsing, models, graph layout, watching and job scheduling live in `gitbello-core`. `gitbello-gdext` only converts types and forwards calls. If you are writing logic in gdext or GDScript that could live in core, move it.
2. **Every git invocation goes through `GitRunner`.** Never call `std::process::Command::new("git")` anywhere else. The runner sets the environment, flags and Windows no-console flag (see PLAN §3.2).
3. **git must never prompt or open an editor.** Pass messages through `-F -` or stdin, use `--no-edit`, and set `GIT_TERMINAL_PROMPT=0`. Credentials are handled by the user's credential helper.
4. **Never block the Godot main thread.** All git work runs as jobs on core worker threads. Results come back through the event queue polled by `RepoSession` (PLAN §3.4).
5. **Writes to the same repository are serialized.** Reads may run concurrently. Status reads use `--no-optional-locks`.
6. **Keep large data in Rust.** Godot asks for visible slices (`get_rows(start, count)`). Never send a full history or a large diff to GDScript in one call.
7. **Every core feature gets tests** against real temporary repositories built with the fixture helpers in `gitbello-core/tests/support`. Parsers get unit tests with captured git output.
8. **Never run state-changing git commands on real repositories outside a temp dir** while developing or testing, including this repository's own repo. Only read-only commands are allowed on real repos (for example, the graph performance benchmark).
9. **Typed GDScript only.** Every variable, parameter and return value is typed. The untyped-declaration warning is set to error in project settings.
10. **Every user-facing operation is an Action** registered in the action registry (id, label, shortcut, enabled predicate). Menus, context menus, shortcuts and the command palette all read from the registry.

## Working agreement

- Work on one milestone at a time, in order, from `docs/PLAN.md`. Do not start the next milestone without approval.
- Keep the milestone checklist in `docs/PLAN.md` up to date as tasks are completed.
- Ask before adding a new crate or Godot addon, changing the architecture in PLAN, or changing public interfaces between core, gdext and GDScript.
- At the end of a milestone, stop and post a review summary covering:
  - what was built
  - how it was tested
  - known gaps
  - a manual test script for Caleb (step-by-step UI checks, since you cannot see the UI)
  - proposed adjustments to the next milestone
- If a task turns out much larger than planned, stop and propose a split instead of pushing through.
- Commit in small, focused commits using Conventional Commits (`feat(core): ...`, `fix(ui): ...`).

## Conventions

- **Rust:** edition 2021+, `rustfmt` defaults, `clippy -D warnings`. Use `thiserror` for errors in core and `anyhow` only in xtask and cli. No `unwrap()` outside tests.
- **GDScript:** `snake_case` files and functions, `PascalCase` classes (`class_name`). One scene per feature component. Signals for upward communication, method calls for downward.
- **Theming:** no hardcoded colors or sizes in scenes. Use the theme and its type variations.
- **Godot project settings** that must stay on: low processor mode, HiDPI, native file dialogs. See PLAN §3.7.
- **Cross-platform:** use `gitbello_core::paths` for config and data dirs, keep paths as `PathBuf` in core, and test path handling with spaces and non-ASCII characters.
- **Dependencies:** keep them few. Avoid crates that pull `windows-sys` 0.61+ (or other `raw-dylib` imports): the local windows-gnu toolchain cannot build them. `winapi-util` is pinned to 0.1.9 in `Cargo.lock` for this reason; don't `cargo update` it.

## Verifying work without seeing the UI

- Prefer testing logic in core (`cargo test`) or through `gitbello-cli`, for example `gitbello-cli status <path>` or `gitbello-cli graph <path> --rows 0..50`.
- For UI, write headless smoke scripts under `godot/tests/smoke/`, run with `cargo xtask smoke`. They instantiate scenes, drive them with a fixture repo, and assert on node state.
- `cargo xtask smoke` creates throwaway fixture repos (`gitbello-cli fixture`) and a scratch config (`GITBELLO_CONFIG`); smoke tests get them as `--fixtures=<dir>`. Never point tests at the real config.
- To look at the UI, run `res://tests/visual/shell_screenshots.tscn -- --repos=<a>;<b> --out=<dir>` (windowed, with `GITBELLO_CONFIG` set to a scratch file) and read the PNGs.
- Performance claims need numbers. Log timings and memory, and include them in the milestone summary.
