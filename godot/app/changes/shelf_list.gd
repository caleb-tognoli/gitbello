class_name ShelfList
extends VBoxContainer
## Shelf names grouped under collapsible branch headings. Shelf selection
## never rebuilds the native list during its input event.

signal shelf_selected(shelf: Dictionary)
signal menu_requested(shelf: Dictionary, at: Vector2)

const ALL_ID: String = "all"
const BRANCH_PREFIX: String = "branch:"

var _shelves: Array[Dictionary] = []
var _shown: Array[Dictionary] = []
## Native rows, including a `group` dictionary for each branch heading.
var _rows: Array[Dictionary] = []
var _expanded: Dictionary[String, bool] = {}
var _pending_group: String = ""
var _branch: String = ""
var _selected_oid: String = ""
var _replacement_oid: String = ""
var _all_branches: bool = true
var _branches: PackedStringArray = PackedStringArray()
var _pending_branch: String = ""
var _branch_button: Button = null
var _branch_badge: CountBadge = CountBadge.new()
## Rebuilt each time it opens: the branches come and go with the shelves.
var _picker: OptionsPopover = OptionsPopover.new()

@onready var _filter: FilterField = %ShelfFilter
@onready var _names: ItemList = %ShelfNames
## Over the list when it shows no shelf: no branch chosen, the filter hides
## every shelf, or there is none.
var _empty: EmptyState = null


func _ready() -> void:
	_empty = EmptyState.create_compact()
	_names.add_child(_empty)
	_filter.changed.connect(_rebuild)
	_filter.done.connect(focus_list)
	_filter.submitted.connect(func(_backwards: bool) -> void: focus_list())
	_branch_button = _filter.add_button(&"GitBranch", "Filter shelves by branch")
	_branch_button.focus_mode = Control.FOCUS_ALL
	_branch_button.add_child(_branch_badge)
	_branch_button.pressed.connect(func() -> void: Actions.run_action(&"shelf.filter_branches", _branch_button))
	_names.item_selected.connect(_on_selected)
	_names.item_clicked.connect(_on_clicked)
	add_child(_picker)
	_rebuild()


func show_shelves(shelves: Array[Dictionary], branch: String) -> void:
	_shelves = shelves
	if branch != _branch:
		_expanded.clear()
	_branch = branch
	_rebuild()


func shelf_count() -> int:
	return _shelves.size()


func own_shelves() -> Array[Dictionary]:
	var own: Array[Dictionary] = []
	for shelf: Dictionary in _shelves:
		if not _branch.is_empty() and String(shelf["branch"]) == _branch:
			own.append(shelf)
	return own


func selected_shelf() -> Dictionary:
	for shelf: Dictionary in _shown:
		if String(shelf["oid"]) == _selected_oid:
			return shelf
	return {}


## The replacement arrives before its stash-list refresh.
func replace_shelf(old_oid: String, new_oid: String) -> void:
	if _selected_oid == old_oid:
		_replacement_oid = new_oid


func select_shelf(oid: String) -> bool:
	for shelf: Dictionary in _shown:
		if String(shelf["oid"]) == oid and not branch_expanded(String(shelf["branch"])):
			_expanded[String(shelf["branch"])] = true
			_rebuild()
	var index: int = row_for_shelf(oid)
	if index < 0:
		return false
	_names.select(index)
	_names.ensure_current_is_visible()
	_on_selected(index)
	return true


func row_for_shelf(oid: String) -> int:
	for index: int in _rows.size():
		if String(_rows[index].get("oid", "")) == oid:
			return index
	return -1


func branch_groups() -> PackedStringArray:
	var labels: PackedStringArray = PackedStringArray()
	for index: int in _rows.size():
		if _rows[index].has("group"):
			labels.append(_names.get_item_text(index))
	return labels


func branch_expanded(branch: String) -> bool:
	return _expanded.get(branch, branch == _branch)


func toggle_pending_group() -> void:
	_expanded[_pending_group] = not branch_expanded(_pending_group)
	_rebuild()


func names() -> ItemList:
	return _names


