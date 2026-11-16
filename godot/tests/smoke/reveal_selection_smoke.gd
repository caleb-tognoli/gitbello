extends SmokeTest
## `list.reveal_selection` (K): the focused list scrolls back to its selected
## row (the cursor's when it is selected) and centres it; an item list shows
## its current item; nothing happens without a selection, in a diff or while
## a text field has the focus (K types there). History's commit list on a
## fixture repository can use it, its diff cannot. The History part is
## skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


class RowList:
	extends VirtualList

	func _get_row_count() -> int:
		return 1000


func run() -> void:
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var action: ActionRegistry.Action = Actions.get_action(&"list.reveal_selection")
	expect(action != null, "the action is registered")
	if action == null:
		main.queue_free()
		return
	expect_eq(Actions.shortcuts(&"list.reveal_selection"), PackedStringArray(["K"]), "K by default")
	expect(Actions.with_shortcuts().has(action), "Settings → Keyboard lists it, so it can be rebound")
	expect(not Actions.listed().has(action), "the palette leaves it out, like History's F")

	await _test_list()
	await _test_item_list()
	await _test_history(main)
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()


func _test_list() -> void:
	var list: RowList = RowList.new()
	add_child(list)
	list.position = Vector2.ZERO
	list.size = Vector2(300, 200)
	list.refresh()
	await get_tree().process_frame
	list.grab_focus()
	expect(VirtualList.revealable(list) == null, "a list without a selection has nothing to reveal")
	press("K")
	expect_eq(list.scroll_offset(), 0.0, "K without a selection does not scroll")

	list.select_only(500)
	list.set_scroll_offset(0.0)
	press("K")
	var middle: float = list.row_top(500) + list.row_extent(500) / 2.0 - list.scroll_offset()
	expect(absf(middle - list.size.y / 2.0) <= 1.0, "K centres the selected row: %s" % middle)

	list.set_scroll_offset(list.max_scroll_offset())
	press("K")
	expect(list.row_at(Vector2(10, list.size.y / 2.0)) == 500, "K brings it back from below")

	list.select_only(999)
	list.set_scroll_offset(0.0)
	press("K")
	expect_eq(list.scroll_offset(), list.max_scroll_offset(), "the last row scrolls as far as the list goes")

	# The cursor's row when it is selected, else the first selected one.
	list.select_only(200)
	list._toggle(700)
	expect_eq(list.selection_row(), 700, "the cursor's selected row")
	list._toggle(700)
	expect_eq(list.selection_row(), 200, "the first selected row when the cursor's is not")

	var field: LineEdit = LineEdit.new()
	add_child(field)
	field.position = Vector2(0, 220)
	field.size = Vector2(200, 30)
	list.set_scroll_offset(0.0)
	field.grab_focus()
	await get_tree().process_frame
	type_text("k")
	expect_eq(field.text, "k", "K types in a text field")
	expect_eq(list.scroll_offset(), 0.0, "the list does not scroll while typing")
	field.queue_free()

	list.queue_free()


func _test_item_list() -> void:
	var items: ItemList = ItemList.new()
	for i: int in 300:
		items.add_item("Item %d" % i)
	add_child(items)
	items.position = Vector2.ZERO
	items.size = Vector2(300, 200)
	await get_tree().process_frame
	items.select(250)
	items.get_v_scroll_bar().value = 0.0
	items.grab_focus()
	await get_tree().process_frame
	expect(VirtualList.revealable(items) == items, "an item list with a selection can be revealed")
	press("K")
	await get_tree().process_frame
	expect(items.get_v_scroll_bar().value > 0.0, "K scrolls an item list to its selected item")
	items.queue_free()


func _test_history(main: Main) -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("reveal_selection_smoke: no --fixtures, History skipped")
		return
	var page: RepoTab = main.open_repo(fixtures.path_join("repo-5"))
	var list: CommitList = page.history().commit_list()
	expect(await wait_until(func() -> bool: return list.row_count() > 0 and list.cursor == 0),
			"History selects the newest commit")
	expect(VirtualList.revealable(list) == list, "History's commit list can be revealed")
	list.grab_focus()
	expect(Actions.get_action(&"list.reveal_selection").is_enabled(), "K is enabled on the focused commit list")
	var diff: DiffView = page.history().details().diff_panel().view()
	expect(not diff.reveals_selection, "a diff's lines are not revealed")
	diff.grab_focus()
	expect(not Actions.get_action(&"list.reveal_selection").is_enabled(), "K does nothing in a diff")
