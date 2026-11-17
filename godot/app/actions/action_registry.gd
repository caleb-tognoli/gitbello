class_name ActionRegistry
extends Node
## Every user-facing operation (AGENTS rule 10, ARCHITECTURE §3.7). Menus, context
## menus, the command palette and shortcuts all read from here. Autoloaded as
## `Actions`.
##
## Shortcuts: each action has default shortcuts; a user override from the
## config (`Core.keybindings()`) replaces them.
##
## A run may say which control started it (`run_action(id, origin)`): the job
## it starts then shows its progress there (see `Feedback`).

signal actions_changed()
## An action ran (for tests and status messages).
signal action_ran(id: StringName)


## Shared visual vocabulary for menus and the palette. Unmapped actions keep
## their text without an unrelated fallback icon.
const ICONS: Dictionary[StringName, StringName] = {
	&"app.command_palette": &"Search",
	&"app.keyboard_shortcuts": &"Keyboard",
	&"app.settings": &"Tools",
	&"app.about": &"Info",
	&"app.open_config_folder": &"Folder",
	&"home.open": &"Home",
	&"home.row_open": &"Folder",
	&"home.row_pin": &"Pin",
	&"home.row_unpin": &"Pin",
	&"home.row_rename": &"Rename",
	&"home.row_relocate": &"Load",
	&"home.row_show": &"Folder",
	&"home.row_terminal": &"Terminal",
	&"home.row_copy_path": &"ActionCopy",
	&"home.row_remove": &"Remove",
	&"repo.clone": &"GitFetch",
	&"repo.add_existing": &"FolderAdd",
	&"repo.scan": &"Search",
	&"repo.create": &"Add",
	&"repo.refresh": &"Reload",
	&"tab.close": &"Close",
	&"repo.open_terminal": &"Terminal",
	&"repo.show_in_file_manager": &"Folder",
	&"repo.remotes": &"GitRemote",
	&"repo.tags": &"GitTag",
	&"repo.ignore_rules": &"GitIgnore",
	&"view.changes": &"FileList",
	&"view.history": &"History",
	&"view.find": &"Search",
	&"view.toggle_git_log": &"Terminal",
	&"history.next_match": &"ChevronDown",
	&"history.previous_match": &"ChevronUp",
	&"history.current_branch": &"GitBranch",
	&"history.all_branches": &"GitBranches",
	&"history.compact_rows": &"RowsOneLine",
	&"history.detailed_rows": &"RowsTwoLine",
	&"history.toggle_graph": &"GitGraph",
	&"view.options": &"Sliders",
	&"history.go_to_current_commit": &"GitCommit",
	&"diff.copy": &"ActionCopy",
	&"diff.retry": &"Reload",
	&"diff.cycle_mode": &"Panels2Alt",
	&"diff.toggle_whole_file": &"ExpandAll",
	&"image.zoom_in": &"ZoomIn",
	&"image.zoom_out": &"ZoomOut",
	&"image.zoom_fit": &"ZoomFit",
	&"diff.open_file": &"ExternalLink",
	&"changes.show_file": &"Folder",
	&"changes.copy_path": &"ActionCopy",
	&"changes.clear_filters": &"Clear",
	&"changes.clear_filter_options": &"Clear",
	&"changes.focus_message": &"GitCommit",
	&"changes.commit": &"GitCommit",
	&"changes.discard": &"Remove",
	&"edit.undo": &"Undo",
	&"changes.undo_discard": &"Undo",
	&"changes.restore_line_endings": &"LineEndings",
	&"changes.ignore": &"GitIgnore",
	&"changes.ignore_file": &"GitIgnore",
	&"changes.ignore_extension": &"GitIgnore",
	&"changes.ignore_folder": &"GitIgnore",
	&"changes.undo_ignore": &"Undo",
	&"changes.stop_ignoring": &"GitIgnore",
	&"changes.ignore_hint": &"GitIgnore",
	&"changes.shelve": &"GitShelf",
	&"changes.shelve_listed": &"GitShelf",
	&"changes.discard_listed": &"Remove",
	&"changes.shelve_checked": &"GitShelf",
	&"changes.discard_checked": &"Remove",
	&"view.shelves": &"GitShelf",
	&"view.compare": &"GitCompare",
	&"branch.compare": &"GitCompare",
	&"compare.with_current": &"GitBranch",
	&"compare.with": &"GitCompare",
	&"commit.compare_working": &"FileModified",
	&"commit.compare_with": &"GitCompare",
	&"history.compare_selected": &"GitCompare",
	&"compare.close": &"Close",
	&"compare.swap": &"Swap",
	&"compare.recent": &"History",
	&"compare.restore_left": &"Restore",
	&"compare.restore_right": &"Restore",
	&"compare.cherry_pick": &"GitCherryPick",
	&"compare.copy_hash": &"Hash",
	&"compare.all_changes": &"FileList",
	&"view.file_history": &"FileHistory",
	&"file_history.open": &"FileHistory",
	&"file_history.close": &"Close",
	&"file_history.compare_versions": &"GitCompare",
	&"file_history.restore": &"Restore",
	&"file_history.open_version": &"ExternalLink",
	&"file_history.show_in_history": &"History",
	&"file_history.copy_hash": &"Hash",
	&"file_history.blame": &"Blame",
	&"blame.before": &"History",
	&"blame.show_changes": &"FileHistory",
	&"shelf.restore": &"Restore",
	&"shelf.restore_file": &"Restore",
	&"shelf.discard_file": &"Remove",
	&"shelf.restore_left": &"Restore",
	&"shelf.rename": &"Rename",
	&"shelf.discard": &"Remove",
	&"shelf.undo_discard": &"Undo",
	&"sync.sync": &"Reload",
	&"sync.fetch": &"GitFetch",
	&"sync.pull": &"GitPull",
	&"sync.pull_merge": &"GitMerge",
	&"sync.pull_rebase": &"GitRebase",
	&"sync.pull_ff_only": &"GitFastForward",
	&"sync.push": &"GitPush",
	&"sync.force_push": &"StatusWarning",
	&"sync.cancel": &"Close",
	&"branch.switch": &"GitBranch",
	&"branch.checkout": &"GitBranch",
	&"branch.new": &"GitBranchAdd",
	&"branch.rename": &"Rename",
	&"branch.delete": &"Remove",
	&"branch.delete_remote": &"Remove",
	&"branch.set_upstream": &"GitRemote",
	&"tag.new": &"GitTag",
	&"tag.push": &"GitPush",
	&"tag.delete": &"Remove",
	&"changes.cancel_amend": &"Close",
	&"commit.amend": &"GitAmend",
	&"commit.reword": &"Rename",
	&"commit.squash": &"GitSquash",
	&"commit.move_up": &"ChevronUp",
	&"commit.move_down": &"ChevronDown",
	&"commit.drop": &"Remove",
	&"commit.checkout": &"GitCheckout",
	&"commit.copy_hash": &"Hash",
	&"commit.copy_short_hash": &"Hash",
	&"commit.copy_subject": &"TextFile",
	&"commit.merge": &"GitMerge",
	&"commit.undo": &"Undo",
	&"branch.merge": &"GitMerge",
	&"operation.continue": &"StatusSuccess",
	&"operation.abort": &"Close",
	&"operation.open_resolver": &"GitConflict",
	&"conflict.undo": &"Undo",
	&"conflict.next": &"ChevronDown",
	&"conflict.previous": &"ChevronUp",
	&"conflict.reopen": &"GitConflict",
	&"task.new": &"GitWorktree",
	&"branch.new_worktree": &"GitWorktree",
	&"commit.new_worktree": &"GitWorktree",
	&"worktree.setup": &"Tools",
	&"worktree.open": &"GitWorktree",
	&"worktree.cleanup": &"Clear",
	&"worktree.prune": &"Scissors",
	&"worktree.remove": &"Remove",
	&"worktree.open_terminal": &"Terminal",
	&"worktree.show_in_file_manager": &"Folder",
	&"worktree.copy_path": &"ActionCopy",
	&"worktree.lock": &"Lock",
	&"app.quit": &"Power",
	&"app.report_issue": &"Bug",
	&"app.whats_new": &"Sparkle",
	&"branch.copy_name": &"ActionCopy",
	&"diff.copy_path": &"ActionCopy",
	&"commit.cherry_pick": &"GitCherryPick",
	&"commit.copy_message": &"TextFile",
	&"commit.open_web": &"Globe",
	&"branch.open_web": &"Globe",
	&"diff.open_web": &"Globe",
	&"diff.select_all": &"SelectAll",
	&"diff.toggle_minimap": &"Minimap",
	&"diff.next_change": &"ChevronDown",
	&"diff.previous_change": &"ChevronUp",
	&"history.toggle_compact": &"RowsOneLine",
	&"operation.skip": &"Skip",
	&"repo.init": &"Add",
	&"worktree.unlock": &"Unlock",
	&"changes.include_all": &"CommitIncluded",
	&"changes.exclude_all": &"CommitExcluded",
	&"shelf.filter_branches": &"Filter",
}

