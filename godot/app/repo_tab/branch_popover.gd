class_name BranchPopover
extends PopupPanel
## The Branch button's list (PLAN §4): a filter, then Recent, local branches
## (grouped by prefix such as `feature/`) and Remote branches with ↑↓. Enter or
## a click chooses a branch; one checked out in another worktree says so ("in
## fix-login ↗") and choosing it shows that worktree. Right-click opens the
## branch's menu.

## A branch was chosen: a ref like `{type, name, short, commit, is_head,
## upstream, worktree}` (`type` is `branch` or `remote`).
signal branch_chosen(ref: Dictionary)
## Right-click or the menu key on a branch; `at_position` is on the screen.
signal menu_requested(ref: Dictionary, at_position: Vector2)
signal new_branch_requested()

const THEME_TYPE: StringName = &"BranchPopover"
const RECENT_COUNT: int = 5
const FILTER_FIELD: PackedScene = preload("res://ui/filter_field/filter_field.tscn")

var session: RepoSession = null

var _filter: FilterField = FILTER_FIELD.instantiate() as FilterField
var _tree: Tree = Tree.new()
var _new_button: Button = Button.new()


func _ready() -> void:
	var box: VBoxContainer = VBoxContainer.new()
	add_child(box)
	_filter.placeholder = tr("Filter branches")
	_filter.changed.connect(_rebuild)
	_filter.submitted.connect(func(_backwards: bool) -> void: _activate_first())
	_filter.done.connect(_on_filter_done)
	box.add_child(_filter)
	_tree.hide_root = true
	_tree.columns = 2
	_tree.set_column_expand(1, false)
	_tree.select_mode = Tree.SELECT_ROW
	# A right-click selects its row first, so its menu is for that branch.
	_tree.allow_rmb_select = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_activated.connect(func() -> void: _choose(_tree.get_selected()))
	_tree.item_mouse_selected.connect(_on_mouse_selected)
	_tree.gui_input.connect(_on_tree_key)
	box.add_child(_tree)
	var footer: HBoxContainer = HBoxContainer.new()
	_new_button.text = tr("New branch…")
	_new_button.icon = AppTheme.icon(&"Add")
	_new_button.theme_type_variation = &"ToolbarButton"
	_new_button.pressed.connect(func() -> void:
		hide()
		new_branch_requested.emit())
	footer.add_child(_new_button)
	box.add_child(footer)


## Opens under `anchor` with an empty filter.
func open_below(anchor: Control) -> void:
	_filter.set_text("")
	var rect: Rect2 = anchor.get_global_rect()
	var window_position: Vector2 = Vector2(anchor.get_window().position)
	var width: int = get_theme_constant(&"width", THEME_TYPE)
	var height: int = get_theme_constant(&"height", THEME_TYPE)
	var scale: float = anchor.get_window().content_scale_factor
	popup(Rect2i(Vector2i(window_position + rect.position * scale + Vector2(0.0, rect.size.y * scale)),
			Vector2i(Vector2(width, height) * scale)))
	_filter.focus_text()


## Visible branch rows, as `short` names in order (for tests).
func row_names() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var root: TreeItem = _tree.get_root()
	if root != null:
		_collect(root, out)
	return out


## Visible row labels, including sections and folders (for tests).
func row_labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var root: TreeItem = _tree.get_root()
	if root != null:
		_collect_labels(root, out)
	return out


## The first branch row's ref (for tests), or empty.
func first_ref() -> Dictionary:
	var first: TreeItem = _first_ref(_tree.get_root())
	return first.get_metadata(0) as Dictionary if first != null else {}


func set_filter(text: String) -> void:
	_filter.set_text(text)


## Chooses the first branch row (what Enter in the filter does).
func _activate_first() -> void:
	var first: TreeItem = _first_ref(_tree.get_root())
	if first != null:
		_choose(first)


func _rebuild() -> void:
	_tree.clear()
	var root: TreeItem = _tree.create_item()
	if session == null or not session.is_ready():
		return
	var refs: Array[Dictionary] = session.branch_refs()
	var local: Array[Dictionary] = []
	var remote: Array[Dictionary] = []
	var local_names: PackedStringArray = PackedStringArray()
	for ref: Dictionary in refs:
		(local if String(ref["kind"]) == "branch" else remote).append(ref)
		if String(ref["kind"]) == "branch":
			local_names.append(String(ref["short_name"]))
	remote.assign(remote.filter(func(ref: Dictionary) -> bool:
		return not _remote_has_local(String(ref["short_name"]), local_names)))
	refs.clear()
	refs.append_array(local)
	refs.append_array(remote)
	var query: String = _filter.text().strip_edges().to_lower()
	if not query.is_empty():
		for ref: Dictionary in refs:
			if String(ref["short_name"]).to_lower().contains(query):
				_add_ref(root, ref, String(ref["short_name"]))
		_select_first()
		return
	var recent: Array[Dictionary] = []
	recent.assign(local.filter(func(ref: Dictionary) -> bool: return not bool(ref["is_head"])))
	recent.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["committed_at"]) > int(b["committed_at"]))
	# Recent only helps once the local list is longer than it.
	if local.size() > RECENT_COUNT and not recent.is_empty():
		var section: TreeItem = _section(root, "Recent")
		for i: int in mini(RECENT_COUNT, recent.size()):
			_add_ref(section, recent[i], String(recent[i]["short_name"]))
	var locals: TreeItem = root
	var folder_counts: Dictionary[String, int] = {}
	for ref: Dictionary in local:
		var name: String = String(ref["short_name"])
		var slash: int = name.rfind("/")
		if slash > 0:
			var folder: String = name.left(slash)
			folder_counts[folder] = int(folder_counts.get(folder, 0)) + 1
	var folders: Dictionary[String, TreeItem] = {}
	for ref: Dictionary in local:
		var name: String = String(ref["short_name"])
		var parent: TreeItem = locals
		var slash: int = name.rfind("/")
		var folder: String = name.left(slash) if slash > 0 else ""
		var grouped: bool = slash > 0 and int(folder_counts[folder]) > 1
		if grouped:
			if not folders.has(folder):
				folders[folder] = _section(locals, folder + "/", false)
			parent = folders[folder]
		_add_ref(parent, ref, name.substr(slash + 1) if grouped else name)
	if not remote.is_empty():
		var remotes: TreeItem = _section(root, "Remote")
		remotes.collapsed = true
		for ref: Dictionary in remote:
			_add_ref(remotes, ref, String(ref["short_name"]))
	_select_first()


