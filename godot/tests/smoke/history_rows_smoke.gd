extends SmokeTest
## M7.10: two-line history rows. Initials and their colours, the relative
## dates, the author line with co-authors, the ref chips (the current
## branch by name, the others counted per kind, the merged remote branch,
## the popover of all refs and its menus over it), the details' people
## cards and ref chips (folded past six), and Compact rows in the options menu (saved in the scratch config, applied to
## every History view). Read-only on the
## fixture `repo-5`; skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const DAY: int = 86400


func run() -> void:
	_check_initials()
	_check_dates()
	_check_summary()
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("history_rows_smoke: no --fixtures, skipped the views")
		return
	var was_compact: bool = Core.history_compact()
	if was_compact:
		Core.set_history_compact(false)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(fixtures.path_join("repo-5"))
	page.show_view(WorktreeView.View.HISTORY)
	var history: HistoryView = page.history()
	var list: CommitList = history.commit_list()
	expect(await wait_until(func() -> bool: return list.row_count() == 3), "three commits")
	expect(not list.compact, "rows have two lines by default")
	var tall: float = list.row_height()
	expect_eq(tall, float(list.get_theme_constant(&"two_line_row_height", CommitList.LIST_THEME_TYPE)),
			"two-line rows use their own height")

	var row: Dictionary = list.row_data(0)
	var meta: String = list.meta_text(row)
	expect(meta.begins_with(String(row["author"]) + " · "), "the author line starts with the author: %s" % meta)
	var paired: Dictionary = row.duplicate()
	paired["coauthors"] = [{"name": "Grace Hopper", "email": "grace@navy.mil"}, {"name": "", "email": "bot@x.org"}]
	expect(list.meta_text(paired).begins_with(String(row["author"]) + " +2 · "),
			"co-authors are counted: %s" % list.meta_text(paired))
	var tooltip: String = list.people_text(paired)
	expect(tooltip.contains("Co-author: Grace Hopper <grace@navy.mil>") and tooltip.contains("<bot@x.org>"),
			"the tooltip lists the co-authors: %s" % tooltip)
	expect(tooltip.ends_with(list.date_text(int(row["time"]))), "the tooltip ends with the exact time")

	await _check_chips(list, history, page)
	await _check_details(list, history, page)

	# Rows (Compact | Detailed) in the search field's options, and the View menu's radios.
	var options: OptionsPopover = history.options_popover()
	var rows: SegmentedControl = options.control("rows") as SegmentedControl
	expect(rows != null, "the options have the rows choice")
	expect_eq(options.value("rows"), "detailed", "it shows Detailed for two-line rows")
	expect_eq(rows.choice_button("compact").icon, AppTheme.tintable_icon(&"RowsOneLine"), "Compact has the one-line icon")
	expect(rows.choice_button("detailed").tooltip_text.begins_with("Detailed rows"), "the tooltip names the rows")
	expect(not Actions.get_action(&"history.compact_rows").hidden and not Actions.get_action(&"history.detailed_rows").hidden,
			"Compact rows and Detailed rows are actions")
	history.scope_button().pressed.emit()
	rows.choice_button("compact").pressed.emit()
	expect(options.visible, "the popover stays open")
	options.hide()
	expect(list.compact and Core.history_compact(), "Compact switches and saves")
	expect_eq(options.value("rows"), "compact", "the choice follows")
	expect(not history.scope_button().button_pressed, "compact rows do not light the options button")
	expect_eq(history.search_field().options_badge().count, 0, "and are not counted as a filter")
	# Show graph, beside it: off moves the text to the left edge, saved.
	var graph: ToggleChip = options.control("graph") as ToggleChip
	expect(graph.button_pressed, "Show graph is on by default")
	var with_graph: float = list.text_left()
	history.scope_button().pressed.emit()
	graph.button_pressed = false
	options.hide()
	expect(not list.show_graph and not Core.history_graph(), "Show graph off hides the graph and saves")
	expect(list.text_left() < with_graph, "the text starts further left (%s < %s)" % [list.text_left(), with_graph])
	Actions.run_action(&"history.toggle_graph")
	expect(list.show_graph and Core.history_graph(), "the action brings the graph back")
	expect(bool(options.value("graph")), "and the chip follows")
	expect(list.row_height() < tall, "compact rows are shorter")
	# Compact rows: the ref icons and the author's avatar on the right.
	await get_tree().process_frame
	await get_tree().process_frame
	var compact_hits: Array = list.chip_rects(0)
	expect(not compact_hits.is_empty() and (compact_hits[0][1] as Dictionary).has("labels"),
			"compact rows draw icon chips: %s" % [compact_hits])
	if not compact_hits.is_empty():
		var icons: Rect2 = compact_hits[compact_hits.size() - 1][0]
		expect(icons.end.x > list.size.x * 0.5, "on the right")
		var avatar_at: Vector2 = Vector2(icons.end.x + list.get_theme_constant(&"avatar_gap", CommitList.LIST_THEME_TYPE)
				+ 2.0, icons.get_center().y)
		expect(list.get_tooltip(avatar_at).begins_with(String(row["author"])),
				"the avatar after them names the author: %s" % list.get_tooltip(avatar_at))
	var other: RepoTab = main.open_repo(fixtures.path_join("repo-1"))
	other.show_view(WorktreeView.View.HISTORY)
	expect(other.history().commit_list().compact, "a new tab opens compact")
	Actions.run_action(&"history.detailed_rows")
	expect(not list.compact and not other.history().commit_list().compact,
			"Detailed rows switches every History view back")
	expect_eq(options.value("rows"), "detailed", "and the choice follows")
	Actions.run_action(&"history.toggle_compact")
	expect(list.compact, "the toggle still flips the rows")
	Actions.run_action(&"history.toggle_compact")
	expect(not Core.history_compact(), "and saves it")

	if was_compact:
		Core.set_history_compact(true)
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _check_initials() -> void:
	expect_eq(AvatarPainter.initials("Ada Lovelace", "ada@example.com"), "AL", "first and last names")
	expect_eq(AvatarPainter.initials("Jérôme Le Gall", ""), "JG", "accents and middle names")
	expect_eq(AvatarPainter.initials("  caleb ", ""), "C", "a single name")
	expect_eq(AvatarPainter.initials("", "bot@example.com"), "B", "the email without a name")
	expect_eq(AvatarPainter.initials("(bot)", ""), "B", "punctuation is skipped")
	expect_eq(AvatarPainter.initials("", ""), "?", "nothing to go on")
	var a: int = AvatarPainter.color_index("Ada", "Ada@Example.com", 10)
	expect_eq(a, AvatarPainter.color_index("Someone", " ada@example.com", 10), "the colour follows the email")
	expect(a >= 0 and a < 10, "the index is in the palette")


