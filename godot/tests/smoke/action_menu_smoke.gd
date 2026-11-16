extends SmokeTest
## `ActionMenu`: actions that do not apply are left out, those that
## cannot run are greyed with their reason, checkable ones are checks or
## radio items, shortcuts show, separators never lead, trail or double, and
## submenus left empty are dropped.

var _ran: Array[StringName] = []
var _applies: bool = true
var _can_run: bool = true
var _on: bool = true


func run() -> void:
	Actions.register(&"test.menu_a", "Alpha", "Test", func() -> void: _ran.append(&"test.menu_a"),
			PackedStringArray(["Ctrl+Alt+F7"]))
	Actions.register(&"test.menu_b", "Bravo", "Test", func() -> void: _ran.append(&"test.menu_b"),
			PackedStringArray(), func() -> bool: return _can_run, func() -> String: return "Not now")
	Actions.register(&"test.menu_c", "Charlie", "Test", func() -> void: _ran.append(&"test.menu_c"))
	Actions.set_visible(&"test.menu_c", func() -> bool: return _applies)
	Actions.register(&"test.menu_d", "Delta", "Test", func() -> void: _on = not _on)
	Actions.set_checked(&"test.menu_d", func() -> bool: return _on)
	Actions.register(&"test.menu_e", "Echo", "Test", func() -> void: pass)
	Actions.set_checked(&"test.menu_e", func() -> bool: return true, true)
	Actions.get_action(&"test.menu_e").menu_label = "E"

	var menu: ActionMenu = ActionMenu.new()
	add_child(menu)
	var shown: int = menu.fill([&"", &"test.menu_a", &"", &"", &"test.menu_b", &"test.menu_c", &"",
		&"test.menu_d", &"test.menu_e", &""])
	expect_eq(shown, 5, "every action shows while it applies")
	expect_eq(menu.top_labels(), PackedStringArray(["Alpha", "Bravo", "Charlie", "Delta", "E"]),
			"menu labels, the short one where set")
	expect_eq(menu.item_count, 7, "two separators: none leading, trailing or doubled")
	expect(menu.is_item_separator(1) and menu.is_item_separator(4), "separators between the groups")
	expect(menu.get_item_shortcut(0) != null, "the shortcut shows")
	expect(menu.is_item_checkable(5) and menu.is_item_checked(5), "a checked check item")
	expect(menu.is_item_radio_checkable(6), "a radio item")

	_can_run = false
	_applies = false
	menu.fill([&"test.menu_a", &"", &"test.menu_c", &"", &"test.menu_b"])
	expect_eq(menu.top_labels(), PackedStringArray(["Alpha", "Bravo"]), "an action that does not apply is left out")
	expect_eq(menu.item_count, 3, "its group's separator goes with it")
	expect(menu.is_item_disabled(2), "an action that cannot run is greyed")
	expect_eq(menu.get_item_tooltip(2), "Not now", "with why in its tooltip")
	expect(not menu.press("Bravo"), "a greyed item cannot be pressed")

	expect(menu.press("Alpha"), "an item runs its action")
	expect_eq(_ran, [&"test.menu_a"] as Array[StringName], "Alpha ran")

	var chosen: Array[StringName] = []
	menu.auto_run = false
	menu.chosen.connect(func(id: StringName) -> void: chosen.append(id))
	menu.fill([&"test.menu_a"])
	menu.press_id(&"test.menu_a")
	expect_eq(chosen, [&"test.menu_a"] as Array[StringName], "without auto_run the owner is told")
	expect_eq(_ran.size(), 1, "and the action did not run itself")
	menu.auto_run = true

	var dynamic_ran: Array[String] = []
	menu.fill([ActionMenu.title("Target"), &"test.menu_a",
		ActionMenu.sub("Empty", [&"test.menu_c"]),
		ActionMenu.sub("More", [&"test.menu_d"]),
		ActionMenu.dynamic("Rules", func() -> Array:
			return [{"label": "One", "run": func() -> void: dynamic_ran.append("one")}, {},
				{"label": "Two", "run": func() -> void: dynamic_ran.append("two"), "disabled": true}])])
	expect_eq(menu.get_item_text(0), "Target", "a title is a labelled separator")
	expect(menu.submenu("Empty") == null, "a submenu with nothing to show is left out")
	expect(menu.submenu("More") != null, "a submenu of actions")
	var rules: ActionMenu = menu.submenu("Rules")
	expect(rules != null and rules.item_count == 3, "a dynamic submenu with its separator")
	expect(menu.press("One"), "a dynamic item runs")
	expect_eq(dynamic_ran, ["one"] as Array[String], "its callable ran")
	expect(not menu.press("Two"), "a disabled dynamic item does not")
	expect(&"test.menu_d" in menu.action_ids(), "action ids include the submenus'")

	_applies = true
	menu.fill([ActionMenu.family("Pick", [&"test.menu_a", &"test.menu_c"], {&"test.menu_c": "C"})])
	var family: ActionMenu = menu.submenu("Pick")
	expect(family != null and family.top_labels() == PackedStringArray(["Alpha", "C"]),
			"a family shows its own labels")
	_applies = false
	menu.fill([ActionMenu.family("Pick", [&"test.menu_a", &"test.menu_c"], {&"test.menu_a": "A"})])
	expect_eq(menu.top_labels(), PackedStringArray(["Alpha"]), "a family of one is flat, with its menu label")

	menu.fill([ActionMenu.item("Choice", func() -> void: pass, &"", true, "Why not")])
	expect(menu.is_item_disabled(0) and menu.get_item_tooltip(0) == "Why not", "a disabled choice says why")

	menu.fill([ActionMenu.dynamic("Nothing", func() -> Array: return [])])
	expect(menu.item_count == 1 and menu.is_item_disabled(0), "an empty dynamic submenu is greyed")

	expect_eq(menu.fill([&"test.menu_c"]), 0, "nothing shows")
	expect(not menu.open([&"test.menu_c"], Vector2.ZERO), "and the menu does not open")

	# An opened menu redraws for a moment (a first frame Windows did not show
	# left it blank), then stops.
	expect(menu.open([&"test.menu_a"], Vector2.ZERO), "the menu opens")
	expect(menu.is_redrawing(), "a menu just opened redraws")
	var deadline: int = Time.get_ticks_msec() + ActionMenu.REDRAW_MS + 100
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	expect(not menu.is_redrawing(), "and stops after a moment")
	menu.hide()

	for id: StringName in [&"test.menu_a", &"test.menu_b", &"test.menu_c", &"test.menu_d", &"test.menu_e"]:
		Actions.unregister(id)
	menu.queue_free()
	await get_tree().process_frame