## Short labels for menus and tooltip cards (`Action.menu_label`), where the
## menu or the object already says what the action works on. The palette and
## Settings → Keyboard keep the full label. English keys, translated. Inside
## a family (Compare ▸, Open ▸) the menu gives its own labels instead.
const MENU_LABELS: Dictionary[StringName, String] = {
	&"app.keyboard_shortcuts": "Shortcuts…",
	&"app.about": "About",
	&"repo.clone": "Clone…",
	&"repo.add_existing": "Open…",
	&"repo.scan": "Scan folder…",
	&"repo.create": "New repository…",
	&"view.toggle_git_log": "Git log",
	&"view.find": "Find",
	&"diff.cycle_mode": "Next mode",
	&"diff.toggle_whole_file": "Whole file",
	&"diff.toggle_minimap": "Minimap",
	&"history.toggle_graph": "Graph",
	&"history.next_match": "Next match",
	&"history.previous_match": "Previous match",
	&"history.current_branch": "Current branch",
	&"history.all_branches": "All branches",
	&"history.go_to_current_commit": "Current commit",
	&"history.go_to_parent": "Parent commit",
	&"changes.undo_discard": "Undo discard",
	&"changes.undo_ignore": "Undo ignore rule",
	&"changes.ignore_hint": "Ignore folder",
	&"changes.clear_filters": "Clear filters",
	&"shelf.restore": "Restore",
	&"shelf.rename": "Rename",
	&"shelf.discard": "Discard…",
	&"shelf.restore_file": "Restore",
	&"shelf.discard_file": "Discard",
	&"shelf.undo_discard": "Undo shelf discard",
	&"shelf.restore_left": "Restore left changes",
	&"sync.cancel": "Cancel",
	&"operation.abort": "Abort…",
	&"operation.continue": "Continue",
	&"operation.skip": "Skip commit",
	&"operation.open_resolver": "Resolve conflicts",
	&"conflict.undo": "Undo choice",
	&"conflict.use_ours": "Use ours",
	&"conflict.use_theirs": "Use theirs",
	&"conflict.use_both": "Use both, ours first",
	&"conflict.use_both_reversed": "Use both, theirs first",
	&"conflict.file_ours": "Use ours for file",
	&"conflict.file_theirs": "Use theirs for file",
	&"branch.switch": "Switch…",
	&"branch.rename": "Rename…",
	&"branch.delete": "Delete…",
	&"branch.delete_remote": "Delete…",
	&"tag.push": "Push",
	&"tag.delete": "Delete…",
	&"commit.checkout": "Check out…",
	&"commit.cherry_pick": "Cherry-pick…",
	&"commit.copy_hash": "Copy hash",
	&"commit.copy_short_hash": "Copy short hash",
	&"commit.copy_subject": "Copy subject",
	&"commit.copy_message": "Copy message",
	&"branch.copy_name": "Copy name",
	&"diff.copy_path": "Copy path",
	&"commit.merge": "Merge / Rebase…",
	&"commit.undo": "Undo last",
	&"commit.reword": "Reword…",
	&"commit.squash": "Squash down…",
	&"commit.move_up": "Move up",
	&"commit.move_down": "Move down",
	&"commit.drop": "Drop…",
	&"task.new": "New…",
	&"worktree.setup": "Setup…",
	&"commit.new_worktree": "New worktree…",
	&"worktree.cleanup": "Clean up…",
	&"worktree.prune": "Prune",
	&"file_history.open_version": "Open",
	&"file_history.show_in_history": "Show in History",
	&"file_history.copy_hash": "Copy hash",
	&"compare.copy_hash": "Copy hash",
	&"compare.cherry_pick": "Cherry-pick…",
	&"compare.restore_left": "Restore from left",
	&"compare.restore_right": "Restore from right",
	&"blame.before": "Blame before",
}

