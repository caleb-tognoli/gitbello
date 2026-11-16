extends SmokeTest
## The Markdown diff's Preview mode on the CLI's `markdown` fixture: a
## Markdown file offers unified, split and preview (an untracked one unified
## and preview, a text file neither), Preview draws the document with its
## changed blocks and words, folds the unchanged blocks far from a change
## into gaps (opened by their buttons, a heading link or Whole file), is
## saved for Markdown only, F7 moves between the
## changes, code is coloured by the syntax system, the repository's picture
## is drawn (a missing and a web one stay text), a heading link scrolls and a
## file link selects that file, the scroll strip marks every change and
## scrolls, the lines come back in Unified, and History's diff follows.
## Read-only on the repository. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("markdown_preview_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("markdown")
	var text_mode: String = Core.diff_mode("text")
	expect_eq(Core.diff_mode("markdown"), "unified", "Markdown starts unified")
	expect(not Core.set_diff_mode("text", "preview"), "preview is no text mode")
	expect(not Core.set_diff_mode("markdown", "onion"), "an image mode is no Markdown mode")

	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var panel: DiffPanel = changes.diff_panel()
	var preview: MarkdownDiffView = panel.markdown_view()
	expect(await wait_until(func() -> bool: return session.change_count() == 3), "README.md, notes.txt and docs/guide.md")

	# A modified Markdown file: three modes, the lines first.
	expect(await _select(changes, session, "README.md"), "README.md's diff loads")
	expect_eq(panel.viewer(), "markdown", "Markdown has its own viewer")
	expect_eq(panel.modes(), PackedStringArray(["unified", "split", "preview"]), "a modified Markdown file offers three modes")
	expect(panel.mode_button("preview") != null, "the picker has Preview")
	expect(panel.mode_button("preview").tooltip_text.begins_with(tr("Preview")), "Preview's tooltip names it")
	expect(panel.view().visible and not preview.visible, "the lines show in Unified")

	# Preview: the document with its changes.
	panel.choose_mode("preview")
	expect_eq(Core.diff_mode("markdown"), "preview", "Preview is saved for Markdown")
	expect_eq(Core.diff_mode("text"), text_mode, "the text mode stays")
	expect(preview.visible and not panel.view().visible, "Preview replaces the lines")

	# Folded: each change with a block of context and its section's heading;
	# items 4-6 and the five blocks after the last change hide in gaps.
	var folded: Dictionary = session.diff_info().get("markdown", {})
	expect_eq(int(folded.get("total", 0)), 19, "the document has 19 blocks")
	expect_eq(int(folded.get("blocks", 0)), 13, "eleven blocks and two gaps show")
	expect(bool(folded.get("can_expand", false)), "some blocks are folded")
	expect_eq(preview.block_count(), 13, "every row is fetched")
	expect_eq(preview.gap_rows(), PackedInt64Array([4, 12]), "a gap between the changes and one at the end")
	expect_eq(preview.changes(), PackedInt64Array([2, 6, 7, 10]), "the changed rows")
	expect_eq(preview.gap_label(4), tr("%d blocks hidden") % 3, "the first gap hides three items")
	expect_eq(preview.gap_label(12), tr("%d blocks hidden") % 5, "the last hides five blocks")
	expect(await wait_until(func() -> bool: return preview.built_count() == 13), "every row is built")
	expect_eq((preview.block_control(4).find_children("*", "Button", true, false) as Array).size(), 1,
			"a small gap opens at once")
	expect(not preview.press_expander(4, "up"), "and has no step buttons")
	expect(panel.whole_file_button().visible and not panel.whole_file_button().button_pressed,
			"Whole file shows in Preview")
	expect(panel.can_toggle_whole_file(), "Whole file can be turned on")
	panel.toggle_whole_file()
	expect(await wait_until(func() -> bool: return preview.block_count() == 19), "Whole file shows every block")
	expect(preview.gap_rows().is_empty() and panel.whole_file_button().button_pressed, "with no gaps")
	panel.toggle_whole_file()
	expect(await wait_until(func() -> bool: return preview.block_count() == 13), "turned off, the gaps fold again")
	expect(preview.scroll_to_anchor("logo"), "a link to the folded Logo heading")
	expect(await wait_until(func() -> bool: return preview.block_count() == 17), "opens the gap it is in")
	expect(await wait_until(func() -> bool: return preview.scroll_vertical > 0), "and scrolls to it")
	preview.scroll_vertical = 0
	expect(preview.press_expander(4, "all"), "the first gap's button")
	expect(await wait_until(func() -> bool: return preview.block_count() == 19), "opens the three items")
	expect(not bool((session.diff_info().get("markdown", {}) as Dictionary).get("can_expand", true)), "nothing is folded")

	var info: Dictionary = session.diff_info()
	var markdown: Dictionary = info.get("markdown", {})
	expect_eq(int(markdown.get("blocks", 0)), 19, "the preview has 19 blocks")
	expect_eq(preview.block_count(), 19, "every block is fetched")
	expect_eq(preview.changes(), PackedInt64Array([2, 8, 9, 12]), "the renamed heading, the added item, the quote and the removed paragraph changed")
	expect(await wait_until(func() -> bool: return preview.built_count() == 19), "every block is built")
	await get_tree().process_frame

	# The scroll strip: a mark per changed block, in order, and a thumb.
	var strip: MarkdownStrip = preview.scroll_strip()
	expect(strip.visible and strip.size.x > 0.0 and strip.size.y > 0.0, "the strip shows beside the preview")
	expect(not preview.get_v_scroll_bar().visible, "the strip replaces the scroll bar")
	var marks: PackedFloat32Array = preview.change_marks()
	var kinds: PackedInt32Array = PackedInt32Array()
	var ordered: bool = true
	for i: int in range(0, marks.size(), 3):
		kinds.append(int(marks[i + 2]))
		ordered = ordered and marks[i] < marks[i + 1] and (i == 0 or marks[i] >= marks[i - 2])
	expect_eq(kinds, PackedInt32Array([MarkdownDiffView.MARK_CHANGED, MarkdownDiffView.MARK_ADDED,
			MarkdownDiffView.MARK_CHANGED, MarkdownDiffView.MARK_REMOVED]), "the heading, item, quote and paragraph are marked")
	expect(ordered and marks[marks.size() - 2] <= preview.content_height(), "the marks follow the document")
	if preview.content_height() > preview.size.y:
		expect(strip.thumb().y > 0.0, "the thumb shows what is on screen")
		var click: InputEventMouseButton = InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = Vector2(2.0, strip.size.y - 1.0)
		strip._gui_input(click)
		click.pressed = false
		strip._gui_input(click)
		expect_eq(preview.scroll_vertical, int(preview.content_height() - preview.size.y), "a click at the bottom scrolls to the end")
		expect(strip.thumb().x > 0.0, "the thumb follows")
		var wheel: InputEventMouseButton = InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_UP
		wheel.pressed = true
		strip._gui_input(wheel)
		expect(preview.scroll_vertical < int(preview.content_height() - preview.size.y), "the wheel scrolls up")
		preview.scroll_vertical = 0
	else:
		expect_eq(strip.thumb().y, 0.0, "no thumb when the document fits")
	var blocks: Array = session.markdown_blocks("changes", 0, 19)
	expect_eq(String((blocks[2] as Dictionary)["change"]), "changed", "the renamed heading is one changed block")
	expect_eq(String((blocks[8] as Dictionary)["change"]), "added", "the new list item is added")
	expect_eq(String((blocks[8] as Dictionary)["marker"]), "bullet", "with its bullet")
	expect_eq(String((blocks[12] as Dictionary)["change"]), "removed", "the old paragraph is removed")
	expect_eq(String((blocks[6] as Dictionary)["marker"]), "task", "a task item")
	expect(bool((blocks[6] as Dictionary)["checked"]), "ticked")
	expect_eq(String((blocks[10] as Dictionary)["kind"]), "table", "the table")
	expect_eq(String((blocks[11] as Dictionary)["info"]), "rust", "the code block's language")
	var code_line: Dictionary = ((blocks[11] as Dictionary)["lines"] as Array)[0] as Dictionary
	var tokens: PackedInt32Array = code_line["syntax"]
	expect(tokens.size() >= 3 and tokens[0] == 0 and tokens[1] == 2, "`fn` is a token of the code's first line: %s" % [tokens])

	# The repository's picture is drawn; a missing and a web one stay text.
	expect_eq(String((blocks[16] as Dictionary)["anchor"]), "logo", "the heading's anchor")
	var pictures: Array = (blocks[17] as Dictionary)["spans"]
	var indices: PackedInt64Array = PackedInt64Array()
	for span: Variant in pictures:
		if int((span as Dictionary)["style"]) & MarkdownDiffView.IMAGE != 0:
			indices.append(int((span as Dictionary)["image"]))
	expect_eq(indices, PackedInt64Array([0, 1, -1]), "the logo and the missing file are repository pictures, the web one is not")
	expect(await wait_until(func() -> bool:
		return bool((session.diff_info().get("markdown", {}) as Dictionary).get("images_ready", false))),
		"core reads the pictures")
	expect(not session.markdown_image("changes", 0).is_empty(), "the logo was read")
	expect(session.markdown_image("changes", 1).is_empty(), "the missing picture was not")
	expect(await wait_until(func() -> bool: return preview.block_picture_count(17) == 1), "the logo is drawn")
	expect(preview.block_text(17).contains("[Missing]") and preview.block_text(17).contains("[Web]"),
			"the others show their text")

	# Links: a heading of the document scrolls to it.
	var link_spans: Array = (blocks[18] as Dictionary)["spans"]
	var targets: PackedStringArray = PackedStringArray()
	for span: Variant in link_spans:
		var part: Dictionary = span as Dictionary
		if not String(part["target"]).is_empty():
			targets.append("%s:%s%s" % [part["target"], part["path"], part["anchor"]])
	expect_eq(targets, PackedStringArray(["file:docs/guide.md", "anchor:logo"]), "the links' targets")
	preview.scroll_vertical = 0
	expect(preview.scroll_to_anchor("logo"), "the heading is found")
	expect(await wait_until(func() -> bool: return preview.scroll_vertical > 0), "the preview scrolls to it")
	expect(not preview.scroll_to_anchor("nowhere"), "an unknown anchor goes nowhere")
	for frame: int in MarkdownDiffView.FOLLOW_FRAMES + 2:
		await get_tree().process_frame
	preview.scroll_vertical = 0
	await get_tree().process_frame
	var quote: Dictionary = blocks[9] as Dictionary
	expect_eq(int(quote["quote"]), 1, "the quote's depth")
	var marked: PackedStringArray = PackedStringArray()
	for span: Variant in quote["spans"]:
		var part: Dictionary = span as Dictionary
		if String(part["change"]) != "same":
			marked.append("%s:%s" % [part["change"], part["text"]])
	expect_eq(marked, PackedStringArray(["added:only ", "removed:shows", "added:draws"]), "the quote's changed words")
	expect(preview.block_text(9).contains("shows") and preview.block_text(9).contains("draws"), "both words show in the quote")
	expect(not panel.whole_file_button().visible, "no whole-file button once every gap is open")
	expect(not panel.can_toggle_whole_file(), "nothing to expand")
	await get_tree().process_frame
	expect(preview.block_control(0).size.y > preview.block_control(1).size.y * 0.8, "the title is drawn large")

	# F7 / Shift+F7 move between the changed blocks.
	expect(Actions.is_enabled(&"diff.next_change"), "Next change is enabled in Preview")
	Actions.run_action(&"diff.next_change")
	expect_eq(preview.current_change(), 2, "F7 goes to the first change")
	await get_tree().process_frame
	await get_tree().process_frame
	Actions.run_action(&"diff.next_change")
	expect_eq(preview.current_change(), 8, "F7 again goes to the next one")
	Actions.run_action(&"diff.previous_change")
	expect_eq(preview.current_change(), 2, "Shift+F7 goes back")

	# A text file has no preview; the saved Markdown mode does not touch it.
	expect(await _select(changes, session, "notes.txt"), "notes.txt's diff loads")
	expect_eq(panel.viewer(), "text", "a text file has the text viewer")
	expect_eq(panel.modes(), PackedStringArray(["unified", "split"]), "and no preview")
	expect(panel.view().visible and not preview.visible, "its lines show")
	expect_eq(panel.mode(), text_mode, "in the saved text mode")

	# A link to a listed file selects it.
	preview.file_link_clicked.emit("docs/guide.md", "")
	expect(await wait_until(func() -> bool:
		var shown: Dictionary = session.diff_info()
		return String(shown.get("path", "")) == "docs/guide.md" and String(shown.get("state", "")) == "ready"),
		"the guide link selects the guide")

	# An untracked Markdown file: its document, nothing marked.
	expect(await _select(changes, session, "docs/guide.md"), "the untracked guide's diff loads")
	expect_eq(panel.modes(), PackedStringArray(["unified", "preview"]), "a new Markdown file offers unified and preview")
	expect(preview.visible, "it opens in the saved Preview")
	expect_eq(preview.block_count(), 4, "the guide's blocks")
	expect(preview.changes().is_empty(), "nothing is marked in a new file")
	expect(not Actions.is_enabled(&"diff.next_change") or _focused(), "no change to move to")

	# Back to Unified: the lines again.
	expect(await _select(changes, session, "README.md"), "README.md again")
	expect(preview.visible, "README.md opens in Preview")
	press("Ctrl+Shift+D")
	expect_eq(panel.mode(), "unified", "Ctrl+Shift+D wraps to Unified")
	expect(panel.view().visible and not preview.visible, "the lines are back")
	expect(panel.view().row_count() > 0, "with their rows")
	expect_eq(preview.block_count(), 0, "the preview is cleared")
	panel.choose_mode("preview")

	# History's diff follows the saved mode.
	page.show_view(WorktreeView.View.HISTORY)
	var details: CommitDetails = page.history().details()
	var history_panel: DiffPanel = details.diff_panel()
	var commits: CommitList = page.history().commit_list()
	expect(await wait_until(func() -> bool: return commits.row_count() == 2), "two commits")
	commits.select_only(0)
	expect(await wait_until(func() -> bool: return history_panel.markdown_view().block_count() > 0), "the commit's README shows its preview")
	expect_eq(history_panel.mode(), "preview", "History opens in Preview")
	var committed: MarkdownDiffView = history_panel.markdown_view()
	expect_eq(committed.changes().size(), 5, "the reworded line, the ticked task, the table, the code and the new paragraph")

	Core.set_diff_mode("markdown", "unified")
	main.queue_free()
	await get_tree().process_frame


func _focused() -> bool:
	return get_viewport().gui_get_focus_owner() is DiffView


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
		return String(info.get("path", "")) == path and String(info.get("state", "")) == "ready" \
				and changes.diff_panel().modes() == PackedStringArray(info.get("modes", PackedStringArray())))
