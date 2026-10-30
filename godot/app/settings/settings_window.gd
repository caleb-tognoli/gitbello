class_name SettingsWindow
extends AcceptDialog
## Edits the app settings like Godot's Editor Settings: categories on the left,
## their settings on the right, and a search over all of them. Changes apply
## immediately; a setting that differs from its default has a button to revert it.

const THEME_TYPE: StringName = &"SettingsDialog"
const FILTER_FIELD: PackedScene = preload("res://ui/filter_field/filter_field.tscn")
const CATEGORIES: Array = [
	[
		"General",
		[
			[&"pull_mode", "Pull", &"option", ["Fast-forward only", "Merge", "Rebase"],
				["ff-only", "merge", "rebase"]],
			[&"auto_fetch_minutes", "Auto-fetch", &"spin", [0, 99999, 1, " min"]],
			[&"editor_command", "Editor", &"line", "code {path}"],
			[&"terminal_command", "Terminal", &"line", "Platform default"],
		],
	],
	[
		"Worktrees",
		[
			[&"worktree_template", "New worktree folders", &"line", ".worktrees/{branch_slug}"],
			[&"branch_prefix", "Branch prefix", &"line", "None"],
		],
	],
	[
		"Interface",
		[
			[&"theme", "Theme", &"option", ["System", "Dark", "Light"], ["system", "dark", "light"]],
			[&"accent", "Accent colour", &"color"],
		],
	],
]
const DETAILS: Dictionary = {
	&"pull_mode": "How Pull integrates the remote branch into the current branch",
	&"auto_fetch_minutes": "Minutes between automatic fetches; 0 turns auto-fetch off",
	&"editor_command": "The command for Open in editor; {path} is replaced by the folder",
	&"terminal_command": "The command for Open terminal here; {path} is replaced by the folder. Leave empty for the platform's terminal.",
	&"worktree_template": "Relative paths start at the repository root. {repo_parent}, {repo_name}, {repo}, {branch_slug} and {branch} are filled in.",
	&"branch_prefix": "Starts the name of new worktrees' branches, for example caleb/",
	&"theme": "System follows the operating system's dark or light mode",
	&"accent": "Used for selections, focused fields and active controls",
}
const DEFAULTS: Dictionary = {
	&"pull_mode": "ff-only",
	&"auto_fetch_minutes": 10,
	&"editor_command": "code {path}",
	&"terminal_command": "",
	&"worktree_template": ".worktrees/{branch_slug}",
	&"branch_prefix": "",
	&"theme": "system",
	&"accent": "",
}

var categories: ItemList = ItemList.new()
var search: FilterField = FILTER_FIELD.instantiate() as FilterField

var _list: VBoxContainer = VBoxContainer.new()
var _error: Label = Label.new()
var _rows: Array[Dictionary] = []
var _headers: Array[Label] = []
var _refreshers: Dictionary[StringName, Callable] = {}
var _category: String = "General"
var _refreshing: bool = false
var _reset: ConfirmationDialog = ConfirmationDialog.new()


func _init() -> void:
	title = "Settings"
	ok_button_text = "Close"
	min_size = Vector2i(820, 520)
	var reset: Button = add_button("Reset All…", false, &"reset")
	reset.icon = AppTheme.icon(&"Reload")
	reset.tooltip_text = "Restore every setting to its default"
	custom_action.connect(_on_custom_action)

	var content: VBoxContainer = VBoxContainer.new()
	content.add_theme_constant_override(&"separation", 8)
	add_child(content)
	var layout: HBoxContainer = HBoxContainer.new()
	layout.add_theme_constant_override(&"separation", 12)
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(layout)

	var left: VBoxContainer = VBoxContainer.new()
	left.custom_minimum_size.x = 190.0
	layout.add_child(left)
	search.placeholder = "Filter settings"
	left.add_child(search)
	categories.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(categories)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override(&"separation", 4)
	scroll.add_child(_list)
	_error.theme_type_variation = &"ErrorLabel"
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.hide()
	content.add_child(_error)
	_build()

	categories.item_selected.connect(_on_category_selected)
	search.changed.connect(_filter)

	_reset.title = "Reset settings"
	_reset.dialog_text = "Restore every setting to its default?"
	_reset.ok_button_text = "Reset"
	_reset.confirmed.connect(reset_to_defaults)
	add_child(_reset)


