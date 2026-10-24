class_name CommitDetails
extends HSplitContainer
## The selected commit (PLAN M4b): summary, author, date, hashes, the full
## message, its files, and the diff of the selected file.

const THEME_TYPE: StringName = &"CommitDetails"

var session: RepoSession = null:
	set = set_session
## Formats unix times (the commit list's local-time format).
var date_format: Callable = Callable()

@onready var _info: VBoxContainer = %Info
@onready var _summary: Label = %Summary
@onready var _meta: Label = %Meta
@onready var _body: Label = %Body
@onready var _body_scroll: ScrollContainer = %BodyScroll
@onready var _files_label: Label = %FilesLabel
@onready var _files: CommitFileList = %Files
@onready var _diff_panel: DiffPanel = %CommitDiffPanel


func _ready() -> void:
	_apply_theme()
	_files.current_changed.connect(_on_file_changed)
	_diff_panel.set_source(func(start: int, count: int) -> Array:
		return session.commit_diff_lines(start, count) if session != null else [])
	_diff_panel.set_split_source(func(start: int, count: int) -> Array:
		return session.diff_split_rows("commit", start, count) if session != null else [])
	_diff_panel.load_full_requested.connect(func() -> void:
		session.select_commit_file(String(session.commit_diff_info().get("path", "")), true))
	_files.gui_input.connect(_on_files_key)
	_diff_panel.view().gui_input.connect(_on_diff_key)
	show_placeholder()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()


func set_session(value: RepoSession) -> void:
	if session != null:
		session.commit_loaded.disconnect(_on_commit_loaded)
		session.commit_diff_changed.disconnect(_on_diff_changed)
	session = value
	_files.session = session
	if session != null:
		session.commit_loaded.connect(_on_commit_loaded)
		session.commit_diff_changed.connect(_on_diff_changed)


func file_list() -> CommitFileList:
	return _files


func diff_panel() -> DiffPanel:
	return _diff_panel


func summary_text() -> String:
	return _summary.text


## Asks for commit `oid`; the panel fills in when it arrives.
func show_commit(oid: String) -> void:
	if session == null or oid.is_empty():
		show_placeholder()
		return
	session.load_commit(oid)


func show_placeholder() -> void:
	_summary.text = "Select a commit to see its details."
	_meta.text = ""
	_body.text = ""
	_body_scroll.hide()
	_files_label.text = ""
	_files.show_files(0)
	_diff_panel.clear("Select a file to see its changes.")


## Focuses the file list (cursor on the first file).
func focus_files() -> void:
	_files.grab_focus()
	if _files.cursor < 0 and _files.row_count() > 0:
		_files.select_only(0)


func _on_commit_loaded() -> void:
	var info: Dictionary = session.commit_info()
	if info.is_empty():
		return
	_summary.text = String(info["summary"])
	var parents: PackedStringArray = info["parents"]
	var short_parents: PackedStringArray = PackedStringArray()
	for parent: String in parents:
		short_parents.append(parent.left(7))
	var when: String = date_format.call(int(info["time"])) if date_format.is_valid() else str(info["time"])
	var meta: PackedStringArray = PackedStringArray([
		String(info["oid"]).left(10),
		"%s <%s>" % [String(info["author"]), String(info["email"])],
		when,
	])
	if String(info["committer"]) != String(info["author"]):
		meta.append("committed by %s" % String(info["committer"]))
	if not short_parents.is_empty():
		meta.append(("parents " if short_parents.size() > 1 else "parent ") + " ".join(short_parents))
	_meta.text = "  ·  ".join(meta)
	_body.text = String(info["body"])
	_body_scroll.visible = not _body.text.is_empty()
	var count: int = int(info["file_count"])
	_files_label.text = "%d file%s changed" % [count, "" if count == 1 else "s"]
	_files.show_files(count)
	if count > 0:
		_files.select_only(0)
	else:
		_diff_panel.clear()


func _on_file_changed(path: String) -> void:
	if path.is_empty():
		return
	session.select_commit_file(path, false)
	_on_diff_changed()


func _on_diff_changed() -> void:
	_diff_panel.show_info(session.commit_diff_info())


## Right in the file list moves into the diff.
func _on_files_key(event: InputEvent) -> void:
	var view: DiffView = _diff_panel.view()
	if event.is_action_pressed("ui_right", false, true) and view.row_count() > 0:
		view.grab_focus()
		if view.cursor < 0:
			view.select_only(0)
		_files.accept_event()


func _on_diff_key(event: InputEvent) -> void:
	var view: DiffView = _diff_panel.view()
	if event.is_action_pressed("ui_left", false, true) and view.h_scroll() <= 0.0:
		_files.grab_focus()
		view.accept_event()


func _apply_theme() -> void:
	_info.custom_minimum_size.x = float(get_theme_constant(&"files_width", THEME_TYPE))
	_body_scroll.custom_minimum_size.y = float(get_theme_constant(&"body_height", THEME_TYPE))
