extends Node

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000


func _ready() -> void:
	var fixtures: String = ""
	var out: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--fixtures="):
			fixtures = arg.trim_prefix("--fixtures=").replace("\\", "/")
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	var config: String = OS.get_environment("GITBELLO_CONFIG").replace("\\", "/")
	if fixtures.is_empty() or out.is_empty() or config.get_base_dir() != fixtures \
			or not FileAccess.file_exists(fixtures.path_join("global.gitconfig")):
		printerr("history_screenshots: use CLI fixtures and a scratch config inside them")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(fixtures.path_join("repo-1"))
	page.show_view(WorktreeView.View.HISTORY)
	if not await _wait(func() -> bool: return page.session.is_ready() and page.history().commit_list().row_count() >= 3):
		return
	page.session.fetch()
	if not await _wait(func() -> bool: return int(page.session.badge().get("behind", 0)) == 1):
		return
	await get_tree().create_timer(1.0).timeout
	var history: HistoryView = page.history()
	for mode: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + mode))
		if history.has_method("set_all_branches"):
			history.call("set_all_branches", false)
			if not await _wait(func() -> bool: return history.commit_list().row_count() == 3):
				return
			Actions.run_action(&"history.go_to_current_commit")
			await _shot(out, "current_" + mode)
			if history.has_method("scope_menu"):
				history.scope_button().pressed.emit()
				for frame: int in 30:
					await get_tree().process_frame
				history.scope_menu().get_texture().get_image().save_png(out.path_join("scope_menu_" + mode + ".png"))
				history.scope_menu().hide()
			history.call("set_all_branches", true)
			if not await _wait(func() -> bool: return history.commit_list().row_count() == 4):
				return
			Actions.run_action(&"history.go_to_current_commit")
			await _shot(out, "all_" + mode)
		else:
			history.commit_list().select_only(0)
			await _shot(out, "before_" + mode)
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("history_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


func _shot(out: String, name: String) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var path: String = out.path_join(name + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path)