## Where an action's shortcut works: `GLOBAL` anywhere, the others in one part
## of the window. Two actions may share a key when their contexts never show
## at once (Ctrl+Z undoes a discard in Changes and a choice in the resolver).
const GLOBAL: StringName = &"Global"
## Contexts by id prefix; ids not listed are `GLOBAL`.
const CONTEXT_PREFIXES: Dictionary[String, StringName] = {
	"diff.": &"Diff",
	"image.": &"Diff",
	"changes.": &"Changes",
	"history.": &"History",
	"commit.": &"History",
	"shelf.": &"Shelves",
	"conflict.": &"Resolver",
	"compare.": &"Compare",
	"file_history.": &"File history",
	"blame.": &"File history",
}
## Ids whose context differs from their prefix's.
const CONTEXT_IDS: Dictionary[StringName, StringName] = {
	&"commit.undo": &"Changes",
	&"compare.with_current": GLOBAL,
	&"compare.with": GLOBAL,
	&"compare.close": GLOBAL,
	&"file_history.open": GLOBAL,
	&"file_history.close": GLOBAL,
	&"file_history.blame": GLOBAL,
}
## Contexts shown inside others: the diff sits in Changes, History and
## Shelves. The resolver replaces the diff, so it overlaps only `GLOBAL`.
const CONTEXTS_INSIDE: Dictionary[StringName, Array] = {
	&"Diff": [&"Changes", &"History", &"Shelves", &"Compare", &"File history"],
}


