extends Node
## Captures File history (PLAN M8a) in numbered shots, dark then light: the
## uncommitted changes, a commit with its details, the rename (its chip and
## the old → new diff), a version's menu, the filter (its matches, then no
## match), two versions selected, those versions in Compare (filtered to the
## file), the field's options menu, compact rows, a history read from
## another branch ("as of …"), a deleted file's history, the files' menu in
## Changes; then, dark only, the diff's menu, Open in History
## with that file's menu, Restore version with its toast and what it
## changed, and the minimum window width. Pass --repo=<the CLI's history
## fixture> --out=<directory> and launch windowed with GITBELLO_CONFIG set
## to a scratch file (it restores the file, then undoes it, and saves the
## row setting: throwaway fixtures only).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000
const FILE: String = "src/login/auth.rs"

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
		printerr("file_history_screenshots: pass --repo=<history fixture> --out=<directory>")
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
	var view: FileView = worktree.file_view()
	var list: FileHistoryList = view.version_list()
	for mode: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + mode))
		# From Changes: the files' menu, then the history.
		worktree.show_view(WorktreeView.View.CHANGES)
		var changes: ChangesView = page.changes()
		if not await _wait(func() -> bool: return session.change_count() == 2):
			return
		for row: int in changes.list().row_count():
			if changes.list().path_at(row) == FILE:
				changes.list().select_only(row)
		changes.list().context_menu_requested.emit(changes.list().cursor, Vector2(140, 12))
		await _shot("changes-menu-" + mode, changes.context_menu())
		changes.context_menu().hide()
		Actions.run_action(&"file_history.open")
		if not await _loaded(session, view) or not await _diff_shown(view):
			return
		# The row's line counts come after the status.
		if not await _wait(func() -> bool:
			return int((session.file_history_info()["working"] as Dictionary).get("additions", -1)) >= 0):
			return
		await _shot("uncommitted-" + mode, null)
		# A commit with a message body and a co-author.
		list.select_only(1)
		if not await _wait(func() -> bool: return view.details_header().has_body()) or not await _diff_shown(view):
			return
		await _shot("commit-" + mode, null)
		# The rename.
		list.select_only(4)
		if not await _diff_shown(view):
			return
		await _shot("rename-" + mode, null)
		list.context_menu_requested.emit(4, Vector2(160, list.row_top(4) + list.row_extent(4) * 0.5))
		await _shot("version-menu-" + mode, view.version_menu())
		view.version_menu().hide()
		# The filter: only the commits it matches, then none.
		view.filter_field().set_text("login")
		if not await _wait(func() -> bool:
			return int(session.file_history_info()["count"]) == 2 and list.row_count() == 2) \
				or not await _diff_shown(view):
			return
		view.filter_field().focus_text()
		view.filter_field().text_box().deselect()
		view.filter_field().text_box().caret_column = 5
		await _shot("filter-" + mode, null)
		view.filter_field().set_text("no such words")
		if not await _wait(func() -> bool: return not view.message_text().is_empty()):
			return
		await _shot("filter-no-match-" + mode, null)
		view.filter_field().set_text("")
		list.grab_focus()
		if not await _wait(func() -> bool: return list.row_count() == 7) or not await _diff_shown(view):
			return
		# Two versions selected, then compared.
		list.select_only(1)
		list._toggle(5)
		list.context_menu_requested.emit(5, Vector2(160, list.row_top(5) + list.row_extent(5) * 0.5))
		await _shot("two-versions-" + mode, view.version_menu())
		view.version_menu().hide()
		Actions.run_action(&"file_history.compare_versions")
		if not await _wait(func() -> bool:
			var info: Dictionary = session.compare_info()
			return String(info.get("state", "")) == "ready" and not worktree.compare().current_file().is_empty() \
					and worktree.compare().diff_panel().view().row_count() > 0):
			return
		await _shot("compared-" + mode, null)
		Actions.run_action(&"compare.close")
		# The field's options, then compact rows.
		view.options_button().pressed.emit()
		await _shot("options-menu-" + mode, view.options_menu())
		view.options_menu().hide()
		Actions.run_action(&"history.toggle_compact")
		list.select_only(2)
		if not await _diff_shown(view):
			return
		await _shot("compact-" + mode, null)
		Actions.run_action(&"history.toggle_compact")
		# Read from another branch.
		worktree.open_file_history(FILE, "topic", "topic")
		if not await _loaded(session, view) or not await _diff_shown(view):
			return
		await _shot("as-of-topic-" + mode, null)
		# A deleted file.
		worktree.open_file_history("gone.txt")
		if not await _loaded(session, view) or not await _diff_shown(view):
			return
		await _shot("deleted-file-" + mode, null)
		Actions.run_action(&"file_history.close")
	Actions.run_action(&"view.theme_dark")
	worktree.open_file_history(FILE)
	if not await _loaded(session, view):
		return
	# The diff's menu.
	list.select_only(4)
	if not await _diff_shown(view):
		return
	view.diff_panel().view().context_menu_requested.emit(0, Vector2(220, 70))
	await _shot("diff-menu", view.diff_menu())
	view.diff_menu().hide()
	# Open in History, and the menu of a commit's file there.
	var renamed_oid: String = String(list.version_at(4).get("oid", ""))
	Actions.run_action(&"file_history.show_in_history")
	var history: HistoryView = page.history()
	if not await _wait(func() -> bool:
		return String(history.selected_commit().get("hash", "")) == renamed_oid and history.details().file_list().row_count() > 0):
		return
	await _shot("shown-in-history", null)
	history.details().file_list().context_menu_requested.emit(0, Vector2(120, 12))
	await _shot("history-file-menu", history.details().file_menu())
	history.details().file_menu().hide()
	# Restore a version from before the rename (the toast with Undo), then Undo.
	Actions.run_action(&"view.file_history")
	var path: String = repo.path_join(FILE)
	var edited: String = FileAccess.get_file_as_string(path)
	list.select_only(5)
	if not await _diff_shown(view):
		return
	Actions.run_action(&"file_history.restore")
	if not await _wait(func() -> bool:
		return FileAccess.get_file_as_string(path) != edited and session.can_undo_discard()):
		return
	await _shot("restored", null)
	# What the restore changed, as the uncommitted changes.
	list.select_only(0)
	if not await _wait(func() -> bool: return view.on_working_row()) or not await _diff_shown(view):
		return
	await _shot("restored-changes", null)
	# The toast's Undo.
	if not main.toasts().press_fix(tr("Undo")):
		printerr("file_history_screenshots: the restore's toast has no Undo")
		session.undo_discard()
	if not await _wait(func() -> bool: return FileAccess.get_file_as_string(path) == edited):
		return
	# The minimum window width.
	list.select_only(4)
	get_window().size = Vector2i(get_window().min_size.x, 860)
	if not await _diff_shown(view):
		return
	await _shot("narrow", null)
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _loaded(session: RepoSession, view: FileView) -> bool:
	await get_tree().process_frame
	return await _wait(func() -> bool:
		var info: Dictionary = session.file_history_info()
		return bool(info.get("open", false)) and not bool(info.get("loading", true)) \
				and not view.is_loading())


func _diff_shown(view: FileView) -> bool:
	for frame: int in 3:
		await get_tree().process_frame
	return await _wait(func() -> bool:
		return String(view.session.slot_diff_info("file").get("state", "")) == "ready" \
				and view.diff_panel().view().row_count() > 0)


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("file_history_screenshots: timed out at step %d" % _step)
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


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
		printerr("file_history_screenshots: %s: the popup did not open" % file_name)
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	_step += 1
	image.save_png(path)
	print("SHOT ", path)
