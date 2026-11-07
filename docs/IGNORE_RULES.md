# Ignore rules

Status: scope settled with Caleb on 2026-11-02 (§6), interface (a) approved the same day; (a) implemented on 2026-11-06 (see "As built" in §4). §4.5 (b) is provisional.

Two parts:

1. **Ignore from Changes.** Right-click a file in Changes and ignore it: the file, its extension, or one of its folders. Write the rule to `.gitignore` (shared) or `.git/info/exclude` (only on this computer). If the file is already tracked, the same flow can also untrack it.
2. **Ignore rules viewer.** Repository → Ignore rules… lists every rule that applies to the repository, where it comes from, and what each line hides right now.

## 1. Review of the proposal (Q&A)

**Q: See the current gitignore, and what each line hides locally. Is that feasible and cheap?**
Yes, with two git commands and no new dependency:

- `git ls-files -z --others --ignored --exclude-standard --directory` lists what is ignored right now. `--directory` collapses a fully ignored folder (`target/`, `node_modules/`) into one entry, so large build folders stay cheap.
- Piping that list into `git check-ignore -z -v --stdin` gives, for each entry, the `source:line:pattern` that decided it. Group by `(source, line)` to get "this line hides these paths".

Two catches found while trying it on a scratch repo:

- With `--directory`, git also lists parent folders that only *contain* ignored files (`src/`, `src/a/` for `src/a/f.log`). `check-ignore` does not attribute them, so drop any entry it does not attribute; its ignored contents are listed separately.
- `check-ignore` reports nothing for tracked files unless `--no-index` is passed. That is how to find "tracked but matches a rule" (see the third point).

The viewer should show more than one `.gitignore`. The rules that apply come from: every `.gitignore` in the tree (nested ones apply to their folder), `.git/info/exclude`, and the global `core.excludesFile` (default `~/.config/git/ignore`). Show all three kinds, each labelled.

**Q: "Ignore this file / \*.ext" from the right-click menu, written to `.gitignore` or `.git/info/exclude`.**
Agreed. Changes needed:

- Don't use a fixed pair of menu items. Use a short **Ignore** submenu with the two or three most likely rules, plus **Ignore…** to open the dialog with every option (§2). The quick entries skip the dialog, and the dialog handles the less common cases.
- The target has to be clear. `.git/info/exclude` lives in the repository's *common* directory, so it applies to **every worktree of the repository**, not just the current one. Label it "Only on this computer (all worktrees)". The existing `/.worktrees/` exclusion in `backend.rs` already relies on this.
- Writing a rule changes `.gitignore`, which then appears in Changes as a modified file. That is correct: the user commits it. Writing to `info/exclude` changes nothing in Changes except the files that disappear.

**Q: Files already tracked are still tracked after you ignore them. Offer to remove them too?**
Yes, but "remove completely" can mean three different things, and only the first belongs here:

| Meaning | Git | Proposal |
|---|---|---|
| Stop tracking from the next commit and keep the file on disk | `git rm --cached -r -- <paths>` | **Yes.** A checkbox in the dialog ("Also stop tracking 3 files that match"). On by default only when the rule is shared |
| Keep it tracked but stop showing my local edits (local config files) | `git update-index --skip-worktree` | **Later, as its own action.** This is usually what people want for `config.local.json`. It is not ignoring, so it needs its own label and a way to list and reverse it |
| Purge it from all history (secrets, huge binaries) | `git filter-repo` and a force push | **No.** It rewrites history and is out of scope. If the file looks like a secret, the dialog says the file is still in history and the key should be rotated |

The untrack warning has to be explicit. After you commit and push, **anyone who pulls has the file deleted from their disk**, because to them it is a tracked file being removed. That is fine for build output and dangerous for a config file. The dialog says so whenever it untracks.

**Q: Choose the scope: the file, the extension, the folder, or any parent level.**
Agreed. The suggestions are computed in core and listed from narrowest to widest. For `src/game/assets/hero.import`:

| Option | Pattern (root `.gitignore`) | Notes |
|---|---|---|
| This file | `/src/game/assets/hero.import` | Anchored with a leading `/`, so it matches only this path |
| This name anywhere | `hero.import` | Shown only when the name is distinctive (not `index.js`, `README.md`) |
| `*.import` everywhere | `*.import` | |
| `*.import` in `assets/` and below | `/src/game/assets/**/*.import` | |
| Folder `assets/` | `/src/game/assets/` | Trailing `/` matches the folder only |
| Folder `game/` | `/src/game/` | One option per parent level, up to the top folder |
| Folder `src/` | `/src/` | |
| Custom… | editable | Starts from the selected option, validated and previewed live |

