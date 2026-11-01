extends SmokeTest

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	if fixtures_dir().is_empty():
		return
	var embedded: bool = get_tree().root.gui_embed_subwindows
	get_tree().root.gui_embed_subwindows = DisplayServer.get_name() == "headless"
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(fixtures_dir().path_join("repo-10"))
	expect(await wait_until(func() -> bool: return page.strip().chips().size() == 2 and page.session.is_ready()),
			"two worktree chips are ready")
	var strip: WorktreeStrip = page.strip()
	var first: WorktreeChip = strip.chips()[0]
	var second: WorktreeChip = strip.chips()[1]
	first.grab_focus()
	expect(first.has_focus(), "selected chip accepts focus")
	press("Tab")
	expect(second.has_focus(), "Tab reaches the next chip")
	expect(first.selected and not second.selected, "focus does not select a worktree")
	press("Shift+Tab")
	expect(first.has_focus(), "Shift+Tab returns to the first chip")
	press("Tab")
	press("Shift+F10")
	expect(await wait_until(func() -> bool: return page.context_menu().visible), "Shift+F10 opens the chip menu")
	expect("Lock…" in page.menu_labels() and "Delete…" in page.menu_labels(), "menu targets the focused linked chip, not the selected main worktree")
	await _popup_key("Escape", page.context_menu())
	await get_tree().process_frame
	expect(not page.context_menu().visible, "Escape closes the context menu")
	expect(second.has_focus(), "Escape restores chip focus")
	press("Menu")
	expect(await wait_until(func() -> bool: return page.context_menu().visible), "Menu key opens the chip menu")
	var context: PopupMenu = page.context_menu()
	for i: int in context.item_count:
		await _popup_key("Down", context)
		if context.get_item_text(context.get_focused_item()) == "Lock…":
			break
	await _popup_key("Enter", context)
	expect(page.ops().form().visible, "arrows and Enter run the focused chip's Lock action")
	expect(first.selected, "opening a nonselected chip's action does not switch worktrees")
	page.ops().form().hide()
	var chosen: Array[String] = []
	strip.worktree_chosen.connect(func(path: String) -> void: chosen.append(path))
	second.grab_focus()
	press("Enter")
	expect(await wait_until(func() -> bool: return second.selected), "Enter activates the focused worktree")
	expect_eq(chosen.size(), 1, "Enter activates only once")
	expect(not second.has_focus(), "activation focuses the worktree view")
	first.grab_focus()
	press("Space")
	expect(first.selected, "Space activates the first chip")
	expect_eq(chosen.size(), 2, "Space activates only once")
	press("Ctrl+2")
	expect(second.selected, "Ctrl+2 still selects the second worktree")
	press("Ctrl+1")
	expect(first.selected, "Ctrl+1 still selects the first worktree")
	second.grab_focus()
	press("Tab")
	expect(strip.new_task_button().has_focus(), "Tab skips the hidden overflow button and reaches New worktree")
	press("Enter")
	expect(await wait_until(func() -> bool: return page.ops().form().visible), "keyboard New worktree opens its form")
	page.ops().form().hide()
	strip.new_task_button().grab_focus()
	press("Tab")
	var more: Button = get_viewport().gui_get_focus_owner() as Button
	expect(more != null and more.tooltip_text == "More worktree actions", "Tab reaches More worktree actions")
	press("Space")
	var task_menu: PopupMenu = null
	for child: Node in strip.get_children():
		if child is PopupMenu and (child as PopupMenu).visible:
			task_menu = child as PopupMenu
	expect(task_menu != null, "Space opens More worktree actions")
	if task_menu != null:
		await _popup_key("Escape", task_menu)
		expect(not task_menu.visible, "Escape closes More worktree actions")
		expect(more.has_focus(), "Escape restores the menu button's focus")
	await _overflow(strip)
	main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame
	get_tree().root.gui_embed_subwindows = embedded


func _overflow(source: WorktreeStrip) -> void:
	var template: Dictionary = source.chips()[0].worktree.duplicate()
	var strip: WorktreeStrip = WorktreeStrip.new()
	add_child(strip)
	strip.size = Vector2(600.0, 60.0)
	var worktrees: Array[Dictionary] = []
	for i: int in 14:
		var wt: Dictionary = template.duplicate()
		wt["path"] = "/keyboard/worktree-%02d" % i
		wt["name"] = "worktree-%02d-long-name" % i
		wt["is_main"] = i == 0
		worktrees.append(wt)
	strip.show_worktrees(worktrees, String(worktrees[0]["path"]))
	await get_tree().process_frame
	await get_tree().process_frame
	strip.chips()[0].grab_focus()
	for i: int in 13:
		press("Tab")
		await get_tree().process_frame
	expect(strip.chips()[13].has_focus(), "Tab reaches worktrees beyond the nine numbered shortcuts")
	await get_tree().process_frame
	var scroll: ScrollContainer = strip.chips()[13].get_parent().get_parent() as ScrollContainer
	expect(scroll.scroll_horizontal > 0, "focused offscreen chip scrolls into view")
	strip.chips()[0].grab_focus()
	press("Shift+Tab")
	var all: Button = get_viewport().gui_get_focus_owner() as Button
	expect(all == strip.list_button() and all.tooltip_text == "Worktrees", "the worktree icon is in the Tab order before the chips")
	press("Enter")
	var menu: PopupMenu = null
	for child: Node in strip.get_children():
		if child is PopupMenu and (child as PopupMenu).visible:
			menu = child as PopupMenu
	expect(menu != null and menu.item_count == 14, "Enter opens all worktrees")
	if menu != null:
		await _popup_key("Down", menu)
		await _popup_key("Escape", menu)
		expect(not menu.visible, "Escape closes the worktree list")
		expect(all.has_focus(), "Escape returns focus to the worktree icon")
		var chosen: Array[String] = []
		strip.worktree_chosen.connect(func(path: String) -> void: chosen.append(path))
		press("Enter")
		await _popup_key("Down", menu)
		var target: String = String(worktrees[menu.get_focused_item()]["path"])
		await _popup_key("Enter", menu)
		expect_eq(chosen, [target] as Array[String], "arrows and Enter choose the highlighted worktree")
	strip.chips()[13].grab_focus()
	var focused_path: String = strip.chips()[13].path()
	worktrees[13]["name"] = "aaa-reordered"
	strip.show_worktrees(worktrees, String(worktrees[0]["path"]))
	var restored: WorktreeChip = get_viewport().gui_get_focus_owner() as WorktreeChip
	expect(restored != null and restored.path() == focused_path, "refresh preserves focused worktree by path")
	worktrees.remove_at(13)
	strip.show_worktrees(worktrees, String(worktrees[0]["path"]))
	expect(strip.chips()[0].has_focus(), "removing the focused worktree falls back to the selected chip")
	all.grab_focus()
	strip.size.x = 10000.0
	await get_tree().process_frame
	await get_tree().process_frame
	expect(not strip.overflows() and all.visible and all.has_focus(), "resizing away overflow keeps the worktree icon and its focus")
	strip.queue_free()
	await get_tree().process_frame


func _popup_key(shortcut: String, popup: PopupMenu) -> void:
	var event: InputEventKey = Shortcuts.parse(shortcut)
	event.window_id = popup.get_window_id()
	Input.parse_input_event(event)
	await get_tree().process_frame
	event = event.duplicate() as InputEventKey
	event.pressed = false
	Input.parse_input_event(event)
	await get_tree().process_frame
