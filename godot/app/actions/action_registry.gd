class_name ActionRegistry
extends Node
## Every user-facing operation (AGENTS rule 10, PLAN §3.7). Menus, context
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
	&"repo.open": &"FolderAdd",
	&"repo.refresh": &"Reload",
	&"tab.close": &"Close",
	&"repo.open_in_editor": &"ExternalLink",
	&"repo.open_terminal": &"Terminal",
	&"repo.show_in_file_manager": &"Folder",
	&"repo.remotes": &"GitRemote",
	&"repo.tags": &"GitTag",
	&"view.changes": &"FileList",
	&"view.history": &"History",
	&"view.find": &"Search",
	&"view.toggle_git_log": &"Terminal",
	&"history.next_match": &"ChevronDown",
	&"history.previous_match": &"ChevronUp",
	&"diff.copy": &"ActionCopy",
	&"diff.toggle_side_by_side": &"Panels2Alt",
	&"diff.toggle_whole_file": &"ExpandAll",
	&"changes.open_file": &"TextFile",
	&"changes.show_file": &"Folder",
	&"changes.copy_path": &"ActionCopy",
	&"changes.focus_message": &"GitCommit",
	&"changes.commit": &"GitCommit",
	&"changes.discard": &"Remove",
	&"changes.undo_discard": &"Undo",
	&"changes.shelve": &"GitShelf",
	&"changes.shelve_listed": &"GitShelf",
	&"changes.discard_listed": &"Remove",
	&"view.shelves": &"GitShelf",
	&"shelf.restore": &"Undo",
	&"shelf.restore_file": &"Undo",
	&"shelf.discard_file": &"Remove",
	&"shelf.restore_left": &"Undo",
	&"shelf.rename": &"Rename",
	&"shelf.discard": &"Remove",
	&"shelf.undo_discard": &"Undo",
	&"sync.sync": &"Reload",
	&"sync.fetch": &"GitFetch",
	&"sync.pull": &"GitPull",
	&"sync.pull_merge": &"GitPull",
	&"sync.pull_rebase": &"GitPull",
	&"sync.pull_ff_only": &"GitPull",
	&"sync.push": &"GitPush",
	&"sync.force_push": &"GitPush",
	&"sync.cancel": &"Close",
	&"branch.switch": &"GitBranch",
	&"branch.checkout": &"GitBranch",
	&"branch.new": &"GitBranch",
	&"branch.rename": &"Rename",
	&"branch.delete": &"Remove",
	&"branch.set_upstream": &"GitRemote",
	&"tag.new": &"GitTag",
	&"tag.push": &"GitPush",
	&"tag.delete": &"Remove",
	&"commit.checkout": &"GitCommit",
	&"commit.copy_hash": &"ActionCopy",
	&"task.new": &"GitWorktree",
	&"worktree.add_existing": &"GitWorktree",
	&"worktree.open": &"GitWorktree",
	&"worktree.cleanup": &"Clear",
	&"worktree.prune": &"Clear",
	&"worktree.remove": &"Remove",
	&"worktree.open_in_editor": &"ExternalLink",
	&"worktree.open_terminal": &"Terminal",
	&"worktree.show_in_file_manager": &"Folder",
	&"worktree.copy_path": &"ActionCopy",
	&"worktree.lock": &"Lock",
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

	func is_enabled() -> bool:
		return not enabled.is_valid() or bool(enabled.call())

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
		shortcuts: PackedStringArray = PackedStringArray(),
		enabled: Callable = Callable(), reason: Callable = Callable()) -> Action:
	var action: Action = Action.new()
	action.reason = reason
	action.id = id
	action.label = label
	action.category = category
	action.run = run
	action.enabled = enabled
	action.default_shortcuts = shortcuts
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
	var name: StringName = ICONS.get(id, &"")
	return AppTheme.icon(name) if name != &"" else null


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


func is_enabled(id: StringName) -> bool:
	var action: Action = _actions.get(id)
	return action != null and action.is_enabled()


## Runs `id` if it exists and is enabled. Returns whether it ran. `origin` is
## the control that started it, if any (see `origin()`).
func run_action(id: StringName, origin: Control = null) -> bool:
	var action: Action = _actions.get(id)
	if action == null or not action.is_enabled():
		return false
	var outer: Control = _origin
	_origin = origin
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


## `Label (Shortcut)`, plus why it is disabled when it is: for tooltips.
func tooltip(id: StringName) -> String:
	var action: Action = _actions.get(id)
	if action == null:
		return ""
	var shortcut: String = shortcut_label(id)
	var text: String = action.label if shortcut.is_empty() else "%s (%s)" % [action.label, shortcut]
	var why: String = action.disabled_reason()
	return text if why.is_empty() else "%s\n%s" % [text, why]


## Effective shortcuts: the user's override, else the defaults.
func shortcuts(id: StringName) -> PackedStringArray:
	if _overrides.has(id):
		var override: String = _overrides[id]
		return PackedStringArray() if override == "none" else PackedStringArray([override])
	var action: Action = _actions.get(id)
	return action.default_shortcuts if action != null else PackedStringArray()


## First effective shortcut for display, or "".
func shortcut_label(id: StringName) -> String:
	var list: PackedStringArray = shortcuts(id)
	return Shortcuts.display(list[0]) if not list.is_empty() else ""


## Sets the user's shortcut for `id` and saves it. "" restores the default;
## "none" removes every shortcut.
func set_shortcut(id: StringName, text: String) -> void:
	if text.is_empty():
		_overrides.erase(id)
	else:
		_overrides[id] = text
	_parsed.erase(id)
	Core.set_keybinding(String(id), text)
	actions_changed.emit()


## The action whose shortcut `event` presses, or &"".
func action_for_event(event: InputEventKey) -> StringName:
	for id: StringName in _actions:
		for shortcut: InputEventKey in _shortcut_events(id):
			if Shortcuts.matches(event, shortcut):
				return id
	return &""


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
