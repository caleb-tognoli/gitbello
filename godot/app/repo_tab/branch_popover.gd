class_name BranchPopover
extends PopupPanel
## The Branch button's list (UX.md): a filter, then Recent (the current
## branch and the ones last checked out), the other local branches and the
## remote branches no local branch tracks, each listed once (see `sections`),
## with the commits to push and pull. Names show their prefix (`feature/`)
## muted; sections are plain headers. It opens on the current branch. Enter or a single click chooses a branch; one checked
## out in another worktree has a worktree icon and choosing it shows that
## worktree. Alt+Enter opens the highlighted branch in a new worktree
## instead. Right-click opens the branch's menu. Opened to pick a branch to
## merge, it says so in a header, leaves out the current branch, shows how old
## each branch's last commit is and emits `merge_chosen` instead. It fits its
## rows, up to the theme's `height`.

## A branch was chosen: a ref like `{type, name, short, commit, is_head,
## upstream, worktree}` (`type` is `branch` or `remote`).
signal branch_chosen(ref: Dictionary)
## Right-click or the menu key on a branch; `at_position` is on the screen.
signal menu_requested(ref: Dictionary, at_position: Vector2)
## Delete was pressed on a branch or remote branch.
signal delete_requested(ref: Dictionary)
signal new_branch_requested()
## Alt+Enter on a branch: open it in a new worktree.
signal new_worktree_requested(ref: Dictionary)
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
## Draws the branch names, prefixes muted, over the tree.
var _names: BranchNameLayer = null
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
	_filter.text_box().gui_input.connect(func(event: InputEvent) -> void:
		if _is_alt_enter(event):
			_filter.text_box().accept_event()
			_open_in_worktree(_tree.get_selected()))
	_tree.hide_root = true
	_tree.hide_folding = true
	_tree.columns = 2
	_count_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_count_layer.draw.connect(_draw_counts)
	_tree.add_child(_count_layer)
	_tree.draw.connect(_count_layer.queue_redraw)
	_names = BranchNameLayer.new(_tree)
	_tree.set_column_expand(1, false)
	_tree.select_mode = Tree.SELECT_ROW
	# A right-click selects its row first, so its menu is for that branch.
	_tree.allow_rmb_select = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_activated.connect(func() -> void: _choose(_tree.get_selected()))
	_tree.item_mouse_selected.connect(_on_mouse_selected)
	_tree.gui_input.connect(_on_tree_input)
	box.add_child(_tree)
	AutoScroll.enable(_tree)
	_empty.theme_type_variation = &"DimLabel"
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# One line: a wrapping label measures its height at no width, which made
	# the popover as tall as the message spelled one letter per line.
	_empty.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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
	_names.clear()
	_names.prefix_color = get_theme_color(&"prefix_color", THEME_TYPE)
	_empty.hide()
	_tree.set_column_custom_minimum_width(1, 0)
	var root: TreeItem = _tree.create_item()
	if session == null or not session.is_ready():
		return
	var query: String = _filter.text().strip_edges().to_lower()
	for section: Array in sections(session.branch_refs(), _merging):
		var refs: Array[Dictionary] = []
		refs.assign((section[1] as Array).filter(func(ref: Dictionary) -> bool:
			return query.is_empty() or String(ref["short_name"]).to_lower().contains(query)))
		if refs.is_empty():
			continue
		if not String(section[0]).is_empty():
			_section(root, String(section[0]))
		for ref: Dictionary in refs:
			_add_ref(root, ref)
	if query.is_empty():
		_select_current()
	else:
		_select_first()
	_fit()


## The list's sections in order, as `[title, refs]` (an empty title has no
## header row): Recent, the other local branches A–Z and the remote branches
## no local branch tracks, A–Z. Recent holds the current branch, then the
## branches last checked out (in any worktree), up to `RECENT_COUNT` rows.
## With `RECENT_COUNT` local branches or fewer, or none checked out but the
## current one, there is no Recent: the local list has no header and starts
## with the current branch. `merging` leaves the current branch out and lists
## its upstream first in Remote (the usual branch to merge after a fetch).
static func sections(all: Array[Dictionary], merging: bool) -> Array:
	var local: Array[Dictionary] = []
	var remote: Array[Dictionary] = []
	var tracked: Dictionary[String, bool] = {}
	var head_upstream: String = ""
	var head: Dictionary = {}
	for ref: Dictionary in all:
		if String(ref["kind"]) != "branch":
			remote.append(ref)
			continue
		if not String(ref["upstream"]).is_empty():
			tracked[String(ref["upstream"])] = true
		if bool(ref["is_head"]):
			head_upstream = String(ref["upstream"])
			head = ref
			if merging:
				continue
		local.append(ref)
	var by_name: Callable = func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["short_name"]).naturalnocasecmp_to(String(b["short_name"])) < 0
	local.sort_custom(by_name)
	var remotes: Array[Dictionary] = []
	var upstream: Array[Dictionary] = []
	for ref: Dictionary in remote:
		var short: String = String(ref["short_name"])
		if merging and short == head_upstream:
			upstream.append(ref)
		elif not tracked.has(short):
			remotes.append(ref)
	remotes.sort_custom(by_name)
	upstream.append_array(remotes)
	var recent: Array[Dictionary] = []
	recent.assign(local.filter(func(ref: Dictionary) -> bool:
		return not bool(ref["is_head"]) and int(ref.get("checked_out_at", 0)) > 0))
	recent.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["checked_out_at"]) > int(b["checked_out_at"]))
	var out: Array = []
	var has_head: bool = not merging and not head.is_empty()
	if local.size() > RECENT_COUNT and not recent.is_empty():
		recent.resize(mini(recent.size(), RECENT_COUNT - (1 if has_head else 0)))
		if has_head:
			recent.push_front(head)
		var rest: Array[Dictionary] = []
		rest.assign(local.filter(func(ref: Dictionary) -> bool: return not recent.has(ref)))
		out.append(["Recent", recent])
		out.append(["Local", rest])
	else:
		if has_head:
			local.erase(head)
			local.push_front(head)
		out.append(["", local])
	out.append(["Remote", upstream])
	return out


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


