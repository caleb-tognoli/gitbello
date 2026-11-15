# Compare

Compare two states of a repository: branches, remote branches, tags, commits or the working copy.

```
[ ⎇ main v ] ⇄ [ ⎇ feature v ]                                    (🕘)
+------------------------+------------------------------------------+
| All changes            | selected commit's details (as History)   |
| Only on feature (5)    +--------------+---------------------------+
|  Improve login         | files        | diff                      |
|  Add token refresh     |              |                           |
| Only on main (2)  [Include]           |                           |
|  Bump deps             |              |                           |
+------------------------+--------------+---------------------------+
```

## Sides

- Left is the base, right is what is compared; the diff reads left → right. Either side is any revision git resolves (branch, remote branch, tag, hash, `HEAD~3`); the right side can also be **Working copy** (tracked changes and untracked files, as in Changes). ⇄ swaps them.
- Each side is a chip button with the ref's icon that opens a filterable picker (`compare_picker.gd`): Working copy (right side only), local branches, remote branches, tags, recent commits (listed by subject), and "Enter any revision…" (Enter resolves it; an invalid one shows inline under the field). A side that is a plain commit shows its subject (the hash in the tooltip); lists, chips, menus and toasts name commits by subject.
- **Since the fork** is what All changes shows: `merge-base(left, right)` diffed against the right side (what the right side added since it split off, like a pull request). The "Only on <left> (N)" header has an **Include** pill at its right (outlined off, filled on; `compare.full_difference`, "Include the left side's commits"): off, the left side's commits are dimmed; on, All changes is the full difference from the left side's tip (so those commits show undone, as its tooltip says). Clicking it from a commit selects All changes. Unrelated histories keep it on, locked.

## View

- A *Compare* view joins the switch only while a comparison is open, with a close × on its tab. One comparison per worktree: opening another replaces it. Not restored on restart. Compare keeps its own diff slot, so the History and Changes selections are untouched.
- **Bar:** the two side chips with ⇄ between them, a line under the bar, and a Recent button at the far right (`compare.recent`) that opens a popover of the repository's last 5 comparisons (kept per repository in its UI state, with the Include setting and the subjects of commit sides; the one open is skipped).
- **Left:** the commit list (`CompareCommitList`, a `CommitList` with History's two-line rows without the graph): All changes ("N changed files"), then "Only on <right> (N)" and "Only on <left> (N)" as one-line section headers with a fold arrow (a click folds the section, moving the cursor to All changes when its commit is folded away; the cursor skips section names). The list stops at 2000 commits with a "More commits are not listed" row.
- **Right:** the selected commit's details (`CommitHeader`, without a merge's parent links, which navigate History; Copy through `compare.copy_hash`) over its files beside the diff. All changes shows every file of the comparison, without a details block. Narrowing to a commit compares it with its first parent (a root commit with the empty tree). The details' height and the files' width follow History's.
- **Files:** like Changes without checkboxes: status letters, renames as old → new, the filter field (a filter in double quotes names one exact path, or one renamed from it: `compare::filter_files`). The diff is read-only and keeps the diff modes, the minimap and the image viewer. File rows have no `+N −M`; the list header keeps the totals. Large ranges stay in Rust: the list is fetched in slices.
- **Refresh:** a working-copy side refreshes with the file watcher like Changes; ref sides refresh when refs move (commit, fetch, checkout). The selected file and commit are kept when they still exist.

## Entry points

All actions, so also in the palette:
- Ref menus (branch list, ref chips, the "+N" popover): Compare ▸ **with current branch** and **with…** (the ref on the right, the other side's picker open).
- History: Ctrl+click a second commit selects two rows (the older one becomes the left side) → **Compare commits** in the commit menu and the details pane. A single commit's menu: Compare ▸ **with working copy** and **with…**.
- **Branch → Compare…** (Ctrl+Shift+C): the current branch on the left, the right picker open. A comparison opened only to pick its other side is replaced by the pick.
- File history's **Compare versions** opens Compare filtered to the file's exact path.

## Actions

- File menu: **Restore from <left>** / **Restore from <right>** writes that side's version into the working copy (a file missing on that side is deleted); the left side means its own revision (not the merge base) and, while narrowed, the commit's parent or the commit. Backed up first; the toast offers Undo, as for discard. Disabled for a side that is the working copy.
- Commits: select commits not reachable from HEAD → **Cherry-pick onto <current branch>**, oldest first, through the cherry-pick flow and its conflict banner. A multi-commit cherry-pick refuses merge commits (one merge alone keeps the mainline-1 flow), and finishing a conflicted step through gitbello's commit continues the rest of the sequence.

## Core

- `compare.rs` (sides, resolve, merge base, counts, the file list with stats and renames, `filter_files`), `backend/compare.rs` (`git merge-base`, `rev-list --left-right --count`, a left-right log for the two commit sections, `diff -z -M --raw --numstat <base> <right>`; against the working copy `diff <base>` plus untracked files from status), `runtime/compare.rs` (the comparison a worktree shows, its selected commit and diff slot). File diffs between any two sides are `DiffTarget` kinds (tree vs tree, working copy vs a commit). All reads, run as jobs.
- `gitbello-cli compare <repo> <left> <right|--working> [--fork|--exact] [--file <path>]` for headless checks.
