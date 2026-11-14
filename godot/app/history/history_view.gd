class_name HistoryView
extends HSplitContainer
## History of one worktree: the commit list (with a status line) on the left,
## the selected commit's details and diff on the right. Right moves from the
## list into the details' files, and from there into the diff; Left goes back.
## HEAD is selected initially; reloads follow it or preserve a historical selection.
## Above the list, a search finds commits by subject, author or hash
## (`RepoSession.search_commits`) and highlights them in place: the graph
## stays whole, other rows are dimmed. The field counts the matches
## ("3/41"). When a search finishes, the first match from the selected
## commit down is selected; Enter and Shift+Enter (or F3, Shift+F3 and the
## field's arrows, shown while searching) step through the matches. The
## field's options menu picks the scope, compact rows and the graph; there is no row
## between the field and the list.

signal repo_loaded(row_count: int, error: String)

## Every History view, for `set_compact` across tabs.
const GROUP: StringName = &"history_views"
## How long a commit to reveal may take to show up in a list that is not
## loading before the newest commit is selected instead.
const REVEAL_WAIT: float = 1.0
## The options menu's Compact rows and Show graph items.
const COMPACT_ID: int = 2
const GRAPH_ID: int = 3
## Right-click or the menu key on a commit; `at_position` is in screen coordinates.
signal commit_menu_requested(at_position: Vector2)
## Right-click on a ref label: `{name, short, kind, is_head}`, screen
## position, and the popup the menu opens over (or null).
signal label_menu_requested(label: Dictionary, at_position: Vector2, over: Window)
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

## The error of the last load, shown over an empty list.
var _load_error: String = ""
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
var _refs_popover: RefsPopover = null
## Over the commit list while the history loads or reloads.
var _loading: LoadingIndicator = LoadingIndicator.new()
## Over an empty list when the load failed: its error.
var _empty_label: Label = null
## Over the list of a repository without commits: "No commits yet".
var _empty: EmptyState = null
@onready var _commit_list: CommitList = %CommitList
@onready var _search: FilterField = %SearchField
@onready var _details: CommitDetails = %Details
@onready var _left: VBoxContainer = %Left


func _ready() -> void:
	_details.date_format = _commit_list.date_text
	_empty = EmptyState.create_compact()
	_commit_list.add_child(_empty)
	_empty.show_compact(&"GitCommit", "No commits yet")
	_commit_list.add_child(_loading)
	_empty_label = Label.new()
	_empty_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty_label.theme_type_variation = &"ErrorLabel"
	_empty_label.hide()
	_commit_list.add_child(_empty_label)
	_commit_list.selection_changed.connect(_on_commit_selected)
	_commit_list.gui_input.connect(_on_list_key)
	_commit_list.context_menu_requested.connect(func(row: int, at: Vector2) -> void:
		var label: Dictionary = _commit_list.label_at(row, at)
		if label.is_empty():
			commit_menu_requested.emit(_commit_list.get_screen_position() + at)
		else:
			label_menu_requested.emit(label, _commit_list.get_screen_position() + at, null))
	# Made here, not with the view, so a view freed outside the tree frees it too.
	_refs_popover = RefsPopover.new()
	add_child(_refs_popover)
	_commit_list.refs_requested.connect(func(_row: int, at: Vector2, labels: Array) -> void:
		_refs_popover.open_at(labels, _commit_list.get_screen_transform() * at))
	_refs_popover.menu_requested.connect(label_menu_requested.emit)
	_details.file_list().gui_input.connect(_on_files_key)
	_details.parent_requested.connect(_on_parent_requested)
	_details.label_menu_requested.connect(label_menu_requested.emit)
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
	_scope_menu.add_separator()
	_scope_menu.add_check_item(tr("Compact rows"), COMPACT_ID)
	_scope_menu.add_check_item(tr("Show graph"), GRAPH_ID)
	_scope_menu.id_pressed.connect(func(id: int) -> void:
		if id == COMPACT_ID or id == GRAPH_ID:
			Actions.run_action(&"history.toggle_compact" if id == COMPACT_ID else &"history.toggle_graph", _scope_button)
			return
		Actions.run_action(&"history.all_branches" if id == 1 else &"history.current_branch", _scope_button))
	_scope_menu.about_to_popup.connect(_update_scope)
	add_child(_scope_menu)
	add_to_group(GROUP)
	set_compact(Core.history_compact())
	set_show_graph(Core.history_graph())
	_apply_theme()


