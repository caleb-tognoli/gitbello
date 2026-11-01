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
	_check_recent_labels()
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

	var opened: bool = await _wait(func() -> bool:
		for i: int in main.tab_count():
			if main.page_at(i).worktrees().size() != 2 or int(main.page_at(i).session.badge().get("changed", 0)) != 2:
				return false
		return true)
	expect(opened, "every tab knows its two worktrees and 2 changed files")
	expect_eq(main.tab_bar().get_tab_title(0), "repo-1", "a tab is titled by its repository")
	expect(main.tab_bar().get_tab_icon(0) != null, "a tab with changes has an attention dot")
	expect_eq(main.page_at(0).attention(), RepoTab.Attention.CHANGES, "changed files come first after conflicts")
	expect(main.tab_bar().get_tab_tooltip(0).contains("repo-1-feature"), "the tab's tooltip lists its worktrees")

	var strip: WorktreeStrip = main.page_at(0).strip()
	var chips: Array[WorktreeChip] = strip.chips()
	expect_eq(chips.size(), 2, "two worktree chips")
	if chips.size() == 2:
		expect_eq(chips[0].texts(), {"name": "repo-1", "marker": "dot"}, "the main worktree's chip: its folder and a changes dot")
		expect_eq(chips[1].texts()["name"], "feature", "the linked chip leaves out the repository's name")
		expect(chips[0].tooltip_text.contains("2 changed files"), "the chip explains its live changed count")
		expect(chips[0].tooltip_text.contains("1 commit ahead"), "the tooltip has the live ahead count")
		var chip_tooltip: Control = chips[0]._make_custom_tooltip(chips[0].tooltip_text)
		var push_icon: bool = chip_tooltip.find_children("*", "TextureRect", true, false).any(func(node: Node) -> bool:
			return (node as TextureRect).texture == AppTheme.tintable_icon(&"GitAhead"))
		expect(push_icon, "the live ahead count has its tinted arrow")
		chip_tooltip.free()
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
		# A real right-click on a chip opens its menu.
		var click: InputEventMouseButton = InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_RIGHT
		click.pressed = true
		click.position = chips[1].get_global_rect().get_center()
		click.global_position = click.position
		get_viewport().push_input(click)
		var release: InputEventMouseButton = click.duplicate() as InputEventMouseButton
		release.pressed = false
		get_viewport().push_input(release)
		var menu: PopupMenu = main.page_at(0).active_view().context_menu()
		expect(await _wait(func() -> bool: return menu.visible), "right-clicking a chip opens its menu: %s"
				% [main.page_at(0).active_view().menu_labels()])
		menu.hide()

	# A change made outside the app arrives through the watcher.
	var file: FileAccess = FileAccess.open(repos[0].path_join("from outside.txt"), FileAccess.WRITE)
	file.store_string("x")
	file.close()
	var updated: bool = await _wait(func() -> bool:
		var now: Array[WorktreeChip] = main.page_at(0).strip().chips()
		return not now.is_empty() and now[0].tooltip_text.contains("3 changed files"))
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
	expect_eq(int(Core.repo_ui_state(page.key()).get("sidebar_width", 0)), 520, "the shared sidebar width is saved")
	for which: WorktreeView.View in [WorktreeView.View.CHANGES, WorktreeView.View.SHELVES, WorktreeView.View.HISTORY]:
		page.show_view(which)
		for frame: int in 3:
			await get_tree().process_frame
		var left: Control = page.history().left_pane() if which == WorktreeView.View.HISTORY else page.changes().left_pane()
		expect_eq(roundi(left.size.x), 520, "switching views keeps the sidebar width")
	page.show_view(WorktreeView.View.CHANGES)
	page.changes().split_offset = 400
	page.changes().drag_ended.emit()
	page.show_view(WorktreeView.View.HISTORY)
	for frame: int in 3:
		await get_tree().process_frame
	expect_eq(roundi(page.history().left_pane().size.x), 400, "resizing Changes also resizes History")
	page.active_view()._restore_widths()
	expect_eq(page.history().split_offset, 400, "the common width is restored")
	var original_size: Vector2i = get_window().size
	get_window().size = Vector2i(960, 680)
	for which: WorktreeView.View in [WorktreeView.View.SHELVES, WorktreeView.View.CHANGES, WorktreeView.View.HISTORY]:
		page.show_view(which)
		for frame: int in 3:
			await get_tree().process_frame
		var left: Control = page.history().left_pane() if which == WorktreeView.View.HISTORY else page.changes().left_pane()
		expect_eq(roundi(left.size.x), 400, "compact-window view switching keeps the sidebar width")
	get_window().size = original_size
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
	await _check_palette(main)

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
	await _check_home_recent()


