class_name ChangesView
extends HSplitContainer
## Working-copy changes of one worktree (PLAN §4 Changes view): one list of
## changed files with commit checkboxes, the commit box under it, and the diff
## of the highlighted file with line checkboxes. Above the list, a filter
## (text and options, like GitHub Desktop's) narrows the files shown; the
## check-all box then covers the files shown only. The checkboxes are the commit
## selection kept in core (PLAN §3.10). With no changes, suggested actions
## take the diff's place. The Shelves view reuses the preview pane with a
## dedicated shelf browser and details, without commit controls.
## Keyboard: arrows move, Space or Enter toggle the checkboxes of the
## highlighted files or diff lines (a hunk header takes its hunk), Right and
## Left move between the list and the diff, Delete discards, Ctrl+Z undoes the
## last discard; see the `changes.*` actions for the rest.

const THEME_TYPE: StringName = &"ChangesView"
signal shelf_selection_changed()
## The filter's options (`RepoSession.set_change_filter`), like GitHub Desktop's.
const FILTER_OPTIONS: Array[Array] = [
	["included", "Included in commit"],
	["excluded", "Excluded from commit"],
	["", ""],
	["new", "New files"],
	["modified", "Modified files"],
	["deleted", "Deleted files"],
]

var session: RepoSession = null:
	set = set_session
## Shows job progress and results (discard with Undo, commit); may be null
## in tests.
var feedback: Feedback = null:
	set(value):
		feedback = value
		if is_node_ready():
			_commit_box.feedback = value
## Runs the shelf flows (forms, confirmations); set by the worktree view.
var ops: RepoOps = null

var _confirm: ConfirmationDialog = ConfirmationDialog.new()
## Runs when the user confirms the discard dialog.
var _pending_discard: Callable = Callable()
var _menu: PopupMenu = PopupMenu.new()
var _menu_actions: Array[StringName] = []
## The diff shows a shelved file (not a change): keep it over status reloads.
var _showing_shelf: bool = false
var _shelves_mode: bool = false
var _shelf_oid: String = ""
var _shelf_path: String = ""
var _editing_shelf: Dictionary = {}

@onready var _files: VBoxContainer = %Files
@onready var _switch_slot: Container = %SwitchSlot
@onready var _filter_bar: Control = %FilterBar
@onready var _filter: FilterField = %FilterField
@onready var _list_header: ListHeader = %ListHeader
@onready var _no_match: Control = %NoMatch
@onready var _list: ChangeList = %List
@onready var _commit_box: CommitBox = %CommitBox
@onready var _diff_panel: DiffPanel = %DiffPanel
@onready var _diff_view: DiffView = _diff_panel.view()
@onready var _empty: EmptyState = %Empty
@onready var _shelves: ShelfList = %Shelves
@onready var _offer_bar: Control = %OfferBar
@onready var _offer_label: Label = %OfferLabel
@onready var _offer_button: Button = %OfferButton
@onready var _commit_panel: Control = %CommitPanel
@onready var _shelf_details: Control = %ShelfDetails
@onready var _shelf_title: Button = %ShelfTitle
@onready var _shelf_name_edit: LineEdit = %ShelfNameEdit
@onready var _shelf_branch: Label = %ShelfBranch
@onready var _shelf_date: Label = %ShelfDate
@onready var _shelf_hash: Label = %ShelfHash
@onready var _shelf_auto: Label = %ShelfAuto
@onready var _shelf_files: ShelfFileList = %ShelfFiles
@onready var _shelf_files_box: Control = %ShelfFilesBox
@onready var _shelf_files_header: ListHeader = %ShelfFilesHeader
@onready var _shelf_files_split: HSplitContainer = %ShelfFilesSplit


