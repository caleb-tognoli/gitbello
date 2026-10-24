class_name RepoSidebar
extends Tree
## Read-only repository overview (PLAN §4): Changes, Worktrees, Branches,
## Remotes, Tags, Stashes. Each section rebuilds from its session signal and
## keeps the user's collapsed folders.

const THEME_TYPE: StringName = &"RepoSidebar"
## Changed files listed under Changes; the rest are summarised.
const MAX_LISTED_CHANGES: int = 200

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
## Paths ("Branches/feature") the user collapsed or expanded.
var _folded: Dictionary[String, bool] = {}


func _ready() -> void:
	custom_minimum_size.x = float(get_theme_constant(&"width", THEME_TYPE))
	hide_root = true
	columns = 2
	set_column_expand(1, false)
	item_collapsed.connect(_on_item_collapsed)
	_build_sections()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		custom_minimum_size.x = float(get_theme_constant(&"width", THEME_TYPE))
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


func _signal_pairs(s: RepoSession) -> Array:
	return [
		[s.status_changed, _rebuild_changes],
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
	var status: Dictionary = session.status() if session != null else {}
	var changes: Array = status.get("changes", [])
	var section: TreeItem = _reset(Section.CHANGES, str(changes.size()) if not changes.is_empty() else "")
	for i: int in mini(changes.size(), MAX_LISTED_CHANGES):
		var change: Dictionary = changes[i]
		var what: String = String(change["conflict"])
		if what.is_empty():
			what = String(change["index"]) if bool(change["staged"]) else String(change["worktree"])
		_add(section, String(change["path"]), what)
	if changes.size() > MAX_LISTED_CHANGES:
		_add(section, "… %d more" % (changes.size() - MAX_LISTED_CHANGES))


func _rebuild_worktrees() -> void:
	var worktrees: Array[Dictionary] = session.worktrees() if session != null else []
	var section: TreeItem = _reset(Section.WORKTREES, str(worktrees.size()) if worktrees.size() > 1 else "")
	for wt: Dictionary in worktrees:
		var branch: String = String(wt["branch"])
		if bool(wt["detached"]):
			branch = "detached " + String(wt["head"]).left(7)
		var flags: PackedStringArray = PackedStringArray()
		if bool(wt["is_current"]):
			flags.append("current")
		if bool(wt["locked"]):
			flags.append("locked")
		if bool(wt["prunable"]):
			flags.append("missing")
		var item: TreeItem = _add(section, "%s  ·  %s" % [String(wt["name"]), branch], " ".join(flags))
		item.set_tooltip_text(0, String(wt["path"]))


func _rebuild_branches() -> void:
	var local: Array[Dictionary] = session.local_branches() if session != null else []
	var remote: Array[Dictionary] = session.remote_branches() if session != null else []
	_add_branch_nodes(_reset(Section.BRANCHES, ""), local, "Branches")
	_add_branch_nodes(_reset(Section.REMOTES, ""), remote, "Remotes")


func _add_branch_nodes(parent: TreeItem, nodes: Array, prefix: String) -> void:
	for node: Dictionary in nodes:
		var path: String = prefix + "/" + String(node["name"])
		var ref: Dictionary = node["ref"]
		if ref.is_empty():
			var folder: TreeItem = _add(parent, String(node["name"]), "", path)
			_add_branch_nodes(folder, node["children"], path)
			continue
		var badge: PackedStringArray = PackedStringArray()
		if bool(ref["gone"]):
			badge.append("gone")
		if int(ref["ahead"]) > 0:
			badge.append("↑%d" % int(ref["ahead"]))
		if int(ref["behind"]) > 0:
			badge.append("↓%d" % int(ref["behind"]))
		var item: TreeItem = _add(parent, String(node["name"]), " ".join(badge))
		item.set_tooltip_text(0, String(ref["short_name"]))
		if bool(ref["is_head"]):
			item.set_custom_color(0, get_theme_color(&"head_color", THEME_TYPE))
			item.set_text(0, "● " + String(node["name"]))


func _rebuild_tags() -> void:
	var tags: Array[Dictionary] = session.tags() if session != null else []
	var section: TreeItem = _reset(Section.TAGS, str(tags.size()) if not tags.is_empty() else "")
	for tag: Dictionary in tags:
		_add(section, String(tag["name"]), String(tag["commit"]).left(7))


func _rebuild_stashes() -> void:
	var stashes: Array[Dictionary] = session.stashes() if session != null else []
	var section: TreeItem = _reset(Section.STASHES, str(stashes.size()) if not stashes.is_empty() else "")
	for stash: Dictionary in stashes:
		var branch: String = String(stash["branch"])
		_add(section, String(stash["message"]), branch)


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
