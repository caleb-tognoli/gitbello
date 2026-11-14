extends Node
## M7.15 P1 shots, dark then light: the options popover at its defaults,
## with filters on (Clear showing) and a segment focused from the keyboard,
## then the check boxes, radio buttons, switches and a menu's check items in
## the new check style. Each popover shot has a 2x crop. Needs no repository
## and writes no settings (the theme is built here, not from the config).
## Popups are embedded in the window so nothing opens beside it.
##
##   --out=<dir>

var _out: String = ""
var _step: int = 0
var _popover: OptionsPopover = null
var _anchor: Button = null


func _ready() -> void:
	DisplayServer.window_set_position(Vector2i(-10000, -10000))
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if _out.is_empty():
		printerr("options_popover_screenshots: pass --out=<dir>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_viewport().gui_embed_subwindows = true
	get_window().size = Vector2i(900, 560)
	for light: bool in [false, true]:
		var theme_name: String = "light" if light else "dark"
		_apply_theme(light)
		var page: Control = _build_page()
		add_child(page)
		await _settle()
		_popover.open_below(_anchor)
		await _shot("%s-defaults" % theme_name, true)
		(_popover.control("new") as ToggleChip).button_pressed = true
		(_popover.control("modified") as ToggleChip).button_pressed = true
		(_popover.control("rows") as SegmentedControl).choice_button("compact").pressed.emit()
		await _shot("%s-filters-on" % theme_name, true)
		var detailed: Button = (_popover.control("rows") as SegmentedControl).choice_button("detailed")
		detailed.grab_focus()
		await _shot("%s-segment-focused" % theme_name, true)
		_popover.hide()
		await _shot("%s-checks" % theme_name, false)
		var menu: PopupMenu = page.get_meta(&"menu") as PopupMenu
		menu.popup(Rect2i(Vector2i(520, 300), Vector2i.ZERO))
		await _shot("%s-menu-checks" % theme_name, false)
		menu.hide()
		page.queue_free()
		await get_tree().process_frame
	get_tree().quit(0)


## The project theme rebuilt in the light or dark palette, as
## `ThemeManager.apply` does, without reading or writing the config.
func _apply_theme(light: bool) -> void:
	var project_theme: Theme = ThemeDB.get_project_theme()
	project_theme.clear()
	project_theme.merge_with(AppTheme.build(light))
	RenderingServer.set_default_clear_color(AppTheme.palette(light).background)
	get_tree().root.propagate_notification(Control.NOTIFICATION_THEME_CHANGED)


func _build_page() -> Control:
	var page: PanelContainer = PanelContainer.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin: MarginContainer = MarginContainer.new()
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	page.add_child(margin)
	var columns: HBoxContainer = HBoxContainer.new()
	columns.add_theme_constant_override(&"separation", 40)
	margin.add_child(columns)
	# Left: a field with the options button at its right.
	var left: VBoxContainer = VBoxContainer.new()
	left.custom_minimum_size.x = 420
	columns.add_child(left)
	var bar: HBoxContainer = HBoxContainer.new()
	left.add_child(bar)
	var field: LineEdit = LineEdit.new()
	field.placeholder_text = "Filter files"
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(field)
	_anchor = Button.new()
	_anchor.icon = AppTheme.icon(&"Sliders")
	_anchor.theme_type_variation = &"FilterFieldButton"
	bar.add_child(_anchor)
	_popover = OptionsPopover.new()
	_popover.return_focus = field
	left.add_child(_popover)
	_popover.add_section("Filter", &"changes.clear_filters", &"Filter")
	_popover.add_chips("Show", [
		{"id": "new", "icon": "FileAdded", "label": "New"},
		{"id": "modified", "icon": "FileModified", "label": "Modified"},
		{"id": "deleted", "icon": "FileDeleted", "label": "Deleted"},
	])
	_popover.add_chips("Commit", [
		{"id": "included", "icon": "CommitIncluded", "label": "Included"},
		{"id": "excluded", "icon": "CommitExcluded", "label": "Excluded"},
	])
	_popover.add_chips("Also", [
		{"id": "endings", "icon": "LineEndings", "label": "Line endings only"},
		{"id": "ignored", "icon": "GitIgnore", "label": "Ignored"},
	])
	_popover.add_section("View", &"", &"RowsTwoLine")
	_popover.add_segmented("rows", "Rows", [
		{"id": "compact", "icon": "RowsOneLine", "label": "Compact"},
		{"id": "detailed", "icon": "RowsTwoLine", "label": "Detailed"},
	], "detailed", "detailed")
	_popover.add_segmented("scope", "Branches", [
		{"id": "current", "icon": "GitBranch", "label": "Current"},
		{"id": "all", "icon": "GitBranches", "label": "All"},
	], "current")
	_popover.add_chips("Graph", [{"id": "graph", "icon": "GitGraph", "label": "Show graph", "value": true,
		"default": true, "counted": false}])
	# Right: every kind of check, on, off and disabled.
	var right: VBoxContainer = VBoxContainer.new()
	columns.add_child(right)
	for entry: Array in [["Included in commit", true, false], ["Excluded from commit", false, false],
			["Disabled, on", true, true], ["Disabled, off", false, true]]:
		var check: CheckBox = CheckBox.new()
		check.text = entry[0]
		check.button_pressed = entry[1]
		check.disabled = entry[2]
		right.add_child(check)
	var group: ButtonGroup = ButtonGroup.new()
	for entry: Array in [["Current branch", true], ["All branches", false]]:
		var radio: CheckBox = CheckBox.new()
		radio.button_group = group
		radio.text = entry[0]
		radio.button_pressed = entry[1]
		right.add_child(radio)
	for entry: Array in [["Show profile pictures", true], ["Fetch automatically", false]]:
		var switch: CheckButton = CheckButton.new()
		switch.text = entry[0]
		switch.button_pressed = entry[1]
		right.add_child(switch)
	var menu: PopupMenu = PopupMenu.new()
	menu.add_radio_check_item("Current branch")
	menu.add_radio_check_item("All branches")
	menu.set_item_checked(0, true)
	menu.add_separator()
	menu.add_check_item("Minimap")
	menu.add_check_item("Word wrap")
	menu.set_item_checked(3, true)
	page.add_child(menu)
	page.set_meta(&"menu", menu)
	return page


func _settle() -> void:
	for frame: int in 20:
		await get_tree().process_frame


func _shot(shot_name: String, crop_popover: bool) -> void:
	await _settle()
	_step += 1
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = _out.path_join("%02d-%s.png" % [_step, shot_name])
	image.save_png(path)
	print("SHOT ", path)
	if crop_popover and _popover.visible:
		var rect: Rect2i = Rect2i(_popover.position - Vector2i(8, 8), _popover.size + Vector2i(16, 16)) \
				.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
		var crop: Image = image.get_region(rect)
		crop.resize(rect.size.x * 2, rect.size.y * 2, Image.INTERPOLATE_NEAREST)
		crop.save_png(_out.path_join("%02d-%s-crop.png" % [_step, shot_name]))
