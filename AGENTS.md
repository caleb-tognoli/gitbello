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
│  └─ themes/icons/           # SVG icons (Godot editor set + git icons), recoloured per theme
└─ .github/workflows/ci.yml
```

## Commands

```
cargo xtask build            # build gdext (debug) and copy into godot/bin
cargo xtask build --release
cargo xtask run              # build + launch Godot project
cargo xtask test             # cargo test for the whole workspace
cargo xtask check            # fmt --check + clippy -D warnings + test
cargo xtask smoke [--only <name>]   # headless Godot smoke scripts (or those matching <name>)
cargo xtask bench-graph <repo> [--ui] [--record]   # graph load + scroll benchmark (read-only)
```

Releases: bump the version in `rust/Cargo.toml`, `godot/project.godot` and `godot/export_presets.cfg`, add its `CHANGELOG.md` section, then push a `v<version>` tag. `.github/workflows/release.yml` builds every platform and the Windows installer (`packaging/`) and attaches them to a draft release.

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
- Commits are Caleb's alone: no `Co-Authored-By` or other AI attribution trailers in commit messages or PR descriptions.

## Conventions

- **Rust:** edition 2021+, `rustfmt` defaults, `clippy -D warnings`. Use `thiserror` for errors in core and `anyhow` only in xtask and cli. No `unwrap()` outside tests.
- **GDScript:** `snake_case` files and functions, `PascalCase` classes (`class_name`). One scene per feature component. Signals for upward communication, method calls for downward.
- **Theming:** no hardcoded colors or sizes in scenes. Use the theme and its type variations. The theme is built at runtime by `godot/app/theme/app_theme.gd` (one palette per theme plus the user's accent colour); add colours, sizes and variations there. Icons are SVGs in `godot/themes/icons/` drawn in the Godot editor's greys (`#e0e0e0`) and imported as `DPITexture` (copy an existing `.svg.import`), so the light theme can recolour them; get them with `AppTheme.icon(&"Name")`. Keep `godot/themes/icons/LICENSES.md` up to date.
- **Localization:** every fixed user-facing string uses English as its translation key in `godot/localization/gitbello.csv` (English and Italian columns). Display it with `tr()`/`TranslationServer.translate()` and refresh dynamic controls on `NOTIFICATION_TRANSLATION_CHANGED`. Do not translate paths, refs, user content, Git commands/progress or raw stderr. `godot/app/localization/l10n.gd` applies the persisted language choice.
- **Godot project settings** that must stay on: low processor mode, HiDPI, native file dialogs. See PLAN §3.7.
- **Cross-platform:** use `gitbello_core::paths` for config and data dirs, keep paths as `PathBuf` in core, and test path handling with spaces and non-ASCII characters.
- **Dependencies:** keep them few. Avoid crates that pull `windows-sys` 0.61+ (or other `raw-dylib` imports): the local windows-gnu toolchain cannot build them. `winapi-util` is pinned to 0.1.9 in `Cargo.lock` for this reason; don't `cargo update` it.

## Verifying work without seeing the UI

