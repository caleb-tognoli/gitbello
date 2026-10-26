extends SmokeTest
## M4b: selecting a commit in the history shows its details, files and the
## first file's diff; Right and Left move between list, files and diff. The
## files sit beside the diff, the layout buttons work like radio buttons and
## the details' sizes are saved.
## Uses fixture `repo-5` read-only. Skipped without `--fixtures`.

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
	expect_eq(history.status_text(), "3 commits", "the status line has no load time")
	expect_eq(details.files_header().text(), "1 changed file", "the files header counts the files")
	expect_eq(ListHeader.count_text(12345, "commit"), "12,345 commits", "counts have thousands separators")
	expect_eq(details.files_header().size.y, history.list_header().size.y,
			"the files header is as tall as the commits header")
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
	expect(Core.diff_side_by_side(), "the layout is saved")
	var row: Dictionary = diff.row_data(1)
	expect(String(row.get("left", {}).get("text", "")) == "v1" and String(row.get("right", {}).get("text", "")) == "v2",
			"v1 and v2 share a side-by-side row: %s" % [row])
	# `v1` -> `v2` changes the line's only word: no word highlight on top.
	expect(Array(row["right"]["hl"]).is_empty(), "a whole-line change has no word highlight: %s" % [row["right"]["hl"]])
	press("Ctrl+Shift+D")
	expect(not diff.side_by_side and not Core.diff_side_by_side(), "Ctrl+Shift+D switches back")

	# Unified and Side by side are one choice.
	var unified: Button = details.diff_panel().layout_button(false)
	var split: Button = details.diff_panel().layout_button(true)
	expect(unified.button_pressed and not split.button_pressed, "Unified is the chosen layout")
	split.button_pressed = true
	split.pressed.emit()
	expect(diff.side_by_side and Core.diff_side_by_side(), "Side by side switches the layout")
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
	var hash: String = list.hash_at(2)
	session.search_commits(hash.left(7))
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


func _diff_has(diff: DiffView, needle: String) -> bool:
	for i: int in diff.row_count():
		if diff.line_text(i).contains(needle):
			return true
	return false
