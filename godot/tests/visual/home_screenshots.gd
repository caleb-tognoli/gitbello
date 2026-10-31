extends Node
## Saves screenshots of Home (PLAN §4 Home, M7.5) for visual review: an empty
## library, a full one (dark and light), folder groups, a missing folder, a
## clone running and failing, the Home tab, the Add menu, the forms and a scan.
## Usage: godot --path godot res://tests/visual/home_screenshots.tscn --
##        --repos=<a>;<b>;... --scan=<folder with repositories> --work=<dir> --out=<dir>
## Run with GITBELLO_CONFIG pointing at a scratch config file in an empty
## folder (the library goes next to it). It clones the first repository into
## `<work>/clone`: throwaway repositories only.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000


func _ready() -> void:
	var repos: PackedStringArray = PackedStringArray()
	var out: String = ""
	var scan_root: String = ""
	var work: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repos="):
			repos = arg.trim_prefix("--repos=").split(";", false)
		elif arg.begins_with("--scan="):
			scan_root = arg.trim_prefix("--scan=")
		elif arg.begins_with("--work="):
			work = arg.trim_prefix("--work=")
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	if repos.size() < 2 or out.is_empty() or work.is_empty():
		printerr("home_screenshots: pass -- --repos=a;b;... --scan=<dir> --work=<dir> --out=<dir>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	while main.tab_count() > 0:
		main.close_tab(0)
	var home: Home = main.home()
	var ops: LibraryOps = main.library_ops()

	Actions.run_action(&"view.theme_dark")
	await _shot(out, "01-home_empty_dark")
	Actions.run_action(&"view.theme_light")
	await _shot(out, "02-home_empty_light")
	Actions.run_action(&"view.theme_dark")

	# Recent: the first ones opened (newest last), the rest only added.
	for i: int in repos.size():
		Core.library_add(repos[i])
	for i: int in mini(8, repos.size()):
		main.open_repo(repos[i])
		await _wait(func() -> bool: return main.current_page().session.is_ready())
	Core.library_pin(repos[repos.size() - 1], true)
	while main.tab_count() > 0:
		main.close_tab(0)
	await _summaries(repos)
	await _shot(out, "03-home_dark")
	Actions.run_action(&"view.theme_light")
	await _summaries(repos)
	await _shot(out, "04-home_light")
	Actions.run_action(&"view.theme_dark")

	home.set_group(Home.Group.FOLDER)
	await _summaries(repos)
	await _shot(out, "05-home_grouped")
	home.set_group(Home.Group.NONE)

	home.filter_field().set_text(repos[1].replace("\\", "/").get_file())
	await _shot(out, "06-home_filtered")
	home.filter_field().set_text("")

	var missing: String = work.path_join("moved away")
	Core.library_add(missing)
	home.set_sort(Home.Sort.PATH)
	await get_tree().process_frame
	home.show_row(missing)
	await _wait(func() -> bool: return not Core.repo_summary(missing).is_empty())
	home.show_row(missing)
	await _shot(out, "07-home_missing")
	home.set_sort(Home.Sort.NAME)

	ops.clone(repos[0], work.path_join("clone"))
	await _shot_window(ops.form(), out, "08-clone_form")
	ops.form().submit()
	# A local clone is quick: catch its row in the next frames.
	await get_tree().process_frame
	await get_tree().process_frame
	_save(out, "09-home_clone_running")
	await _wait(func() -> bool: return main.tab_count() > 0)
	await _shot(out, "10-clone_opened")
	ops.clone(work.path_join("no such source"), work.path_join("failed clone"))
	ops.form().submit()
	await _wait(func() -> bool:
		return not ops.clones().is_empty() and not String(ops.clones()[0]["error"]).is_empty())
	Actions.run_action(&"home.open")
	await _shot(out, "11-home_tab_clone_failed")

	home.add_menu().show_popup()
	await _shot_window(home.add_menu().get_popup(), out, "12-add_menu")
	home.add_menu().get_popup().hide()

	ops.create()
	await _shot_window(ops.form(), out, "13-create_form")
	ops.form().hide()
	ops.init_folder(work)
	await _shot_window(ops.form(), out, "14-initialize_form")
	ops.form().hide()

	if not scan_root.is_empty():
		ops.scan(scan_root)
		await _wait(func() -> bool: return not ops.scan_dialog().running() and not ops.scan_dialog().rows().is_empty())
		await _shot_window(ops.scan_dialog(), out, "15-scan")
		ops.scan_dialog().hide()

	Actions.run_action(&"view.theme_light")
	await _summaries(repos)
	await _shot(out, "16-home_tab_light")

	# Narrower layouts (a UI scale shrinks the logical width below the
	# window's minimum): the scroll bar shows and no card may reach under it.
	Actions.run_action(&"view.theme_dark")
	var shot: int = 17
	get_window().size = Vector2i(1000, 600)
	for width: int in [1131, 1000, 940, 920, 900]:
		get_window().content_scale_factor = 1000.0 / float(width)
		await _settle()
		var bar: VScrollBar = home.scroll_container().get_v_scroll_bar()
		var widest: float = 0.0
		for path: String in home.recent_paths():
			widest = maxf(widest, home.card_for(path).get_global_rect().end.x)
		print("CHECK width %d: bar %s at %.0f, cards end at %.0f -> %s" % [width, bar.visible,
				bar.get_global_rect().position.x, widest,
				"ok" if not bar.visible or widest < bar.get_global_rect().position.x else "OVERLAP"])
		await _shot(out, "%02d-home_width_%d" % [shot, width])
		shot += 1
	get_tree().quit(0)


## Waits until the summaries of `paths` on screen arrived (or a while).
func _summaries(paths: PackedStringArray) -> void:
	await _settle()
	await _wait(func() -> bool:
		for path: String in paths:
			if Core.repo_summary(path).is_empty():
				return false
		return true, 5_000)


func _wait(condition: Callable, timeout_ms: int = WAIT_MS) -> void:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline and not condition.call():
		await get_tree().process_frame


func _settle() -> void:
	for i: int in 30:
		await get_tree().process_frame


## Popups are windows of their own; this saves one's content.
func _shot_window(window: Window, dir: String, file_name: String) -> void:
	await _settle()
	var path: String = dir.path_join(file_name + ".png")
	window.get_texture().get_image().save_png(path)
	print("SHOT ", path)


func _shot(dir: String, file_name: String) -> void:
	await _settle()
	_save(dir, file_name)


func _save(dir: String, file_name: String) -> void:
	var path: String = dir.path_join(file_name + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path)
