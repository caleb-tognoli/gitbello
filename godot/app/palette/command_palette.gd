class_name CommandPalette
extends PanelContainer
## Fuzzy search over actions plus dynamic entries (tabs, recent repositories)
## (PLAN §4). Opened with Ctrl+K / Ctrl+Shift+P. Enter runs the selection,
## Escape or clicking elsewhere closes it.

signal closed()

const DISABLED_HINTS: Dictionary[String, String] = {
	"Open a repository first.": "Open a repository",
	"No repository": "Open a repository",
	"This repository has no shelves.": "No shelves",
	"Select a changed file first.": "Select a changed file",
	"No changed files are listed.": "No changed files",
	"Check files first.": "No checked files",
	"Search the history first.": "Search History",
	"There is no discard to undo.": "Nothing to undo",
	"Select a shelf in the Shelves view first.": "Select a shelf",
	"Select a shelved file first.": "Select a shelved file",
	"There is no shelf discard to undo.": "Nothing to undo",
	"No changes were left on this branch.": "No changes left here",
	"This repository has no remote. Add one with Repository → Remotes…": "Add a remote",
	"The current branch does not follow a remote branch.": "No upstream branch",
	"There is no branch checked out.": "No branch checked out",
	"There is no commit to start a branch from yet.": "No commits yet",
	"There is no remote to follow.": "No remote branches",
	"Select the current HEAD commit in History to amend it.": "Select HEAD in History",
	"There are no other worktrees.": "No other worktrees",
	"No worktree folder is missing.": "No missing worktrees",
	"The last commit changed. Start amend again.": "HEAD changed—restart amend",
	"Finish the operation in progress first": "Finish current operation",
	"Loading the commit message": "Loading message",
	"Resolve conflicts first": "Resolve conflicts",
	"Reading the changes": "Reading changes",
	"There is no commit to amend": "No commits yet",
}

## Extra entries from the shell: `{label, detail, run: Callable}`.
var dynamic_entries: Callable = Callable()

## Shown entries, parallel to the tree items: `{label, detail, run: Callable}`.
var _entries: Array[Dictionary] = []
var _visible: Array[Dictionary] = []

@onready var _query: LineEdit = %Query
@onready var _results: Tree = %Results


func _ready() -> void:
	hide()
	_query.placeholder_text = tr("Type a command, repository or tab…")
	_results.set_column_expand(1, false)
	_query.text_changed.connect(func(_text: String) -> void: _filter())
	_query.gui_input.connect(_on_query_input)
	_results.item_activated.connect(_on_result_activated)
	_results.gui_input.connect(func(event: InputEvent) -> void:
		var mouse: InputEventMouseButton = event as InputEventMouseButton
		if mouse != null and mouse.pressed:
			_query.grab_focus())


func open() -> void:
	_layout()
	_collect()
	_query.text = ""
	_filter()
	show()
	_query.grab_focus()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_query.placeholder_text = tr("Type a command, repository or tab…")
		if visible:
			_collect()
			_filter()


## Size and position come from the theme (`CommandPalette` constants).
func _layout() -> void:
	var width: float = float(get_theme_constant(&"width", &"CommandPalette"))
	var height: float = float(get_theme_constant(&"height", &"CommandPalette"))
	var top: float = float(get_theme_constant(&"top", &"CommandPalette"))
	var parent_size: Vector2 = get_parent_area_size()
	width = minf(width, parent_size.x - 2.0 * top)
	offset_left = -width * 0.5
	offset_right = width * 0.5
	offset_top = top
	offset_bottom = top + minf(height, parent_size.y - 2.0 * top)


func close() -> void:
	if visible:
		hide()
		closed.emit()


## Entries currently listed, best match first (for tests).
func visible_labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for entry: Dictionary in _visible:
		out.append(String(entry["label"]))
	return out


func set_query(text: String) -> void:
	_query.text = text
	_filter()


func run_selected() -> void:
	_run_selected()


