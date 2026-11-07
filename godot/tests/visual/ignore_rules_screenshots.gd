extends Node
## The ignore rules viewer and the rest of M7.7b, one numbered screenshot per
## step, actions included: the folder hint, its close menu and what Ignore
## does; Repository → Ignore rules… on each file (chips), a chip's menu, the
## Add form, its ▾ templates and template rules before and after adding, Stop tracking
## asked and done, a rule removed, the light theme; "Show ignored files", its
## menu and Stop ignoring; the Ignore dialog's Where choices and a rule added
## to the global file. Pass --work=<empty directory> --out=<dir> and launch
## windowed with GITBELLO_CONFIG and GIT_CONFIG_GLOBAL set to scratch files:
## it builds a repository in <work> and sets `core.excludesFile` in that
## global config (it quits without one).

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _out: String = ""
var _step: int = 0


func _ready() -> void:
	var work: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--work="):
			work = arg.trim_prefix("--work=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if work.is_empty() or _out.is_empty() or OS.get_environment("GIT_CONFIG_GLOBAL").is_empty():
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var repo: String = work.path_join("game")
	var global_file: String = work.path_join("global ignore")
	_build_repo(repo, global_file)
	get_viewport().gui_embed_subwindows = true
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_index("notes.txt") >= 0):
		get_tree().quit(3)
		return
	Actions.run_action(&"view.theme_dark")
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var list: ChangeList = changes.list()
	var ops: IgnoreOps = changes.ignore_ops()
	var gitignore: String = repo.path_join(".gitignore")

	# The folder hint: the button, its close menu, then Ignore.
	await _wait(func() -> bool: return changes.hint_bar().visible)
	await _shot("hint")
	changes.open_hint_menu()
	await _shot("hint-close-menu")
	changes.hint_menu().hide()
	changes.ignore_hint_folder()
	await _wait(func() -> bool: return (_read(gitignore).contains("/node_modules/")
			and session.change_index("node_modules/pkg-0/index.js") < 0))
	await _shot("hint-ignored")

	# The viewer: each file as a chip, what a line hides beside the lines.
	Actions.run_action(&"repo.ignore_rules")
	var dialog: IgnoreRulesDialog = main.ignore_rules_dialog()
	await _wait(func() -> bool: return dialog.sources().size() >= 4)
	dialog.select_line_text("*.log")
	await _shot("viewer-root-rule")
	dialog.select_line_text("/build/")
	await _shot("viewer-folder-rule")
	for entry: Array in [[1, "viewer-nested"], [2, "viewer-my-computer"], [3, "viewer-global"]]:
		dialog.select_source(int(entry[0]))
		await _shot(String(entry[1]))
	var chip: IgnoreSourceChip = dialog.chip(3)
	chip.menu_requested.emit(chip.get_screen_position() + Vector2(12.0, chip.size.y))
	await _shot("chip-menu")
	dialog.chip_menu().hide()

	# Add: the form, the ▾ templates, a template's missing lines, then added.
	dialog.select_source(0)
	var form: FormDialog = ops.form()
	dialog.press("add")
	await _wait(func() -> bool: return form.visible)
	await _shot("add-form")
	form.hide()
	dialog.press("add_more")
	await _shot("add-templates")
	var add: PopupMenu = dialog.add_menu()
	add.hide()
	for i: int in add.item_count:
		if add.get_item_text(i) == "Godot":
			add.id_pressed.emit(add.get_item_id(i))
	await _wait(func() -> bool: return form.visible and not ops.preview().is_empty())
	await _shot("add-template-form")
	form.submit()
	await _wait(func() -> bool: return _read(gitignore).contains(".godot/") and dialog.lines().size() > 8)
	await _shot("template-added")

	# Stop tracking: asked, then done.
	dialog.select_line_text("*.log")
	dialog.press("untrack")
	await _shot("stop-tracking")
	ops.untrack_confirmation().get_ok_button().pressed.emit()
	await _wait(func() -> bool: return dialog.recap().begins_with("3 files") and not dialog.recap().contains("tracked"))
	await _shot("stop-tracking-done")

	# Remove rule.
	dialog.select_line_text("unused/")
	await _shot("remove-rule")
	dialog.press("remove")
	await _wait(func() -> bool: return not _read(gitignore).contains("unused/") and not dialog.select_line_text("unused/"))
	await _shot("remove-rule-done")
	Actions.run_action(&"view.theme_light")
	dialog.select_line_text("*.log")
	await _shot("viewer-light")
	Actions.run_action(&"view.theme_dark")
	dialog.hide()

	# Show ignored files: muted rows at the end, their menu, Stop ignoring.
	changes.filter_field().set_option("ignored", true)
	await _wait(func() -> bool: return session.change_index("a.log") >= 0)
	var row: int = session.change_index("a.log")
	list.select_only(row)
	await _shot("show-ignored-files")
	_right_click(list.global_position + Vector2(list.size.x / 3.0, (float(row) + 0.5) * list.row_height()))
	await _wait(func() -> bool: return changes.context_menu().visible)
	await _shot("ignored-file-menu")
	changes.context_menu().hide()
	Actions.run_action(&"changes.stop_ignoring")
	await _wait(func() -> bool:
		var at_row: int = session.change_index("a.log")
		return at_row >= 0 and not bool(list.row(at_row).get("ignored", false)))
	await _shot("stop-ignoring-done")
	changes.filter_field().set_option("ignored", false)

	# The Ignore dialog's Where choices, then a rule in the global file.
	await _wait(func() -> bool: return session.change_index("notes.txt") >= 0)
	list.select_only(session.change_index("notes.txt"))
	Actions.run_action(&"changes.ignore")
	await _wait(func() -> bool: return ops.form().visible)
	var where: OptionButton = ops.form().field("where") as OptionButton
	where.show_popup()
	await _shot("where-choices")
	where.get_popup().hide()
	where.select(IgnoreOps.GLOBAL)
	where.item_selected.emit(IgnoreOps.GLOBAL)
	await _wait(func() -> bool: return not ops.preview().is_empty())
	await _shot("where-global")
	ops.form().submit()
	await _wait(func() -> bool: return _read(global_file).contains("notes.txt") and session.change_index("notes.txt") < 0)
	await _shot("global-added")
	get_tree().quit(0)


