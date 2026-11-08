class_name ShortcutChip
extends PanelContainer
## One shortcut drawn as key caps (`Ctrl` `Shift` `P`). Clicking it, or Enter
## or Space while it has focus, emits `activated` (the Keyboard page then
## records a new shortcut). Without a shortcut it reads "Add shortcut".

signal activated()

enum State { NORMAL, RECORDING, CONFLICT }

## Canonical text such as `Ctrl+Shift+P`, or "" for the Add chip.
var shortcut: String = ""
var state: State = State.NORMAL

var _keys: HBoxContainer = HBoxContainer.new()
var _hovered: bool = false
var _pulse: Tween = null


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_PASS
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_keys.theme_type_variation = &"ShortcutChipKeys"
	_keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_keys)
	mouse_entered.connect(func() -> void:
		_hovered = true
		_update_style())
	mouse_exited.connect(func() -> void:
		_hovered = false
		_update_style())
	focus_entered.connect(_update_style)
	focus_exited.connect(_update_style)
	_build()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_build()


func set_shortcut(text: String) -> void:
	shortcut = text
	_build()


func set_state(value: State) -> void:
	state = value
	_build()


func _gui_input(event: InputEvent) -> void:
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
		grab_focus()
		activated.emit()
		accept_event()
	elif event.is_action_pressed(&"ui_accept") and state == State.NORMAL:
		activated.emit()
		accept_event()


func _build() -> void:
	for child: Node in _keys.get_children():
		_keys.remove_child(child)
		child.queue_free()
	if state == State.RECORDING:
		_keys.add_child(_text(tr("Press keys…"), &"ShortcutChipPrompt"))
	elif shortcut.is_empty():
		_keys.add_child(_text(tr("Add shortcut"), &"ShortcutChipText"))
	else:
		for key: String in Shortcuts.display_keys(shortcut):
			var cap: PanelContainer = PanelContainer.new()
			cap.theme_type_variation = &"KeyCap"
			cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cap.add_child(_text(key, &"KeyCapLabel"))
			_keys.add_child(cap)
	_update_style()


func _text(value: String, variation: StringName) -> Label:
	var label: Label = Label.new()
	label.text = value
	label.theme_type_variation = variation
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _update_style() -> void:
	match state:
		State.RECORDING:
			theme_type_variation = &"ShortcutChipRecording"
		State.CONFLICT:
			theme_type_variation = &"ShortcutChipConflict"
		_:
			if _hovered:
				theme_type_variation = &"ShortcutChipHover"
			elif has_focus():
				theme_type_variation = &"ShortcutChipFocus"
			else:
				theme_type_variation = &"ShortcutChip"
	# The recording chip breathes until a key arrives.
	if state == State.RECORDING and _pulse == null and is_inside_tree():
		_pulse = create_tween().set_loops()
		_pulse.tween_property(self, ^"modulate:a", 0.55, 0.6).set_trans(Tween.TRANS_SINE)
		_pulse.tween_property(self, ^"modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)
	elif state != State.RECORDING and _pulse != null:
		_pulse.kill()
		_pulse = null
		modulate.a = 1.0
