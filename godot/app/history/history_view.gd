class_name HistoryView
extends HSplitContainer
## History of one worktree: the commit list (with a status line) on the left,
## the selected commit's details and diff on the right. Right moves from the
## list into the details' files, and from there into the diff; Left goes back.
## HEAD is selected initially; reloads follow it or preserve a historical selection.
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
signal notice(title: String, message: String)

var _graph_loading: bool = true
var _parent_action_oid: String = ""
var _parent_action_source: String = ""
var _parent_action_session: RepoSession = null
var _pending_parent_oid: String = ""
var _pending_parent_source: String = ""
var _pending_parent_session: RepoSession = null


var session: RepoSession = null:
	set = set_session

## What the header says without a search: the commit count, progress or an error.
var _commits_text: String = ""
## A new query's first match is still to be selected.
var _jump_pending: bool = false
## The field's previous and next match buttons.
var _match_buttons: Array[Button] = []
var _selected_oid: String = ""
var _restore_oid: String = ""
var _head_pending: bool = false
var _follow_head: bool = false

var _scope_menu: PopupMenu = null
var _scope_button: Button = null
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
	_details.parent_requested.connect(_on_parent_requested)
	for entry: Array in [[&"ChevronUp", "Previous match (Shift+Enter)", false], [&"ChevronDown", "Next match (Enter)", true]]:
		var button: Button = _search.add_button(entry[0], entry[1])
		button.pressed.connect(step_match.bind(entry[2]))
		button.hide()
		_match_buttons.append(button)
	_search.changed.connect(_on_search_text)
	_search.submitted.connect(func(backwards: bool) -> void: step_match(not backwards))
	_search.done.connect(func() -> void: _commit_list.grab_focus())
	_scope_button = _search.add_button(&"Filter", "Filter options")
	_scope_button.toggle_mode = true
	_scope_button.pressed.connect(_show_scope_menu)
	_scope_menu = PopupMenu.new()
	_scope_menu.add_radio_check_item(tr("Current branch"), 0)
	_scope_menu.add_radio_check_item(tr("All branches"), 1)
	_scope_menu.id_pressed.connect(func(id: int) -> void:
		Actions.run_action(&"history.all_branches" if id == 1 else &"history.current_branch", _scope_button))
	_scope_menu.about_to_popup.connect(_update_scope)
	add_child(_scope_menu)
	_apply_theme()


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_cancel_parent_navigation()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		_update_header()
		for i: int in _match_buttons.size():
			_match_buttons[i].tooltip_text = tr("Previous match (Shift+Enter)") if i == 0 else tr("Next match (Enter)")


func set_session(value: RepoSession) -> void:
	if session == value:
		return
	_cancel_parent_navigation()
	_graph_loading = true
	_selected_oid = ""
	_restore_oid = ""
	_head_pending = false
	_follow_head = false
	if session != null:
		session.graph_changed.disconnect(_on_graph_changed)
		session.graph_loaded.disconnect(_on_graph_loaded)
		session.graph_reset.disconnect(_on_graph_reset)
		session.search_changed.disconnect(_on_search_changed)
		session.head_changed.disconnect(_on_history_state)
		session.status_changed.disconnect(_on_history_state)
		session.refs_changed.disconnect(_on_history_state)
	session = value
	if session != null:
		session.graph_changed.connect(_on_graph_changed)
		session.graph_loaded.connect(_on_graph_loaded)
		session.graph_reset.connect(_on_graph_reset)
		session.search_changed.connect(_on_search_changed)
		session.head_changed.connect(_on_history_state)
		session.status_changed.connect(_on_history_state)
		session.refs_changed.connect(_on_history_state)
		var saved: Dictionary = Core.repo_ui_state(session.repo_path())
		session.set_history_all_branches(int(saved.get("history_all_branches", 0)) == 1)
		if is_node_ready():
			session.search_commits(_search.text())
	_commit_list.session = session
	_details.session = session
	_commits_text = "Loading…" if session != null else ""
	_update_header()


func set_all_branches(all: bool) -> void:
	if session == null:
		return
	Core.set_repo_ui_state(session.repo_path(), "history_all_branches", 1 if all else 0)
	session.set_history_all_branches(all)
	_update_scope()


func can_go_to_current_commit() -> bool:
	return session != null and not String(session.status().get("oid", "")).is_empty()


