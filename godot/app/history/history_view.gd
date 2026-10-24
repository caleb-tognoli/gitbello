class_name HistoryView
extends VBoxContainer
## History tab content for one repository: toolbar plus the commit list.
## M1 spike: the Open button moves into the ActionRegistry in M3.

signal repo_loaded(row_count: int, error: String)

@onready var _session: RepoSession = %Session
@onready var _commit_list: CommitList = %CommitList
@onready var _path_label: Label = %PathLabel
@onready var _status_label: Label = %StatusLabel
@onready var _open_button: Button = %OpenButton


func _ready() -> void:
	_commit_list.session = _session
	_session.graph_changed.connect(_on_graph_changed)
	_session.graph_loaded.connect(_on_graph_loaded)
	_open_button.pressed.connect(_show_open_dialog)


func commit_list() -> CommitList:
	return _commit_list


func session() -> RepoSession:
	return _session


func open_repo(path: String) -> void:
	_path_label.text = path
	var error: String = _session.open(path)
	_commit_list.session = _session
	if error.is_empty():
		_status_label.text = "Loading…"
	else:
		_status_label.text = error
		repo_loaded.emit(0, error)
	_commit_list.grab_focus()


func _show_open_dialog() -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.use_native_dialog = true
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.title = "Open repository"
	dialog.dir_selected.connect(open_repo)
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


func _on_graph_changed(_start: int, _count: int) -> void:
	_status_label.text = "Loading… %s commits" % _thousands(_session.graph_row_count())


func _on_graph_loaded(row_count: int, error: String) -> void:
	if not error.is_empty():
		_status_label.text = error
	else:
		var stats: Dictionary = _session.load_stats()
		_status_label.text = "%s commits · first page %d ms · indexed in %d ms · %d lanes max" % [
			_thousands(row_count),
			int(stats.get("first_page_ms", 0.0)),
			int(stats.get("total_ms", 0.0)),
			int(stats.get("max_lanes", 0)),
		]
	repo_loaded.emit(row_count, error)


static func _thousands(value: int) -> String:
	var digits: String = str(value)
	var out: String = ""
	while digits.length() > 3:
		out = "," + digits.right(3) + out
		digits = digits.left(digits.length() - 3)
	return digits + out
