extends Node
## The diff header's mode picker (M7.8 P1), in numbered shots per theme: a
## modified file unified and side by side (two modes), then the untracked
## file, a deleted file and a file added in a commit (one mode: no picker),
## each with a 2x crop of the header's right end. Pass --repo=<CLI fixture
## repo> --out=<directory> and set GITBELLO_CONFIG to a scratch config before
## launching windowed. It deletes README.md from the repo's working tree and
## saves the text mode: throwaway fixtures only.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000
## Width of the header's right end in the crops, in pixels.
const CROP_WIDTH: int = 420

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
		printerr("diff_modes_screenshots: pass --repo=<fixture> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	DirAccess.remove_absolute(repo.path_join("README.md"))
	Core.set_diff_mode("text", "unified")
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
		page.show_view(WorktreeView.View.CHANGES)
		if not await _select(changes, session, "app.txt"):
			return
		await _shot("modified-unified-" + theme, changes.diff_panel())
		Actions.run_action(&"diff.cycle_mode")
		await _shot("modified-split-" + theme, changes.diff_panel())
		for entry: Array in [["notes.txt", "untracked"], ["README.md", "deleted"]]:
			if not await _select(changes, session, entry[0]):
				return
			await _shot("%s-no-picker-%s" % [entry[1], theme], changes.diff_panel())
		page.show_view(WorktreeView.View.HISTORY)
		var commits: CommitList = page.history().commit_list()
		if not await _wait(func() -> bool: return commits.row_count() >= 2):
			return
		commits.select_only(commits.row_count() - 2)
		var added_shown: Callable = func() -> bool:
			var info: Dictionary = session.commit_diff_info()
			return String(info.get("code", "")) == "A" and String(info.get("state", "")) == "ready"
		if not await _wait(added_shown):
			return
		await _shot("history-added-no-picker-" + theme, page.history().details().diff_panel())
		commits.select_only(0)
		if not await _wait(func() -> bool: return page.history().details().diff_panel().picker_visible()):
			return
		await _shot("history-modified-split-" + theme, page.history().details().diff_panel())
		Actions.run_action(&"diff.cycle_mode")
	Core.set_diff_mode("text", "unified")
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
		printerr("diff_modes_screenshots: %s is not in Changes" % path)
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
			printerr("diff_modes_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## The window, then a 2x crop of `panel`'s header's right end.
func _shot(file_name: String, panel: DiffPanel) -> void:
	for frame: int in 30:
		await get_tree().process_frame
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
	print("SHOT ", _out.path_join(stem + ".png"))
