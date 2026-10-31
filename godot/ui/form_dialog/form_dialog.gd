class_name FormDialog
extends ConfirmationDialog
## A small form in a dialog (new branch, rename, tag, upstream): text lines,
## check boxes, choices, colours and a multi-line text, checked by `validator`
## as the user types. Enter in a line submits when the form is valid.
## Labels sit in a column left of their fields; notes added before the first
## field introduce the form, later ones are hints under the field above.
## `set_menu` joins a ▾ to OK with other ways to submit (a split button).
## The buttons sit on the right, Cancel then OK.

## The user changed field `key` (code setting a value does not count).
signal field_changed(key: String)

const THEME_TYPE: StringName = &"FormDialog"

## `func(values: Dictionary) -> String`: what is wrong, or "" when valid.
## While something is wrong OK is disabled, with the reason as its tooltip.
var validator: Callable = Callable()
## Async forms keep the window open to show progress and errors.
var hide_on_submit: bool = true

var _fields: Dictionary[String, Control] = {}
var _ref_names: Array[String] = []
## Folder fields' `on_pick` (see `add_folder`).
var _pickers: Dictionary[String, Callable] = {}
## What is wrong with the values, or "" (see `validator`).
var _error: String = ""
## `func(values: Dictionary) -> void`, called with the submitted values.
var _on_submit: Callable = Callable()
## The ▾ joined to OK (see `set_menu`), what its entries run and their labels.
var _menu_button: MenuButton = MenuButton.new()
var _menu_runs: Array[Callable] = []
var _menu_labels: PackedStringArray = PackedStringArray()
## OK and the ▾, joined.
var _split: HBoxContainer = HBoxContainer.new()

@onready var _intro: VBoxContainer = %Intro
@onready var _box: GridContainer = %Fields


func _ready() -> void:
	get_ok_button().theme_type_variation = &"PrimaryButton"
	confirmed.connect(_submit)
	_menu_button.icon = AppTheme.ARROW_DOWN
	_menu_button.flat = false
	_menu_button.theme_type_variation = &"SplitMenuButton"
	_menu_button.tooltip_text = "More ways to do this"
	_menu_button.get_popup().id_pressed.connect(_on_menu_id)
	_arrange_buttons()
	_menu_button.hide()
	_apply_theme()


