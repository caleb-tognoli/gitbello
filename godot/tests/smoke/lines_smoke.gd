extends SmokeTest
## M6.5 P3 acceptance (was M4b): commit part of a file with the keyboard
## only, through the line checkboxes; a hunk header toggles its hunk; discard
## a line and undo it. Uses fixture `repo-7`; GDScript only edits README.md,
## the app runs git. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("lines_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-7")
	var readme: String = repo.path_join("README.md")
	write_file(readme, "# repo 7\nline a\nline b\n")

	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.change_count() == 3),
			"README.md and app.txt are modified, notes.txt is untracked")
	press("Ctrl+Shift+G")
	var view: ChangesView = page.changes()
	var list: ChangeList = view.list()
	expect_eq(list.path_at(list.cursor), "README.md", "README.md is first")
	expect_eq(session.picked_count(), 3, "nothing staged: every file is included")
	var diff: DiffView = view.diff_view()
	expect(await wait_until(func() -> bool: return diff.row_count() == 4 and diff.pickable),
			"README diff has 4 rows with checkboxes: %d" % diff.row_count())
	expect(Array(diff.line(1).get("syntax", [])) == [0, 8, 0], "Markdown heading is colored: %s" % [diff.line(1)])
	expect_eq(diff.row_pick(2), "all", "+line a starts picked")

	# Right moves into the diff; Down three times to `+line b`; Space leaves it out.
	press("Right")
	expect(view.diff_view_focused(), "Right focuses the diff")
	press("Down")
	press("Down")
	press("Down")
	expect_eq(diff.line_text(diff.cursor), "line b", "cursor on +line b")
	press("Space")
	expect(await wait_until(func() -> bool: return diff.row_pick(3) == "none"), "Space left out +line b")
	expect_eq(diff.row_pick(2), "all", "+line a stays picked")
	expect_eq(diff.row_pick(0), "partial", "the hunk header shows a partial pick")
	expect(await wait_until(func() -> bool: return String(list.row(0).get("pick", "")) == "partial"),
			"README.md's checkbox is partial")

	# The hunk header toggles its whole hunk: all in, then back to the pick.
	press("Up")
	press("Up")
	press("Up")
	expect_eq(int(diff.line(diff.cursor)["kind"]), 0, "cursor on the hunk header")
	press("Space")
	expect(await wait_until(func() -> bool: return diff.row_pick(3) == "all"), "Space on the header picked the hunk")
	press("Down")
	press("Down")
	press("Down")
	press("Space")
	expect(await wait_until(func() -> bool: return diff.row_pick(3) == "none"), "+line b left out again")

	# Leave out app.txt and notes.txt from the list, then commit with the keyboard.
	press("Left")
	expect(list.has_focus(), "Left goes back to the list")
	press("Down")
	expect_eq(list.path_at(list.cursor), "app.txt", "cursor on app.txt")
	press("Space")
	expect(await wait_until(func() -> bool: return String(list.row(1).get("pick", "")) == "none"),
			"Space left out app.txt")
	press("Down")
	press("Space")
	expect(await wait_until(func() -> bool: return session.picked_count() == 1), "Space left out notes.txt")
	var box: CommitBox = view.commit_box()
	expect_eq(box.button_text(), "Commit 1 file to main", "the button says what it commits")
	press("Ctrl+Shift+M")
	type_text("Add line a")
	expect(await wait_until(func() -> bool: return box.can_commit()), "ready to commit: %s" % box.block_reason())
	press("Ctrl+Enter")
	expect(await wait_until(func() -> bool: return not box.is_busy() and box.summary().is_empty()),
			"Ctrl+Enter committed (output: %s)" % box.output_text())
	expect(await wait_until(func() -> bool: return _head_subject(session) == "Add line a"), "graph shows the commit")
	expect_eq(read_file(readme), "# repo 7\nline a\nline b\n", "the working copy keeps line b")
	expect(await wait_until(func() -> bool: return session.change_count() == 3), "the rest is still a change")
	list.grab_focus()
	list.select_only(0)
	expect(await wait_until(func() -> bool: return diff.row_count() == 4 and int(diff.line(2)["kind"]) == 1 			and int(diff.line(3)["kind"]) == 2), "README's diff against HEAD has line a as context, line b added")

	# Delete on `+line b` asks first, then discards; Ctrl+Z brings it back.
	press("Right")
	press("Down")
	press("Down")
	press("Down")
	expect_eq(diff.line_text(diff.cursor), "line b", "cursor on +line b")
	press("Delete")
	var dialog: ConfirmationDialog = view.confirm_dialog()
	expect(await wait_until(func() -> bool: return dialog.visible), "discard asks for confirmation")
	press("Enter")
	expect(await wait_until(func() -> bool: return read_file(readme) == "# repo 7\nline a\n"),
			"discard removed line b from the file: %s" % read_file(readme).c_escape())
	expect(await wait_until(func() -> bool: return view.can_undo_discard()), "the discard can be undone")
	press("Left")
	press("Ctrl+Z")
	expect(await wait_until(func() -> bool: return read_file(readme) == "# repo 7\nline a\nline b\n"),
			"Ctrl+Z restored line b: %s" % read_file(readme).c_escape())

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _head_subject(session: RepoSession) -> String:
	var rows: Array[Dictionary] = session.graph_rows(0, 1)
	return String(rows[0]["subject"]) if not rows.is_empty() else ""