Edge cases the generator must handle:

- **Escaping.** A leading `#` or `!`, trailing spaces, and `* ? [ \` in names need a backslash. Non-ASCII names are written as UTF-8 and need no escaping. Unit-test with captured `check-ignore` output, as for other parsers.
- **Multi-select.** "Ignore N files" offers the extension option only when all of them share one extension, and folder options only for folders that contain all of them.
- **Untracked folders.** Status uses `--untracked-files=all`, so a new folder shows up as many files. Offer the folder as an option, and when every changed file sits under one new folder, list it first.
- **Disabled for** conflicted files, and for files inside a submodule (they belong to the submodule's repository).
- **Negation limit.** git cannot re-include a file if a parent folder is excluded. Custom rules starting with `!` get a warning when that applies.

## 2. UX

### Right-click in Changes (and the diff header)

```
Ignore                          ▸  Ignore "hero.import"
                                   Ignore all *.import files
                                   Ignore folder "assets/"
                                   ─────────────
                                   Ignore…
```

Quick entries write to the shared root `.gitignore`. If the rule matches tracked files, core refuses and the dialog opens prefilled, because untracking needs a decision. Each one is an Action (golden rule 10): `changes.ignore_file`, `changes.ignore_extension`, `changes.ignore_folder` and `changes.ignore` (the dialog), so the command palette has them too.

### Ignore dialog

- A list of options (the table above) and an editable **Pattern** field.
- **Where:** *Shared with everyone (.gitignore)* / *Only on this computer (all worktrees)*. Under Shared, a choice of which `.gitignore` when there are nested ones: the root one by default, or the nearest existing one, with the pattern rewritten relative to it.
- **Live preview:** "Hides 14 changed files" with the first few paths, and "3 tracked files match" with the untrack checkbox and its warning. The preview runs as a read job with only the candidate pattern, rewritten in the root-relative form that `git ls-files -x` matches correctly (§4.1 `match_form`).
- If the rule already exists in the target file, the preview says so and the button reads "Already ignored".
- **Ignore** writes the rule, untracks when chosen, refreshes status, and shows a toast with **Undo**.

### Ignore rules viewer (Repository → Ignore rules…)

A dialog like Remotes… and Tags… (`godot/app/manage/`):

- **Left:** the sources: root `.gitignore`, nested `.gitignore` files, `info/exclude` ("This computer"), and the global file ("All your repositories", read-only by default). Each shows how many paths it hides.
- **Middle:** the lines of the chosen source. Comments are dimmed, `!` negations are marked, each rule shows a count ("hides 2 folders, 31 files"), and rules that match nothing are flagged as unused. Tracked files that match a rule appear as a warning chip on that line ("4 tracked files match"), with **Stop tracking…**.
- **Right:** what the selected line hides, as a virtual list fetched in slices (golden rule 6). Folders stay collapsed.
- **Actions:** Remove rule (undoable), Open file in editor, Copy pattern. Editing lines in place can come later, once M8's editable working copy exists.

### Additions worth considering

1. **"Show ignored files"** in the Changes filter menu. It lists ignored files greyed out, each with the rule that hides it ("ignored by .gitignore:12 `*.log`"). This makes "Why isn't my file showing up?" answerable. Right-clicking one offers **Stop ignoring**: remove the line when it matches exactly that path, otherwise add a `!` negation, with the parent-folder warning.
2. **Ignore templates** in the viewer: "Add rules for Godot / Rust / Node / macOS…" from the same templates Create repository already uses (`library_ops.gd`), showing only the lines that are missing.
3. **Home or status hint.** When many untracked files sit under one folder (`node_modules/`, `target/`, `.godot/`), the Changes empty or offer bar suggests "Ignore folder `target/`?". Cheap, and it covers the most common first-day annoyance.
4. **Skip-worktree** ("Keep tracked, ignore my local edits"), listed in the viewer under its own section so it is never hidden state. Separate follow-up (see the table above).

## 3. Undo

- **Rule added:** core keeps the target file's bytes from before the write. Undo restores them only if the file is unchanged since (same bytes as after our write). Otherwise it removes our exact lines when it can find them, and refuses with an explanation when it can't.
- **Untracked:** Undo puts back the index entries saved before `rm --cached` (`update-index --index-info`), so staged content returns exactly, and then undoes the rule.
- Same per-repository stack and toast as `undo_discard` until M9's operation log replaces both.

## 4. Interface (for approval)

All parsing, pattern generation, preview and file writing live in `gitbello-core` (golden rule 1). gdext forwards calls and GDScript only shows the results.

This follows the existing patterns. `load_*` returns a job id, a signal says the data arrived, and a getter returns it (as with `load_merge_preview` / `merge_preview_ready` / `merge_preview`). Writes return a job id and report through `job_finished`. Undo uses its own per-repository stack, like `undo_shelf_discard`. No new crates or addons: matching goes through `git ls-files -x`, not a gitignore crate.

### 4.1 Core: `gitbello-core/src/ignore.rs` (a)

```rust
pub enum IgnoreTarget {
    /// A `.gitignore`; `dir` is its repo-relative folder ("" = the root one).
    Shared { dir: PathBuf },
    /// `info/exclude` in the common dir (every worktree).
    Local,
    /// `core.excludesFile`. Refused in (a), writable in (b).
    Global,
}

