extends SmokeTest
## M8a: File history. Opens the history of a renamed file from Changes
## (the uncommitted changes first, then every commit under both names, the
## side branch's among them), checks the bar, the rows' chips and counts, a
## version's details and diff, the rename's diff header, the version menu,
## Open, Restore with Undo, two versions into Compare (filtered to the
## file), Open in History, the tab and its ×; the uncommitted row's counts,
## the filter (text, hash, no match, Find), the Compact rows option and the
## switch's Alt+number shortcuts. Then from History's
## file list (a fixed start: "as of …", a deleted file's history, no
## reload), from Compare's files, and a commit on another branch shown in
## History (All branches). On fixture `history`: `src/login/auth.rs` was
## `src/auth.rs`, edited on `side` under that name; `gone.txt` was added and
## deleted; `topic` has one more commit; the file is edited locally. It
## restores (then undoes) the file. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const FILE: String = "src/login/auth.rs"
const OLD: String = "src/auth.rs"
const SUBJECTS: Array[String] = ["Improve login", "Merge side", "Handle empty passwords", "Move auth into login",
	"Check tokens", "Add auth"]

## Lines the fixture's local edit adds and removes.
const WORKING_LINES: Array[int] = [2, 0]

var _opened: PackedStringArray = PackedStringArray()


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("file_history_smoke: no --fixtures, skipped")
		return
	var opener: Callable = RepoOps.opener
	RepoOps.opener = func(opened: String) -> Error:
		_opened.append(opened)
		return OK
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var repo: String = fixtures.path_join("history")
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.is_ready()), "the repository opens")
	var worktree: WorktreeView = page.active_view()
	var view: FileView = worktree.file_view()
	var list: FileHistoryList = view.version_list()
	expect(not worktree.file_history_button().visible, "no File history tab without a history")
	expect(not Actions.is_enabled(&"view.file_history"), "View → File history is disabled without one")
	expect_eq(ActionRegistry.context_for(&"file_history.restore"), &"File history", "version actions work in the view")
	expect_eq(ActionRegistry.context_for(&"file_history.open"), ActionRegistry.GLOBAL, "opening a history works anywhere")
	expect(ActionRegistry.contexts_overlap(&"Diff", &"File history"), "the diff shows inside File history")
	for action: ActionRegistry.Action in Actions.with_shortcuts():
		if String(action.id).begins_with("file_history.") or action.id == &"view.file_history":
			for text: String in action.default_shortcuts:
				expect(Actions.conflicts(action.id, text).is_empty(), "default %s of %s clashes" % [text, action.id])

	# From Changes: the highlighted file, read from HEAD.
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	expect(await wait_until(func() -> bool: return session.change_count() == 2), "two changed files")
	expect(await _select_change(changes, session, FILE), "the edited file's diff loads")
	changes.list().context_menu_requested.emit(changes.list().cursor, Vector2(10, 10))
	expect(tr("File history") in changes.menu_labels(), "the files' menu offers it: %s" % changes.menu_labels())
	changes.context_menu().hide()
	expect(Actions.run_action(&"file_history.open"), "File history runs")
	expect_eq(page.view, WorktreeView.View.FILE, "the File history view shows")
	expect(worktree.file_history_button().visible and worktree.file_history_button().button_pressed,
			"its tab shows, pressed")
	expect(await _loaded(session, view), "the history loads")
	var info: Dictionary = session.file_history_info()
	expect_eq(int(info["count"]), 6, "six commits changed the file")
	expect(bool(info["has_working"]), "and it has uncommitted changes")
	expect_eq(Array(info["names"] as PackedStringArray), [FILE, OLD], "both names are known")
	expect_eq(view.path_label().path, FILE, "the bar names the file")
	expect(view.path_label().tooltip_text.contains(OLD), "its tooltip has the old name: %s" % view.path_label().tooltip_text)
	expect(view.filter_count_text().is_empty(), "no count without a filter")
	expect(view.blame_button().visible and not view.blame_button().button_pressed, "the bar's Blame switch is off")
	expect(view.start_text().is_empty(), "no start chip for a history read from HEAD")
	expect_eq(list.row_count(), 7, "the uncommitted changes and six commits")
	expect(list.is_working_row(0), "the uncommitted changes come first")
	for i: int in SUBJECTS.size():
		expect_eq(String(list.version_at(i + 1).get("subject", "")), SUBJECTS[i], "row %d" % (i + 1))

	# The first row is selected: the working copy against HEAD, no details.
	expect(await wait_until(func() -> bool: return list.cursor == 0), "the first row is selected")
	expect(await _diff_ready(session, FILE), "the uncommitted changes' diff loads")
	expect(await wait_until(func() -> bool: return view.diff_panel().view().row_count() > 0), "and shows")
	expect(not view.details_header().visible, "no commit details for the uncommitted changes")
	expect(not Actions.is_enabled(&"file_history.restore"), "nothing to restore from your own files")
	expect_eq(Actions.get_action(&"file_history.restore").reason.call(), tr("These are already your files."),
			"and it says why")
	# Its row says what the edit is: the lines, counted after the status.
	expect(await wait_until(func() -> bool:
		return int((session.file_history_info()["working"] as Dictionary).get("additions", -1)) >= 0),
			"the uncommitted lines are counted")
	var working: Dictionary = session.file_history_info()["working"]
	expect_eq(String(working["code"]), "M", "the file is modified")
	expect_eq([int(working["additions"]), int(working["deletions"])], WORKING_LINES, "its added and removed lines")
	expect(await wait_until(func() -> bool:
		return list.marks_text(0) == tr("%d lines added, %d removed") % WORKING_LINES),
			"the row's marks say so: %s" % list.marks_text(0))
	expect_eq(String(list.row_data(0).get("subject", "x")), "", "the row has one line, no second text")

	# The third button of the switch is the third view: Alt+3 here.
	expect_eq(Actions.shortcut_label(&"view.file_history"), "Alt+3", "File history is third in the switch")
	expect(worktree.file_history_button().tooltip_text.contains("Alt+3"),
			"its tooltip says so: %s" % worktree.file_history_button().tooltip_text)
	press("Alt+1")
	expect_eq(page.view, WorktreeView.View.CHANGES, "Alt+1 shows Changes")
	press("Alt+3")
	expect_eq(page.view, WorktreeView.View.FILE, "Alt+3 shows the file's history")
	press("Alt+PageUp")
	expect_eq(page.view, WorktreeView.View.HISTORY, "Alt+PageUp goes to the view before")
	press("Alt+PageDown")
	expect_eq(page.view, WorktreeView.View.FILE, "Alt+PageDown comes back")

	# A commit: its details, its counts and its diff of the file.
	list.select_only(1)
	expect(await _diff_ready(session, FILE), "Improve login's diff loads")
	expect(view.details_header().visible, "its details show")
	expect_eq(view.details_header().summary_text(), "Improve login", "with its summary")
	expect(await wait_until(func() -> bool: return view.details_header().has_body()), "and its message once read")
	expect(view.details_header().body_text().contains("Hash passwords"), "the body: %s" % view.details_header().body_text())
	expect_eq(view.details_header().people().size(), 2, "the author and the co-author")
	var improve: Dictionary = list.version_at(1)
	expect_eq(int(improve["additions"]), 4, "four lines added")
	expect_eq(String(improve["code"]), "M", "a modification has no chip")
	expect(list.marks_text(1).contains("4"), "the marks' tooltip counts: %s" % list.marks_text(1))
	await get_tree().process_frame
	expect(list.rows_drawn > 0, "rows are drawn")

	# The rename: its chip, both names, a diff from the old name.
	var rename: int = list.row_of(String(_oid(list, "Move auth into login")))
	expect_eq(rename, 4, "the rename's row")
	list.select_only(rename)
	expect(await _diff_ready(session, FILE), "the rename's diff loads")
	var renamed_version: Dictionary = list.version_at(rename)
	expect_eq(String(renamed_version["code"]), "R", "it is a rename")
	expect_eq(String(renamed_version["original_path"]), OLD, "from the old name")
	expect(list.marks_text(rename).contains(OLD), "the chip's tooltip names it: %s" % list.marks_text(rename))
	expect_eq(String(session.slot_diff_info("file").get("original_path", "")), OLD, "the diff reads old → new")
	var side: int = list.row_of(String(_oid(list, "Handle empty passwords")))
	expect_eq(String(list.version_at(side)["path"]), OLD, "the side branch's commit knew the file by its old name")
	var added: Dictionary = list.version_at(list.row_of(String(_oid(list, "Add auth"))))
	expect_eq(String(added["code"]), "A", "the first commit added it")
	expect_eq(int(added["additions"]), 12, "with twelve lines")

	# The filter: only the commits it matches, the uncommitted changes left out.
	var filter: FilterField = view.filter_field()
	press("Ctrl+F")
	expect(filter.text_box().has_focus(), "Find focuses the filter")
	filter.set_text("login")
	expect(await _filtered(session, view, 2), "two commits mention login")
	expect_eq(view.filter_count_text(), "2", "the field counts the matches")
	expect(not list.is_working_row(0), "the uncommitted changes are left out")
	expect_eq([String(list.version_at(0)["subject"]), String(list.version_at(1)["subject"])],
			["Improve login", "Move auth into login"], "the matches, newest first")
	expect_eq(list.cursor, 1, "the selected version stays selected")
	expect(not list.match_strip().visible, "no strip of matches: only they are listed")
	filter.set_text(String(added["oid"]).left(7))
	expect(await _filtered(session, view, 1), "a hash finds its commit")
	expect_eq(String(list.version_at(0)["subject"]), "Add auth", "the first commit")
	expect(await wait_until(func() -> bool: return list.cursor == 0), "which is selected")
	filter.set_text("no such words")
	expect(await _filtered(session, view, 0), "nothing matches")
	expect_eq(view.message_text(), tr("No matches"), "it says so: %s" % view.message_text())
	expect_eq(view.filter_count_text(), tr("No matches"), "and the field")
	filter.set_text("")
	expect(await _loaded(session, view), "without the filter every version is back")
	expect_eq(list.row_count(), 7, "the uncommitted changes too")
	expect(view.filter_count_text().is_empty(), "and the count is gone")

	# The field's options: the rows, History's setting.
	var options: OptionsPopover = view.options_popover()
	view.options_button().pressed.emit()
	expect(options.visible, "the options open")
	expect_eq(options.ids(), PackedStringArray(["rows"]), "with the rows choice")
	expect_eq(options.value("rows"), "detailed", "on Detailed")
	(options.control("rows") as SegmentedControl).choice_button("compact").pressed.emit()
	options.hide()
	expect(list.compact and Core.history_compact(), "Compact switches to one-line rows, for History too")
	Actions.run_action(&"history.detailed_rows")
	expect(not list.compact and options.value("rows") == "detailed", "and back, the choice following")
	list.select_only(rename)
	expect(await _diff_ready(session, FILE), "the rename's diff shows again")

	# The version menu and Open.
	list.context_menu_requested.emit(rename, Vector2(10, 10))
	expect(view.version_menu().visible, "a version's menu opens")
	for label: String in ["Compare versions", "Restore version", "Open version",
			"Open in History", "Copy commit hash"]:
		expect(_menu_has(view.version_menu(), tr(label)), "the menu has %s" % label)
	expect(_menu_disabled(view.version_menu(), tr("Compare versions")), "Compare needs two versions")
	view.version_menu().hide()
	var before: int = _opened.size()
	expect(Actions.run_action(&"file_history.open_version"), "Open version runs")
	expect(await wait_until(func() -> bool: return _opened.size() > before), "it opens a file")
	expect(_opened[-1].get_file() == "auth.rs" and not _same(_opened[-1], repo.path_join(FILE)),
			"a copy of that version, not the working file: %s" % _opened[-1])
	view.diff_panel().view().context_menu_requested.emit(0, Vector2(10, 10))
	expect(_menu_has(view.diff_menu(), tr("Open")), "the diff's menu has Open")
	view.diff_menu().hide()

	# Restore a version from before the rename into the current name; Undo.
	var path: String = repo.path_join(FILE)
	var edited: String = read_file(path)
	var check: int = list.row_of(String(_oid(list, "Check tokens")))
	list.select_only(check)
	expect(await _diff_ready(session, OLD), "Check tokens' diff loads, under the old name")
	expect(Actions.is_enabled(&"file_history.restore"), "Restore version is offered")
	Actions.run_action(&"file_history.restore")
	expect(await wait_until(func() -> bool:
		var text: String = read_file(path)
		return text != edited and text.contains("check_token") and not text.contains("from_secs(60)")),
			"the file is that version again, under its current name")
	expect(not FileAccess.file_exists(repo.path_join(OLD)), "the old name stays gone")
	expect(await wait_until(func() -> bool: return session.can_undo_discard()), "the restore can be undone")
	session.undo_discard()
	expect(await wait_until(func() -> bool: return read_file(path) == edited), "Undo brings the edit back")
	expect_eq(String(list.version_at(list.cursor).get("subject", "")), "Check tokens", "the selection stays")

	# Two versions open in Compare, the older on the left, filtered to the file.
	list.select_only(1)
	_ctrl_click(list, check)
	expect_eq(list.selected_rows().size(), 2, "Ctrl+click selects a second version")
	expect(Actions.is_enabled(&"file_history.compare_versions"), "Compare versions is offered")
	expect(not Actions.is_enabled(&"file_history.restore"), "Restore needs one version")
	var newer: String = String(list.version_at(1)["oid"])
	var older: String = String(list.version_at(check)["oid"])
	Actions.run_action(&"file_history.compare_versions")
	expect_eq(page.view, WorktreeView.View.COMPARE, "Compare shows")
	var compare: CompareView = worktree.compare()
	expect_eq(String(compare.shown_request().get("left", "")), older, "the older version is on the left")
	expect_eq(String(compare.shown_request().get("right", "")), newer, "the newer on the right")
	expect(await _compared(session), "the two versions compare")
	expect_eq(String(session.compare_info()["mode"]), "exact", "as a full difference")
	expect_eq(compare.filter_field().text(), "\"%s\"" % FILE, "the filter has the file's exact path")
	expect(await wait_until(func() -> bool: return compare.current_file() == FILE), "and the file is selected")
	expect_eq(compare.file_list().row_count(), 1, "alone in the list")
	expect(worktree.file_history_button().visible, "the File history tab stays")
	expect_eq([Actions.shortcut_label(&"view.compare"), Actions.shortcut_label(&"view.file_history")],
			["Alt+3", "Alt+4"], "Compare took the third place, File history the fourth")
	press("Alt+4")
	expect_eq(page.view, WorktreeView.View.FILE, "Alt+4 is the file's history now")
	press("Alt+3")
	expect_eq(page.view, WorktreeView.View.COMPARE, "and Alt+3 the comparison")
	compare.file_list().context_menu_requested.emit(0, Vector2(10, 10))
	expect(_menu_has(compare.file_menu(), tr("File history")), "Compare's file menu offers the history")
	compare.file_menu().hide()
	Actions.run_action(&"compare.close")
	expect_eq(page.view, WorktreeView.View.FILE, "closing Compare returns to the file's history")
	expect_eq(int(session.file_history_info()["count"]), 6, "which is as it was")

	# Open in History.
	list.select_only(check)
	expect(Actions.is_enabled(&"file_history.show_in_history"), "Open in History is offered")
	Actions.run_action(&"file_history.show_in_history")
	expect_eq(page.view, WorktreeView.View.HISTORY, "History shows")
	var history: HistoryView = page.history()
	expect(await wait_until(func() -> bool: return history.selected_commit().get("hash", "") == older),
			"with the commit selected")
	expect(Actions.is_enabled(&"view.file_history"), "View → File history is enabled now")
	Actions.run_action(&"view.file_history")
	expect_eq(page.view, WorktreeView.View.FILE, "View → File history returns to the file's history")

	# The tab's ×: back to the view the history was opened from.
	worktree.file_history_close_button().pressed.emit()
	expect(not view.has_history(), "the × closes the history")
	expect(not worktree.file_history_button().visible, "its tab goes")
	expect_eq(page.view, WorktreeView.View.CHANGES, "back in Changes, where it was opened")
	expect(not bool(session.file_history_info()["open"]), "the session closed it too")

	# From History's file list: read from that commit ("as of …").
	page.show_view(WorktreeView.View.HISTORY)
	var removal: int = -1
	expect(await wait_until(func() -> bool: return history.commit_list().row_count() >= 8), "History lists the commits")
	for row: int in history.commit_list().row_count():
		if String(history.commit_list().row_data(row).get("subject", "")) == "Add a scratch file":
			removal = row
	expect(removal >= 0, "History has the commit that added gone.txt")
	history.commit_list().select_only(removal)
	var details: CommitDetails = history.details()
	expect(await wait_until(func() -> bool: return details.file_list().path_at(details.file_list().cursor) == "gone.txt"),
			"its file is selected")
	details.file_list().context_menu_requested.emit(0, Vector2(10, 10))
	expect(_menu_has(details.file_menu(), tr("File history")), "History's file menu offers the history")
	details.file_menu().hide()
	Actions.run_action(&"file_history.open")
	expect_eq(page.view, WorktreeView.View.FILE, "the File history view shows")
	expect(await _loaded(session, view), "gone.txt's history loads")
	expect_eq(int(session.file_history_info()["count"]), 1, "as of that commit: only its addition")
	expect(not bool(session.file_history_info()["has_working"]), "a fixed start has no uncommitted changes")
	expect(view.start_text().contains("Add a scratch file"), "the bar says where it starts: %s" % view.start_text())
	expect_eq(String(list.version_at(0)["code"]), "A", "the row is the addition")
	Actions.run_action(&"file_history.close")
	expect_eq(page.view, WorktreeView.View.HISTORY, "closing returns to History")

	# A deleted file's history, read from HEAD: the deletion cannot be restored.
	worktree.open_file_history("gone.txt")
	expect(await _loaded(session, view), "gone.txt's history from HEAD loads")
	expect_eq(int(session.file_history_info()["count"]), 2, "its deletion and its addition")
	expect(await wait_until(func() -> bool: return list.cursor == 0), "the deletion is selected")
	expect_eq(String(list.version_at(0)["code"]), "D", "the newest commit deleted it")
	expect(not Actions.is_enabled(&"file_history.restore"), "a deletion has no version to restore")
	expect_eq(Actions.get_action(&"file_history.restore").reason.call(), tr("This commit deleted the file."),
			"and it says why")
	list.select_only(1)
	expect(Actions.is_enabled(&"file_history.restore"), "the addition can be restored")

	# A new history starts without the last one's filter.
	filter.set_text("scratch")
	expect(await _filtered(session, view, 2), "both commits match")

	# A file nobody committed: only its message.
	worktree.open_file_history("no such file.txt")
	expect(await _loaded(session, view), "an unknown file's history loads")
	expect_eq(view.message_text(), tr("No commits for this file"), "it says so: %s" % view.message_text())
	expect_eq(list.row_count(), 0, "no rows")
	expect(filter.text().is_empty(), "and no filter left from the last history")

	# A history read from another branch: its commit shows in History once
	# all branches are listed.
	worktree.open_file_history(FILE, "topic", "topic")
	expect(await _loaded(session, view), "the history as of topic loads")
	expect_eq(int(session.file_history_info()["count"]), 7, "topic's commit and the six")
	expect_eq(view.start_text(), tr("as of %s") % "topic", "the bar names topic")
	expect(await wait_until(func() -> bool: return list.cursor == 0), "topic's commit is selected")
	var topic_oid: String = String(list.version_at(0)["oid"])
	expect_eq(String(list.version_at(0)["subject"]), "Try a longer timeout", "it is topic's commit")
	expect(not bool(session.history_info().get("all_branches", false)), "History lists the current branch")
	Actions.run_action(&"file_history.show_in_history")
	expect_eq(page.view, WorktreeView.View.HISTORY, "History shows")
	expect(await wait_until(func() -> bool: return bool(session.history_info().get("all_branches", false))),
			"it switches to all branches")
	expect(await wait_until(func() -> bool: return history.selected_commit().get("hash", "") == topic_oid),
			"and selects topic's commit")
	history.set_all_branches(false)

	# From Compare's files: read from the right side.
	worktree.open_compare("side", "topic", false)
	expect(await _compared(session), "side ⇄ topic compares")
	expect(await wait_until(func() -> bool: return not compare.current_file().is_empty()), "a file is selected")
	var target: Dictionary = worktree.file_history_target()
	expect_eq(String(target.get("start", "")), topic_oid, "the history would be read from topic's commit")
	expect_eq(String(target.get("start_name", "")), "topic", "called topic")
	Actions.run_action(&"compare.close")
	Actions.run_action(&"file_history.close")

	RepoOps.opener = opener
	for index: int in main.tab_bar().tab_count:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


