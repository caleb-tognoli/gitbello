extends Node
## M7.16's entry points in the real app, one numbered screenshot per step: a
## branch's menu with Open in new worktree, the worktree it makes at once with
## its Undo toast, Undo, an offline one click (the toast says which fetch it
## is based on), History's commit menu with New worktree here… and the dialog
## it opens, the worktree list's filter with no match and Enter, Worktree
## setup…, a failed setup's toast, and the Undo toast in the light theme.
## Adds refs and worktrees to `--repo` and moves its remote away for a
## moment: a throwaway CLI fixture repo-10 only, with `GITBELLO_CONFIG` set
## to a scratch file.
## `-- --repo=<CLI fixture repo-10> --out=<dir>`

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _main: Main
var _page: RepoTab
var _out: String = ""
var _step: int = 0
@onready var root: Window = get_tree().root


func _ready() -> void:
	DisplayServer.window_set_position(Vector2i(-10000, -10000))
	# Every frame draws, so a shot's `frame_post_draw` comes when nothing moves.
	OS.low_processor_usage_mode = false
	_run.call_deferred()


func _run() -> void:
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
	if _out.is_empty() or repo.is_empty() or OS.get_environment("GITBELLO_CONFIG").is_empty():
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	# Popups are embedded (a native popup off screen has no picture); set
	# before the app is built, so its windows are made embedded.
	root.gui_embed_subwindows = true
	_main = MAIN.instantiate() as Main
	root.add_child(_main)
	root.content_scale_factor = 1.0
	root.size = Vector2i(1280, 800)
	Actions.run_action(&"view.theme_dark")
	_page = _main.open_repo(repo)
	var loaded: Callable = func() -> bool:
		return _page.session.is_ready() and not _page.session.branch_refs().is_empty() \
				and not _page.session.default_base().is_empty()
	await _until(loaded)
	var head: String = ""
	for ref: Dictionary in _page.session.branch_refs():
		if String(ref["short_name"]) == "main":
			head = String(ref["commit"])
	_write(repo.path_join(".git/refs/heads/one-click"), head + "\n")
	DirAccess.make_dir_recursive_absolute(repo.path_join(".git/refs/remotes/origin"))
	_write(repo.path_join(".git/refs/remotes/origin/remote-only"), head + "\n")
	Core.focus_in(_page.session)
	await _until(func() -> bool: return _has_branch("one-click"))
	await _frames(30)
	var view: WorktreeView = _page.active_view()
	var main_session: RepoSession = _page.session

	# A branch's menu, then one click.
	var one_ref: Dictionary = {"type": "branch", "name": "refs/heads/one-click", "short": "one-click",
		"commit": head, "is_head": false, "upstream": "", "worktree": ""}
	view.show_ref_menu(one_ref, Vector2(300, 260))
	await _shot_popup(view.context_menu(), "branch-menu", "%s" % [view.menu_labels()])
	view.press_menu("Open in new worktree")
	await _until(func() -> bool: return _page.session.current_branch() == "one-click")
	await _frames(120)
	await _shot("one-click-created", "current %s · toasts %s" % [_page.session.current_branch(), _toasts().toast_texts()])
	_toasts().press_fix("Undo", "one-click")
	await _until(func() -> bool: return main_session.worktrees().size() == 2)
	await _shot("undone", "worktrees %d · branch one-click kept: %s" % [main_session.worktrees().size(),
			_has_branch("one-click")])

	# Offline: the remote's folder moved away; the remote branch is checked
	# out from its last fetch, and the toast says so.
	var origin: String = repo + "-origin.git"
	DirAccess.rename_absolute(origin, origin + "-away")
	_page.active_view().ops().open_in_new_worktree({"type": "remote", "name": "refs/remotes/origin/remote-only",
		"short": "origin/remote-only", "commit": head, "is_head": false, "upstream": "", "worktree": ""})
	await _until(func() -> bool: return _page.session.current_branch() == "remote-only")
	await _shot("offline-created", "toasts %s" % [_toasts().toast_texts()])
	DirAccess.rename_absolute(origin + "-away", origin)
	_toasts().press_fix("Undo", "remote-only")
	await _until(func() -> bool: return main_session.worktrees().size() == 2)
	await _frames(20)

	# History's commit menu, and the dialog it opens.
	view = _page.active_view()
	view.history().commit_menu_requested.emit(Vector2(300, 260))
	await _shot_popup(view.context_menu(), "commit-menu", "%s" % [view.menu_labels()])
	view.press_menu("New worktree here…")
	var form: FormDialog = view.ops().form()
	await _until(func() -> bool: return form.visible)
	await _shot_popup(form, "commit-dialog", "From %s" % view.ops().base_button().text)
	form.hide()

	# The worktree list: a filter matching nothing, then Enter.
	var strip: WorktreeStrip = _page.strip()
	# Placed under its icon in the window's coordinates (it is embedded).
	strip.list_button().pressed.emit()
	var all_list: WorktreeListPopover = strip.all_list()
	var under: Rect2 = strip.list_button().get_global_rect()
	all_list.position = Vector2i(under.position + Vector2(0.0, under.size.y))
	all_list.set_filter("brand new")
	await _shot_popup(all_list, "list-no-match", all_list.empty_text())
	all_list._filter.submitted.emit(false)
	await _until(func() -> bool: return form.visible)
	await _shot_popup(form, "list-enter-dialog", (form.field("name") as LineEdit).text)
	form.hide()

	# Worktree setup…, then a setup that fails.
	view.ops().edit_worktree_setup()
	await _until(func() -> bool: return form.visible)
	await _shot_popup(form, "setup-settings-empty", "")
	(form.field("copy") as TextEdit).text = ".env*\n.vscode/"
	(form.field("command") as LineEdit).text = "echo installing && exit 3"
	form.revalidate()
	await _shot_popup(form, "setup-settings-filled", "")
	form.submit()
	var feature: String = ""
	for wt: Dictionary in main_session.worktrees():
		if not bool(wt["is_main"]):
			feature = String(wt["path"])
	view.ops().run_setup(feature)
	await _until(func() -> bool: return Array(_toasts().toast_texts()).any(func(t: String) -> bool: return t.begins_with("Setup failed")))
	await _shot("setup-failed", "toasts %s · fixes %s" % [_toasts().toast_texts(), _toasts().fix_labels()])
	main_session.set_worktree_setup(PackedStringArray(), "")

	Actions.run_action(&"view.theme_light")
	await _frames(10)
	_page.active_view().ops().open_in_new_worktree(one_ref)
	await _until(func() -> bool: return _page.session.current_branch() == "one-click")
	await _frames(120)
	await _shot("light-one-click", "toasts %s" % [_toasts().toast_texts()])
	get_tree().quit(0)


func _toasts() -> Toasts:
	return _main.toasts()


func _has_branch(branch: String) -> bool:
	for ref: Dictionary in _page.session.branch_refs():
		if String(ref["kind"]) == "branch" and String(ref["short_name"]) == branch:
			return true
	return false


func _shot(step: String, note: String) -> void:
	await _frames(12)
	await RenderingServer.frame_post_draw
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	root.get_texture().get_image().save_png(path)
	print("SHOT ", path, " · ", note)


func _shot_popup(window: Window, step: String, note: String) -> void:
	await _frames(12)
	await RenderingServer.frame_post_draw
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	var image: Image = null
	if window.is_embedded():
		var whole: Image = root.get_texture().get_image()
		image = whole.get_region(Rect2i(window.position, window.size).intersection(Rect2i(Vector2i.ZERO, whole.get_size())))
	else:
		image = window.get_texture().get_image()
	image.save_png(path)
	print("SHOT ", path, " · ", note)


static func _write(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _until(condition: Callable, seconds: float = 30.0) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while not bool(condition.call()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _frames(count: int) -> void:
	for frame: int in count:
		await get_tree().process_frame
