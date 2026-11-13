extends Node
## Comparison sheet of the changed-word tint (M7.6 P3 step B): the same diff
## and its minimap at several `AppTheme.word_tint_percent` values, in both
## themes. Each intensity is saved as `<theme>-<percent>.png` (the top of the
## diff with the top of its minimap column beside it, `ZOOM` times larger),
## and a sheet per theme stacks
## them top to bottom in `PERCENTS` order; `<theme>-selection.png` adds the
## kept tint with rows from the context through the changes selected. Pass --repo=<throwaway repo with
## word-level changes to `--file`> --file=<its path> --out=<directory>, with
## GITBELLO_CONFIG set to a scratch config, and launch windowed (read-only).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000
const PERCENTS: Array[int] = [30, 40, 50, 60]
## Height of the diff shown for each intensity, in UI pixels.
const CROP_HEIGHT: float = 260.0
## Width of the diff text kept left of the minimap column, in UI pixels.
const TEXT_WIDTH: float = 640.0
## How much the minimap column is enlarged.
const ZOOM: int = 3
## The rows selected for the selection shot.
const SELECTED: Vector2i = Vector2i(3, 9)

var _out: String = ""


func _ready() -> void:
	var args: Dictionary[String, String] = {}
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	for key: String in ["repo", "file", "out"]:
		if not args.has(key):
			printerr("word_tint_sheet: pass --repo --file --out")
			get_tree().quit(2)
			return
	_out = args["out"]
	DirAccess.make_dir_recursive_absolute(_out)
	get_window().size = Vector2i(1400, 820)
	if not Core.diff_minimap():
		Actions.run_action(&"diff.toggle_minimap")
	Core.set_diff_mode("text", "unified")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame

	var page: RepoTab = main.open_repo(args["repo"])
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() > 0):
		return
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var diff: DiffView = changes.diff_view()
	var list: ChangeList = changes.list()
	if not await _wait(func() -> bool: return list.row_count() > 0):
		return
	for i: int in list.row_count():
		if list.path_at(i) == args["file"]:
			list.grab_focus()
			list.select_only(i)
	if not await _wait(func() -> bool: return diff.row_count() > 0):
		return

	var kept: int = AppTheme.word_tint_percent
	for theme_name: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + theme_name))
		var crops: Array[Image] = []
		for percent: int in PERCENTS:
			AppTheme.word_tint_percent = percent
			ThemeManager.apply(main)
			for frame: int in 30:
				await get_tree().process_frame
			var crop: Image = _crop(diff)
			crop.save_png(_out.path_join("%s-%d.png" % [theme_name, percent]))
			crops.append(crop)
		var sheet: Image = Image.create_empty(crops[0].get_width(), crops[0].get_height() * crops.size(),
				false, Image.FORMAT_RGBA8)
		for i: int in crops.size():
			sheet.blit_rect(crops[i], Rect2i(Vector2i.ZERO, crops[i].get_size()),
					Vector2i(0, i * crops[0].get_height()))
		var path: String = _out.path_join("sheet-%s.png" % theme_name)
		sheet.save_png(path)
		print("SHOT ", path)
		AppTheme.word_tint_percent = kept
		ThemeManager.apply(main)
		diff.select_lines(SELECTED.x, SELECTED.y)
		for frame: int in 30:
			await get_tree().process_frame
		path = _out.path_join("%s-selection.png" % theme_name)
		_crop(diff).save_png(path)
		print("SHOT ", path)
		diff.clear_selection()
	AppTheme.word_tint_percent = kept
	ThemeManager.apply(main)
	Actions.run_action(&"view.theme_dark")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


## The top of `diff`'s text, `TEXT_WIDTH` wide, with the top of its minimap
## column joined on the right, `ZOOM` times larger.
func _crop(diff: DiffView) -> Image:
	var image: Image = get_viewport().get_texture().get_image()
	var ui_scale: float = get_window().content_scale_factor
	var rect: Rect2 = diff.get_global_rect()
	var column: Rect2 = diff.minimap().get_global_rect()
	var height: int = roundi(minf(CROP_HEIGHT, rect.size.y) * ui_scale)
	var text: Image = image.get_region(Rect2i(Vector2i((rect.position * ui_scale).round()),
			Vector2i(roundi(TEXT_WIDTH * ui_scale), height)))
	var side: Image = image.get_region(Rect2i(Vector2i((column.position * ui_scale).round()),
			Vector2i(roundi(column.size.x * ui_scale), floori(height / float(ZOOM)))))
	side.resize(side.get_width() * ZOOM, side.get_height() * ZOOM, Image.INTERPOLATE_NEAREST)
	var out: Image = Image.create_empty(text.get_width() + side.get_width(), height, false, Image.FORMAT_RGBA8)
	out.fill(Color.BLACK)
	out.blit_rect(text, Rect2i(Vector2i.ZERO, text.get_size()), Vector2i.ZERO)
	out.blit_rect(side, Rect2i(Vector2i.ZERO, side.get_size()), Vector2i(text.get_width(), 0))
	return out


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("word_tint_sheet: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true
