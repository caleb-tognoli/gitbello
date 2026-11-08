extends SmokeTest
## M4b: selecting a commit in the history shows its details, files and the
## first file's diff; Right and Left move between list, files and diff. The
## files sit beside the diff, the layout buttons work like radio buttons and
## the details' sizes are saved.
## Parent navigation merges the fixture's local remote into `repo-5`.
## Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("history_smoke: no --fixtures, skipped")
		return
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(fixtures.path_join("repo-5"))
	var history: HistoryView = page.history()
	var list: CommitList = history.commit_list()
	expect(await wait_until(func() -> bool: return list.row_count() == 3), "three commits")
	var details: CommitDetails = history.details()
	expect(await wait_until(func() -> bool: return list.cursor == 0),
			"the newest commit is selected by default: %d" % list.cursor)
	expect(await wait_until(func() -> bool: return details.summary_text() == "Improve app"),
			"details show the newest commit: %s" % details.summary_text())
	list.grab_focus()
	var diff: DiffView = details.diff_panel().view()
	expect(await wait_until(_diff_has.bind(diff, "v2")), "first file's diff is shown")
	expect_eq(history.status_text(), "", "the search field counts nothing without a search")
	expect(history.find_child("ListHeader", true, false) == null, "there is no header row above the list")
	expect_eq(history.empty_text(), "", "a loaded history has no empty text")
	expect_eq(details.files_header().text(), "1 changed file", "the files header counts the files")
	expect_eq(ListHeader.count_text(12345, "commit"), "12,345 commits", "counts have thousands separators")
	expect_eq(ListHeader.number_text(1234567), "1,234,567", "numbers have thousands separators")
	var first_code: String = String(details.file_list().row(0).get("code", ""))
	expect(not first_code.is_empty(), "the first file has a status code")
	expect_eq(details.diff_panel().status_code(), first_code, "the diff header shows the file's status icon")
	expect_eq(details.diff_panel().path_text(), details.file_list().path_at(0), "the header shows the path")
	expect_eq(Core.rename_parts("src/util.rs", "lib/util.rs"), PackedStringArray(["", "src", "lib", "/util.rs"]),
			"a move shares the file name")
	expect_eq(FileRowPainter.path_lead("src/ui/a.rs", ""), PackedStringArray(["src/ui", "/"]), "the folder leads the name")
	expect_eq(FileRowPainter.path_lead("a.rs", ""), PackedStringArray(["", ""]), "a top-level file has no folder")
	expect_eq(FileRowPainter.path_lead("docs/b.md", "docs/a.md"), PackedStringArray(["docs/a.md", " → "]), "a rename")
	expect_eq(FileRowPainter.path_lead("lib/u.rs", "src/u.rs"), PackedStringArray(["{src → lib}", "/"]), "a move")
	expect(details.body_text().is_empty(), "a one-line message has no body")
	expect(details.collapsed, "without a body the details shrink to fit")
	expect(details.totals_text().begins_with("+"), "the files section shows the commit's totals: %s" % details.totals_text())
	expect(details.diff_panel().counts_text().begins_with("+"),
			"the diff header shows the file's counts: %s" % details.diff_panel().counts_text())
	await get_tree().process_frame
	var files_rect: Rect2 = details.file_list().get_global_rect()
	var diff_rect: Rect2 = diff.get_global_rect()
	expect(files_rect.end.x <= diff_rect.position.x and files_rect.position.y < diff_rect.end.y,
			"the files are beside the diff: %s %s" % [files_rect, diff_rect])

	# Ctrl+Shift+D switches every diff to side by side (and back).
	press("Ctrl+Shift+D")
	expect(diff.side_by_side, "Ctrl+Shift+D shows the diff side by side")
	expect_eq(Core.diff_mode("text"), "split", "the layout is saved")
	var row: Dictionary = diff.row_data(1)
	expect(String(row.get("left", {}).get("text", "")) == "v1" and String(row.get("right", {}).get("text", "")) == "v2",
			"v1 and v2 share a side-by-side row: %s" % [row])
	# `v1` -> `v2` changes the line's only word: no word highlight on top.
	expect(Array(row["right"]["hl"]).is_empty(), "a whole-line change has no word highlight: %s" % [row["right"]["hl"]])
	press("Ctrl+Shift+D")
	expect(not diff.side_by_side and Core.diff_mode("text") == "unified", "Ctrl+Shift+D switches back")

	# Unified and Side by side are one choice.
	var unified: Button = details.diff_panel().mode_button("unified")
	var split: Button = details.diff_panel().mode_button("split")
	expect(unified.button_pressed and not split.button_pressed, "Unified is the chosen layout")
	split.button_pressed = true
	split.pressed.emit()
	expect(diff.side_by_side and Core.diff_mode("text") == "split", "Side by side switches the layout")
	expect(not unified.button_pressed, "and Unified is no longer chosen")
	unified.button_pressed = true
	unified.pressed.emit()
	expect(not diff.side_by_side and not split.button_pressed, "Unified switches back")
	unified.pressed.emit()
	expect(not diff.side_by_side, "pressing the chosen layout again keeps it")

	# The details' height and the files' width are saved per repository.
	details.split_offset = 240
	details.drag_ended.emit()
	details.files_split().split_offset = 260
	details.files_split().drag_ended.emit()
	var saved: Dictionary = Core.repo_ui_state(page.key())
	expect_eq(int(saved.get("details_height", 0)), 240, "the details height is saved")
	expect_eq(int(saved.get("details_files_width", 0)), 260, "the files width is saved")

	press("Down")
	expect(await wait_until(func() -> bool: return details.summary_text() == "Add app"),
			"Down shows the next commit: %s" % details.summary_text())

	press("Right")
	expect(details.file_list().has_focus(), "Right moves into the files")
	expect(await wait_until(func() -> bool: return diff.row_count() > 0), "its diff loads")
	press("Right")
	expect(diff.has_focus(), "Right again moves into the diff")
	press("Left")
	expect(details.file_list().has_focus(), "Left goes back to the files")
	press("Left")
	expect(list.has_focus(), "Left again goes back to the commits")

	await _check_search(page.session, list)
	await _check_search_ui(history, list, details)
	await _check_parents(page)
	await _check_merge_parents(page)
	await _check_parent_links(main, page)
	await _check_pending_parents(page)

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


