# Actions, menus, tooltips and options

Every user-facing operation is an action in `ActionRegistry` (golden rule 10). Menus, the menu bar, the palette, shortcuts, buttons' tooltips and Settings → Keyboard all read from it.

## Actions

- `Action`: `id`, `label` (full, for the palette and Settings → Keyboard), `menu_label` (short, for menus, the menu bar and tooltip cards: "Delete…" in a branch's menu, "Copy hash"; `ActionRegistry.MENU_LABELS`), `category`, `context`, `shortcut`, `visible`, `enabled` with its `reason`, `checked` / `radio`, `dynamic_label`, `shortcut_from` (borrow another action's shortcut for display) and `run` (with its origin control). Both labels are translated.
- **Two predicates:** `visible` (does it apply here?) hides an item; `enabled` (can it run now?) greys it, with its reason as the item's tooltip. Pairs such as Lock / Unlock and Pin / Unpin show one entry; conflict and operation items hide outside a conflict or an operation. Reasons are short fragments ("No conflicts", "Select a file", "Select HEAD in History"); actions without one show "Unavailable here" in the palette (`CommandPalette.DISABLED_HINTS` keeps a few shorter forms).
- `Actions.set_visible`, `Actions.set_checked`, `Actions.tooltip(id)`, `Actions.shown_shortcuts`, `shortcut_text`.

## ActionMenu

`ActionMenu` (`app/actions/action_menu.gd`) fills every `PopupMenu`: the menu bar, context menus, the Add and Sync menus and the choice menus (a form's submit ▾, Ignore rules' chip and template menus, the image side's Open, the conflict's Both ▾, the folder hint's close menu). It takes a list of action ids, separators, static submenus and dynamic submenus, and handles icons, shortcuts, check and radio items, disabled state and tooltips once. `ActionMenu.family` builds Copy ▸, Compare ▸ and Open in ▸ (flat when only one item shows); `ActionMenu.scoped` makes a submenu whose actions act on another target (a worktree menu's Branch ▸). Tests press entries by action id (`menu_ids`, `press_menu_id`).

- **One menu per object:** `Menus` (`app/actions/menus.gd`) holds one definition each for a branch, remote branch, tag, worktree, commit, changed file, ignored file, file at a commit, diff, conflict block and Home row, used wherever it is opened (the graph's ref chips, the branch list, the worktree list, History's, Compare's and File history's lists); items that do not apply there are hidden by `visible`.
- **Order:** primary action → create (New branch…, New tag…) → families → destructive last, behind a separator.
- **Titles** only where the target is not obvious: a labelled separator naming it on menus from graph ref chips, multi-selections ("3 files") and the worktree list.
- **Shortcuts** show in every menu.
- **Drawing:** a menu opened with `open_at` redraws every frame for `REDRAW_MS` (300 ms). On Windows the right-click that brings the app to the front can show the menu's window after its only frame was drawn (low processor mode), which left it blank.
- **Icons:** nearly every item has one where it is specific; no repeats inside a family, no forced matches (left without: the conflict side choices, Short hash, Subject, Pull with ▸). Checkable items show the check mark and the icon. The menu bar's submenus take theirs from `AppMenuBar.SUB_ICONS`.

## Menu bar

```
File       Home, Open…, Open recent ▸, Clone…, Scan…, New ▸ | Close tab | Settings… | Quit
Edit       Copy, Select all | Undo | Find, Next / Previous match
View       Changes, History, Shelves, Compare, File history | Diff ▸ | History ▸ | Palette, Git log
Repository Fetch, Pull with ▸, Push ▸ | Remotes…, Tags…, Ignore rules… | Shelve…, Restore left | Terminal, File manager | Continue / Resolve / Abort | Refresh
Branch     Switch…, New… | Merge / Rebase…, Compare… | Rename…, Upstream…
Commit     Commit, Amend…, Undo last | Cherry-pick…, Check out… | New tag… | Copy hash
Worktree   New…, Setup… | Terminal, File manager, Copy path | Lock / Unlock | Clean up…, Prune, Delete…
Help       Shortcuts…, What's new, Report an issue, Open config folder | About
```