class Action:
	extends RefCounted
	var id: StringName
	var _label: String
	var label: String:
		get: return tr(_label)
		set(value): _label = value
	var _category: String
	var category: String:
		get: return tr(_category)
		set(value): _category = value
	var run: Callable
	## Where its shortcut works (`ActionRegistry.GLOBAL` or a context name).
	var context: StringName = &"Global"
	## Returns bool; an invalid Callable means always enabled.
	var enabled: Callable
	var default_shortcuts: PackedStringArray
	## Hidden actions run from shortcuts but are not listed in the palette.
	var hidden: bool = false
	## Whether the shortcut also works while a text field has focus (text
	## fields otherwise keep keys like Ctrl+Enter for themselves).
	var in_text_fields: bool = false
	## Returns why the action is disabled (shown in tooltips), or "".
	var reason: Callable = Callable()
	## Returns the id of the action whose shortcut also runs this one right
	## now (&"" for none): menus and tooltips show that shortcut while this
	## action has none of its own. Alt+3 shows the third view of the switch,
	## whichever it is.
	var shortcut_from: Callable = Callable()
	## Returns whether the action applies here at all; menus hide it when not
	## (greyed is for `enabled`: it applies, but cannot run now). An invalid
	## Callable means it always applies.
	var visible: Callable = Callable()
	var _menu_label: String = ""
	## The short label menus and tooltip cards show, where the menu or button
	## already names the object ("Delete…" in a branch's menu); `label` when
	## unset. The palette and Settings → Keyboard keep `label`.
	var menu_label: String:
		get:
			if dynamic_label.is_valid():
				var now: String = String(dynamic_label.call())
				if not now.is_empty():
					return tr(now)
			return tr(_menu_label) if not _menu_label.is_empty() else label
		set(value): _menu_label = value
	## Returns the menu label right now ("Undo discard" for Edit → Undo), or ""
	## for `menu_label`'s usual one. An invalid Callable means it never changes.
	var dynamic_label: Callable = Callable()
	## Returns whether the action is on: menus show it as a check (or a radio
	## item with `radio`). An invalid Callable means it is not checkable.
	var checked: Callable = Callable()
	var radio: bool = false

	func is_enabled() -> bool:
		return not enabled.is_valid() or bool(enabled.call())

	func is_visible() -> bool:
		return not visible.is_valid() or bool(visible.call())

	func is_checkable() -> bool:
		return checked.is_valid()

	func is_checked() -> bool:
		return checked.is_valid() and bool(checked.call())

	## Why the action cannot run now, or "" when it can (or nobody said).
	func disabled_reason() -> String:
		if is_enabled():
			return ""
		return tr(String(reason.call())) if reason.is_valid() else ""


