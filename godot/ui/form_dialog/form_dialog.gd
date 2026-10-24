class_name FormDialog
extends ConfirmationDialog
## A small form in a dialog (new branch, rename, tag, upstream): text lines,
## check boxes, choices and a multi-line text, checked by `validator` as the
## user types. Enter in a line submits when the form is valid.

## The user changed field `key` (code setting a value does not count).
signal field_changed(key: String)

const THEME_TYPE: StringName = &"FormDialog"

## `func(values: Dictionary) -> String`: an error to show, or "" when valid.
## Errors show once the user changed something; OK is disabled before that too.
var validator: Callable = Callable()

var _fields: Dictionary[String, Control] = {}
var _ref_names: Array[String] = []
var _touched: bool = false
## `func(values: Dictionary) -> void`, called with the submitted values.
var _on_submit: Callable = Callable()

@onready var _box: VBoxContainer = %Fields
@onready var _error: Label = %Error


func _ready() -> void:
	confirmed.connect(_submit)
	_apply_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()


## Clears the form and sets what it is for. `on_submit` receives the values.
func begin(title_text: String, ok_text: String, on_submit: Callable) -> void:
	title = title_text
	ok_button_text = ok_text
	_on_submit = on_submit
	validator = Callable()
	for child: Node in _box.get_children():
		_box.remove_child(child)
		child.queue_free()
	_fields.clear()
	_ref_names.clear()
	_touched = false
	_error.text = ""


## A one-line text field. `ref_name` turns typed spaces into dashes.
func add_line(key: String, label: String, value: String = "", ref_name: bool = false,
		placeholder: String = "") -> LineEdit:
	_add_label(label)
	var line: LineEdit = LineEdit.new()
	line.text = value
	line.placeholder_text = placeholder
	line.text_changed.connect(_on_line_changed.bind(line))
	line.text_submitted.connect(func(_text: String) -> void: submit())
	_box.add_child(line)
	_fields[key] = line
	if ref_name:
		_ref_names.append(key)
	return line


func add_check(key: String, label: String, value: bool = false) -> CheckBox:
	var check: CheckBox = CheckBox.new()
	check.text = label
	check.button_pressed = value
	check.toggled.connect(func(_on: bool) -> void: _touch(key))
	_box.add_child(check)
	_fields[key] = check
	return check


## A drop-down; its value is the chosen option's text.
func add_choice(key: String, label: String, options: PackedStringArray, selected: int = 0) -> OptionButton:
	_add_label(label)
	var choice: OptionButton = OptionButton.new()
	for option: String in options:
		choice.add_item(option)
	choice.selected = clampi(selected, -1, options.size() - 1)
	choice.item_selected.connect(func(_index: int) -> void: _touch(key))
	_box.add_child(choice)
	_fields[key] = choice
	return choice


func add_text(key: String, label: String, value: String = "", placeholder: String = "") -> TextEdit:
	_add_label(label)
	var text: TextEdit = TextEdit.new()
	text.text = value
	text.placeholder_text = placeholder
	text.custom_minimum_size.y = float(get_theme_constant(&"text_height", THEME_TYPE))
	text.text_changed.connect(_touch.bind(key))
	_box.add_child(text)
	_fields[key] = text
	return text


## A line of explanation (dim).
func add_note(text: String) -> Label:
	var note: Label = Label.new()
	note.text = text
	note.theme_type_variation = &"DimLabel"
	# Wrapping needs a width up front, or the label measures itself tall.
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = float(get_theme_constant(&"note_width", THEME_TYPE))
	_box.add_child(note)
	return note


func field(key: String) -> Control:
	return _fields.get(key)


## Current values: text for lines, texts and choices, bool for check boxes.
func values() -> Dictionary:
	var out: Dictionary = {}
	for key: String in _fields:
		var control: Control = _fields[key]
		if control is LineEdit:
			out[key] = (control as LineEdit).text.strip_edges()
		elif control is TextEdit:
			out[key] = (control as TextEdit).text
		elif control is CheckBox:
			out[key] = (control as CheckBox).button_pressed
		elif control is OptionButton:
			var choice: OptionButton = control as OptionButton
			out[key] = choice.get_item_text(choice.selected) if choice.selected >= 0 else ""
	return out


func error_text() -> String:
	return _error.text


func open() -> void:
	_validate()
	# Shrink to this form's fields (an earlier, larger form set the size).
	reset_size()
	popup_centered(Vector2i(get_theme_constant(&"width", THEME_TYPE), 0))
	for key: String in _fields:
		var control: Control = _fields[key]
		if control is LineEdit or control is TextEdit:
			control.grab_focus()
			if control is LineEdit:
				(control as LineEdit).select_all()
			return
	get_ok_button().grab_focus()


## Submits like the OK button, if the form is valid. Returns whether it did.
func submit() -> bool:
	_touched = true
	if not _validate():
		return false
	hide()
	_submit()
	return true


func _submit() -> void:
	if _on_submit.is_valid():
		_on_submit.call(values())


func _validate() -> bool:
	var error: String = String(validator.call(values())) if validator.is_valid() else ""
	_error.text = error if _touched else ""
	_error.visible = not _error.text.is_empty()
	get_ok_button().disabled = not error.is_empty()
	return error.is_empty()


func _touch(key: String = "") -> void:
	_touched = true
	if not key.is_empty():
		field_changed.emit(key)
	_validate()


func _on_line_changed(text: String, line: LineEdit) -> void:
	var key: String = _fields.find_key(line)
	if key in _ref_names and text.contains(" "):
		var caret: int = line.caret_column
		line.text = text.replace(" ", "-")
		line.caret_column = caret
	_touch(key)


func _add_label(text: String) -> void:
	if text.is_empty():
		return
	var label: Label = Label.new()
	label.text = text
	_box.add_child(label)


func _apply_theme() -> void:
	_box.add_theme_constant_override(&"separation", get_theme_constant(&"separation", THEME_TYPE))
