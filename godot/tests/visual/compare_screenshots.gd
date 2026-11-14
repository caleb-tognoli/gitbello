extends Node
## Captures Compare (PLAN M7.12c) in numbered shots, dark then light: All
## changes, a commit with its details, the commit and file menus, the
## working-copy side, both sides moved (the Include pill off with the left
## side's commits dimmed, hovered, then on from a selected commit, each
## with a 3x crop of the pill's row), a folded section, History's details with two commits selected, those commits
## compared and the Recent popover listing them by subject. Pass
## --repo=<CLI fixture repo> --out=<directory> and launch windowed with
## GITBELLO_CONFIG set to a scratch file (recent comparisons are saved
## there). It fetches the fixture's origin: throwaway fixtures only.

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
		printerr("compare_screenshots: pass --repo=<fixture> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_window().size = Vector2i(1400, 860)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready()):
		return
	var worktree: WorktreeView = page.active_view()
	var compare: CompareView = worktree.compare()
	# Both sides moved once origin/main has the fixture's remote commit.
	Actions.run_action(&"sync.fetch")
	for mode: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + mode))
		# All changes: feature/login ⇄ main, app.txt's diff.
		worktree.open_compare("feature/login", "main", false)
		if not await _compared(session) or not await _wait(func() -> bool:
			return compare.diff_panel().view().row_count() > 0):
			return
		var commits: CompareCommitList = compare.commit_list()
		await _shot("all-changes-" + mode, null)
		# main's commit: its details over its files.
		commits.select_only(2)
		if not await _wait(func() -> bool:
			return compare.details_header().visible and compare.diff_panel().view().row_count() > 0):
			return
		await _shot("commit-" + mode, null)
		commits.context_menu_requested.emit(2, Vector2(160, commits.row_top(2) + commits.row_extent(2) * 0.5))
		await _shot("commit-menu-" + mode, compare.commit_menu())
		compare.commit_menu().hide()
		var files: VirtualList = compare.file_list()
		files.context_menu_requested.emit(0, Vector2(120, files.row_height() * 0.5))
		await _shot("file-menu-" + mode, compare.file_menu())
		compare.file_menu().hide()
		# main ⇄ the working copy.
		worktree.open_compare("main", "", true)
		if not await _compared(session):
			return
		await _shot("working-copy-" + mode, null)
		# main ⇄ origin/main: each has a commit the other lacks.
		worktree.open_compare("main", "origin/main", false)
		if not await _wait(func() -> bool:
			var info: Dictionary = session.compare_info()
			return String(info.get("state", "")) == "ready" and not bool(info.get("reloading", false)) \
					and int(info.get("only_left", 0)) > 0 and int(info.get("only_right", 0)) > 0):
			return
		await _shot("both-moved-" + mode, null)
		await _crop("include-off-" + mode, commits)
		commits._set_pill_hovered(true)
		await _crop("include-hover-" + mode, commits)
		commits._set_pill_hovered(false)
		# From a selected commit, the pill selects All changes.
		commits.select_only(2)
		if not await _wait(func() -> bool: return not compare.focused_commit().is_empty()):
			return
		commits.include_toggled.emit()
		if not await _compared(session):
			return
		await _shot("included-" + mode, null)
		await _crop("include-on-" + mode, commits)
		commits.toggle_section("left")
		await _shot("folded-" + mode, null)
		commits.toggle_section("left")
		commits.include_toggled.emit()
		if not await _compared(session):
			return
		# History: two commits selected offer Compare commits.
		Actions.run_action(&"compare.close")
		worktree.show_view(WorktreeView.View.HISTORY)
		var list: CommitList = page.history().commit_list()
		if not await _wait(func() -> bool: return list.row_count() >= 2):
			return
		list.select_only(1)
		list._toggle(2)
		await _shot("history-pair-" + mode, null)
		Actions.run_action(&"history.compare_selected")
		if not await _compared(session):
			return
		await _shot("commit-sides-" + mode, null)
		# Back to main ⇄ origin/main: Recent lists the commits by subject.
		worktree.open_compare("main", "origin/main", false)
		if not await _compared(session):
			return
		compare.show_recent()
		await _shot("recent-" + mode, compare.recent_popover())
		compare.recent_popover().hide()
		Actions.run_action(&"compare.close")
		list.select_only(0)
	Actions.run_action(&"view.theme_dark")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _compared(session: RepoSession) -> bool:
	await get_tree().process_frame
	return await _wait(func() -> bool:
		var info: Dictionary = session.compare_info()
		return String(info.get("state", "")) == "ready" and not bool(info.get("reloading", false)))


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("compare_screenshots: timed out at step %d" % _step)
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## A 3x crop of the left side's section header in `commits`, and the row
## above and below it.
func _crop(file_name: String, commits: CompareCommitList) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var header: int = -1
	for row: int in commits.row_count():
		if commits.kind_at(row) == "left":
			header = row
	if header < 0:
		printerr("compare_screenshots: %s: no left section" % file_name)
		return
	var top: float = commits.row_top(header) - commits.scroll_offset() - 12.0
	var height: float = commits.row_extent(header) + 36.0
	var origin: Vector2 = commits.get_global_position()
	var rect: Rect2i = Rect2i(Rect2(origin + Vector2(0.0, top), Vector2(commits.size.x, height)))
	var image: Image = get_viewport().get_texture().get_image().get_region(rect)
	image.resize(image.get_width() * 3, image.get_height() * 3, Image.INTERPOLATE_NEAREST)
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	_step += 1
	image.save_png(path)
	print("SHOT ", path)


## The window, with `popup` (a separate window) drawn in where it shows.
func _shot(file_name: String, popup: Window) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	if popup != null and popup.visible:
		var menu: Image = popup.get_texture().get_image()
		menu.convert(image.get_format())
		var at: Vector2i = popup.position - get_window().position
		image.blit_rect(menu, Rect2i(Vector2i.ZERO, menu.get_size()), at)
	elif popup != null:
		printerr("compare_screenshots: %s: the popup did not open" % file_name)
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	_step += 1
	image.save_png(path)
	print("SHOT ", path)
