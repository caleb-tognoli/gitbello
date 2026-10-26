class_name VirtualList
extends Control
## Draws only the visible rows of a list of any length (PLAN §3.7).
##
## Subclasses override `_get_row_count()`, `_draw_row()` and optionally
## `_prepare_rows()`, then call `refresh()` when the row count changes.
## Handles scrolling, keyboard navigation, multi-select (Ctrl/Shift) and
## context-menu requests.

signal selection_changed()
signal row_activated(row: int)
signal context_menu_requested(row: int, at_position: Vector2)

const THEME_TYPE: StringName = &"VirtualList"
const WHEEL_ROWS: float = 3.0

## Row with keyboard focus, or -1.
var cursor: int = -1
## Draw the selected rows' background and the cursor's outline (off for a
## subclass that shows its own selection).
var draws_selection: bool = true

var _row_count: int = 0
var _selected: Dictionary[int, bool] = {}
var _anchor: int = -1
var _scroll_bar: VScrollBar = VScrollBar.new()


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	clip_contents = true


func _ready() -> void:
	add_child(_scroll_bar, false, Node.INTERNAL_MODE_FRONT)
	_scroll_bar.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	_scroll_bar.value_changed.connect(_on_scroll_changed)
	resized.connect(_update_scroll_range)
	refresh()


## Number of rows. Override.
func _get_row_count() -> int:
	return 0


## Called once per redraw before rows `first..first + count` are drawn. Override
## to fetch data for the visible range in one batch.
func _prepare_rows(_first: int, _count: int) -> void:
	pass


## Draws one row inside `rect`. Override.
func _draw_row(_row: int, _rect: Rect2, _selected_row: bool) -> void:
	pass


## Re-reads the row count and redraws.
func refresh() -> void:
	_row_count = maxi(0, _get_row_count())
	if cursor >= _row_count:
		cursor = _row_count - 1
	_update_scroll_range()
	queue_redraw()


func row_count() -> int:
	return _row_count


func row_height() -> float:
	return float(maxi(1, get_theme_constant(&"row_height", THEME_TYPE)))


func scroll_offset() -> float:
	return _scroll_bar.value


func set_scroll_offset(offset: float) -> void:
	_scroll_bar.value = clampf(offset, 0.0, maxf(0.0, _scroll_bar.max_value - _scroll_bar.page))


func first_visible_row() -> int:
	return int(scroll_offset() / row_height())


func visible_row_count() -> int:
	return int(ceil(size.y / row_height())) + 1


## Width available to rows (excludes the scroll bar when it is shown).
func content_width() -> float:
	return size.x - (_scroll_bar.size.x if _scroll_bar.visible else 0.0)


func row_at(at_position: Vector2) -> int:
	var row: int = int((at_position.y + scroll_offset()) / row_height())
	return row if at_position.y >= 0.0 and row < _row_count else -1


func scroll_to_row(row: int) -> void:
	var top: float = row * row_height()
	if top < scroll_offset():
		set_scroll_offset(top)
	elif top + row_height() > scroll_offset() + size.y:
		set_scroll_offset(top + row_height() - size.y)


func is_selected(row: int) -> bool:
	return _selected.has(row)


func selected_rows() -> PackedInt32Array:
	var rows: PackedInt32Array = PackedInt32Array(_selected.keys())
	rows.sort()
	return rows


func select_only(row: int) -> void:
	_selected.clear()
	if row >= 0 and row < _row_count:
		_selected[row] = true
	_anchor = row
	cursor = row
	queue_redraw()
	selection_changed.emit()


func clear_selection() -> void:
	_selected.clear()
	queue_redraw()
	selection_changed.emit()


