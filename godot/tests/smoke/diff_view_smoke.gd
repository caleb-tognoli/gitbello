extends SmokeTest
## The diff is selected as plain text (drag, double-click, keys), and
## the lines between hunks open from the hunk headers' expanders or all at
## once with Show whole file; the minimap scrolls it and marks its changes,
## jumps ease, F7 and Shift+F7 step through the changes, and tiles are
## rendered ahead.
## Uses fixture `repo-12`; GDScript only writes
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

	press("Alt+1")
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
	expect_eq(diff.expander_label(9), "43 lines hidden", "the header says what it hides")
	expect_eq(diff.expander_label(18), "Show 37 more lines", "the end row says what follows")
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
	expect(not diff.caret_shown(), "the mouse shows no caret")
	expect(Actions.is_enabled(&"diff.copy"), "Copy is offered for the selection")
	expect_eq(diff.selected_text(), "7\nl8\nl9", "the selection is plain text from column to column")
	expect_eq(diff.selected_rows(), PackedInt32Array([1, 2, 3]), "it touches three rows")
	expect_eq(diff.selected_or_cursor(), PackedInt32Array([1, 2, 3]), "its lines can be picked")
	# A double click selects a word.
	_mouse(diff, at.call(4, 1), true)
	_mouse(diff, at.call(4, 1), false)
	_mouse(diff, at.call(4, 1), true)
	expect_eq(diff.selected_text(), "l10", "a double click selects the word")
	_drag(diff, at.call(5, 1))
	expect_eq(diff.selected_text(), "l10\nL10", "dragging on after it goes by words")
	_mouse(diff, at.call(5, 1), false)
	_mouse(diff, at.call(4, 0), true)
	_mouse(diff, at.call(4, 0), false)
	# Down selects the next line whole; Shift+Down extends.
	press("Down")
	expect(diff.caret_shown(), "the keyboard shows the caret")
	expect_eq(diff.selected_text(), "L10", "Down selects the next line")
	press("Shift+Down")
	expect_eq(diff.selected_text(), "L10\nl11", "Shift+Down extends")
	press("Shift+Left")
	expect_eq(diff.selected_text(), "L10\nl1", "Shift+Left takes back a character")
	press("Ctrl+Shift+Left")
	expect_eq(diff.selected_text(), "L10\n", "Ctrl+Shift+Left takes back a word")

	# Show whole file: every line, the button pressed; again for the changes.
	Actions.run_action(&"diff.toggle_whole_file")
	expect(await wait_until(func() -> bool: return diff.row_count() == 102),
			"the whole file: 100 lines and the 2 added: %d" % diff.row_count())
	expect_eq(diff.line_text(0), "l1", "it starts at the first line")
	expect_eq(diff.row_expanders(0), "", "nothing is left to open")
	await _test_minimap(diff, session)
	await _test_prefetch()
	Actions.run_action(&"diff.toggle_whole_file")
	expect(await wait_until(func() -> bool: return diff.row_count() == 19), "only the changes again: %d" % diff.row_count())
	await _test_strip_gaps(diff)

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


