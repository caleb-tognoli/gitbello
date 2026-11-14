extends SmokeTest


func run() -> void:
	# Toast lifetimes are timers: run game time faster (the runner resets it).
	Engine.time_scale = 4.0
	var host: Control = Control.new()
	host.size = Vector2(960, 600)
	host.theme = AppTheme.build(false)
	add_child(host)
	var toasts: Toasts = Toasts.new()
	host.add_child(toasts)
	toasts.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	toasts.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	toasts.grow_vertical = Control.GROW_DIRECTION_BEGIN
	host.theme.set_constant(&"seconds", &"Toasts", 1)
	host.theme.set_constant(&"undo_seconds", &"Toasts", 1)
	var calls: Array[int] = [0]
	for i: int in 8:
		toasts.show_toast("Error %d" % i, "Local changes would be overwritten. Commit or shelve the changes before switching.", "git checkout\nstderr", [{"label": "Fix %d" % i, "run": func() -> void: calls[0] += 1}])
	var undo: PanelContainer = toasts.show_success("Discarded changes", func() -> void: calls[0] += 1)
	var progress: PanelContainer = toasts.show_progress("Fetching…", func() -> void: calls[0] += 1)
	await _settle()
	var scroll: ScrollContainer = toasts.get_node("Scroll") as ScrollContainer
	var stack: VBoxContainer = scroll.get_node("Stack") as VBoxContainer
	var overflow: Label = toasts.get_node("Overflow") as Label
	expect(toasts.size.y <= host.size.y / 3.0 + 1.0, "burst stays inside one-third of available height: %s" % toasts.size)
	expect(host.get_global_rect().encloses(toasts.get_global_rect()), "bounded stack remains inside the shell")
	expect(toasts.get_rect().end.x > host.size.x - 40.0 and toasts.position.x > host.size.x / 2.0,
			"the stack sits at the bottom right: %s" % toasts.get_rect())
	expect_eq(toasts.toast_count(), 10, "capacity retains every notification")
	expect(overflow.visible and overflow.text.contains("10"), "overflow visibly reports retained count")
	expect(stack.size.y > scroll.size.y, "overflow is scrollable rather than expanding the shell")
	var before: int = scroll.scroll_vertical
	toasts.show_toast("New arrival", "A later error")
	await _settle()
	expect_eq(scroll.scroll_vertical, before, "arrivals preserve the reading position")
	await get_tree().create_timer(1.2).timeout
	expect(is_instance_valid(undo) and not undo.is_queued_for_deletion(), "capacity-hidden Undo does not expire")
	expect((undo.find_children("*", "Timer", true, false)[0] as Timer).paused,
			"capacity protection pauses the remaining Undo lifetime")
	toasts.update_progress(progress, "Fetching objects", 65)
	expect_eq((progress.find_child("Progress", true, false) as ProgressBar).value, 65.0, "offscreen progress keeps updating")
	toasts.finish_progress(progress)
	await _settle()
	expect(not toasts.toast_texts().has("Fetching objects"), "offscreen progress can finish")
	var undo_button: Button = (undo.find_child("Actions", true, false) as Node).get_child(0) as Button
	undo_button.grab_focus()
	await _settle()
	expect(scroll.get_global_rect().intersects(undo_button.get_global_rect()), "keyboard navigation reveals an overflow action")
	expect(toasts.press_fix("Undo"), "retained Undo remains actionable")
	await _settle()
	expect_eq(calls[0], 1, "Undo executes once")
	scroll.scroll_vertical = 0
	await _settle()
	expect(toasts.press_fix("Fix 0"), "the oldest fix remains available")
	await _settle()
	expect_eq(calls[0], 2, "retained fix executes once")
	for panel: Node in stack.get_children():
		panel.queue_free()
	await _settle()
	expect_eq(toasts.toast_count(), 0, "dismissal empties retained stack")
	expect(not overflow.visible and toasts.size.y < 1.0, "empty stack leaves no overlay footprint")
	var completed: PanelContainer = toasts.show_progress("Working")
	toasts.show_toast("Later error", "Keep the original order")
	toasts.finish_progress(completed, "Done")
	await _settle()
	expect_eq(toasts.toast_texts(), PackedStringArray(["Done", "Later error"]), "progress result preserves its position")
	await get_tree().create_timer(1.2).timeout
	expect_eq(toasts.toast_texts(), PackedStringArray(["Later error"]), "ordinary success still expires but errors remain")
	var exposed: PanelContainer = toasts.show_success("Visible Undo", func() -> void: pass)
	await _settle()
	expect(not (exposed.find_children("*", "Timer", true, false)[0] as Timer).paused,
			"a fully exposed unattended Undo is not capacity-paused")
	await get_tree().create_timer(1.2).timeout
	expect(not is_instance_valid(exposed), "an exposed Undo resumes normal expiration")
	for panel: Node in stack.get_children():
		panel.queue_free()
	await _settle()
	toasts.show_toast("A long error", "A wrapped line of error context. ".repeat(150))
	await _settle()
	expect(toasts.size.y <= host.size.y / 3.0 + 1.0, "one tall error is bounded too")
	host.size = Vector2(320, 360)
	await _settle()
	expect(toasts.size.x <= host.size.x, "stack fits narrow available width")
	expect(toasts.size.y <= host.size.y / 3.0 + 1.0, "stack follows host resize")
	host.queue_free()
	await get_tree().process_frame
	var main: Main = preload("res://app/main/main.tscn").instantiate() as Main
	add_child(main)
	for light: bool in [true, false]:
		Actions.run_action(&"view.theme_light" if light else &"view.theme_dark")
		for i: int in 8:
			main.toasts().show_toast("Error %d" % i, "An error that will be dismissed before changing theme")
		await _settle()
		for panel: Node in main.toasts().get_node("Scroll/Stack").get_children():
			panel.queue_free()
		await _settle()
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _settle() -> void:
	for frame: int in 12:
		await get_tree().process_frame
