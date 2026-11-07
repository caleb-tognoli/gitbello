extends Node
## Open in the default app (M7.8 P3), in numbered shots with the menus
## drawn in: the Changes list's and a text diff's menus, an image side's, a
## History file's, Home's row menu and "No local changes" without Open in
## editor, and Settings without Editor.
## Nothing is opened. Pass --fixtures=<CLI fixture dir with repo-1 and the
## images fixtures> --clean=<a repository without changes> --out=<directory>
## and set GITBELLO_CONFIG to a scratch config (with its library) before
## launching windowed (read-only on the repositories).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 60_000

var _out: String = ""
var _step: int = 1
var _main: Main = null


func _ready() -> void:
	var fixtures: String = ""
	var clean: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--fixtures="):
			fixtures = arg.trim_prefix("--fixtures=")
		elif arg.begins_with("--clean="):
			clean = arg.trim_prefix("--clean=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if fixtures.is_empty() or clean.is_empty() or _out.is_empty():
		printerr("open_screenshots: pass --fixtures=<dir> --clean=<repo> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	RepoOps.opener = func(_path: String) -> Error: return OK
	_main = MAIN.instantiate() as Main
	add_child(_main)
	await get_tree().process_frame
	Actions.run_action(&"view.theme_dark")

	# Changes: the list's menu on an image, then the image's side menu.
	var page: RepoTab = _main.open_repo(fixtures.path_join("images"))
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() >= 6):
		return
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	if not await _select(changes, session, "logo.png"):
		return
	var images: ImageDiffView = changes.diff_panel().image_view()
	if not await _wait(func() -> bool: return images.texture(ImageDiffView.OLD) != null and images.texture(ImageDiffView.NEW) != null):
		return
	var list: VirtualList = changes.list()
	list.context_menu_requested.emit(list.cursor, Vector2(120, list.row_height() * (list.cursor + 0.5)))
	await _shot("changes-list-menu", changes.context_menu())
	changes.context_menu().hide()
	_right_click(images, images.side_rect(ImageDiffView.OLD).get_center())
	await _shot("image-old-side-menu", changes.diff_panel().image_menu())
	changes.diff_panel().image_menu().hide()

	# History: a commit file's menu.
	page.show_view(WorktreeView.View.HISTORY)
	var details: CommitDetails = page.history().details()
	var commits: CommitList = page.history().commit_list()
	if not await _wait(func() -> bool: return commits.row_count() >= 2):
		return
	commits.select_only(0)
	if not await _wait(func() -> bool: return String(session.commit_diff_info().get("state", "")) == "ready"):
		return
	for frame: int in 10:
		await get_tree().process_frame
	details.files().context_menu_requested.emit(0, Vector2(80, details.files().row_height() * 0.5))
	await _shot("history-file-menu", details.file_menu())
	details.file_menu().hide()

	# A text diff's menu, in repo-1's Changes.
	var text_page: RepoTab = _main.open_repo(fixtures.path_join("repo-1"))
	var text_session: RepoSession = text_page.session
	if not await _wait(func() -> bool: return text_session.is_ready() and text_session.change_count() > 0):
		return
	text_page.show_view(WorktreeView.View.CHANGES)
	var text_changes: ChangesView = text_page.changes()
	text_changes.list().select_only(0)
	var diff: DiffView = text_changes.diff_panel().view()
	if not await _wait(func() -> bool: return diff.row_count() > 0):
		return
	diff.context_menu_requested.emit(2, Vector2(300, diff.row_height() * 2.5))
	await _shot("changes-diff-menu", text_changes.context_menu())
	text_changes.context_menu().hide()

	# A repository without changes: "No local changes" has no Open in editor.
	var clean_page: RepoTab = _main.open_repo(clean)
	if not await _wait(func() -> bool: return clean_page.session.is_ready() and clean_page.session.change_count() == 0):
		return
	clean_page.show_view(WorktreeView.View.CHANGES)
	await _shot("no-local-changes", null)

	# Home's row menu.
	_main.open_home()
	await get_tree().process_frame
	var home: Home = _main.home()
	if not await _wait(func() -> bool: return not home.listed().is_empty()):
		return
	var row: Control = home.row_for(home.listed()[0])
	_right_click(row, Vector2(200, 12))
	await _shot("home-row-menu", home.row_menu())
	home.row_menu().hide()

	# Settings, General.
	_main.settings_window().open()
	await _shot_window("settings-general", _main.settings_window())
	_main.settings_window().hide()

	while _main.tab_count() > 0:
		_main.close_tab(0)
	get_tree().quit(0)


func _right_click(control: Control, at: Vector2) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.pressed = true
	event.position = at
	event.global_position = control.get_global_transform_with_canvas() * at
	if control.gui_input.get_connections().is_empty():
		control._gui_input(event)
	else:
		control.gui_input.emit(event)


## Highlights `path` in Changes and waits for its diff.
func _select(changes: ChangesView, session: RepoSession, path: String) -> bool:
	var index: int = -1
	for row: int in changes.list().row_count():
		if changes.list().path_at(row) == path:
			index = row
	if index < 0:
		printerr("open_screenshots: %s is not in Changes" % path)
		get_tree().quit(1)
		return false
	changes.list().select_only(index)
	return await _wait(func() -> bool:
		var info: Dictionary = session.diff_info()
		return String(info.get("path", "")) == path and String(info.get("state", "")) == "ready")


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("open_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## The window, with `popup` (a separate window) drawn in where it shows.
func _shot(file_name: String, popup: Window) -> void:
	for frame: int in 20:
		await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	if popup != null and popup.visible:
		var menu: Image = popup.get_texture().get_image()
		menu.convert(image.get_format())
		var at: Vector2i = popup.position - get_window().position
		image.blit_rect(menu, Rect2i(Vector2i.ZERO, menu.get_size()), at)
	elif popup != null:
		printerr("open_screenshots: %s: the menu did not open" % file_name)
	_save(image, file_name)


func _shot_window(file_name: String, window: Window) -> void:
	for frame: int in 20:
		await get_tree().process_frame
	_save(window.get_texture().get_image(), file_name)


func _save(image: Image, file_name: String) -> void:
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	_step += 1
	image.save_png(path)
	print("SHOT ", path)
