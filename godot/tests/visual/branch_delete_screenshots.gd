extends Node
## The delete flows in the real app, one numbered screenshot per step: a
## merged, published branch (its dialog, the toast, Undo), an unmerged one,
## the current branch, a branch checked out in another worktree, a remote
## branch, the Delete key in the branch list, a worktree, the cleanup, a tag,
## the palette's reason for a delete it cannot run, and the dialog in the
## light theme. Each shot's line in the log says what the repository holds
## then (local and remote branches). Steps the build cannot do are shot as
## they are (a menu without Delete) and the run goes on.
## Deletes branches, worktrees and tags in `--repo` and on its remote: a
## throwaway CLI fixture prepared by `branch_delete_prep.sh` only, with
## `GITBELLO_CONFIG` set to a scratch file.
## `-- --repo=<prepared fixture repo-1> --out=<dir>`

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _main: Main
var _page: RepoTab
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
	_page = _main.open_repo(repo)
	await _until(func() -> bool: return _session().is_ready() and _session().worktrees().size() >= 3)
	await _frames(30)

	# A merged branch that was pushed.
	var view: WorktreeView = _page.active_view()
	view.open_branches()
	await _shot_window(view.branch_popover(), "branch-list")
	view.branch_popover().hide()
	await _ref_menu("done", "branch", "merged-branch-menu")
	await _press_delete("Delete branch…", "merged-branch-dialog")
	await _submit_and_wait(func() -> bool: return not _has(_session(), "branch", "done"))
	await _shot("merged-branch-deleted", "")
	if _press_toast("Undo"):
		await _until(func() -> bool: return _has(_session(), "branch", "done") and _has(_session(), "remote", "origin/done"), 20.0)
		await _shot("merged-branch-undone", "")

	# A branch with commits merged nowhere else.
	await _ref_menu("wip", "branch", "unmerged-branch-menu")
	await _press_delete("Delete branch…", "unmerged-branch-dialog")
	await _submit_and_wait(func() -> bool:
		return not _has(_session(), "branch", "wip") or _page.ops().confirm_dialog().visible)
	_log("  after submit: confirm %s" % _page.ops().confirm_dialog().visible)
	if _page.ops().confirm_dialog().visible:
		await _shot_window(_page.ops().confirm_dialog(), "unmerged-branch-asks-again")
		_page.ops().confirm_dialog().get_ok_button().pressed.emit()
		await _until(func() -> bool: return not _has(_session(), "branch", "wip"))
	await _shot("unmerged-branch-deleted", "")

	# The checked-out branch.
	await _ref_menu("cur", "branch", "current-branch-menu")
	if await _press_delete("Delete branch…", "current-branch-dialog"):
		var switch: ConfirmationDialog = _page.ops().switch_dialog()
		await _submit_and_wait(func() -> bool: return not _has(_session(), "branch", "cur") or switch.visible)
		if switch.visible:
			await _shot_window(switch, "current-branch-local-changes")
			switch.get_ok_button().pressed.emit()
			await _until(func() -> bool: return not _has(_session(), "branch", "cur"))
		await _until(func() -> bool: return _session().current_branch() == "main")
		await _shot("current-branch-deleted", "")

	# A branch checked out in another worktree.
	await _ref_menu("feature/login", "branch", "worktree-branch-menu")
	if await _press_delete("Delete branch…", "worktree-branch-dialog"):
		await _submit_and_wait(func() -> bool: return not _has(_session(), "branch", "feature/login"))
		await _shot("worktree-branch-deleted", "")

	# A remote branch.
	await _ref_menu("origin/old", "remote", "remote-branch-menu")
	if await _press_delete("Delete remote branch…", "remote-branch-dialog"):
		await _submit_and_wait(func() -> bool: return not _has(_session(), "remote", "origin/old"))
		await _shot("remote-branch-deleted", "")

	# The Delete key in the branch list.
	view = _page.active_view()
	view.open_branches()
	view.branch_popover().set_filter("light")
	await _frames(4)
	var key: InputEventKey = InputEventKey.new()
	key.keycode = KEY_DELETE
	key.pressed = true
	(view.branch_popover().find_children("*", "Tree", true, false)[0] as Tree).gui_input.emit(key)
	await _until(_dialog_open, 5.0)
	if _dialog_open():
		view.branch_popover().hide()
		await _shot_window(_dialog(), "delete-key-dialog")
		_dialog().hide()
	else:
		await _shot_window(view.branch_popover(), "delete-key-nothing")
		view.branch_popover().hide()

	# A worktree.
	var task: Dictionary = _worktree_with("task")
	_page.ops().remove_worktree(task)
	await _until(_dialog_open)
	await _shot_window(_dialog(), "worktree-dialog")
	_dialog().hide()

	# The cleanup.
	Actions.run_action(&"worktree.cleanup")
	await _until(_dialog_open)
	await _shot_window(_dialog(), "cleanup-dialog")
	await _submit_and_wait(func() -> bool: return _worktree_with("task").is_empty())
	await _frames(30)
	await _shot("cleanup-done", "")

	# A pushed tag.
	_page.ops().delete_tag("v1.0")
	await _until(_dialog_open)
	await _shot_window(_dialog(), "tag-dialog")
	_dialog().hide()

	# The palette on main, which cannot be deleted while checked out.
	_main.palette().open()
	_main.palette().set_query("delete branch")
	await _frames(8)
	await _shot("palette-delete-branch", "palette: %s" % [_main.palette().visible_labels()])
	_main.palette().close()

	# The dialog in the light theme.
	Actions.run_action(&"view.theme_light")
	await _ref_menu("light", "branch", "")
	await _press_delete("Delete branch…", "light-theme-dialog")
	_dialog().hide()
	Actions.run_action(&"view.theme_dark")
	get_tree().quit()


