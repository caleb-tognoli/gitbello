extends SmokeTest

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		return
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var path: String = fixtures.path_join("repo-4")
	var page: RepoTab = main.open_repo(path)
	page.show_view(WorktreeView.View.HISTORY)
	var history: HistoryView = page.history()
	var session: RepoSession = page.session
	var list: CommitList = history.commit_list()
	expect(await wait_until(func() -> bool: return list.row_count() == 3 and bool(session.history_info().get("ready", false))), "current history and tracking load")
	expect(not bool(session.history_info().get("all_branches", true)), "current branch is the default")
	var head: String = String(session.status()["oid"])
	expect(await wait_until(func() -> bool: return history.details().commit_oid() == head), "HEAD is selected initially")
	list.reload_matches()
	expect_eq(String(history.selected_commit().get("subject", "")), "Improve app", "commit actions keep metadata before the next draw")
	expect_eq(history.list_header().status_text(), "1 outgoing", "the header counts outgoing commits")
	expect(bool(session.graph_rows(0, 1)[0]["outgoing"]), "HEAD has an outgoing marker")
	expect(not bool(session.graph_rows(1, 1)[0]["outgoing"]), "the published ancestor has no outgoing marker")
	expect((history.details().get_node("%Outgoing") as Label).visible, "outgoing details are visible")
	expect(history.find_child("GoToHead", true, false) == null, "there is no current-commit button")
	expect(history.find_child("Tracking", true, false) == null, "there is no tracking row")
	var scope: PopupMenu = history.scope_menu()
	expect_eq(scope.item_count, 2, "the scope popover has only two choices")
	expect_eq(scope.get_item_text(0), "Current branch", "the first choice is current branch")
	expect_eq(scope.get_item_text(1), "All branches", "the second choice is all branches")
	expect(scope.is_item_checked(0) and not scope.is_item_checked(1), "only current branch is selected")
	expect(history.scope_button().get_parent() == history.search_field().get_node("%Buttons"), "scope is inside the filter field")
	expect_eq(history.scope_button().theme_type_variation, &"FilterFieldButton", "scope uses the Changes filter button style")
	expect(history.scope_button().tooltip_text.contains("main"), "the scope tooltip names the branch")
	var jump: ActionRegistry.Action = Actions.get_action(&"history.go_to_current_commit")
	expect_eq(jump.label, "Go to current commit", "the action uses the new name")
	expect(jump.hidden, "the action is keyboard-only, not listed in the palette")
	expect_eq(Actions.shortcut_label(jump.id), "F", "F is the default current-commit shortcut")

	session.fetch()
	expect(await wait_until(func() -> bool: return int(session.badge().get("behind", 0)) == 1), "fixture fetch sees incoming history")
	expect(await wait_until(func() -> bool: return list.row_count() == 3 and history.status_text() == "3 commits"), "incoming commits stay outside current history")
	list.select_only(2)
	var selected: String = list.hash_at(2)
	_pick_scope(history, 1)
	expect(await wait_until(func() -> bool: return list.row_count() == 4 and list.hash_at(list.cursor) == selected), "the popover loads all refs and preserves selection by hash")
	expect(scope.is_item_checked(1) and not scope.is_item_checked(0), "scope choices are mutually exclusive")
	expect(history.scope_button().button_pressed, "the alternate scope highlights the filter button")
	expect_eq(String(session.status()["oid"]), head, "changing history does not check out anything")
	expect_eq(int(Core.repo_ui_state(session.repo_path()).get("history_all_branches", 0)), 1, "scope is persisted for this worktree")
	history.search_field().set_text("Remote change")
	expect(await wait_until(func() -> bool: return history.status_text() == "1 of 1 match"), "all-ref search finds the remote-only commit")
	var remote: String = list.hash_at(list.cursor)
	expect(remote != head, "the remote commit is selected")
	expect(not bool(session.graph_rows(list.cursor, 1)[0]["outgoing"]), "remote-only commits are not outgoing")
	expect(not (history.details().get_node("%Outgoing") as Label).visible, "the outgoing detail clears on another commit")
	list.grab_focus()
	press("F")
	expect(await wait_until(func() -> bool: return list.hash_at(list.cursor) == head), "F selects the current commit")
	expect_eq(history.search_field().text(), "Remote change", "F preserves search")
	var jumps: Array[int] = [0]
	var count_jump: Callable = func(id: StringName) -> void:
		if id == jump.id:
			jumps[0] += 1
	Actions.action_ran.connect(count_jump)
	history.search_field().focus_text()
	expect(not Actions.is_enabled(jump.id), "the shortcut is disabled in text fields")
	type_text("f")
	await get_tree().process_frame
	expect_eq(history.search_field().text(), "f", "f still types normally in search")
	expect_eq(jumps[0], 0, "typing f does not run navigation")
	Actions.action_ran.disconnect(count_jump)
	history.search_field().set_text("Remote change")
	expect(await wait_until(func() -> bool: return history.status_text() == "1 of 1 match"), "search can be restored")
	list.grab_focus()
	press("F")
	expect(await wait_until(func() -> bool: return list.hash_at(list.cursor) == head), "F works again after leaving search")

	_pick_scope(history, 0)
	expect(await wait_until(func() -> bool: return list.row_count() == 3 and history.status_text() == "No matches"), "search reruns within the current branch")
	expect_eq(list.hash_at(list.cursor), head, "HEAD remains selected after scope change")
	history.search_field().set_text("")
	Actions.run_action(&"history.all_branches")
	expect(await wait_until(func() -> bool: return list.row_count() == 4), "the palette action also changes scope")
	var remote_row: int = session.graph_find_commit(remote)
	list.select_only(remote_row)
	Actions.run_action(&"history.current_branch")
	expect(await wait_until(func() -> bool: return list.row_count() == 3 and list.hash_at(list.cursor) == head), "a commit outside the new scope falls back to HEAD")
	Actions.run_action(&"history.all_branches")
	expect(await wait_until(func() -> bool: return list.row_count() == 4), "all scope is ready for reopen")
	main.close_tab(0)
	await get_tree().process_frame
	page = main.open_repo(path)
	page.show_view(WorktreeView.View.HISTORY)
	history = page.history()
	expect(await wait_until(func() -> bool: return history.commit_list().row_count() == 4), "reopening restores the saved scope")
	expect(bool(page.session.history_info().get("all_branches", false)), "restored scope is all branches")

	var linked: RepoTab = main.open_repo(fixtures.path_join("repo-4-feature"))
	linked.show_view(WorktreeView.View.HISTORY)
	var local: HistoryView = linked.history()
	expect(await wait_until(func() -> bool: return bool(linked.session.history_info().get("ready", false)) and local.commit_list().row_count() == 2), "the linked worktree has its own current-branch scope")
	expect(not bool(linked.session.history_info().get("all_branches", true)), "scope is independent between worktrees")
	expect_eq(local.list_header().tooltip_text, "No upstream · Publish branch", "the header tooltip explains a missing upstream without an extra row")
	expect(local.list_header().status_text().is_empty(), "there is no misleading outgoing count without upstream")
	for row: Dictionary in linked.session.graph_rows(0, 2):
		expect(not bool(row["outgoing"]), "inherited history is not all marked unpushed")
	linked.show_view(WorktreeView.View.CHANGES)
	expect(not Actions.is_enabled(jump.id), "F does not navigate outside History")
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _pick_scope(history: HistoryView, id: int) -> void:
	history.scope_button().pressed.emit()
	var menu: PopupMenu = history.scope_menu()
	expect(menu.visible, "the filter button opens the scope popover")
	menu.id_pressed.emit(id)
	menu.hide()
