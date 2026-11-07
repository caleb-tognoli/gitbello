extends Node
## Line endings in diffs (M7.9 P1), in numbered shots: the "Line endings"
## row unified and side by side, the "No newline at end of file" row both
## ways, the cards of endings-only, final-newline-only and both, Show diff,
## and History's card, then the same in the light theme, with 2x crops of
## the marker rows. P2: the list's `EOL` chips (2x crop), the "Line endings
## only" filter, the list menu with Restore line endings and the toast after
## restoring from the card (then undone). Pass --repo=<the CLI's `eol`
## fixture> --out=<directory> and set GITBELLO_CONFIG to a scratch config
## (it saves the text mode) before launching windowed. It restores a file
## and undoes it: throwaway fixtures only.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 60_000

var _out: String = ""
var _step: int = 1
var _main: Main = null


func _ready() -> void:
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or _out.is_empty():
		printerr("line_endings_screenshots: pass --repo=<eol fixture> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_main = MAIN.instantiate() as Main
	add_child(_main)
	await get_tree().process_frame
	var page: RepoTab = _main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() == 5):
		return
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var panel: DiffPanel = changes.diff_panel()
	for theme: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + theme))
		# Each theme starts with the cards (Show diff is kept per file).
		DiffPanel._eol_full.clear()
		panel.choose_mode("unified")
		if not await _select(changes, session, "edit.txt"):
			return
		if not await _wait(func() -> bool: return bool(changes.list().row(1).get("endings_only", false))):
			return
		await _shot("%s-endings-unified" % theme, panel)
		_save_crop(changes.list(), "%s-list-chips-2x" % theme)
		panel.choose_mode("split")
		await _shot("%s-endings-split" % theme, panel)
		if not await _select(changes, session, "tail.txt"):
			return
		await _shot("%s-no-newline-split" % theme, panel)
		panel.choose_mode("unified")
		await _shot("%s-no-newline-unified" % theme, panel)
		for path: String in ["crlf.txt", "nonl.txt", "both.txt"]:
			if not await _select(changes, session, path):
				return
			await _shot("%s-card-%s" % [theme, path.get_basename()], panel)
		panel.card_action.emit("eol_show_diff")
		await _shot("%s-show-diff" % theme, panel)
		# P2: the filter, the list menu, Restore line endings and its toast.
		var filter: FilterField = changes.filter_field()
		filter.set_option("endings_only", true)
		filter.options_button().pressed.emit()
		await _shot("%s-filter-endings-only" % theme, null, filter.menu())
		filter.menu().hide()
		filter.set_option("endings_only", false)
		if not await _select(changes, session, "crlf.txt"):
			return
		var row: int = changes.list().cursor
		changes.list().context_menu_requested.emit(row, Vector2(120.0, changes.list().row_height() * (row + 0.5)))
		await _shot("%s-list-menu" % theme, null, changes.context_menu())
		changes.context_menu().hide()
		if not await _select(changes, session, "both.txt"):
			return
		panel.card_action.emit("eol_restore")
		if not await _wait(func() -> bool: return session.change_count() == 4):
			return
		await _shot("%s-restored-toast" % theme, null)
		changes.undo_discard()
		if not await _wait(func() -> bool: return session.change_count() == 5):
			return
		page.show_view(WorktreeView.View.HISTORY)
		var commits: CommitList = page.history().commit_list()
		if not await _wait(func() -> bool: return commits.row_count() == 2):
			return
		commits.select_only(0)
		if not await _wait(func() -> bool: return String(session.commit_diff_info().get("state", "")) == "ready"):
			return
		await _shot("%s-history-card" % theme, null)
		page.show_view(WorktreeView.View.CHANGES)
	while _main.tab_count() > 0:
		_main.close_tab(0)
	get_tree().quit(0)


## Highlights `path` in Changes and waits for its diff.
func _select(changes: ChangesView, session: RepoSession, path: String) -> bool:
	var index: int = -1
	for row: int in changes.list().row_count():
		if changes.list().path_at(row) == path:
			index = row
	if index < 0:
		printerr("line_endings_screenshots: %s is not in Changes" % path)
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
			printerr("line_endings_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## The window, with `popup` (a separate window) drawn in where it shows,
## then with `panel` a 2x crop of the diff's last rows (where the marker rows
## are) when it shows lines.
func _shot(file_name: String, panel: DiffPanel, popup: Window = null) -> void:
	for frame: int in 20:
		await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	if popup != null and popup.visible:
		var menu: Image = popup.get_texture().get_image()
		menu.convert(image.get_format())
		image.blit_rect(menu, Rect2i(Vector2i.ZERO, menu.get_size()), popup.position - get_window().position)
	elif popup != null:
		printerr("line_endings_screenshots: %s: the menu did not open" % file_name)
	_save(image, file_name)
	if panel == null or panel.view().row_count() == 0:
		return
	var view: DiffView = panel.view()
	var rows: int = mini(view.row_count(), 4)
	var top: float = view.get_global_rect().position.y + view.row_height() * (view.row_count() - rows)
	var crop: Rect2i = Rect2i(Vector2i(int(view.get_global_rect().position.x), int(top)),
			Vector2i(int(view.size.x * 0.6), int(view.row_height() * rows)))
	var part: Image = image.get_region(crop)
	part.resize(part.get_width() * 2, part.get_height() * 2, Image.INTERPOLATE_NEAREST)
	_save(part, file_name + "-rows-2x", false)


## A 2x crop of `control` from the last shot's frame (unnumbered, after it).
func _save_crop(control: Control, file_name: String) -> void:
	var image: Image = get_viewport().get_texture().get_image()
	var part: Image = image.get_region(Rect2i(control.get_global_rect()))
	part.resize(part.get_width() * 2, part.get_height() * 2, Image.INTERPOLATE_NEAREST)
	_save(part, file_name, false)


func _save(image: Image, file_name: String, numbered: bool = true) -> void:
	var path: String = _out.path_join("%02d-%s.png" % [_step - (0 if numbered else 1), file_name])
	if numbered:
		_step += 1
	image.save_png(path)
	print("SHOT ", path)
