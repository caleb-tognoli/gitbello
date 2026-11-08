extends SmokeTest
## The Keyboard page of Settings: contexts and conflicts in the registry, then
## recording, Escape, a conflict with Cancel and Reassign, keys shared across
## contexts, clear and revert, the filters (text, pressed keys, Changed),
## folding sections, Settings' search pointing at shortcuts, and Reset all.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var before: Dictionary = Core.keybindings()
	Actions.reset_all_shortcuts()
	L10n.apply("en")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	_check_registry()

	expect(Actions.run_action(&"app.keyboard_shortcuts"), "Keyboard shortcuts runs")
	var settings: SettingsWindow = main.settings_window()
	var page: ShortcutsPage = settings.shortcuts
	expect(await wait_until(func() -> bool: return settings.visible), "Settings opens")
	expect(page.is_visible_in_tree(), "it opens on the Keyboard page")
	expect(page.search.text_box().has_focus(), "the page's filter has focus")
	expect(not page.row(&"worktree.select_1").is_empty(), "hidden actions with a default key are listed")
	expect(page.row(&"shelf.toggle_branch_group").is_empty(), "hidden actions without a key are not")
	var about: Dictionary = page.row(&"app.about")
	expect(not about.is_empty(), "actions without a shortcut are listed")
	var add_chip: ShortcutChip = (about.chips as HBoxContainer).get_child(0) as ShortcutChip
	expect(not add_chip.visible, "the Add chip waits for hover")
	var palette_chips: HBoxContainer = page.row(&"app.command_palette").chips
	expect_eq(palette_chips.get_child_count(), 2, "both palette shortcuts have a chip")
	expect_eq((page.row(&"diff.copy").context as Label).text, "Diff", "context tags show")
	expect(not (page.row(&"app.about").context as Label).visible, "global actions have no tag")
	expect(not (page.row(&"changes.discard").context as Label).visible, "no tag repeats its section")
	expect((page.row(&"conflict.undo").context as Label).visible, "Conflicts rows say they work in the resolver")

	# Record a new shortcut
	page.record(&"app.about")
	expect(page.is_recording(&"app.about"), "a click on the chip records")
	expect(not settings.dialog_close_on_escape, "the window leaves Escape to the page while recording")
	expect_eq(add_chip.state, ShortcutChip.State.RECORDING, "the chip shows it is recording")
	press("Ctrl+Alt+F11", settings)
	await get_tree().process_frame
	expect(not page.is_recording(), "the key ends recording")
	expect_eq(Actions.shortcuts(&"app.about"), PackedStringArray(["Ctrl+Alt+F11"]), "the new shortcut saves")
	expect_eq(String(Core.keybindings().get("app.about", "")), "Ctrl+Alt+F11", "it reaches the config")
	expect((about.dot as Control).visible, "a changed shortcut has its dot")
	expect(settings.dialog_close_on_escape, "Escape closes the window again")

	# Escape cancels
	page.record(&"app.about")
	press("Escape", settings)
	await get_tree().process_frame
	expect(not page.is_recording(), "Escape stops recording")
	expect_eq(Actions.shortcuts(&"app.about"), PackedStringArray(["Ctrl+Alt+F11"]), "Escape keeps the shortcut")
	page.record(&"app.about")
	press("Shift", settings)
	expect(page.is_recording(), "a modifier alone keeps recording")
	page.cancel()

	# A clash asks first
	page.record(&"app.about")
	press("Ctrl+Shift+P", settings)
	await get_tree().process_frame
	expect_eq(page.pending().get("conflicts", []), [&"app.command_palette"], "the palette's key is a conflict")
	expect((about.conflict as Control).visible, "the conflict shows under the row")
	expect("Command palette" in (about.message as Label).text, "it names the other action: %s" % (about.message as Label).text)
	expect((about.reassign as Button).has_focus(), "Reassign has focus")
	press("Escape", settings)
	await get_tree().process_frame
	expect(page.pending().is_empty(), "Escape cancels the conflict")
	expect_eq(Actions.shortcuts(&"app.about"), PackedStringArray(["Ctrl+Alt+F11"]), "cancel keeps the old shortcut")
	page.record(&"app.about")
	press("Ctrl+K", settings)
	await get_tree().process_frame
	page.reassign()
	await get_tree().process_frame
	expect_eq(Actions.shortcuts(&"app.about"), PackedStringArray(["Ctrl+K"]), "Reassign gives the key")
	expect_eq(Actions.shortcuts(&"app.command_palette"), PackedStringArray(["Ctrl+Shift+P"]),
			"and takes it from the palette, which keeps its other key")
	expect(Actions.is_modified(&"app.command_palette"), "the palette counts as changed")

	# Contexts that never show together share keys; nested ones do not
	page.record(&"changes.undo_discard")
	press("Alt+O", settings)
	await get_tree().process_frame
	expect(page.pending().is_empty(), "a resolver key is free in Changes")
	expect_eq(Actions.shortcuts(&"changes.undo_discard"), PackedStringArray(["Alt+O"]), "and saves")
	page.record(&"diff.copy")
	press("Ctrl+Shift+S", settings)
	await get_tree().process_frame
	expect_eq(page.pending().get("conflicts", []), [&"changes.include_all"], "the diff sits inside Changes")
	page.cancel()

	# Clear and revert
	(page.row(&"app.command_palette").clear as Button).pressed.emit()
	await get_tree().process_frame
	expect(Actions.shortcuts(&"app.command_palette").is_empty(), "clear removes every shortcut")
	(page.row(&"app.command_palette").revert as Button).pressed.emit()
	await get_tree().process_frame
	expect_eq(Actions.shortcuts(&"app.command_palette"), PackedStringArray(["Ctrl+Shift+P", "Ctrl+K"]),
			"revert restores both defaults")
	expect(not Actions.is_modified(&"app.command_palette"), "and the palette is unchanged again")
	expect(Actions.conflicts(&"app.about", "Ctrl+K") == [&"app.command_palette"], "now About clashes again")
	page.record(&"app.about")
	press("Ctrl+Alt+F11", settings)
	await get_tree().process_frame

	# Filters
	page.search.set_text("fetch")
	expect(page.is_row_shown(&"sync.fetch"), "the filter finds Fetch")
	expect(not page.is_row_shown(&"app.about"), "and hides the rest")
	page.search.set_text("ctrl+shift+f")
	expect(page.is_row_shown(&"sync.fetch"), "the filter matches shortcut text")
	page.search.set_text("")
	page.set_key_search(true)
	expect(not settings.dialog_close_on_escape, "key search owns Escape")
	press("Ctrl+B", settings)
	await get_tree().process_frame
	expect(page.is_row_shown(&"branch.switch"), "pressing Ctrl+B finds Switch branch")
	expect(not page.is_row_shown(&"sync.fetch"), "and only what uses it")
	expect_eq(page.search.text(), "Ctrl+B", "the field shows the keys")
	press("Escape", settings)
	expect(not page.key_search.button_pressed, "Escape leaves key search")
	expect(page.is_row_shown(&"sync.fetch"), "and every row shows again")
	page.changed_filter.button_pressed = true
	await get_tree().process_frame
	expect(page.is_row_shown(&"app.about") and page.is_row_shown(&"changes.undo_discard"), "Changed shows changed rows")
	expect(not page.is_row_shown(&"sync.fetch"), "and hides the others")
	expect_eq(page.changed_filter.text, "Changed  2", "the chip counts them")
	page.changed_filter.button_pressed = false
	page.toggle_section("App")
	expect(not page.is_row_shown(&"app.about"), "a folded section hides its rows")
	page.toggle_section("App")
	expect(page.is_row_shown(&"app.about"), "unfolding shows them")

	# Settings' search counts shortcuts
	settings.show_category("General")
	expect(not page.is_visible_in_tree(), "other categories hide the page")
	settings.search.set_text("palette")
	expect(settings._shortcut_hits.visible, "Settings' search mentions matching shortcuts")
	expect_eq(settings._shortcut_hits.text, "Matching shortcuts: 1", "it counts them")
	settings._shortcut_hits.pressed.emit()
	expect(page.is_visible_in_tree(), "the button opens Keyboard")
	expect_eq(page.search.text(), "palette", "with the search carried over")
	expect(page.is_row_shown(&"app.command_palette"), "showing the match")

	# Reset all
	expect(not page.reset_all.disabled, "Reset all is available with changes")
	page._confirm.confirmed.emit()
	await get_tree().process_frame
	expect_eq(Actions.modified_count(), 0, "Reset all restores every default")
	expect(Core.keybindings().is_empty(), "and empties the config's keybindings")
	expect(page.reset_all.disabled, "nothing is left to reset")
	expect(not (about.dot as Control).visible, "the dots go")

	page.record(&"app.about")
	settings.hide()
	expect(not page.is_recording(), "closing Settings stops recording")
	for id: Variant in before:
		Actions.set_shortcut(StringName(str(id)), str(before[id]))
	main.queue_free()
	await get_tree().process_frame