func _ready() -> void:
	get_ok_button().theme_type_variation = &"PrimaryButton"
	_reset.get_ok_button().theme_type_variation = &"DangerButton"
	for row: Dictionary in _rows:
		(row.label as Label).custom_minimum_size.x = get_theme_constant(&"label_width", THEME_TYPE)
	_refresh(&"")


func open() -> void:
	search.set_text("")
	_refresh(&"")
	_filter()
	reset_size()
	popup_centered(Vector2i(get_theme_constant(&"width", THEME_TYPE),
			get_theme_constant(&"height", THEME_TYPE)))
	search.focus_text()


func show_category(category: String) -> void:
	_category = category
	search.set_text("")
	_filter()


func get_control(key: StringName) -> Control:
	for row: Dictionary in _rows:
		if row.key == key:
			return row.control as Control
	return null


func get_revert_button(key: StringName) -> Button:
	for row: Dictionary in _rows:
		if row.key == key:
			return row.revert as Button
	return null


func reset_to_defaults() -> void:
	var values: Dictionary = DEFAULTS.duplicate()
	values.erase(&"theme")
	var error: String = Core.set_settings(values)
	if not error.is_empty():
		_show_error(&"", error)
		return
	Core.set_theme_choice(String(DEFAULTS[&"theme"]))
	ThemeManager.apply(self)
	_refresh(&"")
	_show_error(&"", "")


func _build() -> void:
	for category: Array in CATEGORIES:
		var category_name: String = category[0]
		categories.add_item(category_name)
		var header: Label = Label.new()
		header.text = category_name
		header.theme_type_variation = &"HeaderSmall"
		_list.add_child(header)
		_headers.append(header)
		for row: Array in category[1]:
			_add_row(category_name, row)


func _add_row(category: String, definition: Array) -> void:
	var key: StringName = definition[0]
	var box: HBoxContainer = HBoxContainer.new()
	box.custom_minimum_size.y = 34.0
	box.add_theme_constant_override(&"separation", 8)
	var label: Label = Label.new()
	label.text = definition[1]
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.tooltip_text = DETAILS.get(key, definition[1])
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_child(label)

	var control: Control = _create_control(key, definition[2], definition.slice(3))
	var editor: Control = control.get_meta(&"editor", control) as Control
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.tooltip_text = label.tooltip_text
	box.add_child(control)
	var revert: Button = Button.new()
	revert.icon = AppTheme.icon(&"Reload")
	revert.theme_type_variation = &"ToolbarButton"
	revert.tooltip_text = "Revert to the default"
	revert.pressed.connect(func() -> void: _set_value(key, DEFAULTS[key]))
	var revert_slot: CenterContainer = CenterContainer.new()
	revert_slot.custom_minimum_size = Vector2(32, 34)
	revert_slot.add_child(revert)
	box.add_child(revert_slot)
	_list.add_child(box)
	_rows.append({
		"key": key,
		"category": category,
		"text": definition[1],
		"details": DETAILS.get(key, ""),
		"row": box,
		"label": label,
		"control": editor,
		"revert": revert,
	})


func _create_control(key: StringName, kind: StringName, options: Array) -> Control:
	match kind:
		&"line":
			var line: LineEdit = LineEdit.new()
			line.placeholder_text = options[0]
			line.text_submitted.connect(func(_text: String) -> void: _commit_line(key, line))
			line.focus_exited.connect(func() -> void: _commit_line(key, line))
			_refreshers[key] = func() -> void: line.text = String(_current_value(key))
			return line
		&"spin":
			var spin: SpinBox = SpinBox.new()
			spin.min_value = options[0][0]
			spin.max_value = options[0][1]
			spin.step = options[0][2]
			spin.suffix = options[0][3]
			spin.alignment = HORIZONTAL_ALIGNMENT_RIGHT
			spin.value_changed.connect(func(value: float) -> void: _set_value(key, int(value)))
			_refreshers[key] = func() -> void: spin.set_value_no_signal(int(_current_value(key)))
			return spin
		&"color":
			return _create_color_control(key)
		_:
			var option: OptionButton = OptionButton.new()
			var labels: Array = options[0]
			var values: Array = options[1]
			for label: String in labels:
				option.add_item(label)
			option.item_selected.connect(func(index: int) -> void: _set_value(key, values[index]))
			_refreshers[key] = func() -> void:
				option.select(maxi(0, values.find(_current_value(key))))
			return option