var _actions: Dictionary[StringName, Action] = {}
## The control that started the action running now (null between runs, or
## when it came from a shortcut or the palette).
var _origin: Control = null
var _overrides: Dictionary[StringName, String] = {}
var _parsed: Dictionary[StringName, Array] = {}


func _ready() -> void:
	var bindings: Dictionary = Core.keybindings()
	for id: Variant in bindings:
		_overrides[StringName(str(id))] = str(bindings[id])


## Registers (or replaces) an action. `shortcuts` are defaults like "Ctrl+K".
## `reason` returns why it is disabled (see `Action.reason`).
func register(id: StringName, label: String, category: String, run: Callable,
		default_shortcuts: PackedStringArray = PackedStringArray(),
		enabled: Callable = Callable(), reason: Callable = Callable()) -> Action:
	var action: Action = Action.new()
	action.reason = reason
	action.id = id
	action.label = label
	action.category = category
	action.context = context_for(id)
	action.run = run
	action.enabled = enabled
	action.default_shortcuts = default_shortcuts
	action.menu_label = MENU_LABELS.get(id, "")
	_actions[id] = action
	_parsed.erase(id)
	actions_changed.emit()
	return action


func unregister(id: StringName) -> void:
	if _actions.erase(id):
		_parsed.erase(id)
		actions_changed.emit()


## The same themed icon wherever an action appears.
func icon(id: StringName) -> Texture2D:
	var icon_name: StringName = ICONS.get(id, &"")
	return AppTheme.icon(icon_name) if icon_name != &"" else null


func get_action(id: StringName) -> Action:
	return _actions.get(id)


## Visible actions sorted by category, then label.
func listed() -> Array[Action]:
	var out: Array[Action] = []
	for action: Action in _actions.values():
		if not action.hidden:
			out.append(action)
	out.sort_custom(func(a: Action, b: Action) -> bool:
		return [a.category, a.label] < [b.category, b.label])
	return out


## What the shortcut editor lists: the visible actions plus hidden ones that
## have a default shortcut (Ctrl+1 … Ctrl+9), sorted like `listed()`.
func with_shortcuts() -> Array[Action]:
	var out: Array[Action] = []
	for action: Action in _actions.values():
		if not action.hidden or not action.default_shortcuts.is_empty():
			out.append(action)
	out.sort_custom(func(a: Action, b: Action) -> bool:
		return [a.category, a.label] < [b.category, b.label])
	return out


## The context of action `id` (see `CONTEXT_PREFIXES`).
static func context_for(id: StringName) -> StringName:
	if CONTEXT_IDS.has(id):
		return CONTEXT_IDS[id]
	for prefix: String in CONTEXT_PREFIXES:
		if String(id).begins_with(prefix):
			return CONTEXT_PREFIXES[prefix]
	return GLOBAL


## Whether shortcuts in contexts `a` and `b` can be pressed at the same time.
static func contexts_overlap(a: StringName, b: StringName) -> bool:
	return a == b or a == GLOBAL or b == GLOBAL \
			or b in CONTEXTS_INSIDE.get(a, []) or a in CONTEXTS_INSIDE.get(b, [])


