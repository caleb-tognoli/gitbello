class_name HistoryView
extends HSplitContainer
## History of one worktree: the commit list (with a status line) on the left,
## the selected commit's details and diff on the right. Right moves from the
## list into the details' files, and from there into the diff; Left goes back.

signal repo_loaded(row_count: int, error: String)
## Right-click or the menu key on a commit; `at_position` is in screen coordinates.
signal commit_menu_requested(at_position: Vector2)
## Right-click on a ref label: `{name, short, kind, is_head}`, screen position.
signal label_menu_requested(label: Dictionary, at_position: Vector2)

var session: RepoSession = null:
	set = set_session

@onready var _commit_list: CommitList = %CommitList
@onready var _status_label: Label = %StatusLabel
@onready var _details: CommitDetails = %Details
@onready var _left: VBoxContainer = %Left
@onready var _switch_slot: Container = %SwitchSlot


func _ready() -> void:
	_details.date_format = _commit_list.date_text
	_commit_list.selection_changed.connect(_on_commit_selected)
	_commit_list.gui_input.connect(_on_list_key)
	_commit_list.context_menu_requested.connect(func(row: int, at: Vector2) -> void:
		var label: Dictionary = _commit_list.label_at(row, at)
		if label.is_empty():
			commit_menu_requested.emit(_commit_list.get_screen_position() + at)
		else:
			label_menu_requested.emit(label, _commit_list.get_screen_position() + at))
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


## Where the Changes/History switch goes while this view shows.
func switch_slot() -> Container:
	return _switch_slot


## The left column (its width is saved per repository).
func left_pane() -> Control:
	return _left


func details() -> CommitDetails:
	return _details


## The line above the list: the commit count, progress or an error.
func status_text() -> String:
	return _status_label.text


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
	_left.custom_minimum_size.x = float(get_theme_constant(&"min_left_width", &"Panes"))


func _on_graph_changed(_start: int, _count: int) -> void:
	_status_label.text = "Loading… %s commits" % _thousands(session.graph_row_count())


func _on_graph_reset() -> void:
	_status_label.text = "Reloading…"


func _on_graph_loaded(row_count: int, error: String) -> void:
	if not error.is_empty():
		_status_label.text = error
	else:
		_status_label.text = "%s commit%s" % [_thousands(row_count), "" if row_count == 1 else "s"]
	repo_loaded.emit(row_count, error)


static func _thousands(value: int) -> String:
	var digits: String = str(value)
	var out: String = ""
	while digits.length() > 3:
		out = "," + digits.right(3) + out
		digits = digits.left(digits.length() - 3)
	return digits + out
