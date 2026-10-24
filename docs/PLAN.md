# gitbello — architecture and plan

Status: **planning** · Owner: Caleb · Budget: ~20 h/week · Workflow: milestone by milestone with review

---

## 1. Vision and scope

gitbello is a lightweight, native-feeling Git GUI for people who juggle many repositories and worktrees every day. Its main differentiators over GitHub Desktop and Fork are:

- **Repos and worktrees as first-class citizens.** Each repo opens in a tab, with its worktrees nested in the sidebar and live status everywhere.
- **A clean, uncluttered UI.** Balanced density, keyboard-friendly, with a command palette for everything.
- **Better workflows** for merge (conflict preview before merging), stash and new-task creation.
- **Light editing.** Edit the working copy directly from the diff viewer.
- **Fast and idle-quiet.** Native Rust core and a Godot UI that redraws only when needed.

### In scope (v1)

File, hunk and line staging · commit and amend · fetch, pull and push · branches · tags · stash · history graph · diff viewer with editing · blame and file history · conflict resolver · cherry-pick · worktrees (nested, new task, path convention, cleanup) · command palette · live status badges and auto-fetch · custom actions · undo via operation log · integrated terminal (late milestone).

### Out of scope (v1)

GitHub, GitLab or any hosting integration (gitbello is pure git) · interactive rebase · submodule management (display only) · LFS management (it works transparently through git) · bundled git · auto-update.

---

## 2. Decisions

| # | Decision | Choice |
|---|---|---|
| D1 | UI framework | Godot 4, latest stable 4.x, pinned in `project.godot` and CI (currently **4.7**; CI uses 4.7.2; gdext `godot = "=0.5.5"` with `api-4-7`) |
| D2 | UI language | Typed GDScript, thin view only |
| D3 | Native layer | Rust through gdext (`godot` crate, pinned version) |
| D4 | Git access | System `git` CLI behind a `GitBackend` trait; `gix` for hot reads later |
| D5 | Minimum git | **2.40** (needs `worktree list -z`, `merge-tree --write-tree`); checked at startup |
| D6 | Multi-project model | One tab per repo; worktrees nested in the repo's sidebar and can be opened as their own tab |
| D7 | Themes | Light and dark Godot themes, follow the OS setting |
| D8 | Testing | Rust core tests on temp repos, parser unit tests, headless Godot smoke tests |
| D9 | Distribution | Open source on GitHub |

### Open decisions (Caleb to confirm)

- ~~**O1 License.**~~ **Decided: MIT OR Apache-2.0** (2026-10-24).
- **O2 Terminal approach** (M10). A full embedded terminal or "open system terminal here". See §3.13.
- **O3 Default worktree path template.** Suggested: `{repo_parent}/{repo_name}.worktrees/{branch_slug}`.

---

## 3. Architecture

### 3.1 Layers

```
┌──────────────────────────────────────────────────────────┐
│ Godot (typed GDScript)                                   │
│  App shell · tabs · sidebar · panels · ActionRegistry    │
│  Custom controls: VirtualList, GraphView, DiffView       │
└──────────────▲──────────────────────────┬────────────────┘
               │ signals (events)         │ #[func] calls
┌──────────────┴──────────────────────────▼────────────────┐
│ gitbello-gdext (cdylib) — type conversion only           │
│  RepoSession (Node) · AppCore (singleton) · converters   │
└──────────────▲──────────────────────────┬────────────────┘
               │ Event channel            │ Rust API
┌──────────────┴──────────────────────────▼────────────────┐
│ gitbello-core (pure Rust)                                │
│  JobScheduler · RepoState · Watcher · GraphIndex         │
│  Operations (stage, commit, fetch…) · OpLog · Config     │
│  GitBackend trait → CliBackend (→ GixBackend later)      │
│  GitRunner (process spawning, env, parsing helpers)      │
└──────────────────────────────────────────────────────────┘
```

`gitbello-cli` links `gitbello-core` directly for headless testing and debugging.

### 3.2 GitRunner

There is one place that spawns git processes. Every call goes through it.

- It resolves the git binary once (PATH, plus an override in settings), runs `git --version`, and refuses to open repos if the version is below the minimum.
- **Environment** for every call:
  - `GIT_TERMINAL_PROMPT=0`
  - `GIT_OPTIONAL_LOCKS=0` for read jobs
  - `LC_ALL=C` and `LANG=C` so error parsing is stable
  - `GIT_PAGER=cat`
  - a no-op `GIT_EDITOR` to guard against stray editor launches
