extends Node

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func _ready() -> void:
	var repo: String = ""
	var out: String = ""
	var phase: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
		elif arg.begins_with("--phase="):
			phase = arg.trim_prefix("--phase=")
	if repo.is_empty() or out.is_empty() or phase.is_empty():
		get_tree().quit(2)
		return
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	get_window().size = Vector2i(1100, 760)
	var page: RepoTab = main.open_repo(repo)
	var deadline: int = Time.get_ticks_msec() + 30_000
	var ready: bool = false
	while Time.get_ticks_msec() < deadline:
		ready = page.worktrees().size() >= 7
		for wt: Dictionary in page.worktrees():
			if not bool(wt["prunable"]) and int(wt["changed"]) < 0:
				ready = false
		if ready:
			break
		await get_tree().process_frame
	if not ready:
		printerr("worktree overflow capture: fixture status did not load")
		get_tree().quit(1)
		return
	for choice: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + choice))
		await _settle()
		page.strip()._all_button.pressed.emit()
		await _settle()
		var menu: PopupMenu = page.strip()._all_menu
		var path: String = out.path_join("%s_%s.png" % [phase, choice])
		menu.get_texture().get_image().save_png(path)
		get_viewport().get_texture().get_image().save_png(out.path_join("%s_%s_shell.png" % [phase, choice]))
		print("SHOT ", path)
		for i: int in menu.item_count:
			print("ROW ", menu.get_item_text(i), " TOOLTIP ", menu.get_item_tooltip(i).replace("\n", " | "))
		menu.hide()
	main.close_tab(0)
	get_tree().quit()


func _settle() -> void:
	for i: int in 30:
		await get_tree().process_frame