func _create_color_control(key: StringName) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 2)
	var picker: ColorPickerButton = ColorPickerButton.new()
	picker.edit_alpha = false
	picker.custom_minimum_size.x = 64.0
	var swatches: Array[Button] = []
	var group: ButtonGroup = ButtonGroup.new()
	group.allow_unpress = true
	picker.color_changed.connect(func(color: Color) -> void: _set_value(key, _stored_accent(color)))
	for preset: Color in AppTheme.ACCENT_PRESETS:
		var swatch: Button = Button.new()
		swatch.icon = AppTheme.swatch(preset)
		swatch.theme_type_variation = &"ToolbarButton"
		swatch.toggle_mode = true
		swatch.button_group = group
		swatch.tooltip_text = "#" + preset.to_html(false)
		swatch.pressed.connect(func() -> void: _set_value(key, _stored_accent(preset)))
		swatches.append(swatch)
		row.add_child(swatch)
	row.add_child(picker)
	row.set_meta(&"editor", picker)
	_refreshers[key] = func() -> void:
		var color: Color = ThemeManager.configured_accent()
		picker.color = color
		for i: int in swatches.size():
			swatches[i].set_pressed_no_signal(AppTheme.ACCENT_PRESETS[i].is_equal_approx(color))
	return row


func _commit_line(key: StringName, line: LineEdit) -> void:
	if not _refreshing:
		_set_value(key, line.text.strip_edges())


func _set_value(key: StringName, value: Variant) -> bool:
	if _refreshing:
		return true
	var error: String = _validation_error(key, value)
	if error.is_empty() and _current_value(key) != value:
		if key == &"theme":
			Core.set_theme_choice(String(value))
			ThemeManager.apply(self)
		else:
			error = Core.set_settings({key: value})
			if error.is_empty() and key == &"accent":
				ThemeManager.apply(self)
	_show_error(key, error)
	if error.is_empty():
		_refresh(key)
	return error.is_empty()


func _validation_error(key: StringName, value: Variant) -> String:
	var text: String = str(value).strip_edges()
	match key:
		&"editor_command":
			return "Enter an editor command." if text.is_empty() else ""
		&"worktree_template":
			return "Enter a worktree folder template." if text.is_empty() else ""
		&"branch_prefix":
			return Core.branch_prefix_error(text)
	return ""


func _current_value(key: StringName) -> Variant:
	if key == &"theme":
		return Core.theme_choice()
	return Core.settings().get(key, DEFAULTS[key])


func _refresh(key: StringName) -> void:
	_refreshing = true
	for k: StringName in _refreshers:
		if key.is_empty() or k == key:
			_refreshers[k].call()
	for row: Dictionary in _rows:
		if key.is_empty() or row.key == key:
			var is_default: bool = _current_value(row.key) == DEFAULTS[row.key]
			(row.revert as Button).visible = not is_default
	_refreshing = false


func _filter() -> void:
	var query: String = search.text().strip_edges().to_lower()
	categories.deselect_all()
	for i: int in categories.item_count:
		if query.is_empty() and categories.get_item_text(i) == _category:
			categories.select(i)
	var shown_categories: Dictionary = {}
	for row: Dictionary in _rows:
		var described: String = "%s %s" % [row.text, row.details]
		var shown: bool = query in described.to_lower() if not query.is_empty() else row.category == _category
		(row.row as Control).visible = shown
		if shown:
			shown_categories[row.category] = true
	for header: Label in _headers:
		header.visible = not query.is_empty() and shown_categories.has(header.text)


func _show_error(key: StringName, text: String) -> void:
	_error.text = text
	_error.visible = not text.is_empty()
	_error.tooltip_text = text
	if key != &"":
		var control: Control = get_control(key)
		if control != null:
			control.tooltip_text = text if not text.is_empty() else String(DETAILS.get(key, ""))


func _stored_accent(color: Color) -> String:
	return "" if color.is_equal_approx(AppTheme.DEFAULT_ACCENT) else "#" + color.to_html(false)


func _on_category_selected(index: int) -> void:
	_category = categories.get_item_text(index)
	search.set_text("")
	_filter()


func _on_custom_action(action: StringName) -> void:
	if action == &"reset":
		_reset.popup_centered()
