extends Node
## Windows: deleting a worktree while a program uses its folder, in the real
## app, one screenshot per step. A copy of `ping` running from the worktree
## (like an app built there) stops the deletion before anything is deleted;
## Try again deletes it once the program exits. A terminal sitting in a
## subfolder (`cmd` with its current folder there) lets git delete part of
## the folder: the toast offers to delete the rest. Adds and deletes
## worktrees in `--repo`: a throwaway CLI fixture (`repo-10`) only, with
## `GITBELLO_CONFIG` set to a scratch file.
## `-- --repo=<fixture repo-10> --out=<dir>`

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
	if _out.is_empty() or repo.is_empty() or OS.get_name() != "Windows":
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
	var session: RepoSession = page.session
	await _until(func() -> bool: return session.is_ready() and session.worktrees().size() >= 2)
	var toasts: Toasts = _main.toasts()
	# Like build output, the programs' folder is ignored.
	var exclude: FileAccess = FileAccess.open(repo.path_join(".git/info/exclude"), FileAccess.READ_WRITE)
	exclude.seek_end()
	exclude.store_string("/bin/\n")
	exclude.close()

	# A program running from the worktree: nothing is deleted.
	var busy: String = repo + "-busy"
	var pid: int = await _add_running(session, busy, "busy")
	await _shot("busy-worktree-chip", "worktrees: %d, program PID %d" % [session.worktrees().size(), pid])
	page.ops().remove_worktree(_worktree(session, busy))
	await _until(func() -> bool: return page.ops().form().visible)
	await _shot_window(page.ops().form(), "delete-confirmation")
	page.ops().form().submit()
	await _until(func() -> bool: return toasts.fix_labels().has("Try again"))
	await _shot("in-use-toast", "toasts: %s; worktrees: %d; README kept: %s" % [toasts.toast_texts(),
			session.worktrees().size(), FileAccess.file_exists(busy.path_join("README.md"))])
	await _details(toasts, "in-use-details")
	OS.kill(pid)
	await _until(func() -> bool: return not OS.is_process_running(pid))
	_press_fix(toasts, "Try again")
	await _until(func() -> bool: return _worktree(session, busy).is_empty() and not _has_branch(session, "busy"))
	await _shot("deleted-after-try-again", "worktrees: %d; folder exists: %s; toasts: %s" % [
			session.worktrees().size(), DirAccess.dir_exists_absolute(busy), toasts.toast_texts()])

	# A terminal in a subfolder: git deletes part of the folder.
	var held: String = repo + "-held"
	session.add_worktree(held, "held", "main")
	await _until(func() -> bool: return not _worktree(session, held).is_empty())
	DirAccess.make_dir_recursive_absolute(held.path_join("bin/sub"))
	var shell: int = OS.create_process("cmd.exe", ["/d", "/c", "cd /d \"%s\" && ping -n 120 127.0.0.1 >nul" % held.path_join("bin/sub").replace("/", "\\")])
	await _wait(1.0)
	page.ops().remove_worktree(_worktree(session, held))
	await _until(func() -> bool: return page.ops().form().visible)
	page.ops().form().submit()
	await _until(func() -> bool: return toasts.fix_labels().has("Try again"), 60.0)
	await _shot("folder-left-toast", "toasts: %s; registered: %s; folder exists: %s" % [toasts.toast_texts(),
			not _worktree(session, held).is_empty(), DirAccess.dir_exists_absolute(held)])
	await _details(toasts, "folder-left-details")
	OS.execute("taskkill", ["/F", "/T", "/PID", str(shell)])
	await _until(func() -> bool: return not OS.is_process_running(shell))
	_press_fix(toasts, "Try again")
	await _until(func() -> bool: return not DirAccess.dir_exists_absolute(held) and not _has_branch(session, "held"))
	await _shot("rest-deleted", "folder exists: %s; branch kept: %s; toasts: %s" % [DirAccess.dir_exists_absolute(held),
			_has_branch(session, "held"), toasts.toast_texts()])
	get_tree().quit()


## Adds worktree `path` on a new branch and starts a copy of `ping` from it.
func _add_running(session: RepoSession, path: String, branch: String) -> int:
	session.add_worktree(path, branch, "main")
	await _until(func() -> bool: return not _worktree(session, path).is_empty())
	var exe: String = path.path_join("bin/held.exe")
	DirAccess.make_dir_recursive_absolute(exe.get_base_dir())
	DirAccess.copy_absolute(OS.get_environment("SystemRoot").path_join("System32/PING.EXE"), exe)
	return OS.create_process(exe, ["-n", "120", "127.0.0.1"])


func _details(toasts: Toasts, step: String) -> void:
	for node: Node in toasts.find_children("*", "Button", true, false):
		if (node as Button).tooltip_text == "Show error details":
			(node as Button).pressed.emit()
			break
	await _frames(4)
	var dialog: AcceptDialog = null
	for child: Node in toasts.get_children():
		if child is AcceptDialog:
			dialog = child as AcceptDialog
	if dialog == null:
		print("SHOT skipped: no details dialog")
		return
	await _shot_window(dialog, step)
	dialog.get_ok_button().pressed.emit()
	await _frames(4)


func _press_fix(toasts: Toasts, label: String) -> void:
	for node: Node in toasts.find_children("*", "Button", true, false):
		if (node as Button).text == label:
			(node as Button).pressed.emit()
			return


static func _has_branch(session: RepoSession, branch: String) -> bool:
	for ref: Dictionary in session.branch_refs():
		if String(ref["kind"]) == "branch" and String(ref["short_name"]) == branch:
			return true
	return false


static func _worktree(session: RepoSession, path: String) -> Dictionary:
	for wt: Dictionary in session.worktrees():
		if Paths.same(String(wt["path"]), path):
			return wt
	return {}


func _shot(step: String, note: String) -> void:
	await _frames(12)
	_main.queue_redraw()
	await RenderingServer.frame_post_draw
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	root.get_texture().get_image().save_png(path)
	print("SHOT ", path, " · ", note)


func _shot_window(window: Window, step: String) -> void:
	await _frames(12)
	await RenderingServer.frame_post_draw
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	window.get_texture().get_image().save_png(path)
	print("SHOT ", path)


func _until(condition: Callable, seconds: float = 30.0) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while not bool(condition.call()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _frames(count: int) -> void:
	for frame: int in count:
		await get_tree().process_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
