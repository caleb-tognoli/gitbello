extends SmokeTest
## M6, reworked in M6.5 P2: worktrees as chips in one repository tab. A chip
## shows its worktree; a branch checked out in another worktree jumps there
## from the branch list and deleting it offers its worktree too; Ctrl+T opens New worktree
## (create, check out a local or remote branch, the From list, the folder preview, a taken
## folder, Run setup) and shows the result; one click (a branch's menu, Alt+Enter in the branch
## list) with Undo, New worktree here…, Enter on an unmatched worktree filter, the setup's
## settings and a failed setup; a chip's menu
## locks, unlocks and removes (on Windows, not while a program runs from the
## worktree); cleanup removes merged worktrees with their
## branches and closes their views; the Settings dialog saves. Uses fixture
## `repo-10`. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	_test_chip_tooltips()
	_test_worktree_list()
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("worktrees_smoke: no --fixtures, skipped")
		return
	await _overflow_selection()
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
	await _overflow_presentation()
	strip.list_button().pressed.emit()
	var all_list: WorktreeListPopover = strip.all_list()
	expect_eq(all_list.rows().size(), 2, "the list has both real worktrees")
	expect(not all_list.footer_button(&"worktree.prune").visible, "Prune shows only while a folder is missing")
	var cleanup: Button = all_list.footer_button(&"worktree.cleanup")
	expect(cleanup.visible and not cleanup.disabled and cleanup.text.is_empty(), "Clean up is an icon in the footer")
	expect_eq(all_list.footer_button(&"task.new").text, "New worktree…", "the footer's New worktree is labelled")
	var right_click: InputEventMouseButton = InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	(all_list._rows.get_child(1) as Button).gui_input.emit(right_click)
	await get_tree().process_frame
	await get_tree().process_frame
	expect("Delete…" in page.menu_labels() and page.context_menu().get_parent() == all_list,
			"right-click on a row opens its worktree's menu over the list: %s" % [page.menu_labels()])
	page.close_menu()
	await get_tree().process_frame
	expect(page.context_menu().get_parent() != all_list and all_list.visible, "the menu goes back once it closes")
	all_list.choose(1)
	expect(await wait_until(func() -> bool: return page.active_view().worktree_path().ends_with("repo-10-feature")),
			"overflow selection opens the linked fixture worktree")
	strip.chips()[0].chosen.emit()

	# A branch checked out in a worktree: the list says where, deleting it
	# deletes its worktree too, and choosing it shows that worktree.
	var view: WorktreeView = page.active_view()
	var popover: BranchPopover = view.branch_popover()
	press("Ctrl+B")
	expect(await wait_until(func() -> bool: return popover.visible), "Ctrl+B opens the branch list")
	popover.set_filter("feature/login")
	var login: Dictionary = popover.first_ref()
	expect(not String(login.get("worktree", "")).is_empty(), "feature/login says which worktree has it")
	var login_row: TreeItem = popover._tree.get_selected()
	expect_eq(login_row.get_icon(0), AppTheme.icon(&"GitWorktree"), "a branch in another worktree has the worktree icon")
	expect_eq(login_row.get_text(1), "", "with no in-worktree badge")
	popover.menu_requested.emit(login, Vector2.ZERO)
	await get_tree().process_frame
	expect(&"branch.delete" in page.menu_ids(), "a branch in a worktree can be deleted: %s" % [page.menu_ids()])
	page.close_menu()
	popover.branch_chosen.emit(login)
	popover.hide()
	expect(await wait_until(func() -> bool: return page.active_view().session.current_branch() == "feature/login"),
			"choosing it shows its worktree")
	expect_eq(main.tab_count(), 1, "in the same tab")
	expect(strip.chips()[1].selected, "its chip is selected")
	strip.chips()[0].chosen.emit()
	expect(page.active_view() == view, "a click on the first chip goes back")

	# A chip's Branch ▸ is the menu of the branch checked out there, acting
	# on that branch; the worktree's own items still act on the worktree.
	strip.worktree_menu_requested.emit(strip.chips()[1].worktree, Vector2.ZERO)
	await get_tree().process_frame
	var branch_menu: ActionMenu = page.context_menu().submenu("Branch")
	var chip_menu: ActionMenu = page.context_menu()
	expect_eq(chip_menu.top_labels(), PackedStringArray(["Open in", "Copy path", "Branch", "Lock…", "Delete…"]),
			"the chip's menu: its own items, Branch ▸, then Lock beside Delete")
	expect(chip_menu.item_count == 7 and chip_menu.is_item_separator(2) and chip_menu.is_item_separator(4),
			"Branch ▸ in a group of its own")
	if branch_menu != null:
		expect(&"branch.rename" in branch_menu.action_ids() and &"branch.copy_name" in branch_menu.action_ids(),
				"with the branch's items: %s" % [branch_menu.action_ids()])
		expect(&"worktree.copy_path" in page.menu_ids() and not &"worktree.copy_path" in branch_menu.action_ids(),
				"beside the worktree's own")
		expect(branch_menu.press_id(&"branch.rename"), "Rename runs from Branch ▸")
		var rename_form: FormDialog = page.ops().form()
		expect(await wait_until(func() -> bool: return rename_form.visible), "Rename opens")
		expect_eq((rename_form.field("name") as LineEdit).text, "feature/login", "on the chip's branch")
		rename_form.hide()
	expect(page.ref_target().is_empty(), "the menu's target is cleared once it ran")
	var main_wt: Dictionary = strip.chips()[0].worktree
	strip.worktree_menu_requested.emit(main_wt, Vector2.ZERO)
	await get_tree().process_frame
	expect(page.context_menu().submenu("Branch") != null, "the current worktree's chip has Branch ▸ too")
	page.close_menu()

	# Ctrl+T: New worktree. With no name the branches are listed to check
	# out; a new name offers Create first, and the folder preview follows it.
	press("Ctrl+T")
	var ops: RepoOps = page.ops()
	var form: FormDialog = ops.form()
	expect(await wait_until(func() -> bool: return form.visible), "Ctrl+T opens New worktree")
	await get_tree().process_frame
	var form_width: int = form.size.x
	var rows: WorktreeBranchList = ops.worktree_branch_list()
	expect(form.get_ok_button().disabled, "Create waits for a name")
	expect_eq(form.get_ok_button().tooltip_text, "Type a branch name.", "its tooltip says why")
	expect(rows.row_labels().has("feature/login") and not rows.row_labels()[0].begins_with("Create"),
			"with no name, the branches are listed: %s" % [rows.row_labels()])
	expect(rows.choice().is_empty(), "and none is chosen")
	expect_eq(ops.new_worktree_base(), "origin/main", "From is the remote's default branch")
	type_text("task one")
	var name_line: LineEdit = form.field("name") as LineEdit
	expect(await wait_until(func() -> bool: return name_line.text == "task-one"), "a space becomes a dash: %s" % name_line.text)
	expect_eq(rows.row_labels()[0], "Create task-one", "a new name offers Create first: %s" % [rows.row_labels()])
	expect_eq(String(rows.choice().get("start", "")), "new", "and it is chosen")
	expect(ops.base_button().is_visible_in_tree(), "From shows for a new branch")
	expect_eq(ops.folder_preview_text(), ".worktrees/task-one",
			"the folder preview follows the branch, from the repository root")
	expect(not form.field("folder").is_visible_in_tree(), "the folder is a preview until edited")
	expect(form.field("setup") == null, "no Run setup without a setup")
	expect_eq(form.size.x, form_width, "typing the name does not resize the form")
	expect(not form.get_ok_button().disabled, "Create is enabled: %s" % form.get_ok_button().tooltip_text)
	# Browse: a folder with things in it is where the worktree goes; an empty
	# one is the worktree's (the folder shows as a field).
	form.pick_folder("folder", repo)
	await get_tree().process_frame
	expect_eq(ops.folder_preview_text(), "task-one", "a picked folder holds the worktree")
	var empty: String = repo.path_join("picked empty")
	DirAccess.make_dir_absolute(empty)
	form.pick_folder("folder", empty)
	await get_tree().process_frame
	expect(form.field("folder").is_visible_in_tree(), "a picked empty folder shows in the field")
	expect_eq((form.field("folder") as LineEdit).text, "picked empty", "it is the worktree's folder")
	expect_eq(ops.folder_preview_text(), "", "the preview hides while the folder is typed")
	form.hide()

	# A taken folder gets a number instead of blocking Create; the setup copies
	# the main worktree's matching files.
	var task_path: String = repo.path_join(".worktrees/task-one")
	DirAccess.make_dir_recursive_absolute(task_path)
	write_file(task_path.path_join("keep.txt"), "someone else's\n")
	write_file(repo.path_join("notes.local"), "secret\n")
	expect(session.set_worktree_setup(PackedStringArray(["*.local"]), ""), "a setup is saved")
	press("Ctrl+T")
	expect(await wait_until(func() -> bool: return form.visible), "Ctrl+T opens it again")
	rows = ops.worktree_branch_list()
	type_text("task-one")
	expect(await wait_until(func() -> bool: return ops.folder_preview_text().contains("task-one-2")),
			"a taken folder gets a number: %s" % ops.folder_preview_text())
	expect(ops.folder_preview_text().ends_with("task-one is taken"), "the line says why: %s" % ops.folder_preview_text())
	expect(not form.get_ok_button().disabled, "a taken folder does not block Create")
	var setup: CheckBox = form.field("setup") as CheckBox
	expect(setup != null and setup.button_pressed, "Run setup shows, ticked")
	expect(setup != null and setup.text == "Run setup: copy *.local", "it says what it does: %s" % (setup.text if setup else ""))
	press("Enter")
	expect(await wait_until(func() -> bool: return page.views().size() == 3), "the new worktree shows as a chip")
	expect_eq(main.tab_count(), 1, "no new tab")
	var made_path: String = task_path + "-2"
	expect(FileAccess.file_exists(made_path.path_join("README.md")), "the worktree is in the numbered folder")
	expect(await wait_until(func() -> bool: return page.session.current_branch() == "task-one"),
			"the new worktree shows, on task-one")
	expect(await wait_until(func() -> bool: return FileAccess.file_exists(made_path.path_join("notes.local"))),
			"the setup copied the matching file")
	expect(await wait_until(func() -> bool: return strip.chips().size() == 3), "three chips")
	expect(FileAccess.get_file_as_string(repo.path_join(".git/info/exclude")).contains("/.worktrees/"),
			"the nested worktrees are excluded from the main repository's status")
	DirAccess.remove_absolute(repo.path_join("notes.local"))
	# Cleanup below removes it as a clean worktree.
	DirAccess.remove_absolute(made_path.path_join("notes.local"))
	DirAccess.remove_absolute(task_path.path_join("keep.txt"))
	DirAccess.remove_absolute(task_path)
	session.set_worktree_setup(PackedStringArray(), "")
	strip.chips()[0].chosen.emit()

	# A name that matches a remote branch offers to check it out first; a
	# loose ref stands in for a branch someone pushed.
	var main_commit: String = ""
	for ref: Dictionary in session.branch_refs():
		if String(ref["short_name"]) == "main":
			main_commit = String(ref["commit"])
	DirAccess.make_dir_recursive_absolute(repo.path_join(".git/refs/remotes/origin"))
	write_file(repo.path_join(".git/refs/remotes/origin/remote-only"), main_commit + "\n")
	write_file(repo.path_join(".git/refs/heads/free-branch"), main_commit + "\n")
	Core.focus_in(session)
	expect(await wait_until(func() -> bool:
		return session.branch_refs().any(func(r: Dictionary) -> bool: return String(r["short_name"]) == "origin/remote-only")),
			"the remote branch is listed")
	popover.set_filter("origin/")
	expect_eq(popover.row_names(), PackedStringArray(["origin/remote-only"]),
			"Remote keeps remote-only branches but not local duplicates")
	press("Ctrl+T")
	expect(await wait_until(func() -> bool: return form.visible), "Ctrl+T asks again")
	rows = ops.worktree_branch_list()
	name_line = form.field("name") as LineEdit
	type_text("remote-only")
	expect(await wait_until(func() -> bool: return rows.row_labels().size() >= 2 and rows.row_labels()[0] == "origin/remote-only"),
			"the remote branch comes first: %s" % [rows.row_labels()])
	expect_eq(rows.row_labels()[1], "Create remote-only", "then Create")
	expect_eq(String(rows.choice().get("start", "")), "remote", "checking it out is chosen")
	expect_eq(String(rows.choice().get("branch", "")), "remote-only", "as a local branch of the same name")
	expect(not ops.base_button().is_visible_in_tree(), "From hides while checking out")
	press("Down")
	expect_eq(String(rows.choice().get("start", "")), "new", "Down chooses Create")
	expect(ops.base_button().is_visible_in_tree(), "and From shows again")
	press("Up")
	expect_eq(String(rows.choice().get("start", "")), "remote", "Up goes back")
	# An existing local branch is checked out; one in a worktree can't be.
	name_line.text = ""
	type_text("free-branch")
	expect(await wait_until(func() -> bool: return rows.row_labels().size() > 0 and rows.row_labels()[0] == "free-branch"),
			"a local branch comes first: %s" % [rows.row_labels()])
	expect_eq(String(rows.choice().get("start", "")), "existing", "and is checked out")
	expect(not rows.row_labels().has("Create free-branch"), "nothing to create: it exists")
	name_line.text = ""
	type_text("feature/login")
	expect(await wait_until(func() -> bool: return rows.choice().is_empty()), "a branch in a worktree can't be chosen")
	expect(form.get_ok_button().disabled and form.get_ok_button().tooltip_text.contains("is checked out in"),
			"Create says where it is: %s" % form.get_ok_button().tooltip_text)
	# From: branches, remote branches and tags, or any revision typed.
	name_line.text = ""
	type_text("from-test")
	var bases: BasePopover = ops.base_popover()
	ops.base_button().pressed.emit()
	expect(await wait_until(func() -> bool: return bases.visible), "From opens its list")
	expect(bases.row_labels().has("Local") and bases.row_labels().has("Remote") and bases.row_labels().has("origin/main"),
			"it has sections: %s" % [bases.row_labels()])
	bases.set_filter("a1b2c3d")
	expect_eq(bases.row_labels(), PackedStringArray(["Use a1b2c3d"]), "a revision it doesn't list is offered as typed")
	bases.set_filter("free")
	bases.choose_selected()
	expect_eq(ops.new_worktree_base(), "free-branch", "a chosen base is used")
	expect_eq(ops.base_button().text, "free-branch", "and shown")
	form.hide()
	DirAccess.remove_absolute(repo.path_join(".git/refs/heads/free-branch"))

	# A branch prefix from the settings starts the name; typing goes after it.
	expect(not Core.set_settings({"branch_prefix": "a b/"}).is_empty(), "a prefix git refuses is refused")
	expect_eq(Core.set_settings({"branch_prefix": "me/"}), "", "the prefix is saved")
	press("Ctrl+T")
	expect(await wait_until(func() -> bool: return form.visible), "Ctrl+T asks once more")
	name_line = form.field("name") as LineEdit
	expect_eq(name_line.text, "me/", "the name starts with the prefix")
	expect(form.get_ok_button().disabled, "the bare prefix is not a name yet")
	type_text("idea")
	expect(await wait_until(func() -> bool: return name_line.text == "me/idea"), "typing goes after the prefix: %s" % name_line.text)
	expect(await wait_until(func() -> bool: return ops.folder_preview_text().ends_with("me-idea")),
			"the folder follows: %s" % ops.folder_preview_text())
	form.hide()
	Core.set_settings({"branch_prefix": ""})

	# One click: Open in new worktree on a branch's menu makes it at once, with
	# a toast that offers Undo; Undo removes it, and the branch stays (the
	# create only checked it out).
	var toasts: Toasts = main.toasts()
	write_file(repo.path_join(".git/refs/heads/one-click"), main_commit + "\n")
	Core.focus_in(session)
	expect(await wait_until(func() -> bool: return _has_branch(session, "one-click")), "a free branch is listed")
	var one_ref: Dictionary = {"type": "branch", "name": "refs/heads/one-click", "short": "one-click",
		"commit": main_commit, "is_head": false, "upstream": "", "worktree": ""}
	page.active_view().show_ref_menu(one_ref, Vector2.ZERO)
	expect(page.press_menu("Open in new worktree"), "a branch's menu offers it: %s" % [page.menu_labels()])
	var one_path: String = repo.path_join(".worktrees/one-click")
	expect(await wait_until(func() -> bool: return page.session.current_branch() == "one-click"),
			"it shows at once, on the branch")
	expect(FileAccess.file_exists(one_path.path_join("README.md")), "at the template's folder")
	expect(await wait_until(func() -> bool: return toasts.toast_texts().has("New worktree one-click")),
			"a toast says so: %s" % [toasts.toast_texts()])
	expect(toasts.press_fix("Undo", "one-click"), "with Undo: %s" % [toasts.fix_labels()])
	expect(await wait_until(func() -> bool: return session.worktrees().size() == 3), "Undo removed the worktree")
	expect(not DirAccess.dir_exists_absolute(one_path), "and its folder")
	expect(_has_branch(session, "one-click"), "the branch it only checked out stays")
	expect(await wait_until(func() -> bool: return Paths.same(page.active_view().worktree_path(), repo)),
			"the first worktree shows again")
	# A branch in a worktree already can't open in another.
	var login_ref: Dictionary = {"type": "branch", "name": "refs/heads/feature/login", "short": "feature/login",
		"commit": main_commit, "is_head": false, "upstream": "", "worktree": ""}
	expect(ops.new_worktree_spec(login_ref).is_empty(), "a branch in a worktree has nothing to open")

	# Alt+Enter in the branch list: a remote branch becomes a local branch
	# tracking it, in a new worktree; Undo deletes that branch too.
	press("Ctrl+B")
	expect(await wait_until(func() -> bool: return popover.visible), "the branch list opens")
	popover.set_filter("origin/remote-only")
	expect_eq(String(popover.first_ref().get("short", "")), "origin/remote-only", "the remote branch is listed")
	popover.open_selected_in_worktree()
	var remote_path: String = repo.path_join(".worktrees/remote-only")
	expect(await wait_until(func() -> bool: return page.session.current_branch() == "remote-only"),
			"Alt+Enter opens it in a new worktree, as a local branch")
	expect(session.branch_refs().any(func(r: Dictionary) -> bool:
		return String(r["short_name"]) == "remote-only" and String(r["upstream"]) == "origin/remote-only"),
			"tracking the remote branch")
	expect(await wait_until(func() -> bool: return toasts.press_fix("Undo", "remote-only")), "Undo is offered")
	expect(await wait_until(func() -> bool: return not _has_branch(session, "remote-only")),
			"Undo deleted the branch the create made")
	expect(await wait_until(func() -> bool: return not DirAccess.dir_exists_absolute(remote_path)), "and the worktree")
	DirAccess.remove_absolute(repo.path_join(".git/refs/heads/one-click"))

	# History's commit menu: New worktree here… fills in From with the commit.
	ops = page.ops()
	ops.new_worktree("", main_commit)
	expect(await wait_until(func() -> bool: return form.visible), "New worktree here… opens the dialog")
	expect_eq(ops.new_worktree_base(), main_commit, "From is the commit")
	expect_eq(ops.base_button().text, ShortHash.of(main_commit), "shown short")
	form.hide()
	# Enter on a worktree filter that matches nothing: the dialog, with the
	# text as the branch name.
	strip.list_button().pressed.emit()
	all_list.set_filter("brand new")
	all_list._filter.submitted.emit(false)
	expect(await wait_until(func() -> bool: return form.visible), "Enter with no match opens New worktree")
	expect_eq((form.field("name") as LineEdit).text, "brand-new", "named after the filter")
	form.hide()

	# The setup's settings, and a failed setup: a toast with the output, Run
	# again and Open terminal; the worktree stays.
	ops.edit_worktree_setup()
	expect(await wait_until(func() -> bool: return form.visible), "Worktree setup opens")
	(form.field("copy") as TextEdit).text = ".env*\n\n.vscode/\n"
	(form.field("command") as LineEdit).text = "exit 3"
	expect(form.submit(), "it saves")
	var saved: Dictionary = session.worktree_setup()
	expect_eq(Array(saved["copy"]), [".env*", ".vscode/"], "one pattern per line, blanks dropped")
	expect_eq(String(saved["command"]), "exit 3", "and the command")
	ops.run_setup(made_path)
	expect(await wait_until(func() -> bool: return toasts.toast_texts().has("Setup failed in task-one-2")),
			"a failed setup says so: %s" % [toasts.toast_texts()])
	expect("Run again" in toasts.fix_labels() and "Open terminal" in toasts.fix_labels(),
			"with Run again and Open terminal: %s" % [toasts.fix_labels()])
	expect(DirAccess.dir_exists_absolute(made_path), "the worktree stays")
	session.set_worktree_setup(PackedStringArray(), "")

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
	# Deleting the shown worktree moves to the main one; its branch goes too.
	expect(page.show_worktree(spare), "the spare worktree shows")
	expect(await wait_until(func() -> bool: return page.session.is_ready()), "and loads")
	expect(await _menu_for(page, session, "repo-10-spare", "Delete…"), "the menu offers delete for the shown worktree")
	var delete_form: FormDialog = page.ops().form()
	expect(await wait_until(func() -> bool: return delete_form.visible), "delete asks first")
	var with_branch: CheckBox = delete_form.field("delete_branch") as CheckBox
	expect(with_branch != null and with_branch.accessibility_name == "spare", "deleting the branch too is offered")
	expect(await wait_until(func() -> bool: return with_branch.button_pressed), "on, once it is found merged")
	expect_eq(delete_form.get_ok_button().theme_type_variation, &"DangerButton", "Delete is the red button")
	press("Enter")
	expect(await wait_until(func() -> bool: return session.worktrees().size() == 3), "the spare worktree was deleted")
	expect(not DirAccess.dir_exists_absolute(spare), "its folder is gone")
	expect(Paths.same(page.active_view().worktree_path(), repo), "the main worktree shows")
	expect(await wait_until(func() -> bool: return not _has_branch(session, "spare")), "its branch was deleted")
	await _deleted_outside(main, page, session, repo, fixtures.path_join("repo-10-gone"))
	if OS.get_name() == "Windows":
		await _delete_while_in_use(main, page, session, repo, fixtures.path_join("repo-10-busy"))

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

	# Settings apply as soon as a control changes.
	expect(Actions.run_action(&"app.settings"), "Settings opens")
	var settings: SettingsWindow = main.settings_window()
	expect(await wait_until(func() -> bool: return settings.visible), "the settings window shows")
	(settings.get_control(&"auto_fetch_minutes") as SpinBox).value = 15
	expect_eq(int(Core.settings()["auto_fetch_minutes"]), 15, "the interval was saved")
	Core.set_settings({"auto_fetch_minutes": 0})

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


