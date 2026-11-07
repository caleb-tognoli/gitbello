extends SmokeTest
## M7.9 P1: line endings in diffs. A diff whose endings changed ends with a
## "Line endings: LF → CRLF (3 lines)" row after its last line, a last line
## without a newline is followed by a "No newline at end of file" row
## (neither selectable nor copied), and a file whose only changes are its
## endings or final newline shows a card with Show diff, in Changes and in
## History. P2: those files carry an `EOL` chip and pass the "Line endings
## only" filter; Restore line endings (card, action) puts their endings back
## and Undo brings the edits back. Uses the `eol` fixture (it restores a file
## and undoes it). Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("line_endings_smoke: no --fixtures, skipped")
		return
	Core.set_diff_mode("text", "unified")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(fixtures.path_join("eol"))
	var session: RepoSession = page.session
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var panel: DiffPanel = changes.diff_panel()
	var view: DiffView = panel.view()
	expect(await wait_until(func() -> bool: return session.change_count() == 5), "five changed files")

	# P2: the files whose only changes are endings, found after the status.
	var endings_only: PackedStringArray = PackedStringArray(["both.txt", "crlf.txt", "nonl.txt"])
	expect(await wait_until(func() -> bool: return _chipped(changes) == endings_only),
			"EOL chips on %s" % [_chipped(changes)])
	session.set_change_filter("", PackedStringArray(["endings_only"]))
	expect_eq(session.shown_change_count(), 3, "the Line endings only filter shows them")
	session.set_change_filter("", PackedStringArray())
	changes.list().reload()

	# CRLF lines in an LF file: one row after the last line.
	expect(await _select(changes, session, "edit.txt"), "edit.txt's diff loads")
	var endings: Dictionary = session.diff_info().get("endings", {})
	expect(endings.get("from") == "LF" and endings.get("to") == "CRLF" and int(endings.get("lines", 0)) == 3,
			"diff_info has the endings: %s" % endings)
	expect(not bool(session.diff_info().get("eol_only", true)), "text changed too")
	var markers: Array[int] = _marker_rows(view, "line_endings")
	expect_eq(markers, [view.row_count() - 1] as Array[int], "one row, after the last line")
	if markers.size() == 1:
		expect_eq(DiffView.marker_label(view.row_data(markers[0])), "Line endings: LF → CRLF (3 lines)", "it says what changed")
	view.select_all()
	expect(not view.selected_text().contains("Line endings") and view.selected_text().contains("let count = 5;"),
			"Copy leaves the marker rows out")
	view.clear_selection()
	panel.choose_mode("split")
	await get_tree().process_frame
	var split_markers: Array[int] = _marker_rows(view, "line_endings")
	expect_eq(split_markers, [view.row_count() - 1] as Array[int], "side by side too")
	if split_markers.size() == 1:
		var row: Dictionary = view.row_data(split_markers[0])
		expect(row["left"] == row["right"], "spanning both sides")
	panel.choose_mode("unified")
	await get_tree().process_frame

	# A last line without a newline: its own row, not text on the line.
	expect(await _select(changes, session, "tail.txt"), "tail.txt's diff loads")
	var no_newline: Array[int] = _marker_rows(view, "no_newline")
	expect_eq(no_newline.size(), 1, "one no-newline row")
	if no_newline.size() == 1:
		expect_eq(String(view.row_data(no_newline[0] - 1).get("text", "")), "final", "under the line without it")
		expect_eq(DiffView.marker_label(view.row_data(no_newline[0])), "No newline at end of file", "it says so")
	expect(_marker_rows(view, "line_endings").is_empty(), "no line-endings row without ending changes")
	panel.choose_mode("split")
	await get_tree().process_frame
	var split_no_newline: Array[int] = _marker_rows(view, "no_newline")
	if split_no_newline.size() == 1:
		var row: Dictionary = view.row_data(split_no_newline[0])
		expect((row["left"] as Dictionary).is_empty() and not (row["right"] as Dictionary).is_empty(),
				"side by side, on the new side only")
	else:
		expect(false, "side by side, one no-newline row: %d" % split_no_newline.size())
	panel.choose_mode("unified")
	await get_tree().process_frame

	# Only endings, only the final newline, both: a card with Show diff.
	var cards: Dictionary[String, Array] = {
		"crlf.txt": ["Line endings: CRLF → LF (6 lines)"],
		"nonl.txt": ["Newline added at the end"],
		"both.txt": ["Line endings: CRLF → LF (2 lines)", "Newline added at the end"],
	}
	for path: String in cards:
		expect(await _select(changes, session, path), "%s's diff loads" % path)
		expect_eq(panel.message_text(), "\n".join(cards[path]), "%s shows the card" % path)
		expect_eq(panel.card_buttons(), PackedStringArray(["Restore line endings", "Show diff"]),
				"%s's card offers Restore line endings and Show diff" % path)
		expect_eq(view.row_count(), 0, "no diff behind %s's card" % path)
	expect(await _select(changes, session, "crlf.txt"), "crlf.txt again")
	expect(not panel.picker_visible(), "no mode picker on the card")
	panel.card_action.emit("eol_show_diff")
	expect(view.row_count() > 0 and panel.message_text().is_empty(), "Show diff shows the diff")
	expect_eq(_marker_rows(view, "line_endings"), [view.row_count() - 1] as Array[int], "with its row at the end")
	expect(panel.picker_visible(), "and the mode picker")
	expect(await _select(changes, session, "nonl.txt"), "nonl.txt again")
	expect(await _select(changes, session, "crlf.txt"), "back to crlf.txt")
	expect(view.row_count() > 0, "Show diff holds for the file")

	# Restore line endings from the card, then Undo.
	expect(Actions.is_enabled(&"changes.restore_line_endings"), "Restore line endings applies to crlf.txt")
	expect(await _select(changes, session, "tail.txt"), "tail.txt")
	expect(not Actions.is_enabled(&"changes.restore_line_endings"), "but not to tail.txt (its last line changed)")
	expect(await _select(changes, session, "both.txt"), "both.txt")
	panel.card_action.emit("eol_restore")
	expect(await wait_until(func() -> bool: return session.change_count() == 4), "both.txt has no changes left")
	expect(changes.can_undo_discard(), "it can be undone")
	changes.undo_discard()
	expect(await wait_until(func() -> bool: return session.change_count() == 5), "Undo brings both.txt's edits back")
	expect(await wait_until(func() -> bool: return _chipped(changes) == endings_only), "with its chip")

	# History: the commit that converted the notes.
	page.show_view(WorktreeView.View.HISTORY)
	var details: CommitDetails = page.history().details()
	var commits: CommitList = page.history().commit_list()
	expect(await wait_until(func() -> bool: return commits.row_count() == 2), "two commits")
	commits.select_only(0)
	expect(await wait_until(func() -> bool:
		var info: Dictionary = session.commit_diff_info()
		return String(info.get("state", "")) == "ready" and String(info.get("path", "")) == "notes.txt"),
			"the conversion's diff loads")
	expect_eq(details.diff_panel().message_text(), "Line endings: LF → CRLF (4 lines)",
			"History shows the card")
	expect_eq(details.diff_panel().card_buttons(), PackedStringArray(["Show diff"]), "with Show diff")

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


## Paths of the Changes rows with the `EOL` chip.
func _chipped(changes: ChangesView) -> PackedStringArray:
	var paths: PackedStringArray = PackedStringArray()
	for row: int in changes.list().row_count():
		if bool(changes.list().row(row).get("endings_only", false)):
			paths.append(changes.list().path_at(row))
	return paths


## Rows of `view` holding a `marker` row (either side).
func _marker_rows(view: DiffView, marker: String) -> Array[int]:
	var rows: Array[int] = []
	for row: int in view.row_count():
		var data: Dictionary = view.row_data(row)
		var lines: Array = [data] if not view.side_by_side else [data.get("left", {}), data.get("right", {})]
		for line: Dictionary in lines:
			if int(line.get("kind", -1)) == DiffView.KIND_MARKER and String(line.get("marker", "")) == marker:
				rows.append(row)
				break
	return rows


## Highlights `path` in Changes and waits for its diff.
func _select(changes: ChangesView, session: RepoSession, path: String) -> bool:
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
