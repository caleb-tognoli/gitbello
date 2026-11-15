# gitbello UX

How the main workflows look and behave. Architecture is in [ARCHITECTURE.md](ARCHITECTURE.md); diffs, history, Compare, syntax colours and menus have their own docs (linked below).

## Window layout

```
File  Edit  View  Repository  Branch  Commit  Worktree  Help
[• gitbello  x] [spritesheetbelli  x] [⌂ Home]               <- repo tabs
[⎇] ( main  2 ↑1 ) | ( login  1 ) ( docs-pass )            <- worktree strip
[ Branch: main          v ]  [ Push ↑1        v ]  ( Changes 3 | History | Shelves )
[ Merging feature/login into main · 2 conflicts   Continue  Abort ]  <- only during an operation
+---------------------------+---------------------------------------+
| file list / commit graph  | diff of the selected file, or         |
|                           | commit details + files + diff         |
|  commit box (Changes)     |                                       |
+---------------------------+---------------------------------------+
```

## Menu bar

Built from the action registry with `ActionMenu` (see [MENUS_AND_TOOLTIPS.md](MENUS_AND_TOOLTIPS.md)): disabled items are greyed with the reason as their tooltip, and every item shows its shortcut. The top row uses compact 13 px text; dropdowns stay at 14 px. F10 opens File on Windows/Linux, and Alt plus the localized menu's initial opens a menu (unique letters per language); native macOS menus keep platform behaviour. The menus are File · Edit · View · Repository · Branch · Commit · Worktree · Help.

## Repo tabs

One tab per repo, never per worktree; the title is the repo name.
- An attention dot shows the most important state across the repo's worktrees: conflict or operation in progress (error colour), then changed files (modified colour), then ahead/behind (accent). Its tooltip lists each worktree with its state.
- A small spinner shows while any job of the repo runs.
- The tab-strip **+** opens Home in a Home tab.
- Opening a linked worktree's path (open dialog, recent list, command line, drag and drop, restored tabs) focuses its repo's tab and selects that worktree's chip.

## Home

One page for finding, opening and adding repositories. It fills the window when no tab is open and opens as a Home tab from the tab-strip **+** or Ctrl+N. There is at most one Home tab, always last: **+** focuses it when it exists. Choosing a repository turns the Home tab into that repository's tab, or focuses its tab and closes Home when it is already open. Home tabs are not saved with the open tabs; tabs keep being restored at launch, and Home shows when none come back.

```
[ Filter repositories…                          ]       [ + Add v ]

Recent
 +-----------+ +-----------+ +-----------+ +-----------+
 | gitbello  | | api       | | site      | | godot-x   |
 | main  •   | | dev  ↑2   | | main      | | ! missing |
 | 2 min ago | | yesterday | | 3 days ago| | Locate…   |
 +-----------+ +-----------+ +-----------+ +-----------+

All repositories (34)                     Sort: Name v   Group: Folder v
 * gitbello   C:/caleb/dev/gitbello   main •    open
   api        C:/work/api             dev ↑2                         ...
   > C:/caleb/oss (12)
   cloning tokio  [#######---] 64%                              Cancel
```

