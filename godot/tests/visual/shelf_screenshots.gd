extends Node
## Read-only shelf layout capture. Pass --repo=<fixture> --out=<directory>
## and set GITBELLO_CONFIG to a scratch config before launching windowed.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func _ready() -> void:
	var repo: String = ""
	var out: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	if repo.is_empty() or out.is_empty():
		get_tree().quit(2)
		return
	get_viewport().gui_embed_subwindows = true
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var deadline: int = Time.get_ticks_msec() + 30_000
	while page.session.shelves().is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if page.session.shelves().is_empty():
		printerr("No shelves: ", page.session.open_error(), " path: ", page.session.repo_path())
		get_tree().quit(3)
		return
	page.show_view(WorktreeView.View.SHELVES)
	while page.changes().diff_view().row_count() == 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	get_viewport().notify_mouse_entered()
	for choice: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + choice))
		await _shot(out.path_join("shelves_" + choice + ".png"))
		var motion: InputEventMouseMotion = InputEventMouseMotion.new()
		motion.position = (page.changes().get_node("%DiscardShelf") as Button).get_global_rect().get_center()
		get_viewport().push_input(motion, true)
		await _shot(out.path_join("shelves_discard_hover_" + choice + ".png"))
		motion.position = Vector2.ZERO
		get_viewport().push_input(motion, true)
		var files: ShelfFileList = page.changes().shelf_files()
		motion.position = files.global_position + Vector2(files.size.x / 2.0, files.row_height() / 2.0)
		get_viewport().push_input(motion, true)
		var click: InputEventMouseButton = InputEventMouseButton.new()
		click.position = motion.position
		click.button_index = MOUSE_BUTTON_RIGHT
		click.pressed = true
		get_viewport().push_input(click, true)
		click.pressed = false
		get_viewport().push_input(click, true)
		await _shot(out.path_join("shelf_file_menu_" + choice + ".png"))
		page.changes().context_menu().hide()
	Actions.run_action(&"shelf.rename")
	await _shot(out.path_join("shelves_inline_name.png"))
	# Unchanged name: leaving the field performs no write.
	(page.changes().get_node("%ShelfNameEdit") as LineEdit).release_focus()
	var names: ItemList = page.changes().shelf_list().names()
	names.item_clicked.emit(0, Vector2.ZERO, MOUSE_BUTTON_LEFT)
	await _shot(out.path_join("shelves_collapsed.png"))
	names.item_clicked.emit(0, Vector2.ZERO, MOUSE_BUTTON_LEFT)
	Actions.run_action(&"shelf.filter_branches")
	await _shot(out.path_join("shelf_branches.png"))
	page.changes().shelf_list().branch_picker().hide()
	Actions.run_action(&"shelf.scope_none")
	await _shot(out.path_join("shelves_no_branches.png"))
	Actions.run_action(&"shelf.scope_all")
	deadline = Time.get_ticks_msec() + 30_000
	while page.changes().diff_view().row_count() == 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	get_window().size = Vector2i(960, 680)
	await _shot(out.path_join("shelves_compact.png"))
	page.show_view(WorktreeView.View.CHANGES)
	deadline = Time.get_ticks_msec() + 30_000
	while String(page.session.diff_info().get("state", "none")) == "loading" and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await _shot(out.path_join("changes.png"))
	page.changes().list_header().context_menu_requested.emit(Vector2(200, 230))
	await _shot(out.path_join("changes_header_menu.png"))
	page.changes().context_menu().hide()
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit()


func _shot(path: String) -> void:
	for frame: int in 10:
		await get_tree().process_frame
	RenderingServer.force_draw()
	var error: Error = get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path, " ", error)
