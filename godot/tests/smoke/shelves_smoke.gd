extends SmokeTest
## M6.5 P4 acceptance: shelve a file, leave changes behind on a switch, come
## back and restore them from the offer, preview and restore a shelf from the
## Shelved section, and discard a shelf with undo. Uses fixture `repo-11`
## (app.txt edited, notes.txt untracked, a stash "work in progress" on main);
## the app runs git. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
var _mouse_entered: bool = false


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("shelves_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-11")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	var operation_errors: Array[String] = []
	session.job_finished.connect(func(_id: int, label: String, ok: bool, error: Dictionary) -> void:
		if not ok:
			operation_errors.append("%s: %s" % [label, error]))
	expect(await wait_until(func() -> bool: return session.change_count() == 2 and session.shelves().size() == 1),
			"repo-11 has two changes and one stash")
	press("Ctrl+Shift+G")
	var view: ChangesView = page.changes()
	var shelves: ShelfList = view.shelf_list()
	expect(not shelves.visible, "Changes does not contain the shelf browser")
	expect(page.active_view().shelves_button().visible, "a repository with a stash shows Shelves")
	expect(Actions.run_action(&"view.shelves"), "Shelves opens through the registry")
	expect(shelves.visible and shelves.shelf_count() == 1, "the dedicated view lists the fixture's stash")
	expect("work in progress" in " ".join(shelves.row_texts()), "the stash is named in the browser")
	expect(not view.commit_box().is_visible_in_tree(), "Shelves has no commit form")
	expect(not Actions.is_enabled(&"changes.commit"), "commit is disabled in Shelves")
	press("Ctrl+Shift+G")

	# Shelve app.txt (highlighted first) under a name.
	var list: ChangeList = view.list()
	expect_eq(list.path_at(list.cursor), "app.txt", "app.txt is highlighted")
	expect(Actions.run_action(&"changes.shelve"), "Shelve selected files… runs")
	var ops: RepoOps = page.ops()
	var form: FormDialog = ops.form()
	expect(await wait_until(func() -> bool: return form.visible), "the shelve form asks for a name")
	(form.field("name") as LineEdit).text = "app edit"
	expect(form.submit(), "the shelve form submits")
	expect(await wait_until(func() -> bool: return session.change_count() == 1 and shelves.shelf_count() == 2),
			"app.txt was shelved: %d changes, %d shelves" % [session.change_count(), shelves.shelf_count()])
	expect_eq(read_file(repo.path_join("app.txt")), "v2\n", "app.txt is back to the last commit")
	# Real pointer input on two distinct flat rows (the old tree rebuilt itself
	# during native mouse selection and failed in the windowed app).
	for frame: int in 3:
		await get_tree().process_frame
	_click_at(page.active_view().shelves_button().get_global_rect().get_center())
	await get_tree().process_frame
	expect_eq(page.view, WorktreeView.View.SHELVES, "clicking the navigation button opens Shelves")
	expect(shelves.select_shelf(String(_shelf(session, "app edit")["oid"])), "select the newer shelf first")
	var names: ItemList = shelves.names()
	var older_row: int = shelves.row_for_shelf(String(_shelf(session, "work in progress")["oid"]))
	_click_at(names.global_position + names.get_item_rect(older_row).get_center())
	expect(await wait_until(func() -> bool: return String(view.selected_shelf().get("name", "")) == "work in progress"),
			"clicking a different shelf selects it")
	expect(await wait_until(func() -> bool: return _diff_has(view.diff_view(), "stashed change")),
			"clicking a shelf opens its saved file preview")
	expect_eq(names.item_count, 3, "two shelf names and one branch heading, without files")
	expect_eq(shelves.branch_groups(), PackedStringArray(["main"]), "shelves are grouped by branch")
	expect(not names.is_item_selectable(0), "branch headings cannot be selected")
	expect_eq(names.get_item_text(1), "app edit", "shelf rows contain only names")
	_click_at(names.global_position + names.get_item_rect(0).get_center())
	await get_tree().process_frame
	expect_eq(names.item_count, 1, "clicking the branch heading collapses its shelves")
	expect(not shelves.branch_expanded("main"), "branch is collapsed")
	expect_eq(String(view.selected_shelf().get("name", "")), "work in progress", "collapsing preserves the detail selection")
	session.refresh()
	await get_tree().process_frame
	expect(not shelves.branch_expanded("main"), "refresh preserves the collapsed state")
	_click_at(names.global_position + names.get_item_rect(0).get_center())
	await get_tree().process_frame
	expect_eq(names.item_count, 3, "clicking again expands the branch")
	shelves.filter_field().set_text("APP EDIT")
	expect_eq(shelves.row_texts(), PackedStringArray(["app edit"]), "name filtering ignores case")
	shelves.filter_field().set_text("no matching shelf")
	expect(view.selected_shelf().is_empty(), "no-match filtering clears the selected shelf")
	expect(not view.shelf_files_split().visible and not view.diff_panel().visible, "an empty filter hides the whole right-hand file/diff area")
	expect(not (view.get_node("%ShelfDetails") as Control).visible, "empty filtering hides the details too")
	expect(not Actions.is_enabled(&"shelf.restore"), "no-match filtering disables shelf actions")
	expect(not (view.get_node("%RestoreShelf") as Button).is_visible_in_tree(), "empty results hide the title-row actions")
	shelves.filter_field().set_text("")
	press("Ctrl+F")
	expect(shelves.filter_field().text_box().has_focus(), "Ctrl+F focuses the shelf-name filter")
	press("Escape")
	press("Ctrl+Shift+G")

	# Switch with notes.txt still changed: leave it on main.
	var created: bool = await _job_ok(session, session.create_branch("topic", "HEAD", false))
	expect(created, "topic created")
	ops.checkout_branch("topic")
	var dialog: ConfirmationDialog = ops.switch_dialog()
	expect(await wait_until(func() -> bool: return dialog.visible), "the switch asks what to do with the changes")
	ops.leave_button().pressed.emit()
	expect(await wait_until(func() -> bool: return session.current_branch() == "topic" and session.change_count() == 0),
			"switched to topic without the changes")
	expect(not view.offer_bar().visible, "no offer on topic")
	expect(page.active_view().shelves_button().visible, "other branches' shelves keep the button visible")
	expect(Actions.run_action(&"view.shelves"), "shelves can be opened on a clean branch")
	expect(not shelves.branch_expanded("main") and shelves.branch_expanded("topic"), "only the current branch starts expanded")
	expect_eq(names.item_count, 1, "other branches initially show only their heading")
	expect(shelves.select_shelf(String(_shelf(session, "app edit")["oid"])), "explicit selection opens the shelf's branch")
	expect(await wait_until(func() -> bool: return view.diff_panel().visible and view.diff_view().row_count() > 0),
			"a clean working copy still shows the shelf preview")
	expect(not view.empty_state().visible, "No local changes does not cover the shelf preview")
	expect(Actions.run_action(&"shelf.scope_current"), "This branch filter runs")
	expect(view.selected_shelf().is_empty(), "topic has no shelves of its own")
	expect(not Actions.is_enabled(&"shelf.restore"), "nothing can be restored in an empty scope")
	expect(Actions.run_action(&"shelf.scope_all"), "All branches filter runs")
	expect(not view.selected_shelf().is_empty(), "other branches' shelves can be selected")
	# A shelf on a second branch exercises choosing several branches at once.
	write_file(repo.path_join("topic.txt"), "topic work\n")
	session.refresh()
	expect(await wait_until(func() -> bool: return session.change_count() == 1), "topic edit is seen")
	expect(await _job_ok(session, session.shelve(PackedStringArray(["topic.txt"]), "topic work")), "shelf on topic created")
	expect(await wait_until(func() -> bool: return not _shelf(session, "topic work").is_empty()), "topic shelf listed")
	expect(Actions.run_action(&"shelf.filter_branches"), "branch picker opens through the registry")
	expect(shelves.branch_picker().visible, "branch picker is visible")
	var main_check: CheckBox = shelves.branch_check("main")
	var topic_check: CheckBox = shelves.branch_check("topic")
	expect(main_check != null and topic_check != null, "picker lists both branches")
	main_check.pressed.emit()
	expect_eq(shelves.row_texts(), PackedStringArray(["topic work"]), "one branch can be excluded")
	topic_check.pressed.emit()
	expect(shelves.row_texts().is_empty(), "no selected branches produces an empty list")
	expect_eq((shelves.get_node("%NoShelvesMatch") as Label).text, "No branches selected.", "the reason appears in the list")
	expect(not view.shelf_files_split().is_visible_in_tree(), "no duplicate message or split panes on the right")
	main_check.pressed.emit()
	topic_check.pressed.emit()
	expect_eq(shelves.selected_branches().size(), 2, "several branches can be selected together")
	expect_eq(shelves.branch_groups(), PackedStringArray(["topic", "main"]), "current branch first, with separate branch groups")
	expect(view.shelf_files_split().visible, "the right-hand panes return with a selection")
	expect_eq(shelves.branch_badge().count, 2, "the filter uses the shared branch count badge")
	var has_badge: bool = false
	for child: Node in main_check.get_children():
		if child is CountBadge:
			has_badge = (child as CountBadge).count == 3
	expect(has_badge, "branch shelf counts use the same CountBadge component as navigation")
	expect(Actions.run_action(&"shelf.scope_all"), "select all branches")
	expect(shelves.all_branches(), "all includes branches added later")
	shelves.branch_picker().hide()
	expect(await _job_ok(session, session.discard_shelf(String(_shelf(session, "topic work")["oid"]))), "remove the temporary topic shelf")
	press("Ctrl+Shift+G")

	# Back on main: the changes left there are offered back.
	ops.checkout_branch("main")
	expect(await wait_until(func() -> bool: return session.current_branch() == "main"), "back on main")
	expect(await wait_until(func() -> bool: return view.offer_bar().visible), "the offer shows on main")
	expect(await wait_until(func() -> bool: return view.offer_label_text() == "1 change was left on main"),
			"it counts the changes: %s" % view.offer_label_text())
	expect(Actions.run_action(&"shelf.restore_left"), "Restore runs")
	expect(await wait_until(func() -> bool: return session.change_count() == 1 and not view.offer_bar().visible),
			"notes.txt is back and the offer is gone")
	expect_eq(read_file(repo.path_join("notes.txt")), "untracked\n", "notes.txt has its content")

	# Preview a shelved file, then restore that shelf.
	var shelf: Dictionary = _shelf(session, "app edit")
	expect(not shelf.is_empty(), "the app edit shelf is listed")
	expect(Actions.run_action(&"view.shelves"), "open Shelves to preview the saved edit")
	shelves.select_shelf(String(shelf["oid"]))
	expect(await wait_until(func() -> bool: return view.shelf_files().choose_path("app.txt")),
			"its files load: %s" % [shelves.row_texts()])
	var diff: DiffView = view.diff_view()
	expect(await wait_until(func() -> bool: return _diff_has(diff, "local edit")), "the preview shows the shelved edit")
	expect(not diff.pickable, "a shelved file has no checkboxes")
	for choice: String in ["light", "dark"]:
		Actions.run_action(StringName("view.theme_" + choice))
		await get_tree().process_frame
		expect(shelves.is_visible_in_tree() and view.diff_panel().is_visible_in_tree(), "shelves follow the live theme")
	session.refresh()
	expect(await wait_until(func() -> bool: return _diff_has(diff, "local edit")), "refresh preserves the shelf preview")
	expect(shelves.select_shelf(String(shelf["oid"])), "the shelf can be selected")
	expect(Actions.run_action(&"shelf.restore"), "Restore shelf runs")
	expect(await wait_until(func() -> bool: return read_file(repo.path_join("app.txt")) == "local edit\n"),
			"app.txt has the shelved edit again; errors: %s" % [operation_errors])
	expect(await wait_until(func() -> bool: return _shelf(session, "app edit").is_empty()), "the restored shelf is gone")

	# Discard the fixture's stash, then undo.
	var wip: Dictionary = _shelf(session, "work in progress")
	expect(shelves.select_shelf(String(wip.get("oid", ""))), "the stash can be selected")
	expect(Actions.run_action(&"shelf.discard"), "Discard shelf… runs")
	var confirm: ConfirmationDialog = ops.confirm_dialog()
	expect(await wait_until(func() -> bool: return confirm.visible), "discarding asks first")
	confirm.get_ok_button().pressed.emit()
	expect(await wait_until(func() -> bool: return session.shelves().is_empty()), "the stash is dropped")
	expect(await wait_until(func() -> bool: return page.view == WorktreeView.View.CHANGES),
			"discarding the last shelf returns to Changes")
	expect(not page.active_view().shelves_button().visible, "the last shelf disappearing hides the button")
	expect(not Actions.is_enabled(&"view.shelves"), "the empty view is disabled in the registry")
	expect(await wait_until(func() -> bool: return Actions.run_action(&"shelf.undo_discard")), "Undo shelf discard runs")
	expect(await wait_until(func() -> bool: return _shelf(session, "work in progress").get("oid", "") == wip["oid"]),
			"the same stash is back")
	expect(await wait_until(func() -> bool: return page.active_view().shelves_button().visible),
			"Undo makes the Shelves button reappear")
	expect_eq(page.view, WorktreeView.View.CHANGES, "Undo does not steal the active view")
	# Removing a shelf from outside the UI also updates navigation.
	expect(await _job_ok(session, session.discard_shelf(String(wip["oid"]))), "remove the remaining fixture shelf")
	expect(await wait_until(func() -> bool: return not page.active_view().shelves_button().visible), "empty again")
	list.select_only(0)
	for frame: int in 3:
		await get_tree().process_frame
	var header_label: Control = view.list_header().get_node("%Label") as Control
	_click_at(header_label.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	expect(view.context_menu().visible, "right-clicking the changed-file count opens its menu")
	expect_eq(view.menu_labels(), PackedStringArray(["Shelve all", "Discard all"]),
			"the header offers operations on the whole list")
	view.context_menu().hide()
	expect(Actions.run_action(&"changes.shelve_listed"), "header Shelve runs")
	expect(form.visible, "bulk shelving asks for a name")
	(form.field("name") as LineEdit).text = "Final shelf"
	expect(form.submit(), "bulk shelf submits")
	expect(await wait_until(func() -> bool: return session.change_count() == 0), "bulk shelve includes the unhighlighted file")
	expect(await wait_until(func() -> bool: return page.active_view().shelves_button().visible), "first shelf reveals button")
	expect(Actions.run_action(&"view.shelves"), "open the only shelf")
	expect(await wait_until(func() -> bool: return session.change_count() == 0 and _diff_has(diff, "local edit")),
			"preview remains visible with all changes shelved")
	var title: Button = view.get_node("%ShelfTitle") as Button
	var name_edit: LineEdit = view.get_node("%ShelfNameEdit") as LineEdit
	for frame: int in 3:
		await get_tree().process_frame
	_click_at(title.get_global_rect().get_center())
	expect(name_edit.is_visible_in_tree() and name_edit.has_focus(), "clicking the shelf title edits it inline")
	expect(not form.visible, "renaming has no dialog")
	name_edit.text = "Cancelled name"
	press("Escape")
	expect(not name_edit.visible and title.visible, "Escape exits inline editing")
	expect_eq(String(view.selected_shelf().get("name", "")), "Final shelf", "Escape keeps the original name")
	expect(Actions.run_action(&"shelf.rename"), "the registry also starts inline rename")
	name_edit.text = "   "
	name_edit.text_submitted.emit(name_edit.text)
	expect_eq(String(view.selected_shelf().get("name", "")), "Final shelf", "blank names keep the original")
	Actions.run_action(&"shelf.rename")
	name_edit.text = "Renamed shelf"
	name_edit.text_submitted.emit(name_edit.text)
	expect(await wait_until(func() -> bool: return String(view.selected_shelf().get("name", "")) == "Renamed shelf"),
			"rename keeps the selected shelf")
	Actions.run_action(&"shelf.rename")
	name_edit.text = "Click-away name"
	(view.get_node("%RestoreShelf") as Button).grab_focus()
	expect(await wait_until(func() -> bool: return String(view.selected_shelf().get("name", "")) == "Click-away name"), "leaving the field saves the inline name")
	expect_eq((view.get_node("%RestoreShelf") as Button).get_parent(), title.get_parent(), "Restore shares the name row")
	expect_eq((view.get_node("%DiscardShelf") as Button).get_parent(), title.get_parent(), "Discard shares the name row")
	expect(Actions.run_action(&"shelf.restore"), "restore the last shelf")
	expect(await wait_until(func() -> bool: return session.shelves().is_empty() and page.view == WorktreeView.View.CHANGES),
			"restoring the last shelf returns to Changes")
	expect(not page.active_view().shelves_button().visible, "restore hides the empty Shelves button")
	var pickable: bool = await wait_until(func() -> bool: return view.diff_view().pickable)
	expect(pickable, "Changes restores its selectable diff: cursor %d, files %d, info %s" % [
			view.list().cursor, view.list().row_count(), session.diff_info()])
	# The same header action honors the visible list even when filtered.
	for query: String in ["app.txt", ""]:
		view.filter_field().set_text(query)
		expect(Actions.run_action(&"changes.discard_listed"), "header Discard runs")
		expect(view.confirm_dialog().visible, "bulk discard asks for confirmation")
		view.confirm_dialog().get_ok_button().pressed.emit()
		var remaining: int = 1 if not query.is_empty() else 0
		expect(await wait_until(func() -> bool: return session.change_count() == remaining), "discard covers only listed paths")
		if not query.is_empty():
			expect_eq(read_file(repo.path_join("notes.txt")), "untracked\n", "filter-hidden changes are kept")
		expect(Actions.run_action(&"changes.undo_discard"), "bulk discard can be undone")
		expect(await wait_until(func() -> bool: return session.change_count() == 2), "undo restores both files")

	# Per-file shelf actions target the right-clicked file, retain the rest,
	# follow the replacement shelf and undo without duplicating it.
	expect(await _job_ok(session, session.shelve(session.change_paths(0, session.shown_change_count()), "File actions")), "create a multi-file shelf")
	expect(await wait_until(func() -> bool: return not _shelf(session, "File actions").is_empty()), "file-action shelf appears")
	Actions.run_action(&"view.shelves")
	shelves.select_shelf(String(_shelf(session, "File actions")["oid"]))
	expect(await wait_until(func() -> bool: return view.shelf_files().row_count() == 2), "both saved files load")
	var shelf_files: ShelfFileList = view.shelf_files()
	# Rapid fixture operations can stack success toasts over the file rows.
	for toast: Node in main.toasts().get_children():
		toast.queue_free()
	for frame: int in 3:
		await get_tree().process_frame
	_click_at(shelf_files.global_position + Vector2(shelf_files.size.x / 2.0, shelf_files.row_height() * 1.5), MOUSE_BUTTON_RIGHT)
	var hovered: Control = get_viewport().gui_get_hovered_control()
	expect(view.context_menu().visible, "right-clicking a shelved file opens its menu: files %s; mouse %s; hovered %s; overlay %s" % [
			shelf_files.get_global_rect(), get_viewport().get_mouse_position(), hovered.get_path() if hovered != null else "none", page.active_view().overlay().visible])
	expect_eq(view.menu_labels(), PackedStringArray(["Restore file", "Discard file"]), "file menu has only per-file actions")
	expect_eq(view.selected_shelf_file(), "notes.txt", "the right-clicked file is the action target")
	view.context_menu().hide()
	var original_oid: String = String(view.selected_shelf()["oid"])
	expect(Actions.run_action(&"shelf.discard_file"), "discard the selected shelved file")
	expect(ops.confirm_dialog().visible, "file discard asks for confirmation")
	ops.confirm_dialog().get_ok_button().pressed.emit()
	expect(await wait_until(func() -> bool: return view.shelf_files().row_count() == 1 and String(view.selected_shelf().get("oid", "")) != original_oid), "discard selects the remainder and reloads its files")
	expect_eq(session.change_count(), 0, "discarding a shelved file leaves the working copy alone")
	expect_eq(String(view.selected_shelf().get("name", "")), "File actions", "the shelf keeps its name")
	expect(Actions.run_action(&"shelf.undo_discard"), "undo a partial discard")
	expect(await wait_until(func() -> bool: return view.shelf_files().row_count() == 2 and String(view.selected_shelf().get("oid", "")) == original_oid), "Undo restores the original shelf and selection")
	expect_eq(session.shelves().size(), 1, "Undo does not duplicate the shelf")
	shelf_files.choose_path("notes.txt")
	expect(Actions.run_action(&"shelf.restore_file"), "restore only notes.txt")
	expect(await wait_until(func() -> bool: return session.change_count() == 1 and view.shelf_files().row_count() == 1), "only one file returns to the working copy")
	expect_eq(read_file(repo.path_join("notes.txt")), "untracked\n", "untracked file content restored")
	expect_eq(read_file(repo.path_join("app.txt")), "v2\n", "app.txt stays shelved")
	expect_eq(view.selected_shelf_file(), "app.txt", "next remaining file is selected")
	expect(Actions.run_action(&"shelf.discard_file"), "discard the last shelved file")
	ops.confirm_dialog().get_ok_button().pressed.emit()
	expect(await wait_until(func() -> bool: return session.shelves().is_empty() and page.view == WorktreeView.View.CHANGES), "last-file discard uses the normal empty-shelf fallback")
	expect(Actions.run_action(&"shelf.undo_discard"), "undo last-file discard")
	expect(await wait_until(func() -> bool: return session.shelves().size() == 1), "the shelf reappears")
	expect_eq(page.view, WorktreeView.View.CHANGES, "Undo keeps the current view")
	Actions.run_action(&"view.shelves")
	expect(await wait_until(func() -> bool: return view.shelf_files().row_count() == 1), "last file loads again")
	expect(Actions.run_action(&"shelf.restore_file"), "restore the last file")
	expect(await wait_until(func() -> bool: return session.shelves().is_empty() and session.change_count() == 2 and page.view == WorktreeView.View.CHANGES), "last-file restore returns to Changes with both restored files")

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _shelf(session: RepoSession, name: String) -> Dictionary:
	for shelf: Dictionary in session.shelves():
		if String(shelf["name"]) == name:
			return shelf
	return {}


func _click_at(at: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	if not _mouse_entered:
		get_viewport().notify_mouse_entered()
		_mouse_entered = true
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_viewport().push_input(motion, true)
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = button
	click.pressed = true
	click.position = at
	click.global_position = at
	get_viewport().push_input(click, true)
	var release: InputEventMouseButton = click.duplicate() as InputEventMouseButton
	release.pressed = false
	get_viewport().push_input(release, true)


func _diff_has(diff: DiffView, needle: String) -> bool:
	for i: int in diff.row_count():
		if diff.line_text(i).contains(needle):
			return true
	return false


## Waits for `job` of `session` to finish; returns whether it succeeded.
func _job_ok(session: RepoSession, job: int) -> bool:
	if job < 0:
		return false
	var done: Array[bool] = [false, false]
	var on_finished: Callable = func(id: int, _label: String, ok: bool, _error: Dictionary) -> void:
		if id == job:
			done[0] = true
			done[1] = ok
	session.job_finished.connect(on_finished)
	var finished: bool = await wait_until(func() -> bool: return done[0])
	session.job_finished.disconnect(on_finished)
	return finished and done[1]