- Branch has no Delete…: the bar's target is the current branch, which cannot be deleted. The Worktree items act on the selected worktree when no chip was right-clicked (`RepoTab.current_worktree_ref`). View → History ▸ has Current / All branches as radio items. Help → What's new and Report an issue open the project's GitHub pages; Open config folder uses `Core.config_folder()`.
- Definitions: `godot/app/main/app_menu_bar.gd` (`&""` is a separator).

## Undo

- **Edit → Undo** (`edit.undo`, Ctrl+Z) runs the newest file-level undo in the active view: a discard (including Restore line endings and restores from Compare or File history), an ignore rule, a shelf discard or a conflict choice. Core tracks which is newest (`undo_order.rs`, `RepoState::newest_undo`); each stack stays the source of truth, and entries a stack drops on its own are skipped. The item is labelled with what it takes back ("Undo discard"). The four undos have no Ctrl+Z of their own and show it while they are the newest.
- **Undo last commit** stays its own item (the undo strip) and never runs on Ctrl+Z.
- Known gap: a toast's Undo stays after Edit → Undo took the same change back.

## Copy and Open on <host>

- **Copy ▸** Hash, Short hash, Subject, Message on a commit; Copy name on a branch, remote branch or tag; Copy path on a file (repository-relative for a file of a commit).
- **Open on <host>** for a commit, a branch with a live upstream, a remote branch, a tag, and a file in History or File history, on GitHub, GitLab, Bitbucket, Azure DevOps, Codeberg and Gitea, recognised by host name only (`web_links.rs`, unit-tested; `runtime/web_pages.rs`; `RepoSession.ref_web_page`, `commit_web_page`). Hidden for unknown hosts, local remotes and branches never pushed. Known gap: a commit or tag that was never pushed still gets the entry.

## Tooltip cards

- Buttons and list rows use one `TooltipCard` (`ui/tooltip_card/`): the short label, the shortcut as key caps on the right, and optional muted fact lines (the target, "2 commits to origin/main", or why it is disabled); rows add icon + text lines (the worktree chip's card has the same layout).
- `TooltipCard.install` (from `Main._ready`) turns every Godot tooltip whose text has a tab (`Label\tCtrl+B`) or a second line into a card, drawn inside Godot's own tooltip label. `ActionRegistry.tooltip` returns the short label, the canonical shortcut and why it is disabled, so every action-backed button gets the card; other controls build card text with `TooltipCard.text_for`.
- Wording: fragments, no sentences or trailing periods, nothing that restates the label. Dialog text, form errors, notes and toasts keep their sentences. Menu items keep Godot's plain-text tooltip (the reason only).
- Headless Godot shows no tooltips, so `tooltip_card_smoke` checks the hook on a hand-built popup; `tooltip_screenshots.tscn` hovers real controls.

## Options popovers

The filter fields' options are one themed popover per field, opened by a sliders button.

```
[🔍 src/…                ✕ │ ⚟2]      ⚟ = sliders icon, 2 = CountBadge
          ┌───────────────────────────────────────┐
          │ Filter                         Clear  │
          │ Show    (+ New) (~ Modified) (− Deleted)│
          │ Commit  (✓ Included) (✗ Excluded)     │
          │ Also    (↵ Line endings only) (⊘ Ignored)│
          ├───────────────────────────────────────┤
          │ View                                  │
          │ Rows    [≡ Compact | ☰ Detailed]      │
          │ Graph   (⌇ Show graph)                │
          └───────────────────────────────────────┘
```

- **Sections:** Filter (what is listed) and View (how it looks), split by a full-width divider; each with an optional accent icon and a bold title. One label column across sections. At most 400 px wide.
- **Either/or choices** are segmented controls (`SegmentedControl`) with an icon and a short label, the chosen side filled with the accent: Rows `Compact | Detailed`, Branches `Current | All`.
- **On/off options** are toggle chips (`ToggleChip`) that fill with the accent when on, wrapping in a flow row: Changes' Included / Excluded, New / Modified / Deleted, Line endings only, Show ignored files; History's Show graph.
- **Dynamic lists** are check rows (`add_checks`, with a `count` badge and `{separator}`): the shelves' branch filter.
- **Active state:** with the popover closed, the button reads pressed with a `CountBadge` of the options that differ from their default. History's branch scope does not count (it is in the button's tooltip), so History never shows a badge.
- **Clear:** an accent-tinted pill with a cross at the right of the Filter header, shown while a counted filter is on (`changes.clear_filter_options`); it resets counted filters only, not the text, view settings or the branch scope.
- **Behaviour:** clicks change options live and keep the popover open; Tab / Shift+Tab move between controls, Left / Right within a segmented control, Space / Enter toggle, Escape closes and returns focus to the field. Alt+Down in the field opens it (`view.options`). Shortcuts show in each control's tooltip.
- **Where:** Changes (Filter: three chip rows with Clear), History (Filter: Branches; View: Rows and Show graph), File history (View: Rows), Blame (its own sliders button: Ignore whitespace and Detect moved lines, with a badge), the shelves' branch filter (its GitBranch button and badge).
- **Checks app-wide:** check, radio, partial and switch icons are generated from the palette in `AppTheme._add_checks` (cached by SVG) on the `CheckBox`, `CheckButton` and `PopupMenu` theme types, so Settings, dialogs, menus and the shelf list match.
- Code: `godot/ui/options_popover/` (`OptionsPopover` with `add_section(title, clear_action)`, `add_segmented`, `add_chips`, `add_checks`, the `changed(id, value)` signal and `count()`), `FilterField.add_options()` (returns the popover behind the button, signal `option_changed`). Theme types `OptionsPopover`, `OptionsSection`, `Segmented`, `SegmentedButton`, `ToggleChip`. The diff header's options (Minimap, the mode picker) are not in a popover.

