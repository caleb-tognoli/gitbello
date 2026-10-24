class_name ShortcutsDialog
extends AcceptDialog
## Lists every action with its shortcut. Select one, then "Change" and press
## the new keys; "Reset" restores the default, "Remove" clears it.

var _tree: Tree = Tree.new()
var _hint: Label = Label.new()
var _capturing: StringName = &""


func _init() -> void:
	title = "Keyboard shortcuts"
	ok_button_text = "Close"
	var layout: VBoxContainer = VBoxContainer.new()
	add_child(layout)
	_tree.columns = 2
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.set_column_expand(1, false)
	layout.add_child(_tree)
	var buttons: HBoxContainer = HBoxContainer.new()
	layout.add_child(buttons)
	for spec: Array in [["Change", _start_capture], ["Reset", _reset], ["Remove", _remove]]:
		var button: Button = Button.new()
		button.text = String(spec[0])
		button.pressed.connect(spec[1])
		buttons.add_child(button)
	_hint.theme_type_variation = &"DimLabel"
	layout.add_child(_hint)
	Actions.actions_changed.connect(_rebuild)


func open() -> void:
	_rebuild()
	popup_centered_ratio(0.6)


func _rebuild() -> void:
	_tree.clear()
	var root: TreeItem = _tree.create_item()
	for action: ActionRegistry.Action in Actions.listed():
		var item: TreeItem = root.create_child()
		item.set_text(0, "%s: %s" % [action.category, action.label])
		item.set_text(1, Actions.shortcut_label(action.id))
		item.set_metadata(0, action.id)


func _selected() -> StringName:
	var item: TreeItem = _tree.get_selected()
	return StringName(item.get_metadata(0)) if item != null else &""


func _start_capture() -> void:
	_capturing = _selected()
	_hint.text = "Press the new shortcut (Escape to cancel)" if _capturing != &"" else "Select an action first"


func _reset() -> void:
	var id: StringName = _selected()
	if id != &"":
		Actions.set_shortcut(id, "")


func _remove() -> void:
	var id: StringName = _selected()
	if id != &"":
		Actions.set_shortcut(id, "none")


func _input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if _capturing == &"" or key == null or not key.pressed or key.echo:
		return
	get_viewport().set_input_as_handled()
	if key.keycode == KEY_ESCAPE:
		_capturing = &""
		_hint.text = ""
		return
	var text: String = Shortcuts.from_event(key)
	if text.is_empty():
		return # modifier only; wait for the key
	var taken: StringName = Actions.action_for_event(key)
	Actions.set_shortcut(_capturing, text)
	_hint.text = "%s set%s" % [Shortcuts.display(text),
			" (also used by %s)" % Actions.get_action(taken).label if taken != &"" and taken != _capturing else ""]
	_capturing = &""