## The shown worktree's folder deleted outside gitbello: its view closes
## and the main worktree shows, with no error panel or toast.
func _deleted_outside(main: Main, page: RepoTab, session: RepoSession, repo: String, gone: String) -> void:
	var count: int = session.worktrees().size()
	session.add_worktree(gone, "gone", "main")
	expect(await wait_until(func() -> bool: return session.worktrees().size() == count + 1), "a worktree to delete was added")
	expect(page.show_worktree(gone), "it shows")
	expect(await wait_until(func() -> bool: return page.session.is_ready()), "and loads")
	var views: int = page.views().size()
	var toasts: int = main.toasts().toast_count()
	_remove_tree(gone)
	expect(not FileAccess.file_exists(gone.path_join(".git")), "its files were deleted outside gitbello")
	Core.focus_in(page.session)
	expect(await wait_until(func() -> bool: return Paths.same(page.active_view().worktree_path(), repo)),
			"the main worktree shows")
	expect_eq(page.views().size(), views - 1, "the deleted worktree's view closed")
	expect(not page.has_error(), "no error panel")
	expect(main.toasts().toast_count() <= toasts, "no toast")
	session.prune_worktrees()
	expect(await wait_until(func() -> bool: return session.worktrees().size() == count), "pruned")


static func _remove_tree(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	for sub: String in dir.get_directories():
		_remove_tree(path.path_join(sub))
	for file: String in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


## Windows: deleting a worktree a program runs from (a copy of `findstr`
## waiting on its input, like an app built there) deletes nothing and says
## which program; once it exits, the toast's Try again deletes the worktree
## and its branch.
func _delete_while_in_use(main: Main, page: RepoTab, session: RepoSession, repo: String, busy: String) -> void:
	var count: int = session.worktrees().size()
	session.add_worktree(busy, "busy", "main")
	expect(await wait_until(func() -> bool: return session.worktrees().size() == count + 1), "a busy worktree was added")
	# Like build output, the program's folder is ignored.
	var exclude: FileAccess = FileAccess.open(repo.path_join(".git/info/exclude"), FileAccess.READ_WRITE)
	exclude.seek_end()
	exclude.store_string("/bin/\n")
	exclude.close()
	var exe: String = busy.path_join("bin/held.exe")
	DirAccess.make_dir_recursive_absolute(exe.get_base_dir())
	# CI runners cannot start a copy of PING.EXE; findstr works everywhere.
	var copied: Error = DirAccess.copy_absolute(OS.get_environment("SystemRoot").path_join("System32/findstr.exe"), exe)
	expect_eq(copied, OK, "the program was copied into the worktree")
	# It reads its open input until killed.
	var held: Dictionary = OS.execute_with_pipe(exe, ["x"])
	var pid: int = int(held.get("pid", -1))
	expect(pid > 0, "a program runs from the worktree")
	expect(await _menu_for(page, session, "repo-10-busy", "Delete…"), "the menu offers delete")
	var form: FormDialog = page.ops().form()
	expect(await wait_until(func() -> bool: return form.visible), "delete asks first")
	expect(await wait_until(func() -> bool: return bool(form.values().get("delete_branch", false))),
			"its merged branch is ticked once checked")
	press("Enter")
	var retry: Array[Button] = []
	expect(await wait_until(func() -> bool:
		retry.assign(main.toasts().find_children("*", "Button", true, false).filter(
				func(b: Node) -> bool: return (b as Button).text == "Try again"))
		return not retry.is_empty()), "a toast offers to try again")
	var toast_text: String = "\n".join(main.toasts().find_children("*", "Label", true, false).map(
			func(l: Node) -> String: return (l as Label).text))
	expect(toast_text.contains("a program is running files from the worktree"), "the toast says why: %s" % toast_text)
	expect(toast_text.contains("held.exe (PID %d)" % pid), "and names the program: %s" % toast_text)
	expect_eq(session.worktrees().size(), count + 1, "the worktree is still there")
	expect(FileAccess.file_exists(busy.path_join("README.md")), "nothing was deleted")
	OS.kill(pid)
	expect(await wait_until(func() -> bool: return not OS.is_process_running(pid)), "the program exits")
	if retry.is_empty():
		return
	retry[0].pressed.emit()
	expect(await wait_until(func() -> bool: return session.worktrees().size() == count), "try again deletes the worktree")
	expect(not DirAccess.dir_exists_absolute(busy), "its folder is gone")
	expect(await wait_until(func() -> bool: return not _has_branch(session, "busy")), "with its branch, as chosen")


func _overflow_selection() -> void:
	var strip: WorktreeStrip = WorktreeStrip.new()
	# The chips' widths come from the theme (`max_width` caps each name; 0
	# without it), and the project theme is only filled in once a Main runs.
	strip.theme = AppTheme.build(false)
	strip.size.x = 480.0
	add_child(strip)
	var rows: Array[Dictionary] = []
	for i: int in 6:
		rows.append({"path": "C:/fixture/worktree-%d" % i, "name": "worktree-%d" % i,
			"branch": "feature-%d" % i, "head": "", "detached": false, "bare": false,
			"locked": false, "lock_reason": "", "prunable": false, "is_main": i == 0, "changed": 0})
	var first: String = String(rows[0]["path"])
	var last: String = String(rows[5]["path"])
	strip.worktree_chosen.connect(func(path: String) -> void: strip.show_worktrees(rows, path))
	strip.show_worktrees(rows, last)
	await _settle_strip()
	expect(strip.overflows(), "the test strip overflows")
	expect(_chip_in_view(strip, last), "an initially selected last chip scrolls into view")
	var main_chip: WorktreeChip = strip.chips()[0]
	expect(main_chip.get_parent() != strip.scroll_row().content(), "the main worktree's chip is outside the scroll")
	var main_x: float = main_chip.global_position.x
	var scrolled: int = strip._scroll.scroll_horizontal
	expect(scrolled > 0, "revealing the last chip scrolled the linked ones")
	strip.show_worktrees(rows, first)
	await _settle_strip()
	expect(_chip_in_view(strip, first), "the main worktree's chip stays in view")
	expect_eq(main_chip.global_position.x, main_x, "and in place while the linked chips scroll")
	expect_eq(strip._scroll.scroll_horizontal, scrolled, "choosing it leaves the linked chips where they are")
	# Filled, not opened: the actions its footer reads left with the test's Main.
	strip.all_list().fill(rows, first)
	strip.all_list().choose(5)
	await _settle_strip()
	expect(_chip_in_view(strip, last), "the all-worktrees choice reveals its chip")
	strip._scroll.scroll_horizontal = 0
	await _settle_strip()
	strip.show_worktrees(rows, last)
	await _settle_strip()
	expect_eq(strip._scroll.scroll_horizontal, 0, "an unchanged refresh preserves manual scrolling")
	strip.show_worktrees(rows, first)
	strip.show_worktrees(rows, last)
	strip.show_worktrees(rows, first)
	await _settle_strip()
	expect(_chip_in_view(strip, first), "rapid selections reveal only the latest chip")
	strip.show_worktrees(rows, last)
	await _settle_strip()
	strip.size.x = 340.0
	await _settle_strip()
	expect(_chip_in_view(strip, last), "narrowing the strip keeps its selection in view")
	# The main worktree's chip does not scroll: leave the linked ones room.
	strip.size.x = 520.0
	await _settle_strip()
	rows[0]["name"] = "a-longer-main-worktree-folder"
	strip.show_worktrees(rows, last)
	await _settle_strip()
	expect(_chip_in_view(strip, last), "a preceding chip growing keeps the selection in view")
	rows[5]["name"] = "a-first"
	strip.show_worktrees(rows, last)
	await _settle_strip()
	expect(_chip_in_view(strip, last), "reordering resolves the selection by path")
	rows[5]["name"] = "an-oversized-worktree-".repeat(8)
	strip.show_worktrees(rows, last)
	await _settle_strip()
	for chip: WorktreeChip in strip.chips():
		if Paths.same(chip.path(), last):
			expect(chip.global_position.x - strip._scroll.global_position.x <= strip.scroll_row().cover_width() + 1.0,
					"an oversized selected chip exposes its leading edge")
	rows[0]["name"] = "worktree-0"
	rows.remove_at(5)
	strip.show_worktrees(rows, first)
	await _settle_strip()
	expect(_chip_in_view(strip, first), "removing a chip does not leave a stale reveal target")
	strip.show_worktrees([rows[0]], first)
	strip.size.x = 800.0
	await _settle_strip()
	expect(not strip.overflows(), "the chips fit again")
	expect(_chip_in_view(strip, first), "a fitting selection remains visible")
	strip.queue_free()
	await get_tree().process_frame


func _overflow_presentation() -> void:
	var strip: WorktreeStrip = WorktreeStrip.new()
	add_child(strip)
	strip.size = Vector2(240.0, 40.0)
	var base: Dictionary = {"path": "/fixture/main", "name": "main", "branch": "main", "head": "abcdef1234",
		"detached": false, "bare": false, "locked": false, "lock_reason": "", "prunable": false,
		"is_main": true, "changed": 0, "conflicts": 0, "ahead": 0, "behind": 0, "operation": ""}
	var dirty: Dictionary = base.duplicate()
	dirty.merge({"path": "/fixture/dirty", "name": "dirty", "is_main": false, "changed": 3, "ahead": 1, "behind": 2}, true)
	var conflict: Dictionary = base.duplicate()
	conflict.merge({"path": "/fixture/conflict", "name": "conflict", "is_main": false, "changed": 2,
		"conflicts": 1, "operation": "merge", "locked": true, "lock_reason": "keep for review"}, true)
	var missing: Dictionary = conflict.duplicate()
	missing.merge({"path": "/fixture/missing", "name": "missing", "prunable": true, "changed": -1}, true)
	var locked: Dictionary = base.duplicate()
	locked.merge({"path": "/fixture/locked", "name": "locked", "is_main": false, "locked": true}, true)
	var detached: Dictionary = base.duplicate()
	detached.merge({"path": "/fixture/detached", "name": "detached", "is_main": false, "detached": true, "branch": ""}, true)
	var rows: Array[Dictionary] = [missing, dirty, locked, detached, conflict, base]
	strip.show_worktrees(rows, "/fixture/dirty")
	await get_tree().process_frame
	await get_tree().process_frame
	expect(strip.overflows(), "a narrow strip overflows")
	strip.list_button().pressed.emit()
	var list: WorktreeListPopover = strip.all_list()
	var listed: Array[Dictionary] = list.rows()
	expect_eq(listed.size(), 6, "all worktrees listed")
	if listed.size() == 6:
		expect_eq([listed[0]["name"], listed[0]["branch"], listed[0]["changes"], listed[0]["marker"]],
				["main", "main", "", "GitWorktree"], "main remains first with no changes")
		expect_eq([listed[3]["name"], listed[3]["changes"], listed[3]["ahead"], listed[3]["behind"]],
				["dirty", "3", 1, 2], "the dirty row has its changes and both counts, in pills")
		expect(listed[3]["selected"] and not listed[0]["selected"], "the shown worktree's row is marked")
		expect_eq(listed[2]["branch"], "detached abcdef1", "detached head is identified")
		expect_eq(listed[1]["marker"], "GitConflict", "conflict takes priority over lock")
		expect_eq(listed[4]["marker"], "Lock", "locked marker")
		expect_eq(listed[5]["marker"], "StatusWarning", "missing takes priority over conflict")
		var tip: String = String(listed[1]["tooltip"])
		for detail: String in ["/fixture/conflict", "2 changed files", "1 conflicted file", "Merge in progress", "Locked: keep for review"]:
			expect(tip.contains(detail), "combined tooltip includes " + detail)
		expect(String(listed[3]["tooltip"]).contains("1 commit ahead") and String(listed[3]["tooltip"]).contains("2 commits behind"), "sync detail")
		expect(String(listed[5]["tooltip"]).contains("Folder missing"), "missing explained")
		expect(listed[5]["changes"] == "" and not String(listed[5]["tooltip"]).contains("No local changes"), "unknown is not shown as clean")
		expect_eq(list.target_index(), 3, "with no filter, Enter would choose the shown worktree")
		list.set_filter("DIRT")
		expect_eq(list.rows().size(), 1, "the filter matches folder names, ignoring case")
		expect_eq(list.target_index(), 0, "Enter would choose the first match")
		list.set_filter("abcdef")
		expect(list.rows().size() == 1 and list.rows()[0]["name"] == "detached", "the filter matches what the branch column says")
		list.set_filter("no such worktree")
		expect(list.rows().is_empty() and list.target_index() == -1, "nothing matches")
		expect_eq(list.empty_text(), "No match · Enter: new worktree", "and the list offers a new one")
		list.set_filter("")
		expect_eq(list.rows().size(), 6, "clearing the filter shows every worktree")
	list.hide()
	dirty["changed"] = 4
	strip.show_worktrees(rows, "/fixture/main")
	strip.list_button().pressed.emit()
	listed = list.rows()
	expect(listed.size() == 6 and listed[3]["changes"] == "4", "reopening gets current status")
	expect(listed.size() == 6 and listed[0]["selected"] and not listed[3]["selected"], "selection refreshes")
	list.hide()
	strip.queue_free()
	await get_tree().process_frame


func _settle_strip() -> void:
	for frame: int in 12:
		await get_tree().process_frame


static func _chip_in_view(strip: WorktreeStrip, path: String) -> bool:
	for chip: WorktreeChip in strip.chips():
		if Paths.same(chip.path(), path):
			var row: ScrollRow = strip.scroll_row()
			var viewport: Rect2 = strip.get_global_rect()
			if chip.get_parent() == row.content():
				# Clear of the arrows over the row's ends.
				var span: Vector2 = row._visible_span(float(row.scroll_container().scroll_horizontal))
				var origin: float = row.content().global_position.x
				viewport = Rect2(origin + span.x, 0.0, span.y - span.x, 0.0)
			var rect: Rect2 = chip.get_global_rect()
			return rect.position.x >= viewport.position.x - 1.0 and rect.end.x <= viewport.end.x + 1.0
	return false


func _test_worktree_list() -> void:
	var list: WorktreeListPopover = WorktreeListPopover.new()
	add_child(list)
	var base: Dictionary = {"head": "abcdef1234", "detached": false, "prunable": false, "locked": false,
		"lock_reason": "", "conflicts": 0, "operation": ""}
	var main_wt: Dictionary = base.merged({"path": "C:/test/repo", "name": "repo", "branch": "main",
		"changed": 2, "ahead": 1, "behind": 0}, true)
	var login: Dictionary = base.merged({"path": "C:/test/repo-login", "name": "repo-login", "branch": "feature/login",
		"changed": 0, "ahead": 0, "behind": 3, "locked": true}, true)
	var worktrees: Array[Dictionary] = [main_wt, login]
	list.fill(worktrees, "C:/test/repo-login")
	var rows: Array[Dictionary] = list.rows()
	expect_eq(rows.size(), 2, "one row per worktree")
	if rows.size() == 2:
		expect_eq(rows[0], {"name": "repo", "branch": "main", "changes": "2", "ahead": 1, "behind": 0,
				"marker": "GitWorktree", "tooltip": "C:/test/repo\n2 changed files\n1 commit ahead", "selected": false},
				"the main row has its changes and the commit to push, with no arrows in its text")
		expect_eq(rows[1], {"name": "repo-login", "branch": "feature/login", "changes": "", "ahead": 0, "behind": 3,
				"marker": "Lock", "tooltip": "C:/test/repo-login\n3 commits behind\nLocked", "selected": true},
				"the shown worktree's row is marked, with the commits to pull and its lock")
	var picked: Array[String] = []
	list.chosen.connect(func(path: String) -> void: picked.append(path))
	list.choose(0)
	expect_eq(picked, ["C:/test/repo"] as Array[String], "a row emits its worktree's path")
	list.queue_free()


func _test_chip_tooltips() -> void:
	var chip: WorktreeChip = WorktreeChip.new()
	var wt: Dictionary = {"path": "C:/test/repo-login", "name": "repo-login", "short_name": "login",
		"branch": "main", "head": "abcdef1234", "detached": false, "prunable": false, "locked": false,
		"lock_reason": "", "changed": 1, "ahead": 1, "behind": 2, "conflicts": 1, "operation": "rebase"}
	chip.set_worktree(wt)
	add_child(chip)
	expect_eq(chip.texts(), {"name": "login", "marker": "GitConflict"}, "the short name; a conflict outranks changes")
	expect_eq(chip.tooltip_text, "repo-login\nmain\nC:/test/repo-login\n1 changed file\n1 conflicted file\n1 commit ahead\n2 commits behind\nRebase in progress",
			"the tooltip names the folder, branch and path, then the state")
	_expect_card(chip, [&"FileModified", &"GitConflict", &"GitAhead", &"GitBehind", &"GitConflict"])
	wt.merge({"changed": 3, "ahead": 2, "behind": 0, "conflicts": 0, "operation": "", "locked": true, "lock_reason": "[b]review[/b]"}, true)
	chip.set_worktree(wt)
	expect_eq(chip.texts()["marker"], "Lock", "a lock outranks changes")
	expect(chip.tooltip_text.contains("3 changed files"), "changed files plural")
	expect(chip.tooltip_text.ends_with("Locked: [b]review[/b]"), "lock reason is retained as plain text")
	var reused: Control = chip._make_custom_tooltip(chip.tooltip_text)
	wt.merge({"locked": false}, true)
	chip.set_worktree(wt)
	expect_eq(chip.texts()["marker"], "dot", "changed files show a dot")
	_expect_card(chip, [&"FileModified", &"GitAhead"], reused)
	wt.merge({"changed": 0, "ahead": 0, "detached": true}, true)
	chip.set_worktree(wt)
	expect_eq(chip.texts(), {"name": "login", "marker": ""}, "a clean detached worktree shows only its name")
	expect_eq(chip.tooltip_text, "repo-login\nDetached at abcdef1\nC:/test/repo-login\nNo changed files",
			"known zero does not claim synced; detached is in the tooltip")
	wt.merge({"changed": -1, "ahead": 9}, true)
	chip.set_worktree(wt)
	expect_eq(chip.texts()["marker"], "", "unknown status has no dot")
	expect(chip.tooltip_text.ends_with("Status not available yet"), "unknown is not reported as clean")
	wt.merge({"prunable": true, "changed": 3}, true)
	chip.set_worktree(wt)
	expect_eq(chip.texts()["marker"], "StatusWarning", "a missing folder has the warning marker")
	expect(chip.tooltip_text.ends_with("C:/test/repo-login\nFolder missing"), "missing folder takes precedence over status")
	_expect_card(chip, [&"StatusWarning"])
	wt.erase("short_name")
	chip.set_worktree(wt)
	expect_eq(chip.texts()["name"], "repo-login", "without a short name the folder is shown")
	chip.queue_free()


## Checks a chip's tooltip card against its plain tooltip: title, branch and
## path lines, then one line per state with `status_icons`.
func _expect_card(chip: WorktreeChip, status_icons: Array[StringName], existing: Control = null) -> void:
	var child_count: int = chip.get_child_count()
	var card: Control = existing if existing != null else chip._make_custom_tooltip(chip.tooltip_text)
	var lines: PackedStringArray = chip.tooltip_text.split("\n")
	var title: Label = card.get_child(0) as Label
	expect_eq(title.text, lines[0], "the card's title is the folder")
	expect_eq(title.theme_type_variation, &"WorktreeTooltipTitle", "the title is styled as one")
	expect_eq((card.get_child(1).get_child(1) as Label).text, lines[1], "then the branch")
	expect_eq((card.get_child(2).get_child(1) as Label).text, lines[2], "then the literal path")
	var status: Node = card.get_child(3)
	expect_eq(status.get_child_count(), status_icons.size(), "one status line per state")
	for i: int in mini(status.get_child_count(), status_icons.size()):
		var icon: TextureRect = status.get_child(i).get_child(0) as TextureRect
		var tinted: bool = status_icons[i] in [&"GitAhead", &"GitBehind"]
		expect_eq(icon.texture, AppTheme.tintable_icon(status_icons[i]) if tinted else AppTheme.icon(status_icons[i]),
				"status line %d has its themed icon" % i)
		expect_eq((status.get_child(i).get_child(1) as Label).text, lines[3 + i], "status line %d has its text" % i)
	card.free()
	expect_eq(chip.get_child_count(), child_count, "custom tooltips do not change persistent chip layout")


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


static func _has_branch(session: RepoSession, branch: String) -> bool:
	for ref: Dictionary in session.branch_refs():
		if String(ref["kind"]) == "branch" and String(ref["short_name"]) == branch:
			return true
	return false
