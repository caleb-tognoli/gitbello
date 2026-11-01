extends Node
## Drives the toast rules through the real app and saves one screenshot per
## step: a commit (no toast), a discard (Undo toast), Copy hash, a fetch from
## the palette (progress), an error with a fix and Details, the light theme
## and a burst in a small window. Commits, discards and fetches in `--repo`:
## a throwaway CLI fixture with a remote (`repo-8`) only, with
## `GITBELLO_CONFIG` set to a scratch file.
## `-- --repo=<fixture repo> --out=<dir>`

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _main: Main
var _out: String = ""
var _step: int = 0
@onready var root: Window = get_tree().root


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
	if _out.is_empty() or repo.is_empty():
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_main = MAIN.instantiate() as Main
	root.add_child(_main)
	root.content_scale_factor = 1.0
	root.size = Vector2i(1280, 800)
	Input.warp_mouse(Vector2(4, 4))
	Actions.run_action(&"view.theme_dark")
	var page: RepoTab = _main.open_repo(repo)
	await _until(func() -> bool: return page.session.is_ready())
	page.show_view(WorktreeView.View.CHANGES)
	var session: RepoSession = page.session
	var toasts: Toasts = _main.toasts()
	var view: ChangesView = page.changes()

	# A commit: the list empties and the undo strip shows it; no toast.
	_write(repo.path_join("toast-demo.txt"), "first\n")
	await _until(func() -> bool: return view.commit_box().can_commit() or _has_change(session))
	view.commit_box().set_message("Add the toast demo", "")
	await _until(func() -> bool: return view.commit_box().can_commit())
	view.commit_box().commit()
	await _until(func() -> bool: return not session.undoable_commit().is_empty() and not _has_change(session))
	await _shot("commit-no-toast", "no toast after a commit: %d" % toasts.toast_count())

	# A discard: the toast offers Undo, with its time-left line.
	_write(repo.path_join("toast-demo.txt"), "first\nsecond\n")
	await _until(func() -> bool: return _has_change(session))
	view._discard_paths(PackedStringArray(["toast-demo.txt"]))
	view.confirm_dialog().get_ok_button().pressed.emit()
	await _until(func() -> bool: return toasts.fix_labels().has("Undo"))
	await _wait(1.0)
	await _shot("discard-undo-toast", "toasts: %s" % [toasts.toast_texts()])

	# Copy hash: nothing else shows it.
	page.ops().copy_hash(String(session.undoable_commit()["oid"]))
	await _shot("copy-hash-toast", "toasts: %s" % [toasts.toast_texts()])
	_clear(toasts)

	# A fetch from the palette: no button behind it, so a progress toast.
	page.ops().fetch()
	await _frames(2)
	await _shot("fetch-progress-toast", "toasts: %s" % [toasts.toast_texts()])
	await _until(func() -> bool: return toasts.toast_count() == 0)
	await _shot("fetch-done-no-toast", "toasts after the fetch: %d" % toasts.toast_count())

	# An error with a fix and Details.
	Core.git_error.emit(repo, {"kind": "non_fast_forward", "title": "Push rejected",
		"message": "The remote has commits this branch does not have. Pull them, then push again.",
		"command": "push origin main", "stderr": "! [rejected] main -> main (fetch first)"})
	await _shot("error-toast", "toasts: %s" % [toasts.toast_texts()])

	# The same in the light theme, with a success below the error.
	Actions.run_action(&"view.theme_light")
	page.ops().copy_hash(String(session.undoable_commit()["oid"]))
	await _shot("light-theme", "toasts: %s" % [toasts.toast_texts()])

	# A burst in a small window: bounded, scrolling, with the count.
	Actions.run_action(&"view.theme_dark")
	root.size = Vector2i(960, 600)
	for i: int in 5:
		toasts.show_toast("repo-%d: Cannot update worktree" % (i + 3),
				"Local changes would be overwritten. Commit or shelve the changes before switching branches.")
	await _shot("burst-small-window", "toasts: %d" % toasts.toast_count())
	_clear(toasts)
	get_tree().quit(0)


func _has_change(session: RepoSession) -> bool:
	return session.change_count() > 0


func _write(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _clear(toasts: Toasts) -> void:
	for panel: Node in toasts.get_node("Scroll/Stack").get_children():
		panel.queue_free()


func _shot(step: String, note: String) -> void:
	await _frames(12)
	_main.queue_redraw()
	await RenderingServer.frame_post_draw
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	root.get_texture().get_image().save_png(path)
	print("SHOT ", path, " · ", note)


func _until(condition: Callable, seconds: float = 30.0) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while not bool(condition.call()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _frames(count: int) -> void:
	for frame: int in count:
		await get_tree().process_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