## The minimap of the whole file (102 rows): it replaces the scroll bar,
## renders tiles, marks the changes, scrolls on clicks, drags and the wheel,
## falls back to its strip when turned off, and dims lines left out.
func _test_minimap(diff: DiffView, session: RepoSession) -> void:
	var minimap: DiffMinimap = diff.minimap()
	var window_size: Vector2i = get_window().size
	get_window().size = Vector2i(1600, 900)
	expect(await wait_until(func() -> bool: return diff.size.x >= 600.0, 5000),
			"the wider window widens the diff (%.0f px)" % diff.size.x)
	await get_tree().process_frame
	expect(minimap.visible and minimap.has_sources(), "the minimap shows beside a diff")
	expect(not diff._scroll_bar.visible, "it replaces the scroll bar")
	expect(minimap.is_full(), "a wide diff shows the preview (diff %.0f px wide)" % diff.size.x)
	expect_eq(minimap.size.x, float(minimap.get_theme_constant(&"width", DiffMinimap.THEME_TYPE)),
			"the column is as wide as the theme says")
	expect(minimap.tile_count() > 0, "drawing renders tiles")
	var flags: PackedByteArray = minimap.overview()
	expect_eq(flags.size(), int(minimap.size.y), "a bucket per pixel")
	var marks: int = 0
	for flag: int in flags:
		marks |= flag
	expect_eq(marks & (DiffMinimap.ADDED | DiffMinimap.REMOVED), DiffMinimap.ADDED | DiffMinimap.REMOVED,
			"the strip marks the added and removed lines")

	# A click centres its row; dragging the box scrolls on.
	var row_px: float = minimap.row_height()
	_mouse(minimap, Vector2(10.0, 80.5 * row_px), true)
	_mouse(minimap, Vector2(10.0, 80.5 * row_px), false)
	expect(diff.is_easing(), "a click eases the diff there")
	expect(await wait_until(func() -> bool: return not diff.is_easing(), 2000), "the ease ends")
	var middle: int = diff.first_visible_row() + int(diff.size.y / diff.row_height() / 2.0)
	expect(diff.scroll_offset() > 0.0 and absi(middle - 80) <= 2 or diff.scroll_offset() == diff.max_scroll_offset(),
			"a click centres row 80 (middle %d)" % middle)
	diff.set_scroll_offset(0.0)
	var box: Rect2 = minimap.box_rect()
	_mouse(minimap, box.get_center(), true)
	_drag(minimap, box.get_center() + Vector2(0.0, 20.0))
	_mouse(minimap, box.get_center() + Vector2(0.0, 20.0), false)
	expect(diff.scroll_offset() > 0.0, "dragging the box scrolls")
	_hover(minimap, minimap.box_rect().get_center())
	expect_eq(minimap.mouse_default_cursor_shape, Control.CURSOR_DRAG, "the box shows the drag cursor")
	var below: Vector2 = Vector2(10.0, minimap.box_rect().end.y + 4.0)
	_hover(minimap, below)
	expect_eq(minimap.mouse_default_cursor_shape, Control.CURSOR_POINTING_HAND,
			"the rest of the preview shows a hand (%s)" % below)
	var wheel: InputEventMouseButton = InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	var before: float = diff.scroll_offset()
	minimap._gui_input(wheel)
	expect(diff.scroll_offset() < before, "the wheel over the minimap scrolls the diff")
	var strip: Rect2 = minimap.strip_rect()
	_mouse(minimap, Vector2(strip.get_center().x, strip.end.y - 1.0), true)
	_mouse(minimap, Vector2(strip.get_center().x, strip.end.y - 1.0), false)
	expect(await wait_until(func() -> bool: return not diff.is_easing(), 2000), "the strip's jump eases")
	expect_eq(diff.scroll_offset(), diff.max_scroll_offset(), "the strip's bottom scrolls to the end")
	_hover(minimap, strip.get_center())
	expect_eq(minimap.mouse_default_cursor_shape, Control.CURSOR_POINTING_HAND, "the strip shows a hand")

	await _test_changes(diff)

	# Off: only the strip, as wide as a scroll bar.
	Actions.run_action(&"diff.toggle_minimap")
	expect(not Core.diff_minimap() and not minimap.is_full(), "the toggle turns the preview off")
	expect_eq(minimap.size.x, float(minimap.get_theme_constant(&"strip_only_width", DiffMinimap.THEME_TYPE)),
			"the strip alone stays")
	Actions.run_action(&"diff.toggle_minimap")
	expect(Core.diff_minimap() and minimap.is_full(), "the toggle turns it back on")
	# A narrow diff keeps only the strip too.
	get_window().size = Vector2i(900, 700)
	expect(await wait_until(func() -> bool: return not minimap.is_full(), 5000),
			"a narrow diff shows only the strip (%.0f px)" % diff.size.x)
	expect_eq(minimap.size.x, float(minimap.get_theme_constant(&"strip_only_width", DiffMinimap.THEME_TYPE)),
			"the narrow strip is as wide as a scroll bar")
	get_window().size = window_size

	# Lines left out of the commit are marked so.
	var lines: PackedInt32Array = PackedInt32Array()
	for row: int in diff.row_count():
		var kind: int = int(diff.line(row).get("kind", -1))
		if kind == DiffView.KIND_ADDED or kind == DiffView.KIND_REMOVED:
			lines.append(int(diff.line(row).get("index", -1)))
	session.pick_lines(lines, false)
	expect(await wait_until(func() -> bool:
		for flag: int in minimap.overview():
			if flag & DiffMinimap.LEFT_OUT:
				return true
		return false, 5000), "lines left out of the commit are marked")
	session.pick_lines(lines, true)


