extends SmokeTest
## M8b: Blame. Blames a file from Changes (the working copy: every line's
## commit, the uncommitted lines, the strip's counts), focuses a commit by
## its gutter (details, tinted lines, the marked version, next change), lets
## go of it, blames before a commit (the version under the old name) until
## the commit that added the file, shows a line's changes back in History,
## switches mode by the bar, the Blame and File history actions, a deleting
## commit's message, the options, and the menus that offer Blame. On fixture `history` (see `file_history_smoke`).
## Read-only on the repository; the options go to the scratch config.
## Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const FILE: String = "src/login/auth.rs"
const OLD: String = "src/auth.rs"
## The subject of the commit each line of the working copy is blamed on
## ("" for the lines not committed yet).
const LINES: Array[String] = ["Add auth", "Add auth", "Move auth into login", "Add auth", "Add auth",
	"Handle empty passwords", "Handle empty passwords", "Handle empty passwords", "Add auth", "Check tokens",
	"Add auth", "Add auth", "Add auth", "Add auth", "Add auth", "Add auth", "Improve login", "Improve login",
	"Improve login", "Improve login", "", ""]


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("blame_smoke: no --fixtures, skipped")
		return
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(fixtures.path_join("history"))
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.is_ready()), "the repository opens")
	var worktree: WorktreeView = page.active_view()
	var view: FileView = worktree.file_view()
	var list: FileHistoryList = view.version_list()
	var blame: BlameView = view.blame_view()
	expect_eq(ActionRegistry.context_for(&"file_history.blame"), ActionRegistry.GLOBAL, "Blame works anywhere")
	expect_eq(ActionRegistry.context_for(&"blame.before"), &"File history", "its actions work in the view")
	for text: String in Actions.get_action(&"file_history.blame").default_shortcuts:
		expect(Actions.conflicts(&"file_history.blame", text).is_empty(), "default %s of Blame clashes" % text)
	expect(not Actions.is_enabled(&"blame.before"), "nothing to blame before without a blame")
	expect_eq(Actions.get_action(&"blame.before").reason.call(), tr("No blame is open."), "and it says why")
	Core.set_blame_ignore_whitespace(false)
	Core.set_blame_detect_moves(false)

	# From Changes: the working copy, the caret's line kept.
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	expect(await wait_until(func() -> bool: return session.change_count() == 2), "two changed files")
	expect(await _select_change(changes, session, FILE), "the edited file's diff loads")
	changes.list().context_menu_requested.emit(changes.list().cursor, Vector2(10, 10))
	expect(tr("File history") in changes.menu_labels() and not tr("Blame") in changes.menu_labels(),
			"the files' menu offers File history, not Blame: %s" % changes.menu_labels())
	changes.context_menu().hide()
	expect(Actions.run_action(&"file_history.blame"), "Blame runs")
	expect_eq(page.view, WorktreeView.View.FILE, "the File history view shows")
	expect(view.is_blame(), "with Blame on")
	expect(view.blame_button().button_pressed, "the bar's switch says so")
	expect(view.blame_button().tooltip_text.contains(Shortcuts.display("Ctrl+Alt+B")), "its tooltip names the shortcut")
	expect(await _blamed(session, view), "the blame loads")
	expect(await wait_until(func() -> bool:
		var history: Dictionary = session.file_history_info()
		return not bool(history.get("loading", true)) and list.row_count() == int(history["count"]) + 1),
			"and the versions")
	expect(list.is_working_row(list.cursor), "the uncommitted changes are selected")
	var info: Dictionary = session.blame_info()
	expect_eq(String(info["oid"]), "", "the working copy is blamed")
	expect_eq(String(info["path"]), FILE, "under its name")
	expect_eq(int(info["lines"]), LINES.size(), "every line of the file")
	expect_eq(int(info["blamed"]), LINES.size(), "each blamed")
	expect_eq(blame.row_count(), LINES.size(), "the view shows them")
	expect(blame.visible and not view.diff_panel().visible, "the blame replaces the diff")
	expect_eq(view.blame_version_text(), tr("Working copy"), "the strip names the version")
	expect_eq(view.blame_status_text(), "22 lines · 6 commits", "and counts lines and commits")
	expect(view.blame_message_text().is_empty(), "no message over the lines")
	expect(not view.details_header().visible, "no details without a focused commit")
	var rows: Array = session.blame_lines(0, LINES.size())
	for i: int in LINES.size():
		var row: Dictionary = rows[i]
		expect_eq(String(row.get("summary", "")) if not bool(row["working"]) else "", LINES[i], "line %d" % (i + 1))
		expect_eq(int(row["new"]), i + 1, "line %d's number" % (i + 1))
		expect_eq(bool(row["first"]), i == 0 or LINES[i] != LINES[i - 1], "line %d starts a run" % (i + 1))
	expect(bool(rows[20]["working"]) and is_equal_approx(float(rows[20]["age"]), 1.0), "the uncommitted lines are the newest")
	expect(is_zero_approx(float(rows[0]["age"])), "the first commit's are the oldest")
	expect_eq(String(rows[0]["text"]), "use std::time::Duration;", "the lines have their text")
	expect(not (rows[0]["syntax"] as PackedInt32Array).is_empty(), "and syntax colours")
	expect_eq(blame.gutter_texts(20)[0], tr("Not committed yet"), "the gutter says so")
	expect_eq(blame.gutter_texts(0)[0], "Fixture", "and names the author")
	expect(not blame.gutter_texts(0)[1].is_empty(), "with a date")
	expect(blame.get_tooltip(Vector2(20.0, 5.0)).begins_with("Add auth\nFixture · "),
			"the gutter's tooltip has the subject: %s" % blame.get_tooltip(Vector2(20.0, 5.0)))
	expect(view.left_pane().visible, "the versions stay beside the blame")

	# A click in the gutter focuses the line's commit.
	var tokens: String = _oid(list, "Check tokens")
	_click_gutter(blame, 9)
	expect(await wait_until(func() -> bool: return view.blame_focus() == tokens), "the clicked line's commit has the focus")
	expect(await wait_until(func() -> bool:
		return view.details_header().visible and view.details_header().commit_oid() == tokens),
			"its details show over the blame")
	expect_eq(list.marked, tokens, "its version is marked in the list")
	expect(list.is_working_row(list.cursor), "the selection stays on the blamed version")
	rows = session.blame_lines(0, LINES.size())
	for i: int in LINES.size():
		expect_eq(bool(rows[i]["focus"]), i == 9, "line %d's focus" % (i + 1))
	expect_eq(session.diff_change_row("blame", false, 0, true), 9, "the next change is the commit's line")
	expect_eq(view.target_commit(), tokens, "Copy commit hash would copy it")
	expect(Actions.is_enabled(&"file_history.copy_hash") and Actions.is_enabled(&"file_history.show_in_history"),
			"the commit's actions are on")
	blame.context_menu_requested.emit(9, Vector2(40.0, 190.0))
	for label: String in ["Blame before this commit", "Show changes", "Open in History", "Copy commit hash"]:
		expect(_menu_has(view.blame_menu(), tr(label)), "the blame's menu has %s" % label)
	view.blame_menu().hide()
	_click_gutter(blame, 9)
	expect(await wait_until(func() -> bool: return view.blame_focus().is_empty()), "a second click lets go of it")
	expect(not view.details_header().visible and list.marked.is_empty(), "the details and the mark go")

	# Uncommitted lines have no commit to show; before them is the last commit.
	blame.go_to_line(21)
	expect(not Actions.is_enabled(&"blame.show_changes"), "no changes to show for a line that is not committed")
	expect_eq(Actions.get_action(&"blame.show_changes").reason.call(), tr("This line is not committed yet."),
			"it says why")
	expect(view.target_commit().is_empty(), "nor a hash to copy")
	expect(Actions.run_action(&"blame.before"), "Blame before runs on an uncommitted line")
	var newest: String = _oid(list, "Improve login")
	expect(await wait_until(func() -> bool: return String(session.blame_info().get("oid", "")) == newest)
			and await _blamed(session, view), "the last commit's version is blamed")
	expect_eq(list.cursor, 1, "and selected")
	expect_eq(int(session.blame_info()["lines"]), 20, "without the uncommitted lines")
	expect_eq(blame.cursor, 19, "the caret stays as near the line as it can")

	# Blame before "Check tokens": the version before it, under the old name.
	# The focused commit has no line there, so the focus goes.
	_click_gutter(blame, 9)
	expect(await wait_until(func() -> bool: return view.blame_focus() == tokens), "the commit is focused again")
	expect(Actions.run_action(&"blame.before"), "Blame before this commit runs")
	var first: String = _oid(list, "Add auth")
	expect(await wait_until(func() -> bool:
		return String(list.version_at(list.cursor).get("oid", "")) == first), "the version before it is selected")
	expect(await wait_until(func() -> bool: return String(session.blame_info().get("oid", "")) == first)
			and await _blamed(session, view), "and blamed")
	info = session.blame_info()
	expect_eq(String(info["path"]), OLD, "under the name it had")
	expect_eq(int(info["lines"]), 12, "with the lines it had")
	expect_eq(view.blame_status_text(), "12 lines · 1 commit", "all by one commit")
	expect_eq(view.blame_version_text(), tr("As of %s") % ("%s  %s" % [first.left(7), "Add auth"]), "the strip names it")
	expect_eq(blame.cursor, 9, "the caret stays on the line")
	expect(await wait_until(func() -> bool: return view.blame_focus().is_empty() and not view.details_header().visible),
			"a version without the focused commit's lines lets go of it")
	expect(list.marked.is_empty(), "and of its mark")
	expect(not Actions.is_enabled(&"blame.before"), "the commit that added the file has nothing before it")
	expect_eq(Actions.get_action(&"blame.before").reason.call(), tr("This commit added the file."), "it says why")

	# Show changes: back to History on the line's commit.
	expect(Actions.run_action(&"blame.show_changes"), "Show changes runs")
	expect(not view.is_blame() and view.diff_panel().visible and not blame.is_visible_in_tree(), "the diff shows, Blame off")
	expect_eq(String(view.current_version().get("oid", "")), first, "on the line's commit")
	expect(not bool(session.blame_info().get("open", true)), "the blame is closed")
	expect(await _diff_ready(session, OLD), "its diff loads")

	# The bar's switch, and the same version blamed again.
	expect(not view.blame_button().button_pressed, "the bar's switch is off")
	view.blame_button().button_pressed = true
	expect(view.is_blame() and await _blamed(session, view), "the bar's Blame blames the selected version")
	expect_eq(String(session.blame_info()["oid"]), first, "the one selected")
	list.select_only(1)
	expect(await wait_until(func() -> bool: return String(session.blame_info().get("oid", "")) == newest)
			and await _blamed(session, view), "selecting a version blames it")

	# The options run the blame again and are saved.
	view.blame_options_button().pressed.emit()
	expect(view.blame_options_menu().visible, "the options open")
	expect(_menu_has(view.blame_options_menu(), tr("Ignore whitespace")) and _menu_has(view.blame_options_menu(),
			tr("Detect moved lines")), "with both options")
	view.blame_options_menu().hide()
	expect(Actions.run_action(&"blame.toggle_ignore_whitespace"), "Ignore whitespace runs")
	expect(Core.blame_ignore_whitespace(), "and is saved")
	expect(await _blamed(session, view), "the blame runs again")
	Actions.run_action(&"blame.toggle_detect_moves")
	expect(Core.blame_detect_moves() and await _blamed(session, view), "Detect moved lines too")
	Actions.run_action(&"blame.toggle_ignore_whitespace")
	Actions.run_action(&"blame.toggle_detect_moves")
	expect(not Core.blame_ignore_whitespace() and not Core.blame_detect_moves(), "both off again")
	expect(await _blamed(session, view), "and blamed again")

	expect(view.left_pane().visible, "the versions stay beside the blame")
	expect(blame.gutter_width() > 0.0 and blame.gutter_width() < blame.size.x * 0.5,
			"the gutter leaves room for the lines")

	# File history on the same file leaves Blame as it is; the action and
	# the switch turn it off and on.
	expect(Actions.run_action(&"file_history.open"), "File history runs while blaming")
	expect(view.is_blame() and view.shown_path() == FILE, "the same history, Blame still on")
	expect(Actions.run_action(&"file_history.blame"), "Blame runs in the view")
	expect(not view.is_blame() and not view.blame_button().button_pressed and view.diff_panel().visible,
			"and turns Blame off")
	expect(not bool(session.blame_info().get("open", true)), "the blame is closed")
	expect(Actions.run_action(&"file_history.blame"), "Blame runs again")
	expect(view.is_blame() and view.blame_button().button_pressed and await _blamed(session, view),
			"and blames the selected version")
	view.blame_button().button_pressed = false
	expect(not view.is_blame() and view.diff_panel().visible, "the switch turns it off")
	view.blame_button().button_pressed = true
	expect(view.is_blame() and await _blamed(session, view), "and on")
	view.version_list().context_menu_requested.emit(view.version_list().cursor, Vector2(10, 10))
	expect(not _menu_has(view.version_menu(), tr("Blame")), "a version's menu has no Blame")
	view.version_menu().hide()

	# A commit that deleted the file has nothing to blame.
	worktree.open_file_history("gone.txt", "", "", true)
	expect(await wait_until(func() -> bool:
		return view.shown_path() == "gone.txt" and list.row_count() == 2 and list.cursor == 0), "a deleted file's history")
	expect(await wait_until(func() -> bool: return view.blame_message_text() == tr("This commit deleted the file.")),
			"the deleting commit says so: %s" % view.blame_message_text())
	expect(not blame.visible, "without lines")
	list.select_only(1)
	expect(await wait_until(func() -> bool: return int(session.blame_info().get("lines", 0)) == 1)
			and await _blamed(session, view), "the commit that added it is blamed")
	expect(view.blame_message_text().is_empty() and blame.visible, "with its line")

	# Closing ends the blame.
	Actions.run_action(&"file_history.close")
	expect(not bool(session.blame_info().get("open", true)), "closing the history closes the blame")
	expect(not view.is_blame(), "and the next history starts in History mode")

	for index: int in main.tab_bar().tab_count:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


