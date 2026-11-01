extends Node
## Read-only capture of the worktree header with the Changes | History |
## Shelves switch: each view in the dark and light themes, then Changes at
## the minimum window width. Pass --repo=<fixture with changes and a stash, e.g. CLI
## fixture repo-11> --out=<directory> and set GITBELLO_CONFIG to a scratch
## config before launching windowed.

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
		printerr("view_switch_screenshots: pass --repo=<fixture> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and not session.shelves().is_empty() \
			and session.change_count() > 0):
		return
	var views: Array[Array] = [[WorktreeView.View.CHANGES, "changes"], [WorktreeView.View.HISTORY, "history"],
			[WorktreeView.View.SHELVES, "shelves"]]
	var step: int = 1
	for mode: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + mode))
		for entry: Array in views:
			page.show_view(entry[0])
			await _shot(out, "%02d-%s-%s" % [step, entry[1], mode])
			step += 1
	Actions.run_action(&"view.theme_dark")
	page.show_view(WorktreeView.View.CHANGES)
	# The window's minimum width.
	get_window().size = Vector2i(960, 640)
	await _shot(out, "%02d-changes-narrow" % step)
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("view_switch_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


func _shot(out: String, file_name: String) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var path: String = out.path_join(file_name + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path)
