extends Node
## Ignoring changed files (M7.7a), one numbered screenshot per step: the
## files' menu with its Ignore submenu, the dialog on a folder rule with its
## preview, a quick rule on a tracked file opening the dialog with the
## untrack choice, the list and toast after untracking, and the dialog in the
## light theme. Pass --repo=<CLI fixture repo> --out=<directory>, set
## GITBELLO_CONFIG to a scratch config and launch windowed. It writes build
## output into the repo, adds rules and untracks app.txt: throwaway fixtures only.

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _out: String = ""
var _step: int = 0


func _ready() -> void:
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or _out.is_empty():
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	for file: String in ["build/debug/x.o", "build/y.o"]:
		DirAccess.make_dir_recursive_absolute(repo.path_join(file).get_base_dir())
		var handle: FileAccess = FileAccess.open(repo.path_join(file), FileAccess.WRITE)
		handle.store_string("output\n")
		handle.close()
	get_viewport().gui_embed_subwindows = true
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() == 4):
		get_tree().quit(3)
		return
	Actions.run_action(&"view.theme_dark")
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var list: ChangeList = changes.list()
	var ops: IgnoreOps = changes.ignore_ops()
	var form: FormDialog = ops.form()

	# Right-click a build file: the menu, then its Ignore submenu.
	var row: int = session.change_index("build/debug/x.o")
	list.select_only(row)
	await _shot("changes")
	_right_click(list.global_position + Vector2(list.size.x / 3.0, (float(row) + 0.5) * list.row_height()))
	await _wait(func() -> bool: return changes.context_menu().visible)
	await _shot("files-menu")
	var menu: PopupMenu = changes.context_menu()
	var sub: PopupMenu = changes.ignore_menu()
	var index: int = -1
	for i: int in menu.item_count:
		if menu.get_item_submenu_node(i) == sub:
			index = i
	var item_height: float = float(menu.size.y) / float(maxi(menu.item_count, 1))
	sub.popup(Rect2i(menu.position + Vector2i(menu.size.x - 4, int(item_height * index)), Vector2i.ZERO))
	await _shot("ignore-submenu")
	sub.hide()
	menu.hide()

	# The dialog: the parent folder, with what it hides.
	Actions.run_action(&"changes.ignore")
	await _wait(func() -> bool: return form.visible)
	var rules: OptionButton = form.field("rule") as OptionButton
	for i: int in rules.item_count:
		if rules.get_item_text(i) == "The folder build/":
			rules.select(i)
			rules.item_selected.emit(i)
	await _wait(func() -> bool: return int(ops.preview().get("hidden_count", 0)) == 2)
	await _shot("dialog-folder")
	rules.show_popup()
	await _shot("dialog-rule-choices")
	rules.get_popup().hide()
	form.hide()

	# A quick rule on a tracked file opens the dialog with the untrack choice.
	list.select_only(session.change_index("app.txt"))
	Actions.run_action(&"changes.ignore_file")
	await _wait(func() -> bool: return form.visible and int(ops.preview().get("tracked_count", 0)) == 1)
	await _shot("dialog-untrack")
	Actions.run_action(&"view.theme_light")
	await _shot("dialog-untrack-light")
	Actions.run_action(&"view.theme_dark")
	form.submit()
	await _wait(func() -> bool: return session.change_index(".gitignore") >= 0 and ops.can_undo())
	list.select_only(session.change_index("app.txt"))
	await _shot("after-untrack", 30)
	get_tree().quit(0)


func _right_click(at: Vector2) -> void:
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	get_viewport().push_input(motion, true)
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.position = at
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	get_viewport().push_input(click, true)
	click.pressed = false
	get_viewport().push_input(click, true)


func _wait(condition: Callable, timeout_ms: int = 30_000) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await get_tree().process_frame
	print("TIMEOUT at step ", _step + 1)
	return bool(condition.call())


## Saves `NN-<name>.png` after the frame settles.
func _shot(name_text: String, frames: int = 10) -> void:
	for frame: int in frames:
		await get_tree().process_frame
	RenderingServer.force_draw()
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, name_text])
	var error: Error = get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path, " ", error)