- **Filter field**, empty and focused each time Home shows: matches names and paths in any case. Enter opens the first match; ↑ ↓ move through the list (rows scroll into view; Up on the first row goes back to the filter).
- **Recent:** the 8 most recently opened repositories as cards, in equal columns clear of the scroll bar: name (or display name), current branch, attention dot (the tab dot's rules), ↑↓ from the last fetch, and when it was last opened. Repositories with the same folder name are told apart by parent folders (`Paths.short_labels`), here and in File → Open recent.
- **All repositories:** the whole library, sortable by name, last opened or path, flat or grouped by parent folder (collapsible). Pinned repositories come first. Rows show name, path (dim), branch, dot and ↑↓, and "open" when the repository has a tab.
- **Row actions** (the ⋯ button and right-click; registered `home.row_*` actions, hidden from the palette): Open, Pin / Unpin, Rename… (display name only; the folder is not touched), Change location…, Show in file manager, Open terminal, Copy path, Remove from list. Remove never touches files and its toast offers Undo; for a repository with an open tab it asks first ("Remove and close tab").
- **Change location** takes a folder that must be a git repository (a worktree or subfolder resolves to its repository as everywhere else). A different root commit gets a warning ("This looks like a different repository") with Use anyway. The display name, pin and per-repo UI state move with it.
- **Missing folders:** the row says so, with Locate… (Change location) and Remove, instead of failing on open. Whether a folder is missing comes with the summary, so the main thread never touches a slow or gone drive.
- **Status** is read lazily for visible rows and cards only, as low-priority reads with `--no-optional-locks`, at most two at a time: branch, dirty, and ↑↓ against the upstream as last fetched. Home never fetches and never watches repositories without a tab.
- **Drag and drop:** a repository folder is added (and opened); a folder that is not a repository but contains some offers Scan.
- Opening a repository any other way (Ctrl+O, the command line, drop, palette, restored tabs) adds it to the library (`library_root`: a linked worktree or subfolder lists its main repository) and updates its last-opened time. File → Open recent and the palette read the library.

**Add ▾** (a menu button on Home; each entry is also an action, in File and the palette):

| Entry | Flow |
|---|---|
| **Clone…** | Repository URL, filled from the clipboard when it holds a git URL. Destination = the default clone folder (Settings) plus a folder name taken from the URL, editable. Options: branch (empty for the remote's default), with submodules. Runs in the background as a progress row on Home with Cancel and an inline error (a failed clone keeps a row with Retry and Dismiss); several clones can run at once. When done the repository joins the library; a toast offers Open, and the Home tab that started it opens it if nothing else was chosen there meanwhile. |
| **Add existing folder…** (Ctrl+O) | The native folder dialog. A subfolder resolves to its repository root, and a linked worktree to its main repository with that worktree's chip selected. A folder that is not a repository offers **Initialize here** or **Scan inside**. |
| **Scan folder…** | Pick a root and a depth (default 3). A background job walks the folders without following links, skipping `node_modules` and the inside of `.git`, and stops descending at a repository (submodules are not listed). Linked worktrees fold into their main repository. Results come into a checklist: repositories already in the library are shown checked and disabled, bare ones start unchecked, the rest are checked; **Add selected**. |
| **Create…** | Name, location, initial branch (`main`), an optional `.gitignore` template (bundled: Godot, Rust, Node, Python, Unity, Visual Studio; from github/gitignore, CC0) and an optional README. With either option it makes a first commit. No license picker. |
| **Initialize folder…** | `git init` in an existing folder with files, initial branch, optional `.gitignore` template, optional first commit of everything. |

Dialogs of these flows put Cancel then OK on the right, like forms (`FormDialog.align_right`).

## Worktree strip

One row: a worktree icon (it opens the worktree list), the main worktree's chip, a thin line, then the linked ones by folder name.
- A chip is borderless text (the shown one filled): the folder name without the repository's name in front (`shop-login` → `login`; core's `worktrees::short_name`), capped in width with "…", then one marker: a missing-folder, conflict/operation (in the conflict colour) or lock icon, else a dot when it has changed files. Its tooltip card has the folder, branch (or detached commit), path, changed and conflicted files, ↑ahead ↓behind, the operation and the lock reason. Middle-click shows its folder in the file manager.
- Selecting a chip switches the whole tab content. Each worktree keeps its own view, selection and scroll positions. Ctrl+1…9 select chips 1–9.
- Chip menu: Open in ▸ (terminal, file manager), Copy path | Branch ▸ (the branch menu of the branch checked out there, acting on that branch; none for a detached worktree) | Lock… / Unlock, Delete…. Delete is also offered for the shown worktree, which moves to the main one; it offers to delete its branch too, on by default, saying what it would lose, and its remote branch (see **Deleting branches**).
- The worktree list works like the branch popover: a filter (folder or branch; Enter chooses the first match, else the shown worktree; Enter on a filter that matches nothing opens New worktree named after the text, and the empty line says "No match · Enter: new worktree"), a scrolling list of every worktree with its marker, branch, changed files and ↑↓ (the shown one highlighted; right-click opens the chip's menu), and a footer: **New worktree…** (Ctrl+T), then icons for Clean up merged worktrees… and, only while a folder is missing, Prune.
- When the chips don't fit, the strip scrolls (`ScrollRow`, with ‹ › buttons); the worktree icon still lists all worktrees. Selection and chip-layout changes reveal the selected chip with minimal scrolling; unchanged refreshes keep manual scrolling.

## Branch button and popover

The big button shows the active worktree's branch ("Detached at abc1234" when detached) and opens a popover (Ctrl+B):
- A filter field, then one flat list where each branch appears once, each row with ↑↓, under plain section headers (nothing folds): Recent, then Local, then Remote. Recent is the current branch followed by the branches last checked out in any worktree (from the HEAD reflogs), five rows in all; Local is the other local branches A–Z. With five local branches or fewer, or no other branch checked out, there is no Recent and no Local header: the current branch comes first, then A–Z. Remote lists, A–Z, only the remote branches no local branch tracks. Names are shown in full with their prefix muted (`feature/`, `origin/`); a name too wide loses its prefix first. Each branch row has a branch icon, except the current branch uses a checkmark instead.
- The list opens with the current branch selected (nothing when it is not listed); while filtering, the sections keep their headers (empty ones are dropped) and the first match is selected. An unmatched search shows a quiet "No matching branches" message. Enter or a single click checks out; Alt+Enter opens the highlighted branch in a new worktree.
- In merge mode the current branch is left out, Recent holds five other branches and the current branch's upstream comes first in Remote.
- A branch checked out in another worktree has a worktree icon instead (its tooltip names the folder); choosing it selects that worktree's chip instead of checking out.
- A New branch button. Row menus are the branch menu ([MENUS_AND_TOOLTIPS.md](MENUS_AND_TOOLTIPS.md)); Delete on a row deletes it, like the menu. A new branch made from the current commit takes local changes along without asking.
- **Remotes and tags:** Repository → Remotes… and Tags… open management dialogs (add, rename, re-point, remove; create light or annotated, delete, push tags).

## Sync button

One big button whose action follows the active branch's state:

| State | Label | Click |
|---|---|---|
| No upstream | Publish branch (with the count of commits on no remote branch) | push and set upstream |
| Behind | Pull ↓N | pull with the configured mode |
| Ahead | Push ↑N | push |
| Diverged | Sync ↑M ↓N | pull with the configured mode, then push if the pull succeeded |
| Rewritten (diverged only by your own amend/rebase/reset) | Force push ↑M ↓N (warning icon) | the Force push confirmation, worded for the rewrite |
| Up to date | Fetch | fetch |

- The counts are pills (an arrow icon and the number): commits to push in the accent, commits to pull in amber. The same pills show ahead/behind everywhere: worktree chips and their tooltips, the branch list, Home and the "No local changes" suggestion. Without an upstream (or with a gone one), outgoing commits are those on no remote branch (`rev-list HEAD --not --remotes`); without any remote branch nothing counts.
- Its tooltip is a card: the action and its shortcut (Ctrl+Shift+Y), "1 commit to origin/main", "Fetched 3 min ago".
- While a job runs the button keeps its width and says one short verb ("Pushing…") with a progress line; what runs and git's progress text are in its tooltip. The ▾ part then offers Cancel.
- With the default pull mode `ff-only`, a diverged pull cannot succeed, so a click shows the fix toast (Pull and merge / Pull and rebase) straight away and the push follows the chosen pull.
- **Rewritten:** the branch once pointed at its upstream's commit (its reflog) and every upstream commit HEAD lacks is yours (`git var GIT_AUTHOR_IDENT`), so merging or rebasing would bring the old versions back. On the remote's default branch or a shared-looking name (`main`, `master`, `develop`, `development`, `trunk`, `release/*`) the button stays Sync and its toast (shown whatever the pull mode) adds Force push… to Merge and Rebase. Anyone else's commit up there, or one the branch never pointed at, keeps it Diverged.
- Force pushes pin the lease to where the last fetch saw the remote branch when the user was asked (`--force-with-lease=<ref>:<oid>`), so a background fetch meanwhile cannot let it overwrite commits nobody looked at.
- The ▾ part offers Fetch, Pull and merge, Pull and rebase, Push, and Force push… (with lease, confirmed), each with its own icon and shortcut.
- Fetch is repo-wide, so it refreshes the ahead/behind of every chip. Pulls run with `--autostash` and explicit flags that win over the user's `pull.rebase` / `pull.ff` config.

## Main panes

The panes switch between **Changes**, **History**, **Shelves**, **Compare** and **File history** with a segmented switch that shows counts, in the header row after the Branch and Sync buttons (which cut long captions short so the switch stays visible). Shelves appears only when at least one shelf exists anywhere in the repository; Compare and File history only while one is open, each with a close × on its tab (`ClosableViewTab`). Alt+1 … Alt+5 pick the switch's buttons by place; Alt+PageDown / Alt+PageUp go round them.
- **Changes:** the file list and commit box on the left, the selected file's diff on the right.
- **History:** the graph list on the left; on the right, the selected commit's details above its file list, which sits beside the diff of the selected file. See [HISTORY.md](HISTORY.md).
- **Shelves:** see **Shelves** below.
- **Compare:** see [COMPARE.md](COMPARE.md). **File history:** see [HISTORY.md](HISTORY.md#file-history).
- All views share one saved sidebar width, so switching views does not move the divider. It is app-wide, so switching tabs or worktrees does not move it either. History also remembers the details' height and the file list's width, app-wide as well (Compare and File history follow them).
- Empty and loading states use `EmptyState` and `LoadingIndicator` ([ARCHITECTURE.md](ARCHITECTURE.md) §3.7).

## Operation banner

While a merge, rebase or cherry-pick is in progress, a full-width banner sits under the Branch/Sync row: "Merging feature/login into main · 2 of 3 conflicts left" (cherry-pick: "Cherry-picking abc1234 'subject'"; rebase: "Rebasing fix onto main · commit 2 of 5"). It is the only red element in the UI, and the chip shows a marker too. Buttons:
- **Continue**, disabled until no conflict is left. Merge and cherry-pick: the same as the commit box's button. Rebase: `rebase --continue` with no editor.
- **Skip** (rebase only).
- **Abort**, always confirmed; the confirmation says how many resolved files go back.
- **Open resolver**: selects the first unresolved file in Changes.

## Feedback

- **In place:** the control that started a job (a big button, a chip, a row) shows its progress and is disabled until the job ends. Cancellable jobs cancel from the control's ▾ or with Esc.
- **No origin** (palette, shortcut, menu): a progress toast that shows the job and closes when it ends, or turns into its success toast when it has one. Auto-fetch stays silent unless it fails (one report per failure streak).
- **When a success toasts:** only when it offers an action (Undo, Open) or nothing on screen shows the result. Results the UI already shows get no toast: commit and amend (the undo strip), sync, pull and push (the Sync button and counts), checkout (the branch button), merge, continue, skip, abort, resolve and undo commit (the banner, resolver, history or Changes), cherry-pick, worktree changes (the chips), shelf restore and rename, tags and remotes (the list acted on), and Home's add and relocate (the cards). Toasts stay for discards (Undo), removing a repository (Undo), a finished clone (Open), copying a hash, shelving (the files leave the list), pushing a tag, new worktrees (Undo), deletes (Undo), and branch create, rename and upstream changes made from the closed branch popover.
- **Toasts** are compact cards stacked at the bottom right of the content area: an icon for the kind (a green check, a red warning, a spinner), the text, inline action buttons in the accent colour and a close button; successes have a thin line showing their time left and fade in and out. The stack is bounded to one-third of the content's height (at most 280 theme units) with scrolling and an overflow count. Capacity never evicts errors, Undo or progress; hidden actionable notifications pause their remaining lifetime until exposed. Successes are short ("Copied 1a2b3c4") and hide after 6 s, or 12 s when they offer Undo. Their remaining lifetime pauses while hovered or while keyboard focus is anywhere inside that toast. Errors stay until dismissed and offer the classified fixes and Details (a dialog with the command and its output). Undo appears only where undo really exists.
- **Blocking overlay:** dims only the affected worktree's panes; the chips and other tabs stay usable. It is for writes that change that worktree's files and must finish before more input makes sense (checkout, pull, merge, rebase, cherry-pick, shelve, restore). It appears after 300 ms, shows what runs and its progress, and offers Cancel where git allows. The main thread never blocks: the overlay only blocks input.

## Changes view

One list of changed files with checkboxes: [x] included in the commit, [ ] left out, [-] partly included (some hunks or lines). The selection is gitbello's own (D10, [ARCHITECTURE.md](ARCHITECTURE.md) §3.10).
- The header reads "N changed files" with a check-all box. The checkboxes are the only multi-file selection: one row is highlighted at a time (it drives the diff and the files' menu), and clicking a checkbox highlights its row. Space toggles the highlighted row's checkbox. "Selected" in action names means checked.
- Right-clicking the changed-file header offers Shelve selected…, Shelve all…, Discard selected… and Discard all…. "All" covers every file currently shown, "selected" the checked ones among them (`RepoSession.shown_picked_paths`), never the highlighted row; hidden files are untouched when filtering. The files' menu acts on its file: Open, Show in file manager, Copy path, File history; the conflict choices; Ignore ▸, Restore line endings; Shelve…, Discard…. Shelving asks for a name, discarding is confirmed and undoable.
- A filter above the header (Ctrl+F): a text box matching paths in any case, and an options popover (the sliders button, Alt+Down) with chips for files included in or excluded from the commit, new, modified or deleted files, line-endings-only files and Show ignored files ([MENUS_AND_TOOLTIPS.md](MENUS_AND_TOOLTIPS.md#options-popovers)). While it hides files the header reads "2 of N changed files" and the check-all box covers the files shown. Escape clears only the text. The filter lives in core (`ChangeFilter`), so rows stay in Rust.
- Rows carry an `EOL` chip when only line endings changed ([DIFF_VIEW.md](DIFF_VIEW.md#line-endings)). A folder of build output that fills the list gets a one-button hint above it ("Ignore node_modules/", [IGNORE_RULES.md](IGNORE_RULES.md)).
- The diff gutter has hunk and line checkboxes.
- The commit box sits under the list: summary, description, and a "Commit 2 files to main" button (Ctrl+Enter), disabled with a tooltip reason when nothing is included or the summary is empty. Hook output shows on failure.
- **Amend** is entered from the HEAD commit's History menu ("Amend…", Ctrl+Shift+A), not a persistent checkbox. It opens the full proposed commit against its first parent (the empty tree for a root commit), loads its message, and temporarily shows "Amending “<commit summary>”", Cancel, and "Save amended commit". Original changes start included; existing working selections, including partial and overlapping changes, are preserved through a temporary-index tree snapshot. HEAD, the real index and working files are not changed by entering or cancelling amend. Unchecked files/lines remain in the working tree but are omitted from the replacement commit; unchecking everything can create an empty replacement commit. Cancel restores the ordinary draft and selection without undoing file edits; success restores the draft and returns to ordinary Changes. Discard explicitly restores working content to the original HEAD, not the amend baseline; line discard is unavailable in the parent-relative diff. Known pushed commits show a persistent force-push warning and require confirmation on Save. Saving uses `--amend`, preserving authorship and merge parents; a stale HEAD is rejected.
- **Empty state:** "No local changes" with big suggested actions for what makes sense now: Push ↑N or Pull ↓N when relevant, Open terminal, New worktree.

## Undo commit strip

Under the commit button: "<subject> · committed 3 min ago · Undo" for HEAD while it is unpushed (not on its upstream; with no upstream, not on any remote branch). It is hidden during an operation.
- **Undo:** `reset --mixed <first parent>` after checking that HEAD is still that commit. The commit's changes join the local changes and its message fills an empty commit box. The next unpushed commit then shows, so several commits can be undone in a row into one set of changes. The first commit of a branch makes the branch unborn again (`update-ref -d`).
- **Undoing a merge commit** asks first: **Undo, keep changes** (everything merged becomes local changes and the merge is lost) or **Remove merge** (`reset --keep <first parent>`: the merged changes are not brought back, since they are still on the other branch; local changes are kept).
- **Undoing a rebase:** after a clean rebase made here, while HEAD is still its result and unpushed, the strip reads "Rebased topic onto main" and Undo moves the branch back (`reset --keep <before>`, after checking HEAD); local changes are kept.
- Fast-forwarded commits show as ordinary commits.

## New worktree

```
New worktree
┌──────────────────────────────┐
│ feature/login▏               │   one searchable branch field
├──────────────────────────────┤
│ + Create feature/login       │
│ ⎇ feature/login-old   local  │
│ ☁ origin/feature/login       │
└──────────────────────────────┘
From    origin/main ▾              searchable: branches, remote branches, tags, a commit
Folder  .worktrees/feature-login   ✎ 📁
☑ Run setup: copy .env*, npm ci
                      [Create]
```

- **One dialog** (Ctrl+T, `RepoOps.new_worktree`) for every case. The branch field searches like the branch popover (`WorktreeBranchList`, a fixed-height list the field keeps the focus over: Up/Down/Page move its selection, the selected row is the choice): an exact local branch, else an exact remote one then **+ Create <name>** (from the From base), then the other local and untracked remote branches containing the text. An existing local branch is checked out, a remote one as a local branch tracking it, and the From row hides. A branch checked out in a worktree is muted with that folder and cannot be chosen.
- **Name input:** the branch prefix is prefilled (typing goes after it); a space becomes `-` as you type; other invalid names show the inline error.
- **From** defaults to the remote's default branch (`default_base`) and opens `BasePopover` (Local, Remote, Tags; text naming none of them is offered as "Use <text>" under Revision). History's commit menu fills in a commit (shown short).
- **Fetch:** a remote base fetches only that branch first (`git fetch <remote> <branch>`). If it fails or takes over ~5 s, the worktree is made from the last known ref and the toast says so ("Based on origin/main from 2 h ago"); a remote branch never fetched still fails.
- **Folder:** a muted preview line from the worktree template, with ✎ (turns it into the folder field) and the folder button (a picked empty folder is the worktree's, another holds it). A taken folder gets `-2`, `-3`… (`Core.free_worktree_path`) and the line says so ("<name> is taken") instead of blocking Create.
- **Setup:** a per-repository setting in the library (`[repo.setup]`, never a committed file), edited in Worktree → Setup… (`worktree.setup`): "Copy files" (glob patterns of ignored files copied from the **main** worktree, one per line) and "Then run" (a command run in the new worktree through `cmd /C` or `sh -c` with `CI=1`, keeping the last 16 KB of output; cancel kills the process tree). The dialog shows a ticked "Run setup: …" check box when the repository has one. Setup runs after the create job, as a read job outside its rollback: a failed command keeps the worktree and shows an error toast with its exit code, the output as details, Run again and Open terminal.
- **One click:** "Open in new worktree" on a branch's menu (branch list, History ref chips) and Alt+Enter on the branch list's highlighted branch skip the dialog: the worktree is made at the template folder with setup, and the dialog opens only when that cannot be done. History's commit menu has "New worktree here…" (the dialog, From filled in).
- **After create:** the new worktree's chip is selected; nothing opens outside the app. Every create shows a toast "New worktree <branch>" with **Undo** (`undo_new_worktree`), which cancels a running setup, force-removes the worktree (setup's ignored output included) and deletes the branch if this create made it; it refuses once there are tracked changes or new commits there.
- Creating runs as one job (`create_worktree`, core `NewWorktree { branch, start: NewBranch { base } | Existing | Remote { upstream }, path }`) with rollback if any git step fails.

## Cleanup merged worktrees

Lists worktrees whose branch is merged into the base branch, or whose upstream is gone ("probably merged", which covers squash merges), with what each would lose (dirty, unpushed). One row per worktree with two toggles, Branches and On origin; Delete counts the ticked rows, removes them (`git worktree remove`) and deletes their branches here and on the remote through the branch delete job. The toast says "Deleted x here and on origin".

## Deleting branches

One dialog, which first reads what the branch would lose (`load_branch_delete_info`: commits the base lacks, commits not pushed, its remote branch, its worktree), so an unmerged branch is deleted in one step with the loss shown, not refused and asked again:
- The dialog lists what goes as rows (`FormDialog.add_item`): a check box, an icon (branch, worktree folder, remote, tag), the name in a chip and short facts at the end, warnings amber ("2 commits not in main · 1 not pushed") and "merged into main" green. What the dialog is about is a fixed, ticked row; the others can be unticked. No "Delete X?" sentence: the title says it. Delete dialogs are narrow (`narrow_width`).
- The remote branch's row shows while the remote still has the branch: ticked, unless the branch has commits the base lacks (deleting both would lose them). Not remembered.
- The branch checked out here can always go: in the main worktree it switches to the base's local branch first (the usual switch, asking about local changes); in a linked worktree it deletes the worktree with it and the main one shows. A branch checked out in another linked worktree goes with that worktree. It cannot go while it is the base's branch checked out here, or checked out in the main worktree; the action says why.
- One job (`delete_branch_with`, `runtime/branch_delete.rs`): the worktree, then the remote branch (a failure keeps the local branch; a remote that lost it already is fine), then the local branch. The toast offers Undo: the local branch at its commit, the remote branch pushed back with a plain push (never over commits pushed since), the upstream. A worktree's folder does not come back.
- Delete remote branch… on remote branches ("gone for everyone"), offering the local branch that tracks it (ticked when it has nothing the remote lacks). Delete tag offers its remote, off.
- Deleting a worktree checks its branch in the background first (a spinner while checking) and keeps a detached worktree's commits as a renamed branch unless unticked. On Windows, a worktree a program runs from or a terminal sits in gets an in-use toast (`gitbello-cli in-use <dir>` lists the programs) with Try again.

## Merge and rebase

- **Scope:** merge into the current branch, or rebase the current branch onto the other one (the active worktree's branch).
- **Entry points:** one action for both, **Merge / Rebase…** (`branch.merge`, Ctrl+Shift+B; `commit.merge` is Merge / Rebase commit…): the branch menu, the Branch menu and the palette (the branch list in merge mode), and the graph menu of a commit or ref label, shown only when that commit is not in HEAD (`in_head`). The dialog's strategy picks merge or rebase.
- **Preview** (a read job, nothing touched): `merge-tree --write-tree --name-only -z --messages HEAD <ref>` (exit 1 means conflicts), `rev-list --count` and the first 50 commits of `HEAD..<ref>`, `merge-base --is-ancestor` for fast-forward, HEAD's own commits, merges and pushed commits, and the merged files intersected with the local changes. Remote-tracking refs are used as of the last fetch.
- **Dialog** (`app/merge/merge_dialog.gd`): titled "Merge into main" ("Rebase main" with Rebase picked). Rows:
  1. `[⎇ topic ▾] → [⎇ main]` followed by the badges, one row that wraps when long names or many badges do not fit. The source chip opens the branch list in merge mode; another branch checks again in place and the strategy goes back to that case's default. Badges (`SummaryBadge`: tinted pills, icon and text): `✓ No conflicts` green, `⚠ Conflicts` red or `Fast-forward` accent; `12 files`; `⚠ 2 shelved` amber (files in its tooltip); for Rebase also `⚠ Rewrites 2 pushed` amber and `2 merges flattened`. While checking: a turning icon and "Checking…" in their place. A final state (up to date, failed) puts its line under the branches.
  2. The strategy, joined buttons with icons: **Merge | Squash | Fast-forward | Rebase**; one that cannot run is disabled with the reason as its tooltip. It opens on Fast-forward when possible, else Merge, and is not remembered.
  3. The merge commit's message (Merge only), one line that grows.
  4. **Conflicts · N**, then **Commits · N** (History's compact rows: avatar, subject, author · age, short hash; the first 50, then "and N more"); for Rebase **To replay · N** (HEAD's own commits) and **Incoming · N** (folded). Each section (`MergeSection`) folds and scrolls after six rows; Commits starts folded when there are conflicts.

  The primary button says what will happen: Create merge commit, Squash 3 commits, Fast-forward main, Rebase main, Merge / Squash / Rebase and resolve…, or Shelve changes and merge (squash, fast-forward, rebase). Nothing to merge or a failed preview leaves the chips, one line ("main already has everything in topic", or why) and Close.
- **Rebase:** offered when HEAD is on a branch with commits of its own and the other side has new ones (otherwise it is a fast-forward). Picking it runs a check (`load_rebase_check`, a read job): the commits `rebase` would pick (`rev-list --reverse --no-merges --right-only --cherry-pick <ref>...HEAD`) replayed one by one with `merge-tree --write-tree --merge-base=<commit>^` on the result so far (an unreachable `commit-tree` each), up to 100; it stops at the first conflict ("Stops at abc1234 subject", its files under Conflicts), and past 100 says "Checked the first 100". `rebase` refuses local changes, so all of them go on a shelf first. Commits already on the upstream are counted (a force push follows through Sync's Rewritten flow, which asks); merges are flattened (no `--rebase-merges`).
- **Local changes:** when they overlap the merged files, the dialog warns and the primary becomes "Shelve changes and merge" (an automatic shelf, the merge, then a restore after a clean merge; after a conflicting merge the shelf stays and the Changes view offers it back once the merge is committed or aborted). Changes that don't overlap stay put and are not part of the merge commit.
- **Running:** `merge` with `--no-ff` (Merge) / `--squash` / `--ff-only`, the message without an editor, or `rebase <ref>`, each with `-c merge.conflictStyle=zdiff3` so the base is in the markers. Merges pass git the ref's short name when it is unique, so markers and messages read `topic`. It blocks the worktree (overlay). Conflicts open Changes with the first conflicted file in the resolver.
- **Finishing a merge or cherry-pick in Changes.** The commit box is prefilled from `MERGE_MSG` (a cherry-pick keeps the original author) and reads "Commit merge into main" / "Commit cherry-pick". The checkboxes are locked: the commit takes the index (git's result plus resolved files), so local changes that were there before the merge stay out. During a rebase the commit box is disabled ("Use Continue in the banner"). A squash merge is not an operation: its staged result is committed like any other change, with a message built from the squashed commits' subjects prefilled.
- **Cherry-pick** from the graph's commit menu (a merge against its first parent) or several commits from Compare ([COMPARE.md](COMPARE.md)).

## Conflict resolver

It lives in the Changes view: conflicted files are listed first, and selecting one shows the resolver in the diff pane. Unified or Side by side follows the diff's text mode.
- **Unified:** the file with each conflict as a block: a header "Conflict 1 of 3 · [Ours] [Theirs] [Both ▾]" (Both: ours then theirs, or theirs then ours), then the ours lines and the theirs lines labelled with their branch.
- **Side by side:** ours on the left and theirs on the right, aligned per block, with Take ours · Both ▾ · Take theirs in the block header.
- **Show base:** a toggle that adds the base lines to each block (full-width rows side by side). It needs zdiff3 markers. For a conflict made outside gitbello without them, it offers "Recreate conflicts with base" (`checkout --conflict=zdiff3`, confirmed if the file was edited).
- **Choices** rewrite that block in the working file (line endings kept); Ctrl+Z (Edit → Undo) undoes block choices, even after they resolved the file (the conflict comes back from the resolve-undo record). Hand edits go through Open (the default app); the file reloads through the watcher. Chosen blocks are marked green in the preview and the minimap strip ([DIFF_VIEW.md](DIFF_VIEW.md#minimap)).
- **Resolving:** a file is staged (`git add`) as soon as no markers are left, whether that came from choices or from an outside edit (a conflict scan after each status). The file list shows the progress ("2 of 3 resolved"); a resolved file's menu offers Reopen conflicts (`update-index --unresolve`, so modify/delete conflicts reopen too; confirmed).
- **Non-text conflicts** show a card instead of blocks (with Show changes over the changed side where one side has the file):
  - Modify/delete: Keep the file (the modified side) or Delete it.
  - Binary: Use ours or Use theirs, with sizes; an image shows ours | theirs previews.
  - Add/add: blocks when both sides are text, otherwise pick a side.
  - Renames: pick a side.
- Conflicts are read from `ls-files -u -z` and the working file's markers; stage blobs come from `cat-file blob :1:<path>`, `:2:` and `:3:`.
- Keys: Alt+O / Alt+T / Alt+B / Alt+Shift+B use ours, theirs, both, both reversed for the conflict at the cursor; F8 / Shift+F8 next / previous conflict.

## Shelves

Shelves replace the classic stash workflow (D11).
- A shelf is a git stash (untracked files included) whose message is `gitbello-shelf: <branch>: <name>` (automatic ones `gitbello-shelf (auto): <branch>: <name>`). It is identified by its commit, never by `stash@{n}`, because the stash stack is shared by every worktree and its indices shift. Every write looks the stash index up by commit right before it runs.
- A shelf belongs to its branch and shows in any worktree that has that branch checked out. Stashes made elsewhere are listed too, with the branch read from git's `WIP on <branch>:` / `On <branch>:` message.
- **Shelve:** right-click a file → Shelve… and name it; right-click the changed-file header to shelve the checked files or every listed file. Whole files only (`git stash push -p` is interactive).
- **Shelves view:** the left list holds shelf names under collapsible branch headings (the current branch first and the only group expanded on load); refresh keeps the group choices, and collapsing the selected shelf's branch keeps its details visible. A name filter has a branch picker (an options popover of check rows: All branches with the shelf count, then each branch with its count). Selecting a shelf shows History-style details (summary, branch, date, hash) above a separate file list beside the read-only diff. Click the name (or Rename) to edit it inline: Enter or leaving the field saves, Escape cancels, an empty name keeps the original. Restore and Discard are quiet buttons at the far right of the name row. Filtering away the selection hides the whole right side; the empty-filter reason appears only in the left list. The preview works with a clean working copy and has no commit checkboxes. The view's button counts shelves across the repository and hides at zero, returning to Changes if Shelves was active; Undo or the first new shelf reveals it without switching views.
- **Restore** applies then drops on success (`stash apply --index <oid>`, without `--index` when the staged part does not apply; conflicts keep the shelf). **Discard** is confirmed and its toast offers Undo (`stash store` of the remembered commit, for the session). **Rename** is `stash store -m <new> <oid>` then a drop of the older entry; renaming the newest shelf protects its commit under `refs/gitbello/rename-shelf/<oid>` while replacing the top entry, with rollback.
- **File actions:** right-click a shelved file to Restore file or Discard file; see [SHELF_FILE_ACTIONS.md](SHELF_FILE_ACTIONS.md).
- **Switching branch with changes** asks: **Bring them to feature** (stash, switch and re-apply) or **Leave them on main** (an automatic shelf, then the switch; the changes come back if the switch fails). When a worktree is on a branch that has automatic shelves, the Changes view offers them back: "3 changes were left on main · Restore" (the newest automatic shelf).
- Shelf jobs refresh the stash list of every open worktree of the repository; shelve and restore block the worktree.

## Command palette

`Ctrl/Cmd+K` (and `Ctrl/Cmd+Shift+P`) opens a fuzzy search over all actions, branches (to check out), repos and their worktrees (to switch), and files (to open their diff). With no search text, it lists only available commands. A search also reveals unavailable commands, dimmed with a compact hint and the full disabled reason in a tooltip. Hints wrap rather than being truncated. Unavailable rows cannot be selected or executed, and keyboard navigation skips them.

## Forms and dialogs

Labels in a left column, fields on the right, hint text under a field, the primary button in the accent colour (as in spritesheetbelli's export dialog). `FormDialog` provides this layout for every form.

## Keyboard

Every shortcut is rebindable in Settings → Keyboard ([MENUS_AND_TOOLTIPS.md](MENUS_AND_TOOLTIPS.md#settings--keyboard)). Highlights:

| Keys | Action |
|---|---|
| Ctrl+K / Ctrl+Shift+P | command palette |
| Ctrl+Tab / Ctrl+Shift+Tab | next / previous repo tab |
| Ctrl+1 … Ctrl+9 | select worktree chip 1–9 |
| Ctrl+B | branch popover |
| Alt+1 … Alt+5 | the first … fifth view of the switch as it shows |
| Alt+PageDown / Alt+PageUp | next / previous view |
| Ctrl+T | new worktree |
| Ctrl+N | Home tab |
| Ctrl+O | add existing folder |
| Ctrl+, | Settings |
| Ctrl+/ | Settings → Keyboard |
| Ctrl+F | find: the current view's filter or search field |
| Alt+Down | the focused field's options popover |
| Ctrl+Enter | commit |
| Ctrl+Shift+A | amend |
| Ctrl+Z | Edit → Undo (the newest file-level undo) |
| Ctrl+Shift+Y | Sync |
| Ctrl+Shift+B | Merge / Rebase… |
| Ctrl+Shift+C | Compare… |
| Ctrl+Shift+D | next diff mode |
| Ctrl+Shift+H | File history of the file in focus |
| Ctrl+Alt+B | Blame on / off |
| F7 / Shift+F7 | next / previous change in the diff |
| F8 / Shift+F8 | resolver: next / previous conflict |
| Alt+O / Alt+T / Alt+B | resolver: ours / theirs / both |
| F | History: go to the current commit |
| F3 / Shift+F3 | History: next / previous search match |
