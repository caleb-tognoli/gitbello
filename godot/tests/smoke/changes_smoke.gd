extends SmokeTest
## The Changes view (M4a, reworked in M6.5 P3): checkboxes, commit and amend
## through History and keyboard shortcuts, on fixture `repo-6` (app.txt modified, notes.txt
## untracked). Also checks the diff of the highlighted file, the commit
## button's text and reason, hook output on a failed commit, the empty state
## and the linked worktree's badge. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _main: Main = null


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("changes_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-6")

	_main = MAIN.instantiate() as Main
	add_child(_main)
	await get_tree().process_frame
	var page: RepoTab = _main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.change_count() == 2),
			"repo-6 has one modified and one untracked file")

	var view: ChangesView = page.changes()
	var list: ChangeList = view.list()
	press("Ctrl+Shift+G")
	expect_eq(page.view, WorktreeView.View.CHANGES, "Ctrl+Shift+G shows the changes view")
	expect(list.has_focus(), "the list has focus")
	expect_eq(list.cursor, 0, "cursor on the first file")
	expect_eq(session.picked_count(), 2, "nothing staged: every file is included")
	expect_eq(view.check_all().state, "all", "the check-all box is checked")
	expect_eq(view.list_header().text(), "2 changed files", "the list header counts the files")
	var badge: CountBadge = page.active_view().changes_badge()
	expect(await wait_until(func() -> bool: return badge.visible and badge.count == 2),
			"the Changes button shows the count in a badge: %d" % badge.count)
	await get_tree().process_frame
	var button: Button = badge.get_parent() as Button
	expect_eq(button.text, "Changes", "the count is not in the button's text")
	expect(badge.position.x + badge.size.x <= button.size.x and badge.position.x > 0.0,
			"the button makes room for its badge: %s in %s" % [badge.get_rect(), button.size])

	# The filter narrows the list; the check-all box then covers the files shown.
	var filter: FilterField = view.filter_field()
	press("Ctrl+F")
	expect(filter.text_box().has_focus(), "Ctrl+F focuses the filter")
	type_text("NOTES")
	await get_tree().process_frame  # LineEdit reports text changes deferred
	expect_eq(list.row_count(), 1, "the filter ignores case")
	expect_eq(list.path_at(0), "notes.txt", "only notes.txt matches")
	expect_eq(view.list_header().text(), "1 of 2 changed files", "the header says how many are shown")
	view.pick_all(false)
	expect(await wait_until(func() -> bool: return session.picked_count() == 1),
			"check-all leaves out the shown file only: %d" % session.picked_count())
	expect(await wait_until(func() -> bool: return view.check_all().state == "none"),
			"check-all shows the shown files' state: %s" % view.check_all().state)
	view.pick_all(true)
	expect(await wait_until(func() -> bool: return session.picked_count() == 2), "check-all includes it again")
	type_text("zzz")
	await get_tree().process_frame
	expect_eq(view.list_header().text(), "0 of 2 changed files", "nothing matches")
	press("Escape")
	expect_eq(filter.text(), "", "Escape clears the filter")
	expect_eq(list.row_count(), 2, "every file is back")
	filter.set_option("new", true)
	expect(filter.options_button().button_pressed, "the options button shows options are on")
	expect_eq(list.row_count(), 1, "New files: only the untracked file")
	expect_eq(list.path_at(0), "notes.txt", "the new file is notes.txt")
	filter.set_option("new", false)
	filter.set_option("included", true)
	expect_eq(list.row_count(), 2, "both files are included")
	session.pick_files(PackedStringArray(["notes.txt"]), false)
	expect(await wait_until(func() -> bool: return list.row_count() == 1),
			"a file left out leaves the Included list at once")
	session.pick_files(PackedStringArray(["notes.txt"]), true)
	expect(await wait_until(func() -> bool: return list.row_count() == 2), "and comes back when included")
	filter.set_option("included", false)
	expect(not filter.is_active(), "no filter left")
	expect_eq(view.list_header().text(), "2 changed files", "the header counts every file again")
	var filter_menu: PopupMenu = filter.menu()
	filter.options_button().pressed.emit()
	expect_eq(_clear_filter_index(filter_menu), -1, "Clear all filters is absent without active filters")
	var base_items: int = filter_menu.item_count
	expect(not Actions.is_enabled(&"changes.clear_filters"), "clear action is disabled without active filters")
	var new_option: int = -1
	for index: int in filter_menu.item_count:
		if filter_menu.get_item_text(index) == "New files":
			new_option = filter_menu.get_item_id(index)
	expect(new_option >= 0, "New files is offered")
	if new_option >= 0:
		filter_menu.id_pressed.emit(new_option)
		expect(filter_menu.visible and _clear_filter_index(filter_menu) >= 0, "clear appears when a filter is checked in the open menu")
		filter_menu.id_pressed.emit(new_option)
		expect(filter_menu.visible and _clear_filter_index(filter_menu) == -1, "clear disappears when the last filter is unchecked")
	filter_menu.hide()
	for mode: String in ["text", "option", "both"]:
		if mode != "option":
			filter.set_text("notes")
		if mode != "text":
			filter.set_option("new", true)
		filter.options_button().pressed.emit()
		var clear_index: int = _clear_filter_index(filter_menu)
		expect(clear_index > 0, "Clear all filters appears for %s filtering" % mode)
		expect_eq(filter_menu.item_count, base_items + 2, "one divider and one reset action are added")
		if clear_index > 0:
			expect(filter_menu.is_item_separator(clear_index - 1), "the reset action is visually separated")
			expect(not filter_menu.is_item_checkable(clear_index), "the reset action is not another filter checkbox")
			filter_menu.id_pressed.emit(filter_menu.get_item_id(clear_index))
		expect(not filter_menu.visible, "clear closes the menu")
		expect_eq(filter.text(), "", "clear removes the search text")
		expect(filter.options().is_empty(), "clear removes option filters")
		expect(not filter.options_button().button_pressed, "clear resets the options button")
		expect_eq(_clear_filter_index(filter_menu), -1, "reset disappears after clearing")
		expect_eq(filter_menu.item_count, base_items, "no reset divider remains after clearing")
		expect_eq(list.row_count(), 2, "clear restores every changed file")
		expect_eq(session.picked_count(), 2, "clear does not change the commit selection")
	filter.set_option("new", true)
	filter.set_text("notes")
	filter.focus_text()
	press("Escape")
	expect_eq(filter.text(), "", "Escape still clears just the text")
	expect_eq(filter.options(), PackedStringArray(["new"]), "Escape leaves option filters active")
	expect(_clear_filter_index(filter_menu) >= 0, "clear stays available while an option remains")
	filter.set_option("new", false)
	expect_eq(_clear_filter_index(filter_menu), -1, "turning the last filter off removes clear")
	filter.set_text("   ")
	expect_eq(_clear_filter_index(filter_menu), -1, "whitespace alone is not an active filter")
	filter.set_text("")
	list.grab_focus()
	list.select_only(0)

	# The highlighted file's diff loads.
	var diff: DiffView = view.diff_view()
	expect(await wait_until(func() -> bool: return _diff_has(diff, "local edit")), "diff of app.txt shows the local edit")

	# Space leaves out the highlighted file; the button follows.
	var box: CommitBox = view.commit_box()
	press("Down")
	expect_eq(list.path_at(list.cursor), "notes.txt", "cursor on notes.txt")
	press("Space")
	expect(await wait_until(func() -> bool: return session.picked_count() == 1), "Space left out notes.txt")
	expect(await wait_until(func() -> bool: return view.check_all().state == "partial"), "check-all shows partial")
	expect_eq(box.button_text(), "Commit 1 file to main", "the button counts the included files")
	press("Ctrl+Shift+U")
	expect(await wait_until(func() -> bool: return session.picked_count() == 0), "Ctrl+Shift+U leaves out everything")
	expect_eq(box.block_reason(), "Nothing included", "the button says why it is disabled")
	press("Ctrl+Shift+S")
	expect(await wait_until(func() -> bool: return session.picked_count() == 2), "Ctrl+Shift+S includes everything")
	expect_eq(box.block_reason(), "Write a summary", "a summary is still needed")

	# Write the message and commit.
	press("Ctrl+Shift+M")
	type_text("Add notes")
	press("Enter")
	type_text("Body line")
	expect_eq(box.summary(), "Add notes", "summary typed")
	expect_eq(box.body(), "Body line", "body typed")
	press("Ctrl+Enter")
	var committed: bool = await wait_until(func() -> bool:
		return not box.is_busy() and box.summary().is_empty() and session.change_count() == 0)
	expect(committed, "Ctrl+Enter commits and clears the message (output: %s)" % box.output_text())
	expect(await wait_until(func() -> bool: return _head_subject(session) == "Add notes"), "graph shows the new commit")
	var commits: int = session.graph_row_count()

	# Nothing left: suggested actions replace the diff.
	var empty: EmptyState = view.empty_state()
	expect(await wait_until(func() -> bool: return empty.visible), "the empty state shows")
	expect_eq(empty.title(), "No local changes", "it says there is nothing to commit")
	expect("New worktree" in empty.button_labels(), "it suggests a new worktree: %s" % [empty.button_labels()])
	expect(await wait_until(func() -> bool: return not badge.visible), "no badge without changes")

	var amend_header: HBoxContainer = view.get_node("%AmendHeader") as HBoxContainer
	var amend_title: Label = view.get_node("%AmendTitle") as Label
	var cancel: Button = view.get_node("%CancelAmend") as Button
	expect(not amend_header.visible, "normal commits have no amend header")
	expect(view.find_child("Amend", true, false) == null, "there is no permanent amend checkbox")
	expect(not Actions.is_enabled(&"commit.amend"), "amend starts from History, not the normal draft")
	box.set_message("Next task", "Keep this draft")
	page.show_view(WorktreeView.View.HISTORY)
	var history: HistoryView = page.history()
	history.commit_list().select_only(1)
	history.commit_menu_requested.emit(Vector2(100.0, 100.0))
	expect(not "Amend…" in page.menu_labels(), "older commits do not offer Amend")
	page.close_menu()
	history.commit_list().select_only(0)
	history.commit_menu_requested.emit(Vector2(100.0, 100.0))
	expect("Amend…" in page.menu_labels(), "HEAD offers Amend")
	expect(page.press_menu("Amend…"), "the History context menu starts amend")
	expect_eq(page.view, WorktreeView.View.CHANGES, "amend opens Changes")
	expect(box.is_amend(), "amend mode is active")
	expect(not box.can_commit(), "commit waits for HEAD's message")
	expect(await wait_until(func() -> bool: return box.summary() == "Add notes"), "amend replaces a nonempty draft with HEAD's summary")
	expect_eq(box.body(), "Body line", "amend loads HEAD's body")
	expect(amend_header.visible, "the temporary amend header shows")
	expect_eq(amend_title.text, "Amending “Add notes”", "the indicator names the commit, not its hash")
	expect_eq(cancel.text, "Cancel", "the exit is labelled Cancel")
	expect_eq(box.button_text(), "Amend commit", "the primary button is explicit")
	box.set_message("An edited amend", "Not the ordinary draft")
	cancel.pressed.emit()
	expect(not box.is_amend() and not amend_header.visible, "Cancel returns to normal mode")
	expect_eq(box.summary(), "Next task", "Cancel restores the ordinary summary even after edits")
	expect_eq(box.body(), "Keep this draft", "Cancel restores the ordinary body")

	page.show_view(WorktreeView.View.HISTORY)
	press("Ctrl+Shift+A")
	expect(box.is_amend(), "the shortcut starts amend from selected HEAD")
	Actions.run_action(&"changes.cancel_amend")
	expect_eq(box.summary(), "Next task", "cancelling while loading restores the draft")
	expect(await wait_until(func() -> bool: return box.can_amend()), "the cancelled message read finishes")
	expect_eq(box.summary(), "Next task", "a late message cannot overwrite the restored draft")
	page.show_view(WorktreeView.View.HISTORY)
	press("Ctrl+Shift+A")
	expect(await wait_until(func() -> bool: return box.summary() == "Add notes"), "HEAD message loads again")
	box.set_message("Add notes (amended)", "Body line")
	press("Ctrl+Enter")
	expect(not Actions.is_enabled(&"changes.cancel_amend"), "Cancel is unavailable during submission")
	committed = await wait_until(func() -> bool: return not box.is_busy() and not box.is_amend())
	expect(committed, "message-only amend finished (output: %s)" % box.output_text())
	expect(await wait_until(func() -> bool: return _head_subject(session) == "Add notes (amended)"),
			"graph shows the amended commit: %s" % _head_subject(session))
	expect_eq(session.graph_row_count(), commits, "amending does not add a commit")
	expect_eq(box.summary(), "Next task", "successful amend restores the ordinary draft")
	expect_eq(box.body(), "Keep this draft", "successful amend restores the draft body")

	write_file(repo.path_join("app.txt"), "amended content\n")
	write_file(repo.path_join("left-out.txt"), "leave this out\n")
	expect(await wait_until(func() -> bool: return session.change_count() == 2), "two new changes arrive")
	session.pick_all(false)
	session.pick_files(PackedStringArray(["app.txt"]), true)
	expect(await wait_until(func() -> bool: return session.picked_count() == 1), "one file is included")
	page.show_view(WorktreeView.View.HISTORY)
	history.commit_list().select_only(0)
	Actions.run_action(&"commit.amend")
	expect(await wait_until(func() -> bool: return box.summary() == "Add notes (amended)"), "amend loads with checked changes")
	expect(box.commit(), "amend submits the checked file")
	expect(await wait_until(func() -> bool: return not box.is_amend() and not box.is_busy() and session.change_count() == 1),
			"amend leaves only the excluded file")
	expect_eq(session.change_paths(0, session.change_count()), PackedStringArray(["left-out.txt"]), "excluded file is untouched")
	expect_eq(session.graph_row_count(), commits, "amend with changes does not add a commit")
	expect_eq(box.summary(), "Next task", "amend with changes also preserves the draft")

	# A rejecting pre-commit hook keeps amend mode, its message and output.
	var hook_path: String = repo.path_join(".git/hooks/pre-commit")
	var hook: FileAccess = FileAccess.open(hook_path, FileAccess.WRITE)
	hook.store_string("#!/bin/sh\necho 'hook says no' >&2\nexit 1\n")
	hook.close()
	FileAccess.set_unix_permissions(hook_path, FileAccess.UNIX_EXECUTE_OWNER | FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	page.show_view(WorktreeView.View.HISTORY)
	expect(await wait_until(func() -> bool:
		var head: String = String(session.status().get("oid", ""))
		for row: int in history.commit_list().row_count():
			if history.commit_list().hash_at(row) == head:
				history.commit_list().select_only(row)
				return Actions.is_enabled(&"commit.amend")
		return false), "the amended HEAD is refreshed and available before another amend")
	press("Ctrl+Shift+A")
	expect(await wait_until(func() -> bool: return box.summary() == "Add notes (amended)"), "HEAD message loads before hook rejection")
	press("Ctrl+Enter")
	var rejected: bool = await wait_until(func() -> bool: return not box.is_busy() and box.output_text().contains("hook says no"))
	expect(rejected, "hook output is shown: %s" % box.output_text())
	expect(box.is_amend(), "a rejected amend stays in amend mode")
	expect_eq(box.summary(), "Add notes (amended)", "message kept after a failed commit")
	DirAccess.remove_absolute(hook_path)
	cancel.pressed.emit()
	expect_eq(box.summary(), "Next task", "cancelling a failed amend restores the draft")

	var message_received: Array[bool] = [false]
	session.head_message_loaded.connect(func(_summary: String, _body: String) -> void:
		message_received[0] = true, CONNECT_ONE_SHOT)
	box.begin_amend({"hash": String(session.status().get("oid", "")), "subject": "Add notes (amended)"})
	var message_job: int = box._message_job
	expect(message_job >= 0, "a message read started")
	box._on_job_finished(message_job, "read HEAD message", false, {"title": "Message read failed"})
	expect(not box.is_amend(), "a failed message read exits amend mode")
	expect_eq(box.summary(), "Next task", "a failed message read preserves the draft")
	expect_eq(box.output_text(), "Message read failed", "a failed message read is explained")
	expect(await wait_until(func() -> bool: return message_received[0]), "the obsolete message result arrives")
	expect_eq(box.summary(), "Next task", "the obsolete message result does not overwrite the draft")

	var old_head: String = String(session.status().get("oid", ""))
	box.begin_amend({"hash": old_head, "subject": "Add notes (amended)"})
	expect(await wait_until(func() -> bool: return box.summary() == "Add notes (amended)"), "amend loads before HEAD changes")
	var oldest: Dictionary = session.graph_rows(session.graph_row_count() - 1, 1)[0]
	expect(session.checkout_commit(String(oldest["hash"]), "keep") >= 0, "another checkout starts on the fixture")
	expect(await wait_until(func() -> bool:
		return String(session.status().get("oid", "")) != old_head and not box.is_amend()),
			"a changed HEAD exits stale amend mode")
	expect_eq(box.summary(), "Next task", "a changed HEAD preserves the ordinary draft")

	# The linked worktree's badge arrives (clean: 0 changes).
	var badged: bool = await wait_until(func() -> bool:
		for wt: Dictionary in session.worktrees():
			if not bool(wt["is_main"]) and int(wt["changed"]) == 0:
				return true
		return false)
	expect(badged, "linked worktree has a badge: %s" % [session.worktrees()])

	press("Ctrl+Shift+H")
	expect_eq(page.view, WorktreeView.View.HISTORY, "Ctrl+Shift+H shows history")
	while _main.tab_count() > 0:
		_main.close_tab(0)
	_main.queue_free()
	await get_tree().process_frame


func _clear_filter_index(menu: PopupMenu) -> int:
	for index: int in menu.item_count:
		if menu.get_item_text(index) == "Clear all filters":
			return index
	return -1


func _diff_has(diff: DiffView, needle: String) -> bool:
	for i: int in diff.row_count():
		if diff.line_text(i).contains(needle):
			return true
	return false


func _head_subject(session: RepoSession) -> String:
	var rows: Array[Dictionary] = session.graph_rows(0, 1)
	return String(rows[0]["subject"]) if not rows.is_empty() else ""