- Prefer testing logic in core (`cargo test`) or through `gitbello-cli`, for example `gitbello-cli status <path>` or `gitbello-cli graph <path> --rows 0..50`.
- For UI, write headless smoke scripts under `godot/tests/smoke/`, run with `cargo xtask smoke`. They instantiate scenes, drive them with a fixture repo, and assert on node state.
- `cargo xtask smoke` creates throwaway fixture repos (`gitbello-cli fixture`) and a scratch config (`GITBELLO_CONFIG`); smoke tests get them as `--fixtures=<dir>`. Never point tests at the real config.
- To look at the UI, run `res://tests/visual/shell_screenshots.tscn -- --repos=<a>;<b> --out=<dir>` (windowed, with `GITBELLO_CONFIG` set to a scratch file) and read the PNGs.
- `res://tests/visual/history_screenshots.tscn -- --fixtures=<CLI fixture dir> --out=<dir>` captures Current branch and All branches in dark/light themes. It fetches the fixture's local remote; use throwaway CLI fixtures and `GITBELLO_CONFIG=<fixtures>/config.toml` only.
- `res://tests/visual/worktree_row_screenshots.tscn -- --repo=<worktree of a throwaway repo with several worktrees> --out=<dir>` captures the worktree strip in both themes, hovered chips with their tooltip cards, the hovered New worktree button and the worktree list (read-only).
- `res://tests/visual/worktree_in_use_screenshots.tscn -- --repo=<CLI fixture repo-10> --out=<dir>` (Windows) deletes worktrees while a program runs from one and while a terminal sits in another: the in-use and folder-left toasts, their details and Try again. Adds and deletes worktrees: throwaway fixtures only, with `GITBELLO_CONFIG=<fixtures>/config.toml`.
- `gitbello-cli in-use <dir>` lists the programs running files from a folder (Windows; what blocks deleting a worktree).
- `res://tests/perf/diff_bench.tscn -- --repo=<root> --file=<path> [--no-minimap]` times diff loads, slice fetches, minimap tiles and overview, and paging (read-only).
- `res://tests/visual/diff_minimap_screenshots.tscn -- --repo=<repo with a long uncommitted change> --file=<its path> --conflict-repo=<repo in a conflicted merge> --conflict=<its path> --out=<dir>` captures the diff minimap: hunks, the whole file at the top and middle, lines left out, side by side, off, narrow, light, and the resolver (it changes the commit selection: throwaway repos only).
- `res://tests/visual/minimap_marks_screenshots.tscn -- --repo=<repo with a change spread through a long file> --file=<its path> --conflict-repo=<repo in a conflicted merge with three blocks> --conflict=<its path> --out=<dir>` captures the strip of a collapsed diff and the resolver after one block is chosen, each with a 3x crop of the minimap column (it writes the conflicted file: throwaway repos only).
- `res://tests/visual/word_tint_sheet.tscn -- --repo=<repo with word-level changes> --file=<its path> --out=<dir>` renders the same diff and minimap at several changed-word tints (`AppTheme.word_tint_percent`) in both themes, one sheet per theme (read-only).
- `res://tests/visual/change_colors_screenshots.tscn -- --repo=<repo with an uncommitted change> --file=<its path> --history-repo=<repo with a long history> --query=<text some subjects contain> --out=<dir>` captures a diff with the theme's and with chosen added/removed colours in both themes, Settings → Interface, and History's strip of search matches with a 3x crop (it saves colours to `GITBELLO_CONFIG`: use a scratch config; read-only on the repositories).
- `res://tests/visual/home_screenshots.tscn -- --repos=<a>;<b>;… --scan=<dir> --work=<dir> --out=<dir>` captures Home (empty, full, grouped, filtered, a missing folder, clones, the Add menu, the forms and a scan). It clones into `<work>`: throwaway repositories only, and `GITBELLO_CONFIG` in an empty folder.
- `gitbello-cli home-bench <dir>` times Home's scan and summaries (read-only).
- `res://tests/visual/merge_screenshots.tscn -- --repo=<throwaway repo with a conflicting topic branch> --out=<dir>` captures the merge dialog, the resolver and the undo strip (it merges: never point it at a real repository).
- `res://tests/visual/conflict_states_screenshots.tscn -- --repo=<a> --rebase-repo=<b> --out=<dir>` captures the cards of conflicts without text blocks, the Abort confirmation and the cherry-pick and rebase banners (see the script's header for the repos it expects; throwaway repos only).
- `res://tests/visual/view_switch_screenshots.tscn -- --repo=<CLI fixture repo-11> --out=<dir>` captures the header row with the Changes | History | Shelves switch in each view and theme, then at the minimum window width (read-only).
- `res://tests/visual/sync_button_screenshots.tscn -- --fixtures=<CLI fixture dir> --out=<dir>` captures the Sync button (push, menu, busy, sync) and the ahead/behind pills in the branch list, chip tooltip, "No local changes" and Home. It fetches `repo-8` and expects `repo-1` without changes (stash them first): throwaway CLI fixtures and `GITBELLO_CONFIG=<fixtures>/config.toml` only.
- `res://tests/visual/toast_flow_screenshots.tscn -- --repo=<CLI fixture repo-8> --out=<dir>` walks the toast rules in numbered shots: a commit (no toast), a discard (Undo), Copy hash, a fetch's progress, an error with a fix, the light theme and a burst. It commits, discards and fetches: throwaway fixtures only, with `GITBELLO_CONFIG=<fixtures>/config.toml`. Keep the fixture path short on Windows (the fixture's remote hits the path limit under deep temp folders).
- `res://tests/visual/readme_screenshots.tscn -- --repo=<throwaway repo with worktrees and an uncommitted change> --out=<dir>` captures the README's History and Changes shots in both themes (read-only); copy `changes_dark.png` and `changes_light.png` to `docs/screenshot.png` and `docs/screenshot-light.png`.
- Performance claims need numbers. Log timings and memory, and include them in the milestone summary.
