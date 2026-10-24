class_name HistoryView
extends VBoxContainer
## History of one repository: a status line and the commit list.

signal repo_loaded(row_count: int, error: String)

var session: RepoSession = null:
	set = set_session

@onready var _commit_list: CommitList = %CommitList
@onready var _status_label: Label = %StatusLabel


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
	_status_label.text = "Loading…" if session != null else ""


func commit_list() -> CommitList:
	return _commit_list


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
