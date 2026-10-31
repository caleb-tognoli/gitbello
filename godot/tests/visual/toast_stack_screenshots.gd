extends Node

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _main: Main
@onready var root: Window = get_tree().root


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var out: String = ""
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
		elif arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
	if out.is_empty() or repo.is_empty():
		get_tree().quit(2)
		return
	_main = MAIN.instantiate() as Main
	root.add_child(_main)
	root.content_scale_factor = 1.0
	Input.warp_mouse(Vector2(4, 4))
	var page: RepoTab = _main.open_repo(repo)
	var deadline: int = Time.get_ticks_msec() + 30_000
	while not page.session.is_ready() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	page.show_view(WorktreeView.View.CHANGES)
	for dimensions: Vector2i in [Vector2i(1280, 800), Vector2i(960, 600)]:
		root.size = dimensions
		for light: bool in [false, true]:
			Actions.run_action(&"view.theme_light" if light else &"view.theme_dark")
			var toasts: Toasts = _main.toasts()
			toasts.show_toast("repo-1: Push rejected", "The remote contains commits that are not in this branch.", "git push\nRejected: fetch first.", [{"label": "Pull", "run": func() -> void: pass}])
			toasts.show_success("Discarded changes in app.txt", func() -> void: pass)
			var progress: PanelContainer = toasts.show_progress("Fetching repo-2…", func() -> void: pass)
			toasts.update_progress(progress, "Fetching repo-2…", 40)
			for i: int in 5:
				toasts.show_toast("repo-%d: Cannot update worktree" % (i + 3), "Local changes would be overwritten. Commit or shelve the changes before switching branches.")
			for frame: int in 12:
				await get_tree().process_frame
			_main.queue_redraw()
			await RenderingServer.frame_post_draw
			var name: String = "burst_%dx%d_%s.png" % [dimensions.x, dimensions.y, "light" if light else "dark"]
			var path: String = out.path_join(name)
			root.get_texture().get_image().save_png(path)
			print("SHOT ", path)
			for toast: Node in toasts.find_children("*", "PanelContainer", true, false):
				if toast.find_child("Title", true, false) != null:
					toast.queue_free()
			for frame: int in 12:
				await get_tree().process_frame
	get_tree().quit(0)
