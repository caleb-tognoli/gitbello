extends Node
## Captures the README's screenshots: History and Changes in the dark and light themes.
## Usage: godot --path godot res://tests/visual/readme_screenshots.tscn --
##        --repo=<throwaway repository with worktrees and an uncommitted change> --out=<dir>
## Run with GITBELLO_CONFIG pointing at a scratch config file (read-only on the repository).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000


func _ready() -> void:
	var repo: String = ""
	var out: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	if repo.is_empty() or out.is_empty():
		printerr("readme_screenshots: pass -- --repo=<path> --out=<dir>")
		get_tree().quit(2)
		return
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	main.open_repo(repo)
	main.tab_bar().current_tab = 0
	var page: RepoTab = main.page_at(0)
	if not await _wait(func() -> bool: return page.history().commit_list().row_count() > 0 \
			and not page.session.badge().get("head", "").is_empty()):
		printerr("readme_screenshots: the history didn't load")
		get_tree().quit(1)
		return
	page.history().commit_list().select_only(0)
	await _shots(out, "history")
	page.show_view(WorktreeView.View.CHANGES)
	if not await _wait(func() -> bool: return page.changes().diff_view().row_count() > 0):
		printerr("readme_screenshots: the diff didn't load")
		get_tree().quit(1)
		return
	await _shots(out, "changes")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit()


func _wait(condition: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return false


func _shots(dir: String, view: String) -> void:
	for theme: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + theme))
		for i: int in 30:
			await get_tree().process_frame
		var path: String = dir.path_join("%s_%s.png" % [view, theme])
		get_viewport().get_texture().get_image().save_png(path)
		print("SHOT ", path)