func _check_registry() -> void:
	expect_eq(Shortcuts.display("Ctrl+Slash"), "Ctrl+/" if not OS.has_feature("macos") else "Cmd+/", "Slash shows as /")
	expect_eq(Shortcuts.display_keys("Ctrl+Plus").size(), 2, "Ctrl++ is two key caps")
	expect_eq(ActionRegistry.context_for(&"diff.copy"), &"Diff", "diff actions work in the diff")
	expect_eq(ActionRegistry.context_for(&"conflict.undo"), &"Resolver", "conflict actions work in the resolver")
	expect_eq(ActionRegistry.context_for(&"commit.undo"), &"Changes", "Undo last commit works in Changes")
	expect_eq(ActionRegistry.context_for(&"app.settings"), ActionRegistry.GLOBAL, "app actions are global")
	expect(ActionRegistry.contexts_overlap(&"Diff", &"History"), "the diff shows inside History")
	expect(not ActionRegistry.contexts_overlap(&"Changes", &"Resolver"), "the resolver replaces the diff")
	expect(not ActionRegistry.contexts_overlap(&"Changes", &"History"), "views never show together")
	for action: ActionRegistry.Action in Actions.with_shortcuts():
		for text: String in action.default_shortcuts:
			var clashes: Array[StringName] = Actions.conflicts(action.id, text)
			expect(clashes.is_empty(), "default %s of %s clashes with %s" % [text, action.id, clashes])
