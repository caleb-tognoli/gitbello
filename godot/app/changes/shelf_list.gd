class_name ShelfList
extends VBoxContainer
## The Shelved section under the changed files (PLAN §4 Shelves): a header
## that collapses it, the current branch's shelves, then "Other branches (N)"
## (collapsed). A shelf expands to its files (read on first expand); choosing
## a file previews its diff. Right-click opens the shelf's menu.

## A shelf's files are wanted (first expand).
signal files_wanted(oid: String)
## A shelved file was chosen: preview it.
signal file_chosen(oid: String, path: String)
## A shelf (or one of its files) is now the selected one; {} when none.
signal shelf_selected(shelf: Dictionary)
## The menu of `shelf` was asked for at `at` (screen position).
signal menu_requested(shelf: Dictionary, at: Vector2)

const THEME_TYPE: StringName = &"ShelfList"

var _header: Button = Button.new()
var _tree: Tree = Tree.new()
var _shelves: Array[Dictionary] = []
## Loaded files per shelf commit.
var _files: Dictionary[String, Array] = {}
var _expanded: Dictionary[String, bool] = {}
var _others_open: bool = false
var _collapsed: bool = false
var _branch: String = ""


func _ready() -> void:
	_header.flat = true
	_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header.focus_mode = Control.FOCUS_NONE
	_header.theme_type_variation = &"SectionHeaderButton"
	_header.pressed.connect(func() -> void:
		_collapsed = not _collapsed
		_update_header())
	add_child(_header)
	_tree.hide_root = true
	_tree.allow_rmb_select = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.theme_type_variation = &"ShelfTree"
	_tree.item_collapsed.connect(_on_item_collapsed)
	_tree.item_selected.connect(_on_item_selected)
	_tree.item_mouse_selected.connect(_on_item_mouse_selected)
	add_child(_tree)
	visible = false


## Shows `shelves` (`RepoSession.shelves()`) for a worktree on `branch`.
func show_shelves(shelves: Array[Dictionary], branch: String) -> void:
	var selected: String = String(selected_shelf().get("oid", ""))
	_shelves = shelves
	_branch = branch
	var live: Dictionary[String, bool] = {}
	for shelf: Dictionary in shelves:
		live[String(shelf["oid"])] = true
	for oid: String in _files.keys():
		if not live.has(oid):
			_files.erase(oid)
			_expanded.erase(oid)
	_rebuild(selected)


## The files of shelf `oid` arrived (`RepoSession.shelf_files()`).
func set_files(oid: String, files: Array[Dictionary]) -> void:
	_files[oid] = files
	_rebuild(String(selected_shelf().get("oid", "")))


func shelf_count() -> int:
	return _shelves.size()


## The current branch's shelves.
func own_shelves() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for shelf: Dictionary in _shelves:
		if String(shelf["branch"]) == _branch and not _branch.is_empty():
			out.append(shelf)
	return out


## The selected shelf (or the shelf of the selected file), or {}.
func selected_shelf() -> Dictionary:
	var item: TreeItem = _tree.get_selected()
	if item == null:
		return {}
	var meta: Variant = item.get_metadata(0)
	if not meta is Dictionary:
		return {}
	return _find(String((meta as Dictionary).get("oid", "")))


## Selects the shelf `oid` (for tests and keyboard flows).
func select_shelf(oid: String) -> bool:
	var item: TreeItem = _item_of(oid, "")
	if item == null:
		return false
	item.select(0)
	_tree.scroll_to_item(item)
	return true


## Expands shelf `oid` and selects its file `path` (once the files are loaded).
func choose_file(oid: String, path: String) -> bool:
	var item: TreeItem = _item_of(oid, path)
	if item == null:
		return false
	item.select(0)
	return true


func expand(oid: String) -> void:
	_expanded[oid] = true
	if not _files.has(oid):
		files_wanted.emit(oid)
	if _is_other(_find(oid)):
		_others_open = true
	_rebuild(oid)


func deselect() -> void:
	_tree.deselect_all()


func tree() -> Tree:
	return _tree


## Labels of the visible rows, for tests.
func row_texts() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var item: TreeItem = _tree.get_root().get_first_child() if _tree.get_root() != null else null
	while item != null:
		if item.is_visible_in_tree():
			out.append(item.get_text(0))
		item = item.get_next_in_tree()
	return out


func _rebuild(selected: String) -> void:
	_tree.clear()
	var root: TreeItem = _tree.create_item()
	var others: Array[Dictionary] = []
	for shelf: Dictionary in _shelves:
		if _is_other(shelf):
			others.append(shelf)
		else:
			_add_shelf(root, shelf, String(shelf["name"]))
	if not others.is_empty():
		var group: TreeItem = _tree.create_item(root)
		group.set_text(0, "Other branches (%d)" % others.size())
		group.set_metadata(0, {"kind": "others"})
		group.set_selectable(0, false)
		group.set_custom_color(0, get_theme_color(&"group_color", THEME_TYPE))
		for shelf: Dictionary in others:
			var branch: String = String(shelf["branch"])
			_add_shelf(group, shelf, "%s · %s" % [branch if not branch.is_empty() else "no branch", shelf["name"]])
		group.collapsed = not _others_open
	if not selected.is_empty():
		var item: TreeItem = _item_of(selected, "")
		if item != null:
			item.select(0)
	visible = not _shelves.is_empty()
	_update_header()


