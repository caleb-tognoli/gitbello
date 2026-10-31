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
	expect(not main.current_page().changes().commit_box().can_amend(), "an unborn repository cannot enter amend mode")
	expect(not Actions.is_enabled(&"commit.amend"), "Amend is unavailable without HEAD")

	Actions.run_action(&"repo.add")
	dialog.show_mode(AddRepositoryDialog.OPEN)
	expect(not dialog.submit(), "open requires an existing folder")
	_set_line(dialog, "existing", fixtures.path_join("repo-1"))
	expect(dialog.submit(), "open existing submits")
	expect_eq(main.tab_count(), 2, "existing repository opens")
	expect(main.current_page().repo_path().ends_with("repo-1"), "the selected existing repository opens")

	Actions.run_action(&"repo.add")
	dialog.show_mode(AddRepositoryDialog.CLONE)
	_test_progress(dialog)
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


func _test_progress(dialog: AddRepositoryDialog) -> void:
	var bar: ProgressBar = dialog._progress
	dialog._start_job(190019)
	expect(bar.visible and bar.indeterminate, "clone starts indeterminate before any progress")
	dialog._on_job_progress(190018, "", "", 50, "Unrelated job")
	expect(bar.indeterminate, "another job cannot change clone progress")
	expect_eq(dialog.job_status(), "Cloning repository…", "another job cannot change clone status")
	dialog._on_job_progress(190019, "", "", -1, "Enumerating objects: 5, done.")
	expect(bar.indeterminate, "unknown percentage stays indeterminate")
	dialog._on_job_progress(190019, "", "", 0, "Receiving objects: 0% (0/10)")
	expect(not bar.indeterminate, "zero is a known percentage")
	expect_eq(bar.value, 0.0, "known zero is preserved")
	dialog._on_job_progress(190019, "", "", 45, "Receiving objects: 45%")
	expect_eq(bar.value, 45.0, "known percentage is displayed")
	dialog._on_job_progress(190019, "", "", 100, "Receiving objects: 100%")
	expect(dialog.running(), "phase completion does not finish the clone")
	dialog._on_job_progress(190019, "", "", 0, "Resolving deltas: 0%")
	expect(not bar.indeterminate and bar.value == 0.0, "new phase can reset to known zero")
	expect_eq(dialog.job_status(), "Resolving deltas: 0%", "phase text follows the progress event")
	dialog._on_job_progress(190019, "", "", -1, "Enumerating objects: 8, done.")
	expect(bar.indeterminate, "unknown after known returns to indeterminate")
	dialog._on_job_cancelled(190018, "", "")
	expect(dialog.running(), "another job cannot cancel the clone")
	dialog._on_job_cancelled(190019, "", "")
	expect(not dialog.running() and not bar.visible, "cancel acknowledgement hides progress")
	expect(not bar.indeterminate and bar.value == 0.0, "cancel clears progress state")
	expect(not dialog._status.visible, "cancel acknowledgement hides status")
	dialog._on_job_progress(190019, "", "", 99, "Late progress")
	expect(not bar.visible and bar.value == 0.0, "late progress from cancelled job is ignored")
	dialog._start_job(190020)
	expect(bar.indeterminate and bar.value == 0.0, "retry starts fresh and indeterminate")
	dialog._on_job_finished(190020, "", "", false, {"message": "Fixture failure"})
	expect(not dialog.running() and not bar.visible, "failure hides progress")
	expect(not bar.indeterminate and bar.value == 0.0, "failure clears progress state")
	expect_eq(dialog.job_status(), "Fixture failure", "failure stays inline")
	expect(not dialog.get_ok_button().disabled or not dialog.error_text().is_empty(),
			"failure returns to normal form validation")
	dialog._start_job(190021)
	expect(bar.indeterminate and bar.value == 0.0, "retry after failure starts indeterminate")
	dialog._on_job_cancelled(190021, "", "")


func _set_line(dialog: AddRepositoryDialog, key: String, text: String) -> void:
	var line: LineEdit = dialog.field(key) as LineEdit
	line.text = text
	line.text_changed.emit(text)
