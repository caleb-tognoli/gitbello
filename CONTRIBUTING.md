# Contributing to gitbello

gitbello is a fast, open-source, cross-platform Git GUI focused on working across many
repositories and worktrees. It is meant to replace GitHub Desktop and Fork for daily use.

- **App/UI:** Godot 4 (latest stable 4.x, pinned), typed GDScript, used as a thin view layer.
- **Core:** Rust, exposed to Godot through GDExtension using the `godot` crate (gdext).
- **Git:** the system `git` executable (CLI) behind a backend trait. `gix` may replace hot read paths later.
- **Targets:** Windows, Linux, macOS.

How it is built is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and how the workflows
behave in [docs/UX.md](docs/UX.md); features have their own docs in `docs/` (listed at
the end of ARCHITECTURE.md). Read the ones your change touches before starting it. The
golden rules in [AGENTS.md](AGENTS.md) (no Godot in the core, every git call through
`GitRunner`, never block the main thread, …) apply to every change, whoever writes it.

## Setting up

You need:

- **Rust** through [rustup](https://rustup.rs). `rust-toolchain.toml` pins the version
  (with rustfmt and clippy); rustup installs it the first time you build.
- **Godot 4.7.x**, the standard build (not .NET), the version in `GODOT_VERSION` of
  `.github/workflows/ci.yml`. The gdext `api-4-7` feature in `rust/Cargo.toml` and
  `config/features` in `godot/project.godot` must match it.
- **git 2.40** or newer on your `PATH`.

Point `GODOT` at the Godot executable, or put `godot` on your `PATH`:

```sh
export GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64
```

```powershell
$env:GODOT = "C:\path\to\Godot_v4.7.2-stable_win64_console.exe"
```

On Windows use the `_console.exe` build, so headless runs print to your terminal.

### Windows: the windows-gnu toolchain

gitbello builds with either Windows toolchain (`x86_64-pc-windows-msvc`, which CI uses,
or `x86_64-pc-windows-gnu`), and both must keep working. The windows-gnu toolchain cannot
link `raw-dylib` imports, so:

- Avoid crates that pull `windows-sys` 0.61+ or other `raw-dylib` imports. Check with
  `cargo tree -i windows-sys` (from `rust/`) after adding or updating a dependency.
- `winapi-util` is pinned to 0.1.9 in `Cargo.lock` for this reason: don't `cargo update`
  it, and update other crates by name (`cargo update -p <crate>`) rather than all at once.

To build with windows-gnu, make it rustup's default host; the pinned version then
installs for it:

```sh
rustup set default-host x86_64-pc-windows-gnu
```

## Building, running and testing

Everything runs through `cargo xtask`, from the repository root or `rust/`:

```
cargo xtask build            # build gdext (debug) and copy into godot/bin
cargo xtask build --release
cargo xtask run              # build + launch Godot project
cargo xtask test             # cargo test for the whole workspace
cargo xtask check            # fmt --check + clippy -D warnings + test
cargo xtask smoke [--only <name>]   # headless Godot smoke scripts (or those matching <name>)
cargo xtask bench-graph <repo> [--ui] [--record]   # graph load + scroll benchmark (read-only)
cargo xtask bless-highlight  # rewrite the syntax samples' expected tokens (review the diff)
```

`cargo xtask help` lists every task. Run `cargo xtask check` and `cargo xtask smoke`
before opening a pull request; CI runs both on Linux, Windows and macOS.

### Tests

- **Core:** every core feature gets tests against real temporary repositories built with
  the fixture helpers in `rust/crates/gitbello-core/tests/support`. Parsers get unit tests
  with captured git output. Never run state-changing git commands on a real repository
  (this one included) outside a temp dir; read-only commands are fine.
- **`gitbello-cli`:** a headless harness over the core, handy for checking logic without
  the UI, for example `gitbello-cli status <path>` or `gitbello-cli graph <path> --rows 0..50`.
  `gitbello-cli fixture <dir>` builds throwaway fixture repositories.
- **Smoke tests:** `godot/tests/smoke/*_smoke.gd` instantiate scenes, drive them with a
  fixture repository and assert on node state. `cargo xtask smoke` builds the library,
  imports the project headless, creates throwaway fixtures and a scratch config
  (`GITBELLO_CONFIG`), and runs them. Add one for each UI feature.
- **Visual and performance scripts:** `godot/tests/visual/` captures screenshots of a
  feature in both themes and `godot/tests/perf/` times hot paths. Each script's header
  says what it expects; [AGENTS.md](AGENTS.md) lists them all with their arguments.
  Run them on throwaway fixtures with `GITBELLO_CONFIG` set to a scratch file, never your
  real config. Attach the screenshots to UI pull requests.
- **Performance claims need numbers:** log timings and memory and put them in the pull
  request. `docs/perf.md` keeps the recorded benchmarks.

## Conventions

- **Rust:** edition 2021+, `rustfmt` defaults, `clippy -D warnings`. Use `thiserror` for errors in core and `anyhow` only in xtask and cli. No `unwrap()` outside tests.
- **GDScript:** typed only: every variable, parameter and return value is typed (the
  untyped-declaration warning is an error in project settings), and a change leaves no
  GDScript warnings. `snake_case` files and functions, `PascalCase` classes (`class_name`). One scene per feature component. Signals for upward communication, method calls for downward.
- **Theming:** no hardcoded colors or sizes in scenes. Use the theme and its type variations. The theme is built at runtime by `godot/app/theme/app_theme.gd` (one palette per theme plus the user's accent colour); add colours, sizes and variations there. Icons are SVGs in `godot/themes/icons/` drawn in the Godot editor's greys (`#e0e0e0`) and imported as `DPITexture` (copy an existing `.svg.import`), so the light theme can recolour them; get them with `AppTheme.icon(&"Name")`. An action's icon is set once, in `ActionRegistry.ICONS`; a button that runs an action takes it from there (`Actions.icon(id)`), so an operation shows the same icon in menus, the palette, toolbars and empty states. Keep `godot/themes/icons/LICENSES.md` up to date.
- **Localization:** every fixed user-facing string uses English as its translation key in `godot/localization/gitbello.csv` (English and Italian columns). Display it with `tr()`/`TranslationServer.translate()` and refresh dynamic controls on `NOTIFICATION_TRANSLATION_CHANGED`. Do not translate paths, refs, user content, Git commands/progress or raw stderr. `godot/app/localization/l10n.gd` applies the persisted language choice.
- **Actions:** every user-facing operation is an Action in the action registry (id,
  label, shortcut, enabled predicate); menus, context menus, shortcuts and the command
  palette all read from it.
- **Godot project settings** that must stay on: low processor mode, HiDPI, native file dialogs. See ARCHITECTURE §3.7.
- **Cross-platform:** use `gitbello_core::paths` for config and data dirs, keep paths as `PathBuf` in core, and test path handling with spaces and non-ASCII characters.
- **Dependencies:** keep them few, and keep them buildable on windows-gnu (see
  [above](#windows-the-windows-gnu-toolchain)). Open an issue before adding a crate or a
  Godot addon.
- **Docs:** keep `docs/` true to the code: when a feature changes, update its doc in the
  same change. Docs describe what is built, not plans. User-visible changes get a line in
  the `Unreleased` section of `CHANGELOG.md`.

## Repository layout

```
gitbello/
├─ AGENTS.md                  # rules for AI coding agents (imports this file)
├─ CONTRIBUTING.md
├─ docs/                      # ARCHITECTURE.md, UX.md, feature docs, perf.md
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
├─ packaging/                 # Windows installer, Linux launcher
└─ .github/                   # CI and release workflows, issue and PR templates
```

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org): `type(scope): summary`,
for example `feat(ui): show the summary's length past 50 characters` or
`fix(core): keep the stash order after a rename`.

- **Types:** `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `ci`, `chore`.
- **Scopes:** `core`, `gdext`, `cli`, `ui`, `xtask`, or leave it out.
- Keep the summary under 72 characters (50 reads best), in the imperative, without a
  final full stop. Explain why in the body when it isn't obvious.
- Make small, focused commits: one change each, each building and passing tests.

## Pull requests

1. For anything bigger than a fix, open an issue first so the approach can be agreed,
   especially new crates or addons, architecture changes (ARCHITECTURE.md) and changes to
   the interfaces between core, gdext and GDScript.
2. Branch from `main` and keep the pull request to one feature or fix. If it grows much
   larger than planned, split it.
3. Run `cargo xtask check` and `cargo xtask smoke`; both must pass.
4. Update the feature's doc in `docs/` and `CHANGELOG.md` when behaviour changes.
5. Open the pull request against `main` and fill in the template: what changed, how you
   tested it, and screenshots of both themes for UI changes.
6. CI must be green on all three platforms before review. Address review comments with
   new commits.

## Releases

Bump the version in `rust/Cargo.toml`, `godot/project.godot` and `godot/export_presets.cfg`, add its `CHANGELOG.md` section, then push a `v<version>` tag. `.github/workflows/release.yml` builds every platform and the Windows installer (`packaging/`) and attaches them to a draft release.

## Reporting bugs and ideas

Use the issue forms: **Bug report** asks for the version, OS, git version and steps;
**Feature request** for the problem and the workflow you have in mind. For a crash,
attach the Godot output (run from a terminal) if you can.

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
