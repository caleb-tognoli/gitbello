extends SmokeTest
## Middle-click autoscroll (`AutoScroll`): sticky and hold modes, the dead
## zone, what stops it, unscrollable targets, a ScrollContainer sideways, a
## worktree chip keeping its own middle click, and trees, item lists and
## text edits.


class RowList:
	extends VirtualList
	var count: int = 0

	func _get_row_count() -> int:
		return count


var _mouse_entered: bool = false
var _mouse: Vector2 = Vector2.ZERO


func run() -> void:
	ThemeManager.apply(self)
	var list: RowList = RowList.new()
	list.count = 1000
	add_child(list)
	list.position = Vector2(0, 0)
	list.size = Vector2(400, 240)
	list.refresh()
	await get_tree().process_frame
	await get_tree().process_frame
	var auto: AutoScroll = AutoScroll.of(get_viewport())
	expect(auto != null, "a VirtualList adds the window's AutoScroll")
	if auto == null:
		return
	expect_eq(AutoScroll.scroll_axes(list), Vector2i(0, 1), "a long list scrolls vertically only")

	_test_speed(auto)
	await _test_sticky(auto, list)
	await _test_hold(auto, list)
	await _test_stops(auto, list)
	_test_unscrollable(auto, list)
	await _test_scroll_container(auto, list)
	await _test_bar_controls(auto, list)
	list.queue_free()


func _test_speed(auto: AutoScroll) -> void:
	expect_eq(auto.speed(5.0), 0.0, "no speed inside the dead zone")
	expect(auto.speed(100.0) > auto.speed(50.0) and auto.speed(50.0) > 0.0, "speed grows with the distance")
	expect(auto.speed(-100.0) < 0.0, "speed has the offset's direction")
	expect(auto.speed(100_000.0) == auto.speed(200_000.0), "speed is capped")


func _test_sticky(auto: AutoScroll, list: RowList) -> void:
	_move(Vector2(200, 100))
	_button(MOUSE_BUTTON_MIDDLE, true)
	_button(MOUSE_BUTTON_MIDDLE, false)
	expect(auto.is_active() and auto.is_sticky(), "a quick middle click keeps scrolling")
	expect(auto.target() == list, "it scrolls the list under the mouse")

	_move(Vector2(200, 104))
	for i: int in 5:
		await get_tree().process_frame
	expect_eq(list.scroll_offset(), 0.0, "the dead zone holds still")

	_move(Vector2(200, 220))
	expect(await wait_until(func() -> bool: return list.scroll_offset() > 0.0, 3000),
			"moving below the click scrolls down")
	expect(auto.is_active(), "it keeps scrolling after the release")

	_button(MOUSE_BUTTON_LEFT, true)
	expect(not auto.is_active(), "a click stops it")
	_button(MOUSE_BUTTON_LEFT, false)
	expect_eq(list.cursor, -1, "the stopping click is swallowed")


func _test_hold(auto: AutoScroll, list: RowList) -> void:
	_move(Vector2(200, 200))
	_button(MOUSE_BUTTON_MIDDLE, true)
	expect(auto.is_active() and not auto.is_sticky(), "holding the middle button scrolls")
	var before: float = list.scroll_offset()
	_move(Vector2(200, 60))
	expect(await wait_until(func() -> bool: return list.scroll_offset() < before, 3000),
			"moving above the click scrolls up")
	_button(MOUSE_BUTTON_MIDDLE, false)
	expect(not auto.is_active(), "releasing after a drag stops it")


func _test_stops(auto: AutoScroll, list: RowList) -> void:
	await _start_sticky(auto, Vector2(200, 100))
	var before: float = list.scroll_offset()
	_button(MOUSE_BUTTON_WHEEL_DOWN, true)
	expect(not auto.is_active(), "a wheel turn stops it")
	expect(list.scroll_offset() > before, "the wheel turn still scrolls")
	_button(MOUSE_BUTTON_WHEEL_DOWN, false)

	await _start_sticky(auto, Vector2(200, 100))
	press("Escape")
	expect(not auto.is_active(), "Esc stops it")

	list.grab_focus()
	await _start_sticky(auto, Vector2(200, 100))
	press("Down")
	expect(not auto.is_active(), "another key stops it")
	expect_eq(list.cursor, 0, "the key still reaches the list")

	await _start_sticky(auto, Vector2(200, 100))
	list.hide()
	await get_tree().process_frame
	await get_tree().process_frame
	expect(not auto.is_active(), "hiding the target stops it")
	list.show()


func _test_unscrollable(auto: AutoScroll, list: RowList) -> void:
	list.count = 3
	list.refresh()
	expect_eq(AutoScroll.scroll_axes(list), Vector2i.ZERO, "a short list cannot scroll")
	_move(Vector2(200, 30))
	_button(MOUSE_BUTTON_MIDDLE, true)
	expect(not auto.is_active(), "a middle click on a list that fits does nothing")
	_button(MOUSE_BUTTON_MIDDLE, false)
	list.count = 1000
	list.refresh()


