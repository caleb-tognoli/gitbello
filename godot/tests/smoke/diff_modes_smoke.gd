extends SmokeTest
## M7.8 P1: each diff offers its modes (`diff_info`'s `viewer` and `modes`),
## the header picker shows only for two or more, a file without the saved
## mode falls back without saving, Ctrl+Shift+D cycles and saves per viewer,
## and every panel follows. Deletes a file in `repo-15` (throwaway fixture).
## Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("diff_modes_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-15")
	expect(Core.set_diff_mode("text", "split"), "the text mode saves")
	expect(not Core.set_diff_mode("text", "onion"), "an image mode is not a text mode")
	expect(not Core.set_diff_mode("image", "unified"), "a text mode is not an image mode")
	expect_eq(Core.diff_mode("text"), "split", "the saved text mode reads back")
	expect_eq(Core.diff_mode("image"), "split", "images start split")
	DirAccess.remove_absolute(repo.path_join("README.md"))

	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var panel: DiffPanel = changes.diff_panel()
	expect(await wait_until(func() -> bool: return session.change_count() == 3), "modified, untracked and deleted files")

	# A modified file offers both text modes and opens in the saved one.
	expect(await _select(changes, session, "app.txt"), "app.txt's diff loads")
	expect_eq(panel.viewer(), "text", "text is drawn by the text viewer")
	expect_eq(panel.modes(), PackedStringArray(["unified", "split"]), "a modified file offers both modes")
	expect(panel.picker_visible(), "the picker shows for two modes")
	expect(panel.mode() == "split" and panel.view().side_by_side, "it opens in the saved mode")
	expect(panel.mode_button("split").button_pressed and not panel.mode_button("unified").button_pressed,
			"the saved mode's button is chosen")
	expect(panel.mode_button("split").tooltip_text.contains(Shortcuts.display("Ctrl+Shift+D")), "the tooltip names the cycle shortcut")
	expect(Actions.is_enabled(&"diff.cycle_mode"), "the cycle action is enabled")

	# New and deleted files offer unified only: no picker, no saving.
	expect_eq(panel.counts_text(), "+1 −1", "both counts show when both are non-zero")
	for path: String in ["notes.txt", "README.md"]:
		expect(await _select(changes, session, path), "%s's diff loads" % path)
		expect_eq(panel.counts_text(), "+1" if path == "notes.txt" else "−1", "a zero count is left out for %s" % path)
		expect_eq(panel.modes(), PackedStringArray(["unified"]), "%s offers unified only" % path)
		expect(not panel.picker_visible() and panel.mode_button("unified") == null, "%s shows no picker" % path)
		expect(panel.mode() == "unified" and not panel.view().side_by_side, "%s falls back to unified" % path)
		expect_eq(Core.diff_mode("text"), "split", "the fallback leaves the saved mode alone")
		expect(not Actions.is_enabled(&"diff.cycle_mode"), "nothing to cycle for %s" % path)
		press("Ctrl+Shift+D")
		expect_eq(Core.diff_mode("text"), "split", "Ctrl+Shift+D does nothing for %s" % path)

	# Back on the modified file, the saved mode comes back; the key cycles.
	expect(await _select(changes, session, "app.txt"), "app.txt again")
	expect(panel.mode() == "split" and panel.view().side_by_side, "the saved mode comes back")
	press("Ctrl+Shift+D")
	expect(panel.mode() == "unified" and not panel.view().side_by_side, "Ctrl+Shift+D cycles to unified")
	expect_eq(Core.diff_mode("text"), "unified", "and saves it")
	expect(panel.mode_button("unified").button_pressed, "the picker follows the key")
	press("Ctrl+Shift+D")
	expect_eq(panel.mode(), "split", "Ctrl+Shift+D wraps")

	# A mode chosen in History applies to the Changes diff too.
	page.show_view(WorktreeView.View.HISTORY)
	var details: CommitDetails = page.history().details()
	var history_panel: DiffPanel = details.diff_panel()
	var commits: CommitList = page.history().commit_list()
	expect(await wait_until(func() -> bool: return commits.row_count() == 3), "three commits")
	commits.select_only(0)
	expect(await wait_until(func() -> bool: return history_panel.picker_visible()), "a modified file in a commit has the picker")
	expect_eq(history_panel.mode(), "split", "History opens in the saved mode")
	var unified: Button = history_panel.mode_button("unified")
	unified.button_pressed = true
	unified.pressed.emit()
	expect(history_panel.mode() == "unified" and not history_panel.view().side_by_side, "the button switches to unified")
	expect_eq(Core.diff_mode("text"), "unified", "the button saves the mode")
	expect(panel.mode() == "unified" and not panel.view().side_by_side, "the Changes diff follows")
	unified.pressed.emit()
	expect_eq(history_panel.mode(), "unified", "pressing the chosen mode again keeps it")
	# The commit that added app.txt: unified only.
	commits.select_only(1)
	var added_shown: Callable = func() -> bool:
		var info: Dictionary = session.commit_diff_info()
		return String(info.get("state", "")) == "ready" and String(info.get("code", "")) == "A"
	expect(await wait_until(added_shown), "an added file in a commit")
	await get_tree().process_frame
	expect(not history_panel.picker_visible(), "an added file in a commit has no picker")

	# The View menu no longer has the side-by-side toggle.
	var menu_labels: PackedStringArray = main.menu_bar().labels("View")
	expect(not menu_labels.has("Side-by-side diff") and not menu_labels.has("Next diff mode"),
			"the View menu has no mode entry: %s" % [menu_labels])
	expect_eq(Actions.shortcut_label(&"diff.cycle_mode"), Shortcuts.display("Ctrl+Shift+D"), "the cycle action keeps Ctrl+Shift+D")
	expect(Actions.get_action(&"diff.toggle_side_by_side") == null, "the old toggle is gone")

	Core.set_diff_mode("text", "unified")
	main.queue_free()
	await get_tree().process_frame


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
