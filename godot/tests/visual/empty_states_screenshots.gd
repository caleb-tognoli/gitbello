extends Node
## Numbered shots of the compact empty states, dark then light: Changes with
## no file selected, its filter matching nothing and after Clear filter, the
## Shelves list filtered to nothing, Compare with no differences and its
## filter matching nothing, a file's history filtered to nothing and the
## history of a path never committed, a repository without commits (History
## and "No local changes") and Home's filter matching nothing.
## Read-only on the repositories; it saves view settings, so run it with
## `GITBELLO_CONFIG` set to a scratch file.
##
##   --repo=<CLI fixture repo-1> --empty=<a repository without commits> --out=<dir>

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000

var _out: String = ""
var _step: int = 0


func _ready() -> void:
	var repo: String = ""
	var empty: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--empty="):
			empty = arg.trim_prefix("--empty=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or empty.is_empty() or _out.is_empty() \
			or OS.get_environment("GITBELLO_CONFIG").is_empty():
		printerr("empty_states_screenshots: pass --repo= --empty= --out= with GITBELLO_CONFIG set")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_window().size = Vector2i(1400, 820)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.has_status() and session.change_count() > 0):
		return
	var worktree: WorktreeView = page.active_view()
	var changes: ChangesView = page.changes()
	for mode: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + mode))
		main.open_repo(repo)
		page.show_view(WorktreeView.View.CHANGES)
		changes.list().select_only(-1)
		if not await _wait(func() -> bool: return changes.diff_panel().message_text() == tr("No file selected")):
			return
		await _shot("changes-no-file-selected-" + mode)
		changes.filter_field().set_text("zzz-none")
		if not await _wait(func() -> bool: return changes.no_match_state().visible):
			return
		await _shot("changes-filter-no-match-" + mode)
		changes.no_match_state().press(tr("Clear filter"))
		if not await _wait(func() -> bool: return changes.list().row_count() > 0 and not changes.no_match_state().visible):
			return
		await _shot("changes-after-clear-filter-" + mode)

		page.show_view(WorktreeView.View.SHELVES)
		changes.shelf_list().filter_field().set_text("zzz-none")
		if not await _wait(func() -> bool: return changes.shelf_list().empty_state().visible):
			return
		await _shot("shelves-filter-no-match-" + mode)
		changes.shelf_list().filter_field().set_text("")

		var compare: CompareView = worktree.compare()
		worktree.open_compare("main", "main", false)
		if not await _wait(func() -> bool: return compare.message_text() == tr("No differences")):
			return
		await _shot("compare-no-differences-" + mode)
		worktree.open_compare("feature/login", "main", false)
		if not await _wait(func() -> bool: return compare.file_list().row_count() > 0):
			return
		compare.filter_field().set_text("zzz-none")
		if not await _wait(func() -> bool: return compare.message_text() == tr("No matches")):
			return
		await _shot("compare-filter-no-match-" + mode)
		compare.filter_field().set_text("")

		var file_view: FileView = worktree.file_view()
		worktree.open_file_history("app.txt")
		if not await _wait(func() -> bool: return file_view.has_history() and file_view.message_text().is_empty() \
				and file_view.loading_indicator() != null and not file_view.loading_indicator().is_loading()):
			return
		file_view.filter_field().set_text("zzz-none")
		if not await _wait(func() -> bool: return file_view.message_text() == tr("No matches")):
			return
		await _shot("file-history-filter-no-match-" + mode)
		file_view.filter_field().set_text("")
		worktree.open_file_history("missing.txt")
		if not await _wait(func() -> bool: return file_view.message_text() == tr("No commits for this file")):
			return
		await _shot("file-history-no-commits-" + mode)

		var blank: RepoTab = main.open_repo(empty)
		blank.show_view(WorktreeView.View.HISTORY)
		if not await _wait(func() -> bool: return blank.session.is_ready() and blank.history().empty_text() == tr("No commits yet")):
			return
		await _shot("history-no-commits-" + mode)
		blank.show_view(WorktreeView.View.CHANGES)
		if not await _wait(func() -> bool: return blank.changes().empty_state().visible):
			return
		await _shot("no-local-changes-" + mode)

		main.open_home()
		main.home().filter_field().set_text("zzz-none")
		await _shot("home-filter-no-match-" + mode)
		main.home().filter_field().set_text("")
	Actions.run_action(&"view.theme_dark")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("empty_states_screenshots: timed out at step %d" % (_step + 1))
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


func _shot(shot_name: String) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, shot_name])
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path)
