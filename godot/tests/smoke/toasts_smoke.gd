extends SmokeTest

var _toasts: Toasts
var _outside: Button
var _root: Control


func run() -> void:
	_root = Control.new()
	_root.size = Vector2(900, 700)
	_root.theme = AppTheme.build(false)
	add_child(_root)
	_outside = Button.new()
	_outside.text = "Outside"
	_root.add_child(_outside)
	_toasts = Toasts.new()
	_toasts.position = Vector2(100, 150)
	_root.add_child(_toasts)
	await get_tree().process_frame
	_outside.grab_focus()
	_mouse(Vector2(10, 80))
	var plain: PanelContainer = _toasts.show_success("Saved")
	var undo: PanelContainer = _toasts.show_success("Discarded", func() -> void: pass)
	expect_eq(_timer(plain).wait_time, 6.0, "ordinary successes get six seconds")
	expect_eq(_timer(undo).wait_time, 12.0, "Undo successes get twelve seconds")
	expect(_outside.has_focus(), "showing a notification never steals keyboard focus")
	plain.queue_free()
	undo.queue_free()
	await get_tree().process_frame
	_root.theme.set_constant(&"seconds", &"Toasts", 1)
	_root.theme.set_constant(&"undo_seconds", &"Toasts", 2)
	await get_tree().process_frame
	plain = _toasts.show_success("Saved")
	undo = _toasts.show_success("Discarded", func() -> void: pass)
	await _wait(1.2)
	expect(not is_instance_valid(plain), "ordinary success expires first")
	expect(is_instance_valid(undo), "Undo survives the ordinary lifetime")
	await _wait(1.0)
	expect(not is_instance_valid(undo), "unattended Undo expires at its own lifetime")

	undo = _toasts.show_success("Discarded", func() -> void: pass)
	await _wait(0.3)
	var button: Button = _undo(undo)
	button.grab_focus()
	await get_tree().process_frame
	var timer: Timer = _timer(undo)
	var remaining: float = timer.time_left
	await _wait(2.2)
	expect(is_instance_valid(undo) and button.has_focus(), "focused Undo survives its deadline")
	expect(absf(timer.time_left - remaining) < 0.1, "keyboard focus preserves remaining time")
	var close: Button = undo.find_children("*", "Button", true, false)[0] as Button
	close.grab_focus()
	await get_tree().process_frame
	expect(timer.paused, "moving focus to Dismiss stays paused")
	_mouse(undo.get_global_rect().get_center())
	await get_tree().process_frame
	close.release_focus()
	await get_tree().process_frame
	expect(timer.paused, "hover still protects a toast after focus leaves")
	button.grab_focus()
	_mouse(Vector2(10, 80))
	await get_tree().process_frame
	expect(timer.paused, "focus still protects a toast after hover leaves")
	button.release_focus()
	await get_tree().process_frame
	expect(not timer.paused, "releasing focus without a replacement resumes time")
	await _wait(0.4)
	expect(timer.time_left < remaining - 0.2, "remaining time resumes instead of resetting")
	await _wait(1.5)
	expect(not is_instance_valid(undo), "resumed remaining time eventually expires")

	plain = _toasts.show_success("Hover")
	await _wait(0.3)
	_mouse(plain.get_global_rect().get_center())
	await get_tree().process_frame
	timer = _timer(plain)
	remaining = timer.time_left
	await _wait(1.2)
	expect(is_instance_valid(plain), "hover protects ordinary successes")
	expect(absf(timer.time_left - remaining) < 0.1, "hover preserves remaining time")
	_mouse(Vector2(10, 80))
	await _wait(0.9)
	expect(not is_instance_valid(plain), "leaving hover resumes only remaining time")

	plain = _toasts.show_success("Unrelated")
	undo = _toasts.show_success("Focused", func() -> void: pass)
	_undo(undo).grab_focus()
	await _wait(1.2)
	expect(not is_instance_valid(plain) and is_instance_valid(undo), "another toast's focus does not stop expiry")
	undo.queue_free()
	await get_tree().process_frame
	var calls: Array[int] = [0]
	undo = _toasts.show_success("Run once", func() -> void: calls[0] += 1)
	await get_tree().process_frame
	_undo(undo).grab_focus()
	press("Enter")
	await get_tree().process_frame
	expect_eq(calls[0], 1, "keyboard activation runs Undo once")
	expect(not is_instance_valid(undo), "activation dismisses its toast")
	plain = _toasts.show_success("Dismiss early")
	(plain.find_children("*", "Button", true, false)[0] as Button).pressed.emit()
	_toasts.show_toast("Error", "Persistent")
	var progress: PanelContainer = _toasts.show_progress("Working")
	await _wait(2.2)
	expect_eq(calls[0], 1, "old timers cannot invoke actions again")
	expect_eq(_toasts.toast_count(), 2, "only error and progress remain")
	_toasts.finish_progress(progress, "Finished")
	await get_tree().process_frame
	await _wait(1.2)
	expect_eq(_toasts.toast_count(), 1, "progress result uses ordinary expiry")
	_root.queue_free()
	await get_tree().process_frame


func _timer(panel: PanelContainer) -> Timer:
	return panel.find_children("*", "Timer", true, false)[0] as Timer


func _undo(panel: PanelContainer) -> Button:
	for node: Node in panel.find_children("*", "Button", true, false):
		var button: Button = node as Button
		if button.text == "Undo":
			return button
	return null


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _mouse(at: Vector2) -> void:
	get_window().size = Vector2i(1280, 800)
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	Input.parse_input_event(motion)
	Input.flush_buffered_events()