## The history search bindings (P5): "app" matches the two newest of
## "Improve app", "Add app", "Initial commit".
func _check_search(session: RepoSession, list: CommitList) -> void:
	var signals: Array[int] = [0]
	var count: Callable = func() -> void: signals[0] += 1
	session.search_changed.connect(count)
	expect(session.search_info().is_empty(), "no search to start with")
	session.search_commits("APP")
	expect(await wait_until(func() -> bool: return bool(session.search_info().get("done", false))),
			"the search finishes: %s" % [session.search_info()])
	expect(signals[0] > 0, "search_changed is emitted")
	var info: Dictionary = session.search_info()
	expect_eq(int(info["matches"]), 2, "two subjects contain app")
	expect_eq(int(info["searched"]), 3, "every row is searched")
	expect_eq(String(info["query"]), "APP", "the query is kept as typed")
	var flags: Array[bool] = []
	for row: Dictionary in session.graph_rows(0, 3):
		flags.append(bool(row["match"]))
	expect_eq(flags, [true, true, false] as Array[bool], "graph rows carry the match flag")
	expect_eq(session.next_match(0, true), 1, "next match")
	expect_eq(session.next_match(1, true), 0, "the next match wraps to the top")
	expect_eq(session.next_match(0, false), 1, "the previous match wraps to the bottom")
	expect_eq(session.next_match(2, false), 1, "from a row that is not a match")
	expect_eq(session.search_match_index(1), 1, "row 1 is the second match")
	expect_eq(session.search_match_index(2), -1, "row 2 is no match")
	expect_eq(session.search_overview(6), PackedByteArray([1, 1, 1, 1, 0, 0]),
			"the overview marks the top two of three rows")
	var oid: String = list.hash_at(2)
	session.search_commits(oid.left(7))
	expect(await wait_until(func() -> bool: return bool(session.search_info().get("done", false))),
			"the hash search finishes")
	expect_eq(session.next_match(0, true), 2, "a hash prefix finds its commit")
	session.search_commits("zzz-none")
	expect(await wait_until(func() -> bool: return bool(session.search_info().get("done", false))),
			"a search without matches finishes")
	expect_eq(session.next_match(0, true), -1, "no match to go to")
	session.search_commits("")
	expect(await wait_until(func() -> bool: return session.search_info().is_empty()), "a blank query ends the search")
	session.search_changed.disconnect(count)


