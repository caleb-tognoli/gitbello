class_name CommandPalette
extends PanelContainer
## Fuzzy search over actions plus dynamic entries (tabs, recent repositories)
## (PLAN §4). Opened with Ctrl+K / Ctrl+Shift+P. Enter runs the selection,
## Escape or clicking elsewhere closes it.

signal closed()

## Extra entries from the shell: `{label, detail, run: Callable}`.
var dynamic_entries: Callable = Callable()

## Shown entries, parallel to the tree items: `{label, detail, run: Callable}`.
var _entries: Array[Dictionary] = []
var _visible: Array[Dictionary] = []

@onready var _query: LineEdit = %Query
@onready var _results: Tree = %Results


func _ready() -> void:
	hide()
	_results.set_column_expand(1, false)
	_query.text_changed.connect(func(_text: String) -> void: _filter())
	_query.gui_input.connect(_on_query_input)
	_results.item_activated.connect(_run_selected)


func open() -> void:
	_layout()
	_collect()
	_query.text = ""
	_filter()
	show()
	_query.grab_focus()


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
		if not action.is_enabled():
			continue
		var id: StringName = action.id
		_entries.append({
			"label": "%s: %s" % [action.category, action.label],
			"detail": Actions.shortcut_label(id),
			"run": func() -> void: Actions.run_action(id),
		})
	if dynamic_entries.is_valid():
		for entry: Dictionary in dynamic_entries.call():
			_entries.append(entry)


func _filter() -> void:
	var labels: PackedStringArray = PackedStringArray()
	for entry: Dictionary in _entries:
		labels.append(String(entry["label"]))
	var order: PackedInt32Array = Core.fuzzy_rank(_query.text, labels)
	_visible.clear()
	_results.clear()
	var root: TreeItem = _results.create_item()
	for i: int in order:
		var entry: Dictionary = _entries[i]
		_visible.append(entry)
		var item: TreeItem = root.create_child()
		item.set_text(0, String(entry["label"]))
		item.set_text(1, String(entry.get("detail", "")))
	var first: TreeItem = root.get_first_child()
	if first != null:
		first.select(0)


func _run_selected() -> void:
	var item: TreeItem = _results.get_selected()
	if item == null:
		return
	var entry: Dictionary = _visible[item.get_index()]
	close()
	(entry["run"] as Callable).call()


func _move_selection(step: int) -> void:
	var item: TreeItem = _results.get_selected()
	if item == null:
		return
	var next: TreeItem = item.get_next() if step > 0 else item.get_prev()
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
