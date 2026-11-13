class_name RefsPopover
extends PopupPanel
## Every ref of a commit (M7.10), opened from a counted ref chip: one row
## each with its chip (`RefChip`, its whole name up to half the window) and,
## for a branch whose remote branch is at the same commit, that remote
## branch muted beside it; a line between the branches and the tags. A
## click, Enter, the menu key or a right-click on a row emits
## `menu_requested` for the ref's menu, which opens over the popover
## (`over`): it stays open until one of the menu's entries runs.

## Show the menu of `ref` (`RefChip.ref_target`) at `at_position` (screen),
## over `over` (this popover).
signal menu_requested(ref: Dictionary, at_position: Vector2, over: Window)

## Share of the window's width a row's chip may take before its name is cut.
const MAX_WIDTH_SHARE: float = 0.5

var _rows: VBoxContainer = VBoxContainer.new()
var _buttons: Array[Button] = []


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
	if not _buttons.is_empty():
		# Focused for the keys, without the outline until a key moves it.
		_buttons[0].grab_focus.call_deferred(true)


## Builds a row per label of `refs`.
func fill(refs: Array) -> void:
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	_buttons.clear()
	var chip_width: float = get_parent().get_viewport().get_visible_rect().size.x * MAX_WIDTH_SHARE
	var tags: bool = false
	for ref_label: Dictionary in refs:
		var tag: bool = String(ref_label.get("kind", "")) == "tag"
		if tag and not tags and not _buttons.is_empty():
			_rows.add_child(HSeparator.new())
		tags = tags or tag
		var row: Button = _row(ref_label, chip_width)
		_rows.add_child(row)
		_buttons.append(row)
		_fit(row)


## The rows' ref names, for tests.
func names() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for row: Button in _buttons:
		out.append(String((row.get_meta(&"label") as Dictionary)["name"]))
	return out


## The chip of row `index`, for tests.
func chip(index: int) -> RefChip:
	return _buttons[index].get_child(0).get_child(0) as RefChip


## Row `index`, for tests.
func row_button(index: int) -> Button:
	return _buttons[index]


## Opens the menu of row `index` as a click would (for tests).
func choose(index: int) -> void:
	_buttons[index].pressed.emit()


func _row(ref_label: Dictionary, chip_width: float) -> Button:
	var button: Button = Button.new()
	button.theme_type_variation = &"WorktreeListRow"
	button.focus_mode = Control.FOCUS_ALL
	button.set_meta(&"label", ref_label)
	button.tooltip_text = RefChip.tooltip(ref_label)
	button.pressed.connect(_choose.bind(button))
	button.gui_input.connect(func(event: InputEvent) -> void:
		var mouse: InputEventMouseButton = event as InputEventMouseButton
		var key: InputEventKey = event as InputEventKey
		if (mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT) \
				or (key != null and key.pressed and key.keycode == KEY_MENU):
			button.accept_event()
			_choose(button))
	var line: HBoxContainer = HBoxContainer.new()
	line.theme_type_variation = &"WorktreeListLine"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(line)
	var ref_chip: RefChip = RefChip.new()
	ref_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ref_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ref_chip.max_width = chip_width
	ref_chip.label = ref_label
	line.add_child(ref_chip)
	var remotes: Array = ref_label.get("remotes", [])
	if not remotes.is_empty():
		var also: Label = Label.new()
		also.theme_type_variation = &"DimLabel"
		also.text = ", ".join(PackedStringArray(remotes))
		line.add_child(also)
	return button


## A button's children don't size it: makes room for the row's line (once
## the row is in the tree, so the theme applies).
func _fit(button: Button) -> void:
	var line: HBoxContainer = button.get_child(0) as HBoxContainer
	var style: StyleBox = button.get_theme_stylebox(&"normal")
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_left = style.get_margin(SIDE_LEFT)
	line.offset_top = style.get_margin(SIDE_TOP)
	line.offset_right = -style.get_margin(SIDE_RIGHT)
	line.offset_bottom = -style.get_margin(SIDE_BOTTOM)
	button.custom_minimum_size = line.get_combined_minimum_size() + style.get_minimum_size()


## The menu opens beside the row, as a submenu would, so it leaves the
## other rows in sight.
func _choose(button: Button) -> void:
	var at: Vector2 = button.get_screen_transform() * Vector2(button.size.x, 0.0)
	menu_requested.emit(RefChip.ref_target(button.get_meta(&"label")), at, self)