## The list's last row, or null.
func _last_visible(item: TreeItem) -> TreeItem:
	return item.get_child(item.get_child_count() - 1) if item != null and item.get_child_count() > 0 else null


## A section's header: a muted row that can't be chosen.
func _section(parent: TreeItem, text: String) -> void:
	var item: TreeItem = _tree.create_item(parent)
	item.set_text(0, tr(text))
	item.set_selectable(0, false)
	item.set_selectable(1, false)
	item.set_custom_color(0, get_theme_color(&"section_color", THEME_TYPE))


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_filter.placeholder = tr("Filter branches")
		_new_button.text = tr("New branch…")
		if _merging and session != null:
			_header_label.text = tr("Merge into %s") % session.current_branch()
		_rebuild()


func _add_ref(parent: TreeItem, ref: Dictionary) -> void:
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
	item.set_text(0, String(ref["short_name"]))
	_names.add(item)
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
	elif not _merging and not bool(ref["is_head"]):
		tooltip += "\n" + tr("Open in new worktree") + TooltipCard.SHORTCUT_SEPARATOR + "Alt+Enter"
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
	return null


func _first_ref(item: TreeItem) -> TreeItem:
	if item == null:
		return null
	for child: TreeItem in item.get_children():
		if child.get_metadata(0) is Dictionary:
			return child
	return null


func _choose(item: TreeItem) -> void:
	if item == null or not item.get_metadata(0) is Dictionary:
		return
	hide()
	if _merging:
		merge_chosen.emit(item.get_metadata(0) as Dictionary)
	else:
		branch_chosen.emit(item.get_metadata(0) as Dictionary)


## Alt+Enter (either Enter key), pressed.
static func _is_alt_enter(event: InputEvent) -> bool:
	var key: InputEventKey = event as InputEventKey
	return key != null and key.pressed and not key.echo and key.alt_pressed \
			and key.keycode in [KEY_ENTER, KEY_KP_ENTER]


## Alt+Enter on `item`: its branch in a new worktree (not while merging).
func _open_in_worktree(item: TreeItem) -> void:
	if _merging or item == null or not item.get_metadata(0) is Dictionary:
		return
	hide()
	new_worktree_requested.emit(item.get_metadata(0) as Dictionary)


## Presses Alt+Enter on the selected row (for tests).
func open_selected_in_worktree() -> void:
	_open_in_worktree(_tree.get_selected())


func _collect(item: TreeItem, out: PackedStringArray) -> void:
	for child: TreeItem in item.get_children():
		if child.get_metadata(0) is Dictionary:
			out.append(String((child.get_metadata(0) as Dictionary)["short"]))


func _collect_labels(item: TreeItem, out: PackedStringArray) -> void:
	for child: TreeItem in item.get_children():
		out.append(child.get_text(0))


func _on_mouse_selected(at_position: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_RIGHT:
		return
	var item: TreeItem = _tree.get_selected()
	if item != null and item.get_metadata(0) is Dictionary:
		menu_requested.emit(item.get_metadata(0) as Dictionary, _tree.get_screen_position() + at_position)


func _on_filter_done() -> void:
	_tree.grab_focus()
	_select_first()


## A click on a branch chooses it once the button is released over the row
## it pressed (the press selects it); a click on a section header does nothing.
func _on_tree_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		var at: TreeItem = _tree.get_item_at_position(button.position)
		if at != null and not at.get_metadata(0) is Dictionary:
			_tree.accept_event()
		elif at != null and not button.pressed and at == _tree.get_selected():
			_choose(at)
		return
	var item: TreeItem = _tree.get_selected()
	if _is_alt_enter(event):
		_tree.accept_event()
		_open_in_worktree(item)
		return
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_DELETE \
			and item != null and item.get_metadata(0) is Dictionary:
		delete_requested.emit(item.get_metadata(0) as Dictionary)
		_tree.accept_event()
		return
	if event.is_action_pressed("ui_up", false, true) and item != null and item == _first_ref(_tree.get_root()):
		_filter.focus_text()
		_tree.accept_event()
