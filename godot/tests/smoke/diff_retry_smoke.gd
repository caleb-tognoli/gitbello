extends SmokeTest

const MAIN: PackedScene = preload("res://app/main/main.tscn")
var _preview: String = ""
var _baseline: bool = false


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("diff_retry_smoke: no --fixtures, skipped")
		return
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--retry-preview="):
			_preview = arg.trim_prefix("--retry-preview=")
		elif arg == "--retry-baseline":
			_baseline = true
	var repo: String = fixtures.path_join("repo-1")
	var config_path: String = fixtures.path_join("global.gitconfig")
	var config: String = read_file(config_path)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.change_count() == 2 and not session.shelves().is_empty()),
			"fixture is ready")
	expect(await wait_until(func() -> bool: return String(session.commit_diff_info().get("state", "")) == "ready"),
			"initial History diff loaded before inducing failures")
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	expect(await wait_until(func() -> bool: return String(session.diff_info().get("state", "")) == "ready"),
			"initial diff loaded")
	changes.filter_field().set_text("app")
	changes.commit_box().set_message("Keep this draft", "And its description")
	session.pick_all(false)
	var picks: int = session.picked_count()
	await _exercise(page, config_path, config, "changes")
	expect_eq(changes.current_path(), "app.txt", "Changes keeps its highlighted path")
	expect_eq(changes.filter_field().text(), "app", "Changes keeps its filter")
	expect_eq(session.picked_count(), picks, "Retry does not change commit inclusion")
	expect_eq(changes.commit_box().summary(), "Keep this draft", "Retry keeps the draft summary")
	expect_eq(changes.commit_box().body(), "And its description", "Retry keeps the draft body")
	if not _baseline:
		page.show_view(WorktreeView.View.HISTORY)
		var details: CommitDetails = page.history().details()
		expect(await wait_until(func() -> bool: return String(session.commit_diff_info().get("state", "")) == "ready"),
				"History's file diff is ready")
		var commit: Dictionary = page.history().selected_commit()
		var file_cursor: int = details.file_list().cursor
		page.history().search_field().set_text("Update")
		await _exercise(page, config_path, config, "history")
		expect_eq(page.history().selected_commit(), commit, "History keeps its commit")
		expect_eq(details.file_list().cursor, file_cursor, "History keeps its file cursor")
		expect_eq(page.history().search_field().text(), "Update", "History keeps its search")
		page.show_view(WorktreeView.View.SHELVES)
		expect(await wait_until(func() -> bool: return String(session.diff_info().get("state", "")) == "ready"),
				"Shelves' file diff is ready")
		var shelf: Dictionary = changes.selected_shelf()
		var shelf_path: String = changes.selected_shelf_file()
		await _exercise(page, config_path, config, "shelves")
		expect_eq(changes.selected_shelf(), shelf, "Shelves keeps its selected shelf")
		expect_eq(changes.selected_shelf_file(), shelf_path, "Shelves keeps its selected file")
		await _message_states()
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _exercise(page: RepoTab, config_path: String, config: String, mode: String) -> void:
	var session: RepoSession = page.session
	var history: bool = mode == "history"
	var panel: DiffPanel = page.history().details().diff_panel() if history else page.changes().diff_panel()
	var info: Callable = session.commit_diff_info if history else session.diff_info
	var path: String = String(info.call().get("path", ""))
	write_file(config_path, "[invalid-retry-test\n")
	if history:
		session.clear_commit_diff()
		session.select_commit_file(path, false)
		page.history().details()._on_diff_changed()
	else:
		session.clear_diff()
		if mode == "shelves":
			session.select_shelf_file(String(page.changes().selected_shelf()["oid"]), path, false)
		else:
			session.select_change(path, false)
		page.changes()._on_diff_changed()
	expect(await wait_until(func() -> bool: return String(info.call().get("state", "")) == "error"),
			mode + ": a real failed read reaches the panel")
	print("REAL DIFF FAILURE ", mode, " ", info.call())
	expect(panel.message_text().contains("Cannot show this diff."), mode + ": failure is inline")
	if _baseline:
		await _shot(mode + "_error")
		write_file(config_path, config)
		expect(not Actions.is_enabled(&"diff.retry"), "baseline has no retry action")
		print("BASELINE CAPTURED")
		return
	var button: Button = panel.get_node("%RetryButton") as Button
	expect(button.is_visible_in_tree(), mode + ": Retry is visible")
	expect(not (panel.get_node("%LoadAnywayButton") as Button).visible, mode + ": Retry is not Load anyway")
	expect(not panel.whole_file_button().visible, mode + ": stale whole-file control is hidden")
	panel.hide()
	expect(not Actions.is_enabled(&"diff.retry"), mode + ": hidden panel cannot retry")
	panel.show()
	for theme: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + theme))
		await _shot(mode + "_error_" + theme)
	expect(Actions.run_action(&"diff.retry"), mode + ": Retry runs through the registry")
	expect_eq(String(info.call().get("state", "")), "loading", mode + ": retry starts synchronously")
	expect(panel.loading_indicator().is_blocking(), mode + ": retry shows loading immediately")
	expect(not Actions.run_action(&"diff.retry"), mode + ": a second retry cannot run while loading")
	expect(await wait_until(func() -> bool: return String(info.call().get("state", "")) == "error"),
			mode + ": repeated failure can be retried again")
	write_file(config_path, config)
	button.grab_focus()
	press("Enter")
	expect(await wait_until(func() -> bool: return String(info.call().get("state", "")) == "ready"),
			mode + ": pressing Retry recovers the real failed diff")
	expect_eq(String(info.call().get("path", "")), path, mode + ": recovery retains the target")
	expect(not Actions.is_enabled(&"diff.retry"), mode + ": Retry is disabled after recovery")
	expect(not button.visible, mode + ": Retry disappears after recovery")
	for theme: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + theme))
		await _shot(mode + "_recovered_" + theme)


func _message_states() -> void:
	var panel: DiffPanel = load("res://ui/diff_view/diff_panel.tscn").instantiate() as DiffPanel
	add_child(panel)
	await get_tree().process_frame
	var retry: Button = panel.get_node("%RetryButton") as Button
	for state: String in ["none", "loading", "ready"]:
		var info: Dictionary = {"state": state, "path": "f.txt", "kind": "head", "line_count": 0, "max_line": 0}
		panel.show_info(info)
		expect(not retry.visible, state + ": no Retry")
	for content: String in ["binary", "empty", "too_large"]:
		panel.show_info({"state": "ready", "path": "f.txt", "kind": "head", "content": content,
				"old_size": 0, "new_size": 1, "bytes": 100})
		expect(not retry.visible, content + ": no Retry")
		expect_eq((panel.get_node("%LoadAnywayButton") as Button).visible, content == "too_large",
				content + ": Load anyway remains separate")
	panel.queue_free()
	await get_tree().process_frame


func _shot(shot_name: String) -> void:
	if _preview.is_empty():
		return
	for frame: int in 4:
		await get_tree().process_frame
	var path: String = _preview.path_join(shot_name + ".png")
	expect_eq(get_viewport().get_texture().get_image().save_png(path), OK, "screenshot saved")
	print("SHOT ", path)
