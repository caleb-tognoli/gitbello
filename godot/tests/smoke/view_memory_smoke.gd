extends SmokeTest
## The Changes | History | Shelves choice follows the user across worktrees
## and repository tabs (read-only on repo-2 and repo-3).

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		return
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var first: RepoTab = main.open_repo(fixtures.path_join("repo-2"))
	var second: RepoTab = main.open_repo(fixtures.path_join("repo-3"))
	expect(await wait_until(func() -> bool:
		return first.session.is_ready() and second.session.is_ready() and not first.session.shelves().is_empty() \
				and not second.session.shelves().is_empty() and second.worktrees().size() == 2), "both repositories load")
	expect_eq(second.view, WorktreeView.View.HISTORY, "a fresh launch starts on History")

	main.tab_bar().current_tab = 0
	first.show_view(WorktreeView.View.CHANGES)
	main.tab_bar().current_tab = 1
	expect_eq(second.view, WorktreeView.View.CHANGES, "another tab shows the view chosen in the last one")

	second.show_view(WorktreeView.View.SHELVES)
	expect(second.select_chip(1), "the linked worktree shows")
	expect(second.active_view().worktree_path().ends_with("repo-3-feature"), "it is the feature worktree")
	expect(await wait_until(func() -> bool: return second.view == WorktreeView.View.SHELVES),
			"a newly opened worktree shows Shelves once its shelves are read")

	second.show_view(WorktreeView.View.HISTORY)
	expect(second.select_chip(0), "the main worktree shows again")
	expect_eq(second.view, WorktreeView.View.HISTORY, "the main worktree follows the linked one's choice")
	main.tab_bar().current_tab = 0
	expect_eq(first.view, WorktreeView.View.HISTORY, "and so does the first tab")

	# A view switched in a hidden worktree does not change the choice.
	second.view_for(fixtures.path_join("repo-3-feature")).show_view(WorktreeView.View.CHANGES)
	expect_eq(WorktreeView.shared_view, WorktreeView.View.HISTORY, "a hidden worktree's switch is not the user's choice")

	# Alt+Page Down/Up go round the shown buttons (no comparison: Compare is
	# skipped), even from the commit list, which uses Page Down itself.
	main.tab_bar().current_tab = 1
	second.history().commit_list().grab_focus()
	var cursor: int = second.history().commit_list().cursor
	var order: Array[WorktreeView.View] = [WorktreeView.View.SHELVES, WorktreeView.View.CHANGES,
			WorktreeView.View.HISTORY]
	for expected: WorktreeView.View in order:
		press("Alt+PageDown")
		expect_eq(second.view, expected, "Alt+PageDown shows the next view")
	expect_eq(second.history().commit_list().cursor, cursor, "the commit list does not page on Alt+PageDown")
	press("Alt+PageUp")
	expect_eq(second.view, WorktreeView.View.CHANGES, "Alt+PageUp goes back")
	press("Alt+PageUp")
	expect_eq(second.view, WorktreeView.View.SHELVES, "and wraps round to the last shown view")
	for entry: Array in [["Alt+1", WorktreeView.View.CHANGES], ["Alt+2", WorktreeView.View.HISTORY],
			["Alt+3", WorktreeView.View.SHELVES]]:
		press(entry[0])
		expect_eq(second.view, entry[1], "%s picks its view" % entry[0])
	press("Alt+4")
	expect_eq(second.view, WorktreeView.View.SHELVES, "Alt+4 does nothing without a fourth view")
	# Alt+number is the button's place in the switch as it shows: with a
	# comparison open Compare is fourth, and the tooltips and menus say so.
	var shown: WorktreeView = second.active_view()
	expect_eq(Actions.shortcut_label(&"view.shelves"), "Alt+3", "Shelves is third")
	expect(Actions.shortcut_label(&"view.compare").is_empty(), "a hidden view has no number")
	shown.open_compare("HEAD~1", "HEAD", false)
	expect_eq(second.view, WorktreeView.View.COMPARE, "a comparison opens")
	expect_eq(Actions.shortcut_label(&"view.compare"), "Alt+4", "Compare is fourth")
	expect(shown.compare_button().tooltip_text.contains("Alt+4"),
			"its tooltip says so: %s" % shown.compare_button().tooltip_text)
	press("Alt+3")
	expect_eq(second.view, WorktreeView.View.SHELVES, "Alt+3 is still Shelves")
	press("Alt+4")
	expect_eq(second.view, WorktreeView.View.COMPARE, "Alt+4 shows the comparison")
	Actions.run_action(&"compare.close")
	expect(Actions.shortcut_label(&"view.compare").is_empty(), "closed, Compare has no number again")

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame
