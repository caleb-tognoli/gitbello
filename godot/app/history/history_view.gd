class_name HistoryView
extends VBoxContainer
## History of one repository: a status line, the commit list and the
## selected commit's details. Right moves from the list into the details'
## files, and from there into the diff; Left goes back.

signal repo_loaded(row_count: int, error: String)
## Right-click or the menu key on a commit; `at_position` is in screen coordinates.
signal commit_menu_requested(at_position: Vector2)

var session: RepoSession = null:
	set = set_session

@onready var _commit_list: CommitList = %CommitList
@onready var _status_label: Label = %StatusLabel
@onready var _split: VSplitContainer = %Split
@onready var _details: CommitDetails = %Details


func _ready() -> void:
	_details.date_format = _commit_list.date_text
	_commit_list.selection_changed.connect(_on_commit_selected)
	_commit_list.gui_input.connect(_on_list_key)
	_commit_list.context_menu_requested.connect(func(_row: int, at: Vector2) -> void:
		commit_menu_requested.emit(_commit_list.get_screen_position() + at))
	_details.file_list().gui_input.connect(_on_files_key)
	_apply_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()


func set_session(value: RepoSession) -> void:
	if session != null:
		session.graph_changed.disconnect(_on_graph_changed)
		session.graph_loaded.disconnect(_on_graph_loaded)
		session.graph_reset.disconnect(_on_graph_reset)
	session = value
	if session != null:
		session.graph_changed.connect(_on_graph_changed)
		session.graph_loaded.connect(_on_graph_loaded)
		session.graph_reset.connect(_on_graph_reset)
	_commit_list.session = session
	_details.session = session
	_status_label.text = "Loading…" if session != null else ""


func commit_list() -> CommitList:
	return _commit_list


func details() -> CommitDetails:
	return _details


## The commit under the cursor: `{hash, subject}`, or empty.
func selected_commit() -> Dictionary:
	var row: int = _commit_list.cursor
	var hash: String = _commit_list.hash_at(row)
	if hash.is_empty():
		return {}
	return {"hash": hash, "subject": String(_commit_list.row_data(row).get("subject", ""))}


func _on_commit_selected() -> void:
	_details.show_commit(_commit_list.hash_at(_commit_list.cursor))


func _on_list_key(event: InputEvent) -> void:
	if event.is_action_pressed("ui_right", false, true) and _details.file_list().row_count() > 0:
		_details.focus_files()
		_commit_list.accept_event()
		return
	var key: InputEventKey = event as InputEventKey
	var menu_key: bool = key != null and key.pressed 			and (key.keycode == KEY_MENU or (key.keycode == KEY_F10 and key.shift_pressed))
	if menu_key and _commit_list.cursor >= 0:
		var height: float = _commit_list.row_height()
		var y: float = (_commit_list.cursor + 1) * height - _commit_list.scroll_offset()
		commit_menu_requested.emit(_commit_list.get_screen_position() + Vector2(0.0, y))
		_commit_list.accept_event()


func _on_files_key(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", false, true):
		_commit_list.grab_focus()
		_details.file_list().accept_event()


func _apply_theme() -> void:
	_details.custom_minimum_size.y = float(get_theme_constant(&"details_height", &"CommitDetails"))


func _on_graph_changed(_start: int, _count: int) -> void:
	_status_label.text = "Loading… %s commits" % _thousands(session.graph_row_count())


func _on_graph_reset() -> void:
	_status_label.text = "Reloading…"


func _on_graph_loaded(row_count: int, error: String) -> void:
	if not error.is_empty():
		_status_label.text = error
	else:
		var stats: Dictionary = session.load_stats()
		_status_label.text = "%s commits · loaded in %d ms" % [
			_thousands(row_count),
			int(stats.get("total_ms", 0.0)),
		]
	repo_loaded.emit(row_count, error)


static func _thousands(value: int) -> String:
	var digits: String = str(value)
	var out: String = ""
	while digits.length() > 3:
		out = "," + digits.right(3) + out
		digits = digits.left(digits.length() - 3)
	return digits + out