func _draw() -> void:
	if _row_count == 0:
		return
	var height: float = row_height()
	var first: int = first_visible_row()
	var count: int = mini(visible_row_count(), _row_count - first)
	_prepare_rows(first, count)
	var width: float = content_width()
	var y: float = first * height - scroll_offset()
	var selection_color: Color = get_theme_color(&"selection_color", THEME_TYPE)
	var cursor_color: Color = get_theme_color(&"cursor_color", THEME_TYPE)
	for row: int in range(first, first + count):
		var rect: Rect2 = Rect2(0.0, y, width, height)
		var selected: bool = draws_selection and _selected.has(row)
		if selected:
			draw_rect(rect, selection_color)
		_draw_row(row, rect, selected)
		if draws_selection and row == cursor and has_focus():
			draw_rect(rect.grow(-0.5), cursor_color, false, 1.0)
		y += height


func _gui_input(event: InputEvent) -> void:
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if mouse != null and mouse.pressed:
		_handle_mouse(mouse)
		return
	if event is InputEventKey and event.is_pressed():
		_handle_key(event as InputEventKey)


func _handle_mouse(mouse: InputEventMouseButton) -> void:
	match mouse.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			var direction: float = -1.0 if mouse.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
			var factor: float = mouse.factor if mouse.factor > 0.0 else 1.0
			set_scroll_offset(scroll_offset() + direction * factor * WHEEL_ROWS * row_height())
			accept_event()
		MOUSE_BUTTON_LEFT:
			var row: int = row_at(mouse.position)
			grab_focus()
			if row < 0:
				return
			if mouse.double_click:
				row_activated.emit(row)
			elif mouse.shift_pressed and _anchor >= 0:
				_select_range(_anchor, row, mouse.is_command_or_control_pressed())
				cursor = row
			elif mouse.is_command_or_control_pressed():
				_toggle(row)
			else:
				select_only(row)
			accept_event()
		MOUSE_BUTTON_RIGHT:
			var row: int = row_at(mouse.position)
			grab_focus()
			if row < 0:
				return
			if not is_selected(row):
				select_only(row)
			context_menu_requested.emit(row, mouse.position)
			accept_event()


func _handle_key(key: InputEventKey) -> void:
	var page: int = maxi(1, int(size.y / row_height()) - 1)
	var target: int = -2
	if key.is_action("ui_up"):
		target = cursor - 1
	elif key.is_action("ui_down"):
		target = cursor + 1
	elif key.is_action("ui_page_up"):
		target = cursor - page
	elif key.is_action("ui_page_down"):
		target = cursor + page
	elif key.is_action("ui_home"):
		target = 0
	elif key.is_action("ui_end"):
		target = _row_count - 1
	elif key.is_action("ui_accept", true) and cursor >= 0:
		row_activated.emit(cursor)
		accept_event()
		return
	elif key.keycode == KEY_A and key.is_command_or_control_pressed():
		_select_range(0, _row_count - 1, false)
		accept_event()
		return
	if target == -2 or _row_count == 0:
		return
	_move_cursor(clampi(target, 0, _row_count - 1), key.shift_pressed)
	accept_event()


func _move_cursor(row: int, extend: bool) -> void:
	if extend and _anchor >= 0:
		_select_range(_anchor, row, false)
		cursor = row
	else:
		select_only(row)
	scroll_to_row(row)


func _select_range(from: int, to: int, keep: bool) -> void:
	if not keep:
		_selected.clear()
	for row: int in range(mini(from, to), maxi(from, to) + 1):
		_selected[row] = true
	queue_redraw()
	selection_changed.emit()


func _toggle(row: int) -> void:
	if _selected.has(row):
		_selected.erase(row)
	else:
		_selected[row] = true
	_anchor = row
	cursor = row
	queue_redraw()
	selection_changed.emit()


func _update_scroll_range() -> void:
	var content: float = _row_count * row_height()
	_scroll_bar.max_value = content
	_scroll_bar.page = size.y
	_scroll_bar.visible = content > size.y
	set_scroll_offset(scroll_offset())


func _on_scroll_changed(_value: float) -> void:
	queue_redraw()
