extends Node
## The image viewer's zoom (M7.8), in numbered shots driven by the viewer's
## input: a small image fitted by whole steps (with a 2x crop of the zoom
## bar), the wheel out to 100% and in at a corner, dragged as far as it goes
## both ways, a double-click back to fitted, onion skin with the bar and the
## slider, a large image fitted, Zoom out stopping there, Actual size, and
## fitted again in the light theme. Pass --fixtures=<dir with the CLI's
## `images`> --out=<directory> and set GITBELLO_CONFIG to a scratch config
## before launching windowed. It saves the image mode: throwaway fixtures
## only.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 60_000

var _out: String = ""
var _step: int = 1


func _ready() -> void:
	var fixtures: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--fixtures="):
			fixtures = arg.trim_prefix("--fixtures=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if fixtures.is_empty() or _out.is_empty():
		printerr("image_zoom_screenshots: pass --fixtures=<dir> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	Core.set_diff_mode("image", "split")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	Actions.run_action(&"view.theme_dark")
	var page: RepoTab = main.open_repo(fixtures.path_join("images"))
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() >= 6):
		return
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var panel: DiffPanel = changes.diff_panel()
	var images: ImageDiffView = panel.image_view()
	if not await _select(changes, session, "logo.png", images):
		return
	await _shot("fitted-small", images, true)
	for notch: int in 12:
		_wheel(images, MOUSE_BUTTON_WHEEL_DOWN, images.size / 2.0)
	await _shot("wheel-out-stops-at-100", images)
	var corner: Vector2 = images.side_rect(ImageDiffView.NEW).position + Vector2(4, 4)
	for notch: int in 8:
		_wheel(images, MOUSE_BUTTON_WHEEL_UP, corner)
	await _shot("wheel-in-at-new-top-left", images, true)
	_drag(images, Vector2(5000, 5000))
	await _shot("dragged-right-down-stops", images)
	_drag(images, Vector2(-10000, -10000))
	await _shot("dragged-left-up-stops", images)
	_double_click(images, images.size / 2.0)
	await _shot("double-click-fits", images)
	panel.choose_mode("onion")
	await _shot("onion-fitted", images)
	panel.choose_mode("split")
	if not await _select(changes, session, "huge.png", images, false):
		return
	(panel.find_child("LoadAnywayButton", true, false) as Button).pressed.emit()
	if not await _wait(func() -> bool: return images.is_visible_in_tree() and images.texture(ImageDiffView.NEW) != null):
		return
	await _shot("large-fitted", images, true)
	Actions.run_action(&"image.zoom_out")
	await _shot("zoom-out-stays-fitted", images, true)
	Actions.run_action(&"image.zoom_actual")
	await _shot("actual-size", images, true)
	_drag(images, Vector2(-100000, -100000))
	await _shot("actual-size-dragged-to-corner", images)
	Actions.run_action(&"view.theme_light")
	if not await _select(changes, session, "logo.png", images):
		return
	await _shot("light-fitted-small", images, true)
	Actions.run_action(&"view.theme_dark")
	Core.set_diff_mode("image", "split")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _wheel(images: ImageDiffView, index: MouseButton, at: Vector2) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = index
	event.pressed = true
	event.position = at
	event.factor = 1.0
	images._gui_input(event)


## A left-button drag by `by` from the view's centre, in steps.
func _drag(images: ImageDiffView, by: Vector2) -> void:
	var at: Vector2 = images.size / 2.0
	var press: InputEventMouseButton = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	images._gui_input(press)
	for i: int in 10:
		var motion: InputEventMouseMotion = InputEventMouseMotion.new()
		motion.relative = by / 10.0
		at += motion.relative
		motion.position = at
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		images._gui_input(motion)
	var release: InputEventMouseButton = press.duplicate() as InputEventMouseButton
	release.pressed = false
	release.position = at
	images._gui_input(release)


func _double_click(images: ImageDiffView, at: Vector2) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.double_click = true
	event.position = at
	images._gui_input(event)
	var release: InputEventMouseButton = event.duplicate() as InputEventMouseButton
	release.pressed = false
	release.double_click = false
	images._gui_input(release)


## Highlights `path` in Changes and waits for its diff (and, with `decoded`,
## both sides).
func _select(changes: ChangesView, session: RepoSession, path: String, images: ImageDiffView,
		decoded: bool = true) -> bool:
	var index: int = -1
	for row: int in changes.list().row_count():
		if changes.list().path_at(row) == path:
			index = row
	if index < 0:
		printerr("image_zoom_screenshots: %s is not in Changes" % path)
		get_tree().quit(1)
		return false
	changes.list().select_only(index)
	return await _wait(func() -> bool:
		var info: Dictionary = session.diff_info()
		return String(info.get("path", "")) == path and String(info.get("state", "")) == "ready" \
				and (not decoded or (images.texture(ImageDiffView.OLD) != null and images.texture(ImageDiffView.NEW) != null)))


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("image_zoom_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## The window, and with `crop` a 2x crop of the zoom bar.
func _shot(file_name: String, images: ImageDiffView, crop: bool = false) -> void:
	for frame: int in 20:
		await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	var stem: String = "%02d-%s" % [_step, file_name]
	_step += 1
	image.save_png(_out.path_join(stem + ".png"))
	print("SHOT ", _out.path_join(stem + ".png"))
	if not crop:
		return
	var bar: Rect2 = images.zoom_bar().get_global_rect().grow(8.0)
	var scale: Vector2 = get_viewport().get_screen_transform().get_scale()
	var rect: Rect2i = Rect2i(Rect2(bar.position * scale, bar.size * scale))
	rect = rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var region: Image = image.get_region(rect)
	region.resize(region.get_width() * 2, region.get_height() * 2, Image.INTERPOLATE_NEAREST)
	region.save_png(_out.path_join(stem + "-bar.png"))
