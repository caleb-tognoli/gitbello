extends SmokeTest
## Scrolling closes tooltips (`TooltipCard.dismiss`): a list under the mouse
## scrolled by the wheel, by code or by middle-click autoscroll, and a chip
## row scrolled sideways, each send the viewport the gesture that makes
## Godot drop its tooltip (and the one waiting to show), once a frame however
## much they scroll; the gesture reaches no control. A list scrolling away
## from the mouse sends none. Headless Godot shows no tooltips, so the
## windowed `scrolling_screenshots` shows them closing.


class TipList:
	extends VirtualList

	func _get_row_count() -> int:
		return 1000

	func _get_tooltip(at_position: Vector2) -> String:
		var row: int = row_at(at_position)
		return "Row %d" % row if row >= 0 else ""


## Counts the dismissing gestures the viewport receives.
class Spy:
	extends Node
	var count: int = 0

	func _input(event: InputEvent) -> void:
		var gesture: InputEventPanGesture = event as InputEventPanGesture
		if gesture != null and gesture.position == TooltipCard.DISMISS_AT:
			count += 1


var _mouse: Vector2 = Vector2.ZERO
var _mouse_entered: bool = false
var _gestures_in_list: int = 0


func run() -> void:
	ThemeManager.apply(self)
	var spy: Spy = Spy.new()
	add_child(spy)
	var list: TipList = TipList.new()
	add_child(list)
	list.position = Vector2.ZERO
	list.size = Vector2(400, 300)
	list.refresh()
	list.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventPanGesture:
			_gestures_in_list += 1)
	await _frames(2)
	spy.count = 0

	TooltipCard.dismiss(get_viewport())
	TooltipCard.dismiss(get_viewport())
	expect_eq(spy.count, 0, "the dismissal waits for the end of the input event")
	await _frames(2)
	expect_eq(spy.count, 1, "two dismissals in a frame send one gesture")
	expect(not get_viewport().has_meta(TooltipCard.DISMISS_META), "nothing is left pending")
	TooltipCard.dismiss(null)

	await _hover_at(Vector2(100, 50))
	_button(MOUSE_BUTTON_WHEEL_DOWN, true)
	_button(MOUSE_BUTTON_WHEEL_DOWN, false)
	expect(list.scroll_offset() > 0.0, "the wheel scrolls the list")
	await _frames(2)
	expect_eq(spy.count, 2, "a wheel turn closes the tooltip")

	list.set_scroll_offset(500.0)
	list.set_scroll_offset(900.0)
	await _frames(2)
	expect_eq(spy.count, 3, "scrolling twice in a frame closes it once")

	list.set_scroll_offset(900.0)
	await _frames(2)
	expect_eq(spy.count, 3, "no scroll, no dismissal")

	await _hover_at(Vector2(600, 500))
	list.set_scroll_offset(1200.0)
	await _frames(2)
	expect_eq(spy.count, 3, "a list scrolling away from the mouse leaves tooltips alone")
	await _hover_at(Vector2(100, 50))

	# Middle-click autoscroll: closes it as it starts and while it scrolls.
	var auto: AutoScroll = AutoScroll.of(get_viewport())
	expect(auto != null, "the window has its AutoScroll")
	if auto != null:
		await _hover_at(Vector2(200, 100))
		_button(MOUSE_BUTTON_MIDDLE, true)
		_button(MOUSE_BUTTON_MIDDLE, false)
		expect(auto.is_sticky(), "autoscroll starts")
		await _frames(2)
		expect_eq(spy.count, 4, "starting autoscroll closes the tooltip")
		_move(Vector2(200, 260))
		var before: int = spy.count
		expect(await wait_until(func() -> bool: return spy.count > before + 2, 3000),
				"autoscrolling keeps tooltips closed")
		auto.stop()
	list.queue_free()

	# A chip row scrolled sideways.
	var row: ScrollRow = ScrollRow.new()
	add_child(row)
	row.position = Vector2.ZERO
	row.size = Vector2(200, 30)
	for i: int in 20:
		var chip: Button = Button.new()
		chip.text = "Chip %d" % i
		chip.tooltip_text = "Chip %d" % i
		row.content().add_child(chip)
	await _frames(3)
	expect(row.overflows(), "the chips overflow the row")
	await _hover_at(Vector2(100, 15))
	var count: int = spy.count
	row.scroll_to(120, false)
	await _frames(2)
	expect_eq(spy.count, count + 1, "scrolling the chip row closes the tooltip")
	row.queue_free()

	expect_eq(_gestures_in_list, 0, "the gesture reaches no control")
	spy.queue_free()


func _frames(count: int) -> void:
	for i: int in count:
		await get_tree().process_frame


## Moves the mouse to `at` and waits for the viewport to see what is there.
func _hover_at(at: Vector2) -> void:
	_move(at)
	await _frames(2)


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