## The strip spans the whole file while hunks are collapsed (19 rows: the
## gaps hide 6, 43 and 37 lines): marks sit where their lines are, and a
## click in a gap opens it, then scrolls to the line clicked.
func _test_strip_gaps(diff: DiffView) -> void:
	var minimap: DiffMinimap = diff.minimap()
	var window_size: Vector2i = get_window().size
	get_window().size = Vector2i(1600, 900)
	expect(await wait_until(func() -> bool: return minimap.is_full(), 5000), "the preview shows")
	await get_tree().process_frame
	# Units: gap 0 (6), rows 0-8, gap 1 (43), rows 9-17, row 18, gap 2 (37).
	expect(is_equal_approx(minimap.strip_position(0.0), 6.0 / 105.0),
			"the first row sits below the lines above the hunk (%f)" % minimap.strip_position(0.0))
	expect(is_equal_approx(minimap.strip_position(9.0), 58.0 / 105.0),
			"the second hunk sits below the 43 lines between (%f)" % minimap.strip_position(9.0))
	var flags: PackedByteArray = minimap.overview()
	var first_mark: int = -1
	for i: int in flags.size():
		if flags[i] & (DiffMinimap.ADDED | DiffMinimap.REMOVED):
			first_mark = i
			break
	expect(absf(first_mark / float(flags.size()) - 10.0 / 105.0) < 0.02,
			"the first change is marked a tenth of the way down (%d of %d)" % [first_mark, flags.size()])
	var target: Dictionary = minimap.strip_target(0.4 * minimap.size.y)
	expect_eq(int(target.get("gap", -1)), 1, "40% down the strip is the gap between the hunks")
	var strip: Rect2 = minimap.strip_rect()
	_mouse(minimap, Vector2(strip.get_center().x, 0.4 * minimap.size.y), true)
	_mouse(minimap, Vector2(strip.get_center().x, 0.4 * minimap.size.y), false)
	expect(await wait_until(func() -> bool: return diff.row_count() == 61, 5000),
			"the click opens the gap's 43 lines in place of its header: %d rows" % diff.row_count())
	expect(await wait_until(func() -> bool: return not diff.is_easing(), 2000), "then eases there")
	var middle: int = diff.first_visible_row() + int(diff.size.y / diff.row_height() / 2.0)
	expect(absi(middle - 36) <= 2 or diff.scroll_offset() == diff.max_scroll_offset(),
			"the line clicked (row 36, l41) is in the middle (middle %d)" % middle)
	get_window().size = window_size


