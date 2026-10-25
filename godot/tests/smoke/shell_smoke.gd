extends SmokeTest
## The shell (M3, reworked in M6.5 P2): five repositories open in tabs with
## live attention dots and worktree chips that update after changes made
## outside the app; worktrees of an open repository open as its chips; the
## menu bar, the palette, the theme, and tabs restored on launch. Uses the
## fixture repositories that `cargo xtask smoke` creates (`-- --fixtures=<dir>`);
## skipped without them.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000

var _fixtures: String = ""


func run() -> void:
	_fixtures = fixtures_dir()
	if _fixtures.is_empty():
		print("shell_smoke: no --fixtures, skipped")
		return

	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	expect_eq(main.tab_count(), 0, "starts with no tabs (empty test config)")

	var repos: PackedStringArray = PackedStringArray()
	for n: int in range(1, 6):
		repos.append(_fixtures.path_join("repo-%d" % n))
		main.open_repo(repos[n - 1])
	expect_eq(main.tab_count(), 5, "five tabs open")
	main.open_repo(repos[0])
	expect_eq(main.tab_count(), 5, "opening an open repo focuses its tab")

	var ready: bool = await _wait(func() -> bool:
		for i: int in main.tab_count():
			if main.page_at(i).worktrees().size() != 2 or int(main.page_at(i).session.badge().get("changed", 0)) != 2:
				return false
		return true)
	expect(ready, "every tab knows its two worktrees and 2 changed files")
	expect_eq(main.tab_bar().get_tab_title(0), "repo-1", "a tab is titled by its repository")
	expect(main.tab_bar().get_tab_icon(0) != null, "a tab with changes has an attention dot")
	expect_eq(main.page_at(0).attention(), RepoTab.Attention.CHANGES, "changed files come first after conflicts")
	expect(main.tab_bar().get_tab_tooltip(0).contains("repo-1-feature"), "the tab's tooltip lists its worktrees")

	var strip: WorktreeStrip = main.page_at(0).strip()
	var chips: Array[WorktreeChip] = strip.chips()
	expect_eq(chips.size(), 2, "two worktree chips")
	if chips.size() == 2:
		expect_eq(chips[0].texts(), {"name": "repo-1", "branch": "main", "badge": "2 ↑1"}, "the main worktree's chip")
		expect(chips[0].selected and not chips[1].selected, "the opened worktree's chip is selected")

	# + follows the last tab, and New worktree the last chip.
	await get_tree().process_frame
	await get_tree().process_frame
	var tabs: TabBar = main.tab_bar()
	var add: Control = main.get_node("%AddButton") as Control
	expect(not tabs.get_offset_buttons_visible(), "the five tabs fit without scroll arrows")
	var tabs_end: float = tabs.global_position.x + tabs.get_tab_rect(tabs.tab_count - 1).end.x
	expect(absf(add.global_position.x - tabs_end) < 16.0,
			"+ sits right after the last tab: %s vs %s" % [add.global_position.x, tabs_end])
	if chips.size() == 2:
		var chips_end: float = chips[1].get_global_rect().end.x
		var new_x: float = strip.new_task_button().global_position.x
		expect(absf(new_x - chips_end) < 16.0, "New worktree sits right after the last chip: %s vs %s" % [new_x, chips_end])

	# A change made outside the app arrives through the watcher.
	var file: FileAccess = FileAccess.open(repos[0].path_join("from outside.txt"), FileAccess.WRITE)
	file.store_string("x")
	file.close()
	var updated: bool = await _wait(func() -> bool:
		var now: Array[WorktreeChip] = main.page_at(0).strip().chips()
		return not now.is_empty() and String(now[0].texts()["badge"]) == "3 ↑1")
	expect(updated, "the chip updates after an outside change")

	# Worktrees: Ctrl+2 shows the second chip in the same tab; opening a
	# worktree's path shows its chip instead of a new tab.
	main.tab_bar().current_tab = 0
	expect(Actions.run_action(&"worktree.select_2"), "Ctrl+2 shows the second worktree")
	var page: RepoTab = main.page_at(0)
	expect(page.active_view().worktree_path().ends_with("repo-1-feature"), "the feature worktree shows")
	expect_eq(page.views().size(), 2, "its view was made on demand")
	expect(Actions.run_action(&"worktree.select_1"), "Ctrl+1 goes back")
	expect(page.active_view().worktree_path().ends_with("repo-1"), "the main worktree shows again")

	# A job that changes a worktree's files dims only that worktree.
	var feature: WorktreeView = page.view_for(_fixtures.path_join("repo-1-feature"))
	page.active_view()._on_job_started(-7, "checkout")
	expect(await wait_until(func() -> bool: return page.active_view().overlay().visible), "the overlay dims the panes")
	expect(not feature.overlay().visible, "the other worktree is not dimmed")
	expect(Actions.run_action(&"worktree.select_2"), "another worktree can be shown meanwhile")
	expect(Actions.run_action(&"worktree.select_1"), "and back")
	page.active_view()._on_job_ended(-7)
	expect(not page.active_view().overlay().visible, "the overlay goes when the job ends")

	# The left column's width is saved per repository.
	var history: HistoryView = page.history()
	history.split_offset = 520
	history.drag_ended.emit()
	expect_eq(int(Core.repo_ui_state(page.key()).get("history_width", 0)), 520, "the history width is saved")
	main.open_repo(_fixtures.path_join("repo-2-feature"))
	expect_eq(main.tab_count(), 5, "a worktree of an open repository opens no tab")
	expect_eq(main.tab_bar().current_tab, 1, "it focuses its repository's tab")
	expect(main.current_view().worktree_path().ends_with("repo-2-feature"), "and shows that worktree")

	await _check_graph(main.page_at(0))
	main.tab_bar().current_tab = 0
	expect(await wait_until(func() -> bool: return main.current_page().session.can_push()), "repo-1 can push")
	_check_menus(main)

	# Reorder: move the first tab to the end.
	main.tab_bar().current_tab = 0
	main.tab_bar().move_tab(0, 4)
	main.tab_bar().current_tab = 4
	main._on_tab_rearranged(4)
	expect(main.page_at(4).repo_path().ends_with("repo-1"), "page order follows the tab bar: %s" % main.page_at(4).repo_path())
	expect(Core.saved_tabs()[4].ends_with("repo-1"), "reordered tabs are saved: %s" % [Core.saved_tabs()])
	expect(Core.saved_tabs()[0].ends_with("repo-2-feature"), "a tab saves its selected worktree")

	expect(Actions.run_action(&"tab.close"), "close tab action runs")
	expect_eq(main.tab_count(), 4, "four tabs after closing one")
	expect_eq(Core.saved_tabs().size(), 4, "closed tab removed from saved tabs")
	expect(Actions.run_action(&"tab.next"), "Ctrl+Tab goes to the next repository")

	expect(main.git_log().row_count() > 0, "git log panel lists commands")

	main.palette().open()
	main.palette().set_query("close tab")
	var labels: PackedStringArray = main.palette().visible_labels()
	expect(not labels.is_empty() and labels[0] == "Tabs: Close tab", "palette ranks Close tab first: %s" % [labels])
	main.palette().set_query("go to repo-3 repo-3-feature")
	labels = main.palette().visible_labels()
	expect(not labels.is_empty() and labels[0] == "Go to: repo-3 · repo-3-feature",
			"palette lists worktrees: %s" % [labels])
	main.palette().close()

	# A folder that is not a repository opens a tab with an error and a toast.
	var plain: String = _fixtures.path_join("not a repo")
	DirAccess.make_dir_recursive_absolute(plain)
	var broken: RepoTab = main.open_repo(plain)
	var errored: bool = await _wait(func() -> bool: return broken.has_error() and main.toasts().toast_count() > 0)
	expect(errored, "non-repository shows an error and a toast")
	main.close_tab(main.tab_count() - 1)

	expect(Actions.run_action(&"view.theme_light"), "light theme action runs")
	expect(ThemeManager.light, "light theme applied")
	var tree_bg: StyleBoxFlat = main.git_log().get_theme_stylebox(&"panel", &"Tree") as StyleBoxFlat
	expect(tree_bg != null and tree_bg.bg_color.get_luminance() > 0.5, "the light theme reaches the panels")
	Actions.run_action(&"view.theme_dark")
	expect(not ThemeManager.light, "dark theme applied")
	Actions.run_action(&"view.theme_system")

	# Restore on launch: a fresh shell reopens the saved tabs.
	main.queue_free()
	await get_tree().process_frame
	var restored: Main = MAIN.instantiate() as Main
	add_child(restored)
	await get_tree().process_frame
	expect_eq(restored.tab_count(), 4, "saved tabs are restored")
	while restored.tab_count() > 0:
		restored.close_tab(0)
	restored.queue_free()
	await get_tree().process_frame


