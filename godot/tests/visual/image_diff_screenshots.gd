extends Node
## The image viewer (M7.8 P2), in numbered shots per theme: a PNG of another
## size split, onion skin, swipe, difference, at 100% and zoomed in; an SVG;
## a deleted and an added (transparent) image alone; an image too wide and
## one past 20 MB; a commit's image in History; and a binary image conflict's
## card. The split shot also gets a 2x crop of the header's right end. Pass
## --fixtures=<dir with the CLI's `images` and `images-conflict`>
## --out=<directory> and set GITBELLO_CONFIG to a scratch config before
## launching windowed. It saves the image mode: throwaway fixtures only.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 60_000
const CROP_WIDTH: int = 520

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
		printerr("image_diff_screenshots: pass --fixtures=<dir> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	Core.set_diff_mode("image", "split")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(fixtures.path_join("images"))
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() >= 6):
		return
	var changes: ChangesView = page.changes()
	var panel: DiffPanel = changes.diff_panel()
	var images: ImageDiffView = panel.image_view()
	for theme: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + theme))
		page.show_view(WorktreeView.View.CHANGES)
		if not await _select(changes, session, "logo.png", images, true, true):
			return
		await _shot("split-" + theme, panel, true)
		for mode_id: String in ["onion", "swipe", "difference"]:
			panel.choose_mode(mode_id)
			if mode_id == "swipe":
				images.set_swipe_position(0.4)
			await _shot(mode_id + "-" + theme, panel)
		panel.choose_mode("split")
		images.actual_size()
		await _shot("actual-size-" + theme, panel)
		images.set_zoom(images.fit_scale() * 4.0, images.side_rect(ImageDiffView.NEW).get_center())
		images.pan_by(Vector2(-100000, -100000))
		await _shot("zoomed-in-dragged-" + theme, panel)
		images.fit()
		for entry: Array in [["icon.svg", "svg", true, true], ["old.png", "deleted", true, false],
				["new.png", "added-transparent", false, true]]:
			if not await _select(changes, session, entry[0], images, entry[2], entry[3]):
				return
			await _shot("%s-%s" % [entry[1], theme], panel)
		if not await _select(changes, session, "wide.png", images, false, false):
			return
		await _shot("too-wide-" + theme, panel)
		if not await _select(changes, session, "huge.png", images, false, false):
			return
		await _shot("too-large-" + theme, panel)
		page.show_view(WorktreeView.View.HISTORY)
		var commits: CommitList = page.history().commit_list()
		if not await _wait(func() -> bool: return commits.row_count() >= 2):
			return
		commits.select_only(0)
		var history_panel: DiffPanel = page.history().details().diff_panel()
		var history_images: ImageDiffView = history_panel.image_view()
		if not await _wait(func() -> bool: return history_images.texture(ImageDiffView.OLD) != null \
				and history_images.texture(ImageDiffView.NEW) != null):
			return
		await _shot("history-" + theme, history_panel)
		var conflict: RepoTab = main.open_repo(fixtures.path_join("images-conflict"))
		var conflict_session: RepoSession = conflict.session
		conflict.show_view(WorktreeView.View.CHANGES)
		if not await _wait(func() -> bool: return conflict_session.is_ready() and conflict_session.change_count() >= 1):
			return
		conflict.changes().list().select_only(0)
		var preview: ImageDiffView = conflict.changes().diff_panel().image_preview()
		if not await _wait(func() -> bool: return preview.texture(ImageDiffView.OLD) != null \
				and preview.texture(ImageDiffView.NEW) != null):
			return
		await _shot("conflict-card-" + theme, conflict.changes().diff_panel())
		main.close_tab(main.tab_count() - 1)
		await get_tree().process_frame
	Core.set_diff_mode("image", "split")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


## Highlights `path` in Changes and waits for its diff and the sides wanted.
func _select(changes: ChangesView, session: RepoSession, path: String, images: ImageDiffView,
		old: bool, new: bool) -> bool:
	var index: int = -1
	for row: int in changes.list().row_count():
		if changes.list().path_at(row) == path:
			index = row
	if index < 0:
		printerr("image_diff_screenshots: %s is not in Changes" % path)
		get_tree().quit(1)
		return false
	changes.list().select_only(index)
	return await _wait(func() -> bool:
		var info: Dictionary = session.diff_info()
		return String(info.get("path", "")) == path and String(info.get("state", "")) == "ready" \
				and (images.texture(ImageDiffView.OLD) != null) == old \
				and (images.texture(ImageDiffView.NEW) != null) == new)


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("image_diff_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## The window, and with `crop` a 2x crop of `panel`'s header's right end.
func _shot(file_name: String, panel: DiffPanel, crop: bool = false) -> void:
	for frame: int in 20:
		await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	var stem: String = "%02d-%s" % [_step, file_name]
	_step += 1
	image.save_png(_out.path_join(stem + ".png"))
	print("SHOT ", _out.path_join(stem + ".png"))
	if not crop:
		return
	var header: Rect2 = (panel.get_child(0) as Control).get_global_rect()
	var scale: Vector2 = get_viewport().get_screen_transform().get_scale()
	var rect: Rect2i = Rect2i(Rect2(Vector2(header.end.x - CROP_WIDTH, header.position.y) * scale,
			Vector2(CROP_WIDTH, header.size.y) * scale))
	rect = rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var region: Image = image.get_region(rect)
	region.resize(region.get_width() * 2, region.get_height() * 2, Image.INTERPOLATE_NEAREST)
	region.save_png(_out.path_join(stem + "-header.png"))
