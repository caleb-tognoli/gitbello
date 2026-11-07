class_name RefsPopover
extends PopupPanel
## Every ref of a commit (M7.10), opened from a history row's "+N" chip: one
## row each with its chip (`RefChip`) and, for a branch whose remote branch
## is at the same commit, that remote branch muted beside it. A click,
## Enter or right-click on a row emits `menu_requested` for the ref's menu.

## Show the menu of `ref` (`RefChip.ref_target`) at `at_position` (screen).
signal menu_requested(ref: Dictionary, at_position: Vector2)

var _rows: VBoxContainer = VBoxContainer.new()


func _ready() -> void:
	theme_type_variation = &"WorktreeListPanel"
	_rows.theme_type_variation = &"WorktreeListRows"
	add_child(_rows)


## Opens at `at_position` (screen) with a row per label of `refs`.
func open_at(refs: Array, at_position: Vector2) -> void:
	fill(refs)
	popup(Rect2i(Vector2i(at_position), Vector2i.ZERO))
	reset_size()
	size = Vector2i(Vector2(size) * get_parent().get_window().content_scale_factor)
	if _rows.get_child_count() > 0:
		(_rows.get_child(0) as Control).grab_focus.call_deferred()


## Builds a row per label of `refs`.
func fill(refs: Array) -> void:
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	for ref_label: Dictionary in refs:
		var row: Button = _row(ref_label)
		_rows.add_child(row)
		_fit(row)


## The rows' ref names, for tests.
func names() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for row: Node in _rows.get_children():
		out.append(String((row.get_meta(&"label") as Dictionary)["name"]))
	return out


## Opens the menu of row `index` as a click would (for tests).
func choose(index: int) -> void:
	(_rows.get_child(index) as Button).pressed.emit()


func _row(ref_label: Dictionary) -> Button:
	var row: Button = Button.new()
	row.theme_type_variation = &"WorktreeListRow"
	row.focus_mode = Control.FOCUS_ALL
	row.set_meta(&"label", ref_label)
	row.tooltip_text = RefChip.tooltip(ref_label)
	row.pressed.connect(_choose.bind(row))
	row.gui_input.connect(func(event: InputEvent) -> void:
		var mouse: InputEventMouseButton = event as InputEventMouseButton
		if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT:
			row.accept_event()
			_choose(row))
	var line: HBoxContainer = HBoxContainer.new()
	line.theme_type_variation = &"WorktreeListLine"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(line)
	var chip: RefChip = RefChip.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.label = ref_label
	line.add_child(chip)
	var remotes: Array = ref_label.get("remotes", [])
	if not remotes.is_empty():
		var also: Label = Label.new()
		also.theme_type_variation = &"DimLabel"
		also.text = ", ".join(PackedStringArray(remotes))
		line.add_child(also)
	return row


## A button's children don't size it: makes room for the row's line (once
## the row is in the tree, so the theme applies).
func _fit(row: Button) -> void:
	var line: HBoxContainer = row.get_child(0) as HBoxContainer
	var style: StyleBox = row.get_theme_stylebox(&"normal")
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_left = style.get_margin(SIDE_LEFT)
	line.offset_top = style.get_margin(SIDE_TOP)
	line.offset_right = -style.get_margin(SIDE_RIGHT)
	line.offset_bottom = -style.get_margin(SIDE_BOTTOM)
	row.custom_minimum_size = line.get_combined_minimum_size() + style.get_minimum_size()


func _choose(row: Button) -> void:
	var at: Vector2 = row.get_screen_transform() * Vector2(0.0, row.size.y)
	hide()
	# After the popover has closed, so the menu does not open over it.
	menu_requested.emit.call_deferred(RefChip.ref_target(row.get_meta(&"label")), at)