func _check_dates() -> void:
	var now: int = Time.get_unix_time_from_datetime_string("2026-11-07T12:00:00")
	expect_eq(RelativeDate.text(now - 20, now, 0), "just now", "seconds")
	expect_eq(RelativeDate.text(now - 600, now, 0), "10 min ago", "minutes")
	expect_eq(RelativeDate.text(now - 3 * 3600, now, 0), "3 h ago", "hours")
	expect_eq(RelativeDate.text(now - DAY - 60, now, 0), "yesterday", "a day")
	expect_eq(RelativeDate.text(now - 12 * DAY, now, 0), "12 days ago", "days")
	expect_eq(RelativeDate.text(now - 40 * DAY, now, 0), "Sep 28", "a date this year")
	expect_eq(RelativeDate.text(now - 400 * DAY, now, 0), "2025-10-03", "an older date")
	expect_eq(RelativeDate.text(now + 3600, now, 0), "Nov 7", "a future date is shown as a date")
	expect_eq(RelativeDate.exact(now, 3600), "2026-11-07 13:00", "the exact time in local time")


const MAIN_LABEL: Dictionary = {"name": "main", "kind": "branch", "is_head": true, "remote": "",
	"remotes": ["origin/main"]}
const TOPIC: Dictionary = {"name": "topic", "kind": "branch", "is_head": false, "remote": "", "remotes": []}
const ONLY_REMOTE: Dictionary = {"name": "origin/fix", "kind": "remote", "is_head": false,
	"remote": "origin", "remotes": []}
const TAG: Dictionary = {"name": "v1.0", "kind": "tag", "is_head": false, "remote": "", "remotes": []}
const TAG_2: Dictionary = {"name": "v1.0.1", "kind": "tag", "is_head": false, "remote": "", "remotes": []}


