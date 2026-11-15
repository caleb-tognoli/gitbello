extends Node
## New worktree (Ctrl+T) in the real app, one numbered screenshot per step,
## each dialog shot with a 2x crop of its branch rows: no name (the branches
## to check out), a new name (Create, From, the folder preview), a name
## matching a remote branch (its check-out first, From hidden) and Down onto
## Create, a local branch, one checked out in a worktree (Create disabled),
## a long name, the From list (open, a typed commit, a filter with matches),
## a taken folder with Run setup, the folder field (✎), the new worktree
## shown after Create, then the dialog and the From list in the light theme.
## Each shot's log line says the rows, the choice and Create's state.
## Adds refs, files and a worktree to `--repo`: a throwaway CLI fixture
## repo-10 only, with `GITBELLO_CONFIG` set to a scratch file.
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
	_main = MAIN.instantiate() as Main
	root.add_child(_main)
	root.content_scale_factor = 1.0
	root.size = Vector2i(1280, 800)
	Actions.run_action(&"view.theme_dark")
	_page = _main.open_repo(repo)
	var loaded: Callable = func() -> bool:
		return _session().is_ready() and not _session().branch_refs().is_empty() \
				and not _session().default_base().is_empty()
	await _until(loaded)
	# A branch someone pushed, a local branch no worktree has, a tag.
	var head: String = ""
	for ref: Dictionary in _session().branch_refs():
		if String(ref["short_name"]) == "main":
			head = String(ref["commit"])
	DirAccess.make_dir_recursive_absolute(repo.path_join(".git/refs/remotes/origin"))
	_write(repo.path_join(".git/refs/remotes/origin/remote-only"), head + "\n")
	_write(repo.path_join(".git/refs/heads/free-branch"), head + "\n")
	DirAccess.make_dir_recursive_absolute(repo.path_join(".git/refs/tags"))
	_write(repo.path_join(".git/refs/tags/v1.0"), head + "\n")
	Core.focus_in(_session())
	var refreshed: Callable = func() -> bool:
		var free: bool = false
		for r: Dictionary in _session().branch_refs():
			free = free or String(r["short_name"]) == "free-branch"
		return free and not _session().tags().is_empty()
	await _until(refreshed)
	await _frames(30)
	var ops: RepoOps = _page.ops()
	var form: FormDialog = ops.form()

	Actions.run_action(&"task.new")
	await _until(func() -> bool: return form.visible)
	await _shot_form(form, "no-name")
	_type(form, "feature/search")
	await _shot_form(form, "new-branch")
	_type(form, "remote-only")
	await _shot_form(form, "remote-match")
	_key(form, KEY_DOWN)
	await _shot_form(form, "remote-match-down-create")
	_type(form, "free-branch")
	await _shot_form(form, "local-branch")
	_type(form, "feature/login")
	await _shot_form(form, "checked-out-elsewhere")
	_type(form, "feature/a-really-long-branch-name-that-keeps-going-for-quite-a-while")
	await _shot_form(form, "long-name")

	_type(form, "feature/search")
	ops.base_button().pressed.emit()
	var bases: BasePopover = ops.base_popover()
	await _until(func() -> bool: return bases.visible)
	await _shot_popup(bases, "from-list")
	bases.set_filter("a1b2c3d")
	await _shot_popup(bases, "from-typed-commit")
	bases.set_filter("ma")
	await _shot_popup(bases, "from-filter-matches")
	bases.set_filter("v1")
	bases.choose_selected()
	await _shot_form(form, "from-tag-chosen")
	form.hide()
	await _frames(4)

	# A taken folder gets a number; the repository has a setup.
	var taken: String = repo.path_join(".worktrees/feature-search")
	DirAccess.make_dir_recursive_absolute(taken)
	_write(taken.path_join("keep.txt"), "someone else's\n")
	_write(repo.path_join("app.local"), "secret\n")
	_session().set_worktree_setup(PackedStringArray([".env*", "*.local"]), "echo ready")
	Actions.run_action(&"task.new")
	await _until(func() -> bool: return form.visible)
	_type(form, "feature/search")
	await _shot_form(form, "taken-folder-and-setup")
	ops._edit_task_folder()
	await _shot_form(form, "folder-field")
	form.hide()
	await _frames(4)
	Actions.run_action(&"task.new")
	await _until(func() -> bool: return form.visible)
	_type(form, "feature/search")
	await _frames(4)
	form.submit()
	await _until(func() -> bool: return _session().current_branch() == "feature/search", 30.0)
	await _until(func() -> bool: return FileAccess.file_exists(taken + "-2/app.local"), 30.0)
	await _frames(30)
	await _shot("created", "current %s at %s · setup copied app.local: %s" % [_session().current_branch(),
			_session().toplevel(), FileAccess.file_exists(taken + "-2/app.local")])

	# The new worktree's view has its own dialogs.
	ops = _page.ops()
	form = ops.form()
	bases = ops.base_popover()
	Actions.run_action(&"view.theme_light")
	await _frames(10)
	Actions.run_action(&"task.new")
	await _until(func() -> bool: return form.visible)
	_type(form, "remote-only")
	await _shot_form(form, "light-remote-match")
	_type(form, "feature/light")
	await _shot_form(form, "light-new-branch")
	ops.base_button().pressed.emit()
	await _until(func() -> bool: return bases.visible)
	await _shot_popup(bases, "light-from-list")
	bases.hide()
	form.hide()
	get_tree().quit(0)