## The search field over the list: the first match is selected, Enter,
## Shift+Enter and F3 step, the header counts, other rows are dimmed.
## The cursor starts on "Add app" (row 1).
func _check_search_ui(history: HistoryView, list: CommitList, details: CommitDetails) -> void:
	var field: FilterField = history.search_field()
	expect(history.match_buttons().all(func(b: Button) -> bool: return not b.visible),
			"no match buttons without a search")
	list.grab_focus()
	press("Ctrl+F")
	expect(field.text_box().has_focus(), "Ctrl+F in History focuses the search")
	type_text("app")
	await get_tree().process_frame  # LineEdit reports text changes deferred
	expect(await wait_until(func() -> bool: return history.status_text() == "2/2"),
			"the selected commit is the second match: %s" % history.status_text())
	expect(history.match_buttons().all(func(b: Button) -> bool: return b.visible), "the match buttons show while searching")
	var strip: MarkStrip = list.match_strip()
	expect(strip.visible, "the strip of matches shows")
	await get_tree().process_frame
	expect(strip.position.x + strip.size.x <= list.size.x and strip.position.x >= list.content_width(),
			"it sits beside the scroll bar, outside the rows (%s)" % strip.position)
	var marked: int = 0
	for flag: int in strip.overview():
		marked += flag
	expect(marked > 0, "it marks the matches")
	expect(strip.current >= 0.0, "the selected match is marked stronger")
	press("Enter")
	expect(await wait_until(func() -> bool: return list.cursor == 0), "Enter wraps to the first match")
	expect_eq(history.status_text(), "1/2", "the count follows")
	expect(await wait_until(func() -> bool: return details.summary_text() == "Improve app"),
			"the details show the match: %s" % details.summary_text())
	press("Shift+Enter")
	expect(await wait_until(func() -> bool: return list.cursor == 1), "Shift+Enter wraps back to the last match")
	press("F3")
	expect(await wait_until(func() -> bool: return list.cursor == 0), "F3 steps to the next match")
	field.set_text("initial")
	expect(await wait_until(func() -> bool: return list.cursor == 2),
			"the first match from the selected commit down is selected: %d" % list.cursor)
	expect(await wait_until(func() -> bool: return history.status_text() == "1/1"),
			"one match: %s" % history.status_text())
	expect(not bool(list.row_data(0).get("match", true)), "the other rows are not matches")
	expect(bool(list.row_data(2).get("match", false)), "the matching row is flagged")
	expect_eq(list.search_query(), "initial", "the list dims and highlights for the query")
	field.set_text("zzz-none")
	expect(await wait_until(func() -> bool: return history.status_text() == "No matches"),
			"no matches: %s" % history.status_text())
	expect_eq(field.get_node("%Count").theme_type_variation, &"FilterFieldCountError", "no matches is shown as an error")
	expect(not list.match_strip().visible, "no strip without matches")
	field.focus_text()
	press("Escape")
	expect_eq(field.text(), "", "Escape clears the search")
	expect(history.match_buttons().all(func(b: Button) -> bool: return not b.visible), "and they hide again")
	expect(await wait_until(func() -> bool: return history.status_text().is_empty()),
			"the count hides with the search: %s" % history.status_text())
	expect_eq(list.search_query(), "", "nothing is dimmed")
	press("Escape")
	expect(list.has_focus(), "a second Escape goes back to the list")


class DelayedHistory:
	extends HistoryView
	var report_parents: bool = false

	func _parent_rows() -> Dictionary:
		return super._parent_rows() if report_parents else {}


func _select_ready(history: HistoryView, row: int) -> bool:
	history._select(row)
	var oid: String = history.commit_list().hash_at(row)
	history.details().show_commit(oid)
	return await wait_until(func() -> bool: return history.details().commit_oid() == oid \
			and String(history.session.commit_info().get("oid", "")) == oid)


func _check_parents(page: RepoTab) -> void:
	var history: HistoryView = page.history()
	var list: CommitList = history.commit_list()
	var details: CommitDetails = history.details()
	expect(await _select_ready(history, 0), "parent source loads")
	var parent: String = list.hash_at(1)
	expect_eq(page.session.graph_parent_rows(0), {parent: 1}, "the bridge maps full parent OIDs to rows")
	expect(page.session.graph_parent_rows(-1).is_empty(), "negative source rows have no parents")
	expect(page.session.graph_parent_rows(3).is_empty(), "unreported source rows have no parents")
	expect(page.session.graph_parent_rows(2).is_empty(), "root rows have no parents")
	expect(Actions.get_action(&"history.go_to_parent").hidden, "the contextual action stays out of the palette")
	expect(not Actions.is_enabled(&"history.go_to_parent"), "there is no target between activations")
	expect(details.parent_links().is_empty(), "an ordinary commit shows no parent links")
	expect(not (details.get_node("%Parents") as Control).visible, "an ordinary commit has no parent row")
	expect(await _select_ready(history, 2), "the root loads")
	expect(details.parent_links().is_empty(), "the root shows no parent links")
	expect(not (details.get_node("%Parents") as Control).visible, "the root has no parent row")


