extends SmokeTest
## M6.5 P4 acceptance: shelve a file, leave changes behind on a switch, come
## back and restore them from the offer, preview and restore a shelf from the
## Shelved section, and discard a shelf with undo. Uses fixture `repo-11`
## (app.txt edited, notes.txt untracked, a stash "work in progress" on main);
## the app runs git. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


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
	expect(await wait_until(func() -> bool: return session.change_count() == 2 and session.shelves().size() == 1),
			"repo-11 has two changes and one stash")
	press("Ctrl+Shift+G")
	var view: ChangesView = page.changes()
	var shelves: ShelfList = view.shelf_list()
	expect(await wait_until(func() -> bool: return shelves.visible and shelves.shelf_count() == 1),
			"the Shelved section lists the fixture's stash")
	expect(shelves.row_texts().has("work in progress"), "as a shelf of main: %s" % [shelves.row_texts()])

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
	shelves.expand(String(shelf["oid"]))
	expect(await wait_until(func() -> bool: return shelves.choose_file(String(shelf["oid"]), "app.txt")),
			"its files load: %s" % [shelves.row_texts()])
	var diff: DiffView = view.diff_view()
	expect(await wait_until(func() -> bool: return _diff_has(diff, "local edit")), "the preview shows the shelved edit")
	expect(not diff.pickable, "a shelved file has no checkboxes")
	expect(shelves.select_shelf(String(shelf["oid"])), "the shelf can be selected")
	expect(Actions.run_action(&"shelf.restore"), "Restore shelf runs")
	expect(await wait_until(func() -> bool: return read_file(repo.path_join("app.txt")) == "local edit\n"),
			"app.txt has the shelved edit again")
	expect(await wait_until(func() -> bool: return _shelf(session, "app edit").is_empty()), "the restored shelf is gone")

	# Discard the fixture's stash, then undo.
	var wip: Dictionary = _shelf(session, "work in progress")
	expect(shelves.select_shelf(String(wip.get("oid", ""))), "the stash can be selected")
	expect(Actions.run_action(&"shelf.discard"), "Discard shelf… runs")
	var confirm: ConfirmationDialog = ops.confirm_dialog()
	expect(await wait_until(func() -> bool: return confirm.visible), "discarding asks first")
	confirm.get_ok_button().pressed.emit()
	expect(await wait_until(func() -> bool: return session.shelves().is_empty()), "the stash is dropped")
	expect(await wait_until(func() -> bool: return Actions.run_action(&"shelf.undo_discard")), "Undo shelf discard runs")
	expect(await wait_until(func() -> bool: return _shelf(session, "work in progress").get("oid", "") == wip["oid"]),
			"the same stash is back")

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _shelf(session: RepoSession, name: String) -> Dictionary:
	for shelf: Dictionary in session.shelves():
		if String(shelf["name"]) == name:
			return shelf
	return {}


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
