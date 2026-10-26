extends SmokeTest
## The tab strip's plus creates, opens and clones repositories in one window.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("add_repository_smoke: no --fixtures, skipped")
		return
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	(main.get_node("%AddButton") as Button).pressed.emit()
	var dialog: AddRepositoryDialog = main.add_repository_dialog()
	expect(dialog.visible, "plus opens the add-repository window")
	expect(not dialog.submit(), "create requires a name")
	expect_eq(dialog.error_text(), "Enter a repository name.", "empty create explains the problem")

	_set_line(dialog, "name", "repo-1")
	_set_line(dialog, "location", fixtures)
	expect(not dialog.submit(), "create rejects a nonempty destination")
	_set_line(dialog, "name", "created smöke")
	_set_line(dialog, "branch", "trunk")
	expect(dialog.submit(), "create starts")
	expect(dialog.visible, "create keeps the window open for its job")
	expect(await wait_until(func() -> bool: return main.tab_count() == 1), "created repository opens")
	expect(not dialog.visible, "successful create closes the window")
	expect(await wait_until(func() -> bool:
		return main.current_page().session.is_ready() and main.current_page().session.current_branch() == "trunk"),
			"created repository uses the requested branch")

	Actions.run_action(&"repo.add")
	dialog.show_mode(AddRepositoryDialog.OPEN)
	expect(not dialog.submit(), "open requires an existing folder")
	_set_line(dialog, "existing", fixtures.path_join("repo-1"))
	expect(dialog.submit(), "open existing submits")
	expect_eq(main.tab_count(), 2, "existing repository opens")
	expect(main.current_page().repo_path().ends_with("repo-1"), "the selected existing repository opens")

	Actions.run_action(&"repo.add")
	dialog.show_mode(AddRepositoryDialog.CLONE)
	_set_line(dialog, "url", "https://example.com/owner/suggested.git")
	expect((dialog.field("destination") as LineEdit).text.ends_with("suggested"),
			"clone suggests a destination folder from the URL")
	dialog.pick_folder("destination", fixtures.path_join("picked clone"))
	_set_line(dialog, "url", "https://example.com/owner/other.git")
	expect((dialog.field("destination") as LineEdit).text.ends_with("picked clone"),
			"a picked clone destination is not overwritten")
	_set_line(dialog, "url", fixtures.path_join("definitely missing"))
	_set_line(dialog, "destination", fixtures.path_join("failed clone"))
	expect(dialog.submit(), "clone with a missing source starts")
	expect(await wait_until(func() -> bool:
		return not dialog.running() and dialog.visible and not dialog.job_status().is_empty()),
			"clone failure returns to the form")
	expect(not dialog.job_status().contains("Cloning repository"), "clone failure is shown inline")

	_set_line(dialog, "url", fixtures.path_join("repo-1"))
	_set_line(dialog, "destination", fixtures.path_join("cloned smöke"))
	expect(dialog.submit(), "valid clone starts after a failure")
	expect(await wait_until(func() -> bool: return main.tab_count() == 3), "cloned repository opens")
	expect(main.current_page().repo_path().ends_with("cloned smöke"), "clone destination is opened")
	expect(not dialog.visible, "successful clone closes the window")
	expect(await wait_until(func() -> bool: return main.current_page().session.is_ready()),
			"cloned repository loads")

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _set_line(dialog: AddRepositoryDialog, key: String, text: String) -> void:
	var line: LineEdit = dialog.field(key) as LineEdit
	line.text = text
	line.text_changed.emit(text)
