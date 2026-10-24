extends SmokeTest
## M4b: stage, unstage and discard single diff lines with the keyboard, and
## undo the discard. Uses fixture `repo-7`; GDScript only edits README.md,
## the app runs git. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("lines_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-7")
	var readme: String = repo.path_join("README.md")
	_write(readme, "# repo 7\nline a\nline b\n")

	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.change_count("unstaged") == 2),
			"README.md and app.txt are modified")
	press("Ctrl+2")
	var view: ChangesView = page.changes()
	var list: ChangeList = view.unstaged_list()
	expect_eq(list.path_at(list.cursor), "README.md", "README.md is first")
	var diff: DiffView = view.diff_view()
	expect(await wait_until(func() -> bool: return diff.row_count() == 4), "README diff has 4 rows: %d" % diff.row_count())
	expect(Array(diff.line(1).get("syntax", [])) == [0, 8, 0], "Markdown heading is colored: %s" % [diff.line(1)])

	# Right moves into the diff; Down twice to `+line a`; Enter stages it.
	press("Right")
	expect(view.diff_view_focused(), "Right focuses the diff")
	press("Down")
	press("Down")
	expect_eq(diff.line_text(diff.cursor), "line a", "cursor on +line a")
	press("Enter")
	expect(await wait_until(func() -> bool: return session.change_count("staged") == 1),
			"Enter staged one line of README.md")
	expect(await wait_until(_line_a_is_context.bind(diff)), "the unstaged diff now has line a as context")

	# Delete on `+line b` asks first, then discards; Ctrl+Z brings it back.
	press("Down")
	expect_eq(diff.line_text(diff.cursor), "line b", "cursor on +line b")
	press("Delete")
	var dialog: ConfirmationDialog = view.confirm_dialog()
	expect(await wait_until(func() -> bool: return dialog.visible), "discard asks for confirmation")
	press("Enter")
	expect(await wait_until(func() -> bool: return _read(readme) == "# repo 7\nline a\n"),
			"discard removed line b from the file: %s" % _read(readme).c_escape())
	expect(await wait_until(func() -> bool: return view.can_undo_discard()), "the discard can be undone")
	press("Left")
	press("Ctrl+Z")
	expect(await wait_until(func() -> bool: return _read(readme) == "# repo 7\nline a\nline b\n"),
			"Ctrl+Z restored line b: %s" % _read(readme).c_escape())

	# In the staged diff, Enter on the hunk header unstages the whole hunk.
	var staged: ChangeList = view.staged_list()
	expect(await wait_until(func() -> bool: return staged.row_count() == 1), "README.md is in the staged list")
	staged.grab_focus()
	staged.select_only(0)
	expect(await wait_until(_staged_diff_shown.bind(session, diff)), "staged diff shown")
	press("Right")
	expect_eq(int(diff.line(diff.cursor)["kind"]), 0, "cursor on the hunk header")
	press("Enter")
	expect(await wait_until(func() -> bool: return session.change_count("staged") == 0),
			"Enter on the hunk header unstaged the hunk")

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _line_a_is_context(diff: DiffView) -> bool:
	return diff.row_count() == 4 and diff.line_text(3) == "line b" and int(diff.line(2)["kind"]) == 1


func _staged_diff_shown(session: RepoSession, diff: DiffView) -> bool:
	return String(session.diff_info().get("kind", "")) == "staged" and diff.row_count() == 3


func _write(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)
