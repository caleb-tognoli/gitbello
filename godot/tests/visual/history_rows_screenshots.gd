extends Node
## Read-only capture of the M7.10 history rows: two-line rows in the dark and
## light themes, a selected row with co-authors, the details of the commit with the most
## refs (and the popover of a counted chip there when they fold), a row's
## refs popover, that popover with a ref's menu open over it,
## compact rows in both themes, and two-line
## rows at the minimum window width. Pass --repo=<throwaway repo with
## co-authored commits, branches and tags> --out=<directory> and set
## GITBELLO_CONFIG to a scratch config before launching windowed.
## --row-heights=46,48,… captures only the two-line rows at each height, in
## both themes (`rows-<height>-<theme>.png`), to compare row paddings.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000


func _ready() -> void:
	var repo: String = ""
	var out: String = ""
	var heights: PackedInt32Array = PackedInt32Array()
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
		elif arg.begins_with("--row-heights="):
			for value: String in arg.trim_prefix("--row-heights=").split(",", false):
				heights.append(value.to_int())
	if repo.is_empty() or out.is_empty() or OS.get_environment("GITBELLO_CONFIG").is_empty():
		printerr("history_rows_screenshots: pass --repo=<repo> --out=<directory> with GITBELLO_CONFIG set")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	Core.set_history_compact(false)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	page.show_view(WorktreeView.View.HISTORY)
	var history: HistoryView = page.history()
	var list: CommitList = history.commit_list()
	if not await _wait(func() -> bool: return page.session.is_ready() and list.row_count() > 3 \
			and bool(page.session.history_info().get("ready", false))):
		return
	history.set_all_branches(true)
	if not await _wait(func() -> bool: return list.row_count() > 3):
		return
	if not heights.is_empty():
		for mode: String in ["dark", "light"]:
			Actions.run_action(StringName("view.theme_" + mode))
			for height: int in heights:
				# The list's own theme wins over the app's for this one item
				# (an override would not reach the CommitList theme type).
				var own: Theme = Theme.new()
				own.set_constant(&"two_line_row_height", CommitList.LIST_THEME_TYPE, height)
				list.theme = own
				await _shot(out, "rows-%d-%s" % [height, mode])
		list.theme = null
		while main.tab_count() > 0:
			main.close_tab(0)
		get_tree().quit(0)
		return
	var step: int = 1
	for mode: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + mode))
		await _shot(out, "%02d-two-line-%s" % [step, mode])
		step += 1
	Actions.run_action(&"view.theme_dark")
	# The first commit with co-authors.
	for row: int in list.row_count():
		if not (list.row_data(row).get("coauthors", []) as Array).is_empty():
			list.select_only(row)
			break
	await _shot(out, "%02d-coauthors-selected" % step)
	step += 1
	# The commit with the most refs, for the details' chips.
	var most: int = 0
	for row: int in list.row_count():
		if (list.row_data(row).get("refs", []) as Array).size() > (list.row_data(most).get("refs", []) as Array).size():
			most = row
	list.select_only(most)
	var wanted: String = String(list.row_data(most)["hash"])
	if not await _wait(func() -> bool: return history.details().commit_oid() == wanted):
		return
	await _shot(out, "%02d-details-refs" % step)
	step += 1
	var header: CommitHeader = history.details().header()
	for chip: RefChip in header.ref_chips():
		if not chip.labels.is_empty():
			var press: InputEventMouseButton = InputEventMouseButton.new()
			press.button_index = MOUSE_BUTTON_LEFT
			press.pressed = true
			chip.gui_input.emit(press)
			await _shot(out, "%02d-details-refs-popover" % step, [header.refs_popover()])
			step += 1
			header.refs_popover().hide()
			break
	# The first two rows with a counted chip, each with its popover open; the
	# first also with a ref's menu over it.
	var counted: Array = []
	for row: int in list.row_count():
		for hit: Array in list.chip_rects(row):
			if (hit[1] as Dictionary).has("labels") and counted.size() < 2:
				counted.append([row, hit])
				break
	for index: int in counted.size():
		var row: int = counted[index][0]
		var hit: Array = counted[index][1]
		var chip: Rect2 = hit[0]
		list.refs_requested.emit(row, Vector2(chip.position.x, chip.end.y), (hit[1] as Dictionary)["labels"])
		await _shot(out, "%02d-refs-popover-row-%d" % [step, row], [history.refs_popover()])
		step += 1
		if index == 0 and history.refs_popover().visible:
			history.refs_popover().choose(0)
			await _shot(out, "%02d-refs-popover-menu" % step, [history.refs_popover(), page.context_menu()])
			step += 1
			page.close_menu()
		history.refs_popover().hide()
	Actions.run_action(&"history.toggle_compact")
	await _shot(out, "%02d-compact" % step)
	step += 1
	Actions.run_action(&"view.theme_light")
	await _shot(out, "%02d-compact-light" % step)
	step += 1
	Actions.run_action(&"view.theme_dark")
	Actions.run_action(&"history.toggle_compact")
	get_window().size = Vector2i(960, 640)
	await _shot(out, "%02d-two-line-narrow" % step)
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("history_rows_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## Saves the window, with `popups` (native windows) drawn over it in order
## where they are on screen.
func _shot(out: String, file_name: String, popups: Array[Window] = []) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var path: String = out.path_join(file_name + ".png")
	var image: Image = get_viewport().get_texture().get_image()
	for popup: Window in popups:
		if not popup.visible:
			continue
		var over: Image = popup.get_texture().get_image()
		over.convert(image.get_format())
		image.blit_rect(over, Rect2i(Vector2i.ZERO, over.get_size()), popup.position - get_window().position)
	image.save_png(path)
	print("SHOT ", path)