func go_to_current_commit() -> void:
	if not can_go_to_current_commit():
		return
	_cancel_parent_navigation()
	_restore_oid = ""
	_head_pending = true
	_jump_pending = false
	_select_newest_if_none()
	_commit_list.grab_focus()


func scope_menu() -> PopupMenu:
	return _scope_menu


func scope_button() -> Button:
	return _scope_button


func _show_scope_menu() -> void:
	_update_scope()
	_scope_menu.position = Vector2i(_scope_button.get_screen_position() + Vector2(0.0, _scope_button.size.y))
	_scope_menu.reset_size()
	_scope_menu.popup()


func _on_history_state() -> void:
	_commit_list.reload_matches()
	_details.update_outgoing()
	_update_scope()
	_select_newest_if_none()


func _update_scope() -> void:
	var info: Dictionary = session.history_info() if session != null else {}
	var branch: String = session.current_branch() if session != null else ""
	var head: String = String(session.status().get("oid", "")) if session != null else ""
	var current: String = tr("Current branch: %s") % branch
	if branch.is_empty():
		current = tr("Detached at %s") % head.left(7) if not head.is_empty() else tr("Current branch")
	var all: bool = bool(info.get("all_branches", false))
	_scope_menu.set_item_text(0, tr("Current branch"))
	_scope_menu.set_item_text(1, tr("All branches"))
	_scope_menu.set_item_checked(0, not all)
	_scope_menu.set_item_checked(1, all)
	_scope_menu.set_item_tooltip(0, current)
	_scope_button.set_pressed_no_signal(all)
	_scope_button.disabled = session == null or not session.is_ready()
	_scope_button.tooltip_text = (tr("All branches") if all else current) + "\n" + tr("Filter options")
	_list_header.hide_status()
	_list_header.tooltip_text = ""
	if head.is_empty():
		_list_header.tooltip_text = tr("No commits yet") if session != null and session.is_ready() else tr("Loading…")
	elif branch.is_empty():
		_list_header.tooltip_text = tr("Detached HEAD · no upstream comparison")
	elif not bool(info.get("ready", false)):
		_list_header.tooltip_text = tr("Checking upstream…")
	elif bool(info.get("gone", false)):
		_list_header.tooltip_text = tr("Upstream gone")
	elif String(info.get("upstream", "")).is_empty():
		_list_header.tooltip_text = tr("No upstream · Publish branch")
	elif int(info.get("outgoing", 0)) > 0:
		var upstream: String = String(info["upstream"]).trim_prefix("refs/remotes/").trim_prefix("refs/heads/")
		_list_header.show_status(AppTheme.icon(&"GitPush"), tr("%d outgoing") % int(info["outgoing"]),
				get_theme_color(&"outgoing_color", CommitList.LIST_THEME_TYPE),
				tr("Commits on the current branch that are not in %s. Based on local refs; fetch to refresh.") % upstream)


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


## The commit under the cursor: `{hash, subject, in_head}`, or empty.
func selected_commit() -> Dictionary:
	var row: int = _commit_list.cursor
	var oid: String = _commit_list.hash_at(row)
	if oid.is_empty():
		return {}
	var data: Dictionary = _commit_list.row_data(row)
	return {"hash": oid, "subject": String(data.get("subject", "")), "in_head": bool(data.get("in_head", true))}


func can_go_to_parent() -> bool:
	return session != null and session == _parent_action_session and is_visible_in_tree() \
			and not _parent_action_oid.is_empty() and _parent_source_valid(_parent_action_source, _parent_action_oid)


func go_to_parent() -> void:
	if not can_go_to_parent():
		return
	_pending_parent_oid = _parent_action_oid
	_pending_parent_source = _parent_action_source
	_pending_parent_session = session
	_jump_pending = false
	_try_parent_navigation()


func _on_parent_requested(source: String, oid: String, origin: LinkButton) -> void:
	_parent_action_source = source
	_parent_action_oid = oid
	_parent_action_session = session
	Actions.run_action(&"history.go_to_parent", origin)
	_clear_parent_action()


func _clear_parent_action() -> void:
	_parent_action_oid = ""
	_parent_action_source = ""
	_parent_action_session = null


func _cancel_parent_navigation() -> void:
	_pending_parent_oid = ""
	_pending_parent_source = ""
	_pending_parent_session = null
	_clear_parent_action()


