class_name SegmentedControl
extends HBoxContainer
## An either/or choice as joined buttons (M7.15), such as Rows `Compact |
## Detailed`: each an icon and a short label, the chosen one filled with the
## accent. A click or Left / Right (with a segment focused) chooses; choosing
## the chosen one again does nothing. Styles are the `Segmented` and
## `SegmentedButton*` theme types.

## The user chose `id` (not sent by `set_value`).
signal selected(id: String)

const THEME_TYPE: StringName = &"Segmented"

var _group: ButtonGroup = ButtonGroup.new()
var _buttons: Array[Button] = []
var _ids: PackedStringArray = PackedStringArray()
## The chosen choice's index, kept here: the buttons' state has already
## changed when their press arrives.
var _current: int = -1


func _init() -> void:
	theme_type_variation = THEME_TYPE
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_CENTER


## Adds choice `id` with a white `icon` (`AppTheme.tintable_icon`, or null)
## and `text` (already translated); returns its button.
func add_choice(id: String, icon: Texture2D, text: String) -> Button:
	var button: Button = Button.new()
	button.toggle_mode = true
	button.button_group = _group
	button.icon = icon
	button.text = text
	button.focus_mode = Control.FOCUS_ALL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(_choose.bind(_buttons.size()))
	button.gui_input.connect(_on_key.bind(_buttons.size()))
	add_child(button)
	_buttons.append(button)
	_ids.append(id)
	if _buttons.size() == 1:
		set_value(id)
	_update_parts()
	return button


## The chosen id, or "" without choices.
func value() -> String:
	return _ids[_current] if _current >= 0 else ""


## Chooses `id` without sending `selected`.
func set_value(id: String) -> void:
	var index: int = _ids.find(id)
	if index >= 0:
		_current = index
		_buttons[index].set_pressed_no_signal(true)
		# A button group only lets go of the others on a press.
		for i: int in _buttons.size():
			if i != index:
				_buttons[i].set_pressed_no_signal(false)


## The button of choice `id`, or null.
func choice_button(id: String) -> Button:
	var index: int = _ids.find(id)
	return _buttons[index] if index >= 0 else null


func ids() -> PackedStringArray:
	return _ids


func _choose(index: int) -> void:
	var changed: bool = index != _current
	set_value(_ids[index])
	if changed:
		selected.emit(_ids[index])


func _on_key(event: InputEvent, index: int) -> void:
	var step: int = 0
	if event.is_action_pressed("ui_left", true, true):
		step = -1
	elif event.is_action_pressed("ui_right", true, true):
		step = 1
	if step == 0:
		return
	_buttons[index].accept_event()
	var next: int = clampi(index + step, 0, _buttons.size() - 1)
	if next == index:
		return
	_buttons[next].grab_focus()
	_choose(next)


## Rounds the outer corners only: the first, the last, or both for one.
func _update_parts() -> void:
	for i: int in _buttons.size():
		var first: bool = i == 0
		var last: bool = i == _buttons.size() - 1
		if first and last:
			_buttons[i].theme_type_variation = &"SegmentedButtonOnly"
		elif first:
			_buttons[i].theme_type_variation = &"SegmentedButtonFirst"
		elif last:
			_buttons[i].theme_type_variation = &"SegmentedButtonLast"
		else:
			_buttons[i].theme_type_variation = &"SegmentedButton"
