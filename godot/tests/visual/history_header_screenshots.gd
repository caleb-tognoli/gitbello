extends Node
## Numbered shots of History without a header row: the list under the search
## field, the field's match count while searching ("Searching…", "2/2",
## "No matches"), the options menu with Compact rows and Show graph, compact
## rows, rows without the graph, the light theme and an empty repository
## (only the details say "No commits yet."). Each step also saves a 2x crop
## of the search field. Read-only on the repositories; it saves the row and
## graph settings, so run it with `GITBELLO_CONFIG` set to a scratch file.
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
	if repo.is_empty() or empty.is_empty() or _out.is_empty() or OS.get_environment("GITBELLO_CONFIG").is_empty():
		printerr("history_header_screenshots: pass --repo=<repo> --empty=<repo> --out=<dir> with GITBELLO_CONFIG set")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	Actions.run_action(&"view.theme_dark")
	if Core.history_compact():
		Actions.run_action(&"history.toggle_compact")
	if not Core.history_graph():
		Actions.run_action(&"history.toggle_graph")
	var page: RepoTab = main.open_repo(repo)
	page.show_view(WorktreeView.View.HISTORY)
	var history: HistoryView = page.history()
	if not await _wait(func() -> bool: return page.session.is_ready() and history.commit_list().row_count() >= 3):
		return
	Actions.run_action(&"history.go_to_current_commit")
	await _shot(history, "no-search")

	var field: FilterField = history.search_field()
	field.set_text("app")
	await get_tree().process_frame
	_print_count(history)
	if not await _wait(func() -> bool: return history.status_text().contains("/")):
		return
	await _shot(history, "search-1-of-2")
	history.step_match(true)
	await _shot(history, "search-next-match")
	history.commit_list().select_only(2)
	await _shot(history, "selection-not-a-match")
	field.set_text("zzz-none")
	if not await _wait(func() -> bool: return history.status_text() == "No matches"):
		return
	await _shot(history, "no-matches")
	field.set_text("")
	await get_tree().process_frame

	history.scope_button().pressed.emit()
	await _menu_shot(history.scope_menu(), "options-menu")
	history.scope_menu().id_pressed.emit(HistoryView.COMPACT_ID)
	history.scope_menu().hide()
	await _shot(history, "compact-rows")
	history.scope_button().pressed.emit()
	await _menu_shot(history.scope_menu(), "options-menu-compact-on")
	history.scope_menu().id_pressed.emit(HistoryView.GRAPH_ID)
	history.scope_menu().hide()
	await _shot(history, "compact-no-graph")
	Actions.run_action(&"history.toggle_compact")
	await _shot(history, "two-line-no-graph")
	history.scope_button().pressed.emit()
	await _menu_shot(history.scope_menu(), "options-menu-graph-off")
	history.scope_menu().hide()
	Actions.run_action(&"view.theme_light")
	await _shot(history, "light-no-graph")
	Actions.run_action(&"view.theme_dark")
	Actions.run_action(&"history.toggle_graph")

	Actions.run_action(&"view.theme_light")
	field.set_text("app")
	if not await _wait(func() -> bool: return history.status_text().contains("/")):
		return
	await _shot(history, "light-search")
	field.set_text("zzz-none")
	if not await _wait(func() -> bool: return history.status_text() == "No matches"):
		return
	await _shot(history, "light-no-matches")
	history.scope_button().pressed.emit()
	await _menu_shot(history.scope_menu(), "light-options-menu")
	history.scope_menu().hide()
	field.set_text("")
	Actions.run_action(&"view.theme_dark")

	var blank: RepoTab = main.open_repo(empty)
	blank.show_view(WorktreeView.View.HISTORY)
	if not await _wait(func() -> bool: return blank.session.is_ready() and blank.history().details().commit_oid().is_empty()):
		return
	await _shot(blank.history(), "empty-repository")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _print_count(history: HistoryView) -> void:
	print("COUNT right after typing: '%s'" % history.status_text())


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("history_header_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


func _settle() -> void:
	for frame: int in 30:
		await get_tree().process_frame


## The window, then a 2x crop of the search field and the top of the list.
func _shot(history: HistoryView, shot_name: String) -> void:
	await _settle()
	_step += 1
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = _out.path_join("%02d-%s.png" % [_step, shot_name])
	image.save_png(path)
	var left: Control = history.left_pane()
	var bar: Rect2 = history.search_field().get_global_rect()
	var rect: Rect2i = Rect2i(Rect2(left.global_position.x, bar.position.y - 6.0,
			left.size.x, bar.size.y + 110.0)).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var crop: Image = image.get_region(rect)
	crop.resize(rect.size.x * 2, rect.size.y * 2, Image.INTERPOLATE_NEAREST)
	crop.save_png(_out.path_join("%02d-%s-crop.png" % [_step, shot_name]))
	print("SHOT %s count='%s' empty='%s'" % [path, history.status_text(), history.empty_text()])


func _menu_shot(menu: PopupMenu, shot_name: String) -> void:
	await _settle()
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, shot_name])
	menu.get_texture().get_image().save_png(path)
	print("SHOT ", path)
