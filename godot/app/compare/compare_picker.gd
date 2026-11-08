class_name ComparePicker
extends PopupPanel
## Picks one side of a comparison (PLAN M7.12): a filter, then Working copy
## (right side only), the local branches, remote branches, tags and recent
## commits (recent comparisons have their own popover, M7.12c). While the
## filter has text, the matching rows come first and the last row uses the
## text itself as a revision (`HEAD~3`, a hash, `v1.2^`);
## Enter takes the selected row. A revision git does not know shows as the
## comparison's error. Sizes and colours are the `BranchPopover` theme's.

## A side was chosen: a revision, or the working copy when `working`.
signal side_chosen(spec: String, working: bool)

const THEME_TYPE: StringName = &"BranchPopover"
const FILTER_FIELD: PackedScene = preload("res://ui/filter_field/filter_field.tscn")
## Recent commits listed (from the top of the history).
const RECENT_COMMITS: int = 20

var session: RepoSession = null

var _filter: FilterField = FILTER_FIELD.instantiate() as FilterField
var _tree: Tree = Tree.new()
## Whether the working copy can be chosen (the right side only).
var _allow_working: bool = false
## The side shown when the picker opened, selected when listed.
var _current: String = ""
var _scale: float = 1.0


func _ready() -> void:
	var box: VBoxContainer = VBoxContainer.new()
	add_child(box)
	_filter.placeholder = tr("Branch, tag or revision")
	_filter.changed.connect(_rebuild)
	_filter.submitted.connect(func(_backwards: bool) -> void: _choose(_tree.get_selected()))
	_filter.done.connect(func() -> void:
		_tree.grab_focus()
		_select_first())
	box.add_child(_filter)
	_tree.hide_root = true
	_tree.hide_folding = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_activated.connect(func() -> void: _choose(_tree.get_selected()))
	_tree.gui_input.connect(_on_tree_input)
	box.add_child(_tree)
	AutoScroll.enable(_tree)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_filter.placeholder = tr("Branch, tag or revision")
		_rebuild()


## Opens under `anchor` with an empty filter, `current` selected.
func open_below(anchor: Control, allow_working: bool, current: String) -> void:
	_allow_working = allow_working
	_current = current
	_filter.set_text("")
	_rebuild()
	_scale = anchor.get_window().content_scale_factor
	var at: Vector2 = anchor.get_screen_transform() * Vector2(0.0, anchor.size.y)
	popup(Rect2i(Vector2i(at), Vector2i(Vector2(get_theme_constant(&"width", THEME_TYPE),
			get_theme_constant(&"height", THEME_TYPE)) * _scale)))
	_filter.focus_text()


func set_filter(text: String) -> void:
	_filter.set_text(text)
	_rebuild()


## The choosable rows' labels in order (for tests).
func row_labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var root: TreeItem = _tree.get_root()
	if root == null:
		return out
	for section: TreeItem in root.get_children():
		if section.get_metadata(0) is Dictionary:
			out.append(section.get_text(0))
		for item: TreeItem in section.get_children():
			out.append(item.get_text(0))
	return out


## Chooses the selected row, as Enter does (for tests).
func choose_selected() -> void:
	_choose(_tree.get_selected())


## Chooses the row labelled `label`, as a click does (for tests).
func choose_row(label: String) -> bool:
	for item: TreeItem in _rows():
		if item.get_text(0) == label:
			_choose(item)
			return true
	return false


