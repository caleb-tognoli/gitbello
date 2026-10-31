class_name ShelfList
extends VBoxContainer
## Shelf names grouped under collapsible branch headings. Shelf selection
## never rebuilds the native list during its input event.

signal shelf_selected(shelf: Dictionary)
signal menu_requested(shelf: Dictionary, at: Vector2)

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
var _picker: PopupPanel = PopupPanel.new()
var _choices: VBoxContainer = VBoxContainer.new()
var _all_check: CheckBox = null
var _checks: Dictionary[String, CheckBox] = {}

@onready var _filter: FilterField = %ShelfFilter
@onready var _names: ItemList = %ShelfNames
@onready var _empty: Label = %NoShelvesMatch


func _ready() -> void:
	_filter.changed.connect(_rebuild)
	_filter.done.connect(focus_list)
	_filter.submitted.connect(func(_backwards: bool) -> void: focus_list())
	_branch_button = _filter.add_button(&"GitBranch", "Filter shelves by branch")
	_branch_button.focus_mode = Control.FOCUS_ALL
	_branch_button.add_child(_branch_badge)
	_branch_button.pressed.connect(func() -> void: Actions.run_action(&"shelf.filter_branches", _branch_button))
	_names.item_selected.connect(_on_selected)
	_names.item_clicked.connect(_on_clicked)
	_picker.theme_type_variation = &"ShelfBranchPicker"
	add_child(_picker)
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_picker.add_child(scroll)
	_choices.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_choices.theme_type_variation = &"PaneColumn"
	scroll.add_child(_choices)
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


func branch_picker() -> PopupPanel:
	return _picker


func branch_check(branch: String) -> CheckBox:
	return _checks.get(branch)


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


func open_branches() -> void:
	for child: Node in _choices.get_children():
		_choices.remove_child(child)
		child.queue_free()
	_checks.clear()
	_all_check = _choice("All branches", _shelves.size())
	_all_check.toggled.connect(func(on: bool) -> void:
		Actions.run_action(&"shelf.scope_all" if on else &"shelf.scope_none", _all_check))
	_choices.add_child(HSeparator.new())
	for branch: String in _available_branches():
		var count: int = 0
		for shelf: Dictionary in _shelves:
			if String(shelf["branch"]) == branch:
				count += 1
		var label: String = branch if not branch.is_empty() else tr("No branch")
		if branch == _branch and not branch.is_empty():
			label += tr(" (current)")
		var check: CheckBox = _choice(label, count)
		_checks[branch] = check
		check.pressed.connect(func() -> void:
			_pending_branch = branch
			Actions.run_action(&"shelf.toggle_filter_branch", check))
	_sync_checks()
	var width: int = get_theme_constant(&"width", &"ShelfBranchPicker")
	var height: int = mini(get_theme_constant(&"max_height", &"ShelfBranchPicker"),
			int(_choices.get_combined_minimum_size().y) + get_theme_constant(&"padding", &"ShelfBranchPicker"))
	_picker.size = Vector2i(width, height)
	_picker.position = Vector2i(_branch_button.get_screen_position() + Vector2(0, _branch_button.size.y))
	_picker.popup()


func _choice(label: String, count: int) -> CheckBox:
	var check: CheckBox = CheckBox.new()
	check.text = label
	check.tooltip_text = label
	_choices.add_child(check)
	var badge: CountBadge = CountBadge.new()
	check.add_child(badge)
	badge.count = count
	return check


func _available_branches() -> PackedStringArray:
	var branches: PackedStringArray = PackedStringArray([_branch])
	for shelf: Dictionary in _shelves:
		var branch: String = String(shelf["branch"])
		if not branch in branches:
			branches.append(branch)
	branches.sort()
	return branches


func _sync_checks() -> void:
	if is_instance_valid(_all_check):
		_all_check.set_pressed_no_signal(_all_branches)
	for branch: String in _checks:
		_checks[branch].set_pressed_no_signal(_all_branches or branch in _branches)


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
	_empty.visible = _shown.is_empty()
	_empty.text = tr("No branches selected.") if not _all_branches and _branches.is_empty() else tr("No shelves match the filter.")
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