- **Global flags:** `-c core.quotepath=false -c color.ui=false`. Use `-z` output formats wherever git supports them.
- **Windows:** set `CREATE_NO_WINDOW` (0x08000000) through `CommandExt::creation_flags`.
- **Streaming mode** for long output (log, diff): it reads stdout incrementally. **Progress mode** for fetch, pull and push: it parses `--progress` lines from stderr into progress events.
- **Cancellation:** each running process is tied to a `CancelToken` and is killed on cancel.
- **Errors:** each call returns a `GitError { command, exit_code, stderr, kind }`, where `kind` is classified (auth failed, non-fast-forward, conflict, lock exists, not a repo, and so on) so the UI can offer specific fixes.
- **Logging:** every command, its duration and exit code go into an in-app "Git log" panel. This helps both debugging and user trust.

### 3.3 Backend and models

`GitBackend` is a trait with read operations (status, refs, worktrees, log stream, diff, blame, show, stash list, merge preview) and write operations (stage patch, commit, checkout, branch ops, fetch/pull/push, stash ops, worktree ops, cherry-pick, merge, conflict resolution). `CliBackend` implements all of it.

The main parsing sources are:

| Data | Command |
|---|---|
| Status | `git status --porcelain=v2 -z --branch --show-stash` |
| Refs | `git for-each-ref --format=...` with NUL-separated fields (includes upstream, ahead/behind via `%(upstream:track)`) |
| Worktrees | `git worktree list --porcelain -z` |
| Log | `git log --all --topo-order -z --format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s` (streamed) |
| In-progress operation | presence of `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REBASE_HEAD` and `rebase-merge/` in the git dir (`git rev-parse --git-dir`, `--git-common-dir`) |

Models (`RepoStatus`, `FileChange`, `Ref`, `Worktree`, `Commit`, `Hunk`, `StashEntry`, `OperationState`) are plain Rust structs in core. gdext converts them to `Dictionary` or packed arrays only at the boundary.

### 3.4 Jobs and events

- `JobScheduler` runs a small pool of worker threads (std threads, `Mutex` + `Condvar` queue and an `mpsc` event channel; no async runtime or extra crates).
- Each repo has a **write queue** (FIFO, one at a time). Reads run on the shared pool. A read that would race with a queued write waits until the write is done.
- Jobs report `Started`, `Progress`, `Finished(Result)` and `Cancelled` through one `Event` channel per `AppCore`.
- After any write, the scheduler automatically queues a targeted refresh. For example, a commit refreshes status, refs and the graph head; staging refreshes only status and the affected diff.
- **Coalescing:** duplicate pending refreshes of the same kind collapse into one.

### 3.5 Godot boundary

- `AppCore` is an autoload singleton. It owns the core runtime, drains the event channel in `_process`, and routes events to the right `RepoSession`.
- `RepoSession` is a Node, one per open repo or worktree tab. It exposes:
  - **Queries** returning small data: `status()`, `refs()`, `worktrees()`, `operation_state()`.
  - **Slice queries:** `graph_row_count()`, `graph_rows(start, count)` (commit fields plus lane data), and `diff_lines(file_id, start, count)`.
  - **Commands** that return a job id: `stage_hunk(...)`, `commit(...)`, `fetch()`, and so on.
  - **Signals:** `status_changed`, `refs_changed`, `graph_changed(range)`, `job_progress(id, pct, text)`, `job_finished(id, ok, error_dict)`.
- When nothing is changing, `_process` should do almost nothing. The event drain is a cheap `try_recv` loop.

### 3.6 Watching and refresh

- Use `notify` with gitbello's own per-repository debouncer (250 ms quiet, 1 s at most) on each open worktree directory and its git dir. Watch the common dir for refs.
- Ignore `objects/` churn and any path git would ignore. Status does the real work, and the watcher only decides whether a status refresh is needed.
- **Window focus in** (`NOTIFICATION_APPLICATION_FOCUS_IN`) triggers a cheap refresh of the active tab as a reliable fallback.
- **Auto-fetch:** a configurable interval (default 10 min, off for metered connections later). It runs with `--prune`, staggered across repos, and never runs while a write is in progress.

### 3.7 Godot app structure and settings

