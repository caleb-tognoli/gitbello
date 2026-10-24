class_name ActionRegistry
extends Node
## Every user-facing operation (AGENTS rule 10, PLAN §3.7). Menus, context
## menus, the command palette and shortcuts all read from here. Autoloaded as
## `Actions`.
##
## Shortcuts: each action has default shortcuts; a user override from the
## config (`Core.keybindings()`) replaces them.

signal actions_changed()
## An action ran (for tests and status messages).
signal action_ran(id: StringName)


class Action:
	extends RefCounted
	var id: StringName
	var label: String
	var category: String
	var run: Callable
	## Returns bool; an invalid Callable means always enabled.
	var enabled: Callable
	var default_shortcuts: PackedStringArray
	## Hidden actions run from shortcuts but are not listed in the palette.
	var hidden: bool = false

	func is_enabled() -> bool:
		return not enabled.is_valid() or bool(enabled.call())


var _actions: Dictionary[StringName, Action] = {}
var _overrides: Dictionary[StringName, String] = {}
var _parsed: Dictionary[StringName, Array] = {}


func _ready() -> void:
	var bindings: Dictionary = Core.keybindings()
	for id: Variant in bindings:
		_overrides[StringName(str(id))] = str(bindings[id])


## Registers (or replaces) an action. `shortcuts` are defaults like "Ctrl+K".
func register(id: StringName, label: String, category: String, run: Callable,
		shortcuts: PackedStringArray = PackedStringArray(),
		enabled: Callable = Callable()) -> Action:
	var action: Action = Action.new()
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


## Runs `id` if it exists and is enabled. Returns whether it ran.
func run_action(id: StringName) -> bool:
	var action: Action = _actions.get(id)
	if action == null or not action.is_enabled():
		return false
	action.run.call()
	action_ran.emit(id)
	return true


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
