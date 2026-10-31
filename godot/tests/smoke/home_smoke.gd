extends SmokeTest
## Home (PLAN §4 Home, M7.5): the no-tab state and the Home tab, opening from
## the filter with the keyboard, remove with Undo, a missing folder
## relocated, scan, clone rows and Create with a template.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("home_smoke: no --fixtures, skipped")
		return
	var repo_1: String = fixtures.path_join("repo-1")
	var repo_2: String = fixtures.path_join("repo-2")
	var repo_3: String = fixtures.path_join("repo-3")
	for path: String in [repo_1, repo_2, repo_3]:
		Core.library_add(path)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	while main.tab_count() > 0:
		main.close_tab(0)
	await get_tree().process_frame
	var home: Home = main.home()
	var ops: LibraryOps = main.library_ops()
	expect(main.home_shown() and home.is_visible_in_tree(), "Home fills the window without tabs")
	expect(not main.has_home_tab(), "no Home tab without repository tabs")
	expect(await wait_until(func() -> bool: return _has(home.listed(), repo_2)), "library repositories are listed")

	# Filter and open with the keyboard only.
	home.filter_field().focus_text()
	await get_tree().process_frame
	type_text("repo-2")
	await get_tree().process_frame
	await get_tree().process_frame
	expect(home.listed().size() >= 1 and Paths.same(home.listed()[0], repo_2), "the filter puts the match first")
	press("Enter", home.get_viewport())
	expect(await wait_until(func() -> bool: return main.tab_count() == 1), "Enter opens the first match")
	expect(Paths.same(main.current_page().repo_path(), repo_2), "the filtered repository opens")
	expect(not main.home_shown(), "Home hides once a repository is open")
	Actions.run_action(&"home.open")
	await get_tree().process_frame
	expect(home.filter_field().text().is_empty(), "Home starts with an empty filter each time")
	main.close_tab(main.tab_count())

	# + opens one Home tab, which becomes the chosen repository's tab.
	(main.get_node("%AddButton") as Button).pressed.emit()
	await get_tree().process_frame
	expect(main.has_home_tab() and main.home_shown(), "+ opens the Home tab")
	expect_eq(main.tab_bar().tab_count, 2, "the Home tab is a tab of its own")
	Actions.run_action(&"home.open")
	expect_eq(main.tab_bar().tab_count, 2, "Home opens at most once")
	expect(home.row_for(repo_2) != null and home.row_for(repo_2).find_child("Open", true, false) != null,
			"an open repository is marked on Home")
	home.chosen.emit(repo_3)
	expect(await wait_until(func() -> bool: return main.tab_count() == 2), "choosing a repository opens it")
	expect(not main.has_home_tab(), "the chosen repository replaces the Home tab")
	expect_eq(main.tab_bar().tab_count, 2, "no tab is left behind")
	Actions.run_action(&"home.open")
	home.chosen.emit(repo_2)
	await get_tree().process_frame
	expect_eq(main.tab_count(), 2, "choosing an open repository opens no tab")
	expect(Paths.same(main.current_page().repo_path(), repo_2), "choosing an open repository focuses its tab")
	expect(not main.has_home_tab(), "and closes the Home tab")

	# Summaries arrive for the rows on screen.
	Actions.run_action(&"home.open")
	expect(await wait_until(func() -> bool: return not Core.repo_summary(repo_1).is_empty()),
			"Home reads the summaries of visible rows")

	# Right-click on a row or a Recent card opens the same menu where clicked.
	var click: Vector2 = Vector2(40, 6)
	# A repository counts as opened once git confirmed it (asynchronously).
	expect(await wait_until(func() -> bool: return home.card_for(repo_3) != null), "opened repositories are Recent")
	await get_tree().process_frame
	var card: Control = home.card_for(repo_3)
	var grid: GridContainer = card.get_parent() as GridContainer
	var gap: int = grid.get_theme_constant(&"h_separation")
	expect(grid.size.x > 0.0 and card.size.x * grid.columns + gap * (grid.columns - 1) >= grid.size.x - 2.0,
			"Recent's cards stretch to share the full width")
	# The first row and a card: lower ones may be moved up to stay on screen.
	for control: Control in [home.row_for(home.listed()[0]), home.card_for(repo_3)]:
		expect(control != null, "a row and a card to right-click")
		if control == null:
			continue
		var event: InputEventMouseButton = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_RIGHT
		event.pressed = true
		event.position = click
		control.gui_input.emit(event)
		var menu: PopupMenu = home.row_menu()
		expect(menu.visible, "right-click opens the menu")
		# Where clicked, or moved up just enough to stay on screen.
		var at: Vector2i = Vector2i(control.get_screen_position() + click)
		expect(menu.position.x == at.x and menu.position.y <= at.y and menu.position.y + menu.size.y >= at.y,
				"the menu opens where clicked: %s at %s" % [menu.position, at])
		expect_eq(menu.get_item_text(0), tr("Open"), "the menu is the repository menu")
		menu.hide()
	var more: Button = home.row_for(home.listed()[0]).find_child("More", true, false) as Button
	more.pressed.emit()
	var menu_rect: Rect2i = Rect2i(home.row_menu().position, home.row_menu().size)
	var below: int = int(more.get_screen_position().y + more.size.y)
	expect(home.row_menu().visible and menu_rect.end.x == int(more.get_screen_position().x + more.size.x)
			and menu_rect.position.y <= below and menu_rect.end.y >= int(more.get_screen_position().y),
			"⋯ opens the menu under it (or just above, to stay on screen), right edges lined up")
	home.row_menu().hide()

	# Remove with Undo.
	ops.remove(repo_1)
	await get_tree().process_frame
	expect(not _in_library(repo_1), "Remove takes the repository off the list")
	expect(main.toasts().press_fix("Undo"), "the removal offers Undo")
	expect(_in_library(repo_1), "Undo brings it back")

	# A missing folder is marked, then relocated.
	var moved: String = fixtures.path_join("moved away")
	Core.library_add(moved)
	await get_tree().process_frame
	await get_tree().process_frame
	home.show_row(moved)
	expect(await wait_until(func() -> bool:
		var row: Control = home.row_for(moved)
		return row != null and _texts(row).has(tr("Folder missing"))), "a missing folder is marked on its row")
	var copy: String = fixtures.path_join("home relocated")
	DirAccess.make_dir_recursive_absolute(copy)
	ops.relocate_to(copy, moved)
	expect(await wait_until(func() -> bool:
		return "".join(main.toasts().toast_texts()).contains(tr("Not a git repository"))),
			"a folder outside any repository is refused")
	expect(_in_library(moved), "a refused location changes nothing")
	ops.relocate_to(fixtures.path_join("repo-4"), moved)
	expect(await wait_until(func() -> bool: return _in_library(fixtures.path_join("repo-4")) and not _in_library(moved)),
			"Change location points the entry at the repository")

	# Create with a template opens the new repository.
	ops.create()
	var form: FormDialog = ops.form()
	_set_line(form, "name", "home created")
	_set_line(form, "location", fixtures)
	var templates: OptionButton = form.field("gitignore") as OptionButton
	for i: int in templates.item_count:
		if templates.get_item_text(i) == "Rust":
			templates.select(i)
			templates.item_selected.emit(i)
	expect(form.submit(), "create starts")
	var created: String = fixtures.path_join("home created")
	expect(await wait_until(func() -> bool:
		return main.current_page() != null and Paths.same(main.current_page().repo_path(), created)),
			"the created repository opens")
	expect(FileAccess.file_exists(created.path_join(".gitignore")), "Create writes the template")
	expect(_in_library(created), "the created repository joins the library")

	# Without starter files there is no first commit: nothing to amend.
	ops.create()
	_set_line(form, "name", "home unborn")
	_set_line(form, "location", fixtures)
	expect(form.submit(), "create without starter files starts")
	var unborn: String = fixtures.path_join("home unborn")
	expect(await wait_until(func() -> bool:
		return (main.current_page() != null and Paths.same(main.current_page().repo_path(), unborn)
				and main.current_page().session.is_ready())), "the empty repository opens")
	expect(not main.current_page().changes().commit_box().can_amend(), "an unborn repository cannot enter amend mode")
	expect(not Actions.is_enabled(&"commit.amend"), "Amend is unavailable without HEAD")

	_check_progress(main, ops)

	# Scan: two of three found repositories are added.
	var scan_root: String = fixtures.path_join("scän root")
	for repo_name: String in ["one", "two", "three"]:
		var job: int = Core.create_repository(scan_root.path_join(repo_name), {"initial_branch": "main"})
		expect(job >= 0, "scan fixture job starts")
		# A created repository joins the library when its job ends.
		expect(await wait_until(func() -> bool: return _in_library(scan_root.path_join(repo_name))),
				"scan fixture %s" % repo_name)
	for repo_name: String in ["one", "two", "three"]:
		Core.library_remove(scan_root.path_join(repo_name))
	ops.scan(scan_root)
	var scan: ScanDialog = ops.scan_dialog()
	expect(await wait_until(func() -> bool: return not scan.running() and scan.rows().size() == 3),
			"the scan finds three repositories")
	expect_eq(scan.checked().size(), 3, "new repositories start checked")
	scan.set_checked(scan_root.path_join("three"), false)
	expect_eq(scan.checked().size(), 2, "one is unchecked")
	scan.get_ok_button().pressed.emit()
	expect(_in_library(scan_root.path_join("one")) and _in_library(scan_root.path_join("two"))
			and not _in_library(scan_root.path_join("three")), "Add selected adds the checked repositories")

	# Clone: a row while it runs, then the clone opens from Home.
	Actions.run_action(&"home.open")
	ops.clone(repo_3, fixtures.path_join("home clone"))
	expect(ops.form().submit(), "clone starts")
	expect_eq(ops.clones().size(), 1, "a running clone has a row")
	var cloned: String = fixtures.path_join("home clone")
	expect(await wait_until(func() -> bool:
		return main.current_page() != null and Paths.same(main.current_page().repo_path(), cloned)),
			"a clone started from Home opens there")
	expect(ops.clones().is_empty(), "the clone's row goes when it ends")
	ops.clone(fixtures.path_join("no such source"), fixtures.path_join("home failed clone"))
	expect(ops.form().submit(), "a clone of a missing source starts")
	expect(await wait_until(func() -> bool:
		return ops.clones().size() == 1 and not String(ops.clones()[0]["error"]).is_empty()),
			"a failed clone keeps its row with the error")
	ops.dismiss_clone(int(ops.clones()[0]["job"]))
	expect(ops.clones().is_empty(), "Dismiss removes the failed row")

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