static func _remote_has_local(remote_name: String, local_names: PackedStringArray) -> bool:
	for local_name: String in local_names:
		if remote_name.ends_with("/" + local_name):
			return true
	return false


func _section(parent: TreeItem, text: String, header: bool = true) -> TreeItem:
	var item: TreeItem = _tree.create_item(parent)
	item.set_text(0, text)
	item.set_selectable(0, false)
	item.set_selectable(1, false)
	if header:
		item.set_custom_color(0, get_theme_color(&"section_color", THEME_TYPE))
	return item


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_filter.placeholder = tr("Filter branches")
		_new_button.text = tr("New branch…")
		_rebuild()


func _add_ref(parent: TreeItem, ref: Dictionary, text: String) -> void:
	var item: TreeItem = _tree.create_item(parent)
	var worktree: String = String(ref["worktree"])
	var elsewhere: bool = not worktree.is_empty() and not bool(ref["is_head"]) \
			and not Paths.same(worktree, session.toplevel())
	var badge: PackedStringArray = PackedStringArray()
	if bool(ref["gone"]):
		badge.append(tr("gone"))
	if int(ref["ahead"]) > 0:
		badge.append("↑%d" % int(ref["ahead"]))
	if int(ref["behind"]) > 0:
		badge.append("↓%d" % int(ref["behind"]))
	if elsewhere:
		badge.append(tr("in %s ↗") % worktree.replace("\\", "/").get_file())
	item.set_text(0, text)
	item.set_text(1, " ".join(badge))
	item.set_custom_color(1, get_theme_color(&"badge_color", THEME_TYPE))
	item.set_tooltip_text(0, String(ref["short_name"]) + (
			"\n" + tr("tracks %s") % String(ref["upstream"]) if not String(ref["upstream"]).is_empty() else ""))
	if bool(ref["is_head"]):
		item.set_icon(0, AppTheme.dot(get_theme_color(&"head_color", THEME_TYPE)))
	item.set_metadata(0, {
		"type": "branch" if String(ref["kind"]) == "branch" else "remote",
		"name": String(ref["name"]),
		"short": String(ref["short_name"]),
		"commit": String(ref["commit"]),
		"is_head": bool(ref["is_head"]),
		"upstream": String(ref["upstream"]),
		"worktree": worktree if elsewhere else "",
	})


func _select_first() -> void:
	var first: TreeItem = _first_ref(_tree.get_root())
	if first != null:
		first.select(0)
		_tree.scroll_to_item(first)


func _first_ref(item: TreeItem) -> TreeItem:
	if item == null:
		return null
	for child: TreeItem in item.get_children():
		if child.get_metadata(0) is Dictionary:
			return child
		if not child.collapsed:
			var found: TreeItem = _first_ref(child)
			if found != null:
				return found
	return null


func _choose(item: TreeItem) -> void:
	if item == null or not item.get_metadata(0) is Dictionary:
		return
	hide()
	branch_chosen.emit(item.get_metadata(0) as Dictionary)


func _collect(item: TreeItem, out: PackedStringArray) -> void:
	for child: TreeItem in item.get_children():
		if child.get_metadata(0) is Dictionary:
			out.append(String((child.get_metadata(0) as Dictionary)["short"]))
		elif not child.collapsed:
			_collect(child, out)


func _collect_labels(item: TreeItem, out: PackedStringArray) -> void:
	for child: TreeItem in item.get_children():
		out.append(child.get_text(0))
		if not child.collapsed:
			_collect_labels(child, out)


func _on_mouse_selected(at_position: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_RIGHT:
		return
	var item: TreeItem = _tree.get_selected()
	if item != null and item.get_metadata(0) is Dictionary:
		menu_requested.emit(item.get_metadata(0) as Dictionary, _tree.get_screen_position() + at_position)


func _on_filter_done() -> void:
	_tree.grab_focus()
	_select_first()


func _on_tree_key(event: InputEvent) -> void:
	var item: TreeItem = _tree.get_selected()
	if event.is_action_pressed("ui_up", false, true) and item != null and item == _first_ref(_tree.get_root()):
		_filter.focus_text()
		_tree.accept_event()
