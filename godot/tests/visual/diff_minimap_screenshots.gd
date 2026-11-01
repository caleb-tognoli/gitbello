extends Node
## Capture of the diff minimap (M7.6): the whole of a long changed file
## unified and scrolled to the middle, with lines left out of the commit,
## side by side, with the minimap off and in a narrow window, in the light
## theme, then the resolver on a conflicted file. Pass --repo=<throwaway
## repo with a long uncommitted change to `--file`> --file=<path in it>
## --conflict-repo=<throwaway repo in a conflicted merge> --conflict=<its
## conflicted path> --out=<directory>, with GITBELLO_CONFIG set to a scratch
## config, and launch windowed. It changes the commit selection (picks),
## never the files.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000

var _out: String = ""
var _step: int = 1


func _ready() -> void:
	var args: Dictionary[String, String] = {}
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	for key: String in ["repo", "file", "conflict-repo", "conflict", "out"]:
		if not args.has(key):
			printerr("diff_minimap_screenshots: pass --repo --file --conflict-repo --conflict --out")
			get_tree().quit(2)
			return
	_out = args["out"]
	DirAccess.make_dir_recursive_absolute(_out)
	get_window().size = Vector2i(1400, 820)
	Actions.run_action(&"view.theme_dark")
	if not Core.diff_minimap():
		Actions.run_action(&"diff.toggle_minimap")
	if Core.diff_side_by_side():
		Actions.run_action(&"diff.toggle_side_by_side")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame

	var page: RepoTab = main.open_repo(args["repo"])
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() > 0):
		return
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var diff: DiffView = changes.diff_view()
	if not await _select(changes, args["file"]):
		return
	if not await _wait(func() -> bool: return diff.row_count() > 0):
		return
	await _shot("hunks")
	Actions.run_action(&"diff.toggle_whole_file")
	var hunk_rows: int = diff.row_count()
	if not await _wait(func() -> bool: return diff.row_count() > hunk_rows):
		return
	await _shot("whole-file-top")
	diff.set_scroll_offset(diff.max_scroll_offset() / 2.0)
	await _shot("whole-file-middle")

	# Leave out the second half's changes.
	var lines: PackedInt32Array = PackedInt32Array()
	for row: int in range(floori(diff.row_count() / 2.0), diff.row_count()):
		var kind: int = int(diff.line(row).get("kind", -1))
		if kind == DiffView.KIND_ADDED or kind == DiffView.KIND_REMOVED:
			lines.append(int(diff.line(row).get("index", -1)))
	session.pick_lines(lines, false)
	await _shot("left-out")
	Actions.run_action(&"diff.toggle_side_by_side")
	await _shot("side-by-side")
	Actions.run_action(&"diff.toggle_side_by_side")
	Actions.run_action(&"diff.toggle_minimap")
	await _shot("minimap-off")
	Actions.run_action(&"diff.toggle_minimap")
	get_window().size = Vector2i(960, 640)
	await _shot("narrow")
	get_window().size = Vector2i(1400, 820)
	Actions.run_action(&"view.theme_light")
	await _shot("light")
	session.pick_lines(lines, true)
	Actions.run_action(&"view.theme_dark")

	var conflict_page: RepoTab = main.open_repo(args["conflict-repo"])
	var conflict_session: RepoSession = conflict_page.session
	if not await _wait(func() -> bool: return conflict_session.is_ready() and conflict_session.change_count() > 0):
		return
	conflict_page.show_view(WorktreeView.View.CHANGES)
	var resolver: ChangesView = conflict_page.changes()
	if not await _select(resolver, args["conflict"]):
		return
	if not await _wait(func() -> bool: return resolver.has_conflict_blocks()):
		return
	await _shot("resolver")
	Actions.run_action(&"diff.toggle_side_by_side")
	await _shot("resolver-side-by-side")
	Actions.run_action(&"diff.toggle_side_by_side")
	Actions.run_action(&"view.theme_light")
	await _shot("resolver-light")
	Actions.run_action(&"view.theme_dark")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _select(changes: ChangesView, path: String) -> bool:
	var list: ChangeList = changes.list()
	if not await _wait(func() -> bool:
		for i: int in list.row_count():
			if list.path_at(i) == path:
				return true
		return false):
		return false
	for i: int in list.row_count():
		if list.path_at(i) == path:
			list.grab_focus()
			list.select_only(i)
	return true


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("diff_minimap_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


func _shot(file_name: String) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	_step += 1
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path)