func _rebuild() -> void:
	_tree.clear()
	var root: TreeItem = _tree.create_item()
	if session == null or not session.is_ready():
		return
	var query: String = _filter.text().strip_edges()
	var lower: String = query.to_lower()
	var matches: Callable = func(text: String) -> bool: return lower.is_empty() or text.to_lower().contains(lower)
	if _allow_working and matches.call(tr("Working copy")):
		_add(root, tr("Working copy"), &"FileList", {"spec": "", "working": true}, tr("Your files as they are now"))
	var local: Array[Dictionary] = []
	var remote: Array[Dictionary] = []
	for ref: Dictionary in session.branch_refs():
		if matches.call(String(ref["short_name"])):
			(local if String(ref["kind"]) == "branch" else remote).append(ref)
	var exact: bool = false
	for entry: Array in [["Branches", local, &"GitBranch"], ["Remote branches", remote, &"GitRemote"]]:
		var refs: Array[Dictionary] = entry[1]
		if refs.is_empty():
			continue
		var section: TreeItem = _section(root, entry[0])
		for ref: Dictionary in refs:
			var short: String = String(ref["short_name"])
			exact = exact or short == query
			var item: TreeItem = _add(section, short, entry[2], {"spec": short, "working": false}, String(ref["name"]))
			if bool(ref["is_head"]):
				item.set_icon(0, AppTheme.icon(&"StatusSuccess"))
				item.set_icon_modulate(0, get_theme_color(&"head_color", THEME_TYPE))
	var tags: Array[Dictionary] = []
	for tag: Dictionary in session.tags():
		if matches.call(String(tag["name"])):
			tags.append(tag)
	if not tags.is_empty():
		var section: TreeItem = _section(root, "Tags")
		for tag: Dictionary in tags:
			exact = exact or String(tag["name"]) == query
			_add(section, String(tag["name"]), &"GitTag", {"spec": String(tag["name"]), "working": false},
					String(tag["commit"]).left(10))
	var commits: Array[Dictionary] = []
	for row: Dictionary in session.graph_rows(0, RECENT_COMMITS):
		var oid: String = String(row["hash"])
		if matches.call(String(row["subject"])) or (not lower.is_empty() and oid.begins_with(lower)):
			commits.append(row)
	if not commits.is_empty():
		var section: TreeItem = _section(root, "Recent commits")
		for row: Dictionary in commits:
			var oid: String = String(row["hash"])
			_add(section, String(row["subject"]), &"GitCommit", {"spec": oid, "working": false},
					"%s\n%s" % [String(row["subject"]), String(row["author"])])
	if not query.is_empty() and not exact:
		_add(root, tr("Use revision “%s”") % query, &"Search", {"spec": query, "working": false},
				tr("Any revision git knows: a hash, HEAD~3, v1.2^…"))
	_select_current()


func _section(parent: TreeItem, text: String) -> TreeItem:
	var item: TreeItem = _tree.create_item(parent)
	item.set_text(0, tr(text))
	item.set_selectable(0, false)
	item.set_custom_color(0, get_theme_color(&"section_color", THEME_TYPE))
	return item


func _add(parent: TreeItem, text: String, icon: StringName, side: Dictionary, tooltip: String) -> TreeItem:
	var item: TreeItem = _tree.create_item(parent)
	item.set_text(0, text)
	item.set_icon(0, AppTheme.icon(icon))
	item.set_icon_modulate(0, get_theme_color(&"icon_color", THEME_TYPE))
	item.set_metadata(0, side)
	item.set_tooltip_text(0, tooltip)
	return item


## Selects the side the picker opened on when listed (and no filter is
## typed), else the first row.
func _select_current() -> void:
	if _filter.text().strip_edges().is_empty():
		for item: TreeItem in _rows():
			var side: Dictionary = item.get_metadata(0)
			if (bool(side["working"]) and _current.is_empty() and _allow_working) or \
					(not _current.is_empty() and String(side["spec"]) == _current):
				item.select(0)
				_tree.scroll_to_item(item)
				return
	_select_first()


func _select_first() -> void:
	var rows: Array[TreeItem] = _rows()
	if not rows.is_empty():
		rows[0].select(0)
		_tree.scroll_to_item(rows[0])


## Choosable rows in order.
func _rows() -> Array[TreeItem]:
	var out: Array[TreeItem] = []
	var root: TreeItem = _tree.get_root()
	if root == null:
		return out
	for child: TreeItem in root.get_children():
		if child.get_metadata(0) is Dictionary:
			out.append(child)
		for item: TreeItem in child.get_children():
			out.append(item)
	return out


func _choose(item: TreeItem) -> void:
	if item == null or not item.get_metadata(0) is Dictionary:
		return
	var side: Dictionary = item.get_metadata(0)
	hide()
	side_chosen.emit(String(side["spec"]), bool(side["working"]))


## A click chooses the row it was released over; Up on the first row goes
## back to the filter.
func _on_tree_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT and not button.pressed:
		var at: TreeItem = _tree.get_item_at_position(button.position)
		if at != null and at == _tree.get_selected():
			_choose(at)
		return
	var rows: Array[TreeItem] = _rows()
	if event.is_action_pressed("ui_up", false, true) and not rows.is_empty() and _tree.get_selected() == rows[0]:
		_filter.focus_text()
		_tree.accept_event()
