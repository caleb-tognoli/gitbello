class_name RepoSidebar
extends Tree
## Repository overview (PLAN §4): Changes, Worktrees, Branches, Remotes,
## Tags, Stashes. Each section rebuilds from its session signal and keeps the
## user's collapsed folders and selection. Choosing a Changes row opens the
## changes view; branch, remote and tag rows carry a ref (see `selected_ref`)
## that Enter activates and right-click or the menu key offers actions for.

## The user chose a row of the Changes section.
signal changes_requested()
## Enter or double-click on a branch, remote branch or tag row.
signal ref_activated(ref: Dictionary)
## Right-click or the menu key on a ref row; `at_position` is in screen
## coordinates.
signal context_menu_requested(ref: Dictionary, at_position: Vector2)

const THEME_TYPE: StringName = &"RepoSidebar"
const CHANGE_GROUPS: Dictionary[String, String] = {
	"conflicted": "Conflicted",
	"unstaged": "Unstaged",
	"untracked": "Untracked",
	"staged": "Staged",
}
## Metadata of Changes rows.
const CHANGES_ROW: String = "changes"

enum Section { CHANGES, WORKTREES, BRANCHES, REMOTES, TAGS, STASHES }

const SECTION_TITLES: Dictionary[Section, String] = {
	Section.CHANGES: "Changes",
	Section.WORKTREES: "Worktrees",
	Section.BRANCHES: "Branches",
	Section.REMOTES: "Remotes",
	Section.TAGS: "Tags",
	Section.STASHES: "Stashes",
}

## Sections collapsed until the user opens them.
const COLLAPSED_BY_DEFAULT: Array[Section] = [Section.TAGS, Section.STASHES]

var session: RepoSession = null:
	set = set_session

var _sections: Dictionary[Section, TreeItem] = {}
## Ref row to select again after a rebuild.
var _reselect: String = ""
## Paths ("Branches/feature") the user collapsed or expanded.
var _folded: Dictionary[String, bool] = {}


func _ready() -> void:
	custom_minimum_size.x = float(get_theme_constant(&"width", THEME_TYPE))
	hide_root = true
	columns = 2
	set_column_expand(1, false)
	set_column_custom_minimum_width(1, get_theme_constant(&"badge_width", THEME_TYPE))
	allow_rmb_select = true
	item_collapsed.connect(_on_item_collapsed)
	item_activated.connect(_on_item_activated)
	item_mouse_selected.connect(_on_item_mouse_selected)
	_build_sections()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		custom_minimum_size.x = float(get_theme_constant(&"width", THEME_TYPE))
		set_column_custom_minimum_width(1, get_theme_constant(&"badge_width", THEME_TYPE))
		_build_sections()
		refresh_all()


func set_session(value: RepoSession) -> void:
	if session != null:
		for pair: Array in _signal_pairs(session):
			var sig: Signal = pair[0]
			if sig.is_connected(pair[1]):
				sig.disconnect(pair[1])
	session = value
	if session != null:
		for pair: Array in _signal_pairs(session):
			(pair[0] as Signal).connect(pair[1])
	refresh_all()


func refresh_all() -> void:
	_rebuild_changes()
	_rebuild_worktrees()
	_rebuild_branches()
	_rebuild_tags()
	_rebuild_stashes()


## Child texts of a section (for tests).
func section_texts(section: Section) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	_collect_texts(_sections[section], out, "")
	return out


func section_item(section: Section) -> TreeItem:
	return _sections[section]


## The selected row's ref: `{type, name, short, commit, is_head, upstream}`
## with type `branch`, `remote` or `tag` (`name` is the full ref name;
## branches add `worktree`, the folder where they are checked out), or type
## `worktree` (`name` is `worktree:<path>`; adds `path`, `is_main`,
## `locked`, `prunable`, `changed`), or an empty dictionary.
func selected_ref() -> Dictionary:
	var item: TreeItem = get_selected()
	if item == null:
		return {}
	var meta: Variant = item.get_metadata(0)
	return meta if meta is Dictionary else {}


## Selects the row of ref `name` (full name). Returns whether it was found.
func select_ref(name: String) -> bool:
	var item: TreeItem = _find_ref(get_root(), name)
	if item == null:
		return false
	var parent: TreeItem = item.get_parent()
	while parent != null:
		parent.collapsed = false
		parent = parent.get_parent()
	item.select(0)
	scroll_to_item(item)
	return true


func _find_ref(item: TreeItem, name: String) -> TreeItem:
	for child: TreeItem in item.get_children():
		var meta: Variant = child.get_metadata(0)
		if meta is Dictionary and String(meta["name"]) == name:
			return child
		var found: TreeItem = _find_ref(child, name)
		if found != null:
			return found
	return null