## Runs after `_check_merge_parents`: row 0 is a merge, the only kind of
## commit whose details link to its parents.
func _check_parent_links(main: Main, page: RepoTab) -> void:
	var history: HistoryView = page.history()
	var list: CommitList = history.commit_list()
	var details: CommitDetails = history.details()
	expect(await _select_ready(history, 0), "the merge loads")
	var info: Dictionary = page.session.commit_info()
	var parents: PackedStringArray = info["parents"]
	expect_eq(details.parent_links().size(), 2, "a merge has two links")
	if details.parent_links().size() != 2:
		return
	var parent: String = parents[0]
	var row: int = int(page.session.graph_parent_rows(0)[parent])
	var link: LinkButton = details.parent_links()[0]
	expect_eq(link.text, parent.left(7), "the parent hash stays short")
	expect(link.tooltip_text.contains(parent), "the tooltip contains the full parent OID")
	expect_eq(link.focus_mode, Control.FOCUS_ALL, "parent links are keyboard accessible")
	link.grab_focus()
	press("Enter")
	expect(await wait_until(func() -> bool: return details.commit_oid() == parent), "Enter opens the parent")
	expect_eq(list.cursor, row, "Enter selects the actual graph row")
	expect_eq(String(page.commit_target().get("hash", "")), parent, "commit actions target the displayed parent")
	expect(list.has_focus(), "navigation returns focus to the commit list")
	expect(details.parent_links().is_empty(), "the ordinary parent shows no links")
	expect(await _select_ready(history, 0), "the merge loads again")
	var stale: LinkButton = details.parent_links()[1]
	list.select_only(row)
	stale.pressed.emit()
	expect_eq(list.cursor, row, "a link cannot navigate once its source is no longer selected")
	expect(await _select_ready(history, 0), "the source loads again")
	var query: String = String(info["summary"])
	history.search_field().set_text(query)
	expect(await wait_until(func() -> bool: return bool(page.session.search_info().get("done", false))), "search completes")
	details.parent_links()[0].grab_focus()
	press("Space")
	expect(await wait_until(func() -> bool: return list.cursor == row and details.commit_oid() == parent),
			"Space can navigate to a nonmatching parent")
	expect_eq(history.search_field().text(), query, "parent navigation preserves the query")
	expect_eq(page.session.search_match_index(list.cursor), -1, "the selected parent is not a search match")
	press("F3")
	expect(await wait_until(func() -> bool: return list.cursor == 0), "F3 still visits the original search matches")
	history.search_field().set_text("")
	expect(await _select_ready(history, 0), "the source is restored before switching tabs")
	var other: RepoTab = main.open_repo(fixtures_dir().path_join("repo-1"))
	expect(await wait_until(func() -> bool: return not other.history().details().commit_oid().is_empty()),
			"another session opens")
	details.parent_links()[0].pressed.emit()
	expect_eq(list.cursor, 0, "an inactive tab's link cannot navigate")
	expect_eq(other.history().commit_list().cursor, 0, "it cannot target the active tab either")
	main.close_tab(1)


func _check_merge_parents(page: RepoTab) -> void:
	var history: HistoryView = page.history()
	var session: RepoSession = page.session
	var previous: String = String(session.status().get("oid", ""))
	expect(session.pull("merge") >= 0, "the fixture's local remote can be merged")
	if not await wait_until(func() -> bool: return session.graph_row_count() == 5 \
			and not String(session.status().get("oid", "")).is_empty() \
			and String(session.status().get("oid", "")) != previous):
		expect(false, "the fixture merge finishes")
		return
	expect(await _select_ready(history, 0), "the merge details load")
	var parents: PackedStringArray = session.commit_info()["parents"]
	expect_eq(parents.size(), 2, "the fixture has two merge parents")
	var rows: Dictionary = session.graph_parent_rows(0)
	expect_eq(rows.size(), parents.size(), "both merge parents resolve independently")
	for index: int in parents.size():
		expect(await _select_ready(history, 0), "the merge is reselected")
		var links: Array[LinkButton] = history.details().parent_links()
		expect_eq(links.size(), 2, "both parents have links")
		if links.size() != 2:
			return
		expect(links[index].tooltip_text.contains(parents[index]), "links preserve Git parent order")
		links[index].pressed.emit()
		expect(await wait_until(func() -> bool: return history.details().commit_oid() == parents[index]),
				"each merge parent opens its own details")
		expect_eq(history.commit_list().cursor, int(rows[parents[index]]), "the mapped parent row is selected")
		expect_eq(String(page.commit_target().get("hash", "")), parents[index], "actions follow each merge parent")