func filter_field() -> FilterField:
	return _filter


func branch_button() -> Button:
	return _branch_button


func branch_badge() -> CountBadge:
	return _branch_badge


func branch_picker() -> OptionsPopover:
	return _picker


func branch_check(branch: String) -> CheckBox:
	return _picker.control(BRANCH_PREFIX + branch) as CheckBox


func focus_filter() -> void:
	_filter.focus_text()


func focus_list() -> void:
	_names.grab_focus()


func row_texts() -> PackedStringArray:
	var labels: PackedStringArray = PackedStringArray()
	for shelf: Dictionary in _shown:
		labels.append(String(shelf["name"]))
	return labels


func set_scope(all: bool) -> void:
	_all_branches = all
	_branches = PackedStringArray() if all else PackedStringArray([_branch])
	_rebuild()
	_sync_checks()


func set_branches(branches: PackedStringArray) -> void:
	_all_branches = false
	_branches = branches.duplicate()
	_rebuild()
	_sync_checks()


func all_branches() -> bool:
	return _all_branches


func selected_branches() -> PackedStringArray:
	return _available_branches() if _all_branches else _branches.duplicate()


func toggle_pending_branch() -> void:
	var selected: PackedStringArray = selected_branches()
	var index: int = selected.find(_pending_branch)
	if index >= 0:
		selected.remove_at(index)
	else:
		selected.append(_pending_branch)
	set_branches(selected)


## Opens the branch filter: All branches, then a check row per branch with
## its shelf count, in the shared options popover.
func open_branches() -> void:
	_picker.hide()
	remove_child(_picker)
	_picker.queue_free()
	_picker = OptionsPopover.new()
	_picker.return_focus = _branch_button
	add_child(_picker)
	_picker.add_section("Branches", &"", &"GitBranch")
	var rows: Array[Dictionary] = [
		{"id": ALL_ID, "label": "All branches", "count": _shelves.size(), "counted": false},
		{"separator": true},
	]
	for branch: String in _available_branches():
		var count: int = 0
		for shelf: Dictionary in _shelves:
			if String(shelf["branch"]) == branch:
				count += 1
		var label: String = branch if not branch.is_empty() else tr("No branch")
		if branch == _branch and not branch.is_empty():
			label += tr(" (current)")
		rows.append({"id": BRANCH_PREFIX + branch, "label": label, "translate": false,
				"count": count, "counted": false})
	_picker.add_checks(rows)
	_picker.changed.connect(_on_picked)
	_sync_checks()
	_picker.open_below(_branch_button)


func _on_picked(id: String, on: Variant) -> void:
	var source: Control = _picker.control(id)
	if id == ALL_ID:
		Actions.run_action(&"shelf.scope_all" if bool(on) else &"shelf.scope_none", source)
	else:
		_pending_branch = id.trim_prefix(BRANCH_PREFIX)
		Actions.run_action(&"shelf.toggle_filter_branch", source)


func _available_branches() -> PackedStringArray:
	var branches: PackedStringArray = PackedStringArray([_branch])
	for shelf: Dictionary in _shelves:
		var branch: String = String(shelf["branch"])
		if not branch in branches:
			branches.append(branch)
	branches.sort()
	return branches


func _sync_checks() -> void:
	for id: String in _picker.ids():
		if id == ALL_ID:
			_picker.set_value(id, _all_branches)
		else:
			_picker.set_value(id, _all_branches or id.trim_prefix(BRANCH_PREFIX) in _branches)


## What the list says without shelves to show, with a way out when there is
## one.
func _update_empty(query: String) -> void:
	_empty.visible = _shown.is_empty()
	if not _empty.visible:
		return
	if not _all_branches and _branches.is_empty():
		_empty.show_compact(&"GitBranch", "No branches selected", "All branches", set_scope.bind(true), &"GitBranch")
	elif not query.is_empty():
		_empty.show_no_match(func() -> void: _filter.clear_filters())
	elif _all_branches or _shelves.is_empty():
		_empty.show_compact(&"GitShelf", "No shelves")
	else:
		_empty.show_compact(&"GitShelf", "No shelves on these branches", "All branches", set_scope.bind(true), &"GitBranch")


