class_name WorktreeBranchList
extends Tree
## The New worktree dialog's rows under its branch field (PLAN §4 New task):
## what the typed name can make (see `rows`). The field keeps the focus: it
## moves the selection with `move`, and the selected row is the choice.
## A branch checked out in a worktree is listed muted and can't be chosen.

## The selected row changed (or the rows did).
signal choice_changed()
## A row was double-clicked: create with it.
signal activated()

const THEME_TYPE: StringName = &"BranchPopover"
## Rows listed at most (the best matches first).
const MAX_ROWS: int = 50

var session: RepoSession = null


func _ready() -> void:
	hide_root = true
	hide_folding = true
	columns = 2
	set_column_expand(1, false)
	select_mode = Tree.SELECT_ROW
	# The branch field keeps the focus; clicks still pick rows.
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size.y = float(get_theme_constant(&"branch_list_height", FormDialog.THEME_TYPE))
	item_selected.connect(func() -> void: choice_changed.emit())
	item_activated.connect(func() -> void:
		if not choice().is_empty():
			activated.emit())
	AutoScroll.enable(self)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		custom_minimum_size.y = float(get_theme_constant(&"branch_list_height", FormDialog.THEME_TYPE))


## Lists the rows for `typed` (see `rows`) and selects the first one that
## can be chosen.
func show_for(typed: String) -> void:
	clear()
	var root: TreeItem = create_item()
	if session == null:
		choice_changed.emit()
		return
	var font: Font = get_theme_font(&"font")
	var font_size: int = get_theme_font_size(&"font_size")
	var badge_width: float = 0.0
	for row: Dictionary in rows(session.branch_refs(), session.remotes(), typed):
		var item: TreeItem = create_item(root)
		var start: String = String(row["start"])
		item.set_text(0, tr("Create %s") % row["branch"] if start == "new" else String(row["label"]))
		item.set_icon(0, AppTheme.icon(&"Add" if start == "new" else &"GitRemote" if start == "remote"
				else &"GitWorktree" if not String(row["worktree"]).is_empty() else &"GitBranch"))
		item.set_metadata(0, row)
		var tooltip: String = String(row["label"])
		if not String(row["worktree"]).is_empty():
			item.set_text(1, String(row["worktree"]).get_file())
			tooltip += "\n" + tr("Checked out in %s") % String(row["worktree"])
			item.set_selectable(0, false)
			item.set_selectable(1, false)
			item.set_custom_color(0, get_theme_color(&"badge_color", THEME_TYPE))
		elif start == "remote":
			tooltip += "\n" + tr("Check out as %s, tracking it") % String(row["branch"])
		item.set_custom_color(1, get_theme_color(&"badge_color", THEME_TYPE))
		item.set_tooltip_text(0, tooltip)
		if not item.get_text(1).is_empty():
			badge_width = maxf(badge_width, font.get_string_size(item.get_text(1), HORIZONTAL_ALIGNMENT_LEFT, -1,
					font_size).x)
	set_column_custom_minimum_width(1, ceili(badge_width) + get_theme_constant(&"inner_item_margin_left")
			+ get_theme_constant(&"inner_item_margin_right") + get_theme_constant(&"h_separation") * 2
			if badge_width > 0.0 else 0)
	var first: TreeItem = _next_selectable(root.get_first_child(), 1)
	if first != null and not typed.is_empty():
		first.select(0)
		scroll_to_item(first)
	else:
		deselect_all()
		if root.get_first_child() != null:
			scroll_to_item(root.get_first_child())
	choice_changed.emit()


## The rows for the typed name, each `{start, branch, upstream, label,
## worktree}`: `start` is `new` (create `branch`), `existing` (check out
## local branch `branch`) or `remote` (check out remote branch `upstream` as
## `branch`); `worktree` is where a local branch is checked out ("" if
## nowhere). A local branch named `typed` comes first (nothing to create);
## else a remote branch whose local name is `typed`, then Create; then the
## other local and remote branches whose names contain it, A–Z. Remote
## branches a local branch tracks are left out. With nothing typed there is
## no Create row and every branch is listed.
static func rows(refs: Array[Dictionary], remotes: PackedStringArray, typed: String) -> Array[Dictionary]:
	var tracked: Dictionary[String, bool] = {}
	var local: Array[Dictionary] = []
	var remote: Array[Dictionary] = []
	for ref: Dictionary in refs:
		if String(ref["kind"]) == "branch":
			if not String(ref["upstream"]).is_empty():
				tracked[String(ref["upstream"])] = true
			var short: String = String(ref["short_name"])
			local.append({"start": "existing", "branch": short, "upstream": "", "label": short,
				"worktree": String(ref["worktree"])})
	var local_names: Dictionary[String, bool] = {}
	for row: Dictionary in local:
		local_names[String(row["branch"])] = true
	for ref: Dictionary in refs:
		var short: String = String(ref["short_name"])
		if String(ref["kind"]) == "branch" or tracked.has(short) or short.ends_with("/HEAD"):
			continue
		var branch: String = local_name(short, remotes)
		if branch.is_empty() or local_names.has(branch):
			continue
		remote.append({"start": "remote", "branch": branch, "upstream": short, "label": short, "worktree": ""})
	var by_label: Callable = func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["label"]).naturalnocasecmp_to(String(b["label"])) < 0
	local.sort_custom(by_label)
	remote.sort_custom(by_label)
	var out: Array[Dictionary] = []
	var query: String = typed.to_lower()
	var exact_local: Array[Dictionary] = []
	exact_local.assign(local.filter(func(r: Dictionary) -> bool: return String(r["branch"]) == typed))
	var exact_remote: Array[Dictionary] = []
	exact_remote.assign(remote.filter(func(r: Dictionary) -> bool: return String(r["branch"]) == typed))
	if not typed.is_empty():
		out.append_array(exact_local)
		# `origin` first when several remotes have it.
		exact_remote.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a["upstream"]).begins_with("origin/") and not String(b["upstream"]).begins_with("origin/"))
		out.append_array(exact_remote)
		if exact_local.is_empty():
			out.insert(mini(out.size(), 1), {"start": "new", "branch": typed, "upstream": "", "label": typed,
				"worktree": ""})
	for row: Dictionary in local + remote:
		if out.size() >= MAX_ROWS:
			break
		if not typed.is_empty() and String(row["branch"]) == typed:
			continue
		if query.is_empty() or String(row["label"]).to_lower().contains(query):
			out.append(row)
	return out


## The local name of remote branch `short` (`origin/feature/x` → `feature/x`),
## by the longest remote name it starts with; "" when none does.
static func local_name(short: String, remotes: PackedStringArray) -> String:
	var best: String = ""
	for remote: String in remotes:
		if short.begins_with(remote + "/") and remote.length() > best.length():
			best = remote
	return "" if best.is_empty() else short.substr(best.length() + 1)


## The selected row (see `rows`), or empty.
func choice() -> Dictionary:
	var item: TreeItem = get_selected()
	return item.get_metadata(0) as Dictionary if item != null and item.get_metadata(0) is Dictionary else {}


## Selects the `step`-th choosable row after the selected one (before it,
## when negative), stopping at the ends.
func move(step: int) -> void:
	var item: TreeItem = get_selected()
	var root: TreeItem = get_root()
	if root == null:
		return
	var direction: int = 1 if step > 0 else -1
	var target: TreeItem = item
	for i: int in absi(step):
		var start: TreeItem = root.get_first_child() if target == null \
				else target.get_next() if direction > 0 else target.get_prev()
		var found: TreeItem = _next_selectable(start, direction)
		if found == null:
			break
		target = found
	if target != null and target != item:
		target.select(0)
		scroll_to_item(target)


## The rows' labels as shown, in order (for tests).
func row_labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var root: TreeItem = get_root()
	if root != null:
		for item: TreeItem in root.get_children():
			out.append(item.get_text(0))
	return out


## `item`, or the first row after it (before it, `direction` -1) that can be
## chosen; null when none.
func _next_selectable(item: TreeItem, direction: int) -> TreeItem:
	while item != null and not item.is_selectable(0):
		item = item.get_next() if direction > 0 else item.get_prev()
	return item
