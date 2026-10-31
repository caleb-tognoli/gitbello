extends Node

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func _ready() -> void:
	var out: String = ""
	var repo: String = ""
	var phase: String = "before"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
		elif arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--phase="):
			phase = arg.trim_prefix("--phase=")
	if out.is_empty() or repo.is_empty():
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	var page: RepoTab = main.open_repo(repo)
	if not await _wait(func() -> bool: return page.session.is_ready() and page.session.can_fetch()):
		return
	var missing: String = repo.get_base_dir().path_join("missing remote é.git")
	page.session.set_remote_url("origin", missing)
	if not await _wait(func() -> bool:
		for remote: Dictionary in page.session.remote_list():
			if String(remote["name"]) == "origin" and String(remote["fetch_url"]) == missing:
				return true
		return false):
		return
	page.session.fetch()
	if not await _wait(func() -> bool: return _info(main.toasts()) != null):
		return
	for choice: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + choice))
		await _settle()
		get_viewport().get_texture().get_image().save_png(out.path_join(phase + "_toast_" + choice + ".png"))
		_info(main.toasts()).pressed.emit()
		await _settle()
		var dialog: AcceptDialog = _dialog(main.toasts())
		dialog.get_texture().get_image().save_png(out.path_join(phase + "_details_" + choice + ".png"))
		print("SHOT ", out.path_join(phase + "_details_" + choice + ".png"))
		print("DETAILS ", dialog.dialog_text if phase == "before" else (dialog.find_child("ErrorDetails", true, false) as TextEdit).text)
		dialog.confirmed.emit()
		await _settle()
	if phase == "after":
		var long_details: String = "git fetch origin\n\n"
		for index: int in 300:
			long_details += "%03d  fatal: Cannot read C:/work/space and é/[literal]/%s\n" % [index, "long-path-".repeat(12)]
		main.toasts().show_toast("Long diagnostic", "Preview of scrollable output", long_details)
		for choice: String in ["dark", "light"]:
			Actions.run_action(StringName("view.theme_" + choice))
			_info(main.toasts(), true).pressed.emit()
			await _settle()
			var dialog: AcceptDialog = _dialog(main.toasts())
			dialog.get_texture().get_image().save_png(out.path_join("after_long_" + choice + ".png"))
			var output: TextEdit = dialog.find_child("ErrorDetails", true, false) as TextEdit
			output.scroll_vertical = output.get_v_scroll_bar().max_value
			await _settle()
			dialog.get_texture().get_image().save_png(out.path_join("after_long_bottom_" + choice + ".png"))
			dialog.confirmed.emit()
			await _settle()
		get_window().size = Main.MIN_WINDOW_SIZE
		for scale: float in [1.0, 1.5]:
			get_window().content_scale_factor = scale
			await _settle()
			_info(main.toasts(), true).pressed.emit()
			await _settle()
			var dialog: AcceptDialog = _dialog(main.toasts())
			var output: TextEdit = dialog.find_child("ErrorDetails", true, false) as TextEdit
			output.select(0, 0, 0, 3)
			await _settle()
			dialog.get_texture().get_image().save_png(out.path_join("after_minimum_scale_%s.png" % str(scale)))
			print("BOUNDS app=%s viewport=%s scale=%s dialog=%s output=%s OK_bottom=%s" % [get_window().size,
				get_viewport().get_visible_rect().size, scale, dialog.size, output.size, dialog.get_ok_button().get_global_rect().end.y])
			dialog.confirmed.emit()
			await _settle()
	get_tree().quit(0)


func _info(toasts: Toasts, last: bool = false) -> Button:
	var result: Button = null
	for node: Node in toasts.find_children("*", "Button", true, false):
		var button: Button = node as Button
		if button.tooltip_text == "Show error details":
			result = button
			if not last:
				return result
	return result


func _dialog(toasts: Toasts) -> AcceptDialog:
	for child: Node in toasts.get_children():
		if child is AcceptDialog:
			return child as AcceptDialog
	return null


func _settle() -> void:
	for index: int in 20:
		await get_tree().process_frame


func _wait(condition: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + 30_000
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await get_tree().process_frame
	printerr("ERROR: preview timed out")
	get_tree().quit(1)
	return false