static func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _build_repo(repo: String, global_file: String) -> void:
	DirAccess.make_dir_recursive_absolute(repo)
	_git(repo, ["init", "-q", "-b", "main"])
	_write(repo, ".gitignore", "# Logs\n*.log\n!keep.log\n\n# Build output\n/build/\nunused/\n")
	_write(repo, "src/.gitignore", "*.tmp\n")
	_write(repo, "src/main.gd", "extends Node\n")
	_write(repo, "tracked.log", "t\n")
	_git(repo, ["add", ".gitignore", "src"])
	_git(repo, ["add", "-f", "tracked.log"])
	_git(repo, ["-c", "user.name=Ada", "-c", "user.email=ada@example.com", "commit", "-q", "-m", "Start"])
	var exclude: String = repo.path_join(".git/info/exclude")
	_write(repo, ".git/info/exclude", FileAccess.get_file_as_string(exclude) + "docs/drafts/\n")
	var handle: FileAccess = FileAccess.open(global_file, FileAccess.WRITE)
	handle.store_string("*.bak\n.DS_Store\n")
	handle.close()
	_git(repo, ["config", "--global", "core.excludesFile", global_file])
	for file: String in ["a.log", "server.log", "keep.log", "build/game.exe", "build/game.pck", "src/cache.tmp",
			"docs/drafts/plan.md", "scene.bak", "notes.txt"]:
		_write(repo, file, "x\n")
	for i: int in 6:
		_write(repo, "node_modules/pkg-%d/index.js" % i, "x\n")


func _write(repo: String, file: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(repo.path_join(file).get_base_dir())
	var handle: FileAccess = FileAccess.open(repo.path_join(file), FileAccess.WRITE)
	handle.store_string(text)
	handle.close()


static func _git(repo: String, args: PackedStringArray) -> void:
	OS.execute("git", PackedStringArray(["-C", repo]) + args)


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