## The list's empty state (smoke tests).
func empty_state() -> EmptyState:
	return _empty


func _rebuild() -> void:
	if not _replacement_oid.is_empty():
		for shelf: Dictionary in _shelves:
			if String(shelf["oid"]) == _replacement_oid:
				_selected_oid = _replacement_oid
				_replacement_oid = ""
				break
	_shown.clear()
	_rows.clear()
	_names.clear()
	var query: String = _filter.text().strip_edges().to_lower()
	var selected_index: int = -1
	var first_index: int = -1
	var branches: PackedStringArray = _available_branches()
	branches.remove_at(branches.find(_branch))
	branches.insert(0, _branch)
	for branch: String in branches:
		if not _all_branches and not branch in _branches:
			continue
		var has_heading: bool = false
		for shelf: Dictionary in _shelves:
			if String(shelf["branch"]) != branch:
				continue
			if not query.is_empty() and not String(shelf["name"]).to_lower().contains(query):
				continue
			if not has_heading:
				var arrow: StringName = &"GuiTreeArrowDown" if branch_expanded(branch) else &"GuiTreeArrowRight"
				var group: int = _names.add_item(branch if not branch.is_empty() else tr("No branch"), AppTheme.icon(arrow))
				_names.set_item_selectable(group, false)
				_names.set_item_tooltip(group, tr("Collapse branch") if branch_expanded(branch) else tr("Expand branch"))
				_rows.append({"group": branch})
				has_heading = true
			_shown.append(shelf)
			if not branch_expanded(branch):
				continue
			var index: int = _names.add_item(String(shelf["name"]))
			if first_index < 0:
				first_index = index
			if String(shelf["oid"]) == _selected_oid:
				selected_index = index
			_rows.append(shelf)
			_names.set_item_tooltip(index, "%s\n%s" % [shelf["name"], shelf["branch"]])
	_apply_group_colors()
	_update_empty(query)
	_branch_button.text = tr("All") if _all_branches else (tr("Branch") if _branches.size() == 1 else tr("Branches"))
	_branch_button.tooltip_text = tr("All branches") if _all_branches else tr("Branches: %s") % ", ".join(_branches)
	_branch_badge.count = selected_branches().size()
	if selected_index < 0 and selected_shelf().is_empty():
		selected_index = first_index
	if selected_index >= 0:
		_names.select(selected_index)
		_on_selected(selected_index)
	else:
		# A collapsed group can still own the detail selection.
		if selected_shelf().is_empty():
			_selected_oid = ""
		shelf_selected.emit(selected_shelf())


func _on_selected(index: int) -> void:
	if index >= 0 and index < _rows.size() and _rows[index].has("group"):
		return
	_selected_oid = String(_rows[index]["oid"]) if index >= 0 and index < _rows.size() else ""
	shelf_selected.emit(selected_shelf())


func _on_clicked(index: int, at: Vector2, button: int) -> void:
	if index < 0 or index >= _rows.size():
		return
	if _rows[index].has("group"):
		if button == MOUSE_BUTTON_LEFT:
			# Never clear the ItemList while its native input handler is running.
			_toggle_group.call_deferred(String(_rows[index]["group"]))
		return
	if button == MOUSE_BUTTON_RIGHT:
		_names.select(index)
		_on_selected(index)
		menu_requested.emit(selected_shelf(), _names.get_screen_position() + at)


func _toggle_group(branch: String) -> void:
	_pending_group = branch
	Actions.run_action(&"shelf.toggle_branch_group", _names)


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_group_colors.call_deferred()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		_rebuild()


func _apply_group_colors() -> void:
	for index: int in _rows.size():
		if _rows[index].has("group"):
			_names.set_item_custom_fg_color(index, get_theme_color(&"group_color", &"ShelfNames"))
			_names.set_item_custom_bg_color(index, get_theme_color(&"group_background", &"ShelfNames"))
