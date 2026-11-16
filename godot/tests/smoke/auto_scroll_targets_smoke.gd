extends SmokeTest
## Middle-click autoscroll reaches the app's long texts without any of them
## opting in: the commit box's description and hook output, History's commit
## message and the Markdown preview, each overflowing and scrolling. Uses the
## CLI's `markdown` fixture (read-only). Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _mouse: Vector2 = Vector2.ZERO
var _mouse_entered: bool = false


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("auto_scroll_targets_smoke: no --fixtures, skipped")
		return
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var auto: AutoScroll = AutoScroll.of(get_viewport())
	expect(auto != null, "the app's window has its AutoScroll")
	if auto == null:
		main.queue_free()
		return
	var page: RepoTab = main.open_repo(fixtures.path_join("markdown"))
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.is_ready()), "the repository opens")
	var lines: String = "\n".join(PackedStringArray(range(200).map(func(i: int) -> String: return "Line %d" % i)))

	# Changes: the commit box's description and hook output.
	page.show_view(WorktreeView.View.CHANGES)
	await get_tree().process_frame
	var changes: ChangesView = page.changes()
	var body: TextEdit = changes.find_child("Body", true, false) as TextEdit
	var output: TextEdit = changes.find_child("Output", true, false) as TextEdit
	expect(body != null and output != null, "the commit box has a description and an output")
	if body != null and output != null:
		body.text = lines
		output.text = lines
		output.show()
		await get_tree().process_frame
		await get_tree().process_frame
		await _expect_scrolls(auto, body, func() -> float: return body.scroll_vertical, "the commit description")
		await _expect_scrolls(auto, output, func() -> float: return output.scroll_vertical, "the hook output")
		output.hide()
		body.text = ""

	# History: the commit message.
	page.show_view(WorktreeView.View.HISTORY)
	var history: HistoryView = page.history()
	expect(await wait_until(func() -> bool: return history.commit_list().cursor >= 0), "History selects a commit")
	var header: CommitHeader = history.details().header()
	# The long message below must not be replaced by the commit's own when its
	# details land late (slow runners).
	expect(await wait_until(func() -> bool:
		return (header.commit_oid() == history.commit_list().hash_at(history.commit_list().cursor)
				and not header.summary_text().is_empty())), "the selected commit's details load")
	await get_tree().process_frame
	var message: RichTextLabel = header.find_child("Body", true, false) as RichTextLabel
	expect(message != null, "the commit details have a message")
	if message != null:
		# A long message, as a commit's body shows (the fixture's are short).
		header._show_body(lines)
		await get_tree().process_frame
		await get_tree().process_frame
		await _expect_scrolls(auto, message, func() -> float: return message.get_v_scroll_bar().value,
				"the commit message")

	# Changes: the Markdown preview of README.md.
	page.show_view(WorktreeView.View.CHANGES)
	var panel: DiffPanel = changes.diff_panel()
	var preview: MarkdownDiffView = panel.markdown_view()
	expect(await wait_until(func() -> bool: return session.change_count() == 3), "the fixture's three changes")
	var row: int = -1
	for i: int in changes.list().row_count():
		if changes.list().path_at(i) == "README.md":
			row = i
	changes.list().select_only(row)
	expect(await wait_until(func() -> bool: return panel.viewer() == "markdown"), "README.md's diff loads")
	panel.choose_mode("preview")
	expect(await wait_until(func() -> bool: return preview.block_count() > 0 and preview.built_count() == preview.block_count()),
			"the preview is built")
	await get_tree().process_frame
	await get_tree().process_frame
	await _expect_scrolls(auto, preview, func() -> float: return float(preview.scroll_vertical), "the Markdown preview")
	panel.choose_mode("unified")
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()


## A middle click at `control`'s upper part autoscrolls `target`; moving down
## scrolls it (`offset` reads how far).
func _expect_scrolls(auto: AutoScroll, target: Control, offset: Callable, what: String) -> void:
	expect_eq(AutoScroll.scroll_axes(target).y, 1, "%s overflows and scrolls" % what)
	var rect: Rect2 = target.get_global_rect()
	var at: Vector2 = rect.position + Vector2(rect.size.x / 2.0, minf(30.0, rect.size.y / 3.0))
	_move(at)
	_button(MOUSE_BUTTON_MIDDLE, true)
	_button(MOUSE_BUTTON_MIDDLE, false)
	expect(auto.is_active() and auto.target() == target,
			"a middle click autoscrolls %s (target: %s, under the mouse: %s)" % [what, auto.target(),
					_path(get_viewport().gui_get_hovered_control())])
	_move(at + Vector2(0.0, 80.0))
	expect(await wait_until(func() -> bool: return float(offset.call()) > 0.0, 3000),
			"moving down scrolls %s (active %s, target %s, still overflows %s)" % [what, auto.is_active(),
					auto.target(), AutoScroll.scroll_axes(target).y == 1])
	auto.stop()


func _path(control: Control) -> String:
	return str(control.get_path()) if control != null else "nothing"


func _move(at: Vector2) -> void:
	if not _mouse_entered:
		get_viewport().notify_mouse_entered()
		_mouse_entered = true
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	motion.relative = at - _mouse
	_mouse = at
	get_viewport().push_input(motion, true)


func _button(index: MouseButton, pressed: bool) -> void:
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = index
	click.pressed = pressed
	click.position = _mouse
	click.global_position = _mouse
	if index == MOUSE_BUTTON_MIDDLE and pressed:
		click.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	get_viewport().push_input(click, true)
