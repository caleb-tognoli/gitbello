extends SmokeTest
## M6, reworked in M6.5 P2: worktrees as chips in one repository tab. A chip
## shows its worktree; a branch checked out in another worktree jumps there
## from the branch list and deleting it offers its worktree too; Ctrl+T runs the new-task flow
## (the folder follows the branch name) and shows the result; a chip's menu
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
	expect("Delete branch…" in page.menu_labels(), "a branch in a worktree can be deleted: %s" % [page.menu_labels()])
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
	await get_tree().process_frame
	var form_width: int = form.size.x
	var base: OptionButton = form.field("base") as OptionButton
	base.item_selected.emit(base.selected)
	expect(form.get_ok_button().disabled, "Create waits for a name")
	expect(not form.get_ok_button().tooltip_text.is_empty(), "its tooltip says why")
	type_text("task one")
	var folder: LineEdit = form.field("folder") as LineEdit
	expect(await wait_until(func() -> bool: return folder.text.ends_with("task-one")),
			"the folder follows the branch: %s" % folder.text)
	expect_eq(form.size.x, form_width, "typing the name does not resize the form")
	expect_eq(folder.text, ".worktrees/task-one",
			"the default template is shown from the repository root: %s" % folder.text)
	var task_path: String = repo.path_join(folder.text)
	# Browse: a folder with things in it is where the worktree goes; an empty
	# one is the worktree's folder.
	form.pick_folder("folder", repo)
	expect_eq(folder.text, "task-one", "a picked folder holds the worktree")
	var empty: String = repo.path_join("picked empty")
	DirAccess.make_dir_absolute(empty)
	form.pick_folder("folder", empty)
	expect_eq(folder.text, "picked empty", "a picked empty folder is the worktree's")
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
	expect(FileAccess.get_file_as_string(repo.path_join(".git/info/exclude")).contains("/.worktrees/"),
			"the nested worktrees are excluded from the main repository's status")
	strip.chips()[0].chosen.emit()

	# A name that matches a remote branch offers to check it out instead; a
	# loose ref stands in for a branch someone pushed.
	var main_commit: String = ""
	for ref: Dictionary in session.branch_refs():
		if String(ref["short_name"]) == "main":
			main_commit = String(ref["commit"])
	DirAccess.make_dir_recursive_absolute(repo.path_join(".git/refs/remotes/origin"))
	write_file(repo.path_join(".git/refs/remotes/origin/remote-only"), main_commit + "\n")
	Core.focus_in(session)
	expect(await wait_until(func() -> bool:
		return session.branch_refs().any(func(r: Dictionary) -> bool: return String(r["short_name"]) == "origin/remote-only")),
			"the remote branch is listed")
	popover.set_filter("origin/")
	expect_eq(popover.row_names(), PackedStringArray(["origin/remote-only"]),
			"Remote keeps remote-only branches but not local duplicates")
	press("Ctrl+T")
	expect(await wait_until(func() -> bool: return form.visible), "Ctrl+T asks again")
	var track: CheckBox = form.field("track") as CheckBox
	var start: OptionButton = form.field("base") as OptionButton
	expect(not track.is_visible_in_tree(), "no offer before a name")
	type_text("remote-only")
	expect(await wait_until(func() -> bool: return track.is_visible_in_tree()), "the remote branch is offered")
	expect(track.button_pressed, "checking it out is on")
	expect(track.text.contains("origin/remote-only"), "it names the remote branch: %s" % track.text)
	expect(start.disabled, "the base does not apply while tracking")
	track.button_pressed = false
	expect(not start.disabled, "unticked, the base applies again")
	type_text("x")
	expect(await wait_until(func() -> bool: return not track.is_visible_in_tree()), "another name drops the offer")
	form.hide()

	# A branch prefix from the settings starts the name; typing goes after it.
	expect(not Core.set_settings({"branch_prefix": "a b/"}).is_empty(), "a prefix git refuses is refused")
	expect_eq(Core.set_settings({"branch_prefix": "me/"}), "", "the prefix is saved")
	press("Ctrl+T")
	expect(await wait_until(func() -> bool: return form.visible), "Ctrl+T asks once more")
	var name_line: LineEdit = form.field("name") as LineEdit
	expect_eq(name_line.text, "me/", "the name starts with the prefix")
	start = form.field("base") as OptionButton
	start.item_selected.emit(start.selected)
	expect(form.get_ok_button().disabled, "the bare prefix is not a name yet")
	type_text("idea")
	expect(await wait_until(func() -> bool: return name_line.text == "me/idea"), "typing goes after the prefix: %s" % name_line.text)
	var shown: LineEdit = form.field("folder") as LineEdit
	expect(await wait_until(func() -> bool: return shown.text.ends_with("me-idea")), "the folder follows: %s" % shown.text)
	expect(not shown.text.is_absolute_path(), "shown from the repository's folder: %s" % shown.text)
	form.hide()
	Core.set_settings({"branch_prefix": ""})

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
	expect(with_branch != null and with_branch.button_pressed and with_branch.accessibility_name == "spare",
			"deleting the branch too is offered, on")
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
	strip.show_worktrees(rows, first)
	await _settle_strip()
	expect(_chip_in_view(strip, first), "selecting the first chip scrolls back")
	strip.list_button().pressed.emit()
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
			expect(absf(chip.global_position.x - strip._scroll.global_position.x) < 2.0,
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
		expect(String(listed[5]["tooltip"]).contains("The folder is missing."), "missing explained")
		expect(listed[5]["changes"] == "" and not String(listed[5]["tooltip"]).contains("No local changes"), "unknown is not shown as clean")
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
	var viewport: Rect2 = strip._scroll.get_global_rect()
	for chip: WorktreeChip in strip.chips():
		if Paths.same(chip.path(), path):
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
	(list.find_children("*", "Button", true, false)[0] as Button).pressed.emit()
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
	expect(chip.tooltip_text.ends_with("C:/test/repo-login\nThe folder is missing."), "missing folder takes precedence over status")
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