func _ready() -> void:
	_list.pick_toggled.connect(func(paths: PackedStringArray, include: bool) -> void:
		session.pick_files(paths, include))
	_list.current_changed.connect(_on_current_changed)
	_list.context_menu_requested.connect(_show_menu.bind(_list))
	_list.gui_input.connect(_on_list_key)
	_list_header.check_toggled.connect(pick_all)
	_list_header.context_menu_requested.connect(_show_header_menu)
	_filter.set_options(FILTER_OPTIONS)
	_filter.changed.connect(_apply_filter)
	_filter.done.connect(focus_files)
	_commit_box.feedback = feedback
	_diff_panel.load_full_requested.connect(_load_full_diff)
	_diff_panel.expand_requested.connect(func(gap: int, how: String) -> void:
		session.expand_diff("changes", gap, how))
	_diff_panel.whole_file_requested.connect(func(whole: bool) -> void:
		session.show_whole_diff("changes", whole))
	_diff_panel.set_source(func(start: int, count: int) -> Array:
		return session.diff_lines(start, count) if session != null else [])
	_diff_panel.set_split_source(func(start: int, count: int) -> Array:
		return session.diff_split_rows("changes", start, count) if session != null else [])
	_diff_view.row_activated.connect(func(_row: int) -> void: toggle_diff_lines())
	_diff_view.pick_clicked.connect(func(lines: PackedInt32Array, include: bool) -> void:
		session.pick_lines(lines, include))
	_diff_view.gui_input.connect(_on_diff_key)
	_diff_view.context_menu_requested.connect(_show_menu.bind(_diff_view))
	_diff_panel.clear("Select a file to see its changes.")
	_confirm.confirmed.connect(func() -> void:
		if _pending_discard.is_valid():
			_pending_discard.call()
		_pending_discard = Callable())
	add_child(_confirm)
	add_child(_menu)
	_menu.id_pressed.connect(func(id: int) -> void: Actions.run_action(_menu_actions[id]))
	_shelves.menu_requested.connect(_show_shelf_menu)
	_shelves.shelf_selected.connect(_on_shelf_selected)
	_shelf_files.current_changed.connect(func(path: String) -> void:
		if not path.is_empty():
			_show_shelf_file(_shelf_oid, path))
	_shelf_files.gui_input.connect(_on_shelf_files_key)
	_shelf_files.context_menu_requested.connect(_show_shelf_file_menu)
	_shelves.names().gui_input.connect(_on_shelf_names_key)
	_shelf_title.pressed.connect(func() -> void: Actions.run_action(&"shelf.rename", _shelf_title))
	_shelf_name_edit.text_submitted.connect(func(_text: String) -> void: _finish_shelf_name(true))
	_shelf_name_edit.focus_exited.connect(func() -> void: _finish_shelf_name(true))
	_shelf_name_edit.gui_input.connect(func(event: InputEvent) -> void:
		if event.is_action_pressed("ui_cancel"):
			_shelf_name_edit.accept_event()
			_finish_shelf_name(false))
	for entry: Array in [[%RestoreShelf, &"shelf.restore"], [%DiscardShelf, &"shelf.discard"]]:
		var button: Button = entry[0]
		var id: StringName = entry[1]
		button.pressed.connect(func() -> void: Actions.run_action(id, button))
	_apply_shelf_theme()
	_offer_button.icon = Actions.icon(&"shelf.restore_left")
	_offer_button.pressed.connect(func() -> void: Actions.run_action(&"shelf.restore_left", _offer_button))


func set_session(value: RepoSession) -> void:
	if session != null:
		session.status_changed.disconnect(reload)
		session.diff_changed.disconnect(_on_diff_changed)
		session.selection_changed.disconnect(_on_selection_changed)
		session.stashes_changed.disconnect(reload_shelves)
		session.shelf_files_loaded.disconnect(_on_shelf_files_loaded)
		session.shelf_replaced.disconnect(_on_shelf_replaced)
	session = value
	if session != null:
		session.status_changed.connect(reload)
		session.diff_changed.connect(_on_diff_changed)
		session.selection_changed.connect(_on_selection_changed)
		session.stashes_changed.connect(reload_shelves)
		session.shelf_files_loaded.connect(_on_shelf_files_loaded)
		session.shelf_replaced.connect(_on_shelf_replaced)
	_list.session = session
	_commit_box.session = session
	if session != null and is_node_ready():
		session.set_change_filter(_filter.text(), _filter.options())
	reload()
	reload_shelves()


func list() -> ChangeList:
	return _list


## Where the Changes/History switch goes while this view shows.
func switch_slot() -> Container:
	return _switch_slot


## The left column (its width is saved per repository).
func left_pane() -> Control:
	return _files


func commit_box() -> CommitBox:
	return _commit_box


func diff_view() -> DiffView:
	return _diff_view


func diff_panel() -> DiffPanel:
	return _diff_panel


func empty_state() -> EmptyState:
	return _empty


func check_all() -> PickBox:
	return _list_header.check()


func list_header() -> ListHeader:
	return _list_header


func filter_field() -> FilterField:
	return _filter


