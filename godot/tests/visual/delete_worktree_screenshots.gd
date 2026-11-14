extends Node
## The Delete worktree dialog in the real app, one numbered screenshot per
## step: a squash-merged branch while it is checked (with a 3x crop of the
## loading spinner) and once it is (ticked, with its remote branch), an
## unmerged branch (unticked) and a click right on its check box, a detached
## worktree's commits kept as a renamed branch (and unticked: what is lost),
## a rebasing worktree, Delete branch and Clean up on the squash-merged
## branch, and the light theme (checking, with a crop, then checked). Each
## shot's line in the log says what the dialog's rows show.
## Builds its own repository (with a bare remote) in `--work` and deletes a
## worktree there: an empty throwaway folder only, with `GITBELLO_CONFIG`
## and `GIT_CONFIG_GLOBAL` set to scratch files.
## `-- --work=<empty dir> --out=<dir>`

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const AUTHOR: PackedStringArray = ["-c", "user.name=Ada", "-c", "user.email=ada@example.com"]

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
	var work: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--work="):
			work = arg.trim_prefix("--work=")
	if _out.is_empty() or work.is_empty() or OS.get_environment("GIT_CONFIG_GLOBAL").is_empty():
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var repo: String = work.path_join("app")
	_build_repo(work, repo)
	_main = MAIN.instantiate() as Main
	root.add_child(_main)
	root.content_scale_factor = 1.0
	root.size = Vector2i(1280, 800)
	Actions.run_action(&"view.theme_dark")
	_page = _main.open_repo(repo)
	var loaded: Callable = func() -> bool:
		return _session().is_ready() and _session().worktrees().size() == 5 and not _session().branch_refs().is_empty()
	await _until(loaded)
	await _frames(30)
	var form: FormDialog = _page.ops().form()

	# A squash-merged branch: checked, then ticked with its remote branch.
	await _open_delete("wt-squashed")
	await _shot_window(form, "squashed-opened", 1)
	_crop(form, "delete_branch", "squashed-opened-crop")
	await _until(func() -> bool: return not "Checking…" in form.item_facts("delete_branch"), 10.0)
	await _shot_window(form, "squashed-checked")
	form.hide()

	# An unmerged branch: unticked; a click right on the box ticks it.
	await _open_delete("wt-feature")
	await _until(func() -> bool: return not "Checking…" in form.item_facts("delete_branch"), 10.0)
	await _shot_window(form, "unmerged")
	var box: CheckBox = form.field("delete_branch") as CheckBox
	_click(form, box.get_global_rect().get_center())
	await _shot_window(form, "unmerged-box-clicked")
	form.hide()

	# A detached worktree: keep its commits as a branch, renamed.
	await _open_delete("wt-detached")
	await _until(func() -> bool: return form.field("keep") != null, 10.0)
	await _shot_window(form, "detached")
	var keep: CheckBox = form.field("keep") as CheckBox
	_click(form, keep.get_global_rect().get_center())
	await _shot_window(form, "detached-unticked")
	_click(form, keep.get_global_rect().get_center())
	await _frames(4)
	var rename_line: LineEdit = form.field("keep_name") as LineEdit
	var chip: Control = rename_line.get_parent().get_child(rename_line.get_index() - 1) as Control
	_click(form, chip.get_global_rect().get_center())
	await _frames(4)
	var rename: LineEdit = rename_line
	rename.clear()
	for ch: String in "spike/kept":
		rename.insert_text_at_caret(ch)
	rename.text_changed.emit(rename.text)
	await _shot_window(form, "detached-renamed")
	form.submit()
	await _until(func() -> bool: return _session().worktrees().size() == 4 and _has_branch("spike/kept"), 30.0)
	await _frames(20)
	await _shot("detached-kept", "branches: %s" % [_branches()])

	# A rebasing worktree: its branch, unticked, and the rebase that goes.
	await _open_delete("wt-rebasing")
	var checked: Callable = func() -> bool:
		return form.field("delete_branch") != null and not "Checking…" in form.item_facts("delete_branch")
	await _until(checked, 10.0)
	await _shot_window(form, "rebasing")
	form.hide()

	# Delete branch and Clean up say the same of the squash-merged branch.
	_page.ops().delete_branch("squashed")
	await _until(func() -> bool: return form.visible and not "Checking…" in form.item_facts("branch"), 10.0)
	await _shot_window(form, "delete-branch-squashed")
	form.hide()
	Actions.run_action(&"worktree.cleanup")
	await _until(func() -> bool: return form.visible and form.field("delete_branches") != null, 20.0)
	await _shot_window(form, "cleanup")
	form.hide()

	Actions.run_action(&"view.theme_light")
	await _frames(10)
	await _open_delete("wt-squashed")
	await _shot_window(form, "light-checking", 1)
	_crop(form, "delete_branch", "light-checking-crop")
	await _until(func() -> bool: return not "Checking…" in form.item_facts("delete_branch"), 10.0)
	await _shot_window(form, "light")
	form.hide()
	Actions.run_action(&"view.theme_dark")
	get_tree().quit(0)


## Opens the Delete worktree dialog of the worktree in folder `folder` the
## way its chip's menu does.
func _open_delete(folder: String) -> void:
	var wt: Dictionary = _worktree(folder)
	_page.strip().worktree_menu_requested.emit(wt, Vector2(400, 60))
	await _frames(2)
	_page.press_menu("Delete…")
	await _until(func() -> bool: return _page.ops().form().visible, 10.0)


