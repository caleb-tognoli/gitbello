extends Node
## Capture of the added and removed colour settings and of History's strip
## of search matches (M7.6 P3 step C): Settings → Interface, a diff with the
## theme's colours and then with chosen ones, in both themes, and a search
## over a long history with its strip, followed by a 3x crop of the strip.
## Pass --repo=<throwaway repo with an uncommitted change to `--file`>
## --file=<its path> --history-repo=<throwaway repo with a long history>
## --query=<text matching some of its subjects> --out=<directory>, with
## GITBELLO_CONFIG set to a scratch config (it saves colours there), and
## launch windowed (read-only on the repositories).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000
const ADDED: String = "#2bb5a0"
const REMOVED: String = "#d2691e"
const ZOOM: int = 3

var _out: String = ""
var _step: int = 1
var _main: Main = null


func _ready() -> void:
	var args: Dictionary[String, String] = {}
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	for key: String in ["repo", "file", "history-repo", "query", "out"]:
		if not args.has(key):
			printerr("change_colors_screenshots: pass --repo --file --history-repo --query --out")
			get_tree().quit(2)
			return
	_out = args["out"]
	DirAccess.make_dir_recursive_absolute(_out)
	get_window().size = Vector2i(1400, 820)
	Core.set_settings({"added_color": "", "removed_color": ""})
	Actions.run_action(&"view.theme_dark")
	Core.set_diff_mode("text", "unified")
	_main = MAIN.instantiate() as Main
	add_child(_main)
	await get_tree().process_frame

	var page: RepoTab = _main.open_repo(args["repo"])
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() > 0):
		return
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var list: ChangeList = changes.list()
	if not await _wait(func() -> bool: return list.row_count() > 0):
		return
	for i: int in list.row_count():
		if list.path_at(i) == args["file"]:
			list.grab_focus()
			list.select_only(i)
	if not await _wait(func() -> bool: return changes.diff_view().row_count() > 0):
		return
	await _shot("diff-default")
	Actions.run_action(&"view.theme_light")
	await _shot("diff-default-light")
	Actions.run_action(&"view.theme_dark")

	var settings: SettingsWindow = _main.settings_window()
	Actions.run_action(&"app.settings")
	settings.show_category("Interface")
	await _window_shot("settings-default", settings)
	_set_colors(ADDED, REMOVED)
	await _window_shot("settings-chosen", settings)
	settings.hide()
	await _shot("diff-chosen")
	Actions.run_action(&"view.theme_light")
	await _shot("diff-chosen-light")
	Actions.run_action(&"view.theme_dark")
	_set_colors("", "")

	var history_page: RepoTab = _main.open_repo(args["history-repo"])
	var history_session: RepoSession = history_page.session
	if not await _wait(func() -> bool: return history_session.is_ready() and history_session.graph_row_count() > 0):
		return
	history_page.show_view(WorktreeView.View.HISTORY)
	var history: HistoryView = history_page.history()
	history.search_field().set_text(args["query"])
	if not await _wait(func() -> bool: return bool(history_session.search_info().get("done", false))):
		return
	var commits: CommitList = history.commit_list()
	await _shot("search", commits.match_strip())
	Actions.run_action(&"view.theme_light")
	await _shot("search-light", commits.match_strip())
	Actions.run_action(&"view.theme_dark")
	history.search_field().set_text("")
	while _main.tab_count() > 0:
		_main.close_tab(0)
	get_tree().quit(0)


## Picks the colours in Settings, as a user would; "" reverts them.
func _set_colors(added: String, removed: String) -> void:
	var settings: SettingsWindow = _main.settings_window()
	for entry: Array in [[&"added_color", added], [&"removed_color", removed]]:
		var key: StringName = entry[0]
		if String(entry[1]).is_empty():
			settings.get_revert_button(key).pressed.emit()
		else:
			var picker: ColorPickerButton = settings.get_control(key) as ColorPickerButton
			picker.color = Color(String(entry[1]))
			picker.color_changed.emit(picker.color)


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("change_colors_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## The main window, then `zoomed` (if any) at `ZOOM` times.
func _shot(file_name: String, zoomed: Control = null) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	image.save_png(path)
	print("SHOT ", path)
	if zoomed != null and zoomed.is_visible_in_tree():
		var ui_scale: float = get_window().content_scale_factor
		var rect: Rect2 = zoomed.get_global_rect()
		# The strip and the scroll bar beside it.
		rect = rect.grow_side(SIDE_RIGHT, 16.0)
		var pixels: Rect2i = Rect2i(Vector2i((rect.position * ui_scale).round()), Vector2i((rect.size * ui_scale).round()))
		var crop: Image = image.get_region(pixels.intersection(Rect2i(Vector2i.ZERO, image.get_size())))
		crop.resize(crop.get_width() * ZOOM, crop.get_height() * ZOOM, Image.INTERPOLATE_NEAREST)
		var crop_path: String = _out.path_join("%02d-%s-strip.png" % [_step, file_name])
		crop.save_png(crop_path)
		print("SHOT ", crop_path)
	_step += 1


## A window of its own (subwindows are not embedded).
func _window_shot(file_name: String, window: Window) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	window.get_texture().get_image().save_png(path)
	print("SHOT ", path)
	_step += 1