## Focuses the filter's text box.
func focus_filter() -> void:
	if _shelves_mode:
		_shelves.focus_filter()
		return
	_filter.focus_text()


func shelf_list() -> ShelfList:
	return _shelves


func shelf_files() -> ShelfFileList:
	return _shelf_files


func shelf_files_split() -> HSplitContainer:
	return _shelf_files_split


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_shelf_theme()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		reload()
		if _shelves_mode:
			_on_shelf_selected(selected_shelf())
		else:
			_on_diff_changed()


func _apply_shelf_theme() -> void:
	_files.custom_minimum_size.x = float(get_theme_constant(&"min_left_width", &"Panes"))
	for entry: Array in [[%RestoreShelf, &"shelf.restore"], [%DiscardShelf, &"shelf.discard"]]:
		(entry[0] as Button).icon = Actions.icon(entry[1])
	_shelf_files_box.custom_minimum_size.x = float(get_theme_constant(&"min_files_width", &"CommitDetails"))
	var tint: Color = get_theme_color(&"icon_tint", &"CommitDetails")
	var icon_size: float = float(get_theme_constant(&"icon_size", &"CommitDetails"))
	for entry: Array in [[%ShelfBranchIcon, &"GitBranch"], [%ShelfDateIcon, &"Clock"], [%ShelfHashIcon, &"GitCommit"]]:
		var icon: TextureRect = entry[0]
		icon.texture = AppTheme.icon(entry[1])
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.custom_minimum_size = Vector2(icon_size, icon_size)
		icon.self_modulate = tint


func offer_bar() -> Control:
	return _offer_bar


func offer_label_text() -> String:
	return _offer_label.text


# --- Shelves ------------------------------------------------------------------

## Changes and Shelves share the core's changes diff slot. Switching reloads
## the appropriate selection, so a shelf never becomes a commit candidate.
func show_shelves_view(enabled: bool) -> void:
	if _shelves_mode == enabled:
		return
	_finish_shelf_name(false)
	_shelves_mode = enabled
	_showing_shelf = enabled
	_list.visible = not enabled
	_commit_panel.visible = not enabled
	_shelves.visible = enabled
	_shelf_details.visible = enabled
	_shelf_files_box.visible = enabled
	if not enabled:
		_shelves.branch_picker().hide()
	_update_header()
	_update_offer()
	_update_empty()
	_clear_diff()
	if enabled:
		_shelf_oid = ""
		_shelf_path = ""
		_on_shelf_selected(selected_shelf())
	else:
		_shelf_oid = ""
		_shelf_path = ""
		_on_current_changed(current_path())


func _on_shelf_selected(shelf: Dictionary) -> void:
	if not _shelves_mode:
		return
	var oid: String = String(shelf.get("oid", ""))
	var changed: bool = oid != _shelf_oid
	if changed:
		_finish_shelf_name(false)
	_shelf_oid = oid
	_shelf_details.visible = not shelf.is_empty()
	_update_empty()
	if changed or shelf.is_empty():
		_shelf_path = ""
		_clear_diff()
		_shelf_files.show_files([])
		_shelf_files_header.set_text("")
	shelf_selection_changed.emit()
	if shelf.is_empty():
		return
	_shelf_title.text = String(shelf["name"])
	_shelf_title.tooltip_text = tr("%s\nClick to rename") % shelf["name"]
	(%RestoreShelf as Button).tooltip_text = tr("Restore into %s; remove the shelf after success") % session.current_branch()
	(%DiscardShelf as Button).tooltip_text = Actions.tooltip(&"shelf.discard")
	var branch: String = String(shelf["branch"])
	_shelf_branch.text = branch if not branch.is_empty() else tr("No branch")
	var offset: int = int(Time.get_time_zone_from_system()["bias"]) * 60
	_shelf_date.text = Time.get_datetime_string_from_unix_time(int(shelf["time"]) + offset, true).left(16)
	_shelf_hash.text = oid.left(10)
	_shelf_hash.tooltip_text = oid
	_shelf_auto.visible = bool(shelf["auto"])
	if changed:
		_shelf_files_header.set_text(tr("Loading files…"))
		session.load_shelf_files(oid)


func edit_shelf_name() -> void:
	var shelf: Dictionary = selected_shelf()
	if shelf.is_empty():
		return
	_editing_shelf = shelf.duplicate()
	_shelf_name_edit.text = String(shelf["name"])
	_shelf_title.hide()
	_shelf_name_edit.show()
	_shelf_name_edit.grab_focus()
	_shelf_name_edit.select_all()


