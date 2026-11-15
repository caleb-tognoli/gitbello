class_name BasePopover
extends PopupPanel
## Where a new worktree's branch starts (PLAN §4 New task): a filter over
## the local branches, remote branches and tags, in sections. Text that names
## none of them offers itself first ("Use a1b2c3d"), for a commit or any other
## revision git knows. Enter or a click chooses.

signal base_chosen(base: String)

const THEME_TYPE: StringName = &"BranchPopover"
const FILTER_FIELD: PackedScene = preload("res://ui/filter_field/filter_field.tscn")

var session: RepoSession = null

var _filter: FilterField = FILTER_FIELD.instantiate() as FilterField
var _tree: Tree = Tree.new()
var _empty: Label = Label.new()
## The base shown when it opened, selected while the filter is empty.
var _current: String = ""
var _scale: float = 1.0
var _width: float = 0.0


func _ready() -> void:
	var box: VBoxContainer = VBoxContainer.new()
	add_child(box)
	_filter.placeholder = tr("Branch, tag or commit")
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
	_empty.theme_type_variation = &"DimLabel"
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_empty.hide()
	box.add_child(_empty)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_filter.placeholder = tr("Branch, tag or commit")
		_rebuild()


## Opens under `anchor` with an empty filter, on `current`.
func open_below(anchor: Control, current: String) -> void:
	_current = current
	_filter.set_text("")
	_rebuild()
	_scale = anchor.get_window().content_scale_factor
	var at: Vector2 = anchor.get_screen_transform() * Vector2(0.0, anchor.size.y)
	_width = maxf(anchor.size.x, float(get_theme_constant(&"width", THEME_TYPE)))
	popup(Rect2i(Vector2i(at), Vector2i(Vector2(_width, 0.0) * _scale)))
	_fit()
	_filter.focus_text()


## Sizes the list to its rows, up to the theme's `height`.
func _fit() -> void:
	if not visible:
		return
	var root: TreeItem = _tree.get_root()
	var last: TreeItem = root.get_child(root.get_child_count() - 1) if root != null and root.get_child_count() > 0 else null
	_tree.custom_minimum_size.y = 0.0
	var rows: float = 0.0
	if last != null:
		var panel: StyleBox = _tree.get_theme_stylebox(&"panel")
		# Item rects are relative to the scroll.
		rows = _tree.get_item_area_rect(last).end.y + _tree.get_scroll().y \
				+ panel.get_margin(SIDE_TOP) + panel.get_margin(SIDE_BOTTOM)
	var chrome: float = get_contents_minimum_size().y - _tree.get_combined_minimum_size().y * float(_tree.visible)
	var tree_height: float = minf(rows, get_theme_constant(&"height", THEME_TYPE) - chrome)
	_tree.custom_minimum_size.y = tree_height
	size = Vector2i(Vector2(_width, chrome + tree_height) * _scale)


func set_filter(text: String) -> void:
	_filter.set_text(text)


## The rows' texts in order, sections included (for tests).
func row_labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var root: TreeItem = _tree.get_root()
	if root != null:
		for item: TreeItem in root.get_children():
			out.append(item.get_text(0))
	return out


## Chooses the selected row, as Enter would (for tests).
func choose_selected() -> void:
	_choose(_tree.get_selected())


## The sections, as `[title, [{name, icon}]]`: Local and Remote branches,
## A–Z, then Tags as listed (newest name first), filtered by
## `query`; a `query` that names none of them is offered as typed: alone
## when nothing matches, else last, under Revision.
static func sections(branches: Array[Dictionary], tags: Array[Dictionary], query: String) -> Array:
	var local: Array[Dictionary] = []
	var remote: Array[Dictionary] = []
	var tag_rows: Array[Dictionary] = []
	var needle: String = query.strip_edges().to_lower()
	var exact: bool = false
	for ref: Dictionary in branches:
		var short: String = String(ref["short_name"])
		if short.ends_with("/HEAD"):
			continue
		exact = exact or short == query.strip_edges()
		if needle.is_empty() or short.to_lower().contains(needle):
			(local if String(ref["kind"]) == "branch" else remote).append({"name": short,
				"icon": &"GitBranch" if String(ref["kind"]) == "branch" else &"GitRemote"})
	for tag: Dictionary in tags:
		var tag_name: String = String(tag["name"])
		exact = exact or tag_name == query.strip_edges()
		if needle.is_empty() or tag_name.to_lower().contains(needle):
			tag_rows.append({"name": tag_name, "icon": &"GitTag"})
	var by_name: Callable = func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["name"]).naturalnocasecmp_to(String(b["name"])) < 0
	local.sort_custom(by_name)
	remote.sort_custom(by_name)
	var out: Array = []
	for section: Array in [["Local", local], ["Remote", remote], ["Tags", tag_rows]]:
		if not (section[1] as Array).is_empty():
			out.append(section)
	# Typed text that names nothing listed: first when nothing matches, else
	# after the matches (a commit, or a ref the lists leave out).
	if not needle.is_empty() and not exact:
		var typed: Array = ["" if out.is_empty() else "Revision",
			[{"name": query.strip_edges(), "icon": &"GitCommit", "typed": true}]]
		out.append(typed)
	return out


func _rebuild() -> void:
	_tree.clear()
	var root: TreeItem = _tree.create_item()
	if session == null:
		return
	var query: String = _filter.text()
	for section: Array in sections(session.branch_refs(), session.tags(), query):
		if not String(section[0]).is_empty():
			var header: TreeItem = _tree.create_item(root)
			header.set_text(0, tr(String(section[0])))
			header.set_selectable(0, false)
			header.set_custom_color(0, get_theme_color(&"section_color", THEME_TYPE))
		for row: Dictionary in section[1]:
			var item: TreeItem = _tree.create_item(root)
			var row_name: String = String(row["name"])
			item.set_text(0, tr("Use %s") % row_name if bool(row.get("typed", false)) else row_name)
			item.set_icon(0, AppTheme.icon(StringName(row["icon"])))
			item.set_tooltip_text(0, row_name)
			item.set_metadata(0, row_name)
	var any: bool = root.get_child_count() > 0
	_tree.visible = any
	_empty.visible = not any
	_empty.text = tr("No branches or tags")
	if query.strip_edges().is_empty():
		_select_named(_current)
	else:
		_select_first()
	_fit()


func _select_named(base_name: String) -> void:
	for item: TreeItem in _tree.get_root().get_children():
		if item.get_metadata(0) is String and String(item.get_metadata(0)) == base_name:
			item.select(0)
			_tree.scroll_to_item(item)
			return
	_tree.deselect_all()


func _select_first() -> void:
	for item: TreeItem in _tree.get_root().get_children():
		if item.get_metadata(0) is String:
			item.select(0)
			_tree.scroll_to_item(item)
			return


func _choose(item: TreeItem) -> void:
	if item == null or not item.get_metadata(0) is String:
		return
	hide()
	base_chosen.emit(String(item.get_metadata(0)))


## A click chooses its row once released over it; Up on the first row goes
## back to the filter.
func _on_tree_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		var at: TreeItem = _tree.get_item_at_position(button.position)
		if at != null and not at.get_metadata(0) is String:
			_tree.accept_event()
		elif at != null and not button.pressed and at == _tree.get_selected():
			_choose(at)
		return
	if event.is_action_pressed("ui_up", false, true):
		var first: TreeItem = null
		for item: TreeItem in _tree.get_root().get_children():
			if item.get_metadata(0) is String:
				first = item
				break
		if first != null and first == _tree.get_selected():
			_filter.focus_text()
			_tree.accept_event()
