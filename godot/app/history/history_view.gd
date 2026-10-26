class_name HistoryView
extends HSplitContainer
## History of one worktree: the commit list (with a status line) on the left,
## the selected commit's details and diff on the right. Right moves from the
## list into the details' files, and from there into the diff; Left goes back.
## A commit is always selected once there is one: the newest by default.
## Above the list, a search finds commits by subject, author or hash
## (`RepoSession.search_commits`) and highlights them in place: the graph
## stays whole, other rows are dimmed. When a search finishes, the first
## match from the selected commit down is selected; Enter and Shift+Enter
## (or F3, Shift+F3 and the field's arrows, shown while searching) step
## through the matches.

signal repo_loaded(row_count: int, error: String)
## Right-click or the menu key on a commit; `at_position` is in screen coordinates.
signal commit_menu_requested(at_position: Vector2)
## Right-click on a ref label: `{name, short, kind, is_head}`, screen position.
signal label_menu_requested(label: Dictionary, at_position: Vector2)

var session: RepoSession = null:
	set = set_session

## What the header says without a search: the commit count, progress or an error.
var _commits_text: String = ""
## A new query's first match is still to be selected.
var _jump_pending: bool = false
## The field's previous and next match buttons.
var _match_buttons: Array[Button] = []

@onready var _commit_list: CommitList = %CommitList
@onready var _list_header: ListHeader = %ListHeader
@onready var _search: FilterField = %SearchField
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
	for entry: Array in [[&"ChevronUp", "Previous match (Shift+Enter)", false], [&"ChevronDown", "Next match (Enter)", true]]:
		var button: Button = _search.add_button(entry[0], entry[1])
		button.pressed.connect(step_match.bind(entry[2]))
		button.hide()
		_match_buttons.append(button)
	_search.changed.connect(_on_search_text)
	_search.submitted.connect(func(backwards: bool) -> void: step_match(not backwards))
	_search.done.connect(func() -> void: _commit_list.grab_focus())
	_apply_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()


func set_session(value: RepoSession) -> void:
	if session != null:
		session.graph_changed.disconnect(_on_graph_changed)
		session.graph_loaded.disconnect(_on_graph_loaded)
		session.graph_reset.disconnect(_on_graph_reset)
		session.search_changed.disconnect(_on_search_changed)
	session = value
	if session != null:
		session.graph_changed.connect(_on_graph_changed)
		session.graph_loaded.connect(_on_graph_loaded)
		session.graph_reset.connect(_on_graph_reset)
		session.search_changed.connect(_on_search_changed)
		if is_node_ready():
			session.search_commits(_search.text())
	_commit_list.session = session
	_details.session = session
	_commits_text = "Loading…" if session != null else ""
	_update_header()


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


## The line above the list: the commit count, progress or an error, or
## the search's matches.
func status_text() -> String:
	return _list_header.text()


func search_field() -> FilterField:
	return _search


## The search field's previous and next match buttons.
func match_buttons() -> Array[Button]:
	return _match_buttons


## Focuses the search box.
func focus_search() -> void:
	_search.focus_text()


## Whether a search has matches to step through.
func has_matches() -> bool:
	return session != null and int(session.search_info().get("matches", 0)) > 0


## Selects the next match after the selected commit (the previous one when
## not `forward`), wrapping around.
func step_match(forward: bool) -> void:
	if session == null:
		return
	var cursor: int = _commit_list.cursor
	var row: int = session.next_match(cursor, forward) if cursor >= 0 or not forward else _first_match_from(0)
	if row >= 0:
		_select(row)


func list_header() -> ListHeader:
	return _list_header


## The commit under the cursor: `{hash, subject}`, or empty.
func selected_commit() -> Dictionary:
	var row: int = _commit_list.cursor
	var hash: String = _commit_list.hash_at(row)
	if hash.is_empty():
		return {}
	return {"hash": hash, "subject": String(_commit_list.row_data(row).get("subject", ""))}


func _on_commit_selected() -> void:
	_details.show_commit(_commit_list.hash_at(_commit_list.cursor))
	_update_header()


func _select(row: int) -> void:
	_commit_list.select_only(row)
	_commit_list.scroll_to_row(row)


## The first match at `row` or below it, wrapping around; -1 without matches.
func _first_match_from(row: int) -> int:
	if row <= 0:
		return 0 if session.search_match_index(0) == 0 else session.next_match(0, true)
	return session.next_match(row - 1, true)


func _on_search_text() -> void:
	_jump_pending = true
	for button: Button in _match_buttons:
		button.visible = not _search.text().strip_edges().is_empty()
	_commit_list.set_search(_search.text())
	if session != null:
		session.search_commits(_search.text())


func _on_search_changed() -> void:
	_commit_list.reload_matches()
	if _jump_pending and bool(session.search_info().get("done", false)):
		_jump_pending = false
		if session.search_match_index(_commit_list.cursor) < 0:
			var row: int = _first_match_from(_commit_list.cursor)
			if row >= 0:
				_select(row)
	_update_header()


## The commit count, or while searching "Searching… 12 matches", "3 of 41
## matches" (the selected commit is the third) or "No matches".
func _update_header() -> void:
	var info: Dictionary = session.search_info() if session != null else {}
	if info.is_empty():
		_list_header.set_text(_commits_text)
		return
	var matches: int = int(info["matches"])
	var text: String = ListHeader.count_text(matches, "match", "matches")
	var index: int = session.search_match_index(_commit_list.cursor)
	if not bool(info["done"]):
		text = "Searching… %s" % text
	elif matches == 0:
		text = "No matches"
	elif index >= 0:
		text = "%d of %s" % [index + 1, text]
	_list_header.set_text(text)


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
	_commits_text = "Loading… %s" % ListHeader.count_text(session.graph_row_count(), "commit")
	_update_header()
	_select_newest_if_none()


func _on_graph_reset() -> void:
	_commits_text = "Reloading…"
	_update_header()


func _on_graph_loaded(row_count: int, error: String) -> void:
	_commits_text = error if not error.is_empty() else ListHeader.count_text(row_count, "commit")
	_update_header()
	_select_newest_if_none()
	if row_count == 0:
		_details.show_placeholder("No commits yet." if error.is_empty() else "")
	repo_loaded.emit(row_count, error)


## Selects the newest commit while none is (on the first rows of a load).
func _select_newest_if_none() -> void:
	if _commit_list.cursor < 0 and _commit_list.row_count() > 0:
		_commit_list.select_only(0)