## Home's Recent cards (M7.5 replaced the welcome screen): ordered as the
## library's recent list, names told apart, full path as tooltip, long names
## cut with an ellipsis instead of widening the card.
func _check_home_recent() -> void:
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	for frame: int in 3:
		await get_tree().process_frame
	var home: Home = main.home()
	var chosen: Array[String] = [""]
	home.chosen.connect(func(path: String) -> void: chosen[0] = path)
	var recent: PackedStringArray = Core.recent_repos(home.get_theme_constant(&"recent_count", &"Home"))
	var labels: PackedStringArray = Paths.short_labels(recent)
	expect_eq(home.recent_paths().size(), recent.size(), "Home shows the library's recent repositories")
	for i: int in recent.size():
		var card: Button = home.card_for(recent[i]) as Button
		expect(card != null and Paths.same(home.recent_paths()[i], recent[i]), "Home keeps recent ordering")
		if card == null:
			continue
		var title: Label = card.find_child("Name", true, false) as Label
		expect_eq(title.text, labels[i], "a card's name is told apart from the others'")
		expect(card.tooltip_text.begins_with(recent[i]), "a card's tooltip starts with its full path")
		expect_eq(title.text_overrun_behavior, TextServer.OVERRUN_TRIM_ELLIPSIS, "long names use an ellipsis")
	if not recent.is_empty():
		var card: Control = home.card_for(recent[0])
		var width: float = card.size.x
		(card.find_child("Name", true, false) as Label).text = "工程 café ".repeat(100) + " · parent"
		for frame: int in 3:
			await get_tree().process_frame
		expect(card.size.x <= width, "long Unicode names stay within the card")
	# Choosing opens the repository, which rebuilds Home: one card at a time.
	for path: String in recent:
		Actions.run_action(&"home.open")
		await get_tree().process_frame
		var card: Button = home.card_for(path) as Button
		if card != null:
			card.pressed.emit()
			expect_eq(chosen[0], path, "each card chooses its own path")
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _check_recent_labels() -> void:
	var paths: PackedStringArray = [
		"C:\\Work\\clients\\gitbello\\", "D:/Personal/clients/gitbello",
		"C:/Projects/unique", "//server/team/gitbello",
		"C:/very long parent with spaces/工程/café", "D:/Archive/café",
	]
	expect_eq(Paths.short_labels(paths), PackedStringArray([
		"gitbello · Work/clients", "gitbello · Personal/clients", "unique",
		"gitbello · team", "café · 工程", "café · Archive",
	]), "only duplicate names receive distinguishing parent suffixes")
	expect_eq(Paths.short_labels(PackedStringArray([
		"C:/team/repo", "D:/team/repo", "//alpha/team/repo", "//beta/team/repo",
	])), PackedStringArray([
		"repo · C:/team", "repo · D:/team", "repo · //alpha/team", "repo · //beta/team",
	]), "drive and server names distinguish otherwise identical parent suffixes")
	var case_labels: PackedStringArray = Paths.short_labels(PackedStringArray([
		"C:/Work/Repo", "D:/Personal/repo",
	]))
	expect_eq(case_labels, PackedStringArray(["Repo · Work", "repo · Personal"]) \
			if OS.has_feature("windows") else PackedStringArray(["Repo", "repo"]),
			"basename comparison respects platform case rules while preserving display case")
	expect_eq(Paths.short_labels(PackedStringArray(["/repo", "/work/repo", "C:/", "/"])),
			PackedStringArray(["repo · /", "repo · work", "C:", "/"]), "root parents and root names stay meaningful")