func _finish_shelf_name(save: bool) -> void:
	if _editing_shelf.is_empty():
		return
	var shelf: Dictionary = _editing_shelf
	var name: String = _shelf_name_edit.text.strip_edges()
	_editing_shelf = {}
	_shelf_title.show()
	_shelf_name_edit.hide()
	if save and not name.is_empty() and ops != null:
		ops.rename_shelf(shelf, name)


## Re-reads the shelves (after every stash list change).
func reload_shelves() -> void:
	if not is_node_ready() or session == null:
		return
	_shelves.show_shelves(session.shelves(), session.current_branch())
	_update_offer()


## The selected shelf in the dedicated browser, or {}.
func selected_shelf() -> Dictionary:
	return _shelves.selected_shelf()


func selected_shelf_file() -> String:
	return _shelf_files.path_at(_shelf_files.cursor) if _shelves_mode else ""


func _on_shelf_replaced(old_oid: String, new_oid: String) -> void:
	_shelves.replace_shelf(old_oid, new_oid)


## Shelves the highlighted files after asking for a name.
func shelve_selected() -> void:
	if ops == null:
		return
	var paths: PackedStringArray = PackedStringArray()
	for index: int in _list.highlighted_rows():
		var row: Dictionary = _list.row(index)
		if not row.is_empty() and not bool(row.get("conflicted", false)):
			paths.append(String(row["path"]))
	ops.shelve(paths)


func can_shelve() -> bool:
	for index: int in _list.highlighted_rows():
		if not bool(_list.row(index).get("conflicted", true)):
			return true
	return false


## Header actions cover the currently listed files, not the highlighted rows
## or commit checkboxes. Capture paths before opening a dialog.
func shelve_listed() -> void:
	if ops != null and session != null:
		ops.shelve(session.change_paths(0, session.shown_change_count()))


func discard_listed() -> void:
	if session != null:
		_discard_paths(session.change_paths(0, session.shown_change_count()))


func _show_header_menu(at: Vector2) -> void:
	_menu.clear()
	_menu_actions.assign([&"changes.shelve_listed", &"changes.discard_listed"])
	for index: int in _menu_actions.size():
		var id: StringName = _menu_actions[index]
		_menu.add_icon_item(Actions.icon(id), Actions.get_action(id).label, index)
		_menu.set_item_disabled(index, not Actions.is_enabled(id))
		_menu.set_item_tooltip(index, Actions.tooltip(id))
	_menu.position = Vector2i(at)
	_menu.reset_size()
	_menu.popup()


func context_menu() -> PopupMenu:
	return _menu


## The newest shelf left on the current branch by a switch, or {}.
func left_shelf() -> Dictionary:
	for shelf: Dictionary in _shelves.own_shelves():
		if bool(shelf["auto"]) and bool(shelf["made_here"]):
			return shelf
	return {}


## "3 changes were left on main · Restore" while such a shelf exists.
func _update_offer() -> void:
	var shelf: Dictionary = left_shelf()
	_offer_bar.visible = not _shelves_mode and not shelf.is_empty()
	if shelf.is_empty():
		return
	var oid: String = String(shelf["oid"])
	var files: Array[Dictionary] = session.shelf_files(oid)
	var branch: String = session.current_branch()
	if files.is_empty():
		session.load_shelf_files(oid)
		_offer_label.text = tr("Changes were left on %s") % branch
	else:
		_offer_label.text = tr("1 change was left on %s") % branch if files.size() == 1 \
				else tr("%d changes were left on %s") % [files.size(), branch]
	_offer_button.tooltip_text = Actions.tooltip(&"shelf.restore_left")


func _on_shelf_files_loaded(oid: String) -> void:
	if _shelves_mode and oid == _shelf_oid:
		var files: Array[Dictionary] = session.shelf_files(oid)
		_shelf_files_header.set_text(ListHeader.count_text(files.size(), "changed file"))
		_shelf_files.show_files(files, _shelf_path)
	if String(left_shelf().get("oid", "")) == oid:
		_update_offer()


func _show_shelf_file(oid: String, path: String) -> void:
	if not _shelves_mode or (_shelf_oid == oid and _shelf_path == path):
		return
	_shelf_oid = oid
	_shelf_path = path
	_showing_shelf = true
	session.select_shelf_file(oid, path, false)