## A left click (press and release) at `at` in `window`.
func _click(window: Window, at: Vector2) -> void:
	for pressed: bool in [true, false]:
		var event: InputEventMouseButton = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = at
		event.global_position = at
		window.push_input(event)


## `repo` with a bare remote: `squashed`, pushed then squash-merged into
## main (pushed), in `wt-squashed`; `feature`, two commits not in main, in
## `wt-feature`; `wt-detached` with a commit on no branch; `wt-rebasing` on
## `rebasing`, stopped in a rebase onto main.
func _build_repo(work: String, repo: String) -> void:
	DirAccess.make_dir_recursive_absolute(repo)
	var remote: String = work.path_join("origin.git")
	_git(work, ["init", "-q", "--bare", "-b", "main", remote])
	_git(repo, ["init", "-q", "-b", "main"])
	_git(repo, ["remote", "add", "origin", remote])
	_write(repo, "README.md", "# App\n")
	_commit(repo, "Initial commit")
	_git(repo, ["push", "-q", "-u", "origin", "main"])
	_git(repo, ["switch", "-q", "-c", "squashed"])
	_write(repo, "login.txt", "login\n")
	_commit(repo, "Add the login form")
	_write(repo, "session.txt", "session\n")
	_commit(repo, "Keep the session")
	_git(repo, ["push", "-q", "-u", "origin", "squashed"])
	_git(repo, ["switch", "-q", "-c", "feature", "main"])
	_write(repo, "search.txt", "search\n")
	_commit(repo, "Search the history")
	_write(repo, "search.txt", "search\nfilters\n")
	_commit(repo, "Filter the search")
	_git(repo, ["switch", "-q", "-c", "rebasing", "main"])
	_write(repo, "README.md", "# App, rebasing\n")
	_commit(repo, "Reword the readme")
	_git(repo, ["switch", "-q", "main"])
	_git(repo, ["merge", "--squash", "-q", "squashed"])
	_commit(repo, "Login (#12)")
	_write(repo, "README.md", "# App\n\nA git client.\n")
	_commit(repo, "Describe the app")
	_git(repo, ["push", "-q", "origin", "main"])
	_git(repo, ["worktree", "add", "-q", "../wt-squashed", "squashed"])
	_git(repo, ["worktree", "add", "-q", "../wt-feature", "feature"])
	_git(repo, ["worktree", "add", "-q", "--detach", "../wt-detached", "main"])
	var detached: String = work.path_join("wt-detached")
	_write(detached, "spike.txt", "a spike\n")
	_commit(detached, "Try a spike")
	_git(repo, ["worktree", "add", "-q", "../wt-rebasing", "rebasing"])
	_git(work.path_join("wt-rebasing"), AUTHOR + PackedStringArray(["rebase", "main"]))


func _write(dir: String, file: String, text: String) -> void:
	var handle: FileAccess = FileAccess.open(dir.path_join(file), FileAccess.WRITE)
	handle.store_string(text)
	handle.close()


func _commit(dir: String, message: String) -> void:
	_git(dir, ["add", "-A"])
	_git(dir, AUTHOR + PackedStringArray(["commit", "-q", "-m", message]))


static func _git(dir: String, args: PackedStringArray) -> String:
	var output: Array = []
	OS.execute("git", PackedStringArray(["-C", dir]) + args, output, true)
	return String(output[0]).strip_edges() if not output.is_empty() else ""


func _session() -> RepoSession:
	return _page.session


func _worktree(folder: String) -> Dictionary:
	for wt: Dictionary in _session().worktrees():
		if String(wt["path"]).replace("\\", "/").ends_with("/" + folder):
			return wt
	return {}


func _branches() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for ref: Dictionary in _session().branch_refs():
		if String(ref["kind"]) == "branch":
			out.append(String(ref["short_name"]))
	return out


func _has_branch(branch: String) -> bool:
	return branch in _branches()


## What the dialog's rows show: each field's tick and facts.
func _rows(form: FormDialog) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for key: String in ["folder", "branch", "delete_branch", "remote", "keep"]:
		var check: CheckBox = form.field(key) as CheckBox
		if check != null and check.is_visible_in_tree():
			parts.append("%s %s %s %s" % [key, "[x]" if check.button_pressed else "[ ]",
					check.accessibility_name, form.item_facts(key)])
	return " | ".join(parts)


func _shot(step: String, note: String) -> void:
	await _frames(12)
	await RenderingServer.frame_post_draw
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	root.get_texture().get_image().save_png(path)
	print("SHOT ", path, " · ", note)


func _shot_window(window: Window, step: String, frames: int = 12) -> void:
	await _frames(frames)
	await RenderingServer.frame_post_draw
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	window.get_texture().get_image().save_png(path)
	print("SHOT ", path, " · ", _rows(window as FormDialog))


## Item `key`'s row of `window`, 3x, cut from what is on screen now.
func _crop(window: Window, key: String, step: String) -> void:
	var row: Control = (window as FormDialog).field(key).get_parent() as Control
	var image: Image = window.get_texture().get_image()
	var rect: Rect2i = Rect2i(row.get_global_rect()).grow(4).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var part: Image = image.get_region(rect)
	part.resize(rect.size.x * 3, rect.size.y * 3, Image.INTERPOLATE_NEAREST)
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	part.save_png(path)
	print("SHOT ", path, " · 3x of ", key)


func _until(condition: Callable, seconds: float = 30.0) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while not bool(condition.call()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _frames(count: int) -> void:
	for frame: int in count:
		await get_tree().process_frame
