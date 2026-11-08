# Changelog

All notable changes to gitbello. The version is set in `rust/Cargo.toml`
(`workspace.package.version`), `godot/project.godot` (`application/config/version`) and
`godot/export_presets.cfg`, and shown in Help > About.

## 1.1.0

### Compare
- Compare any two branches, remote branches, tags or commits, or one of them with the
  working copy, Since fork (like a pull request) or Exact. Files and Commits tabs, with
  the commits only on each side and an All changes row.
- Open it from Branch > Compare… (Ctrl+Shift+C), a ref's menu (Compare with current
  branch, Compare with…), or two commits Ctrl+clicked in History; recent comparisons are
  kept.
- Restore a file from either side (with Undo) and cherry-pick commits onto the current
  branch.

### Views
- The Changes, History, Shelves or Compare view you pick stays when you switch worktree
  or repository tab.
- Alt+1 to Alt+4 show Changes, History, Shelves and Compare (Ctrl+Shift+G and
  Ctrl+Shift+H are gone); Ctrl+PageDown and Ctrl+PageUp go to the next and previous view.

### History
- Two-line rows with the author's avatar, relative dates and ref chips: one branch (a
  local branch and its remote branch merged) and one tag, with "+N" for the rest.
  Compact rows and the graph can be turned off from the search field's menu.
- Co-authors from `Co-authored-by:` trailers show in the rows and the details, and the
  search finds them.
- The header row is gone: the search field counts matches ("3/41").
- Commits on a branch that isn't published yet count as outgoing (Sync's Publish count,
  chips and Home).

### Ignore rules
- Ignore changed files from the Changes list's menu: the file, its name, its extension or
  a folder, with a preview of what the rule hides, in the repository's `.gitignore`,
  `info/exclude` or your global excludes file. A tracked file can stop being tracked.
- Repository > Ignore rules… lists every rule file, what each line hides, unused rules
  and tracked files that match, and adds rules from templates.
- "Show ignored files" in Changes, with the rule behind each file and Stop ignoring.
- A folder that fills Changes (build output) offers to be ignored.

### Deleting branches
- Deleting a branch says what it would lose (commits not in the main branch, commits not
  pushed, its worktree) and deletes it in one step, merged or not.
- It offers to delete the branch on its remote too, ticked unless the branch has commits
  the main branch lacks. Worktree deletes and Clean up merged worktrees offer the same.
- Delete dialogs list what goes as compact rows: an icon, the name and what it would
  lose, warnings in amber and merged branches in green.
- The checked-out branch can be deleted: gitbello switches to the main branch first, or,
  in a linked worktree, deletes the worktree with it and shows the main one.
- Undo on the toast brings the branch back, and pushes its remote branch back.
- Remote branches can be deleted from their menu, Delete deletes the selected branch in
  the branch list, and deleting a tag can delete it on the remote too.

### Diffs
- An image viewer for PNG, JPG, WebP, BMP, TGA and SVG: split, onion skin, swipe and
  difference, with zoom and pan. Image conflicts preview both sides.
- The diff header picks the mode (unified or side by side, or the image modes);
  Ctrl+Shift+D cycles them. The mode is saved per viewer.
- Line endings: a row says when a file's endings changed and when it has no final
  newline; a file that changed only its endings shows a card instead. Restore line
  endings puts them back (with Undo), and Changes marks these files `EOL` and can show
  only them.
- Open opens a file, or the version a diff shows, in its default app. It replaces Open
  in editor and the editor setting.

### Worktrees
- The worktree icon's list has a filter, the chip's menu on right-click and a footer
  with New worktree…, From branch…, Clean up and Prune.
- A worktree deleted outside gitbello closes quietly.

### Changes
- The checkboxes are the only multi-file selection: clicking a row shows its diff.

### Keyboard
- Shortcuts live in Settings > Keyboard (Ctrl+/): filter by name or by pressing keys,
  see what you changed, reassign on a conflict and reset all.

### Speed
- Clicks and selections run before background refreshes, stale jobs are dropped,
  unchanged refreshes are skipped and History loads only new commits. Lists, diffs and
  commit details show when they are loading.

### Fixes and polish
- A new logo, restyled filter fields, a scrolling commit list in the merge dialog.
- The Windows process shows as just "gitbello" in Task Manager.

## 1.0.0

The first release. gitbello is a Git GUI for people who keep many repositories and
worktrees open at once: every repository has a tab, its worktrees sit in a strip of chips
inside it, and live status shows everywhere. It runs on Windows, macOS and Linux, on top
of the git you already have (2.40 or newer).

### Repositories and worktrees
- Home lists every repository you've added, with recent ones first, pinning, grouping by
  folder and a filter, and shows each one's branch, changes and ahead/behind counts.
- Add repositories by cloning, creating, initializing a folder, adding an existing folder
  or scanning a folder for all the repositories inside it.
- One tab per repository. Its worktrees are chips with their branch, changes, conflicts
  and lock state; Ctrl+1…9 switch between them.
- New task makes a branch and its worktree in one step, in `.worktrees/<branch>` by
  default (editable in Settings). Clean up merged worktrees lists those whose branch is
  merged or gone, with their branches.
- Add, remove, lock, unlock and prune worktrees; a worktree whose folder is gone is marked
  instead of failing. On Windows, deleting a worktree that a program is running from
  names the program.

### Changes and commits
- Tick files, hunks or single lines to commit: the commit is built from your selection
  in a temporary index, so whatever was staged elsewhere stays as it was.
- Amend, see the output of a failing hook, and discard files, hunks or lines with Undo.
- Undo the last commit when it isn't pushed yet: its changes and message come back.

### Diffs
- Unified and side-by-side diffs with syntax highlighting and changed words highlighted
  inside lines.
- A minimap of the whole diff beside it, with next and previous change.
- Choose the added and removed colours in Settings.

### History
- A fast commit graph for the current branch or all branches, with commit details and
  the commits not pushed yet marked.
- Search by subject, author or hash, with the matches marked along the scroll bar.
- Cherry-pick a commit from the graph.

### Shelves
- Shelves are stashes tied to a branch: shelve files (untracked ones too), then restore,
  rename or discard them, whole or a file at a time, with Undo.
- Switching branch with local changes asks whether to bring them along or leave them on
  a shelf, and offers them back when you return.

### Sync, branches and tags
- Fetch, pull and push with progress and cancel. Errors come with a fix, like pulling
  when a push is rejected.
- Auto-fetch keeps ahead/behind counts current.
- Create, check out, rename and delete branches and set their upstream; create, delete
  and push tags; manage remotes.

### Merging and conflicts
- Merge shows before it starts whether there will be conflicts, and offers to
  fast-forward, create a merge commit or squash.
- A conflict resolver in the diff pane, unified or side by side, with the base on demand
  and cards for conflicts that aren't text.
- Continue, skip or abort merges, cherry-picks and rebases from the banner.

### Everywhere
- A command palette, menus and rebindable shortcuts for every action.
- Light and dark themes that follow the system, with your accent colour.
- English and Italian.
- Open a repository in your editor or a terminal, see every git command gitbello ran,
  and middle-click to autoscroll any list.