## The history ended loading and the view shows it (the view follows the
## session's signal, a frame after the session knows).
func _loaded(session: RepoSession, view: FileView) -> bool:
	await get_tree().process_frame
	return await wait_until(func() -> bool:
		var info: Dictionary = session.file_history_info()
		return bool(info.get("open", false)) and not bool(info.get("loading", true)) \
				and not view.is_loading() \
				and view.version_list().row_count() == int(info["count"]) + (1 if bool(info["has_working"]) else 0))


## The filter's `count` matches are listed (and nothing else).
func _filtered(session: RepoSession, view: FileView, count: int) -> bool:
	await get_tree().process_frame
	return await wait_until(func() -> bool:
		var info: Dictionary = session.file_history_info()
		return not bool(info.get("loading", true)) and not String(info.get("filter", "")).is_empty() \
				and int(info["count"]) == count and view.version_list().row_count() == count)


func _diff_ready(session: RepoSession, path: String) -> bool:
	return await wait_until(func() -> bool:
		var info: Dictionary = session.slot_diff_info("file")
		return String(info.get("state", "")) == "ready" and String(info.get("path", "")) == path)


func _compared(session: RepoSession) -> bool:
	await get_tree().process_frame
	return await wait_until(func() -> bool:
		var info: Dictionary = session.compare_info()
		return String(info.get("state", "")) == "ready" and not bool(info.get("reloading", false)))


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


## The commit whose subject is `subject`, or "".
func _oid(list: FileHistoryList, subject: String) -> String:
	for row: int in list.row_count():
		if String(list.version_at(row).get("subject", "")) == subject:
			return String(list.version_at(row)["oid"])
	return ""


func _ctrl_click(list: FileHistoryList, row: int) -> void:
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.ctrl_pressed = true
	click.position = Vector2(20.0, list.row_top(row) + list.row_extent(row) * 0.5 - list.scroll_offset())
	list._gui_input(click)


func _same(a: String, b: String) -> bool:
	return a.replace("\\", "/").to_lower() == b.replace("\\", "/").to_lower()


func _menu_has(menu: PopupMenu, label: String) -> bool:
	for i: int in menu.item_count:
		if menu.get_item_text(i) == label:
			return true
	return false


func _menu_disabled(menu: PopupMenu, label: String) -> bool:
	for i: int in menu.item_count:
		if menu.get_item_text(i) == label:
			return menu.is_item_disabled(i)
	return false