## Two-line rows (with the author line) or compact one-line rows.
func set_compact(value: bool) -> void:
	_commit_list.compact = value
	_update_compact_item()


## Draws the commit graph beside the rows or leaves it out.
func set_show_graph(value: bool) -> void:
	_commit_list.show_graph = value
	_update_compact_item()


## Checks Compact rows and Show graph in the options menu and shows their
## shortcuts.
func _update_compact_item() -> void:
	if _scope_menu == null:
		return
	show_check_action(_scope_menu, COMPACT_ID, "Compact rows", &"history.toggle_compact", _commit_list.compact)
	show_check_action(_scope_menu, GRAPH_ID, "Show graph", &"history.toggle_graph", _commit_list.show_graph)


## Sets check item `id` of `menu` to `label` (translated here), `checked`,
## with `action`'s shortcut shown beside it.
static func show_check_action(menu: PopupMenu, id: int, label: String, action: StringName, checked: bool) -> void:
	var index: int = menu.get_item_index(id)
	menu.set_item_text(index, TranslationServer.translate(label))
	menu.set_item_checked(index, checked)
	var shortcuts: PackedStringArray = Actions.shortcuts(action)
	var event: InputEventKey = Shortcuts.parse(shortcuts[0]) if not shortcuts.is_empty() else null
	var shortcut: Shortcut = null
	if event != null:
		shortcut = Shortcut.new()
		shortcut.events = [event]
	menu.set_item_shortcut(index, shortcut)
	# Shown only: the registry handles the keys.
	menu.set_item_shortcut_disabled(index, true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _loading.get_parent() == null:
		_loading.free()  # Never added: freed without ever being ready.
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()
	elif what == NOTIFICATION_VISIBILITY_CHANGED:
		if not is_visible_in_tree():
			_cancel_parent_navigation()
		# A hidden history does not reload; shown again, it catches up.
		if session != null:
			session.set_history_visible(is_visible_in_tree())
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		_update_header()
		_update_empty()
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
		session.set_history_visible(false)
		session.graph_reloading_changed.disconnect(_update_loading)
		session.graph_changed.disconnect(_on_graph_changed)
		session.graph_loaded.disconnect(_on_graph_loaded)
		session.graph_reset.disconnect(_on_graph_reset)
		session.search_changed.disconnect(_on_search_changed)
		session.head_changed.disconnect(_on_history_state)
		session.status_changed.disconnect(_on_history_state)
		session.refs_changed.disconnect(_on_history_state)
	session = value
	if session != null:
		session.set_history_visible(is_visible_in_tree())
		session.graph_reloading_changed.connect(_update_loading)
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
	_load_error = ""
	_update_header()
	_update_loading()


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


## Selects and reveals commit `oid`. A commit the list does not have yet is
## selected once it arrives (a reload behind the rows, a load still running);
## unless the current branch has it (`in_head`), a history of the current
## branch then lists all branches, where the commit may be.
func reveal_commit(oid: String, in_head: bool) -> void:
	if session == null or oid.is_empty():
		return
	_cancel_parent_navigation()
	_commit_list.grab_focus()
	var row: int = session.graph_find_commit(oid)
	if row >= 0:
		_select(row)
		return
	_commit_list.select_only(-1)
	# What a reset keeps selected, and what is selected once it is listed.
	_selected_oid = oid
	_restore_oid = oid
	_head_pending = false
	_follow_head = false
	if not in_head and not bool(session.history_info().get("all_branches", false)):
		set_all_branches(true)
		return
	# Nothing may be on its way: fall back to the newest commit then.
	get_tree().create_timer(REVEAL_WAIT).timeout.connect(func() -> void:
		if _restore_oid == oid and _commit_list.cursor < 0 and not _graph_loading \
				and session != null and not session.graph_reloading():
			_select_newest_if_none())


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
	_update_compact_item()


## The popover of a row's refs (its "+N" chip).
func refs_popover() -> RefsPopover:
	return _refs_popover


func commit_list() -> CommitList:
	return _commit_list


## The left column (its width is saved per repository).
func left_pane() -> Control:
	return _left


func details() -> CommitDetails:
	return _details


## What the search field counts: "Searching…", "3/41", "41" (no match
## selected), "No matches", or "" without a search.
func status_text() -> String:
	return _search.count_text()


## The load's error or "No commits yet" shown over the empty list, or "".
func empty_text() -> String:
	if _empty != null and _empty.visible:
		return _empty.title()
	return _empty_label.text if _empty_label != null and _empty_label.visible else ""


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


## The commit under the cursor: `{hash, subject, in_head}`, or empty.
func selected_commit() -> Dictionary:
	var row: int = _commit_list.cursor
	var oid: String = _commit_list.hash_at(row)
	if oid.is_empty():
		return {}
	var data: Dictionary = _commit_list.row_data(row)
	return {"hash": oid, "subject": String(data.get("subject", "")), "in_head": bool(data.get("in_head", true))}


## The two selected commits, older first (Compare's left side), when exactly
## two rows are selected (Ctrl+click); else empty.
func selected_pair() -> PackedStringArray:
	var rows: PackedInt32Array = _commit_list.selected_rows()
	if rows.size() != 2:
		return PackedStringArray()
	var newer: String = _commit_list.hash_at(mini(rows[0], rows[1]))
	var older: String = _commit_list.hash_at(maxi(rows[0], rows[1]))
	if newer.is_empty() or older.is_empty():
		return PackedStringArray()
	return PackedStringArray([older, newer])


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
	_details.show_pair_action(selected_pair().size() == 2)
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


## The search field's count: "Searching…" until the search finishes, then
## "3/41" (the selected commit is the third match), "41" when the selection
## is not a match, or "No matches"; nothing without a search.
func _update_header() -> void:
	_update_scope()
	var info: Dictionary = session.search_info() if session != null else {}
	if info.is_empty():
		_search.set_count("")
		return
	var matches: int = int(info["matches"])
	var index: int = session.search_match_index(_commit_list.cursor)
	if not bool(info["done"]):
		_search.set_count(tr("Searching…"))
	elif matches == 0:
		_search.set_count(tr("No matches"), true)
	elif index >= 0:
		_search.set_count("%d/%s" % [index + 1, ListHeader.number_text(matches)])
	else:
		_search.set_count(ListHeader.number_text(matches))


## Over the empty list once it has loaded: the load's error, or "No commits
## yet". Nothing while it loads.
func _update_empty() -> void:
	if _empty_label == null:
		return
	var nothing: bool = session != null and not _graph_loading and session.graph_row_count() == 0
	_empty_label.visible = nothing and not _load_error.is_empty()
	_empty_label.text = tr(_load_error)
	_empty.visible = nothing and _load_error.is_empty()


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
	_update_header()
	_update_loading()
	_select_newest_if_none()
	_try_parent_navigation()


func _on_graph_reset() -> void:
	_cancel_parent_navigation()
	_head_pending = _head_pending or _follow_head
	_restore_oid = _selected_oid if not _head_pending else ""
	_graph_loading = true
	_commit_list.select_only(-1)
	_update_header()
	_update_loading()


func _on_graph_loaded(row_count: int, error: String) -> void:
	_graph_loading = false
	_load_error = error
	_update_header()
	_update_loading()
	_select_newest_if_none()
	if row_count == 0:
		_details.show_placeholder(true)
	_try_parent_navigation()
	repo_loaded.emit(row_count, error)


## The list's loading indicator: blocking until the first rows arrive, over
## the rows while more stream in or a reload runs behind them.
func _update_loading() -> void:
	if session == null:
		_loading.hide_loading()
		_update_empty()
		return
	var rows: int = session.graph_row_count()
	if _graph_loading and rows == 0:
		_loading.show_loading(true, tr("Loading history…"))
	elif _graph_loading or session.graph_reloading():
		_loading.show_loading(false, tr("Updating…"))
	else:
		_loading.hide_loading()
	_update_empty()


## The commit list's loading indicator (smoke tests and screenshots).
func loading_indicator() -> LoadingIndicator:
	return _loading


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