func _collect() -> void:
	_entries.clear()
	for action: ActionRegistry.Action in Actions.listed():
		var id: StringName = action.id
		_entries.append({
			"action": id,
			"label": "%s: %s" % [action.category, action.label],
			"detail": Actions.shortcut_label(id),
			"icon": Actions.icon(id),
			"run": func() -> void: Actions.run_action(id),
		})
	if dynamic_entries.is_valid():
		for entry: Dictionary in dynamic_entries.call():
			_entries.append(entry)


func _filter() -> void:
	var query: String = _query.text.strip_edges()
	var searching: bool = not query.is_empty()
	var candidates: Array[Dictionary] = []
	var labels: PackedStringArray = PackedStringArray()
	for entry: Dictionary in _entries:
		if searching or _entry_enabled(entry):
			candidates.append(entry)
			labels.append(String(entry["label"]))
	var order: PackedInt32Array = Core.fuzzy_rank(query, labels)
	_visible.clear()
	_results.clear()
	_results.set_column_expand(1, searching)
	_results.set_column_clip_content(0, searching)
	_results.set_column_clip_content(1, searching)
	var root: TreeItem = _results.create_item()
	for i: int in order:
		var entry: Dictionary = candidates[i]
		var enabled: bool = _entry_enabled(entry)
		var detail: String = String(entry.get("detail", ""))
		var full_detail: String = detail
		if not enabled:
			full_detail = Actions.disabled_reason(StringName(entry["action"]))
			detail = full_detail.trim_suffix(".")
			for reason: String in DISABLED_HINTS:
				if tr(reason) == full_detail:
					detail = tr(DISABLED_HINTS[reason])
					break
			if detail.is_empty():
				detail = tr("Unavailable here")
		_visible.append(entry)
		var item: TreeItem = root.create_child()
		item.set_text(0, String(entry["label"]))
		item.set_icon(0, entry.get("icon") as Texture2D)
		item.set_text(1, detail)
		for column: int in 2:
			item.set_selectable(column, enabled)
			item.set_text_overrun_behavior(column, TextServer.OVERRUN_TRIM_ELLIPSIS)
			item.set_tooltip_text(column, "%s\n%s" % [entry["label"], full_detail if not full_detail.is_empty() else detail])
			if not enabled:
				item.set_custom_color(column, get_theme_color(&"font_color", &"DimLabel"))
		if not enabled:
			item.set_autowrap_mode(1, TextServer.AUTOWRAP_WORD_SMART)
			item.set_text_overrun_behavior(1, TextServer.OVERRUN_NO_TRIMMING)
			item.set_icon_modulate(0, get_theme_color(&"font_color", &"DimLabel"))
	var first: TreeItem = root.get_first_child()
	while first != null and not first.is_selectable(0):
		first = first.get_next()
	if first != null:
		first.select(0)


func _entry_enabled(entry: Dictionary) -> bool:
	return not entry.has("action") or Actions.is_enabled(StringName(entry["action"]))


func _on_result_activated() -> void:
	var item: TreeItem = _results.get_item_at_position(_results.get_local_mouse_position())
	if item != null and item.is_selectable(0) and item == _results.get_selected():
		_run_selected()


func _run_selected() -> void:
	var item: TreeItem = _results.get_selected()
	if item == null:
		return
	var entry: Dictionary = _visible[item.get_index()]
	if not item.is_selectable(0) or not _entry_enabled(entry):
		_filter()
		return
	close()
	(entry["run"] as Callable).call()


func _move_selection(step: int) -> void:
	var item: TreeItem = _results.get_selected()
	if item == null:
		return
	var next: TreeItem = item.get_next() if step > 0 else item.get_prev()
	while next != null and not next.is_selectable(0):
		next = next.get_next() if step > 0 else next.get_prev()
	if next != null:
		next.select(0)
		_results.scroll_to_item(next)


func _on_query_input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed:
		return
	if key.is_action("ui_down"):
		_move_selection(1)
	elif key.is_action("ui_up"):
		_move_selection(-1)
	elif key.is_action("ui_cancel"):
		close()
	elif key.is_action("ui_text_submit") or key.is_action("ui_accept"):
		_run_selected()
	else:
		return
	_query.accept_event()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_action_pressed("ui_cancel"):
		close()
		accept_event()
