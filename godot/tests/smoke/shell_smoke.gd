extends SmokeTest
## M3 acceptance: five repositories open in tabs with live badges that update
## after changes made outside the app. Uses the fixture repositories that
## `cargo xtask smoke` creates (`-- --fixtures=<dir>`); skipped without them.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000

var _fixtures: String = ""


func run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--fixtures="):
			_fixtures = arg.trim_prefix("--fixtures=")
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
			if int(main.page_at(i).session.badge().get("changed", 0)) != 2:
				return false
		return true)
	expect(ready, "every tab reports 2 changed files")
	var title: String = main.tab_bar().get_tab_title(0)
	expect(title.begins_with("repo-1 · main"), "tab title has repo and branch: %s" % title)
	expect(title.ends_with("2 ↑1"), "tab title has the badge: %s" % title)

	# A change made outside the app arrives through the watcher.
	var file: FileAccess = FileAccess.open(repos[0].path_join("from outside.txt"), FileAccess.WRITE)
	file.store_string("x")
	file.close()
	var updated: bool = await _wait(func() -> bool:
		return main.tab_bar().get_tab_title(0).ends_with("3 ↑1"))
	expect(updated, "badge updates after an outside change: %s" % main.tab_bar().get_tab_title(0))

	_check_sidebar(main.page_at(0).sidebar())
	await _check_graph(main.page_at(0))

	# Reorder: move the first tab to the end.
	main.tab_bar().current_tab = 0
	main.tab_bar().move_tab(0, 4)
	main.tab_bar().current_tab = 4
	main._on_tab_rearranged(4)
	expect(main.page_at(4).repo_path().ends_with("repo-1"), "page order follows the tab bar")
	expect(Core.saved_tabs()[4].ends_with("repo-1"), "reordered tabs are saved")

	expect(Actions.run_action(&"tab.close"), "close tab action runs")
	expect_eq(main.tab_count(), 4, "four tabs after closing one")
	expect_eq(Core.saved_tabs().size(), 4, "closed tab removed from saved tabs")

	expect(main.git_log().row_count() > 0, "git log panel lists commands")

	main.palette().open()
	main.palette().set_query("close tab")
	var labels: PackedStringArray = main.palette().visible_labels()
	expect(not labels.is_empty() and labels[0] == "Tabs: Close tab", "palette ranks Close tab first: %s" % [labels])
	main.palette().set_query("go to tab repo-3")
	labels = main.palette().visible_labels()
	expect(not labels.is_empty() and labels[0].begins_with("Go to tab: repo-3"), "palette lists tabs: %s" % [labels])
	main.palette().close()

	# A folder that is not a repository opens a tab with an error and a toast.
	var plain: String = _fixtures.path_join("not a repo")
	DirAccess.make_dir_recursive_absolute(plain)
	var broken: RepoTab = main.open_repo(plain)
	var errored: bool = await _wait(func() -> bool: return broken.has_error() and main.toasts().toast_count() > 0)
	expect(errored, "non-repository shows an error and a toast")
	main.close_tab(main.tab_count() - 1)

	expect(Actions.run_action(&"view.theme_light"), "light theme action runs")
	expect(main.theme == ThemeManager.LIGHT, "light theme applied")
	var tree_bg: StyleBoxFlat = main.page_at(0).sidebar().get_theme_stylebox(&"panel", &"Tree") as StyleBoxFlat
	expect(tree_bg != null and tree_bg.bg_color.get_luminance() > 0.5, "light theme reaches the sidebar")
	Actions.run_action(&"view.theme_dark")
	expect(main.theme == ThemeManager.DARK, "dark theme applied")
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


func _check_sidebar(sidebar: RepoSidebar) -> void:
	var branches: PackedStringArray = sidebar.section_texts(RepoSidebar.Section.BRANCHES)
	expect("feature" in branches and "  login" in branches, "branches grouped by prefix: %s" % [branches])
	expect("● main  [↑1]" in branches, "current branch marked with tracking: %s" % [branches])
	var remotes: PackedStringArray = sidebar.section_texts(RepoSidebar.Section.REMOTES)
	expect("origin" in remotes and "  main" in remotes, "remote branches listed: %s" % [remotes])
	expect(sidebar.section_texts(RepoSidebar.Section.TAGS).size() == 1, "one tag")
	var stashes: PackedStringArray = sidebar.section_texts(RepoSidebar.Section.STASHES)
	expect(stashes.size() == 1 and stashes[0].begins_with("work in progress"), "stash listed: %s" % [stashes])
	var worktrees: PackedStringArray = sidebar.section_texts(RepoSidebar.Section.WORKTREES)
	expect_eq(worktrees.size(), 2, "two worktrees")
	var changes: PackedStringArray = sidebar.section_texts(RepoSidebar.Section.CHANGES)
	expect(changes.size() >= 2, "changed files listed: %s" % [changes])


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