func _check_menus(main: Main) -> void:
	var bar: AppMenuBar = main.menu_bar()
	for title: String in ["File", "Edit", "Repository", "Branch", "View", "Help"]:
		expect(bar.menu(title) != null, "menu %s exists" % title)
	var repository: PackedStringArray = bar.labels("Repository")
	expect("Remotes…" in repository and "Tags…" in repository, "Repository has Remotes… and Tags…: %s" % [repository])
	expect("Push" in repository, "Push is enabled with commits to push: %s" % [repository])
	expect("Undo last discard (disabled)" in bar.labels("Edit"), "a disabled entry shows disabled")
	expect(Actions.disabled_reason(&"changes.undo_discard") != "", "a disabled action says why")
	expect(bar.press("View", "Changes"), "a menu entry runs its action")
	expect_eq(main.current_page().view, WorktreeView.View.CHANGES, "View → Changes shows the changes")
	expect(bar.press("View", "History"), "View → History")


func _check_graph(page: RepoTab) -> void:
	var list: CommitList = page.history().commit_list()
	var loaded: bool = await _wait(func() -> bool: return list.row_count() == 3)
	expect(loaded, "graph has the three commits (got %d)" % list.row_count())
	var rows: Array[Dictionary] = page.session.graph_rows(0, 1)
	var names: PackedStringArray = PackedStringArray()
	if not rows.is_empty():
		for label: Dictionary in rows[0]["refs"]:
			names.append(String(label["name"]))
	expect("main" in names, "newest commit is labelled main: %s" % [names])
	expect(not ("stash" in names), "stash commits stay out of the graph")


## Waits up to WAIT_MS frames for `condition`; returns whether it became true.
func _wait(condition: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await get_tree().process_frame
	return bool(condition.call())
