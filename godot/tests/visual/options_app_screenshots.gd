extends Node
## M7.15 in the app, numbered, dark then light: Changes' options (at
## their defaults, then two filters on with the count and Clear), History's
## (then All branches and Compact chosen), File history's rows, and Blame's
## with an option on and its count. Then, dark: the shelves' branch filter
## (all, then one branch off with the count), a chip focused from the
## keyboard, a hovered segment's tooltip with its shortcut, Changes' and
## History's in Italian, and History's at the minimum window size. Each
## popover shot has a 2x crop of the popover and the button under it. Popups
## are embedded in the window so nothing opens beside it. It saves the rows,
## the graph and the blame options: throwaway fixtures and a scratch
## `GITBELLO_CONFIG` only.
##
##   --fixtures=<dir of `gitbello-cli fixture <dir> --repos 1 --history`,
##   its history repo prepared by tests/visual/options_app_prep.sh> --out=<dir>

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const FILE: String = "src/login/auth.rs"
const WAIT_MS: int = 30_000

var _out: String = ""
var _step: int = 0


func _ready() -> void:
	DisplayServer.window_set_position(Vector2i(-10000, -10000))
	var fixtures: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--fixtures="):
			fixtures = arg.trim_prefix("--fixtures=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if fixtures.is_empty() or _out.is_empty() or OS.get_environment("GITBELLO_CONFIG").is_empty():
		printerr("options_app_screenshots: pass --fixtures=<dir> --out=<dir> with GITBELLO_CONFIG set")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_viewport().gui_embed_subwindows = true
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	# The shell may place the window: off the screen again.
	DisplayServer.window_set_position(Vector2i(-10000, -10000))
	get_window().size = Vector2i(1280, 800)
	Core.set_history_compact(false)
	Core.set_blame_ignore_whitespace(false)
	Core.set_blame_detect_moves(false)
	var page: RepoTab = main.open_repo(fixtures.path_join("history"))
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() >= 1):
		return
	for theme: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + theme))
		# Changes: the filters.
		page.show_view(WorktreeView.View.CHANGES)
		var filter: FilterField = page.changes().filter_field()
		filter.open_options()
		await _shot("%s-changes-options" % theme, filter.options_popover())
		filter.set_option("modified", true)
		filter.set_option("included", true)
		filter.open_options()
		await _shot("%s-changes-filters-on" % theme, filter.options_popover())
		filter.options_popover().hide()
		await _shot("%s-changes-badge" % theme, null)
		filter.clear_filters()
		# History: branches, rows and the graph.
		page.show_view(WorktreeView.View.HISTORY)
		var history: HistoryView = page.history()
		if not await _wait(func() -> bool: return history.commit_list().row_count() > 0):
			return
		history.scope_button().pressed.emit()
		await _shot("%s-history-options" % theme, history.options_popover())
		(history.options_popover().control("rows") as SegmentedControl).choice_button("compact").pressed.emit()
		(history.options_popover().control("scope") as SegmentedControl).choice_button("all").pressed.emit()
		await _shot("%s-history-all-compact" % theme, history.options_popover())
		history.options_popover().hide()
		Actions.run_action(&"history.detailed_rows")
		Actions.run_action(&"history.current_branch")
		# File history: the rows; then Blame and its options.
		page.show_view(WorktreeView.View.CHANGES)
		var changes: ChangesView = page.changes()
		for row: int in changes.list().row_count():
			if changes.list().path_at(row) == FILE:
				changes.list().select_only(row)
		if not await _wait(func() -> bool: return String(session.diff_info().get("path", "")) == FILE):
			return
		Actions.run_action(&"file_history.open")
		var view: FileView = page.active_view().file_view()
		if not await _wait(func() -> bool: return view.version_list().row_count() > 1):
			return
		view.options_button().pressed.emit()
		await _shot("%s-file-history-options" % theme, view.options_popover())
		view.options_popover().hide()
		Actions.run_action(&"file_history.blame")
		if not await _wait(func() -> bool: return view.is_blame() and not view.blame_status_text().is_empty()):
			return
		Actions.run_action(&"blame.toggle_ignore_whitespace")
		view.blame_options_button().pressed.emit()
		await _shot("%s-blame-options-on" % theme, view.blame_options_popover())
		view.blame_options_popover().hide()
		Actions.run_action(&"blame.toggle_ignore_whitespace")
		Actions.run_action(&"file_history.blame")
	Actions.run_action(&"view.theme_dark")
	# Shelves: the branch filter, all branches, then one left out.
	page.show_view(WorktreeView.View.SHELVES)
	var shelves: ShelfList = page.changes().shelf_list()
	if not await _wait(func() -> bool: return shelves.shelf_count() >= 3):
		return
	shelves.open_branches()
	await _shot("dark-shelf-branches", shelves.branch_picker())
	shelves.branch_check("spike").button_pressed = false
	await _shot("dark-shelf-branches-one-off", shelves.branch_picker())
	shelves.branch_picker().hide()
	Actions.run_action(&"shelf.scope_all")
	# Changes: Alt+Down from the field, then a chip focused from the keyboard.
	page.show_view(WorktreeView.View.CHANGES)
	var field: FilterField = page.changes().filter_field()
	field.focus_text()
	await get_tree().process_frame
	Actions.run_action(&"view.options")
	await get_tree().process_frame
	field.options_popover().control("deleted").grab_focus()
	await _shot("dark-changes-chip-focused", field.options_popover())
	field.options_popover().hide()
	# History: a hovered segment's tooltip names its shortcut.
	page.show_view(WorktreeView.View.HISTORY)
	var history_view: HistoryView = page.history()
	history_view.scope_button().pressed.emit()
	var popover: OptionsPopover = history_view.options_popover()
	await _hover(popover, (popover.control("rows") as SegmentedControl).choice_button("compact"))
	await _shot("dark-history-tooltip", null)
	popover.hide()
	# Italian.
	TranslationServer.set_locale("it")
	page.show_view(WorktreeView.View.CHANGES)
	field.set_option("new", true)
	field.open_options()
	await _shot("dark-it-changes-options", field.options_popover())
	field.options_popover().hide()
	field.clear_filters()
	page.show_view(WorktreeView.View.HISTORY)
	history_view.scope_button().pressed.emit()
	await _shot("dark-it-history-options", history_view.options_popover())
	history_view.options_popover().hide()
	TranslationServer.set_locale("en")
	# The minimum window size.
	get_window().size = Main.MIN_WINDOW_SIZE
	await get_tree().process_frame
	history_view.scope_button().pressed.emit()
	await _shot("dark-min-width-history-options", history_view.options_popover())
	history_view.options_popover().hide()
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("options_app_screenshots: timed out at step %d" % (_step + 1))
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## Rests the pointer on `control` inside the embedded `popover` until its
## tooltip shows.
func _hover(popover: Window, control: Control) -> void:
	for frame: int in 10:
		await get_tree().process_frame
	_move_mouse(Vector2(popover.position) + control.get_global_rect().get_center() + Vector2(0, 40))
	for frame: int in 5:
		await get_tree().process_frame
	_move_mouse(Vector2(popover.position) + control.get_global_rect().get_center())
	var until: int = Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _move_mouse(at: Vector2) -> void:
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_viewport().push_input(motion)


## The window, then a 2x crop of `popover` with the row above it (its button).
func _shot(shot_name: String, popover: Window) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	_step += 1
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = _out.path_join("%02d-%s.png" % [_step, shot_name])
	image.save_png(path)
	print("SHOT ", path)
	if popover != null and popover.visible:
		var rect: Rect2i = Rect2i(popover.position - Vector2i(160, 44), popover.size + Vector2i(176, 52)) \
				.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
		var crop: Image = image.get_region(rect)
		crop.resize(rect.size.x * 2, rect.size.y * 2, Image.INTERPOLATE_NEAREST)
		crop.save_png(_out.path_join("%02d-%s-crop.png" % [_step, shot_name]))