func _check_summary() -> void:
	var items: Array[Dictionary] = RefChip.summarize([MAIN_LABEL, TOPIC, ONLY_REMOTE, TAG, TAG_2])
	expect_eq(items.size(), 3, "the current branch, a branch count, a tag count")
	expect_eq(items[0].get("label"), MAIN_LABEL, "the current branch keeps its name")
	expect_eq(items[1].get("labels"), [TOPIC, ONLY_REMOTE], "the other branches are counted")
	expect_eq(items[2].get("labels"), [TAG, TAG_2], "and so are the tags")
	var others: Array[Dictionary] = RefChip.summarize([TOPIC, ONLY_REMOTE, TAG])
	expect(others.size() == 2 and (others[0]["labels"] as Array).size() == 2 and others[1].get("label") == TAG,
			"without the current branch every branch is counted; a lone tag keeps its name: %s" % [others])
	var pair: Array[Dictionary] = RefChip.summarize([MAIN_LABEL, TOPIC])
	expect(pair.size() == 2 and pair[1].get("label") == TOPIC, "one other branch keeps its name: %s" % [pair])
	expect(RefChip.summarize([]).is_empty(), "no refs, no chips")
	var kinds: Array[Dictionary] = RefChip.group_kinds([MAIN_LABEL, TOPIC, ONLY_REMOTE, TAG])
	expect(kinds.size() == 2 and (kinds[0]["labels"] as Array).size() == 3 and (kinds[1]["labels"] as Array).size() == 1,
			"compact rows group the refs by kind")
	expect(RefChip.group_tooltip([TOPIC, ONLY_REMOTE]) == "topic\norigin/fix","an icon's tooltip names its refs")
	expect_eq(RefChip.icon_name(MAIN_LABEL), &"GitRemote", "the cloud replaces the branch icon when merged")
	expect_eq(RefChip.icon_name(TOPIC), &"GitBranch", "a local-only branch has the branch icon")
	expect_eq(RefChip.icon_name(ONLY_REMOTE), &"GitRemote", "a remote branch has the cloud")
	expect_eq(RefChip.icon_name(TAG), &"GitTag", "a tag has the tag icon")
	expect_eq(RefChip.ref_target(ONLY_REMOTE)["name"], "refs/remotes/origin/fix", "menus get the full ref name")
	expect_eq(RefChip.ref_target(TAG)["short"], "v1.0", "and the short one")


func _check_chips(list: CommitList, history: HistoryView, page: RepoTab) -> void:
	var probe: Control = Control.new()
	add_child(probe)
	expect(RefChip.tooltip(MAIN_LABEL).contains("origin/main"), "the merged chip names its remote branch")
	expect(RefChip.shape_icons(probe, [TOPIC]).text == null, "one ref: just the icon")
	var counted: RefChip.Shaped = RefChip.shape_icons(probe, [TOPIC, ONLY_REMOTE, MAIN_LABEL])
	expect(counted.text != null and counted.text.get_size().x > 0.0, "several: the icon and their count")
	expect_eq(counted.icon, &"GitBranch", "several branches: the branch icon")
	expect_eq(RefChip.shape_icons(probe, [ONLY_REMOTE, MAIN_LABEL]).icon, &"GitBranch", "not the first one's cloud")
	expect_eq(RefChip.shape_icons(probe, [TAG, TAG_2]).icon, &"GitTag", "several tags: the tag icon")
	expect_eq(RefChip.shape_icons(probe, [ONLY_REMOTE]).icon, &"GitRemote", "one ref: its own icon")
	var remote_chip: RefChip.Shaped = RefChip.shape(probe, ONLY_REMOTE)
	expect(remote_chip.prefix != null, "a remote branch's prefix is shaped apart")
	var long: Dictionary = TOPIC.duplicate()
	long["name"] = "feature/" + "very-long-branch-name-".repeat(6)
	expect(RefChip.shape(probe, long).size.x <= float(probe.get_theme_constant(&"max_width", RefChip.THEME_TYPE)) + 0.5,
			"a long name is cut to the chip's width")
	probe.queue_free()

	# Drawn chips: the newest row of repo-5 carries main.
	await get_tree().process_frame
	await get_tree().process_frame
	var hits: Array = list.chip_rects(0)
	expect(not hits.is_empty(), "the newest row draws its chips")
	if not hits.is_empty():
		var center: Vector2 = (hits[0][0] as Rect2).get_center()
		var target: Dictionary = list.label_at(0, center)
		expect(String(target.get("name", "")).begins_with("refs/heads/"), "a chip gives its ref: %s" % [target])
		expect(not list.more_at(0, center), "a ref chip is not +N")

	# The popover: every ref, a row's menu goes to the History view's signal
	# and opens over the popover, which stays until an entry runs.
	var popover: RefsPopover = history.refs_popover()
	var asked: Array[Dictionary] = []
	var on_menu: Callable = func(label: Dictionary, _at: Vector2, over: Window) -> void:
		if over == popover:
			asked.append(label)
	history.label_menu_requested.connect(on_menu)
	popover.open_at([long, TOPIC, ONLY_REMOTE, TAG], Vector2(100, 100))
	expect(popover.visible, "a counted chip opens the popover")
	expect_eq(popover.names(), PackedStringArray([long["name"], "topic", "origin/fix", "v1.0"]), "it lists every ref")
	var theme_width: float = float(popover.chip(0).get_theme_constant(&"max_width", RefChip.THEME_TYPE))
	var half: float = popover.get_parent().get_viewport().get_visible_rect().size.x * RefsPopover.MAX_WIDTH_SHARE
	var long_width: float = popover.chip(0).get_combined_minimum_size().x
	expect(long_width > theme_width and long_width <= half + 0.5,
			"a long name is cut only at half the window: %.0f (chip %.0f, half %.0f)" % [long_width, theme_width, half])
	await get_tree().process_frame
	expect(popover.row_button(0).has_focus() and not popover.row_button(0).has_focus(true),
			"the first row has the keys but shows no outline")
	popover.choose(3)
	expect(popover.visible, "choosing a ref keeps the popover")
	await get_tree().process_frame
	expect(asked.size() == 1 and String(asked[0]["name"]) == "refs/tags/v1.0",
			"and asks for that ref's menu over it: %s" % [asked])
	var ref_menu: PopupMenu = page.context_menu()
	expect(ref_menu.visible and ref_menu.get_parent() == popover, "the menu opens over the popover")
	expect(popover.visible, "which stays open under the menu")
	expect("Push tag" in page.menu_labels(), "the fixture's tag gets its menu: %s" % [page.menu_labels()])
	page.close_menu()
	await get_tree().process_frame
	expect(popover.visible, "closing the menu leaves the popover")
	popover.choose(3)
	await get_tree().process_frame
	expect(page.press_menu(Actions.get_action(&"compare.with_current").label), "an entry runs from the menu")
	expect(not popover.visible, "running an entry closes the popover")
	await get_tree().process_frame
	expect(ref_menu.get_parent() != popover, "and the menu goes back to its view")
	page.show_view(WorktreeView.View.HISTORY)
	history.label_menu_requested.disconnect(on_menu)


