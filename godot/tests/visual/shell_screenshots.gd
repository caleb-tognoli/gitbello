extends Node
## Saves screenshots of the shell for visual review (not part of the smoke run).
## Usage: godot --path godot res://tests/visual/shell_screenshots.tscn --
##        --repos=<path>;<path>;... --out=<dir>
## Run with GITBELLO_CONFIG pointing at a scratch config file.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000


func _ready() -> void:
	var repos: PackedStringArray = PackedStringArray()
	var out: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repos="):
			repos = arg.trim_prefix("--repos=").split(";", false)
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	if repos.is_empty() or out.is_empty():
		printerr("shell_screenshots: pass -- --repos=a;b --out=<dir>")
		get_tree().quit(2)
		return
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	for repo: String in repos:
		main.open_repo(repo)
	main.tab_bar().current_tab = 0
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		var list: CommitList = main.page_at(0).history().commit_list()
		if list.row_count() > 0 and not main.page_at(0).session.badge().get("head", "").is_empty():
			break
		await get_tree().process_frame
	await _settle()

	Actions.run_action(&"view.theme_dark")
	await _shot(out, "dark")
	Actions.run_action(&"view.theme_light")
	await _shot(out, "light")
	Actions.run_action(&"view.theme_dark")
	main.palette().open()
	main.palette().set_query("tab")
	await _shot(out, "palette")
	main.palette().close()
	Actions.run_action(&"view.toggle_git_log")
	await _shot(out, "git_log")
	Actions.run_action(&"view.toggle_git_log")

	var page: RepoTab = main.page_at(0)
	page.show_view(RepoTab.View.CHANGES)
	deadline = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and page.changes().diff_view().row_count() == 0:
		await get_tree().process_frame
	await _shot(out, "changes_dark")
	Actions.run_action(&"view.theme_light")
	await _shot(out, "changes_light")
	Actions.run_action(&"view.theme_dark")
	page.changes().untracked_list().grab_focus()
	page.changes().untracked_list().select_only(0)
	await _shot(out, "changes_untracked")
	Actions.run_action(&"changes.focus_message")
	page.changes().commit_box().set_message("Add a summary", "And a longer description.")
	await _shot(out, "changes_message")
	page.show_view(RepoTab.View.HISTORY)
	while main.tab_count() > 0:
		main.close_tab(0)
	await _shot(out, "welcome")
	get_tree().quit(0)


func _settle() -> void:
	for i: int in 30:
		await get_tree().process_frame


func _shot(dir: String, name: String) -> void:
	await _settle()
	var path: String = dir.path_join(name + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path)
