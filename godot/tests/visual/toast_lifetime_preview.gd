extends SmokeTest

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _out: String = ""
var _phase: String = ""
var _started: int = 0


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--phase="):
			_phase = arg.trim_prefix("--phase=")
	await run()
	get_tree().quit(0 if failures.is_empty() else 1)


func run() -> void:
	expect(not _out.is_empty() and not fixtures_dir().is_empty(), "scratch fixtures and output are required")
	if not failures.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_window().size = Vector2i(1280, 800)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(fixtures_dir().path_join("repo-1"))
	expect(await wait_until(func() -> bool: return page.session.is_ready() and page.session.change_count() > 0), "fixture loaded")
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var path: String = fixtures_dir().path_join("repo-1/app.txt")
	var original: String = read_file(path)
	var job: int = page.session.discard_paths(PackedStringArray(["app.txt"]))
	main.feedback().track(page.session, job, "Discarding app.txt", "Discarded changes in app.txt", changes.list(), Callable(), changes.undo_discard)
	expect(await wait_until(func() -> bool: return main.toasts().fix_labels().has("Undo")), "real discard produces an Undo toast through explicit-origin feedback")
	expect(read_file(path) != original, "real discard changed fixture bytes")
	var undo: Button = _undo(main.toasts())
	var undo_panel: PanelContainer = undo.get_parent().get_parent().get_parent() as PanelContainer
	var normal: PanelContainer = main.toasts().show_success("Settings saved")
	changes.list().grab_focus()
	_mouse(Vector2(10, 10))
	_started = Time.get_ticks_msec()
	await _shot("initial", main, undo_panel, normal)
	await _until(7.0)
	await _shot("unfocused_7s", main, undo_panel, normal)
	expect(not is_instance_valid(normal), "plain success has expired by seven seconds")
	expect(is_instance_valid(undo_panel) == (_phase == "after"), "Undo visibility at seven seconds matches phase")
	await _until(13.0)
	await _shot("unfocused_13s", main, undo_panel, normal)
	expect(not is_instance_valid(undo_panel), "unfocused Undo has expired by thirteen seconds")
	var focused: PanelContainer = main.toasts().show_success("Discarded changes in app.txt", changes.undo_discard)
	undo = _undo(main.toasts())
	undo.grab_focus()
	_mouse(Vector2(10, 10))
	_started = Time.get_ticks_msec()
	await _shot("focused_initial", main, focused, null)
	await _until(13.0)
	await _shot("focused_13s", main, focused, null)
	if _phase == "after":
		expect(is_instance_valid(focused) and undo.has_focus(), "focused Undo survives thirteen seconds")
		press("Enter")
		await get_tree().process_frame
	else:
		expect(not is_instance_valid(focused), "baseline removes a focused Undo")
		Actions.run_action(&"changes.undo_discard")
	expect(await wait_until(func() -> bool: return read_file(path) == original), "Undo restores exact original file bytes")
	await _shot("restored", main, null, null)
	Actions.run_action(&"view.theme_light")
	expect(await wait_until(func() -> bool: return not page.session.can_undo_discard()), "the first Undo completes")
	job = page.session.discard_paths(PackedStringArray(["app.txt"]))
	main.feedback().track(page.session, job, "Discarding app.txt", "Discarded changes in app.txt", changes.list(), Callable(), changes.undo_discard)
	expect(await wait_until(func() -> bool: return main.toasts().fix_labels().has("Undo")), "second real discard supplies the light-theme preview")
	var light: PanelContainer = _undo(main.toasts()).get_parent().get_parent().get_parent() as PanelContainer
	_undo(main.toasts()).grab_focus()
	expect(await wait_until(func() -> bool: return not page.session.change_paths(0, page.session.change_count()).has("app.txt")), "the light preview waits for refreshed discard status")
	await _shot("focused_light", main, light, null)
	print("PREVIEW ", _phase, " failures=", failures.size())


func _undo(toasts: Toasts) -> Button:
	for node: Node in toasts.find_children("*", "Button", true, false):
		var button: Button = node as Button
		if button.text == "Undo":
			return button
	return null


func _mouse(at: Vector2) -> void:
	Input.warp_mouse(at)
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_viewport().push_input(motion)


func _until(seconds: float) -> void:
	while Time.get_ticks_msec() - _started < int(seconds * 1000.0):
		await get_tree().process_frame


func _shot(label: String, main: Main, undo: Variant, normal: Variant) -> void:
	main.queue_redraw()
	await get_tree().process_frame
	RenderingServer.force_draw()
	var focus: Control = get_viewport().gui_get_focus_owner()
	print("EVIDENCE phase=%s step=%s elapsed_ms=%d undo_alive=%s normal_alive=%s focus=%s pointer=%s" % [
		_phase, label, Time.get_ticks_msec() - _started, is_instance_valid(undo), is_instance_valid(normal),
		str(focus.get_path()) if focus != null else "none", main.get_global_mouse_position()])
	var output: String = _out.path_join(_phase + "_" + label + ".png")
	expect_eq(get_viewport().get_texture().get_image().save_png(output), OK, "save " + output)
	print("SHOT ", output)
