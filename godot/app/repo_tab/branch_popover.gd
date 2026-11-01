class_name BranchPopover
extends PopupPanel
## The Branch button's list (PLAN §4): a filter, then Recent, local branches
## (grouped by prefix such as `feature/`) and Remote branches with the commits
## to push and pull. It opens
## on the current branch. Enter or a single click chooses a branch; one checked
## out in another worktree has a worktree icon and choosing it shows that
## worktree. Right-click opens the branch's menu. Opened to pick a branch to
## merge, it says so in a header, leaves out the current branch, shows how old
## each branch's last commit is and emits `merge_chosen` instead. It fits its
## rows, up to the theme's `height`.

## A branch was chosen: a ref like `{type, name, short, commit, is_head,
## upstream, worktree}` (`type` is `branch` or `remote`).
signal branch_chosen(ref: Dictionary)
## Right-click or the menu key on a branch; `at_position` is on the screen.
signal menu_requested(ref: Dictionary, at_position: Vector2)
signal new_branch_requested()
## A branch to merge into the current one was chosen (see `open_below`).
signal merge_chosen(ref: Dictionary)

const THEME_TYPE: StringName = &"BranchPopover"
const RECENT_COUNT: int = 5
const FILTER_FIELD: PackedScene = preload("res://ui/filter_field/filter_field.tscn")

var session: RepoSession = null

var _header: HBoxContainer = HBoxContainer.new()
var _header_label: Label = Label.new()
var _filter: FilterField = FILTER_FIELD.instantiate() as FilterField
var _tree: Tree = Tree.new()
var _empty: Label = Label.new()
var _new_button: Button = Button.new()
## Picking a branch to merge rather than to switch to.
var _merging: bool = false
## Rows with commits to push or pull: their pills are drawn on a layer over
## the tree.
var _counted: Array[TreeItem] = []
var _count_layer: Control = Control.new()
## The anchor window's UI scale, for the popup's size.
var _scale: float = 1.0


func _ready() -> void:
	var box: VBoxContainer = VBoxContainer.new()
	add_child(box)
	var merge_icon: TextureRect = TextureRect.new()
	merge_icon.texture = AppTheme.icon(&"GitMerge")
	merge_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	merge_icon.self_modulate = get_theme_color(&"icon_color", THEME_TYPE)
	_header.add_child(merge_icon)
	_header_label.theme_type_variation = &"DimLabel"
	_header.add_child(_header_label)
	_header.visible = false
	box.add_child(_header)
	_filter.placeholder = tr("Filter branches")
	_filter.changed.connect(_rebuild)
	_filter.submitted.connect(func(_backwards: bool) -> void: _choose(_tree.get_selected()))
	_filter.done.connect(_on_filter_done)
	box.add_child(_filter)
	_tree.hide_root = true
	# Sections draw their own arrow as their icon, so top-level branches and
	# section arrows line up (Tree's arrows sit in a margin left of the rows).
	_tree.hide_folding = true
	_tree.columns = 2
	_count_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_count_layer.draw.connect(_draw_counts)
	_tree.add_child(_count_layer)
	_tree.draw.connect(_count_layer.queue_redraw)
	_tree.set_column_expand(1, false)
	_tree.select_mode = Tree.SELECT_ROW
	# A right-click selects its row first, so its menu is for that branch.
	_tree.allow_rmb_select = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_activated.connect(func() -> void: _choose(_tree.get_selected()))
	_tree.item_mouse_selected.connect(_on_mouse_selected)
	_tree.gui_input.connect(_on_tree_input)
	_tree.item_collapsed.connect(func(item: TreeItem) -> void:
		_set_arrow(item)
		_fit.call_deferred())
	box.add_child(_tree)
	AutoScroll.enable(_tree)
	_empty.theme_type_variation = &"DimLabel"
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty.hide()
	box.add_child(_empty)
	var footer: HBoxContainer = HBoxContainer.new()
	_new_button.text = tr("New branch…")
	_new_button.icon = AppTheme.icon(&"Add")
	_new_button.theme_type_variation = &"ToolbarButton"
	_new_button.pressed.connect(func() -> void:
		hide()
		new_branch_requested.emit())
	footer.add_child(_new_button)
	box.add_child(footer)


## Opens under `anchor` with an empty filter; with `merging`, to pick the
## branch to merge into the current one.
func open_below(anchor: Control, merging: bool = false) -> void:
	_merging = merging
	_header.visible = merging
	_header_label.text = tr("Merge into %s") % session.current_branch()
	_new_button.visible = not merging
	_filter.set_text("")
	_rebuild()
	_scale = anchor.get_window().content_scale_factor
	var at: Vector2 = anchor.get_screen_transform() * Vector2(0.0, anchor.size.y)
	popup(Rect2i(Vector2i(at), Vector2i(Vector2(get_theme_constant(&"width", THEME_TYPE), 0.0) * _scale)))
	_fit()
	_filter.focus_text()


## The header picking a branch to merge shows, or empty (for tests).
func header_text() -> String:
	return _header_label.text if _header.visible else ""


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


