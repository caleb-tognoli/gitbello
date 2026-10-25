extends SmokeTest
## The diff is selected as plain text (drag, double-click, keys), and
## the lines between hunks open from the hunk headers' expanders or all at
## once with Show whole file. Uses fixture `repo-12`; GDScript only writes
## long.txt, the app runs git. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("diff_view_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-12")
	var long_file: String = repo.path_join("long.txt")
	write_file(long_file, _lines([]))

	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.change_count() == 3), "long.txt is a new change")
	# Commit long.txt alone, so it has a base to compare with.
	session.pick_all(false)
	session.pick_files(PackedStringArray(["long.txt"]), true)
	session.commit("Add long.txt", "", false)
	expect(await wait_until(func() -> bool: return session.change_count() == 2), "long.txt is committed")
	write_file(long_file, _lines([10, 60]))
	expect(await wait_until(func() -> bool: return session.change_count() == 3), "long.txt changed")

	press("Ctrl+Shift+G")
	var view: ChangesView = page.changes()
	var list: ChangeList = view.list()
	var row: int = -1
	for i: int in list.row_count():
		if list.path_at(i) == "long.txt":
			row = i
	list.grab_focus()
	list.select_only(row)
	var diff: DiffView = view.diff_view()
	# Two hunks of 8 rows, their headers and the end row.
	expect(await wait_until(func() -> bool: return diff.row_count() == 19),
			"long.txt's diff: two hunks and an end row: %d" % diff.row_count())
	expect_eq(diff.row_expanders(0), "up", "the first header opens upwards")
	expect_eq(diff.row_expanders(9), "both", "the second header opens both ways")
	expect_eq(diff.row_expanders(18), "down", "the end row opens downwards")
	expect(Actions.is_enabled(&"diff.toggle_whole_file"), "Show whole file is offered")

	# Up from the second header: 20 more lines between it and its hunk.
	diff.press_expander(9, "up")
	expect(await wait_until(func() -> bool: return diff.row_count() == 39), "20 lines opened: %d" % diff.row_count())
	expect_eq(diff.line_text(10), "l37", "the first opened line")
	expect_eq(int(diff.line(10).get("index", 0)), -1, "opened lines are not diff lines")
	expect_eq(int(diff.line(10).get("new", 0)), 37, "they are numbered")
	expect(String(diff.line(9).get("text", "")).begins_with("@@ -37,27 +37,27 @@"),
			"the header counts them: %s" % diff.line(9).get("text", ""))

	# Plain text selection: a drag across lines copies just their text.
	diff.grab_focus()
	await get_tree().process_frame
	var height: float = diff.row_height()
	var char_width: float = diff._char_width
	var text_left: float = diff._text_left(0)
	var at: Callable = func(r: int, column: int) -> Vector2:
		return Vector2(text_left + column * char_width + 1.0, (r + 0.5) * height - diff.scroll_offset())
	_mouse(diff, at.call(1, 1), true)
	_drag(diff, at.call(3, 2))
	_mouse(diff, at.call(3, 2), false)
	expect(diff.has_selection(), "a drag selects text")
	expect_eq(diff.selected_text(), "7\nl8\nl9", "the selection is plain text from column to column")
	expect_eq(diff.selected_rows(), PackedInt32Array([1, 2, 3]), "it touches three rows")
	expect_eq(diff.selected_or_cursor(), PackedInt32Array([1, 2, 3]), "its lines can be picked")
	# A double click selects a word.
	_mouse(diff, at.call(4, 1), true)
	_mouse(diff, at.call(4, 1), false)
	_mouse(diff, at.call(4, 1), true)
	expect_eq(diff.selected_text(), "l10", "a double click selects the word")
	_mouse(diff, at.call(4, 1), false)
	# Down selects the next line whole; Shift+Down extends.
	press("Down")
	expect_eq(diff.selected_text(), "L10", "Down selects the next line")
	press("Shift+Down")
	expect_eq(diff.selected_text(), "L10\nl11", "Shift+Down extends")

	# Show whole file: every line, the button pressed; again for the changes.
	Actions.run_action(&"diff.toggle_whole_file")
	expect(await wait_until(func() -> bool: return diff.row_count() == 102),
			"the whole file: 100 lines and the 2 added: %d" % diff.row_count())
	expect_eq(diff.line_text(0), "l1", "it starts at the first line")
	expect_eq(diff.row_expanders(0), "", "nothing is left to open")
	Actions.run_action(&"diff.toggle_whole_file")
	expect(await wait_until(func() -> bool: return diff.row_count() == 19), "only the changes again: %d" % diff.row_count())

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _lines(changed: Array[int]) -> String:
	var text: String = ""
	for n: int in range(1, 101):
		text += ("L%d\n" if changed.has(n) else "l%d\n") % n
	return text


func _mouse(target: Control, at: Vector2, pressed: bool) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	target._gui_input(event)


func _drag(target: Control, at: Vector2) -> void:
	var event: InputEventMouseMotion = InputEventMouseMotion.new()
	event.position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	target._gui_input(event)
