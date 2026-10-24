extends SmokeTest
## M4b: selecting a commit in the history shows its details, files and the
## first file's diff; Right and Left move between list, files and diff.
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