## Job progress in the form and in clone rows: indeterminate until git gives
## a percentage, other jobs ignored, reset when the job ends or is cancelled.
func _check_progress(main: Main, ops: LibraryOps) -> void:
	ops.create()
	var bar: ProgressBar = ops._progress
	ops._form_job = 190019
	ops._set_form_busy(true)
	expect(bar.visible and bar.indeterminate, "a job starts indeterminate before any progress")
	ops._on_job_progress(190018, "", "", 50, "Unrelated job")
	expect(bar.indeterminate, "another job cannot change the progress")
	ops._on_job_progress(190019, "", "", -1, "Enumerating objects: 5, done.")
	expect(bar.indeterminate, "an unknown percentage stays indeterminate")
	ops._on_job_progress(190019, "", "", 0, "Receiving objects: 0% (0/10)")
	expect(not bar.indeterminate and bar.value == 0.0, "zero is a known percentage")
	ops._on_job_progress(190019, "", "", 45, "Receiving objects: 45%")
	expect_eq(bar.value, 45.0, "a known percentage is shown")
	ops._on_job_cancelled(190018, "", "")
	expect(ops.running(), "another job cannot cancel this one")
	ops._on_job_cancelled(190019, "", "")
	expect(not ops.running() and not bar.visible, "cancelling hides the progress")
	expect(not bar.indeterminate and bar.value == 0.0, "cancelling resets the progress")
	ops._on_job_progress(190019, "", "", 99, "Late progress")
	expect(not bar.visible and bar.value == 0.0, "late progress of a cancelled job is ignored")
	ops.form().hide()

	Actions.run_action(&"home.open")
	ops._clones[190030] = {"job": 190030, "url": "u", "path": "p/fake", "name": "fake", "percent": -1,
		"text": "", "error": ""}
	ops.clones_changed.emit()
	var row_bar: Callable = func() -> ProgressBar:
		var bars: Array[Node] = main.home().find_children("*", "ProgressBar", true, false)
		return bars[0] as ProgressBar if not bars.is_empty() else null
	expect(row_bar.call() != null and (row_bar.call() as ProgressBar).indeterminate,
			"a clone row starts indeterminate")
	ops._on_job_progress(190030, "", "", 45, "Receiving objects: 45%")
	expect(row_bar.call() != null and not (row_bar.call() as ProgressBar).indeterminate
			and (row_bar.call() as ProgressBar).value == 45.0, "a clone row shows a known percentage")
	ops._on_job_cancelled(190030, "", "")
	await get_tree().process_frame
	expect(ops.clones().is_empty() and row_bar.call() == null, "a cancelled clone's row goes")


static func _has(paths: PackedStringArray, path: String) -> bool:
	for p: String in paths:
		if Paths.same(p, path):
			return true
	return false


static func _in_library(path: String) -> bool:
	for row: Dictionary in Core.library_rows():
		if Paths.same(String(row["path"]), path):
			return true
	return false


## Texts of the labels under `node`.
static func _texts(node: Node) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for label: Node in node.find_children("*", "Label", true, false):
		out.append((label as Label).text)
	return out


func _set_line(form: FormDialog, key: String, text: String) -> void:
	var line: LineEdit = form.field(key) as LineEdit
	line.text = text
	line.text_changed.emit(text)