func _signal_pairs(s: RepoSession) -> Array:
	return [
		[s.status_changed, _rebuild_changes],
		[s.status_changed, _rebuild_worktrees],
		[s.worktrees_changed, _rebuild_worktrees],
		[s.refs_changed, _rebuild_branches],
		[s.refs_changed, _rebuild_tags],
		[s.stashes_changed, _rebuild_stashes],
	]


func _build_sections() -> void:
	clear()
	var root: TreeItem = create_item()
	for section: Section in SECTION_TITLES:
		var item: TreeItem = root.create_child()
		item.set_text(0, SECTION_TITLES[section])
		item.set_selectable(0, false)
		item.set_selectable(1, false)
		item.set_custom_color(0, get_theme_color(&"section_color", THEME_TYPE))
		item.collapsed = _is_folded(SECTION_TITLES[section], section in COLLAPSED_BY_DEFAULT)
		_sections[section] = item


func _reset(section: Section, count_text: String) -> TreeItem:
	var item: TreeItem = _sections[section]
	var selected: Dictionary = selected_ref()
	if not selected.is_empty():
		_reselect = String(selected["name"])
	for child: TreeItem in item.get_children():
		child.free()
	item.set_text(1, count_text)
	item.set_custom_color(1, get_theme_color(&"badge_color", THEME_TYPE))
	return item


func _add(parent: TreeItem, text: String, badge: String = "", path: String = "") -> TreeItem:
	var item: TreeItem = parent.create_child()
	item.set_text(0, text)
	item.set_text(1, badge)
	item.set_custom_color(1, get_theme_color(&"badge_color", THEME_TYPE))
	if not path.is_empty():
		item.set_metadata(0, path)
		item.collapsed = _is_folded(path, false)
	return item


func _rebuild_changes() -> void:
	var changed: int = int(session.badge().get("changed", 0)) if session != null else 0
	var section: TreeItem = _reset(Section.CHANGES, str(changed) if changed > 0 else "")
	if session == null:
		return
	for group: String in CHANGE_GROUPS:
		var count: int = session.change_count(group)
		if count > 0:
			var item: TreeItem = _add(section, CHANGE_GROUPS[group], str(count))
			item.set_metadata(0, CHANGES_ROW)
	if section.get_child_count() == 0:
		_add(section, "No local changes").set_metadata(0, CHANGES_ROW)


func _rebuild_worktrees() -> void:
	var worktrees: Array[Dictionary] = session.worktrees() if session != null else []
	var section: TreeItem = _reset(Section.WORKTREES, str(worktrees.size()) if worktrees.size() > 1 else "")
	for wt: Dictionary in worktrees:
		var branch: String = String(wt["branch"])
		if bool(wt["detached"]):
			branch = "detached " + String(wt["head"]).left(7)
		var flags: PackedStringArray = PackedStringArray()
		if bool(wt["locked"]):
			flags.append("locked")
		if bool(wt["prunable"]):
			flags.append("missing")
		if not String(wt["badge"]).is_empty():
			flags.append(String(wt["badge"]))
		var item: TreeItem = _add(section, "%s  ·  %s" % [String(wt["name"]), branch], " ".join(flags))
		item.set_tooltip_text(0, String(wt["path"]))
		item.set_metadata(0, {
			"type": "worktree",
			"name": "worktree:" + String(wt["path"]),
			"short": String(wt["name"]),
			"path": String(wt["path"]),
			"commit": String(wt["head"]),
			"is_head": bool(wt["is_current"]),
			"is_main": bool(wt["is_main"]),
			"locked": bool(wt["locked"]),
			"prunable": bool(wt["prunable"]),
			"changed": maxi(0, int(wt["changed"])),
			"upstream": "",
		})
		if bool(wt["is_current"]):
			item.set_custom_color(0, get_theme_color(&"head_color", THEME_TYPE))
			item.set_text(0, "● " + item.get_text(0))
	_restore_selection()


func _rebuild_branches() -> void:
	var local: Array[Dictionary] = session.local_branches() if session != null else []
	var remote: Array[Dictionary] = session.remote_branches() if session != null else []
	_add_branch_nodes(_reset(Section.BRANCHES, ""), local, "Branches", "branch")
	_add_branch_nodes(_reset(Section.REMOTES, ""), remote, "Remotes", "remote")
	_restore_selection()


