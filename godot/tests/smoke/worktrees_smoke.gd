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
	_test_chip_tooltips()
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
	strip._all_button.pressed.emit()
	var all_menu: PopupMenu = strip._all_menu
	expect_eq(all_menu.item_count, 2, "overflow lists both real worktrees")
	all_menu.id_pressed.emit(1)
	all_menu.hide()
	expect(await wait_until(func() -> bool: return page.active_view().worktree_path().ends_with("repo-10-feature")),
			"overflow selection opens the linked fixture worktree")
	strip.chips()[0].chosen.emit()

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
	expect(with_branch != null and with_branch.button_pressed and with_branch.text.contains("spare"),
			"deleting the branch too is offered, on")
	expect_eq(delete_form.get_ok_button().theme_type_variation, &"DangerButton", "Delete is the red button")
	press("Enter")
	expect(await wait_until(func() -> bool: return session.worktrees().size() == 3), "the spare worktree was deleted")
	expect(not DirAccess.dir_exists_absolute(spare), "its folder is gone")
	expect(Paths.same(page.active_view().worktree_path(), repo), "the main worktree shows")
	expect(await wait_until(func() -> bool: return not _has_branch(session, "spare")), "its branch was deleted")

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


func _overflow_selection() -> void:
	var strip: WorktreeStrip = WorktreeStrip.new()
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
	expect(strip._all_button.visible, "the test strip overflows")
	expect(_chip_in_view(strip, last), "an initially selected last chip scrolls into view")
	strip.show_worktrees(rows, first)
	await _settle_strip()
	expect(_chip_in_view(strip, first), "selecting the first chip scrolls back")
	strip._all_menu.id_pressed.emit(5)
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
	expect(not strip._all_button.visible, "the all-worktrees button hides when the chips fit")
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
	expect(strip._all_button.visible, "a narrow strip exposes overflow")
	strip._all_button.pressed.emit()
	var menu: PopupMenu = strip._all_menu
	expect_eq(menu.item_count, 6, "all worktrees listed")
	expect_eq(menu.get_item_text(0), "main  ·  main", "main remains first with no clean badge")
	expect_eq(menu.get_item_text(3), "dirty  ·  main  3 ↑1 ↓2", "compact dirty and sync counts")
	expect(menu.is_item_checked(3) and menu.is_item_radio_checkable(3), "selection remains a radio indicator")
	expect_eq(menu.get_item_text(2), "detached  ·  detached abcdef1", "detached head is identified")
	expect(menu.get_item_icon(0) == null and menu.get_item_icon(3) == null, "clean and dirty have no extra icon")
	expect(menu.get_item_icon(1) == AppTheme.icon(&"GitConflict"), "conflict takes priority over lock")
	expect(menu.get_item_icon(4) == AppTheme.icon(&"Lock"), "locked marker")
	expect(menu.get_item_icon(5) == AppTheme.icon(&"StatusWarning"), "missing takes priority over conflict")
	var tip: String = menu.get_item_tooltip(1)
	for detail: String in ["/fixture/conflict", "2 changed files", "1 conflicted file", "Merge in progress", "Locked: keep for review"]:
		expect(tip.contains(detail), "combined tooltip includes " + detail)
	expect(menu.get_item_tooltip(3).contains("1 commit ahead") and menu.get_item_tooltip(3).contains("2 commits behind"), "sync detail")
	expect(menu.get_item_tooltip(5).contains("The folder is missing."), "missing explained")
	expect(not menu.get_item_text(5).contains("-1") and not menu.get_item_tooltip(5).contains("No local changes"), "unknown is not shown as clean")
	menu.hide()
	dirty["changed"] = 4
	strip.show_worktrees(rows, "/fixture/main")
	strip._all_button.pressed.emit()
	expect(menu.get_item_text(3).ends_with("4 ↑1 ↓2"), "reopening gets current status")
	expect(menu.is_item_checked(0) and not menu.is_item_checked(3), "selection refreshes")
	menu.hide()
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