func _show_shelf_menu(_shelf: Dictionary, at: Vector2) -> void:
	_menu.clear()
	_menu_actions.clear()
	for id: StringName in [&"shelf.restore", &"shelf.rename", &"shelf.discard"]:
		if Actions.is_enabled(id):
			_menu.add_icon_item(Actions.icon(id), Actions.get_action(id).label, _menu_actions.size())
			_menu_actions.append(id)
	if _menu.item_count == 0:
		return
	_menu.position = Vector2i(at)
	_menu.reset_size()
	_menu.popup()


func _show_shelf_file_menu(row: int, at: Vector2) -> void:
	var path: String = _shelf_files.path_at(row)
	if path.is_empty():
		return
	_shelf_files.choose_path(path)
	_menu.clear()
	_menu_actions.clear()
	for id: StringName in [&"shelf.restore_file", &"shelf.discard_file"]:
		_menu.add_icon_item(Actions.icon(id), Actions.get_action(id).label, _menu_actions.size())
		_menu.set_item_disabled(_menu.item_count - 1, not Actions.is_enabled(id))
		_menu_actions.append(id)
	_menu.position = Vector2i(_shelf_files.get_screen_position() + at)
	_menu.reset_size()
	_menu.popup()


## Re-reads the list from the session (after every status change).
func reload() -> void:
	if not is_node_ready():
		return
	var had_focus: bool = _list.has_focus()
	_list.reload()
	# A last-shelf restore can remove the shelf before the status refresh
	# brings files back. Select the first arriving file without stealing focus.
	if not _shelves_mode:
		_list.ensure_cursor()
	_update_header()
	_update_empty()
	if had_focus and _list.row_count() == 0:
		focus_files()
	if _list.cursor < 0 and not _showing_shelf:
		_clear_diff()
	# The branch may have changed, and with it the shelves that are its own.
	reload_shelves()


## Focuses the list (cursor on its first row if none), the filter when it
## hides every file, or the summary when there is nothing to list.
func focus_files() -> void:
	if _shelves_mode:
		_shelves.focus_list()
		return
	if _list.row_count() > 0:
		_list.grab_focus()
		_list.ensure_cursor()
	elif has_changes():
		_filter.focus_text()
	else:
		_commit_box.focus_summary()


func focus_message() -> void:
	_commit_box.focus_summary()


func diff_view_focused() -> bool:
	return _diff_view.has_focus()


## Toggles the focused checkboxes: the diff's highlighted lines when it has
## focus, else the highlighted files.
func toggle_selected() -> void:
	if _diff_view.has_focus():
		toggle_diff_lines()
	else:
		_list.toggle_selection()


## Picks the highlighted diff lines, or leaves them out when all are picked.
## Returns whether anything changed.
func toggle_diff_lines() -> bool:
	if session == null or not session.can_pick_lines():
		return false
	var lines: PackedInt32Array = _diff_view.selected_or_cursor()
	if lines.is_empty():
		return false
	return session.pick_lines(lines, not _diff_view.selection_fully_picked())


func pick_all(include: bool) -> void:
	if session != null:
		session.pick_all(include)


## The highlighted file's path (worktree-relative), or "".
func current_path() -> String:
	return _list.path_at(_list.cursor)


func open_file() -> void:
	var path: String = current_path()
	if not path.is_empty():
		OS.shell_open(_absolute(path))


func show_file() -> void:
	var path: String = current_path()
	if not path.is_empty():
		OS.shell_show_in_file_manager(_absolute(path))


func copy_path() -> void:
	var path: String = current_path()
	if not path.is_empty():
		DisplayServer.clipboard_set(_absolute(path))


func _absolute(path: String) -> String:
	return session.toplevel().path_join(path)


## Discards the focused selection after a confirmation: diff lines, or the
## highlighted files (back to the last commit; `undo_discard` brings them
## back, untracked files included).
func discard_selection() -> void:
	if _diff_view.has_focus():
		_discard_lines()
		return
	var paths: PackedStringArray = _list.paths(_list.highlighted_rows())
	_discard_paths(paths)