## Draws the pills of the rows with commits to push or pull at the right of
## their badge cell, on the layer over the tree.
func _draw_counts() -> void:
	var margin_right: float = float(_tree.get_theme_constant(&"inner_item_margin_right"))
	var visible_rect: Rect2 = Rect2(Vector2.ZERO, _tree.size)
	for item: TreeItem in _counted:
		if not item.is_visible_in_tree():
			continue
		var rect: Rect2 = _tree.get_item_area_rect(item, 1)
		if not visible_rect.intersects(rect):
			continue
		var counts: Vector2i = item.get_metadata(1)
		SyncCounts.draw_counts(_count_layer, rect.grow_side(SIDE_RIGHT, -margin_right), counts.x, counts.y, true)


## The first branch row's ref (for tests), or empty.
func first_ref() -> Dictionary:
	var first: TreeItem = _first_ref(_tree.get_root())
	return first.get_metadata(0) as Dictionary if first != null else {}


func set_filter(text: String) -> void:
	_filter.set_text(text)


func _rebuild() -> void:
	_tree.clear()
	_counted.clear()
	_empty.hide()
	_tree.set_column_custom_minimum_width(1, 0)
	var root: TreeItem = _tree.create_item()
	if session == null or not session.is_ready():
		return
	var refs: Array[Dictionary] = session.branch_refs()
	if _merging:
		refs.assign(refs.filter(func(ref: Dictionary) -> bool: return not bool(ref["is_head"])))
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
		_fit()
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
		var branch_name: String = String(ref["short_name"])
		var slash: int = branch_name.rfind("/")
		if slash > 0:
			var folder: String = branch_name.left(slash)
			folder_counts[folder] = int(folder_counts.get(folder, 0)) + 1
	var folders: Dictionary[String, TreeItem] = {}
	for ref: Dictionary in local:
		var branch_name: String = String(ref["short_name"])
		var parent: TreeItem = locals
		var slash: int = branch_name.rfind("/")
		var folder: String = branch_name.left(slash) if slash > 0 else ""
		var grouped: bool = slash > 0 and int(folder_counts[folder]) > 1
		if grouped:
			if not folders.has(folder):
				folders[folder] = _section(locals, folder + "/", false)
			parent = folders[folder]
		_add_ref(parent, ref, branch_name.substr(slash + 1) if grouped else branch_name)
	if not remote.is_empty():
		var remotes: TreeItem = _section(root, "Remote")
		remotes.collapsed = true
		for ref: Dictionary in remote:
			_add_ref(remotes, ref, String(ref["short_name"]))
	_select_current()
	_fit()


## Sizes the list to its rows, up to the theme's `height`; with no rows it
## says why.
func _fit() -> void:
	if not visible:
		return
	var last: TreeItem = _last_visible(_tree.get_root())
	_tree.visible = last != null
	_empty.visible = last == null
	_empty.text = tr("No matching branches") if not _filter.text().strip_edges().is_empty() \
			else tr("No other branches") if _merging else tr("No branches")
	_tree.custom_minimum_size.y = 0.0
	var rows: float = 0.0
	if last != null:
		var panel: StyleBox = _tree.get_theme_stylebox(&"panel")
		# Item rects are relative to the scroll, which `_select_first` may have moved.
		rows = _tree.get_item_area_rect(last).end.y + _tree.get_scroll().y \
				+ panel.get_margin(SIDE_TOP) + panel.get_margin(SIDE_BOTTOM)
	var chrome: float = get_contents_minimum_size().y - _tree.get_combined_minimum_size().y * float(_tree.visible)
	var tree_height: float = minf(rows, get_theme_constant(&"height", THEME_TYPE) - chrome)
	_tree.custom_minimum_size.y = tree_height
	size = Vector2i(Vector2(get_theme_constant(&"width", THEME_TYPE), chrome + tree_height) * _scale)


## The last row a reader can see (collapsed sections hide their children).
func _last_visible(item: TreeItem) -> TreeItem:
	if item == null or item.get_child_count() == 0:
		return null
	var last: TreeItem = item.get_child(item.get_child_count() - 1)
	if last.collapsed:
		return last
	var inner: TreeItem = _last_visible(last)
	return inner if inner != null else last


static func _remote_has_local(remote_name: String, local_names: PackedStringArray) -> bool:
	for local_name: String in local_names:
		if remote_name.ends_with("/" + local_name):
			return true
	return false


func _section(parent: TreeItem, text: String, header: bool = true) -> TreeItem:
	var item: TreeItem = _tree.create_item(parent)
	item.set_text(0, tr(text) if header else text)
	item.set_selectable(0, false)
	item.set_selectable(1, false)
	_set_arrow(item)
	if header:
		item.set_custom_color(0, get_theme_color(&"section_color", THEME_TYPE))
		item.set_icon_modulate(0, get_theme_color(&"section_color", THEME_TYPE))
	return item


