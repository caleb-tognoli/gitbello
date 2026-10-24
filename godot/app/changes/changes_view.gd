class_name ChangesView
extends HSplitContainer
## Working-copy changes of one repository (PLAN §4): unstaged, untracked and
## staged file lists, the commit box and the diff of the selected file.
## Keyboard: arrows move, Enter/Space stage or unstage, Tab moves between
## controls; see the `changes.*` actions for the rest.

const THEME_TYPE: StringName = &"ChangesView"

var session: RepoSession = null:
	set = set_session

## The diff currently shown, to keep its scroll position across reloads.
var _shown_diff: String = ""

@onready var _files: VBoxContainer = %Files
@onready var _unstaged_section: Control = %UnstagedSection
@onready var _unstaged_label: Label = %UnstagedLabel
@onready var _unstaged: ChangeList = %UnstagedList
@onready var _stage_section_button: Button = %StageSectionButton
@onready var _untracked_section: Control = %UntrackedSection
@onready var _untracked_label: Label = %UntrackedLabel
@onready var _untracked: ChangeList = %UntrackedList
@onready var _add_untracked_button: Button = %AddUntrackedButton
@onready var _staged_section: Control = %StagedSection
@onready var _staged_label: Label = %StagedLabel
@onready var _staged: ChangeList = %StagedList
@onready var _unstage_section_button: Button = %UnstageSectionButton
@onready var _clean_label: Label = %CleanLabel
@onready var _commit_box: CommitBox = %CommitBox
@onready var _diff_path: Label = %DiffPath
@onready var _diff_stats: Label = %DiffStats
@onready var _diff_view: DiffView = %DiffView
@onready var _diff_message: Control = %DiffMessage
@onready var _diff_message_label: Label = %DiffMessageLabel
@onready var _load_anyway: Button = %LoadAnywayButton


func _ready() -> void:
	_apply_theme()
	_unstaged.groups = PackedStringArray(["conflicted", "unstaged"])
	_untracked.groups = PackedStringArray(["untracked"])
	_staged.groups = PackedStringArray(["staged"])
	for list: ChangeList in lists():
		list.stage_requested.connect(_on_stage_requested)
		list.current_changed.connect(_on_current_changed.bind(list))
	_stage_section_button.pressed.connect(func() -> void: _stage_list(_unstaged))
	_add_untracked_button.pressed.connect(func() -> void: _stage_list(_untracked))
	_unstage_section_button.pressed.connect(unstage_all)
	_load_anyway.pressed.connect(_load_full_diff)
	_diff_view.source = func(start: int, count: int) -> Array:
		return session.diff_lines(start, count) if session != null else []
	_show_diff_message("Select a file to see its changes.")


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()


func set_session(value: RepoSession) -> void:
	if session != null:
		session.status_changed.disconnect(reload)
		session.diff_changed.disconnect(_on_diff_changed)
	session = value
	if session != null:
		session.status_changed.connect(reload)
		session.diff_changed.connect(_on_diff_changed)
	for list: ChangeList in lists():
		list.session = session
	_commit_box.session = session
	reload()


func lists() -> Array[ChangeList]:
	return [_unstaged, _untracked, _staged]


func unstaged_list() -> ChangeList:
	return _unstaged


func untracked_list() -> ChangeList:
	return _untracked


func staged_list() -> ChangeList:
	return _staged


func commit_box() -> CommitBox:
	return _commit_box


func diff_view() -> DiffView:
	return _diff_view


## Re-reads the lists from the session (after every status change).
func reload() -> void:
	if not is_node_ready():
		return
	var focused: ChangeList = _focused_list()
	for list: ChangeList in lists():
		list.reload()
	var counts: Dictionary[String, int] = {}
	for group: String in ["conflicted", "unstaged", "untracked", "staged"]:
		counts[group] = session.change_count(group) if session != null else 0
	var conflicts: int = counts["conflicted"]
	_unstaged_label.text = "Unstaged · %d" % (counts["unstaged"] + conflicts) \
			+ (" · %d conflicted" % conflicts if conflicts > 0 else "")
	_untracked_label.text = "Untracked · %d" % counts["untracked"]
	_staged_label.text = "Staged · %d" % counts["staged"]
	_unstaged_section.visible = _unstaged.row_count() > 0
	_untracked_section.visible = _untracked.row_count() > 0
	_staged_section.visible = _staged.row_count() > 0
	_clean_label.visible = not (_unstaged_section.visible or _untracked_section.visible or _staged_section.visible)
	# The focused list emptied (its last file moved): continue in the next one.
	if focused != null and focused.row_count() == 0:
		focus_files()
	if _selected_list() == null:
		_clear_diff()