## Settings → Keyboard

- A **Keyboard** category in Settings, opened by Help → Shortcuts…, the palette and Ctrl+/ (`ShortcutsPage`, `ShortcutChip`, `KeyCap` theme types).
- **Page:** a toolbar with a filter (label, category, context, shortcut text), a keyboard button in the field to search by pressing a shortcut, a **Changed** toggle with the count, and **Reset All…** (confirmed). Below it one folding section per category with its count; each row has the action's icon, its label, a context tag (none for global actions), an accent dot when changed and the shortcuts as key caps in chips. Hidden actions with a default key (Ctrl+1 … Ctrl+9, `F`, "Show view N") are listed so they can be rebound; actions without a shortcut show an "Add shortcut" chip on hover. Hovering a row shows its clear (×) and revert buttons. Settings' own search adds "Matching shortcuts: N", which opens the page with the search carried over.
- **Recording:** a click on a chip, or Enter on it, records: the chip pulses "Press keys…", modifiers alone wait for the key, Escape cancels (the window does not close on Escape meanwhile). A key that another action uses in an overlapping context opens a strip under the row ("Ctrl+K is already used by App → Command palette") with **Reassign** (focused; takes the key from the other action, which keeps any other shortcut) and **Cancel**. Choosing the defaults clears the override; Meta must match (not on macOS).
- **Contexts:** `Action.context` comes from the id prefix (`ActionRegistry.CONTEXT_PREFIXES`): Global, Changes, History, Shelves, Diff and Resolver. Two contexts overlap when they are the same, one is Global, or the diff sits inside the other (Changes, History, Shelves); the resolver replaces the diff, so a key can be shared by a diff action and a resolver action.
- Overrides stay one shortcut per action; saved shortcuts of renamed actions move over (`RENAMED_ACTIONS`). Multiple bindings, chords and import/export are not offered.
- Registry calls: `conflicts`, `release_shortcut`, `reset_all_shortcuts`, `with_shortcuts`.