func _parent_source_valid(source: String, oid: String) -> bool:
	if session == null or source.is_empty() or _details.commit_oid() != source \
			or _commit_list.hash_at(_commit_list.cursor) != source:
		return false
	var info: Dictionary = session.commit_info()
	var parents: PackedStringArray = info.get("parents", PackedStringArray())
	return String(info.get("oid", "")) == source and parents.has(oid)


func _parent_rows() -> Dictionary:
	return session.graph_parent_rows(_commit_list.cursor)


func _try_parent_navigation() -> void:
	if _pending_parent_oid.is_empty():
		return
	if session != _pending_parent_session or not is_visible_in_tree() \
			or not _parent_source_valid(_pending_parent_source, _pending_parent_oid):
		_cancel_parent_navigation()
		return
	var row: int = int(_parent_rows().get(_pending_parent_oid, -1))
	if row >= 0 and _commit_list.hash_at(row) == _pending_parent_oid:
		_commit_list.refresh()
		_cancel_parent_navigation()
		_select(row)
		_commit_list.grab_focus()
	elif not _graph_loading:
		var oid: String = _pending_parent_oid
		_cancel_parent_navigation()
		notice.emit(tr("Parent unavailable"), tr("This parent is not available in loaded history.\n%s") % oid)


func _on_commit_selected() -> void:
	_cancel_parent_navigation()
	_selected_oid = _commit_list.hash_at(_commit_list.cursor)
	if not _selected_oid.is_empty():
		_restore_oid = ""
		_head_pending = false
		_follow_head = session != null and _selected_oid == String(session.status().get("oid", ""))
	_details.show_commit(_selected_oid)
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
	_cancel_parent_navigation()
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
	_update_scope()
	var info: Dictionary = session.search_info() if session != null else {}
	if info.is_empty():
		_list_header.set_text(tr(_commits_text))
		return
	var matches: int = int(info["matches"])
	var text: String = ListHeader.count_text(matches, "match", "matches")
	var index: int = session.search_match_index(_commit_list.cursor)
	if not bool(info["done"]):
		text = tr("Searching… %s") % text
	elif matches == 0:
		text = tr("No matches")
	elif index >= 0:
		text = tr("%d of %s") % [index + 1, text]
	_list_header.set_text(tr(_commits_text) if info.is_empty() else text)


func _on_list_key(event: InputEvent) -> void:
	if event.is_action_pressed("ui_right", false, true) and _details.file_list().row_count() > 0:
		_details.focus_files()
		_commit_list.accept_event()
		return
	var key: InputEventKey = event as InputEventKey
	var menu_key: bool = key != null and key.pressed \
			and (key.keycode == KEY_MENU or (key.keycode == KEY_F10 and key.shift_pressed))
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
	_update_scope()


func _on_graph_changed(_start: int, _count: int) -> void:
	_commits_text = tr("Loading… %s") % ListHeader.count_text(session.graph_row_count(), "commit")
	_update_header()
	_select_newest_if_none()
	_try_parent_navigation()


func _on_graph_reset() -> void:
	_cancel_parent_navigation()
	_head_pending = _head_pending or _follow_head
	_restore_oid = _selected_oid if not _head_pending else ""
	_graph_loading = true
	_commit_list.select_only(-1)
	_commits_text = tr("Reloading…")
	_update_header()


func _on_graph_loaded(row_count: int, error: String) -> void:
	_graph_loading = false
	_commits_text = tr(error) if not error.is_empty() else ListHeader.count_text(row_count, "commit")
	_update_header()
	_select_newest_if_none()
	if row_count == 0:
		_details.show_placeholder(tr("No commits yet.") if error.is_empty() else "")
	_try_parent_navigation()
	repo_loaded.emit(row_count, error)


func _select_newest_if_none() -> void:
	if session == null or (_commit_list.cursor >= 0 and not _head_pending):
		return
	if not _restore_oid.is_empty():
		var restored: int = session.graph_find_commit(_restore_oid)
		if restored >= 0:
			_restore_oid = ""
			_select(restored)
			return
		if _graph_loading:
			return
		_restore_oid = ""
	var head: String = String(session.status().get("oid", ""))
	var row: int = session.graph_find_commit(head) if not head.is_empty() else -1
	if row < 0 and _graph_loading:
		return
	_head_pending = false
	if row >= 0:
		_select(row)
	elif _commit_list.row_count() > 0:
		_select(0)