## Prints `parts` and appends them to `<out>/log.txt` at once (Godot's
## stdout is buffered when piped, and lost if the run is killed).
func _log(a: Variant, b: Variant = "", c: Variant = "", d: Variant = "", e: Variant = "") -> void:
	var line: String = "%s%s%s%s%s" % [a, b, c, d, e]
	print(line)
	var path: String = _out.path_join("log.txt")
	var file: FileAccess = FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	file.seek_end()
	file.store_line(line)
	file.close()


func _session() -> RepoSession:
	return _page.active_view().session


## Opens the branch list's menu of `short_name` (`branch` or `remote`), shot
## as `step` unless empty.
func _ref_menu(short_name: String, kind: String, step: String) -> void:
	var ref: Dictionary = _ref(_session(), kind, short_name)
	if ref.is_empty():
		_log("SHOT skipped: no %s %s" % [kind, short_name])
		return
	var view: WorktreeView = _page.active_view()
	var worktree: String = String(ref["worktree"])
	var elsewhere: bool = not worktree.is_empty() and not bool(ref["is_head"]) \
			and not Paths.same(worktree, _session().toplevel())
	view.show_ref_menu({
		"type": "branch" if kind == "branch" else "remote",
		"name": String(ref["name"]),
		"short": short_name,
		"commit": String(ref["commit"]),
		"is_head": bool(ref["is_head"]),
		"upstream": String(ref["upstream"]),
		"worktree": worktree if elsewhere else "",
	}, view.get_screen_position() + Vector2(220.0, 140.0))
	if not step.is_empty():
		await _shot_window(view.context_menu(), step)
		_log("  menu: %s" % [view.menu_labels()])


## Presses `label` in the open menu and shoots the dialog it opens. Returns
## whether one opened.
func _press_delete(label: String, step: String) -> bool:
	var view: WorktreeView = _page.active_view()
	if not view.menu_labels().has(label):
		view.close_menu()
		_log("SHOT skipped: no %s in %s" % [label, view.menu_labels()])
		return false
	view.press_menu(label)
	_log("  pressed %s" % label)
	await _until(_dialog_open, 10.0)
	_log("  dialog open: %s" % _dialog_open())
	if not _dialog_open():
		return false
	if not step.is_empty():
		await _shot_window(_dialog(), step)
	return true


func _submit_and_wait(done: Callable) -> void:
	var dialog: ConfirmationDialog = _dialog()
	if dialog is FormDialog:
		(dialog as FormDialog).submit()
	else:
		dialog.get_ok_button().pressed.emit()
	await _until(done, 30.0)
	await _frames(20)


func _dialog_open() -> bool:
	return _dialog() != null


func _dialog() -> ConfirmationDialog:
	var ops: RepoOps = _page.active_view().ops()
	for dialog: ConfirmationDialog in [ops.form(), ops.confirm_dialog()]:
		if dialog.visible:
			return dialog
	return null


## Presses the toast button labelled `label`, if one shows.
func _press_toast(label: String) -> bool:
	for node: Node in _main.toasts().find_children("*", "Button", true, false):
		if (node as Button).text == label and (node as Button).is_visible_in_tree():
			(node as Button).pressed.emit()
			return true
	_log("SHOT skipped: no %s in the toasts %s" % [label, _main.toasts().toast_texts()])
	return false


func _worktree_with(branch: String) -> Dictionary:
	for wt: Dictionary in _session().worktrees():
		if String(wt["branch"]) == branch:
			return wt
	return {}


static func _ref(session: RepoSession, kind: String, short_name: String) -> Dictionary:
	for ref: Dictionary in session.branch_refs():
		if String(ref["kind"]) == kind and String(ref["short_name"]) == short_name:
			return ref
	return {}


static func _has(session: RepoSession, kind: String, short_name: String) -> bool:
	return not _ref(session, kind, short_name).is_empty()


## What the repository holds: its branches, remote branches and worktrees.
func _state() -> String:
	var local: PackedStringArray = PackedStringArray()
	var remote: PackedStringArray = PackedStringArray()
	for ref: Dictionary in _session().branch_refs():
		if String(ref["kind"]) == "branch":
			local.append(String(ref["short_name"]) + ("*" if bool(ref["is_head"]) else ""))
		elif String(ref["kind"]) == "remote":
			remote.append(String(ref["short_name"]))
	return "branches %s · remote %s · worktrees %d · toasts %s" % [", ".join(local), ", ".join(remote),
			_session().worktrees().size(), _main.toasts().toast_texts()]


func _shot(step: String, note: String) -> void:
	await _frames(12)
	_main.queue_redraw()
	await RenderingServer.frame_post_draw
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	root.get_texture().get_image().save_png(path)
	_log("SHOT ", path, " · ", _state(), (" · " + note) if not note.is_empty() else "")


func _shot_window(window: Window, step: String) -> void:
	await _frames(12)
	await RenderingServer.frame_post_draw
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	window.get_texture().get_image().save_png(path)
	_log("SHOT ", path, " · ", _state())


func _until(condition: Callable, seconds: float = 30.0) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	var next: int = Time.get_ticks_msec() + 3000
	while not bool(condition.call()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if Time.get_ticks_msec() > next:
			next += 3000
			_log("  waiting… ", _state())


func _frames(count: int) -> void:
	for frame: int in count:
		await get_tree().process_frame