func _test_chip_tooltips() -> void:
	var chip: WorktreeChip = WorktreeChip.new()
	var wt: Dictionary = {"path": "C:/test/repo", "name": "repo", "branch": "main",
		"head": "abcdef1234", "detached": false, "prunable": false, "locked": false,
		"lock_reason": "", "changed": 1, "ahead": 1, "behind": 2, "conflicts": 1, "operation": "rebase"}
	chip.set_worktree(wt)
	add_child(chip)
	expect_eq(chip.texts()["badge"], "1 ↑1 ↓2", "tooltip explanations do not change the badge")
	expect_eq(chip.tooltip_text, "C:/test/repo\n1 changed file\n1 conflicted file\nRebase in progress", "tracking has no heading, words or unicode arrows")
	_expect_tooltip_tracking(chip, [{"icon": &"GitPush", "count": "1"}, {"icon": &"GitPull", "count": "2"}])
	wt.merge({"changed": 3, "ahead": 2, "behind": 0, "conflicts": 2, "operation": "", "locked": true, "lock_reason": "[b]review[/b]"}, true)
	chip.set_worktree(wt)
	expect(chip.tooltip_text.contains("3 changed files"), "changed files plural")
	expect(chip.tooltip_text.contains("2 conflicted files"), "conflicted files plural")
	expect(chip.tooltip_text.ends_with("Locked: [b]review[/b]"), "lock reason is retained as plain text")
	_expect_tooltip_tracking(chip, [{"icon": &"GitPush", "count": "2"}])
	var reused_tooltip: Control = chip._make_custom_tooltip(chip.tooltip_text)
	wt.merge({"ahead": 0, "behind": 1}, true)
	chip.set_worktree(wt)
	_expect_tooltip_tracking(chip, [{"icon": &"GitPull", "count": "1"}], reused_tooltip)
	reused_tooltip = chip._make_custom_tooltip(chip.tooltip_text)
	wt.merge({"changed": 0, "ahead": 0, "behind": 0, "conflicts": 0, "locked": false, "detached": true}, true)
	chip.set_worktree(wt)
	expect_eq(chip.tooltip_text, "C:/test/repo\nNo changed files", "known zero does not claim synced or an upstream")
	expect_eq(chip.texts()["badge"], "", "zero counts remain hidden")
	_expect_tooltip_tracking(chip, [], reused_tooltip)
	wt.merge({"changed": -1, "ahead": 9, "behind": 8}, true)
	chip.set_worktree(wt)
	expect_eq(chip.tooltip_text, "C:/test/repo\nStatus not available yet", "unknown is not reported as clean")
	_expect_tooltip_tracking(chip, [])
	wt.merge({"prunable": true, "changed": 3}, true)
	chip.set_worktree(wt)
	expect_eq(chip.tooltip_text, "C:/test/repo\nThe folder is missing.", "missing folder takes precedence over status")
	_expect_tooltip_tracking(chip, [])
	chip.queue_free()


func _expect_tooltip_tracking(chip: WorktreeChip, expected: Array[Dictionary], existing: Control = null) -> void:
	var child_count: int = chip.get_child_count()
	var tooltip: Control = existing if existing != null else chip._make_custom_tooltip(chip.tooltip_text)
	var text: Label = tooltip.get_child(0) as Label
	expect_eq(text.text, chip.tooltip_text, "paths and user content remain literal label text")
	expect_eq(text.theme_type_variation, &"TooltipLabel", "native tooltip font styling")
	expect_eq(tooltip.get_child_count(), 1 if expected.is_empty() else 2, "no empty or stale tracking row")
	var icons: Array[Node] = tooltip.find_children("*", "TextureRect", true, false)
	expect_eq(icons.size(), expected.size(), "only positive known counts have icons")
	for i: int in mini(icons.size(), expected.size()):
		var icon: TextureRect = icons[i] as TextureRect
		var count: Label = icon.get_parent().get_child(1) as Label
		expect_eq(icon.texture, AppTheme.icon(StringName(expected[i]["icon"])), "tracking uses the actual themed SVG texture")
		expect_eq(count.text, String(expected[i]["count"]), "the icon is paired with only its count")
		expect_eq(count.theme_type_variation, &"TooltipLabel", "tracking uses tooltip font styling")
	tooltip.free()
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