func _check_palette(main: Main) -> void:
	var ran: Array[int] = [0]
	var available: Array[bool] = [true]
	Actions.register(&"test.palette_probe_a", "Paletteprobe a", "Tests",
			func() -> void: ran[0] += 1, PackedStringArray(["Ctrl+Alt+F12"]),
			func() -> bool: return available[0])
	Actions.register(&"test.palette_probe_b", "Paletteprobe b", "Tests",
			func() -> void: ran[0] += 1, PackedStringArray(), func() -> bool: return false,
			func() -> String: return "Open a repository first.")
	Actions.register(&"test.palette_probe_c", "Paletteprobe c", "Tests", func() -> void: ran[0] += 1)
	Actions.register(&"test.palette_probe_d", "Paletteprobe d", "Tests",
			func() -> void: ran[0] += 1, PackedStringArray(), func() -> bool: return false)
	var hidden: ActionRegistry.Action = Actions.register(&"test.palette_probe_e", "Paletteprobe e", "Tests",
			func() -> void: ran[0] += 1)
	hidden.hidden = true
	var palette: CommandPalette = main.palette()
	var results: Tree = palette.get_node("%Results") as Tree
	palette.open()
	expect("Tests: Paletteprobe a" in palette.visible_labels(), "available actions are listed without a query")
	expect(not "Tests: Paletteprobe b" in palette.visible_labels(), "unavailable actions stay hidden without a query")
	palette.set_query("   ")
	expect(not "Tests: Paletteprobe b" in palette.visible_labels(), "whitespace does not reveal unavailable actions")
	palette.set_query("paletteprobe")
	await get_tree().process_frame
	await get_tree().process_frame
	expect_eq(palette.visible_labels().size(), 4, "search finds enabled and unavailable actions, but not hidden actions")
	var enabled_items: Array[TreeItem] = []
	var item: TreeItem = results.get_root().get_first_child()
	var disabled: TreeItem = null
	while item != null:
		if item.get_text(0) == "Tests: Paletteprobe b":
			disabled = item
			expect_eq(item.get_text(1), "Open a repository", "an unavailable match shows a compact hint")
			expect(not item.is_selectable(0) and not item.is_selectable(1), "neither column of an unavailable match is selectable")
			expect_eq(item.get_custom_color(0), palette.get_theme_color(&"font_color", &"DimLabel"), "unavailable commands use muted theme text")
			expect(item.get_tooltip_text(1).contains("Open a repository first."), "the full reason remains in the tooltip")
			expect_eq(item.get_text_overrun_behavior(1), TextServer.OVERRUN_NO_TRIMMING, "hints are never ellipsized")
			expect_eq(item.get_autowrap_mode(1), TextServer.AUTOWRAP_WORD_SMART, "long hints can wrap")
		elif item.get_text(0) == "Tests: Paletteprobe d":
			expect_eq(item.get_text(1), "Unavailable here", "actions without a reason have a compact fallback")
		if item.is_selectable(0):
			enabled_items.append(item)
		item = item.get_next()
	expect_eq(enabled_items.size(), 2, "two probe commands can run")
	if enabled_items.size() == 2:
		expect(results.get_selected() == enabled_items[0], "initial selection skips unavailable matches")
		press("Down")
		expect(results.get_selected() == enabled_items[1], "Down skips unavailable matches")
		press("Up")
		expect(results.get_selected() == enabled_items[0], "Up skips unavailable matches")
	if disabled != null:
		var at: Vector2 = results.get_global_rect().position + results.get_item_area_rect(disabled, 0).get_center()
		var motion: InputEventMouseMotion = InputEventMouseMotion.new()
		motion.position = at
		get_viewport().push_input(motion)
		var click: InputEventMouseButton = InputEventMouseButton.new()
		click.position = at
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.double_click = true
		get_viewport().push_input(click)
		click = click.duplicate() as InputEventMouseButton
		click.pressed = false
		get_viewport().push_input(click)
		expect_eq(ran[0], 0, "double-clicking an unavailable match does not execute a selected enabled command")
		expect(palette.visible, "double-clicking an unavailable match keeps the palette open")
	palette.set_query("paletteprobe b")
	expect_eq(palette.visible_labels(), PackedStringArray(["Tests: Paletteprobe b"]), "an unavailable command can be found on its own")
	expect(results.get_selected() == null, "all-unavailable results have no selection")
	press("Down")
	press("Enter")
	expect_eq(ran[0], 0, "Enter cannot execute an unavailable match")
	expect(palette.visible, "Enter on unavailable-only results keeps the explanation visible")
	palette.set_query("paletteprobe a")
	var focus: Control = get_viewport().gui_get_focus_owner()
	expect((palette.get_node("%Query") as LineEdit).has_focus(), "the query keeps keyboard focus after an unavailable click (focus: %s)" % str(focus))
	available[0] = false
	press("Enter")
	expect_eq(ran[0], 0, "availability is checked again before execution")
	expect(palette.visible and results.get_selected() == null, "a newly unavailable command is refreshed without dismissing the palette")
	available[0] = true
	palette.set_query("paletteprobe a")
	press("Enter")
	expect_eq(ran[0], 1, "an available match still executes")
	expect(not palette.visible, "executing an available match closes the palette")
	var long_reason: String = "This unfamiliar explanation must stay completely visible even when it needs several lines. ".repeat(3).strip_edges()
	Actions.get_action(&"test.palette_probe_b").reason = func() -> String: return long_reason
	palette.open()
	palette.set_query("paletteprobe b")
	await get_tree().process_frame
	await get_tree().process_frame
	var wrapped: TreeItem = results.get_root().get_first_child()
	expect_eq(wrapped.get_text(1), long_reason.trim_suffix("."), "unknown reasons keep their full wording")
	var font: Font = results.get_theme_font(&"font")
	var font_size: int = results.get_theme_font_size(&"font_size")
	expect(results.get_item_area_rect(wrapped, 1).size.y > font.get_height(font_size) * 2.0,
			"a long reason grows the row instead of clipping")
	palette.close()
	for id: StringName in [&"test.palette_probe_a", &"test.palette_probe_b", &"test.palette_probe_c",
			&"test.palette_probe_d", &"test.palette_probe_e"]:
		Actions.unregister(id)
	var previous_view: WorktreeView.View = main.current_page().view
	main.current_page().show_view(WorktreeView.View.CHANGES)
	palette.open()
	palette.set_query("amend")
	await get_tree().process_frame
	await get_tree().process_frame
	var amend: TreeItem = results.get_root().get_first_child()
	expect_eq(amend.get_text(1), "Select HEAD in History", "Amend has a short, specific hint")
	var room: float = results.get_item_area_rect(amend, 1).size.x \
			- float(results.get_theme_constant(&"inner_item_margin_left") + results.get_theme_constant(&"inner_item_margin_right"))
	for hint: String in CommandPalette.DISABLED_HINTS.values():
		expect(font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= room,
				"the compact hint fits its column: %s" % hint)
	palette.close()
	main.current_page().show_view(previous_view)


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
