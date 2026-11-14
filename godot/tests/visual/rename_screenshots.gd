extends Node
## Renamed and moved files in numbered shots, each with a 2x crop of the
## diff header: History's moved, renamed and moved-and-renamed files, moves
## in Changes (staged, and one made without `git mv`), the same at the minimum window width (folders cut
## from the left) and the light theme. Prints each row's tooltip. Pass
## --repo=<repo built by tests/visual/rename_prep.sh> --out=<directory> and set
## GITBELLO_CONFIG to a scratch config (read-only on the repository).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000

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
		printerr("rename_screenshots: pass --repo=<repo> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_window().size = Vector2i(1400, 820)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	Actions.run_action(&"view.theme_dark")
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() >= 1):
		return
	for width: String in ["wide", "narrow"]:
		if width == "narrow":
			get_window().size = get_window().min_size
		if not await _history(page, session, width):
			return
		if not await _changes(page, session, width):
			return
	get_window().size = Vector2i(1400, 820)
	Actions.run_action(&"view.theme_light")
	if not await _history(page, session, "light", ["lib/core/util.rs"]):
		return
	Actions.run_action(&"view.theme_dark")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


## History's "Move files" commit, one shot per renamed file.
func _history(page: RepoTab, session: RepoSession, label: String,
		paths: Array = ["lib/core/util.rs", "docs/new.md", "c/y.txt"]) -> bool:
	page.show_view(WorktreeView.View.HISTORY)
	var commits: CommitList = page.history().commit_list()
	if not await _wait(func() -> bool: return commits.row_count() >= 2):
		return false
	commits.select_only(0)
	var files: CommitFileList = page.history().details().file_list()
	if not await _wait(func() -> bool: return files.row_count() >= 3):
		return false
	for path: String in paths:
		var index: int = _row_of(files, path)
		if index < 0:
			printerr("rename_screenshots: %s is not in the commit" % path)
			get_tree().quit(1)
			return false
		files.select_only(index)
		if not await _wait(func() -> bool:
				var info: Dictionary = session.commit_diff_info()
				return String(info.get("path", "")) == path and String(info.get("state", "")) == "ready"):
			return false
		_print_tip(files, index)
		await _shot("history-%s-%s" % [path.get_file().get_basename(), label], page.history().details().diff_panel())
	return true


## The moves in Changes: staged from a short path and from a long one, then
## one made without `git mv` (paired from a deletion and a new file).
func _changes(page: RepoTab, session: RepoSession, label: String) -> bool:
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	for path: String in ["packages/frontend/components/buttons/primary_button.txt",
			"packages/config/release/settings.json", "docs/handbook/setup.md"]:
		var index: int = _row_of(changes.list(), path)
		if index < 0:
			printerr("rename_screenshots: %s is not in Changes" % path)
			get_tree().quit(1)
			return false
		changes.list().select_only(index)
		if not await _wait(func() -> bool:
				var info: Dictionary = session.diff_info()
				return String(info.get("path", "")) == path and String(info.get("state", "")) == "ready"):
			return false
		_print_tip(changes.list(), index)
		await _shot("changes-%s-%s" % [path.get_file().get_basename(), label], changes.diff_panel())
	return true


func _row_of(list: VirtualList, path: String) -> int:
	for row: int in list.row_count():
		if String(list.call(&"path_at", row)) == path:
			return row
	return -1


func _print_tip(list: VirtualList, index: int) -> void:
	var at: Vector2 = Vector2(20.0, list.row_top(index) - list.scroll_offset() + list.row_height() / 2.0)
	print("TIP %s: %s" % [String(list.call(&"path_at", index)), String(list.call(&"_get_tooltip", at)).replace("\n", " | ")])


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("rename_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## The window, then a 2x crop of `panel`'s header.
func _shot(file_name: String, panel: DiffPanel) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	var stem: String = "%02d-%s" % [_step, file_name]
	_step += 1
	image.save_png(_out.path_join(stem + ".png"))
	var header: Rect2 = (panel.get_child(0) as Control).get_global_rect()
	var scale: Vector2 = get_viewport().get_screen_transform().get_scale()
	var rect: Rect2i = Rect2i(Rect2(header.position * scale, header.size * scale))
	rect = rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var crop: Image = image.get_region(rect)
	crop.resize(crop.get_width() * 2, crop.get_height() * 2, Image.INTERPOLATE_NEAREST)
	crop.save_png(_out.path_join(stem + "-header.png"))
	print("SHOT ", _out.path_join(stem + ".png"))
