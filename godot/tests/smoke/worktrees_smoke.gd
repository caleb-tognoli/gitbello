extends SmokeTest
## M6, reworked in M6.5 P2: worktrees as chips in one repository tab. A chip
## shows its worktree; a branch checked out in another worktree jumps there
## from the branch list and cannot be deleted; Ctrl+T runs the new-task flow
## (the folder follows the branch name) and shows the result; a chip's menu
## locks, unlocks and removes; cleanup removes merged worktrees with their
## branches and closes their views; the Settings dialog saves. Uses fixture
## `repo-10`. Skipped without `--fixtures`.

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
	var strip: WorktreeStrip = page.strip()
	expect(await wait_until(func() -> bool: return strip.chips().size() == 2), "two chips")

	# A branch checked out in a worktree: the list says where, cannot delete
	# it, and choosing it shows that worktree.
	var view: WorktreeView = page.active_view()
	var popover: BranchPopover = view.branch_popover()
	press("Ctrl+B")
	expect(await wait_until(func() -> bool: return popover.visible), "Ctrl+B opens the branch list")
	popover.set_filter("feature/login")
	var login: Dictionary = popover.first_ref()
	expect(not String(login.get("worktree", "")).is_empty(), "feature/login says which worktree has it")
	popover.menu_requested.emit(login, Vector2.ZERO)
	expect(not ("Delete branch…" in page.menu_labels()), "no delete for a branch in a worktree: %s" % [page.menu_labels()])
	page.close_menu()
	popover.branch_chosen.emit(login)
	popover.hide()
	expect(await wait_until(func() -> bool: return page.active_view().session.current_branch() == "feature/login"),
			"choosing it shows its worktree")
	expect_eq(main.tab_count(), 1, "in the same tab")
	expect(strip.chips()[1].selected, "its chip is selected")
	strip.chips()[0].chosen.emit()
	expect(page.active_view() == view, "a click on the first chip goes back")

	# Ctrl+T: a new task; the folder follows the branch name.
	press("Ctrl+T")
	var form: FormDialog = page.ops().form()
	expect(await wait_until(func() -> bool: return form.visible), "Ctrl+T asks for the task")
	var base: OptionButton = form.field("base") as OptionButton
	base.item_selected.emit(base.selected)
	expect_eq(form.error_text(), "", "choosing a base before the name shows no error")
	expect(form.get_ok_button().disabled, "Create waits for a name")
	type_text("task one")
	var folder: LineEdit = form.field("folder") as LineEdit
	expect(await wait_until(func() -> bool: return folder.text.ends_with("task-one")),
			"the folder follows the branch: %s" % folder.text)
	expect(folder.text.contains("repo-10.worktrees"), "the default template is used: %s" % folder.text)
	var task_path: String = folder.text
	# Browse: a folder with things in it is where the worktree goes; an empty
	# one is the worktree's folder.
	form.pick_folder("folder", fixtures)
	expect_eq(folder.text, fixtures.path_join("task-one"), "a picked folder holds the worktree")
	var empty: String = fixtures.path_join("picked empty")
	DirAccess.make_dir_absolute(empty)
	form.pick_folder("folder", empty)
	expect_eq(folder.text, empty, "a picked empty folder is the worktree's")
	folder.text = task_path
	expect_eq(String(form.values()["base"]), "origin/main", "the default base is first")
	expect(form.field("open_tab") == null, "the new worktree always shows; no switch to ask about")
	press("Enter")
	expect(await wait_until(func() -> bool: return page.views().size() == 3), "the new task shows as a chip")
	expect_eq(main.tab_count(), 1, "no new tab")
	expect(FileAccess.file_exists(task_path.path_join("README.md")), "the task's worktree has the files")
	expect(await wait_until(func() -> bool: return page.session.current_branch() == "task-one"),
			"the task's worktree shows, on task-one")
	expect(await wait_until(func() -> bool: return strip.chips().size() == 3), "three chips")
	strip.chips()[0].chosen.emit()

	# Lock, unlock and remove a worktree from its chip's menu.
	var spare: String = fixtures.path_join("repo-10-spare")
	session.add_worktree(spare, "spare", "main")
	expect(await wait_until(func() -> bool: return session.worktrees().size() == 4), "a spare worktree was added")
	expect(await _menu_for(page, session, "repo-10-spare", "Lock…"), "the menu offers lock")
	expect(await wait_until(func() -> bool: return form.visible), "lock asks for a reason")
	(form.field("reason") as LineEdit).text = "on a usb disk"
	expect(form.submit(), "lock submitted")
	expect(await wait_until(func() -> bool: return bool(_worktree(session, "repo-10-spare").get("locked", false))),
			"the worktree is locked")
	expect(await _menu_for(page, session, "repo-10-spare", "Unlock"), "the menu offers unlock")
	expect(await wait_until(func() -> bool: return not bool(_worktree(session, "repo-10-spare").get("locked", true))),
			"unlocked")
	expect(await _menu_for(page, session, "repo-10-spare", "Remove…"), "the menu offers remove")
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
	expect(await wait_until(func() -> bool: return page.views().size() == 1), "their views closed")
	expect(await wait_until(func() -> bool: return strip.chips().size() == 1), "one chip left")
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


## Opens the menu of the chip whose folder ends with `folder` and presses
## `label`.
func _menu_for(page: RepoTab, session: RepoSession, folder: String, label: String) -> bool:
	if not await wait_until(func() -> bool: return not _worktree(session, folder).is_empty()):
		return false
	page.strip().worktree_menu_requested.emit(_worktree(session, folder), Vector2.ZERO)
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