func is_enabled(id: StringName) -> bool:
	var action: Action = _actions.get(id)
	return action != null and action.is_enabled()


## Whether `id` exists and applies here (see `Action.visible`).
func is_visible(id: StringName) -> bool:
	var action: Action = _actions.get(id)
	return action != null and action.is_visible()


## Sets when `id` applies (`Action.visible`); unknown ids are ignored.
func set_visible(id: StringName, visible: Callable) -> void:
	var action: Action = _actions.get(id)
	if action != null:
		action.visible = visible


## Makes `id` a check (or radio) item in menus (`Action.checked`).
func set_checked(id: StringName, checked: Callable, radio: bool = false) -> void:
	var action: Action = _actions.get(id)
	if action != null:
		action.checked = checked
		action.radio = radio


## Runs `id` if it exists and is enabled. Returns whether it ran. `origin` is
## the control that started it, if any (see `origin()`).
func run_action(id: StringName, source: Control = null) -> bool:
	var action: Action = _actions.get(id)
	if action == null or not action.is_enabled():
		return false
	var outer: Control = _origin
	_origin = source
	action.run.call()
	_origin = outer
	action_ran.emit(id)
	return true


## The control that started the action running now, or null.
func origin() -> Control:
	return _origin if is_instance_valid(_origin) else null


## Why `id` cannot run now, or "".
func disabled_reason(id: StringName) -> String:
	var action: Action = _actions.get(id)
	return action.disabled_reason() if action != null else ""


## Tooltip text for `id`'s button (a `TooltipCard`): its short label, its
## shortcut as key caps and, when disabled, why (left out with `with_reason`
## false, for a tooltip set once that would keep a stale reason).
func tooltip(id: StringName, with_reason: bool = true) -> String:
	var action: Action = _actions.get(id)
	if action == null:
		return ""
	var why: String = action.disabled_reason() if with_reason else ""
	return TooltipCard.text_for(action.menu_label, shortcut_text(id), PackedStringArray([why]))


## Effective shortcuts: the user's override, else the defaults.
func shortcuts(id: StringName) -> PackedStringArray:
	if _overrides.has(id):
		var override: String = _overrides[id]
		return PackedStringArray() if override == "none" else PackedStringArray([override])
	var action: Action = _actions.get(id)
	return action.default_shortcuts if action != null else PackedStringArray()


## The shortcuts that run `id` right now, for display: its own or, without
## any, those of the action it borrows them from (`Action.shortcut_from`).
func shown_shortcuts(id: StringName) -> PackedStringArray:
	var list: PackedStringArray = shortcuts(id)
	var action: Action = _actions.get(id)
	if not list.is_empty() or action == null or not action.shortcut_from.is_valid():
		return list
	var from: StringName = action.shortcut_from.call()
	return shortcuts(from) if from != &"" else list


## First shortcut that runs `id` (canonical, for `TooltipCard`), or "".
func shortcut_text(id: StringName) -> String:
	var list: PackedStringArray = shown_shortcuts(id)
	return list[0] if not list.is_empty() else ""


## First shortcut that runs `id` for display, or "".
func shortcut_label(id: StringName) -> String:
	var list: PackedStringArray = shown_shortcuts(id)
	return Shortcuts.display(list[0]) if not list.is_empty() else ""


## Sets the user's shortcut for `id` and saves it. "" restores the default;
## "none" removes every shortcut.
func set_shortcut(id: StringName, text: String) -> void:
	# Choosing what the defaults already are is no override.
	var action: Action = _actions.get(id)
	if action != null and (action.default_shortcuts == PackedStringArray([text])
			or (text == "none" and action.default_shortcuts.is_empty())):
		text = ""
	if text.is_empty():
		_overrides.erase(id)
	else:
		_overrides[id] = text
	_parsed.erase(id)
	Core.set_keybinding(String(id), text)
	actions_changed.emit()