## F7 and Shift+F7 in the whole file, whose change blocks start at rows 9
## and 60: from the middle row on, then from the block they went to, wrapping;
## the wheel finishes a running ease.
func _test_changes(diff: DiffView) -> void:
	diff.grab_focus()
	diff.set_scroll_offset(0.0)
	expect(Actions.is_enabled(&"diff.next_change") and Actions.is_enabled(&"diff.previous_change"),
			"next and previous change are offered")
	var centred: Callable = func(row: int) -> float:
		return clampf(row * diff.row_height() - (diff.size.y - diff.row_height()) / 2.0,
				0.0, diff.max_scroll_offset())
	press("F7")
	expect(diff.is_easing(), "F7 eases")
	expect_eq(diff.target_scroll_offset(), centred.call(60), "F7 goes to the block after the middle row")
	expect(await wait_until(func() -> bool: return not diff.is_easing(), 2000), "the ease ends")
	expect_eq(diff.scroll_offset(), centred.call(60), "it ends with the block centred")
	press("F7")
	expect_eq(diff.target_scroll_offset(), centred.call(9), "F7 wraps to the first block")
	await wait_until(func() -> bool: return not diff.is_easing(), 2000)
	press("Shift+F7")
	expect_eq(diff.target_scroll_offset(), centred.call(60), "Shift+F7 wraps to the last block")
	await wait_until(func() -> bool: return not diff.is_easing(), 2000)
	press("Shift+F7")
	expect_eq(diff.target_scroll_offset(), centred.call(9), "Shift+F7 goes to the block before")

	# The wheel during an ease finishes it, then scrolls from its end.
	press("F7")
	var target: float = diff.target_scroll_offset()
	expect(diff.is_easing() and target > 0.0, "F7 eases down")
	var wheel: InputEventMouseButton = InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	diff._gui_input(wheel)
	expect(not diff.is_easing(), "the wheel finishes the ease")
	expect_eq(diff.scroll_offset(), target - VirtualList.WHEEL_ROWS * diff.row_height(),
			"and scrolls on from its end")


## Tiles next to the visible ones are rendered on the next frames, then the
## minimap stops processing: a standalone diff of 2000 rows.
func _test_prefetch() -> void:
	var diff: DiffView = DiffView.new()
	add_child(diff)
	diff.position = Vector2.ZERO
	diff.size = Vector2(1200, 600)
	diff.source = func(start: int, count: int) -> Array:
		var rows: Array = []
		for n: int in range(start, mini(start + count, 2000)):
			rows.append({"index": n, "kind": DiffView.KIND_CONTEXT, "old": n + 1, "new": n + 1, "text": "line"})
		return rows
	var rendered: Array[int] = []
	diff.set_minimap_sources(
		func(_split: bool, first: int, rows: int, columns: int, row_px: int, _char_px: int,
				_palette: PackedColorArray) -> PackedByteArray:
			rendered.append(floori(first / float(DiffMinimap.TILE_ROWS)))
			var bytes: PackedByteArray = PackedByteArray()
			bytes.resize(columns * rows * row_px * 4)
			return bytes,
		func(_split: bool, buckets: int) -> PackedByteArray:
			var flags: PackedByteArray = PackedByteArray()
			flags.resize(buckets)
			return flags)
	diff.show_lines(2000, 2000, false)
	var minimap: DiffMinimap = diff.minimap()
	expect(await wait_until(func() -> bool: return minimap.has_tile(2) and not minimap.is_processing(), 2000),
			"the tile below the visible ones is rendered ahead (rendered %s)" % [rendered])
	expect(minimap.has_tile(0) and minimap.has_tile(1), "the visible tiles are drawn")
	diff.set_scroll_offset(diff.max_scroll_offset() / 2.0)
	expect(await wait_until(func() -> bool: return minimap.has_tile(5) and not minimap.is_processing(), 2000),
			"scrolled to the middle, the next tile is rendered ahead (rendered %s)" % [rendered])
	expect(not minimap.has_tile(7), "tiles further away are not")
	diff.queue_free()


func _hover(target: Control, at: Vector2) -> void:
	var event: InputEventMouseMotion = InputEventMouseMotion.new()
	event.position = at
	target._gui_input(event)


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