pub struct IgnoreRule {
    /// As written, relative to the target file's folder.
    pub pattern: String,
    pub target: IgnoreTarget,
}

pub enum SuggestionKind { File, Name, Extension, ExtensionBelow, Folder }

pub struct Suggestion {
    pub kind: SuggestionKind,
    pub pattern: String,
    /// What the label names: "hero.import", "*.import", "assets/".
    pub subject: String,
    /// Folder level (0 = nearest); 0 for the other kinds.
    pub level: u32,
}

pub enum PatternWarning {
    Empty,
    /// `*`, `/`, `**`.
    MatchesEverything,
    /// A `!` line (git cannot re-include a file whose folder is excluded).
    Negation,
}

pub struct IgnorePreview {
    pub rule: IgnoreRule,
    /// The exact line is already in the target file.
    pub exists: bool,
    pub warning: Option<PatternWarning>,
    /// Changes that would leave Changes (untracked files the rule matches).
    pub hidden_count: usize,
    pub hidden_sample: Vec<PathBuf>, // at most 50
    /// Tracked files the rule matches (candidates for untracking).
    pub tracked_count: usize,
    pub tracked_sample: Vec<PathBuf>, // at most 50
}

// Pure, unit-tested:
pub fn suggestions(paths: &[PathBuf], dir: &Path) -> Vec<Suggestion>;
pub fn escape(name: &str) -> String;
/// The rule as a root-relative pattern that `ls-files -x` matches the same
/// way git applies the written rule: nested rules get their folder prefixed
/// (`*.x` in `src/` → `/src/**/*.x`), folder rules get `**`
/// (`/u/` → `/u/**`, `v/` → `**/v/**`).
pub fn match_form(rule: &IgnoreRule) -> String;
pub fn check(pattern: &str) -> Option<PatternWarning>;
/// Appends `line`, keeping the file's line endings and adding a missing final newline.
pub fn append_line(contents: &[u8], line: &str) -> Vec<u8>;
```

`match_form` is required. On a scratch repo:
- `git ls-files -c -i -x '/a/'` lists nothing for the tracked `a/b/x.js`.
- `ls-files -o -i -x '/u/' -- u/v/n.txt` misses the untracked file.
- `/a/**` and `/u/**` match both.
- Writing `/u/` itself to `.gitignore` hides the folder as expected.

### 4.2 Runtime (a)

| Function | Kind | What it does |
|---|---|---|
| `ignore_suggestions(key, paths, dir) -> Vec<Suggestion>` | sync, no git | Options for the dialog and the quick entries |
| `ignore_files(key, paths) -> Vec<PathBuf>` | sync, a few `stat`s | Folders with a `.gitignore` above every path, root first. The root is always listed, even when missing |
| `load_ignore_preview(key, rule) -> Option<JobId>` | read job | Cancels this repository's previous preview. Event `IgnorePreviewLoaded { repo, job }` |
| `ignore_preview(key) -> Option<&IgnorePreview>` | getter | The last preview |
| `add_ignore_rule(key, rule, untrack: Untrack) -> Option<JobId>` | write job, label "Ignore" | `Untrack { Keep, Remove, RefuseIfTracked }`. See below |
| `can_undo_ignore(key) -> bool`, `undo_ignore(key) -> Option<JobId>` | write job | §3 |
| `ignore_dialog_target(key)`, `set_ignore_dialog_target(key, target)` | `ui_state.rs` | The dialog's remembered target per repository (decision 2) |

`add_ignore_rule`:
1. Re-reads the target file and does nothing if the line is already there.
2. Appends the line with `append_line`, creating `info/` when it is missing.
3. Computes the tracked matches fresh (it does not trust a preview).
   - `RefuseIfTracked` (the quick entries): if any tracked files match, it stops before writing and fails with the new `GitErrorKind::TrackedMatches` (`kind: "tracked_matches"` in the error dictionary). The UI then opens the dialog prefilled.
   - `Remove`: saves the matches' index entries for undo and runs `rm --cached`.
   - `Keep`: leaves them tracked.
4. Requests a status refresh. The watcher may not see a write to `info/exclude` inside `.git/`, so it requests the refresh explicitly.
5. After the refresh, includes the `.gitignore` and the removed paths in the commit (decision 7).
6. Pushes the undo record `{ file, before: Option<Vec<u8>>, after: Vec<u8>, index_entries }`.

Files are written with `std::fs`, the way the `/.worktrees/` exclusion is written today. Existing lines are never reordered or reformatted.

### 4.3 Backend trait, all through `GitRunner` (a)

| Method | git |
|---|---|
| `untracked_matching(repo, paths, match_form)` | `--literal-pathspecs ls-files -z -o -i -x <form> -- <paths>`. `paths` are the untracked paths from status, in batches under the Windows command-line limit. The pathspecs keep git out of `node_modules/` and the like |
| `tracked_matching(repo, match_form)` | `ls-files -z -c -i -x <form>` |
| `index_entries(repo, paths)` | `ls-files -z -s -- <paths>` (saved for undo) |
| `untrack(repo, paths)` | `rm --cached -r -q --ignore-unmatch --pathspec-from-file=- --pathspec-file-nul`. No `-f`: git refuses a file whose staged content differs from both HEAD and the working tree, and that error is shown |
| `restore_index_entries(repo, entries)` | `update-index -z --index-info` (exact undo, staged content included) |

`--pathspec-from-file` needs git 2.26+; the installer already requires 2.40. The reads use `--no-optional-locks`. The watcher's existing `ignored()` is unchanged.

### 4.4 gdext `RepoSession` (a)

```gdscript
func ignore_suggestions(paths: PackedStringArray, dir: String) -> Array[Dictionary]
	# {kind: "file"|"name"|"extension"|"extension_below"|"folder", pattern, subject, level}
func ignore_files(paths: PackedStringArray) -> PackedStringArray   # "" (root) first
func load_ignore_preview(rule: Dictionary) -> int                  # rule = {pattern, target: "shared"|"local", dir}
signal ignore_preview_ready(job: int)
func ignore_preview() -> Dictionary
	# {pattern, target, dir, exists, warning: ""|"empty"|"matches_everything"|"negation",
	#  hidden_count, hidden_sample: PackedStringArray, tracked_count, tracked_sample: PackedStringArray}
func add_ignore_rule(rule: Dictionary, untrack: String) -> int     # "keep" | "remove" | "refuse"
func can_undo_ignore() -> bool
func undo_ignore() -> int
func ignore_dialog_target() -> Dictionary                          # {target, dir}
func set_ignore_dialog_target(target: Dictionary) -> void
```

GDScript's part:
- Builds the submenu and the dialog.
- Debounces preview requests (150 ms) and drops stale results by job id.
- Translates the warning codes.
- For a quick entry, calls `add_ignore_rule(…, "refuse")` directly. On a `tracked_matches` failure it opens the dialog prefilled with that rule instead of showing an error toast.

### As built (a), 2026-11-06

Differences from the tables above:
- `ignore_suggestions` is the pure `ignore::suggestions`, called by gdext directly (it needs no repository state); there is no `Runtime` wrapper.
- No `ignore_dialog_target` bindings: the dialog keeps its target with the existing `Core.repo_ui_state` / `set_repo_ui_state` (`ignore_target`: 0 shared, 1 local).
- The warning for `!` lines is `negation` (any `!` line), not a check against the other rules.
- `add_ignore_rule(rule, untrack)` takes `untrack` as `"keep"`, `"remove"` or `"refuse"`; `add_ignore_rule` and `undo_ignore` also refresh the status of the repository's other open worktrees (`info/exclude` is shared).
- A `tracked_matches` failure does not raise `Core.git_error` (no error toast): the quick entry opens the dialog instead.
- Writing a rule that is already there writes nothing and leaves no undo entry.
- Not built: putting a new folder first in the options when every changed file is under it (§1, "Untracked folders").

UI: `godot/app/changes/ignore_ops.gd` (`IgnoreOps`: quick rules, the dialog on `FormDialog`, undo), the Ignore ▸ submenu in `ChangesView`, actions `changes.ignore_file`, `changes.ignore_extension`, `changes.ignore_folder`, `changes.ignore` and `changes.undo_ignore` (Edit → Undo), icon `GitIgnore`.

### 4.5 Viewer interface (b)

The plan as written before (b) started; "As built (b)" below lists what changed.

- `load_ignore_rules(key) -> JobId`, then event `IgnoreRulesLoaded`.
- `ignore_sources(key)`: `{kind: root|nested|local|global, path, writable, hidden_count}`.
- `ignore_lines(key, source)`: `{number, text, kind: rule|negation|comment|blank, hidden_files, hidden_folders, tracked_count, unused}`.
- `ignore_hidden(key, source, line, start, count)`: slices of `{path, is_dir}`.
- `remove_ignore_rule(key, source, line) -> JobId`, undone through the same stack.
- Backend:
  - `ignored_entries`: `ls-files -z -o -i --exclude-standard --directory`, minus the parent folders that `check-ignore` does not attribute.
  - `check_ignore_verbose`: `-v -n -z --stdin`, with `--no-index` for tracked files.
  - `global_excludes_file`: `config --path core.excludesFile`, falling back to the XDG default.
- "Show ignored files" adds an `ignored` option to `set_change_filter` and an `ignored_by` field (`source:line pattern`) to `change_rows`.

### As built (b), 2026-11-07

Core (`gitbello-core/src/ignore/rules.rs`, pure and unit-tested): `IgnoreRules::build` joins the sources' contents, `ls-files --directory` and `check-ignore -v` into sources (`root`, `nested`, `local`, `global`), their lines (`rule`, `negation`, `comment`, `blank`, each with what it hides, the tracked files it matches and the files it brings back) and an index from each ignored path to its line. `unignore` decides how Stop ignoring works, `template_missing` gives a template's missing lines, `folder_hint` picks the folder for the hint.

Differences from §4.5:
- Sources carry `exists` instead of `writable`: every source is writable, and a global file that is not created yet is listed as "not created yet". When `core.excludesFile` is unset the global file is git's default (`$XDG_CONFIG_HOME/git/ignore`, else `~/.config/git/ignore`).
- `ignore_hidden` rows add `tracked`, and tracked matches come first. `ignore_lines` rows add `reincluded` (what a `!` line brings back).
- The rules load once (`load_ignore_rules`) or are kept up to date by `watch_ignore_rules(open)`: while the viewer is open, or "Show ignored files" is on, each status refresh reloads them. Closing the viewer drops them.
- New bindings: `untrack_ignored(source, line)` (Stop tracking… for every tracked file a line matches), `stop_ignoring(path)` and `stop_ignoring_plan(path)`, `ignore_template_lines(name)`, `ignore_hint()`, `shown_ignored_count()`. All writes share the undo stack of (a).
- Stop ignoring removes the line when it is anchored and names exactly that path; otherwise it adds `!/<path>` to the same file. For a rule in the global file the negation goes to `info/exclude`, so other repositories keep the rule.
- Remove rule checks the line's text before writing and keeps the file's BOM and line endings; Undo refuses (`stale`) when the file changed after the removal.
- A write to the global file refreshes every open repository; a write to `info/exclude` refreshes the repository's other worktrees.
- "Show ignored files" is the `ignored` option of the change filter. Ignored rows come last, muted, without a checkbox (they are never committed, discarded, shelved or ignored again), with "Ignored by <file>, line <n>: <pattern>" as their tooltip. An ignored folder is one row (`build/`) and shows no diff. A path that is also a change (a file just untracked, or one Stop ignoring brought back before the rules reload) is listed once, as the change.
- The viewer (compact, after review on 2026-11-07): a row of chips, one per source, styled like the worktree strip (icon, short name, how many paths it hides, a warning when a rule matches tracked files); middle-click opens the file, right-click offers Open file and Show in file manager. Under a divider, the toolbar (Add with its ▾, Remove, and Stop tracking… only for a rule matching tracked files) above the numbered lines, and beside them what the selected rule hides: a one-line recap with icons ("2 files · 1 tracked") over the paths. Nothing shows without a rule selected. What a line does is in its tooltip. The viewer is not exclusive, so the Ignore dialog and the Stop tracking confirmation open over it.
- Add opens the Ignore form on an empty pattern; its ▾ lists the templates under "Templates", and one opens the form with the lines the root `.gitignore` lacks (chosen over a Template choice in the form, 2026-11-07).
- An edit in the Ignore form drops the preview still loading for the text before it (it used to land as current and could disable Ignore).
- Names: the Ignore dialog's Where and the viewer's chips say "This repository" / "My computer" / "Global setting" (`.gitignore`, `info/exclude`, the global file; icons `GitIgnore`, `User`, `Tools`), with the full meaning in tooltips. The Where choice "Global setting" hides the file choice and leaves untrack off. The preview says nothing while it loads or when no changed file matches.
- The folder hint is one button above the Changes list ("Ignore node_modules/", what the folder holds in its tooltip) and a close button whose menu offers "Don't suggest node_modules/ again" (per repository and folder: `ignore_hint_kept/<folder hash>` = 1 in `Core.repo_ui_state`, which stores ints) or "Never suggest folders to ignore" (the `ignore_hint` setting, back on in Settings → General). It shows for a known output folder (`.godot`, `node_modules`, `target`, `build`, `bin`, `obj`, `dist`, …), or for any folder holding at least 50 new files and more than half of the changes.

UI: `godot/app/manage/ignore_rules_dialog.gd` (`IgnoreRulesDialog`), `ignore_source_chip.gd` and `ignore_hidden_list.gd`; actions `repo.ignore_rules`, `changes.stop_ignoring` and `changes.ignore_hint`.

### 4.6 Interface decisions (2026-11-02)

1. **The preview checks the candidate rule alone.** A later `!` negation elsewhere can make it over-count. Changes shows the real result once the rule is written.
2. **No matcher crate.** Matching uses `git ls-files -x`, debounced. Preview timings go in `docs/perf.md`.
3. **Quick entries let core decide.** `add_ignore_rule(…, RefuseIfTracked)` fails with `tracked_matches`, and the UI opens the dialog. There is no preview round trip.
4. **The commit include happens after the status refresh.** The brief flicker of the `.gitignore` row is accepted.

## 5. Verification

- **Core unit tests:** suggestions for every level, with escaping (`#`, `!`, spaces, brackets, trailing spaces), non-ASCII and space-containing paths, and multi-select. Parse captured `check-ignore -v -z` output, including a negation match and the unattributed parent folders `--directory` emits.
- **Real temp repos:** nested `.gitignore` plus `info/exclude` plus a global file set through a scratch `core.excludesFile`; rule attribution per line; collapsed folders; preview matching the result after writing; untrack keeping the file on disk and staging the deletion; undo in both cases, including refusal after an outside edit; a rule added from a linked worktree landing in the common `info/exclude`; CRLF files keeping CRLF.
- **Smoke:** menu entries and their enabled state (tracked, conflicted, multi-select with mixed extensions), the dialog preview and untrack warning, the toast with Undo, and viewer counts on a fixture.
- **Perf:** time `load_ignore_rules` on a throwaway clone with a populated `node_modules/` or `target/`, and record the numbers in `docs/perf.md`.
- **Screenshots:** a `tests/visual/ignore_screenshots.tscn` covering the menu, the dialog in both themes, and the viewer, on throwaway fixtures.
- Strings in `gitbello.csv` (EN and IT). `cargo xtask check`.

## 6. Decisions (2026-11-02)

1. **Milestone:** M7.7, in two parts. **(a)** Ignore from Changes, the dialog and untrack. **(b)** The rules viewer, "Show ignored files", templates and the folder hint.
2. **Quick entries** write to the shared root `.gitignore` without the dialog. The last target used in the dialog is remembered per repository.
3. **Untrack checkbox:** on by default for shared rules, off for local ones.
4. **Nested `.gitignore`:** the root by default. A nested file can be chosen in the dialog, with the pattern rewritten relative to it.
5. **Global excludes file:** read-only in (a), and a writable third target ("All my repositories") in (b).
6. **Skip-worktree:** yes, as a follow-up after (b). It gets its own action and is listed in the viewer.
7. **After untracking:** `.gitignore` and the removed files are included in the commit together. The user writes and makes the commit.