## Focuses the first non-empty list (cursor on its first row if none).
func focus_files() -> void:
	for list: ChangeList in lists():
		if list.row_count() > 0:
			list.grab_focus()
			list.ensure_cursor()
			return
	_commit_box.focus_summary()


func focus_message() -> void:
	_commit_box.focus_summary()


## Stages or unstages the selection of the focused (or selected) list.
func stage_selected() -> void:
	var list: ChangeList = _focused_list()
	if list == null:
		list = _selected_list()
	if list != null:
		list.activate_selection()


func stage_all() -> void:
	if session != null:
		session.stage_all()


func unstage_all() -> void:
	if session != null:
		session.unstage_all()


func commit() -> bool:
	return _commit_box.commit()


func toggle_amend() -> void:
	_commit_box.set_amend(not _commit_box.is_amend())


func has_changes() -> bool:
	return session != null and (_unstaged.row_count() + _untracked.row_count() + _staged.row_count()) > 0


func _stage_list(list: ChangeList) -> void:
	var rows: PackedInt32Array = PackedInt32Array(range(list.row_count()))
	_on_stage_requested(list.paths_by_group(rows))


func _on_stage_requested(paths_by_group: Dictionary) -> void:
	for group: String in paths_by_group:
		session.stage_paths(group, paths_by_group[group])


func _on_current_changed(group: String, path: String, list: ChangeList) -> void:
	if path.is_empty():
		if _selected_list() == null:
			_clear_diff()
		return
	# One selection across the lists: the diff follows it.
	for other: ChangeList in lists():
		if other != list and other.cursor >= 0:
			other.deselect()
	session.select_diff(group, path, false)
	_on_diff_changed()


func _focused_list() -> ChangeList:
	for list: ChangeList in lists():
		if list.has_focus():
			return list
	return null


func _selected_list() -> ChangeList:
	for list: ChangeList in lists():
		if list.cursor >= 0 and not list.selected_rows().is_empty():
			return list
	return null


func _clear_diff() -> void:
	if session != null:
		session.clear_diff()
	_shown_diff = ""
	_diff_view.show_lines(0, 0, false)
	_diff_path.text = ""
	_diff_stats.text = ""
	_show_diff_message("Select a file to see its changes.")


func _load_full_diff() -> void:
	var info: Dictionary = session.diff_info()
	var group: String = String(info.get("kind", ""))
	session.select_diff(group, String(info.get("path", "")), true)


func _on_diff_changed() -> void:
	var info: Dictionary = session.diff_info() if session != null else {}
	var state: String = String(info.get("state", "none"))
	if state == "none":
		return
	var path: String = String(info["path"])
	var key: String = String(info["kind"]) + ":" + path
	_diff_path.text = path
	var notes: PackedStringArray = info.get("notes", PackedStringArray())
	var stats: PackedStringArray = PackedStringArray(notes)
	if int(info.get("additions", 0)) > 0 or int(info.get("deletions", 0)) > 0:
		stats.append("+%d −%d" % [int(info["additions"]), int(info["deletions"])])
	_diff_stats.text = "  ·  ".join(stats)
	match state:
		"loading":
			if key != _shown_diff:
				_diff_view.show_lines(0, 0, false)
				_show_diff_message("Loading…")
			return
		"error":
			var error: Dictionary = info.get("error", {})
			_diff_view.show_lines(0, 0, false)
			_show_diff_message("Cannot show this diff.\n%s" % String(error.get("message", error.get("title", ""))))
			_shown_diff = ""
			return
	var keep: bool = key == _shown_diff
	_shown_diff = key
	match String(info.get("content", "text")):
		"text", "combined":
			_diff_message.hide()
			_diff_view.show_lines(int(info["line_count"]), int(info["max_line"]), keep)
		"binary":
			_diff_view.show_lines(0, 0, false)
			_show_diff_message("Binary file: %s → %s" % [
				_size_text(int(info["old_size"])), _size_text(int(info["new_size"]))])
		"too_large":
			_diff_view.show_lines(0, 0, false)
			_show_diff_message("This diff is large (more than %s)." % _size_text(int(info["bytes"])), true)
		"empty":
			_diff_view.show_lines(0, 0, false)
			_show_diff_message("No changes to show." if notes.is_empty() else "\n".join(notes))


func _show_diff_message(text: String, offer_full: bool = false) -> void:
	_diff_message_label.text = text
	_load_anyway.visible = offer_full
	_diff_message.show()


static func _size_text(bytes: int) -> String:
	if bytes < 0:
		return "none"
	return String.humanize_size(bytes)


func _apply_theme() -> void:
	_files.custom_minimum_size.x = float(get_theme_constant(&"files_width", THEME_TYPE))
	_files.add_theme_constant_override(&"separation", get_theme_constant(&"separation", THEME_TYPE))