- **Project settings:**
  - `application/run/low_processor_mode = true`
  - HiDPI enabled
  - native file dialogs on
  - the untyped-declaration GDScript warning set to **error**
  - a sensible minimum window size
- **Custom controls** (in `godot/ui/`):
  - **`VirtualList`:** draws only visible rows with `_draw()`, handles selection, keyboard navigation, multi-select and context menus. It is the base for the commit list, file lists and the blame gutter.
  - **`GraphView`:** draws lanes and nodes for visible rows from the lane data supplied by core. It is combined with the commit list inside one scroll container.
  - **`DiffView`:** unified and side-by-side views with hunk and line selection gutters, intra-line highlights, and an editable working-copy side (§3.10). It wraps `CodeEdit` where possible.
- **`ActionRegistry`** (autoload). Every action is `{ id, label, category, shortcut, enabled: Callable, run: Callable }`. The command palette fuzzy-searches it, menus and context menus are built from it, and shortcuts are rebindable.
- **Theming:** `themes/light.tres` and `themes/dark.tres` share type variations. The app follows `DisplayServer.is_dark_mode()` and reacts to changes (use the system theme change callback if the pinned Godot version provides it; otherwise re-check on focus-in).
- **Export:** use custom export templates built with 3D and unneeded modules disabled to shrink the binary (M11).

### 3.8 Config and persistence

