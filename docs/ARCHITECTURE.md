# gitbello architecture

How gitbello is built and why. The UX of each workflow is in [UX.md](UX.md); feature internals are in the other files of this folder (see [the index](#other-docs)). Pending work lives on the project's ideas board, not in the repository.

---

## 1. Vision and scope

gitbello is a lightweight, native-feeling Git GUI for people who juggle many repositories and worktrees every day. Its main differentiators over GitHub Desktop and Fork are:

- **Repos and worktrees as first-class citizens.** Each repo opens in a tab, its worktrees sit in a strip of chips inside that tab, and live status shows everywhere.
- **A clean, uncluttered UI.** Balanced density, big simple buttons for the main features that lead to the detailed actions, keyboard-friendly, with a command palette for everything.
- **Better workflows** for merge (conflict preview before merging), shelving changes (stash without the stack) and creating worktrees.
- **Fast and idle-quiet.** Native Rust core and a Godot UI that redraws only when needed.

### In scope

File, hunk and line selection for commits · commit and amend · fetch, pull and push · branches · tags · stash (as shelves) · history graph and search · diff viewer (text, Markdown preview, images) · blame and file history · Compare · conflict resolver · merge, rebase and cherry-pick · worktrees (chip strip, one-click creation with setup, cleanup) · ignore rules · repository library (Home) · command palette · live status badges and auto-fetch.

### Out of scope

- Hosting integrations (GitHub, GitLab, …): gitbello is pure git. The exceptions are avatar lookups ([HISTORY.md](HISTORY.md#avatars)) and "Open on <host>" links, which only build URLs.
- Interactive rebase (simple history editing is an idea on the board).
- Submodule and LFS management: they work transparently through git and are displayed only.
- A bundled git and an auto-updater.

---

## 2. Decisions

| # | Decision | Choice |
|---|---|---|
| D1 | UI framework | Godot 4, latest stable 4.x, pinned in `project.godot` and CI (currently **4.7**; CI uses 4.7.2; gdext `godot = "=0.5.5"` with `api-4-7`) |
| D2 | UI language | Typed GDScript, thin view only |
| D3 | Native layer | Rust through gdext (`godot` crate, pinned version) |
| D4 | Git access | System `git` CLI behind a `GitBackend` trait; `gix` may replace hot reads later |
| D5 | Minimum git | **2.40** (needs `worktree list -z`, `merge-tree --write-tree`); checked at startup |
| D6 | Multi-project model | One tab per repo; its worktrees are chips in a strip inside the tab. Opening a linked worktree's path focuses its repo's tab with that chip selected |
| D7 | Themes | Light and dark themes built at runtime from one palette each plus a user accent colour, following the OS setting |
| D8 | Testing | Rust core tests on temp repos, parser unit tests, headless Godot smoke tests, screenshot scripts |
| D9 | Distribution | Open source on GitHub, MIT license |
| D10 | Staging model | The Changes checkboxes and diff line picks are gitbello's own selection, seeded from the index and written to it at commit time (§3.10) |
| D11 | Stash model | Shelves: stashes tied to a branch, identified by commit; a Shelves view whose button appears only when the repository has shelves |
| D12 | Visual style | Same family as Caleb's spritesheetbelli (surface/raised/border tokens, recoloured Godot editor icons, segmented toggles, section headers, labels-left forms), tuned for long lists, the graph and diffs |
| D13 | Repository list | A repository library (every repo ever added, no cap, `library.toml` in the data dir) shown on Home, which is both the no-tab state and what the tab-strip **+** opens |
| D14 | Network | Only git talks to remotes, except avatar lookups: on by default, a Settings toggle and per-provider switches, cached on disk, no bundled token; offline or failing lookups fall back to initials |
| D15 | Worktree path | `.worktrees/{branch_slug}` by default, relative to the main worktree's root and locally excluded through `.git/info/exclude`; editable in Settings |
| D16 | HTTP | Through the system `curl` (`CurlRunner`, same no-console, no-prompt and cancel handling as `GitRunner`). Crates were ruled out: `ureq` with rustls needs a C compiler for `ring` (none on the local windows-gnu toolchain), and with native-tls pulls `schannel` → `windows-sys` 0.61 |

---

## 3. Architecture

### 3.1 Layers

```
┌──────────────────────────────────────────────────────────┐
│ Godot (typed GDScript)                                   │
│  App shell · tabs · worktree chips · ActionRegistry      │
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
│  Operations (stage, commit, fetch…) · Config · Library   │
│  GitBackend trait → CliBackend                           │
│  GitRunner (process spawning, env, parsing helpers)      │
└──────────────────────────────────────────────────────────┘
```

`gitbello-cli` links `gitbello-core` directly for headless testing, debugging and benchmarks.

### 3.2 GitRunner

There is one place that spawns git processes. Every call goes through it.

- It resolves the git binary once (PATH, plus an override in settings; it also looks in the usual Git for Windows and Homebrew folders, for apps started from the Finder or right after an installer added Git), runs `git --version`, and refuses to open repos if the version is below the minimum.
- **Environment** for every call:
  - `GIT_TERMINAL_PROMPT=0`
  - `GIT_OPTIONAL_LOCKS=0` for read jobs
  - `LC_ALL=C` and `LANG=C` so error parsing is stable
  - `GIT_PAGER=cat`
  - a no-op `GIT_EDITOR` to guard against stray editor launches
- **Global flags:** `-c core.quotepath=false -c color.ui=false`. Use `-z` output formats wherever git supports them.
- **Windows:** set `CREATE_NO_WINDOW` (0x08000000) through `CommandExt::creation_flags`.
- **Streaming mode** for long output (log, diff, blame): it reads stdout incrementally. **Progress mode** for fetch, pull and push: it parses `--progress` lines from stderr into progress events.
- **Cancellation:** each running process is tied to a `CancelToken` and is killed on cancel.
- **Errors:** each call returns a `GitError { command, exit_code, stderr, kind }`, where `kind` is classified (auth failed, non-fast-forward, conflict, lock exists, not a repo, and so on) so the UI can offer specific fixes.
- **Logging:** every command, its duration and exit code go into the in-app "Git log" panel.

### 3.3 Backend and models

`GitBackend` is a trait with read operations (status, refs, worktrees, log stream, path log, diff, blame, show, stash list, merge preview, compare) and write operations (stage patch, commit, checkout, branch ops, fetch/pull/push, stash ops, worktree ops, cherry-pick, merge, rebase, conflict resolution, ignore rules). `CliBackend` implements all of it; test backends implement only what they need (methods with defaults return `None`).

The main parsing sources are:

| Data | Command |
|---|---|
| Status | `git status --porcelain=v2 -z --branch --show-stash` |
| Refs | `git for-each-ref --format=...` with NUL-separated fields (includes upstream, ahead/behind via `%(upstream:track)`) |
| Worktrees | `git worktree list --porcelain -z` |
| Log | `git log --all --topo-order -z --format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s` plus the body's `Co-authored-by:` trailers (streamed) |
| In-progress operation | presence of `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REBASE_HEAD` and `rebase-merge/` in the git dir (`git rev-parse --git-dir`, `--git-common-dir`) |

Models (`RepoStatus`, `FileChange`, `Ref`, `Worktree`, `Commit`, `Hunk`, `StashEntry`, `OperationState`, …) are plain Rust structs in core. gdext converts them to `Dictionary` or packed arrays only at the boundary.

### 3.4 Jobs and events

- `JobScheduler` runs a small pool of worker threads (std threads, `Mutex` + `Condvar` queue and an `mpsc` event channel; no async runtime or extra crates).
- Each repo has a **write queue** (FIFO, one at a time). Reads run on the shared pool. A read that would race with a queued write waits until the write is done. Fetch runs as a read, so commits never wait for the network.
- Jobs report `Started`, `Progress`, `Finished(Result)` and `Cancelled` through one `Event` channel per `AppCore`.
- After any write, the scheduler queues a targeted refresh. For example, a commit refreshes status, refs and the graph head; staging refreshes only status and the affected diff.
- **Coalescing:** duplicate pending refreshes of the same kind collapse into one.
- **Priorities (busy machines):** reads are Interactive (the shown diff, a commit's details, previews), Normal or Background (graph loads, summaries, searches, auto-fetch, badges, avatars); a worker takes the highest-priority job first, and background jobs never take the last free worker. Superseding labels (the diff, commit details, previews, HEAD info) cancel the same repo's older queued or running job. The table is `runtime::job_policy`.
- **Quiet refreshes:** a refresh whose result equals the current state sends no event. The shown diff reloads only when its inputs changed (HEAD, the file's status, the file's size and mtime); a load already running is not cancelled, it runs once more when it ends. The line-endings scan skips when the modified files' stats are unchanged.

### 3.5 Godot boundary

- `AppCore` is an autoload singleton (the `Core` autoload owns it). It owns the core `Runtime` (config, git, jobs, watcher, repo state, library), drains the event channel in `_process`, and routes events to the right `RepoSession`.
- `RepoSession` is a Node, one per open worktree. A repo tab creates the session of its selected worktree chip first and the others when their chip is first selected; chip badges come from the worktree badges, which need no session. It exposes:
  - **Queries** returning small data: `status()`, `refs()`, `worktrees()`, `operation_info()`.
  - **Slice queries:** `graph_row_count()`, `graph_rows(start, count)` (commit fields plus lane data), `diff_lines(start, count)`, `change_rows(start, count)` and the slot-keyed diff calls (`slot_diff_info(slot)`, `slot_diff_lines(slot, …)`, `diff_split_rows(slot, …)`, `image_side(slot, …)`, `open_version(slot, …)`, `expand_diff(slot, …)`, the minimap calls), where `slot` is `changes`, `commit`, `compare`, `file` or `blame`.
  - **Commands** that return a job id: `commit(...)`, `fetch()`, `merge(...)`, and so on.
  - **Signals:** `status_changed`, `refs_changed`, `graph_changed(range)`, `selection_changed`, `job_progress(id, pct, text)`, `job_finished(id, ok, error_dict)`, and one per feature (`merge_preview_ready`, `file_history_changed`, `blame_changed`, …).
- When nothing is changing, `_process` does almost nothing. The event drain is a cheap `try_recv` loop.

### 3.6 Watching and refresh

- `notify` with gitbello's own per-repository debouncer (250 ms quiet, 1 s at most) on each open worktree directory and its git dir. The common dir is watched for refs.
- Ignore `objects/` churn and any path git would ignore. Status does the real work; the watcher only decides whether a status refresh is needed.
- **Window focus in** (`NOTIFICATION_APPLICATION_FOCUS_IN`) triggers a cheap refresh of the active tab as a reliable fallback.
- **Auto-fetch:** a configurable interval (default 10 min). It runs with `--prune`, one repository at a time, staggered, skips repositories with a write queued, and reports one failure per failure streak.

### 3.7 Godot app structure and settings

- **Project settings:**
  - `application/run/low_processor_mode = true`
  - HiDPI enabled
  - native file dialogs on
  - the untyped-declaration GDScript warning set to **error**
  - a sensible minimum window size
- **Shell:** `Main` holds the tab strip (repo tabs plus at most one Home tab, always last) and the menu bar. A `RepoTab` holds the worktree strip and one `WorktreeView` per opened worktree (its Changes, History, Shelves, Compare and File history views). Two tabs found to be one repository merge. Jobs report to `Feedback` through `RepoOps`, with the control that started the flow (see UX.md, Feedback).
- **Custom controls** (in `godot/ui/`):
  - **`VirtualList`:** draws only visible rows with `_draw()`, handles selection, keyboard navigation, multi-select and context menus, and rows of other heights (`row_top`, `row_extent`, `row_at_offset`). It is the base for the commit list, file lists, the diff and the blame.
  - **`GraphView`:** draws lanes and nodes for visible rows from the lane data supplied by core, inside the commit list.
  - **`DiffView`:** unified and side-by-side views with hunk and line selection gutters, intra-line highlights, syntax colours per background and a core-rendered minimap in place of its scroll bar ([DIFF_VIEW.md](DIFF_VIEW.md)). `BlameView` is a `DiffView` with a leading gutter.
  - **`ImageDiffView`:** the image viewer ([DIFF_VIEW.md](DIFF_VIEW.md#image-viewer)).
  - **`LoadingIndicator`:** one smooth spinner in the accent colour over any panel. While nothing can be shown it sits in the middle with a short caption; while shown content reloads, a thin accent line slides along the top edge instead. It never takes the mouse, appears after 0.2 s, and has no seconds counter.
  - **`EmptyState`:** what a panel shows with nothing in it. The big form (title, hint, suggested actions) is "No local changes"; the compact form (`create_compact`: a muted icon, a terse title and at most one small button) is used for nothing selected ("No file selected"), nothing there ("No commits yet", "No differences") and filters matching nothing ("No matches" with Clear filter). Empty states show only once a load has finished; errors keep their own messages.
  - **`AutoScroll`:** browser-style middle-click autoscroll for every `VirtualList`, `ScrollContainer`, `Tree`, `ItemList` and multi-line `TextEdit` ([DIFF_VIEW.md](DIFF_VIEW.md#middle-click-autoscroll)).
  - Smaller shared pieces: `FilterField`, `OptionsPopover` / `SegmentedControl` / `ToggleChip`, `RefChip`, `AvatarPainter`, `RelativeDate`, `MarkStrip`, `PathLabel`, `ScrollRow`, `TooltipCard`, `FormDialog`.
- **`ActionRegistry`** (autoload). Every user-facing operation is an action: `{ id, label, menu_label, category, context, shortcut, visible, enabled (with a reason), run }`. The command palette, the menu bar, big buttons and every context menu (through `ActionMenu`) are built from it; shortcuts are rebindable in Settings → Keyboard. A run carries its origin control so the job's progress shows there. See [MENUS_AND_TOOLTIPS.md](MENUS_AND_TOOLTIPS.md).
- **Theming:** `AppTheme` (`godot/app/theme/app_theme.gd`, modelled on spritesheetbelli's) builds the project theme at startup from one palette per theme, the accent colour and the added/removed colours from Settings, and rebuilds it when the OS theme, the theme override or those colours change. The app follows `DisplayServer.is_dark_mode()` and reacts to changes.
  - **Tokens:** background, surface, raised, hover, border, text, muted text, accent, error, plus the git colours (graph lanes, ref labels, added/removed/modified/renamed, diff backgrounds and highlights, syntax).
  - **Type variations** for the big header buttons, worktree chips, segmented toggles, section headers, toasts and the blocking overlay. Text on selected rows is checked for WCAG AA contrast against the accent (`theme_smoke.gd`, 11 accents in both themes).
  - Ref labels are darkened until their text reads; diff backgrounds are the git colours blended into the background.
- **Icons:** Godot editor SVG icons (MIT, notice kept in `themes/icons/LICENSES.md`) plus git and app icons drawn on the same 16 px grid in the same greys (`#e0e0e0`), imported as `DPITexture`, recoloured for the light theme; active icons take the accent colour.
- **Localization:** English source strings are keys in `godot/localization/gitbello.csv`, imported as Godot translations. `L10n` applies the persisted Settings → Interface → Language choice (System, English or Italian); System selects Italian for `it*` OS locales and English otherwise. Fixed app/core messages are translated at the UI boundary, while paths, refs, user content, Git commands/progress and raw stderr remain unchanged. Controls with dynamic text refresh on `NOTIFICATION_TRANSLATION_CHANGED`.
- **Menu bar:** a `MenuBar` with `prefer_global_menu`, so macOS gets the system menu bar where Godot supports it and the other platforms an in-window bar.

### 3.8 Config and persistence

- User config lives in the OS config dir (`gitbello_core::paths`, written by hand; the `directories` crate's Windows dependency does not build on the GNU toolchain) as TOML (`config.toml`; `GITBELLO_CONFIG` overrides the path in tests). Unknown keys are kept. It holds:
  - clone folder (empty means the last clone's folder, `last_clone_folder`, then Documents)
  - open repo tabs, each with its selected worktree
  - worktree path template and branch prefix
  - terminal command (default: the platform's terminal)
  - pull mode (`ff-only` by default, `merge` or `rebase`)
  - auto-fetch interval
  - keybindings
  - theme override, interface language, accent colour, added/removed colours
  - diff settings (`diff_text_mode`, `diff_image_mode`, `diff_markdown_mode`, `diff_minimap`), history rows and graph, blame options, avatar settings and providers, the ignore-folder hint
- Per-repo user state (last selected branch, History's scope, Compare's recent comparisons, the Ignore dialog's target, dismissed hints) is stored in the app's data dir in `repos.toml`, keyed by the repo's canonical path. Panel sizes (the shared sidebar width, the shelf files' width, the commit details' height and files width) are app-wide, in the same file under `gitbello:panes`: every tab and worktree uses them and follows a resize at once.
- The repository library is `library.toml` in the same dir: one `[[repo]]` per repository (`path`, optional `name`, `pinned`, `added`, `opened`, `root_commit`, and `[repo.setup]` with the worktree setup's `copy` and `command`), unknown keys kept; a broken file is set aside as `library.toml.broken` and the list starts empty, with a toast.
- The cache dir (`paths::cache_dir`, `GITBELLO_CACHE_DIR` in tests) holds opened file versions (`versions/`, cleared at startup) and profile pictures (`avatars/`).
- **Never write to the user's repo** beyond what the user asks for (ignore rules, commits, …).

### 3.9 History graph

- Stream `git log` in topological order, parsing commits as they arrive. Build a compact `GraphIndex` with commit table, parent indices and ref decorations; authors, co-authors and subjects are interned in an arena.
- **Lane assignment** happens incrementally in core: a standard "active lanes" algorithm that assigns each commit a column and emits edge segments per row, with the lane state checkpointed every 256 rows so slices are replayed. Godot receives per-row `{column, color_idx, segments[]}`.
- **Memory target:** under 150 bytes per commit in the index, excluding strings.
- **Reloads:** when HEAD or the refs move, the graph reloads after a short delay, only while the History view is shown (a hidden one is marked stale and catches up when shown; HEAD info for the undo strip still reloads). The reload lists the tips first: unchanged tips load nothing, new commits on top of the old tips are streamed alone and the old index is copied under them (`GraphIndex::extend_from`), anything else (a rewrite, dropped commits) loads in full. The old rows stay shown until the reload is done (`graph_reloading_changed`), then swap in one reset.
- **Performance targets:** about 80k commits (the `git/git` repo) fully indexed in under 2 s on a modern machine. The first screen appears within 300 ms (stream the first page). Scrolling holds 60 fps. Idle CPU stays near 0%. Measured in [perf.md](perf.md): all met except the first screen on repos without a commit-graph file (git itself takes ~640 ms to emit the first commit on git/git) and 1–2 frames over 16.7 ms when flinging a page per frame.
- `in_head` on graph rows (from `rev-list --branches --remotes --tags --not HEAD`, loaded with the graph) decides where merge entries show.

### 3.10 Diff, staging and selection

- Diffs come from git (`git diff`, `git diff --cached`, `git show`), parsed into hunks and lines in core.
- **Viewing:** the diff text is selected like plain text (drag, double and triple click, Shift, Ctrl+A, Ctrl+C; one side at a time side by side), not as highlighted rows; drags after a double or triple click go by words or lines, Shift+Left/Right extend it (Ctrl by words); Copy and Select all are actions in the diff's context menu and the Edit menu; the arrow keys move a line at a time and only they show a caret, and the lines a selection touches are what Space picks and Delete discards. Diffs load with `-U3`.
- **Gaps:** the lines between hunks open GitHub Desktop-style: a hunk header's expanders show 20 more lines above it or below the previous hunk (all of a gap of 20 or fewer), each says how many lines it hides, an end row ("Show 47 more lines") opens the rest of the file, and **Show whole file** (`diff.toggle_whole_file`, the header's toggle) opens every gap. Core keeps the open gaps per diff (`Expansion`, kept across reloads of the same file) and builds a `DiffLayout` of runs (diff lines, a recounted header, unchanged lines, marker rows, the end row); the unchanged lines come from the old side's blob (`git cat-file blob`, read in a job once a gap opens or when the last hunk may not reach the end of the file, up to 16 MB, a failed read not retried), since git's context lines come from that side too.
- **Hunk and line patches:** build a minimal patch from the selected lines (recomputing hunk headers) and apply it with `git apply --cached --recount`, checked first. Discarding a selection applies the reverse patch to the working tree, after a confirmation. Discards back the file up as a blob first and Undo restores it (the last 20 per repository, in memory). Line picks work on tracked files and untracked files.
- **Commit selection** (D10): the file checkboxes and the hunk and line picks are a selection kept in core, one per worktree.
  - **Model** (`changes.rs`): each changed file has a pick: `Included`, `Excluded`, `AsStaged` (committed exactly as the index has it) or `Lines` (line keys). The checkbox shows all, none or partial. Line picks are keys, not rows, so they survive a reload of the diff: a removed line by its old line number, an added line by the old line it follows plus a hash of its text and its ordinal. Status keeps each file's index blob and mode (porcelain v2 `hI`/`mI`) for this. Lines added to a partly picked file start left out.
  - **Seeding:** when the index has staged changes, the selection starts as exactly those; otherwise every change starts selected. Changes that appear later start selected. When a file's index blob changes from the one seen (staging outside gitbello), that file alone is reseeded from the index, so nothing staged elsewhere is silently dropped. A file staged in part starts `AsStaged`; when its diff opens, the staged lines are matched onto it and it becomes a `Lines` pick if every staged line matches, else it stays `AsStaged` with a note. The selection lives in memory: after a restart it is seeded again from the index.
  - **Diff:** the Changes view shows the working copy against HEAD (`DiffKind::Head`; the empty tree before the first commit). Line picks and line discards use this diff. During amend, `DiffKind::Amend` compares the working copy with the original commit's first parent (its empty tree for a root commit), and `DiffKind::AmendStaged` compares the preserved selection snapshot with that parent; line picks use both, while line discard is unavailable. Discarding whole files always restores them from the real HEAD (index and working copy; untracked files are deleted), backed up for Undo.
  - **Commit:** one write job builds the commit in a temporary index (`GIT_INDEX_FILE`), so the real index is never touched until the commit exists: `read-tree HEAD` (or the amend parent's tree); whole files with `add -A` (a staged rename takes its source; a staged deletion whose file is still on disk is written as a removal); `AsStaged` files with `update-index --index-info` from the selection snapshot's blob; `Lines` files by re-reading the applicable diff, matching the keys and `apply --cached --recount` (a key that no longer matches fails the job before anything is written); then `commit -F -` (with `--amend` and `--allow-empty` when amending). Only then are the committed paths reset in the real index (`reset -q --`). A failing hook or a cancel leaves the real index as it was.
  - **Amend session:** `begin_amend` first writes the current selection to a temporary-index tree snapshot, preserving partial and overlapping changes without touching HEAD, the real index or working files. Its baseline and message come from HEAD; its change list merges the parent-to-working diff with the parent-to-snapshot diff. The ordinary selection is saved separately and restored on cancel. Status refreshes update the amend model from the fixed baseline and snapshot; a changed HEAD, branch or operation ends the session, and saving checks the expected HEAD and branch again in the write job. `cancel_amend` is local and immediate. `is_amending`, `in_amended_commit` and `amend_requires_force_push` feed the UI; the last uses known remote-tracking refs and upstream state.
  - **API:** `Runtime::{pick_files, pick_all, pick_lines}` change the selection in memory (no job) and send `SelectionChanged`; `select_change` loads the applicable Changes diff; `commit` commits the selection; `commit_block_reason` says why it cannot ("Nothing included", "Resolve conflicts first", "Write a summary"). `RepoSession` lists one change list (`change_count()`, `change_rows(start, count)` with `{path, original_path, code, pick, conflicted, as_staged, amending, in_original_commit, resolved, locked, endings_only, ignored_by}`, `change_paths`, `change_index`, `shown_picked_paths`), `select_change(path, full)`, `pick_files(paths, include)`, `pick_all(include)`, `pick_lines(lines, include)` (a hunk header takes its hunk), `picked_count()`, `selection_state()` (the check-all box), `commit_block_reason(amend)` and the `selection_changed` signal; diff rows carry `picked`, `diff_info` carries `as_staged`. `apply_lines("discard", …)` discards lines.
- **Large or binary files:** above a size threshold, show a summary with a "Load anyway" option. Binary files show a size and type summary only, except images, which open in the image viewer.

---

## 4. Distribution

- **Releases:** `.github/workflows/release.yml` builds the gdext library on Windows (static CRT), Linux (ubuntu-22.04) and macOS (universal), exports the three presets in `godot/export_presets.cfg` with Godot's stock templates, and attaches them to a draft release whose notes are the `CHANGELOG.md` section of the tag's version. The steps to cut one are in AGENTS.md.
- **Windows:** a zip plus an Inno Setup installer (`packaging/windows/installer.iss`, current user, offers to download Git for Windows pinned by URL and SHA-256 when git is missing or older than 2.40).
- **Linux:** a `.tar.gz` with `install.sh` (as spritesheetbelli).
- **macOS:** an `.app` zip, ad-hoc signed, with the unsigned-app steps in the README.
- **Branding:** `themes/branding/logo.svg` (a shared-stem "gb" drawn as a branch along the squircle's diagonal, off-white on steel blue with muted amber commit dots) and a heavier `logo_small.svg` for 24 px and below; `tools/export_branding.gd` draws `icon.png` (window icon, boot splash), `icon.ico` (Windows) and `icon_macos.png` (1024 px on the system icon grid, made into an `.icns` by the macOS export).

---

## 5. Testing strategy

- **Parser unit tests:** captured git output fixtures, including unusual cases (renames, copies, unmerged entries, submodules, unicode paths, CRLF, records split across chunks).
- **Integration tests:** real temp repos created with the fixture builders in `gitbello-core/tests/support`, with local bare repos standing in as remotes. Every operation in `CliBackend` gets at least one success test and one failure test.
- **Scheduler tests:** ordering, coalescing and cancellation, using a fake backend.
- **Smoke tests:** headless Godot scripts under `godot/tests/smoke/` that load scenes, open fixture repos (`gitbello-cli fixture`) and assert on node state. `cargo xtask smoke` builds the fixtures and a scratch config.
- **Screenshot scripts:** `godot/tests/visual/` walk features in numbered shots for review (listed in AGENTS.md).
- **Performance:** `cargo xtask bench-graph`, `gitbello-cli` benches and `godot/tests/perf/` scenes; results go in [perf.md](perf.md).
- **Manual test scripts** for Caleb at the end of each feature.

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Godot UI too slow or awkward for large lists and text | Keep large data in Rust and fetch visible slices; keep core UI-agnostic so a different frontend stays possible |
| gdext API changes (pre-1.0) | Pin versions; keep the boundary small (`gitbello-gdext` only) |
| git output differences across versions or platforms | Minimum version check, `-z` formats, `LC_ALL=C`, fixture tests in CI on all three OSes |
| Line-staging bugs corrupting the index | Extensive patch-construction tests (`tests/line_staging.rs`, including 30 random selections against an independent model); `git apply --check` before applying; discard backups |
| Commit-time staging losing work staged elsewhere | Selection seeded from the index and reseeded on outside changes; the commit is built in a temporary index, so the real index changes only after the commit exists; tests for outside staging and failing hooks (`tests/selection.rs`) |
| UI changes breaking smoke coverage | Smoke tests updated with each change, not after; screenshots reviewed before commits |

---

## Other docs

- [UX.md](UX.md): the window, menus, Home, worktrees, branches, sync, Changes, shelves, merge, rebase, the resolver, feedback, keyboard.
- [DIFF_VIEW.md](DIFF_VIEW.md): diff modes, the minimap and autoscroll, the image viewer, Open, line endings.
- [SYNTAX_HIGHLIGHTING.md](SYNTAX_HIGHLIGHTING.md): the lexer framework, languages, line states, colours.
- [HISTORY.md](HISTORY.md): history rows, refs, authors and avatars, search, file history and blame.
- [COMPARE.md](COMPARE.md): comparing branches, commits and the working copy.
- [MENUS_AND_TOOLTIPS.md](MENUS_AND_TOOLTIPS.md): `ActionMenu`, the menu bar, undo, tooltip cards, options popovers, Settings → Keyboard.
- [IGNORE_RULES.md](IGNORE_RULES.md) and [SHELF_FILE_ACTIONS.md](SHELF_FILE_ACTIONS.md): those two features in depth.
- [perf.md](perf.md): measured timings.