func _discard_paths(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	_ask(tr("Discard the changes in %s? They go back to the last commit. You can undo this with %s.") % [
		_describe(paths), Actions.shortcut_label(&"changes.undo_discard")], func() -> void:
		var job: int = session.discard_paths(paths)
		if feedback != null:
			feedback.track(session, job, "Discarding", tr("Discarded the changes in %s") % _describe(paths),
					null, Callable(), undo_discard))


func can_undo_discard() -> bool:
	return session != null and session.can_undo_discard()


func undo_discard() -> void:
	if can_undo_discard():
		session.undo_discard()


## The discard confirmation, for tests.
func confirm_dialog() -> ConfirmationDialog:
	return _confirm


func commit() -> bool:
	return _commit_box.commit()


func toggle_amend() -> void:
	_commit_box.set_amend(not _commit_box.is_amend())


func has_changes() -> bool:
	return session != null and session.change_count() > 0


func _discard_lines() -> void:
	if not session.can_apply_lines("discard"):
		return
	var rows: PackedInt32Array = _diff_view.selected_or_cursor()
	if rows.is_empty():
		return
	var path: String = String(session.diff_info().get("path", ""))
	var what: String = tr("the selected lines") if rows.size() > 1 else tr("the selected line")
	_ask(tr("Discard %s in %s? You can undo this with %s.") % [
		what, path.get_file(), Actions.shortcut_label(&"changes.undo_discard")],
		func() -> void: session.apply_lines("discard", rows))


func _ask(text: String, on_confirm: Callable) -> void:
	_confirm.title = tr("Discard changes")
	_confirm.dialog_text = text
	_confirm.ok_button_text = tr("Discard")
	_pending_discard = on_confirm
	_confirm.popup_centered()
	_confirm.get_ok_button().grab_focus()


static func _describe(paths: PackedStringArray) -> String:
	return paths[0].get_file() if paths.size() == 1 else TranslationServer.translate("%d files") % paths.size()


## "N changed files" ("2 of N" while filtered) and the check-all box, under
## the filter; hidden without changes (the empty state beside the list says so).
func _update_header() -> void:
	var count: int = session.change_count() if session != null else 0
	var shown: int = _list.row_count()
	var filtered: bool = _filter.is_active()
	_filter_bar.visible = count > 0 and not _shelves_mode
	_list_header.visible = count > 0 and not _shelves_mode
	var text: String = ListHeader.count_text(count, "changed file")
	_list_header.set_text(tr("%d of %s") % [shown, text] if filtered else text)
	_no_match.visible = count > 0 and shown == 0
	var state: String = session.selection_state() if session != null else "none"
	var what: String = tr("every shown file") if filtered else tr("every file")
	_list_header.show_check(state, (tr("Leave out ") if state == "all" else tr("Include ")) + what)


## Whether including or leaving out a file can change what the filter shows.
func _filter_uses_picks() -> bool:
	var ids: PackedStringArray = _filter.options()
	return ("included" in ids) != ("excluded" in ids)


func _apply_filter() -> void:
	if session == null:
		return
	session.set_change_filter(_filter.text(), _filter.options())
	_list.reload()
	_update_header()
	if _list.cursor < 0 and not _showing_shelf:
		_clear_diff()


## With no changes, suggested actions replace the diff (PLAN §4 empty state).
func _update_empty() -> void:
	if _shelves_mode:
		_empty.hide()
		var has_shelf: bool = not _shelf_oid.is_empty()
		_shelf_details.visible = has_shelf
		_shelf_files_split.visible = has_shelf
		_diff_panel.visible = has_shelf
		return
	var empty: bool = session != null and session.is_ready() and session.change_count() == 0
	_empty.visible = empty
	_diff_panel.visible = not empty
	_shelf_files_split.visible = not empty
	if not empty:
		return
	var badge: Dictionary = session.badge()
	var ahead: int = int(badge.get("ahead", 0))
	var behind: int = int(badge.get("behind", 0))
	var actions: Array[Dictionary] = []
	if ahead > 0 and behind > 0:
		actions.append({"id": &"sync.sync", "label": tr("Sync ↓%d ↑%d") % [behind, ahead], "icon": &"GitFetch"})
	elif behind > 0:
		actions.append({"id": &"sync.sync", "label": tr("Pull ↓%d") % behind, "icon": &"GitPull"})
	elif ahead > 0:
		actions.append({"id": &"sync.sync", "label": tr("Push ↑%d") % ahead, "icon": &"GitPush"})
	actions.append({"id": &"repo.open_in_editor", "label": "Open in editor", "icon": &"ExternalLink"})
	actions.append({"id": &"repo.open_terminal", "label": "Open terminal", "icon": &"Terminal"})
	actions.append({"id": &"task.new", "label": "New worktree", "icon": &"GitWorktree"})
	_empty.show_state("No local changes", "", actions)


func _on_selection_changed() -> void:
	# With "Included" or "Excluded" on, a toggled file may leave the list.
	if _filter_uses_picks():
		_list.reload()
	else:
		_list.reload_picks()
	_diff_view.invalidate()
	_update_header()
	_commit_box.update_state()


## Context menu for the list or the diff: the actions that apply right now.
func _show_menu(_row: int, at_position: Vector2, source: Control) -> void:
	_menu.clear()
	_menu_actions.clear()
	var ids: Array[StringName] = [&"changes.toggle_selected", &"changes.discard"]
	if source == _diff_view:
		ids = [&"diff.copy", &"diff.select_all", &"", &"changes.toggle_selected", &"changes.discard"]
	if source == _list:
		ids.append_array([&"changes.shelve", &"", &"changes.open_file", &"changes.show_file", &"changes.copy_path"])
	ids.append_array([&"", &"changes.undo_discard"])
	for id: StringName in ids:
		if id == &"":
			if _menu.item_count > 0 and not _menu.is_item_separator(_menu.item_count - 1):
				_menu.add_separator()
				_menu_actions.append(&"")
			continue
		if not Actions.is_enabled(id):
			continue
		var action: ActionRegistry.Action = Actions.get_action(id)
		_menu.add_icon_item(Actions.icon(id), action.label, _menu_actions.size())
		_menu_actions.append(id)
	if _menu.item_count > 0 and _menu.is_item_separator(_menu.item_count - 1):
		_menu.remove_item(_menu.item_count - 1)
		_menu_actions.pop_back()
	if _menu.item_count == 0:
		return
	_menu.position = Vector2i(source.get_screen_position() + at_position)
	_menu.reset_size()
	_menu.popup()


## The context menu's labels, for tests.
func menu_labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i: int in _menu.item_count:
		if not _menu.is_item_separator(i):
			out.append(_menu.get_item_text(i))
	return out


func _on_current_changed(path: String) -> void:
	if _shelves_mode:
		return
	if path.is_empty():
		if not _showing_shelf:
			_clear_diff()
		return
	_showing_shelf = false
	session.select_change(path, false)
	_on_diff_changed()


## Right in the list moves into the diff.
func _on_list_key(event: InputEvent) -> void:
	if event.is_action_pressed("ui_right", false, true) and _diff_view.row_count() > 0:
		_diff_view.grab_focus()
		if _diff_view.cursor < 0:
			_diff_view.select_only(0)
		_list.accept_event()


## Left in the diff (when it is not scrolled sideways) goes back to the list.
func _on_diff_key(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", false, true) and _diff_view.h_scroll() <= 0.0:
		if _shelves_mode:
			_shelf_files.grab_focus()
		else:
			focus_files()
		_diff_view.accept_event()


func _on_shelf_names_key(event: InputEvent) -> void:
	if event.is_action_pressed("ui_right", false, true) and _shelf_files.row_count() > 0:
		_shelf_files.grab_focus()
		_shelves.names().accept_event()


func _on_shelf_files_key(event: InputEvent) -> void:
	if event.is_action_pressed("ui_right", false, true) and _diff_view.row_count() > 0:
		_diff_view.grab_focus()
		_shelf_files.accept_event()
	elif event.is_action_pressed("ui_left", false, true):
		_shelves.focus_list()
		_shelf_files.accept_event()


func _clear_diff() -> void:
	if session != null:
		session.clear_diff()
	_diff_view.pickable = false
	_diff_panel.clear("Select a shelved file to preview its changes." if _shelves_mode else "Select a file to see its changes.")


func _load_full_diff() -> void:
	if _showing_shelf:
		var shelf: Dictionary = _shelves.selected_shelf()
		session.select_shelf_file(String(shelf.get("oid", "")), String(session.diff_info().get("path", "")), true)
		return
	session.select_change(String(session.diff_info().get("path", "")), true)


func _on_diff_changed() -> void:
	if session == null:
		return
	var info: Dictionary = session.diff_info()
	_diff_view.pickable = bool(info.get("pickable", false))
	if bool(info.get("as_staged", false)):
		var notes: PackedStringArray = info.get("notes", PackedStringArray())
		notes.append("Staged in part outside gitbello: committed as staged")
		info["notes"] = notes
	_diff_panel.show_info(info)
