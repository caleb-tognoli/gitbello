extends SmokeTest
## M6: worktrees from the sidebar and the keyboard. Enter opens a linked
## worktree as a tab; Ctrl+T runs the new-task flow (the folder follows the
## branch name) and opens the result; the worktree menu locks, unlocks and
## removes; a branch checked out in a worktree cannot be deleted; cleanup
## removes merged worktrees with their branches and closes their tabs; the
## Settings dialog saves. Uses fixture `repo-10`. Skipped without
## `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("worktrees_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-10")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.worktrees().size() == 2 and not session.default_base().is_empty()),
			"the fixture's linked worktree is listed")
	expect_eq(session.default_base(), "origin/main", "tasks start from the remote's main")
	var linked: String = String(session.worktrees()[1]["path"])
	var sidebar: RepoSidebar = page.sidebar()

	# A branch checked out in a worktree cannot be deleted from its menu.
	expect(sidebar.select_ref("refs/heads/feature/login"), "feature/login is listed")
	sidebar.grab_focus()
	sidebar.context_menu_requested.emit(sidebar.selected_ref(), Vector2.ZERO)
	expect(not ("Delete branch…" in page.menu_labels()), "no delete for a branch in a worktree: %s" % [page.menu_labels()])
	page.close_menu()

	# Enter on the linked worktree opens it in a tab.
	expect(sidebar.select_ref("worktree:" + linked), "the linked worktree has a row")
	sidebar.grab_focus()
	press("Enter")
	expect(await wait_until(func() -> bool: return main.tab_count() == 2), "Enter opened the worktree in a tab")
	var linked_page: RepoTab = main.current_page()
	expect(await wait_until(func() -> bool: return linked_page.title().begins_with("repo-10/")),
			"a linked worktree's tab names its repository: %s" % linked_page.title())
	main.tab_bar().current_tab = 0

	# Ctrl+T: a new task; the folder follows the branch name.
	press("Ctrl+T")
	var form: FormDialog = page.ops().form()
	expect(await wait_until(func() -> bool: return form.visible), "Ctrl+T asks for the task")
	type_text("task one")
	var folder: LineEdit = form.field("folder") as LineEdit
	expect(await wait_until(func() -> bool: return folder.text.ends_with("task-one")),
			"the folder follows the branch: %s" % folder.text)
	expect(folder.text.contains("repo-10.worktrees"), "the default template is used: %s" % folder.text)
	var task_path: String = folder.text
	expect_eq(String(form.values()["base"]), "origin/main", "the default base is first")
	press("Enter")
	expect(await wait_until(func() -> bool: return main.tab_count() == 3), "the new task opened in a tab")
	expect(FileAccess.file_exists(task_path.path_join("README.md")), "the task's worktree has the files")
	expect(await wait_until(func() -> bool: return main.current_page().session.current_branch() == "task-one"),
			"the new tab is on task-one")
	main.tab_bar().current_tab = 0
	expect(await wait_until(func() -> bool: return session.worktrees().size() == 3), "three worktrees listed")

	# Lock, unlock and remove a worktree from its menu.
	var spare: String = fixtures.path_join("repo-10-spare")
	session.add_worktree(spare, "spare", "main")
	expect(await wait_until(func() -> bool: return session.worktrees().size() == 4), "a spare worktree was added")
	# git lists linked worktrees by their internal names, not by age.
	var spare_row: String = "worktree:" + String(_worktree(session, "repo-10-spare")["path"])
	expect(await _menu_for(page, sidebar, spare_row, "Lock worktree…"), "the menu offers lock")
	expect(await wait_until(func() -> bool: return form.visible), "lock asks for a reason")
	(form.field("reason") as LineEdit).text = "on a usb disk"
	expect(form.submit(), "lock submitted")
	expect(await wait_until(func() -> bool: return bool(_worktree(session, "repo-10-spare").get("locked", false))),
			"the worktree is locked")
	expect(await _menu_for(page, sidebar, spare_row, "Unlock worktree"), "the menu offers unlock")
	expect(await wait_until(func() -> bool: return not bool(_worktree(session, "repo-10-spare").get("locked", true))),
			"unlocked")
	expect(await _menu_for(page, sidebar, spare_row, "Remove worktree…"), "the menu offers remove")
	var confirm: ConfirmationDialog = page.ops().confirm_dialog()
	expect(await wait_until(func() -> bool: return confirm.visible), "remove asks first")
	press("Enter")
	expect(await wait_until(func() -> bool: return session.worktrees().size() == 3), "the spare worktree was removed")
	expect(not DirAccess.dir_exists_absolute(spare), "its folder is gone")

	# Cleanup: feature/login and task-one are both merged into origin/main.
	expect(Actions.run_action(&"worktree.cleanup"), "cleanup runs")
	expect(await wait_until(func() -> bool: return form.visible and form.field("delete_branches") != null),
			"cleanup lists merged worktrees")
	expect(form.field("wt0") != null and form.field("wt1") != null, "both worktrees are offered")
	expect(form.submit(), "cleanup submitted")
	expect(await wait_until(func() -> bool: return session.worktrees().size() == 1), "both worktrees were removed")
	expect(await wait_until(func() -> bool: return main.tab_count() == 1), "their tabs closed")
	expect(await wait_until(func() -> bool: return not _has_branch(session, "task-one") and not _has_branch(session, "feature/login")),
			"their branches were deleted")

	# Settings: a bad interval is refused; a good one is saved.
	expect(Actions.run_action(&"app.settings"), "Settings opens")
	var settings: FormDialog = main.settings_form()
	expect(await wait_until(func() -> bool: return settings.visible), "the settings form shows")
	(settings.field("auto_fetch_minutes") as LineEdit).text = "soon"
	expect(not settings.submit(), "a non-number is refused")
	(settings.field("auto_fetch_minutes") as LineEdit).text = "15"
	expect(settings.submit(), "settings saved")
	expect_eq(int(Core.settings()["auto_fetch_minutes"]), 15, "the interval was saved")
	Core.set_settings({"auto_fetch_minutes": 0})

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


## Opens the sidebar menu of row `name` and presses `label`.
func _menu_for(page: RepoTab, sidebar: RepoSidebar, name: String, label: String) -> bool:
	if not await wait_until(func() -> bool: return sidebar.select_ref(name)):
		return false
	sidebar.grab_focus()
	sidebar.context_menu_requested.emit(sidebar.selected_ref(), Vector2.ZERO)
	return page.press_menu(label)


static func _worktree(session: RepoSession, folder: String) -> Dictionary:
	for wt: Dictionary in session.worktrees():
		if String(wt["path"]).ends_with(folder):
			return wt
	return {}


static func _has_branch(session: RepoSession, name: String) -> bool:
	for ref: Dictionary in session.branch_refs():
		if String(ref["kind"]) == "branch" and String(ref["short_name"]) == name:
			return true
	return false