func _test_scroll_container(auto: AutoScroll, list: RowList) -> void:
	list.hide()
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	AutoScroll.enable(scroll)
	add_child(scroll)
	scroll.position = Vector2(0, 300)
	scroll.size = Vector2(300, 40)
	var row: HBoxContainer = HBoxContainer.new()
	scroll.add_child(row)
	var spacer: Control = Control.new()
	spacer.custom_minimum_size = Vector2(1200, 40)
	row.add_child(spacer)
	var chip: WorktreeChip = WorktreeChip.new()
	chip.set_worktree({"path": "C:/test/repo-login", "name": "repo-login", "short_name": "login",
		"branch": "main", "head": "abcdef1234", "detached": false, "prunable": false, "locked": false,
		"lock_reason": "", "changed": 0, "ahead": 0, "behind": 0, "conflicts": 0, "operation": ""})
	row.add_child(chip)
	await get_tree().process_frame
	await get_tree().process_frame
	expect_eq(AutoScroll.scroll_axes(scroll), Vector2i(1, 0), "a wide strip scrolls sideways only")

	_move(Vector2(50, 320))
	_button(MOUSE_BUTTON_MIDDLE, true)
	_button(MOUSE_BUTTON_MIDDLE, false)
	expect(auto.is_active() and auto.target() == scroll, "a middle click on the strip autoscrolls it")
	_move(Vector2(200, 320))
	expect(await wait_until(func() -> bool: return scroll.scroll_horizontal > 0, 3000),
			"moving right scrolls right")
	auto.stop()

	scroll.scroll_horizontal = 10_000
	await get_tree().process_frame
	var revealed: Array[bool] = [false]
	chip.reveal_requested.connect(func() -> void: revealed[0] = true)
	var at: Vector2 = chip.get_global_rect().get_center()
	expect(scroll.get_global_rect().has_point(at), "the chip is in view")
	_move(at)
	_button(MOUSE_BUTTON_MIDDLE, true)
	_button(MOUSE_BUTTON_MIDDLE, false)
	expect(not auto.is_active(), "a chip keeps its middle click")
	expect(revealed[0], "a chip's middle click shows its folder")
	scroll.queue_free()
	list.show()


## A Tree, an ItemList and a TextEdit scroll through their bars; a text edit
## that pastes the primary selection keeps its middle click.
func _test_bar_controls(auto: AutoScroll, list: RowList) -> void:
	list.hide()
	var tree: Tree = Tree.new()
	var root: TreeItem = tree.create_item()
	tree.hide_root = true
	for i: int in 200:
		tree.create_item(root).set_text(0, "Item %d" % i)
	var items: ItemList = ItemList.new()
	for i: int in 200:
		items.add_item("Item %d" % i)
	var text: TextEdit = TextEdit.new()
	var lines: PackedStringArray = PackedStringArray()
	for i: int in 300:
		lines.append("Line %d" % i)
	text.text = "
".join(lines)
	text.middle_mouse_paste_enabled = false
	var bars: Callable = func(control: Control) -> float:
		if control is TextEdit:
			return (control as TextEdit).scroll_vertical
		if control is ItemList:
			return (control as ItemList).get_v_scroll_bar().value
		for child: Node in control.get_children(true):
			if child is VScrollBar:
				return (child as VScrollBar).value
		return -1.0
	for control: Control in [tree, items, text]:
		AutoScroll.enable(control)
		add_child(control)
		control.position = Vector2(0, 0)
		control.size = Vector2(300, 200)
	for control: Control in [tree, items, text]:
		for other: Control in [tree, items, text]:
			other.visible = other == control
		await get_tree().process_frame
		await get_tree().process_frame
		var kind: String = control.get_class()
		expect_eq(AutoScroll.scroll_axes(control).y, 1, "a long %s scrolls vertically" % kind)
		_move(Vector2(150, 50))
		_button(MOUSE_BUTTON_MIDDLE, true)
		_button(MOUSE_BUTTON_MIDDLE, false)
		expect(auto.is_active() and auto.target() == control, "a middle click autoscrolls a %s" % kind)
		_move(Vector2(150, 150))
		expect(await wait_until(func() -> bool: return float(bars.call(control)) > 0.0, 3000),
				"moving down scrolls the %s" % kind)
		auto.stop()
	text.middle_mouse_paste_enabled = true
	_move(Vector2(150, 50))
	_button(MOUSE_BUTTON_MIDDLE, true)
	_button(MOUSE_BUTTON_MIDDLE, false)
	expect_eq(auto.is_active(), not DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD_PRIMARY),
			"a text edit keeps its middle-click paste only where there is a primary selection")
	auto.stop()
	for control: Control in [tree, items, text]:
		control.queue_free()
	list.show()


func _start_sticky(auto: AutoScroll, at: Vector2) -> void:
	_move(at)
	_button(MOUSE_BUTTON_MIDDLE, true)
	_button(MOUSE_BUTTON_MIDDLE, false)
	await get_tree().process_frame
	expect(auto.is_sticky(), "sticky autoscroll starts at %s" % at)


func _move(at: Vector2) -> void:
	if not _mouse_entered:
		get_viewport().notify_mouse_entered()
		_mouse_entered = true
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	motion.relative = at - _mouse
	_mouse = at
	get_viewport().push_input(motion, true)


func _button(index: MouseButton, pressed: bool) -> void:
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = index
	click.pressed = pressed
	click.position = _mouse
	click.global_position = _mouse
	if index == MOUSE_BUTTON_MIDDLE and pressed:
		click.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	get_viewport().push_input(click, true)