func _session() -> RepoSession:
	return _page.session


## Replaces the branch field's text with `text`, as typing would.
func _type(form: FormDialog, text: String) -> void:
	var line: LineEdit = form.field("name") as LineEdit
	line.grab_focus()
	line.clear()
	line.insert_text_at_caret(text)
	line.text_changed.emit(line.text)


## A key press and release in `window`, to its focused control.
func _key(window: Window, keycode: Key) -> void:
	for pressed: bool in [true, false]:
		var key: InputEventKey = InputEventKey.new()
		key.keycode = keycode
		key.pressed = pressed
		window.push_input(key)


func _state(form: FormDialog) -> String:
	var rows: WorktreeBranchList = _page.ops().worktree_branch_list()
	var ok: Button = form.get_ok_button()
	var create: String = "disabled (%s)" % ok.tooltip_text if ok.disabled else "enabled"
	return "rows %s · choice %s · From %s %s · %s · Create %s" % [rows.row_labels(), rows.choice(),
		_page.ops().base_button().is_visible_in_tree(), _page.ops().new_worktree_base(),
		_page.ops().folder_preview_text(), create]


## The dialog, then a 2x crop of its top (the branch field and rows).
func _shot_form(form: FormDialog, step: String) -> void:
	await _frames(12)
	await RenderingServer.frame_post_draw
	_step += 1
	var image: Image = _image(form)
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	image.save_png(path)
	var crop: Image = image.get_region(Rect2i(0, 0, image.get_width(), mini(image.get_height(), 260)))
	crop.resize(crop.get_width() * 2, crop.get_height() * 2, Image.INTERPOLATE_NEAREST)
	crop.save_png(_out.path_join("%02d-%s-2x.png" % [_step, step]))
	print("SHOT ", path, " · ", _state(form))


func _shot_popup(popup: BasePopover, step: String) -> void:
	await _frames(12)
	await RenderingServer.frame_post_draw
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	_image(popup).save_png(path)
	print("SHOT ", path, " · rows ", popup.row_labels())


func _shot(step: String, note: String) -> void:
	await _frames(12)
	await RenderingServer.frame_post_draw
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	root.get_texture().get_image().save_png(path)
	print("SHOT ", path, " · ", note)


## What `window` shows: its own texture, or its part of the window it is
## embedded in.
func _image(window: Window) -> Image:
	if not window.is_embedded():
		return window.get_texture().get_image()
	var whole: Image = root.get_texture().get_image()
	return whole.get_region(Rect2i(window.position, window.size).intersection(Rect2i(Vector2i.ZERO, whole.get_size())))


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