## The blame ended and the view shows all of its lines.
func _blamed(session: RepoSession, view: FileView) -> bool:
	await get_tree().process_frame
	return await wait_until(func() -> bool:
		var info: Dictionary = session.blame_info()
		return bool(info.get("open", false)) and String(info.get("state", "")) == "done" \
				and view.blame_view().visible and view.blame_view().row_count() == int(info["lines"]) \
				and not view.blame_status_text().is_empty() and not view.blame_status_text().begins_with(tr("Blaming")))


func _diff_ready(session: RepoSession, path: String) -> bool:
	return await wait_until(func() -> bool:
		var info: Dictionary = session.slot_diff_info("file")
		return String(info.get("state", "")) == "ready" and String(info.get("path", "")) == path)


func _select_change(changes: ChangesView, session: RepoSession, path: String) -> bool:
	var index: int = -1
	for row: int in changes.list().row_count():
		if changes.list().path_at(row) == path:
			index = row
	if index < 0:
		return false
	changes.list().select_only(index)
	return await wait_until(func() -> bool:
		var info: Dictionary = session.diff_info()
		return String(info.get("path", "")) == path and String(info.get("state", "")) == "ready")


func _oid(list: FileHistoryList, subject: String) -> String:
	for row: int in list.row_count():
		if String(list.version_at(row).get("subject", "")) == subject:
			return String(list.version_at(row)["oid"])
	return ""


func _click_gutter(blame: BlameView, row: int) -> void:
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(20.0, blame.row_top(row) + blame.row_height() * 0.5 - blame.scroll_offset())
	blame._gui_input(click)


func _menu_has(menu: PopupMenu, label: String) -> bool:
	for i: int in menu.item_count:
		if menu.get_item_text(i) == label:
			return true
	return false
