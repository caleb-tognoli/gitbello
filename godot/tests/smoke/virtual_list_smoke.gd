extends SmokeTest
## VirtualList draws only visible rows and handles keyboard and mouse selection.


class CountingList:
	extends VirtualList
	var count: int = 0
	var drawn: Dictionary[int, bool] = {}

	func _get_row_count() -> int:
		return count

	func _draw_row(row: int, _rect: Rect2, _selected_row: bool) -> void:
		drawn[row] = true


func run() -> void:
	var list: CountingList = CountingList.new()
	list.count = 100_000
	add_child(list)
	list.size = Vector2(400, 10 * list.row_height())
	list.refresh()
	await get_tree().process_frame
	await get_tree().process_frame

	expect(not list.drawn.is_empty(), "rows are drawn")
	expect(list.drawn.size() <= list.visible_row_count(),
			"only visible rows are drawn (%d drawn)" % list.drawn.size())

	_key(list, KEY_DOWN)
	expect_eq(list.cursor, 0, "Down from nothing selects the first row")
	_key(list, KEY_DOWN)
	_key(list, KEY_DOWN, true)
	expect_eq(list.cursor, 2, "Shift+Down moves the cursor")
	expect_eq(list.selected_rows(), PackedInt32Array([1, 2]), "Shift+Down extends the selection")

	_key(list, KEY_END)
	expect_eq(list.cursor, list.count - 1, "End goes to the last row")
	expect(list.scroll_offset() > 0.0, "End scrolls to the bottom")
	expect(list.first_visible_row() + list.visible_row_count() > list.count - 1,
			"last row is visible after End")

	_key(list, KEY_HOME)
	expect_eq(list.cursor, 0, "Home goes to the first row")
	expect_eq(list.scroll_offset(), 0.0, "Home scrolls to the top")

	_key(list, KEY_PAGEDOWN)
	expect(list.cursor > 1, "Page Down moves by a page")

	var click_y: float = list.row_height() * 3.5
	_click(list, Vector2(10, click_y), false)
	expect_eq(list.selected_rows(), PackedInt32Array([3]), "click selects one row")
	_click(list, Vector2(10, click_y + list.row_height()), true)
	expect_eq(list.selected_rows(), PackedInt32Array([3, 4]), "Ctrl+click adds a row")

	list.drawn.clear()
	list.set_scroll_offset(50_000 * list.row_height())
	await get_tree().process_frame
	expect(list.drawn.has(50_000), "scrolling far draws the rows there")
	expect(list.drawn.size() <= list.visible_row_count(), "still only visible rows")
	list.queue_free()


func _key(list: VirtualList, keycode: Key, shift: bool = false) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	event.shift_pressed = shift
	list._gui_input(event)


func _click(list: VirtualList, at: Vector2, ctrl: bool) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = at
	event.ctrl_pressed = ctrl
	list._gui_input(event)