## Right-aligns the buttons, Cancel then OK, with the ▾ joined to OK.
func _arrange_buttons() -> void:
	var ok: Button = get_ok_button()
	var row: HBoxContainer = ok.get_parent() as HBoxContainer
	_split.add_theme_constant_override(&"separation", 0)
	ok.add_sibling(_split)
	ok.reparent(_split, false)
	_split.add_child(_menu_button)
	row.move_child(get_cancel_button(), 1)
	row.move_child(_split, 2)
	# The first spacer pushes the buttons right; the others would centre them.
	# The dialog shows and hides them itself, so they stop expanding and move
	# to the left end, where their gaps are taken from the first.
	var spacers: Array[Control] = []
	for child: Node in row.get_children(true):
		if child.get_class() == "Control":
			spacers.append(child as Control)
	for i: int in range(1, spacers.size()):
		spacers[i].size_flags_horizontal = Control.SIZE_FILL
		row.move_child(spacers[i], 0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()


## Clears the form and sets what it is for. `on_submit` receives the values.
func begin(title_text: String, ok_text: String, on_submit: Callable) -> void:
	title = tr(title_text)
	ok_button_text = tr(ok_text)
	cancel_button_text = tr("Cancel")
	get_ok_button().theme_type_variation = &"PrimaryButton"
	get_ok_button().icon = null
	_on_submit = on_submit
	validator = Callable()
	for parent: Node in [_intro, _box]:
		for child: Node in parent.get_children():
			parent.remove_child(child)
			child.queue_free()
	_intro.hide()
	_fields.clear()
	_ref_names.clear()
	_pickers.clear()
	_error = ""
	set_menu([])


## A one-line text field. `ref_name` turns typed spaces into dashes.
func add_line(key: String, label: String, value: String = "", ref_name: bool = false,
		placeholder: String = "") -> LineEdit:
	_add_label(tr(label))
	var line: LineEdit = LineEdit.new()
	line.text = value
	line.placeholder_text = tr(placeholder)
	line.text_changed.connect(_on_line_changed.bind(line))
	line.text_submitted.connect(func(_text: String) -> void: submit())
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_child(line)
	_fields[key] = line
	if ref_name:
		_ref_names.append(key)
	return line


## A folder path: a line with a button that picks a folder in the system's
## dialog. `on_pick` (`func(dir: String) -> String`) turns the picked folder
## into the line's text; without it the line takes the folder itself.
func add_folder(key: String, label: String, value: String = "", placeholder: String = "",
		on_pick: Callable = Callable()) -> LineEdit:
	var line: LineEdit = add_line(key, label, value, false, placeholder)
	_box.remove_child(line)
	var row: HBoxContainer = HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(line)
	var browse: Button = Button.new()
	browse.icon = AppTheme.icon(&"Folder")
	browse.tooltip_text = tr("Choose a folder")
	browse.focus_mode = Control.FOCUS_NONE
	browse.pressed.connect(_browse.bind(key))
	row.add_child(browse)
	_box.add_child(row)
	if on_pick.is_valid():
		_pickers[key] = on_pick
	return line


## Any control as a field, with a label (empty for none).
func add_control(key: String, label: String, control: Control) -> Control:
	_add_label(label, true)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_child(control)
	_fields[key] = control
	return control


## Other ways to submit, in a ▾ joined to OK: `{label, run, icon, disabled,
## tooltip}` entries; `run` gets the values like `on_submit`, a disabled
## entry shows its tooltip after the label. An empty list hides it.
func set_menu(entries: Array) -> void:
	var entries_menu: PopupMenu = _menu_button.get_popup()
	entries_menu.clear()
	_menu_runs.clear()
	_menu_labels.clear()
	for entry: Dictionary in entries:
		var label: String = String(entry["label"])
		var disabled: bool = bool(entry.get("disabled", false))
		var tooltip: String = tr(String(entry.get("tooltip", "")))
		var shown: String = "%s  ·  %s" % [tr(label), tooltip] if disabled and not tooltip.is_empty() else tr(label)
		var icon: StringName = entry.get("icon", &"")
		if icon.is_empty():
			entries_menu.add_item(shown, _menu_runs.size())
		else:
			entries_menu.add_icon_item(AppTheme.icon(icon), shown, _menu_runs.size())
		var index: int = entries_menu.item_count - 1
		entries_menu.set_item_disabled(index, disabled)
		entries_menu.set_item_tooltip(index, tooltip)
		_menu_runs.append(entry["run"])
		_menu_labels.append(label)
	_menu_button.visible = not entries.is_empty()
	get_ok_button().theme_type_variation = &"SplitPrimaryButton" if not entries.is_empty() else &"PrimaryButton"


## The icon before OK's text (until the next `begin`).
func set_ok_icon(icon: Texture2D) -> void:
	get_ok_button().icon = icon


## The ▾ joined to OK (for tests).
func menu_button() -> MenuButton:
	return _menu_button


## Labels of the ▾ entries (for tests).
func menu_labels() -> PackedStringArray:
	return _menu_labels.duplicate()


## Runs the ▾ entry labelled `label`, as a click would. Returns whether it ran.
func press_menu(label: String) -> bool:
	var entries_menu: PopupMenu = _menu_button.get_popup()
	for i: int in entries_menu.item_count:
		if _menu_labels[i] == label and not entries_menu.is_item_disabled(i):
			_on_menu_id(entries_menu.get_item_id(i))
			return true
	return false


## Checks the values again (after the form's state changed from outside).
func revalidate() -> void:
	_validate()


func _on_menu_id(id: int) -> void:
	if id < 0 or id >= _menu_runs.size() or not _validate():
		return
	var run: Callable = _menu_runs[id]
	var current: Dictionary = values()
	hide()
	run.call(current)


## Makes OK the red button of a delete or discard (until the next `begin`).
func make_destructive() -> void:
	get_ok_button().theme_type_variation = &"DangerButton"


## Shows or hides field `key` with its label. The dialog keeps its width;
## only its height follows.
func set_field_visible(key: String, shown: bool) -> void:
	var node: Control = _fields.get(key)
	while node != null and node.get_parent() != _box:
		node = node.get_parent() as Control
	if node == null or node.visible == shown:
		return
	node.visible = shown
	var index: int = node.get_index()
	if index > 0 and _box.columns == 2:
		(_box.get_child(index - 1) as Control).visible = shown
	_shrink_to_content()


## Sets folder field `key` from `dir`, as if picked in the dialog.
func pick_folder(key: String, dir: String) -> void:
	var line: LineEdit = _fields.get(key) as LineEdit
	if line == null:
		return
	line.text = String(_pickers[key].call(dir)) if _pickers.has(key) else dir
	line.caret_column = line.text.length()
	_validate()


func _browse(key: String) -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.use_native_dialog = true
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.title = tr("Choose a folder")
	# Start at the nearest folder of the path typed so far that exists.
	var dir: String = (_fields[key] as LineEdit).text.strip_edges()
	while not dir.is_empty() and not DirAccess.dir_exists_absolute(dir) and dir.get_base_dir() != dir:
		dir = dir.get_base_dir()
	if not dir.is_empty() and DirAccess.dir_exists_absolute(dir):
		dialog.current_dir = dir
	dialog.dir_selected.connect(func(path: String) -> void: pick_folder(key, path))
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


func add_check(key: String, label: String, value: bool = false) -> CheckBox:
	var check: CheckBox = CheckBox.new()
	check.text = tr(label)
	check.button_pressed = value
	check.toggled.connect(func(_on: bool) -> void: _touch(key))
	_add_label("")
	_box.add_child(check)
	_fields[key] = check
	return check


## A drop-down; its value is the chosen option's text.
func add_choice(key: String, label: String, options: PackedStringArray, selected: int = 0) -> OptionButton:
	_add_label(tr(label))
	var choice: OptionButton = OptionButton.new()
	for option: String in options:
		choice.add_item(option)
	choice.selected = clampi(selected, -1, options.size() - 1)
	choice.item_selected.connect(func(_index: int) -> void: _touch(key))
	choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_child(choice)
	_fields[key] = choice
	return choice


func add_text(key: String, label: String, value: String = "", placeholder: String = "") -> TextEdit:
	_add_label(tr(label), true)
	var text: TextEdit = TextEdit.new()
	text.text = value
	text.placeholder_text = tr(placeholder)
	text.custom_minimum_size.y = float(get_theme_constant(&"text_height", THEME_TYPE))
	text.text_changed.connect(_touch.bind(key))
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_child(text)
	_fields[key] = text
	return text


## A colour: swatches for `presets` and a picker for any other. Its value is
## `#rrggbb`.
func add_color(key: String, label: String, value: Color, presets: Array[Color] = []) -> ColorPickerButton:
	_add_label(tr(label))
	var row: HBoxContainer = HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var picker: ColorPickerButton = ColorPickerButton.new()
	picker.color = value
	picker.edit_alpha = false
	picker.custom_minimum_size = Vector2(56, 0)
	var swatches: Array[Button] = []
	var group: ButtonGroup = ButtonGroup.new()
	group.allow_unpress = true
	# The swatch of the picked colour shows pressed.
	var show_picked: Callable = func() -> void:
		for i: int in swatches.size():
			swatches[i].set_pressed_no_signal(presets[i].is_equal_approx(picker.color))
	picker.color_changed.connect(func(_color: Color) -> void:
		show_picked.call()
		_touch(key))
	for preset: Color in presets:
		var swatch: Button = Button.new()
		swatch.icon = AppTheme.swatch(preset)
		swatch.theme_type_variation = &"ToolbarButton"
		swatch.toggle_mode = true
		swatch.button_group = group
		swatch.tooltip_text = "#" + preset.to_html(false)
		swatch.pressed.connect(func() -> void:
			picker.color = preset
			show_picked.call()
			_touch(key))
		swatches.append(swatch)
		row.add_child(swatch)
	show_picked.call()
	row.add_child(picker)
	_box.add_child(row)
	_fields[key] = picker
	return picker


## A line of explanation (dim): introducing the form before the first field,
## else under the field above.
func add_note(text: String) -> Label:
	var note: Label = Label.new()
	note.text = tr(text)
	note.theme_type_variation = &"DimLabel"
	# Wrapping needs a width up front, or the label measures itself tall.
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = float(get_theme_constant(&"note_width", THEME_TYPE))
	if _box.get_child_count() == 0:
		_intro.add_child(note)
		_intro.show()
	else:
		_add_label("")
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
		elif control is ColorPickerButton:
			out[key] = "#" + (control as ColorPickerButton).color.to_html(false)
	return out


func error_text() -> String:
	return _error


func open() -> void:
	_validate()
	_fit_label_column()
	# Shrink to this form's fields (an earlier, larger form set the size).
	reset_size()
	popup_centered(Vector2i(get_theme_constant(&"width", THEME_TYPE), 0))
	# Wrapped notes measure themselves tall until laid out at full width.
	_shrink_to_content.call_deferred()
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
	if not _validate():
		return false
	if hide_on_submit:
		hide()
	_submit()
	return true


func _submit() -> void:
	if _on_submit.is_valid():
		_on_submit.call(values())


func _validate() -> bool:
	_error = tr(String(validator.call(values()))) if validator.is_valid() else ""
	get_ok_button().disabled = not _error.is_empty()
	get_ok_button().tooltip_text = _error
	_menu_button.disabled = not _error.is_empty()
	return _error.is_empty()


func _touch(key: String) -> void:
	field_changed.emit(key)
	_validate()


func _on_line_changed(text: String, line: LineEdit) -> void:
	var key: String = _fields.find_key(line)
	if key in _ref_names and text.contains(" "):
		var caret: int = line.caret_column
		line.text = text.replace(" ", "-")
		line.caret_column = caret
	_touch(key)


## The label column's cell for the next field: `text`, or empty space.
## `top` keeps it at the top of a tall field.
## A form without labelled fields (only check boxes and notes) drops the
## label column, so its fields line up with the intro.
func _fit_label_column() -> void:
	var labelled: bool = false
	for i: int in range(0, _box.get_child_count(), 2):
		labelled = labelled or not (_box.get_child(i) as Label).text.is_empty()
	_box.columns = 2 if labelled else 1
	if not labelled:
		for i: int in range(0, _box.get_child_count(), 2):
			(_box.get_child(i) as Control).hide()


func _shrink_to_content() -> void:
	if visible:
		# The dialog wraps its contents: a zero height becomes the least that fits.
		size = Vector2i(maxi(size.x, get_theme_constant(&"width", THEME_TYPE)), 0)


func _add_label(text: String, top: bool = false) -> void:
	var label: Label = Label.new()
	label.text = text
	label.custom_minimum_size.x = float(get_theme_constant(&"label_width", THEME_TYPE))
	label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN if top else Control.SIZE_SHRINK_CENTER
	_box.add_child(label)


func _apply_theme() -> void:
	var separation: int = get_theme_constant(&"separation", THEME_TYPE)
	_box.add_theme_constant_override(&"v_separation", separation)
	_box.add_theme_constant_override(&"h_separation", separation * 2)
	_intro.add_theme_constant_override(&"separation", separation)
	($Box as VBoxContainer).add_theme_constant_override(&"separation",
			get_theme_constant(&"section_separation", THEME_TYPE))
