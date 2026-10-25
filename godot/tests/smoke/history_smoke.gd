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
	list.grab_focus()
	press("Down")
	expect_eq(list.cursor, 0, "Down selects the newest commit")
	expect(await wait_until(func() -> bool: return details.summary_text() == "Improve app"),
			"details show the newest commit: %s" % details.summary_text())
	var diff: DiffView = details.diff_panel().view()
	expect(await wait_until(_diff_has.bind(diff, "v2")), "first file's diff is shown")
	expect_eq(history.status_text(), "3 commits", "the status line has no load time")
	var first_code: String = String(details.file_list().row(0).get("code", ""))
	expect(not first_code.is_empty(), "the first file has a status code")
	expect_eq(details.diff_panel().status_code(), first_code, "the diff header shows the file's status icon")
	expect(details.body_text().is_empty(), "a one-line message has no body")
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

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _diff_has(diff: DiffView, needle: String) -> bool:
	for i: int in diff.row_count():
		if diff.line_text(i).contains(needle):
			return true
	return false
