extends Node
## The Markdown diff's Preview mode, in numbered shots per theme: README.md
## of the CLI's `markdown` fixture in Changes (Unified with the picker, then
## Preview at the top, scrolled to the second change with F7 and to the
## Logo heading with its picture, each with a 2x crop of the header's right
## end and, in Preview, a 3x crop of the scroll strip with the text beside
## it), the untracked docs/guide.md in
## Preview, and History's commit that edited the readme. Pass
## --repo=<the fixture's markdown repo> --out=<directory> and set
## GITBELLO_CONFIG to a scratch config before launching windowed. It saves
## the Markdown mode (read-only on the repository).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000
const CROP_WIDTH: int = 420
## Pixels of the preview kept left of the strip in its crop.
const STRIP_CONTEXT: float = 60.0

var _out: String = ""
var _step: int = 1


func _ready() -> void:
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or _out.is_empty():
		printerr("markdown_preview_screenshots: pass --repo=<fixture> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	Core.set_diff_mode("markdown", "unified")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() >= 3):
		return
	var changes: ChangesView = page.changes()
	for theme: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + theme))
		Core.set_diff_mode("markdown", "unified")
		page.show_view(WorktreeView.View.CHANGES)
		if not await _select(changes, session, "README.md"):
			return
		var panel: DiffPanel = changes.diff_panel()
		await _shot("readme-unified-" + theme, panel)
		panel.choose_mode("preview")
		await _shot("readme-preview-" + theme, panel)
		Actions.run_action(&"diff.next_change")
		await _frames(10)
		Actions.run_action(&"diff.next_change")
		await _shot("readme-preview-second-change-" + theme, panel)
		var preview: MarkdownDiffView = panel.markdown_view()
		preview.scroll_to_anchor("logo")
		if not await _wait(func() -> bool: return preview.block_picture_count(17) == 1):
			return
		await _shot("readme-pictures-" + theme, panel)
		if not await _select(changes, session, "docs/guide.md"):
			return
		await _shot("untracked-preview-" + theme, panel)
		page.show_view(WorktreeView.View.HISTORY)
		var commits: CommitList = page.history().commit_list()
		if not await _wait(func() -> bool: return commits.row_count() >= 2):
			return
		commits.select_only(0)
		var details_panel: DiffPanel = page.history().details().diff_panel()
		if not await _wait(func() -> bool: return details_panel.markdown_view().block_count() > 0):
			return
		await _shot("history-preview-" + theme, details_panel)
	Core.set_diff_mode("markdown", "unified")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


## Highlights `path` in Changes and waits for its diff.
func _select(changes: ChangesView, session: RepoSession, path: String) -> bool:
	var index: int = -1
	for row: int in changes.list().row_count():
		if changes.list().path_at(row) == path:
			index = row
	if index < 0:
		printerr("markdown_preview_screenshots: %s is not in Changes" % path)
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
			printerr("markdown_preview_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


func _frames(count: int) -> void:
	for frame: int in count:
		await get_tree().process_frame


## The window, then a 2x crop of `panel`'s header's right end.
func _shot(file_name: String, panel: DiffPanel) -> void:
	await _frames(30)
	var image: Image = get_viewport().get_texture().get_image()
	var stem: String = "%02d-%s" % [_step, file_name]
	_step += 1
	image.save_png(_out.path_join(stem + ".png"))
	var header: Rect2 = (panel.get_child(0) as Control).get_global_rect()
	var scale: Vector2 = get_viewport().get_screen_transform().get_scale()
	var rect: Rect2i = Rect2i(Rect2(Vector2(header.end.x - CROP_WIDTH, header.position.y) * scale,
			Vector2(CROP_WIDTH, header.size.y) * scale))
	rect = rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var crop: Image = image.get_region(rect)
	crop.resize(crop.get_width() * 2, crop.get_height() * 2, Image.INTERPOLATE_NEAREST)
	crop.save_png(_out.path_join(stem + "-header.png"))
	var preview: MarkdownDiffView = panel.markdown_view()
	if preview.is_visible_in_tree():
		var strip: Rect2 = preview.scroll_strip().get_global_rect()
		strip = Rect2(strip.position.x - STRIP_CONTEXT, strip.position.y, strip.size.x + STRIP_CONTEXT, strip.size.y)
		var area: Rect2i = Rect2i(Rect2(strip.position * scale, strip.size * scale))
		area = area.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
		var column: Image = image.get_region(area)
		column.resize(column.get_width() * 3, column.get_height() * 3, Image.INTERPOLATE_NEAREST)
		column.save_png(_out.path_join(stem + "-strip.png"))
	print("SHOT ", _out.path_join(stem + ".png"))
