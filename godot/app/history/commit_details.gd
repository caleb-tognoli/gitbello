class_name CommitDetails
extends VSplitContainer
## The selected commit (PLAN M4b, laid out in M6.5): summary, author, date,
## hashes and the full message on top, then its files beside the diff of the
## selected file. The top part's height (this split) and the files' width
## (`files_split()`) are dragged by the user.

const THEME_TYPE: StringName = &"CommitDetails"
## Characters shown of the commit's and its parents' hashes.
const HASH_LENGTH: int = 10
const PARENT_LENGTH: int = 7

var session: RepoSession = null:
	set = set_session
## Formats unix times (the commit list's local-time format).
var date_format: Callable = Callable()

@onready var _files_box: VBoxContainer = %FilesBox
@onready var _split: HSplitContainer = %Split
@onready var _summary: RichTextLabel = %Summary
@onready var _who: Control = %Who
@onready var _ids: Control = %Ids
@onready var _author_name: Label = %AuthorName
@onready var _author_email: Label = %AuthorEmail
@onready var _date: Label = %DateLabel
@onready var _hash: Label = %HashLabel
@onready var _copy_hash: Button = %CopyHash
@onready var _parents: Control = %Parents
@onready var _parents_icon: TextureRect = %ParentsIcon
@onready var _parents_label: Label = %ParentsLabel
@onready var _committer: Control = %Committer
@onready var _committer_label: Label = %CommitterLabel
@onready var _body_separator: Control = %BodySeparator
@onready var _body: RichTextLabel = %Body
@onready var _no_body: Label = %NoBody
@onready var _files_label: Label = %FilesLabel
@onready var _files: CommitFileList = %Files
@onready var _diff_panel: DiffPanel = %CommitDiffPanel


func _ready() -> void:
	_copy_hash.pressed.connect(func() -> void: Actions.run_action(&"commit.copy_hash", _copy_hash))
	_copy_hash.tooltip_text = "Copy the full hash"
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


## The files beside the diff (its offset is the files' width).
func files_split() -> HSplitContainer:
	return _split


func summary_text() -> String:
	return _summary.text


func body_text() -> String:
	return _body.text


## Asks for commit `oid`; the panel fills in when it arrives.
func show_commit(oid: String) -> void:
	if session == null or oid.is_empty():
		show_placeholder()
		return
	session.load_commit(oid)


func show_placeholder() -> void:
	_summary.text = "Select a commit to see its details."
	_who.hide()
	_ids.hide()
	_show_body("")
	_no_body.hide()
	_body_separator.hide()
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
	_author_name.text = String(info["author"])
	_author_email.text = String(info["email"])
	_author_email.visible = not _author_email.text.is_empty()
	_date.text = date_format.call(int(info["time"])) if date_format.is_valid() else str(info["time"])
	var oid: String = String(info["oid"])
	_hash.text = oid.left(HASH_LENGTH)
	_hash.tooltip_text = oid
	var parents: PackedStringArray = info["parents"]
	var short_parents: PackedStringArray = PackedStringArray()
	for parent: String in parents:
		short_parents.append(parent.left(PARENT_LENGTH))
	_parents.visible = not parents.is_empty()
	_parents_icon.texture = AppTheme.icon(&"GitMerge" if parents.size() > 1 else &"GitCommit")
	_parents_icon.tooltip_text = "Parents" if parents.size() > 1 else "Parent"
	_parents_label.text = " ".join(short_parents)
	_parents_label.tooltip_text = "\n".join(parents)
	_committer.visible = String(info["committer"]) != String(info["author"])
	_committer_label.text = "committed by %s" % String(info["committer"])
	_who.show()
	_ids.show()
	_show_body(String(info["body"]).strip_edges())
	_no_body.visible = _body.text.is_empty()
	_body_separator.show()
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


func _show_body(text: String) -> void:
	_body.text = text
	_body.scroll_to_line(0)
	_body.visible = not text.is_empty()


func _apply_theme() -> void:
	_files_box.custom_minimum_size.x = float(get_theme_constant(&"min_files_width", THEME_TYPE))
	_copy_hash.icon = AppTheme.icon(&"ActionCopy")
	var tint: Color = get_theme_color(&"icon_tint", THEME_TYPE)
	var icon_size: float = float(get_theme_constant(&"icon_size", THEME_TYPE))
	for entry: Array in [[%AuthorIcon, &"User"], [%DateIcon, &"Clock"], [%HashIcon, &"GitCommit"],
			[_parents_icon, &""], [%CommitterIcon, &"User"]]:
		var rect: TextureRect = entry[0]
		if entry[1] != &"":
			rect.texture = AppTheme.icon(entry[1])
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.custom_minimum_size = Vector2(icon_size, icon_size)
		rect.self_modulate = tint