func _add_branch_nodes(parent: TreeItem, nodes: Array, prefix: String, type: String) -> void:
	for node: Dictionary in nodes:
		var path: String = prefix + "/" + String(node["name"])
		var ref: Dictionary = node["ref"]
		if ref.is_empty():
			var folder: TreeItem = _add(parent, String(node["name"]), "", path)
			_add_branch_nodes(folder, node["children"], path, type)
			continue
		var badge: PackedStringArray = PackedStringArray()
		if bool(ref["gone"]):
			badge.append("gone")
		if int(ref["ahead"]) > 0:
			badge.append("↑%d" % int(ref["ahead"]))
		if int(ref["behind"]) > 0:
			badge.append("↓%d" % int(ref["behind"]))
		var item: TreeItem = _add(parent, String(node["name"]), " ".join(badge))
		item.set_metadata(0, {
			"type": type,
			"name": String(ref["name"]),
			"short": String(ref["short_name"]),
			"commit": String(ref["commit"]),
			"is_head": bool(ref["is_head"]),
			"upstream": String(ref["upstream"]),
			"worktree": String(ref["worktree"]),
		})
		var tooltip: String = String(ref["short_name"])
		if not String(ref["upstream"]).is_empty():
			tooltip += "\ntracks " + String(ref["upstream"])
		item.set_tooltip_text(0, tooltip)
		if bool(ref["is_head"]):
			item.set_custom_color(0, get_theme_color(&"head_color", THEME_TYPE))
			item.set_text(0, "● " + String(node["name"]))


func _rebuild_tags() -> void:
	var tags: Array[Dictionary] = session.tags() if session != null else []
	var section: TreeItem = _reset(Section.TAGS, str(tags.size()) if not tags.is_empty() else "")
	for tag: Dictionary in tags:
		var item: TreeItem = _add(section, String(tag["name"]), String(tag["commit"]).left(7))
		item.set_metadata(0, {
			"type": "tag",
			"name": "refs/tags/" + String(tag["name"]),
			"short": String(tag["name"]),
			"commit": String(tag["commit"]),
			"is_head": false,
			"upstream": "",
		})
	_restore_selection()


func _rebuild_stashes() -> void:
	var stashes: Array[Dictionary] = session.stashes() if session != null else []
	var section: TreeItem = _reset(Section.STASHES, str(stashes.size()) if not stashes.is_empty() else "")
	for stash: Dictionary in stashes:
		var branch: String = String(stash["branch"])
		_add(section, String(stash["message"]), branch)


func _on_item_activated() -> void:
	var ref: Dictionary = selected_ref()
	if not ref.is_empty():
		ref_activated.emit(ref)
		return
	_open_changes_if_chosen()


func _on_item_mouse_selected(at_position: Vector2, button: int) -> void:
	if button == MOUSE_BUTTON_RIGHT:
		grab_focus()
		_request_menu(get_screen_position() + at_position)
	elif button == MOUSE_BUTTON_LEFT:
		_open_changes_if_chosen()


func _gui_input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed:
		return
	if key.keycode == KEY_MENU or (key.keycode == KEY_F10 and key.shift_pressed):
		var item: TreeItem = get_selected()
		if item != null:
			var rect: Rect2 = get_item_area_rect(item)
			_request_menu(get_screen_position() + rect.position + Vector2(0.0, rect.size.y))
			accept_event()


func _request_menu(at_position: Vector2) -> void:
	var ref: Dictionary = selected_ref()
	if not ref.is_empty():
		context_menu_requested.emit(ref, at_position)


func _open_changes_if_chosen() -> void:
	var item: TreeItem = get_selected()
	if item != null and item.get_metadata(0) is String and item.get_metadata(0) == CHANGES_ROW:
		changes_requested.emit()


func _restore_selection() -> void:
	if not _reselect.is_empty():
		var item: TreeItem = _find_ref(get_root(), _reselect)
		if item != null:
			item.select(0)
		_reselect = ""


func _is_folded(path: String, default: bool) -> bool:
	return _folded.get(path, default)


func _on_item_collapsed(item: TreeItem) -> void:
	var path: Variant = item.get_metadata(0)
	if path == null:
		for section: Section in _sections:
			if _sections[section] == item:
				path = SECTION_TITLES[section]
	if path != null:
		_folded[String(path)] = item.collapsed


func _collect_texts(item: TreeItem, out: PackedStringArray, indent: String) -> void:
	for child: TreeItem in item.get_children():
		var badge: String = child.get_text(1)
		out.append(indent + child.get_text(0) + ("  [" + badge + "]" if not badge.is_empty() else ""))
		_collect_texts(child, out, indent + "  ")
