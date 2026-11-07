extends Node
## Capture of the minimap's marks (M7.6 P3 step B): a diff with its hunks
## collapsed (the strip beside the preview), in both themes, then the
## resolver on a file with three conflict blocks after the first is chosen.
## Each shot is followed by a 3x crop of the minimap column. Pass
## --repo=<throwaway repo with a change spread through a long file>
## --file=<its path> --conflict-repo=<throwaway repo in a conflicted merge
## with three blocks in --conflict> --conflict=<path> --out=<directory>,
## with GITBELLO_CONFIG set to a scratch config, and launch windowed. It
## writes the conflicted file (the block choice): throwaway repos only.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000
const ZOOM: int = 3

var _out: String = ""
var _step: int = 1


func _ready() -> void:
	var args: Dictionary[String, String] = {}
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	for key: String in ["repo", "file", "conflict-repo", "conflict", "out"]:
		if not args.has(key):
			printerr("minimap_marks_screenshots: pass --repo --file --conflict-repo --conflict --out")
			get_tree().quit(2)
			return
	_out = args["out"]
	DirAccess.make_dir_recursive_absolute(_out)
	get_window().size = Vector2i(1400, 820)
	Actions.run_action(&"view.theme_dark")
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
	if not await _select(changes, args["file"]):
		return
	if not await _wait(func() -> bool: return diff.row_count() > 0):
		return
	await _shot("collapsed", diff)
	Actions.run_action(&"view.theme_light")
	await _shot("collapsed-light", diff)
	Actions.run_action(&"view.theme_dark")

	var conflict_page: RepoTab = main.open_repo(args["conflict-repo"])
	var conflict_session: RepoSession = conflict_page.session
	if not await _wait(func() -> bool: return conflict_session.is_ready() and conflict_session.change_count() > 0):
		return
	conflict_page.show_view(WorktreeView.View.CHANGES)
	var resolver: ChangesView = conflict_page.changes()
	var resolver_diff: DiffView = resolver.diff_view()
	if not await _select(resolver, args["conflict"]):
		return
	if not await _wait(func() -> bool: return resolver.has_conflict_blocks()):
		return
	await _shot("three-blocks", resolver_diff)
	var header: int = resolver_diff.find_block_header(0, true)
	resolver_diff.press_block(header, "ours")
	if not await _wait(func() -> bool: return resolver_diff.block_count == 2):
		return
	# Let the choice's highlight fade.
	await get_tree().create_timer(1.6).timeout
	await _shot("first-chosen", resolver_diff)
	Actions.run_action(&"view.theme_light")
	await _shot("first-chosen-light", resolver_diff)
	Actions.run_action(&"view.theme_dark")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _select(changes: ChangesView, path: String) -> bool:
	var list: ChangeList = changes.list()
	if not await _wait(func() -> bool:
		for i: int in list.row_count():
			if list.path_at(i) == path:
				return true
		return false):
		return false
	for i: int in list.row_count():
		if list.path_at(i) == path:
			list.grab_focus()
			list.select_only(i)
	return true


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("minimap_marks_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## The window, then the minimap column of `diff` at `ZOOM` times.
func _shot(file_name: String, diff: DiffView) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	image.save_png(path)
	print("SHOT ", path)
	var minimap: DiffMinimap = diff.minimap()
	var ui_scale: float = get_window().content_scale_factor
	var rect: Rect2 = minimap.get_global_rect()
	var pixels: Rect2i = Rect2i(Vector2i((rect.position * ui_scale).round()), Vector2i((rect.size * ui_scale).round()))
	var crop: Image = image.get_region(pixels.intersection(Rect2i(Vector2i.ZERO, image.get_size())))
	crop.resize(crop.get_width() * ZOOM, crop.get_height() * ZOOM, Image.INTERPOLATE_NEAREST)
	var crop_path: String = _out.path_join("%02d-%s-minimap.png" % [_step, file_name])
	crop.save_png(crop_path)
	print("SHOT ", crop_path)
	_step += 1