## A section's arrow, which is its icon (see `_ready`), centred in a branch
## icon's width so section and branch names line up too.
func _set_arrow(item: TreeItem) -> void:
	if item.get_metadata(0) is Dictionary:
		return
	var arrow: Texture2D = AppTheme.icon(&"GuiTreeArrowRight" if item.collapsed else &"GuiTreeArrowDown")
	var pad: Vector2 = (AppTheme.icon(&"GitBranch").get_size() - arrow.get_size()) / 2.0
	item.set_icon(0, arrow)
	item.set_icon_region(0, Rect2(-pad, arrow.get_size() + pad * 2.0))


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_filter.placeholder = tr("Filter branches")
		_new_button.text = tr("New branch…")
		if _merging and session != null:
			_header_label.text = tr("Merge into %s") % session.current_branch()
		_rebuild()


func _add_ref(parent: TreeItem, ref: Dictionary, text: String) -> void:
	var item: TreeItem = _tree.create_item(parent)
	var worktree: String = String(ref["worktree"])
	var elsewhere: bool = not worktree.is_empty() and not bool(ref["is_head"]) \
			and not Paths.same(worktree, session.toplevel())
	var badge: PackedStringArray = PackedStringArray()
	if bool(ref["gone"]):
		badge.append(tr("gone"))
	# The commits to push and pull, in pills drawn at the cell's right.
	var ahead: int = 0 if _merging else int(ref["ahead"])
	var behind: int = 0 if _merging else int(ref["behind"])
	if _merging:
		badge.clear()
		if ref.has("committed_at") and int(ref["committed_at"]) > 0:
			badge.append(RepoOps.ago(int(Time.get_unix_time_from_system()) - int(ref["committed_at"])))
		item.set_icon_modulate(0, get_theme_color(&"icon_color", THEME_TYPE))
	item.set_text(0, text)
	item.set_text(1, " ".join(badge))
	var margin_right: int = _tree.get_theme_constant(&"inner_item_margin_right")
	var pills: float = SyncCounts.measure(_tree, ahead, behind).x
	if pills > 0.0:
		item.set_metadata(1, Vector2i(ahead, behind))
		_counted.append(item)
	# A column that doesn't expand keeps its minimum width: widen it to fit, up
	# to a third of the list so a badge can't squeeze the branch names away.
	var font: Font = _tree.get_theme_font(&"font")
	var text_width: float = font.get_string_size(item.get_text(1), HORIZONTAL_ALIGNMENT_LEFT, -1,
			_tree.get_theme_font_size(&"font_size")).x
	var gap: float = float(_tree.get_theme_constant(&"h_separation")) if text_width > 0.0 and pills > 0.0 else 0.0
	var badge_width: int = ceili(text_width + gap + pills) + _tree.get_theme_constant(&"inner_item_margin_left") \
			+ margin_right + _tree.get_theme_constant(&"h_separation") * 2
	badge_width = mini(badge_width, floori(get_theme_constant(&"width", THEME_TYPE) / 3.0))
	if badge_width > _tree.get_column_width(1):
		_tree.set_column_custom_minimum_width(1, badge_width)
	item.set_custom_color(1, get_theme_color(&"badge_color", THEME_TYPE))
	var tooltip: String = String(ref["short_name"])
	if not String(ref["upstream"]).is_empty():
		tooltip += "\n" + tr("tracks %s") % String(ref["upstream"])
	if elsewhere:
		tooltip += "\n" + tr("Checked out in %s") % worktree
	item.set_tooltip_text(0, tooltip)
	item.set_icon(0, AppTheme.icon(&"StatusSuccess" if bool(ref["is_head"])
			else &"GitWorktree" if elsewhere else &"GitBranch"))
	if bool(ref["is_head"]):
		item.set_icon_modulate(0, get_theme_color(&"head_color", THEME_TYPE))
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


## Selects the current branch, or nothing when it isn't listed.
func _select_current() -> void:
	_tree.deselect_all()
	var current: TreeItem = _find_head(_tree.get_root())
	if current != null:
		current.select(0)
		_tree.scroll_to_item(current)


func _find_head(item: TreeItem) -> TreeItem:
	for child: TreeItem in item.get_children():
		if child.get_metadata(0) is Dictionary and bool((child.get_metadata(0) as Dictionary)["is_head"]):
			return child
		if not child.collapsed:
			var found: TreeItem = _find_head(child)
			if found != null:
				return found
	return null


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
	if _merging:
		merge_chosen.emit(item.get_metadata(0) as Dictionary)
	else:
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


## A click on a section folds it; a click on a branch chooses it once the
## button is released over the row it pressed (the press selects it).
func _on_tree_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		var at: TreeItem = _tree.get_item_at_position(button.position)
		if at != null and not at.get_metadata(0) is Dictionary:
			if button.pressed:
				at.collapsed = not at.collapsed
			_tree.accept_event()
		elif at != null and not button.pressed and at == _tree.get_selected():
			_choose(at)
		return
	var item: TreeItem = _tree.get_selected()
	if event.is_action_pressed("ui_up", false, true) and item != null and item == _first_ref(_tree.get_root()):
		_filter.focus_text()
		_tree.accept_event()