func _check_details(list: CommitList, history: HistoryView, page: RepoTab) -> void:
	var details: CommitDetails = history.details()
	list.select_only(0)
	var row: Dictionary = list.row_data(0)
	expect(await wait_until(func() -> bool: return details.commit_oid() == String(row["hash"])),
			"the newest commit's details load")
	var people: Array[Dictionary] = details.people()
	expect(not people.is_empty() and String(people[0]["name"]) == String(row["author"]) and String(people[0]["role"]) == "",
			"the first card is the author: %s" % [people])
	for person: Dictionary in people:
		expect(String(person["role"]) in ["", "co-author", "committer"], "a card's role: %s" % [person])
	var chips: Array[RefChip] = details.ref_chips()
	var names: PackedStringArray = PackedStringArray()
	for chip: RefChip in chips:
		names.append(String(chip.label["name"]))
	expect("main" in names, "the details show the commit's refs: %s" % [names])
	var asked: Array[Dictionary] = []
	var on_menu: Callable = func(label: Dictionary, _at: Vector2, _over: Window) -> void: asked.append(label)
	history.label_menu_requested.connect(on_menu)
	if not chips.is_empty():
		var click: InputEventMouseButton = InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		chips[0].gui_input.emit(click)
	expect(asked.size() == 1 and String(asked[0]["name"]).begins_with("refs/"),
			"clicking a chip asks for its ref's menu: %s" % [asked])
	page.close_menu()
	history.label_menu_requested.disconnect(on_menu)

	# Past six refs the details fold them as the rows do.
	var header: CommitHeader = details.header()
	var many: Array = [MAIN_LABEL]
	for i: int in 4:
		var branch: Dictionary = TOPIC.duplicate()
		branch["name"] = "topic-%d" % i
		many.append(branch)
	many.append_array([TAG, TAG_2])
	header._show_refs(many)
	var folded: Array[RefChip] = header.ref_chips()
	expect(folded.size() == 3 and String(folded[0].label["name"]) == "main" and folded[1].labels.size() == 4
			and folded[2].labels.size() == 2, "seven refs fold into main and two counted chips")
	var chip_click: InputEventMouseButton = InputEventMouseButton.new()
	chip_click.button_index = MOUSE_BUTTON_LEFT
	chip_click.pressed = true
	if folded.size() > 1:
		folded[1].gui_input.emit(chip_click)
	expect(header.refs_popover().visible and header.refs_popover().names().size() == 4,
			"a counted chip opens the popover of its refs")
	header.refs_popover().hide()
	header._show_refs(many.slice(0, 6))
	expect_eq(header.ref_chips().size(), 6, "six refs are all shown by name")