## Whether the user changed the shortcuts of `id`.
func is_modified(id: StringName) -> bool:
	return _overrides.has(id)


## How many actions have a user shortcut.
func modified_count() -> int:
	var count: int = 0
	for id: StringName in _overrides:
		if _actions.has(id):
			count += 1
	return count


## Restores every action's default shortcuts.
func reset_all_shortcuts() -> void:
	for id: StringName in _overrides.keys():
		Core.set_keybinding(String(id), "")
	_overrides.clear()
	_parsed.clear()
	actions_changed.emit()


## The other actions that `text` would clash with if `id` used it: those
## with the same key in a context that can show at the same time.
func conflicts(id: StringName, text: String) -> Array[StringName]:
	var out: Array[StringName] = []
	var event: InputEventKey = Shortcuts.parse(text)
	var action: Action = _actions.get(id)
	if event == null or action == null:
		return out
	for other: StringName in _actions:
		if other == id or not contexts_overlap(action.context, _actions[other].context):
			continue
		for shortcut: InputEventKey in _shortcut_events(other):
			if Shortcuts.matches(event, shortcut):
				out.append(other)
				break
	return out


## Takes `text` away from `id`, keeping its other shortcuts.
func release_shortcut(id: StringName, text: String) -> void:
	var event: InputEventKey = Shortcuts.parse(text)
	var kept: PackedStringArray = PackedStringArray()
	for shortcut: String in shortcuts(id):
		if event == null or not Shortcuts.matches(event, Shortcuts.parse(shortcut)):
			kept.append(shortcut)
	var action: Action = _actions.get(id)
	if action != null and kept == action.default_shortcuts:
		set_shortcut(id, "")
	else:
		# An override holds one shortcut: the first one left stays.
		set_shortcut(id, kept[0] if not kept.is_empty() else "none")


## The action whose shortcut `event` presses, or &"".
func action_for_event(event: InputEventKey) -> StringName:
	# Actions may share a key (Ctrl+Z undoes a discard or a conflict choice):
	# the first enabled one wins.
	var first: StringName = &""
	for id: StringName in _actions:
		for shortcut: InputEventKey in _shortcut_events(id):
			if Shortcuts.matches(event, shortcut):
				if _actions[id].is_enabled():
					return id
				if first == &"":
					first = id
	return first


## Text fields swallow most keys. Before the focused one sees a key, run the
## action it presses when that is a Ctrl/Alt/F-key shortcut the field does not
## use for editing, or an action marked `in_text_fields`.
func _input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var focus: Control = get_viewport().gui_get_focus_owner()
	if not (focus is LineEdit or focus is TextEdit):
		return
	var id: StringName = action_for_event(key)
	var action: Action = _actions.get(id)
	if action == null:
		return
	if not action.in_text_fields and (not _is_command_key(key) or _is_text_editing_key(key)):
		return
	if run_action(id):
		get_viewport().set_input_as_handled()


static func _is_command_key(key: InputEventKey) -> bool:
	return key.is_command_or_control_pressed() or key.alt_pressed \
			or (key.keycode >= KEY_F1 and key.keycode <= KEY_F12)


## Whether text fields use `key` themselves (copy, undo, word jumps, ...).
static func _is_text_editing_key(key: InputEventKey) -> bool:
	for action: StringName in InputMap.get_actions():
		var action_name: String = String(action)
		var editing: bool = action_name.begins_with("ui_text_") \
				or action_name in ["ui_cut", "ui_copy", "ui_paste", "ui_undo", "ui_redo"]
		if editing and key.is_action(action, true):
			return true
	return false


func _shortcut_input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var id: StringName = action_for_event(key)
	if id != &"" and run_action(id):
		get_viewport().set_input_as_handled()


func _shortcut_events(id: StringName) -> Array:
	if not _parsed.has(id):
		var events: Array = []
		for text: String in shortcuts(id):
			var parsed: InputEventKey = Shortcuts.parse(text)
			if parsed != null:
				events.append(parsed)
		_parsed[id] = events
	return _parsed[id]