func _queue_delayed(history: HistoryView, target: String) -> void:
	history._parent_action_source = history.details().commit_oid()
	history._parent_action_oid = target
	history._parent_action_session = history.session
	expect(history.can_go_to_parent(), "the delayed request has valid source context")
	history.go_to_parent()
	history._clear_parent_action()


func _check_pending_parents(page: RepoTab) -> void:
	var scene: PackedScene = load("res://app/history/history_view.tscn") as PackedScene
	var history: HistoryView = scene.instantiate() as HistoryView
	# The new script builds its own indicator: free the first one.
	var orphan: LoadingIndicator = history.loading_indicator()
	history.set_script(DelayedHistory)
	orphan.free()
	add_child(history)
	history.session = page.session
	expect(await _select_ready(history, 0), "the delayed view loads real merge metadata")
	var parents: PackedStringArray = page.session.commit_info()["parents"]
	if parents.size() != 2:
		history.session = null
		history.queue_free()
		return
	var target: String = parents[1]
	var destination: int = int(page.session.graph_parent_rows(0)[target])
	_queue_delayed(history, target)
	expect_eq(history._pending_parent_oid, target, "an unreported parent stays pending")
	expect_eq(history.commit_list().cursor, 0, "pending navigation leaves the source selected")
	history.commit_list().set("_row_count", 1)
	history.set("report_parents", true)
	history._on_graph_changed(0, 5)
	expect_eq(history.commit_list().cursor, destination, "reporting the parent resolves the pending jump")
	expect(history._pending_parent_oid.is_empty(), "the pending request is consumed")
	expect(await _select_ready(history, 0), "the delayed source is restored")
	history.set("report_parents", false)
	_queue_delayed(history, target)
	history._select(1)
	expect(history._pending_parent_oid.is_empty(), "competing selection cancels pending navigation")
	history.set("report_parents", true)
	history._on_graph_changed(0, 5)
	expect_eq(history.commit_list().cursor, 1, "later graph progress cannot steal selection")
	expect(await _select_ready(history, 0), "the source is restored for reset")
	history.set("report_parents", false)
	_queue_delayed(history, target)
	history._on_graph_reset()
	expect(history._pending_parent_oid.is_empty(), "a graph reset cancels navigation")
	expect_eq(history.commit_list().cursor, -1, "a reset clears the stale row selection")
	history._on_graph_loaded(5, "")
	expect(await _select_ready(history, 0), "the source is restored after the reset")
	var notices: Array[String] = []
	history.notice.connect(func(_title: String, message: String) -> void: notices.append(message))
	_queue_delayed(history, target)
	history._on_graph_loaded(5, "")
	expect_eq(notices.size(), 1, "an unavailable parent produces one explanation")
	expect_eq(history.commit_list().cursor, 0, "an unavailable parent preserves selection")
	expect_eq(history.details().commit_oid(), String(page.session.commit_info()["oid"]),
			"an unavailable parent preserves the displayed commit")
	history._try_parent_navigation()
	expect_eq(notices.size(), 1, "completed requests do not repeat notices")
	history._graph_loading = true
	_queue_delayed(history, target)
	history.hide()
	expect(history._pending_parent_oid.is_empty(), "hiding the view cancels navigation")
	history.show()
	_queue_delayed(history, target)
	history.session = null
	expect(history._pending_parent_oid.is_empty(), "switching sessions cancels navigation")
	expect(history.details().parent_links().is_empty(), "switching sessions clears stale links")
	history.queue_free()
	await get_tree().process_frame


func _diff_has(diff: DiffView, needle: String) -> bool:
	for i: int in diff.row_count():
		if diff.line_text(i).contains(needle):
			return true
	return false
