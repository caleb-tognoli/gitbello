extends Node
## Syntax sheet (M7.13): every changed file of the `syntax` fixture
## (`gitbello-cli fixture <dir> --syntax`) shown in Changes, unified, in
## both themes. Each file is saved as `<theme>/<NN>-<folder>.png`: the top of
## its diff with the minimap column beside it, and a long diff's end as
## `<NN>-<folder>-end.png`, once its line states are found. Pass --repo=<the fixture's
## syntax repo> --out=<directory>, with GITBELLO_CONFIG set to a scratch
## config, and launch windowed (read-only).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000
## Height of the diff kept, in UI pixels.
const CROP_HEIGHT: float = 640.0
## Width of the diff text kept left of the minimap column, in UI pixels.
const TEXT_WIDTH: float = 760.0

var _out: String = ""


func _ready() -> void:
	var args: Dictionary[String, String] = {}
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	for key: String in ["repo", "out"]:
		if not args.has(key):
			printerr("syntax_sheet: pass --repo --out")
			get_tree().quit(2)
			return
	_out = args["out"]
	get_window().size = Vector2i(1400, 900)
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
	for theme_name: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + theme_name))
		DirAccess.make_dir_recursive_absolute(_out.path_join(theme_name))
		for i: int in list.row_count():
			var path: String = list.path_at(i)
			list.grab_focus()
			list.select_only(i)
			var loaded: Callable = func() -> bool:
				var info: Dictionary = session.diff_info()
				# The line states too (P5a), or the shot shows lines lexed alone.
				return (String(info.get("path", "")) == path and String(info.get("state", "")) == "ready"
						and diff.row_count() > 0 and String(info.get("states", "")) != "loading")
			if not await _wait(loaded):
				return
			for frame: int in 20:
				await get_tree().process_frame
			var folder: String = path.get_base_dir() if not path.get_base_dir().is_empty() else path
			var file: String = _out.path_join(theme_name).path_join("%02d-%s.png" % [i + 1, folder.replace("/", "-")])
			_crop(diff).save_png(file)
			print("SHOT %s (%s, language %s)" % [file, path, session.diff_info().get("language", "")])
			# The end of a long diff too: the samples' multi-line cases are there.
			if diff.max_scroll_offset() + diff.size.y > CROP_HEIGHT:
				diff.set_scroll_offset(diff.max_scroll_offset())
				for frame: int in 10:
					await get_tree().process_frame
				var end_file: String = file.get_basename() + "-end.png"
				_crop(diff, true).save_png(end_file)
				print("SHOT %s (%s, end)" % [end_file, path])
	Actions.run_action(&"view.theme_dark")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


## The top `CROP_HEIGHT` of `diff`'s text (the bottom with `bottom`),
## `TEXT_WIDTH` wide, with its minimap column joined on the right.
func _crop(diff: DiffView, bottom: bool = false) -> Image:
	var image: Image = get_viewport().get_texture().get_image()
	var ui_scale: float = get_window().content_scale_factor
	var rect: Rect2 = diff.get_global_rect()
	var column: Rect2 = diff.minimap().get_global_rect()
	var height: int = roundi(minf(CROP_HEIGHT, rect.size.y) * ui_scale)
	var top: float = maxf(0.0, rect.size.y - CROP_HEIGHT) if bottom else 0.0
	var text: Image = image.get_region(Rect2i(Vector2i(((rect.position + Vector2(0.0, top)) * ui_scale).round()),
			Vector2i(roundi(minf(TEXT_WIDTH, rect.size.x) * ui_scale), height)))
	var side: Image = image.get_region(Rect2i(Vector2i(((column.position + Vector2(0.0, top)) * ui_scale).round()),
			Vector2i(roundi(column.size.x * ui_scale), height)))
	var out: Image = Image.create_empty(text.get_width() + side.get_width(), height, false, Image.FORMAT_RGBA8)
	out.fill(Color.BLACK)
	out.blit_rect(text, Rect2i(Vector2i.ZERO, text.get_size()), Vector2i.ZERO)
	out.blit_rect(side, Rect2i(Vector2i.ZERO, side.get_size()), Vector2i(text.get_width(), 0))
	return out


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("syntax_sheet: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true
