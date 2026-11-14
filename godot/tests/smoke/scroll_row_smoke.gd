extends SmokeTest
## `ScrollRow`: no arrows while the controls fit; past that ‹ and › lie over
## the ends (taking no room, so nothing moves when one shows) only while
## there is more that way; a click scrolls the next control cut off or under
## an arrow fully into view, never by just a pixel; focus reveals a control
## clear of the arrows; the wheel scrolls sideways.


func run() -> void:
	ThemeManager.apply(self)
	var row: ScrollRow = ScrollRow.new()
	add_child(row)
	row.position = Vector2.ZERO
	for i: int in 8:
		var chip: Button = Button.new()
		chip.text = "chip-%d" % i
		chip.custom_minimum_size.x = 100.0
		row.content().add_child(chip)
	row.size = Vector2(1000.0, 32.0)
	await _settle()
	expect(not row.overflows(), "eight 100 px chips fit in 1000 px")
	expect(not row.left_arrow().visible and not row.right_arrow().visible, "no arrows while they fit")

	row.size = Vector2(420.0, 32.0)
	await _settle()
	var scroll: ScrollContainer = row.scroll_container()
	expect(row.overflows(), "they overflow 420 px")
	expect(not row.left_arrow().visible, "at the start, no ‹")
	expect(row.right_arrow().visible, "and a ›")
	expect(absf(row.right_arrow().get_global_rect().end.x - 420.0) < 0.5, "› lies over the row's right end")
	expect_eq(scroll.size.x, 420.0, "the arrows take no room")
	var first: Control = row.content().get_child(0) as Control
	expect_eq(first.get_global_rect().position.x, 0.0, "the first chip starts at the row's edge")

	row.step(1, false)
	await _settle()
	expect(scroll.scroll_horizontal > 0, "› scrolls right")
	expect(row.left_arrow().visible and row.right_arrow().visible, "both arrows once scrolled")
	expect_eq(scroll.size.x, 420.0, "still taking no room")
	expect(_shown(row, row.content().get_child(3) as Control), "the chip cut off on the right shows clear of the arrows")
	for i: int in 10:
		row.step(1, false)
	await _settle()
	expect(not row.can_scroll(1) and not row.right_arrow().visible, "› hides at the end")
	expect(_shown(row, row.content().get_child(7) as Control), "the last chip is shown")
	row.step(-1, false)
	await _settle()
	expect(row.can_scroll(1), "‹ scrolls back")
	for i: int in 10:
		row.step(-1, false)
	await _settle()
	expect_eq(scroll.scroll_horizontal, 0, "back at the start")

	# Animated: a quick double click aims past the first target.
	row.step(1)
	var aimed: int = row._target
	row.step(1)
	expect(row._target > aimed, "a second click while scrolling goes on from where the first ends")
	await get_tree().create_timer(ScrollRow.SCROLL_TIME + 0.1).timeout
	expect_eq(scroll.scroll_horizontal, row._target, "the animation ends at its target")

	# A chip cut off by a pixel is passed over for the next one.
	row.scroll_to(0, false)
	await _settle()
	var third: Control = row.content().get_child(2) as Control
	var cut: float = third.position.x + third.size.x - (scroll.size.x - row.cover_width()) - 1.0
	row.scroll_to(roundi(cut), false)
	await _settle()
	var before: int = scroll.scroll_horizontal
	row.step(1, false)
	await _settle()
	expect(scroll.scroll_horizontal - before >= ScrollRow.MIN_STEP, "› never scrolls by just a pixel")

	# Focus: a chip under › comes out clear of it.
	row.scroll_to(0, false)
	await _settle()
	var hidden: Button = row.content().get_child(5) as Button
	hidden.grab_focus()
	await _settle()
	expect(_shown(row, hidden), "a focused chip is revealed clear of the arrows")
	hidden.release_focus()

	row.scroll_to(0, false)
	await _settle()
	var wheel: InputEventMouseButton = InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	wheel.factor = 1.0
	wheel.position = scroll.get_global_rect().get_center()
	wheel.global_position = wheel.position
	get_viewport().push_input(wheel)
	await _settle()
	expect(scroll.scroll_horizontal > 0, "the wheel scrolls sideways")

	row.size = Vector2(1000.0, 32.0)
	await _settle()
	expect(not row.overflows() and not row.left_arrow().visible and not row.right_arrow().visible,
			"widening hides the arrows")
	row.queue_free()
	await get_tree().process_frame


func _settle() -> void:
	for frame: int in 4:
		await get_tree().process_frame


## Whether `control` shows whole, not under an arrow.
static func _shown(row: ScrollRow, control: Control) -> bool:
	var span: Vector2 = row._visible_span(float(row.scroll_container().scroll_horizontal))
	return control.position.x >= span.x - 1.0 and control.position.x + control.size.x <= span.y + 1.0
