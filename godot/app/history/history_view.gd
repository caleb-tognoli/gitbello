class_name HistoryView
extends VBoxContainer
## History of one repository: a status line, the commit list and the
## selected commit's details. Right moves from the list into the details'
## files, and from there into the diff; Left goes back.

signal repo_loaded(row_count: int, error: String)

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


func _on_commit_selected() -> void:
	_details.show_commit(_commit_list.hash_at(_commit_list.cursor))


func _on_list_key(event: InputEvent) -> void:
	if event.is_action_pressed("ui_right", false, true) and _details.file_list().row_count() > 0:
		_details.focus_files()
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
