extends Node
## Captures Blame (PLAN M8b) in numbered shots: a focused commit in the
## middle of the file, dark then light; then, dark: the working copy
## without a focus, a focused commit's details, the blame's menu, the
## options, Blame before this commit (the version under the old name),
## Show changes (Blame off), the files' menu in Changes and the
## minimum window width. Pass --repo=<a repository built by
## tests/visual/blame_prep.sh> --out=<directory> and launch windowed with
## GITBELLO_CONFIG set to a scratch file (read-only on the repository).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000
const FILE: String = "src/server/session.rs"
## The line whose commit the shots focus (0-based): "Refresh a session…".
const FOCUS_LINE: int = 32

var _out: String = ""
var _step: int = 1


func _ready() -> void:
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or _out.is_empty():
		printerr("blame_screenshots: pass --repo=<blame_prep.sh repository> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_window().size = Vector2i(1400, 860)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready()):
		return
	var worktree: WorktreeView = page.active_view()
	var view: FileView = worktree.file_view()
	var list: FileHistoryList = view.version_list()
	var blame: BlameView = view.blame_view()
	worktree.open_file_history(FILE, "", "", true)
	if not await _blamed(session, view) or not await _wait(func() -> bool:
			return not bool(session.file_history_info().get("loading", true))):
		return
	for mode: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + mode))
		if view.blame_focus().is_empty():
			_click_gutter(blame, FOCUS_LINE)
			if not await _wait(func() -> bool: return view.details_header().visible):
				return
		# The focused lines in the middle, a run cut by the top row.
		blame.set_scroll_offset((FOCUS_LINE - 14) * blame.row_height())
		await _shot("focused-%s" % mode)
	Actions.run_action(&"view.theme_dark")
	# The working copy, nothing focused.
	blame.set_scroll_offset(0.0)
	_click_gutter(blame, FOCUS_LINE)
	if not await _wait(func() -> bool: return view.blame_focus().is_empty()):
		return
	await _shot("working-copy")
	# A commit with a message body, focused from its line.
	_click_gutter(blame, 20)
	if not await _wait(func() -> bool: return view.details_header().visible and view.details_header().has_body()):
		return
	await _shot("focused-commit")
	blame.context_menu_requested.emit(20, Vector2(420.0, blame.row_top(6) + 10.0))
	await _shot("menu", view.blame_menu())
	view.blame_menu().hide()
	view.blame_options_button().pressed.emit()
	await _shot("options", view.blame_options_menu())
	view.blame_options_menu().hide()
	# Before the commit that moved the file: the version under its old name.
	blame.go_to_line(0)
	Actions.run_action(&"blame.before")
	if not await _wait(func() -> bool: return String(session.blame_info().get("path", "")) != FILE) \
			or not await _blamed(session, view):
		return
	await _shot("before-the-rename")
	# Blame off, on the line's commit.
	Actions.run_action(&"blame.show_changes")
	if not await _wait(func() -> bool: return view.diff_panel().view().row_count() > 0):
		return
	await _shot("show-changes")
	# The ways in.
	worktree.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	if not await _wait(func() -> bool: return session.change_count() >= 1):
		return
	changes.list().select_only(0)
	changes.list().context_menu_requested.emit(0, Vector2(140, 12))
	await _shot("changes-menu", changes.context_menu())
	changes.context_menu().hide()
	Actions.run_action(&"file_history.blame")
	list.select_only(0)
	if not await _blamed(session, view):
		return
	get_window().size = get_window().min_size
	await _shot("minimum-width")
	get_tree().quit()


## The blame ended and the view shows all of its lines.
func _blamed(session: RepoSession, view: FileView) -> bool:
	await get_tree().process_frame
	return await _wait(func() -> bool:
		var info: Dictionary = session.blame_info()
		return bool(info.get("open", false)) and String(info.get("state", "")) == "done" \
				and view.blame_view().visible and view.blame_view().row_count() == int(info["lines"]))


func _click_gutter(blame: BlameView, row: int) -> void:
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(20.0, blame.row_top(row) + blame.row_height() * 0.5 - blame.scroll_offset())
	blame._gui_input(click)


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not predicate.call():
		if Time.get_ticks_msec() > deadline:
			printerr("blame_screenshots: timed out at step %d" % _step)
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


func _shot(file_name: String, popup: Window = null) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	if popup != null and popup.visible:
		var menu: Image = popup.get_texture().get_image()
		menu.convert(image.get_format())
		var at: Vector2i = popup.position - get_window().position
		image.blit_rect(menu, Rect2i(Vector2i.ZERO, menu.get_size()), at)
	elif popup != null:
		printerr("blame_screenshots: %s: the popup did not open" % file_name)
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	_step += 1
	image.save_png(path)
	print("SHOT ", path)