func _add_shelf(parent: TreeItem, shelf: Dictionary, text: String) -> void:
	var oid: String = String(shelf["oid"])
	var item: TreeItem = _tree.create_item(parent)
	item.set_text(0, text)
	item.set_icon(0, AppTheme.icon(&"GitShelf"))
	item.set_tooltip_text(0, "%s\n%s%s" % [text, _age(int(shelf["time"])),
			"\nLeft when switching branch" if bool(shelf["auto"]) else ""])
	item.set_metadata(0, {"kind": "shelf", "oid": oid})
	var files: Array = _files.get(oid, [])
	if not _files.has(oid):
		var loading: TreeItem = _tree.create_item(item)
		loading.set_text(0, "Loading…")
		loading.set_selectable(0, false)
	for file: Dictionary in files:
		var row: TreeItem = _tree.create_item(item)
		var code: String = String(file["code"])
		row.set_text(0, String(file["path"]))
		row.set_icon(0, FileRowPainter.code_icon(code))
		row.set_icon_modulate(0, FileRowPainter.code_color(_tree, code))
		row.set_icon_max_width(0, _tree.get_theme_constant(&"icon_size", FileRowPainter.THEME_TYPE))
		var status: String = FileRowPainter.code_name(code)
		row.set_tooltip_text(0, String(file["path"]) if status.is_empty() else "%s\n%s" % [file["path"], status])
		row.set_metadata(0, {"kind": "file", "oid": oid, "path": String(file["path"])})
	item.collapsed = not _expanded.get(oid, false)


func _item_of(oid: String, path: String) -> TreeItem:
	var item: TreeItem = _tree.get_root().get_first_child() if _tree.get_root() != null else null
	while item != null:
		var meta: Variant = item.get_metadata(0)
		if meta is Dictionary and String((meta as Dictionary).get("oid", "")) == oid:
			var kind: String = String((meta as Dictionary)["kind"])
			if (path.is_empty() and kind == "shelf") or String((meta as Dictionary).get("path", "")) == path:
				return item
		item = item.get_next_in_tree()
	return null


func _find(oid: String) -> Dictionary:
	for shelf: Dictionary in _shelves:
		if String(shelf["oid"]) == oid:
			return shelf
	return {}


func _is_other(shelf: Dictionary) -> bool:
	return _branch.is_empty() or String(shelf.get("branch", "")) != _branch


func _update_header() -> void:
	var own: int = own_shelves().size()
	var others: int = _shelves.size() - own
	_header.text = "Shelved · %d" % own if others == 0 else "Shelved · %d (+%d on other branches)" % [own, others]
	_header.icon = AppTheme.icon(&"GuiTreeArrowRight" if _collapsed else &"GuiTreeArrowDown")
	_tree.visible = not _collapsed
	_update_height()


## The tree grows with its visible rows, up to the theme's `max_height`.
func _update_height() -> void:
	var rows: int = row_texts().size()
	var row_height: float = float(get_theme_constant(&"row_height", THEME_TYPE))
	var limit: float = float(get_theme_constant(&"max_height", THEME_TYPE))
	_tree.custom_minimum_size.y = minf(limit, maxf(1.0, float(rows)) * row_height + 8.0)


func _on_item_collapsed(item: TreeItem) -> void:
	var meta: Variant = item.get_metadata(0)
	if not meta is Dictionary:
		return
	var data: Dictionary = meta
	match String(data["kind"]):
		"others":
			_others_open = not item.collapsed
		"shelf":
			var oid: String = String(data["oid"])
			_expanded[oid] = not item.collapsed
			if not item.collapsed and not _files.has(oid):
				files_wanted.emit(oid)
	_update_height.call_deferred()


func _on_item_selected() -> void:
	var item: TreeItem = _tree.get_selected()
	var meta: Variant = item.get_metadata(0) if item != null else null
	if not meta is Dictionary:
		shelf_selected.emit({})
		return
	var data: Dictionary = meta
	shelf_selected.emit(_find(String(data.get("oid", ""))))
	if String(data["kind"]) == "file":
		file_chosen.emit(String(data["oid"]), String(data["path"]))


func _on_item_mouse_selected(at: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_RIGHT:
		return
	var shelf: Dictionary = selected_shelf()
	if not shelf.is_empty():
		menu_requested.emit(shelf, _tree.get_screen_position() + at)


static func _age(time: int) -> String:
	var seconds: int = int(Time.get_unix_time_from_system()) - time
	if seconds < 3600:
		return "%d min ago" % maxi(1, floori(seconds / 60.0))
	if seconds < 86400:
		return "%d h ago" % floori(seconds / 3600.0)
	return "%d days ago" % floori(seconds / 86400.0)