- User config lives in the OS config dir (`gitbello_core::paths`, written by hand; the `directories` crate's Windows dependency does not build on the GNU toolchain) as TOML:
  - known repos
  - open tabs and their layout
  - worktree path template
  - editor command (default `code {path}`)
  - terminal command
  - auto-fetch interval
  - keybindings
  - theme override
- Per-repo user state (last selected branch, panel sizes) is stored in the app's data dir, keyed by the repo's canonical path. **Never write to the user's repo**, except the optional repo-shared `.gitbello/actions.toml` that users create themselves.

### 3.9 History graph

- Stream `git log` in topological order, parsing commits as they arrive. Build a compact `GraphIndex` with commit table, parent indices and ref decorations.
- **Lane assignment** happens incrementally in core: a standard "active lanes" algorithm that assigns each commit a column and emits edge segments per row. Godot receives per-row `{column, color_idx, segments[]}`.
- **Memory target:** under 150 bytes per commit in the index, excluding strings. Interned author names and subjects are stored in an arena.
- **Performance targets** (M1 acceptance): about 80k commits (the `git/git` repo) fully indexed in under 2 s on a modern machine. The first screen appears within 300 ms (stream the first page). Scrolling holds 60 fps with no dropped frames. Idle CPU stays near 0%.

### 3.10 Diff, staging and editing

- Diffs come from git (`git diff`, `git diff --cached`, `git show`), parsed into hunks and lines in core.
- **Hunk and line staging:** build a minimal patch from the selected lines (recomputing hunk headers) and apply it with `git apply --cached --recount`. Unstaging uses `-R`. Discarding a selection applies the reverse patch to the working tree, after a confirmation.
- **Editing in the diff viewer:** the working-copy side is editable. While the user types, core re-diffs the buffer against the index version in memory using `imara-diff`, so the view updates live without touching disk. Save writes the file, then the watcher confirms and git becomes authoritative again. Unsaved buffers are protected on tab close or refresh, and if the file changes on disk while dirty, the user is asked to reload or keep their version.
- **Large or binary files:** above a size threshold, show a summary with a "load anyway" option. Binary files show a size and type summary only.

### 3.11 Undo (operation log)

- Before each undoable operation, core records an `OpLogEntry` with the HEAD, the affected refs (old to new), the stash list head, and a description.
- **Undoable:** commit, amend, branch create, delete or rename, checkout, cherry-pick, merge (before push), stash drop (the dropped commit is kept), and reset.
- **Undo** restores the refs (`git update-ref` with the expected old value as a safety check). It refuses if the working tree is dirty and something would be overwritten, offering to stash first.
- **Never undoable:** anything already pushed (warn instead), and changes to working-tree files that git never stored.
- The reflog is the fallback: an "advanced restore" view lists recent reflog entries.

### 3.12 Custom actions

- Actions are defined in user config (global or per repo) and optionally in a repo's `.gitbello/actions.toml`.
- Each action has a `name`, `command`, `cwd` (repo, worktree or file dir), `confirm`, and `show_output`.
- **Variables:** `{repo}`, `{worktree}`, `{branch}`, `{file}`, `{commit}`.
- Actions are registered in the `ActionRegistry`, so they appear in the palette and context menus.
- **Trust:** actions from a repo's `.gitbello/actions.toml` are untrusted until the user approves them for that repo. If the file changes, approval is required again (similar to VS Code workspace trust).
- **Worktree setup hook:** the new-task flow can run a chosen action after creating a worktree, for example copying `.env` or installing dependencies.

### 3.13 Integrated terminal (M10)

Embedding a real terminal needs three pieces: a PTY (`portable-pty`, which uses ConPTY on Windows), a terminal state machine (`alacritty_terminal` or `vte`), and a grid renderer in Godot (`_draw()` with a monospace font, cursor, selection and scrollback). It is a substantial component, so it comes last.

**Fallback (ships in M5):** an "Open terminal here" action that launches the user's configured terminal in the active worktree.

---

## 4. UX specs for the key workflows

**Tabs and sidebar.** Each tab is a repo or worktree. The sidebar shows: Changes · Worktrees (nested, with badges) · Branches (local and remote, grouped by prefix such as `feature/`) · Tags · Stashes. The tab title shows the repo, the branch, and a badge (dirty count, ahead/behind arrows, conflict marker).

**Live status badges.** Shown on tabs, worktree rows and branch rows: changed-file count, ↑ahead ↓behind, and an icon for an in-progress merge, rebase or cherry-pick. An "operation in progress" banner offers Continue, Abort and Open resolver.

**New task (one click).**
1. Open the dialog: branch name, which is slugified for the folder.
2. Choose the base. It defaults to the upstream default branch and is fetched first.
3. Confirm the target path, previewed from the template.
4. Optionally pick a setup action.
5. Optionally open in the editor, or open as a tab (on by default).

This runs as a single job with rollback if any step fails.

**Cleanup merged worktrees.** Lists worktrees whose branch is merged into the base branch, or whose upstream is gone. It also shows dirty or unpushed warnings. Selected worktrees are removed (`git worktree remove`), with an option to delete their branches too. Squash-merged branches are detected as "upstream gone" and labelled "probably merged".

**Merge with preview.** Before merging, run `git merge-tree --write-tree` to show either "clean merge, N files" or "conflicts in: …" without touching the working tree. The user can then merge, merge with `--no-ff`, or cancel.

**Conflict resolver.** A three-pane view (ours, theirs, result) with base available in a toggle. Each conflict block can take ours, take theirs, take both in either order, or be edited by hand. A per-file "mark resolved" runs `git add`, and progress across files is shown. Stage content comes from `git show :1:`, `:2:` and `:3:` with the path.

**Stash workflow.**
- Stash all, stash selected files (`git stash push -- paths`), or include untracked files.
- Name stashes on creation.
- Preview a stash's diff in the DiffView before applying.
- Apply, pop or drop, where drop is undoable.
- Apply a stash to a different worktree.
- "Move changes to new branch": stash, create a branch, then pop.
- Branch checkout with a dirty tree offers to stash and re-apply after switching.

**Command palette.** `Ctrl/Cmd+K` (and `Ctrl/Cmd+Shift+P`) opens a fuzzy search over all actions, branches (to check out), tabs and repos (to switch), and files (to open their diff).

---

## 5. Milestones

Estimates assume ~20 h/week. The **daily-driver point** comes after M6: at that stage gitbello can replace GitHub Desktop for normal work.

### M0 — Skeleton and toolchain (≈1 week)
- [x] Cargo workspace with `gitbello-core`, `gitbello-gdext`, `gitbello-cli` and `xtask`
- [x] Godot project with the pinned version, `gitbello.gdextension` (all three platforms, debug and release), and the project settings from §3.7
- [x] `cargo xtask build | run | test | check | smoke`
- [x] gdext hello world: Rust `AppCore` autoload visible from GDScript, which emits a signal
- [x] CI (GitHub Actions, matrix win/linux/mac): fmt, clippy, test, build the gdext lib, Godot headless import, and one smoke test
- [x] LICENSE (per O1), README stub, `.gitignore`

**Accept when** `cargo xtask run` opens an empty window on all three OSes (verified in CI where possible), CI is green, and idle CPU is near 0% with low processor mode on.

### M1 — Graph performance spike (≈1.5 weeks)
- [x] `GitRunner` (minimal version: spawn, stream, env, Windows flag), with the classified `GitError` that M2 keeps
- [x] Streaming log parser and `GraphIndex` with incremental lane assignment (lane state checkpointed every 256 rows; slices replayed)
- [x] `gitbello-cli graph <path> --rows a..b` for inspection, plus parser and lane unit tests
- [x] `VirtualList` and `GraphView` in Godot, driven by `graph_rows(start, count)`
- [x] Benchmark on a local clone of `git/git` (read-only); record timings and memory (`cargo xtask bench-graph`, results in `docs/perf.md`)

**Accept when** the targets in §3.9 are met, or a written report explains the gap and the fix. **This is the go/no-go checkpoint for the Godot UI.**

*Result:* all §3.9 targets met except the first screen on repos without a commit-graph file (git itself takes ~640 ms to emit the first commit on git/git) and 1–2 frames over 16.7 ms when flinging a page per frame. See `docs/perf.md`.

### M2 — Core foundation (≈2 weeks)
- [x] Full `GitRunner`: progress mode, cancellation, error classification, command log
- [x] `GitBackend` trait and `CliBackend` reads: status, refs, worktrees, operation state, stash list
- [x] `JobScheduler` with per-repo write queues, refresh coalescing and the event channel (graph loads run as jobs)
- [x] Watcher (§3.6) and the focus-in refresh hook (core side; the Godot focus notification is wired with `RepoSession` in M3)
- [x] Config load and save (§3.8); git version check
- [x] Test fixtures: builders for repos with commits, branches, remotes (a local bare repo), worktrees, stashes, conflicts, detached HEAD, and paths with spaces or unicode

**Accept when** core tests cover every parser and the scheduler's ordering guarantees, and `gitbello-cli status|refs|worktrees <path>` works.

*Result:* 104 Rust tests (parsers on captured output and on real temp repos, scheduler ordering/coalescing/cancellation with a fake backend, watcher on real repos). The CLI also has `stashes`, `op-state`, `watch` and `config`.

### M3 — App shell (≈2 weeks)
- [x] `RepoSession` binding with signals; open repo (folder dialog, recent list, drag and drop). The core `Runtime` (config, git, jobs, watcher, repo state) is owned by the `Core` autoload
- [x] Tabs (open, close, reorder, restore on launch) and a sidebar with all sections and badges (data only, read-only). Worktree rows show branch and state; per-worktree dirty badges come with M6
- [x] `ActionRegistry`, command palette, rebindable shortcuts (palette lists actions, tabs and recent repos; branches and files arrive with M4/M5)
- [x] Light and dark themes that follow the OS; a balanced density pass
- [x] Git command log panel; error toast and dialog using classified errors

**Accept when** five repos can be open in tabs with correct live badges that update after CLI changes outside the app.

*Result:* covered by `shell_smoke.gd` (five fixture repos, badge update after an outside change) and core runtime tests (commits from the CLI). Branch/tag labels on graph rows and the focus-in refresh were added here too.

### M4 — Changes and commit (≈2.5 weeks)

Split after the M3 review into M4a (file-level flow) and M4b (hunk and line work), each with its own review.

#### M4a — Changes panel, unified diff, commit (≈1.5 weeks)
- [x] Changes panel: unstaged, staged and untracked lists, multi-select, stage or unstage files
- [x] `DiffView` (unified): diffs parsed in core and read in slices; large/binary handling
- [x] Commit box: summary and body, amend toggle, hook output shown on failure
- [x] Per-worktree dirty badges in the sidebar (pulled forward from M6)

**Accept when** a full stage-commit-amend cycle works using only the keyboard.

*Result:* covered by `changes_smoke.gd` (Ctrl+2, Enter/Space to stage, Ctrl+Shift+M, Ctrl+Enter, Ctrl+Shift+A, a rejecting hook) and core tests in `tests/changes.rs`. Conflicted files are listed with the unstaged ones. Worktree badges refresh on open, F5 and focus (linked worktrees are not watched until M6). Numbers in `docs/perf.md`.

#### M4b — Hunks, lines, details (≈1.5 weeks)
- [ ] `DiffView`: side-by-side, syntax highlighting (hand-written lexers, no new crate), intra-line highlights
- [ ] Hunk and line staging and unstaging (patch built in core, `git apply --cached --recount`, checked first); discard selection (with confirmation, undoable where possible)
- [ ] Commit details panel when a graph row is selected

**Accept when** the line-staging tests pass, including edge cases (no trailing newline, CRLF files, first and last line of a file).

### M5 — Sync, branches, tags (≈2 weeks)
- [ ] Fetch, pull (ff-only by default, with a merge/rebase setting) and push with progress, cancel, and classified error fixes (for example, a non-fast-forward error offers pull)
- [ ] Auto-fetch scheduler and live ahead/behind
- [ ] Branch create, checkout (dirty-tree flow §4), rename, delete; set upstream
- [ ] Tags: create (light and annotated), delete, push
- [ ] Cherry-pick from the graph context menu
- [ ] "Open in editor" and "Open terminal here" actions

### M6 — Worktrees (≈1.5 weeks) → daily-driver point
- [ ] Worktrees nested in the sidebar with badges; open a worktree as a tab
- [ ] New-task flow (§4) with path template and rollback
- [ ] Cleanup-merged flow (§4)
- [ ] Add, remove, lock, unlock and prune worktrees; handle a missing worktree folder gracefully

**Accept when** Caleb uses gitbello instead of GitHub Desktop for a full week. Collect friction notes for the next milestones.

### M7 — Merge and stash workflows (≈3 weeks)
- [ ] Merge with `merge-tree` preview (§4)
- [ ] Operation-in-progress banner with Continue and Abort for merge and cherry-pick
- [ ] Three-pane conflict resolver (§4)
- [ ] Stash workflow (§4), including stash to another worktree and move changes to a new branch

### M8 — History tools and editing (≈2 weeks)
- [ ] Blame view (`git blame --porcelain`, streamed), clickable to show the commit
- [ ] File history (`git log --follow`) with per-commit diffs
- [ ] Editable working copy in `DiffView` with live re-diff, save, and dirty protection (§3.10)
- [ ] Graph search and filter: by message, author, hash, path

### M9 — Power features (≈1.5 weeks)
- [ ] Operation log and undo (§3.11) with an "advanced restore" reflog view
- [ ] Custom actions with variables, output panel and the trust model (§3.12); worktree setup hook

### M10 — Integrated terminal (≈2.5 weeks, scope per O2)
- [ ] PTY, terminal state machine and Godot grid renderer; one terminal per tab, docked bottom panel
- [ ] Copy and paste, scrollback, resize, theme colors

### M11 — Packaging and first release (≈1.5 weeks)
- [ ] Custom slim export templates; release builds in CI
- [ ] Windows: zip plus installer (Inno Setup or similar). Linux: AppImage (Flatpak later). macOS: `.app` zip, documenting the unsigned-app steps (signing and notarization later)
- [ ] README with screenshots, CONTRIBUTING, issue templates; tag v0.1.0

**Total:** about 22 weeks to v0.1.0 at 20 h/week, with the daily-driver point at about 12 weeks.

---

## 6. Testing strategy

- **Parser unit tests:** captured git output fixtures, including unusual cases (renames, copies, unmerged entries, submodules, unicode paths, CRLF).
- **Integration tests:** real temp repos created with the fixture builders, with local bare repos standing in as remotes. Every operation in `CliBackend` gets at least one success test and one failure test.
- **Scheduler tests:** ordering, coalescing and cancellation, using a fake backend.
- **Smoke tests:** headless Godot scripts that load the main scene, open a fixture repo, and assert on the sidebar, lists and badges.
- **Performance check:** a CI-optional benchmark (`cargo xtask bench-graph <path>`) that records results in `docs/perf.md`.
- **Manual test scripts:** written at the end of every milestone for Caleb.

## 7. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Godot UI too slow or awkward for large lists and text | M1 spike is a go/no-go checkpoint; keep core UI-agnostic so a different frontend stays possible |
| gdext API changes (pre-1.0) | Pin versions; keep the boundary small (`gitbello-gdext` only) |
| git output differences across versions or platforms | Minimum version check, `-z` formats, `LC_ALL=C`, fixture tests in CI on all three OSes |
| Line-staging bugs corrupting the index | Extensive patch-construction tests; verify with `git apply --check` before applying; undo log |
| Scope creep | Out-of-scope list in §1; milestone reviews; daily-driver checkpoint at M6 |
| Terminal effort | Fallback external terminal ships early in M5 |
