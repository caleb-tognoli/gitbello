extends Node
## Numbered screenshots of the scrolling chip rows (`ScrollRow`), each with a
## 2x crop of the row: the worktree strip and header at full width, then in a
## narrow window at the start (› only), with › hovered, after ›, halfway
## (both arrows) and at the end (‹ only), in the light theme; then Ignore rules with more files
## than fit, at the start and scrolled.
## Usage: godot --path godot res://tests/visual/scroll_row_screenshots.tscn --
##        --repo=<throwaway repo with many worktrees>
##        --ignore-repo=<throwaway repo with many .gitignore files> --out=<dir>
## Run with GITBELLO_CONFIG pointing at a scratch config file. Read-only.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000

var _out: String = ""
var _step: int = 0


func _ready() -> void:
	DisplayServer.window_set_position(Vector2i(-10000, -10000))
	var repo: String = ""
	var ignore_repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--ignore-repo="):
			ignore_repo = arg.trim_prefix("--ignore-repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or ignore_repo.is_empty() or _out.is_empty():
		printerr("scroll_row_screenshots: pass -- --repo=<path> --ignore-repo=<path> --out=<dir>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().root.gui_embed_subwindows = true
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	get_window().size = Vector2i(1280, 720)
	Actions.run_action(&"view.theme_dark")
	var page: RepoTab = main.open_repo(repo)
	await _wait(func() -> bool: return page.worktrees().size() > 1)
	var strip: WorktreeStrip = page.strip()
	var row: ScrollRow = strip.scroll_row()
	await _shot("wide", strip, 2.6)

	get_window().size = Vector2i(760, 720)
	await _settle()
	row.scroll_to(0, false)
	await _shot("narrow-start", strip, 2.0)
	await _hover(row.right_arrow())
	await _shot("narrow-hover-right", strip, 2.0)
	_move_mouse(Vector2(380, 600))
	row.step(1)
	await _shot("narrow-after-right", strip, 2.0)
	var bar: HScrollBar = row.scroll_container().get_h_scroll_bar()
	row.scroll_to(roundi((bar.max_value - bar.page) / 2.0), false)
	await _shot("narrow-middle", strip, 2.0)
	for i: int in 20:
		row.step(1, false)
	await _shot("narrow-end", strip, 2.0)
	Actions.run_action(&"view.theme_light")
	row.scroll_to(roundi((bar.max_value - bar.page) / 2.0), false)
	await _shot("narrow-light", strip, 2.0)
	Actions.run_action(&"view.theme_dark")

	get_window().size = Vector2i(1280, 720)
	var ignore_page: RepoTab = main.open_repo(ignore_repo)
	await _wait(func() -> bool: return ignore_page.worktrees().size() >= 1)
	await _settle()
	Actions.run_action(&"repo.ignore_rules")
	var dialog: IgnoreRulesDialog = main.ignore_rules_dialog()
	await _wait(func() -> bool: return dialog.sources().size() >= 6)
	dialog.size = Vector2i(700, 460)
	dialog.position = Vector2i(40, 40)
	await _shot("ignore-start", null, 1.0)
	var chips: ScrollRow = dialog.chip_row()
	chips.step(1)
	await _shot("ignore-after-right", null, 1.0)
	dialog.select_source(dialog.sources().size() - 1)
	await _shot("ignore-last-chosen", null, 1.0)
	dialog.hide()
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _wait(done: Callable) -> void:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and not bool(done.call()):
		await get_tree().process_frame


func _hover(control: Control) -> void:
	_move_mouse(control.get_global_rect().get_center())
	var until: int = Time.get_ticks_msec() + 800
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _move_mouse(at: Vector2) -> void:
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_viewport().push_input(motion)


func _settle() -> void:
	for i: int in 30:
		await get_tree().process_frame


## Saves the window, and a crop of the rows from the top of the window to
## the bottom of `strip`'s header row, scaled by `scale`.
func _shot(file_name: String, strip: Control, scale: float) -> void:
	await _settle()
	_step += 1
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	image.save_png(path)
	print("SHOT ", path)
	if strip == null:
		return
	# The strip and the Changes | History row under it.
	var bottom: int = mini(image.get_height(), int(strip.get_global_rect().end.y) + 56)
	var crop: Image = image.get_region(Rect2i(0, 0, image.get_width(), bottom))
	crop.resize(roundi(crop.get_width() * scale), roundi(crop.get_height() * scale), Image.INTERPOLATE_NEAREST)
	var crop_path: String = _out.path_join("%02d-%s-crop.png" % [_step, file_name])
	crop.save_png(crop_path)
	print("SHOT ", crop_path)
