class_name ChangesView
extends HSplitContainer
## Working-copy changes of one repository (PLAN §4): unstaged, untracked and
## staged file lists, the commit box and the diff of the selected file.
## Keyboard: arrows move, Enter/Space stage or unstage files or the selected
## diff lines (a hunk header takes its hunk), Delete discards, Ctrl+Z undoes
## the last discard; see the `changes.*` actions for the rest.

const THEME_TYPE: StringName = &"ChangesView"

var session: RepoSession = null:
	set = set_session

## The list Left returns to from the diff.
var _last_list: ChangeList = null
var _confirm: ConfirmationDialog = ConfirmationDialog.new()
## Runs when the user confirms the discard dialog.
var _pending_discard: Callable = Callable()
var _menu: PopupMenu = PopupMenu.new()
var _menu_actions: Array[StringName] = []

## Shows the results of discards (with Undo); may be null in tests.
var feedback: Feedback = null

@onready var _files: VBoxContainer = %Files
@onready var _switch_slot: Container = %SwitchSlot
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
@onready var _diff_panel: DiffPanel = %DiffPanel
@onready var _diff_view: DiffView = _diff_panel.view()


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
	_diff_panel.load_full_requested.connect(_load_full_diff)
	_diff_panel.set_source(func(start: int, count: int) -> Array:
		return session.diff_lines(start, count) if session != null else [])
	_diff_panel.set_split_source(func(start: int, count: int) -> Array:
		return session.diff_split_rows("changes", start, count) if session != null else [])
	_diff_view.row_activated.connect(func(_row: int) -> void: stage_diff_lines())
	_diff_panel.clear("Select a file to see its changes.")
	_confirm.confirmed.connect(func() -> void:
		if _pending_discard.is_valid():
			_pending_discard.call()
		_pending_discard = Callable())
	add_child(_confirm)
	add_child(_menu)
	_menu.id_pressed.connect(func(id: int) -> void: Actions.run_action(_menu_actions[id]))
	for list: ChangeList in lists():
		list.context_menu_requested.connect(_show_menu.bind(list))
		list.gui_input.connect(_on_list_key.bind(list))
	_diff_view.gui_input.connect(_on_diff_key)
	_diff_view.context_menu_requested.connect(_show_menu.bind(_diff_view))


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


## Stages or unstages the selection of the focused (or selected) list, or
## the selected lines when the diff has focus.
func stage_selected() -> void:
	if _diff_view.has_focus():
		stage_diff_lines()
		return
	var list: ChangeList = _focused_list()
	if list == null:
		list = _selected_list()
	if list != null:
		list.activate_selection()


## Stages (unstaged diff) or unstages (staged diff) the selected diff lines.
## Returns whether a job started.
func stage_diff_lines() -> bool:
	var mode: String = _line_mode()
	if mode.is_empty():
		return false
	return session.apply_lines(mode, _diff_view.selected_or_cursor()) >= 0


func diff_view_focused() -> bool:
	return _diff_view.has_focus()


## Discards the focused selection after a confirmation: diff lines, or the
## selected files (tracked files are restored from the index and can be
## brought back with `undo_discard`; untracked files go to the trash).
func discard_selection() -> void:
	if _diff_view.has_focus():
		_discard_lines()
		return
	var list: ChangeList = _focused_list()
	if list == null:
		list = _selected_list()
	if list == null or list == _staged:
		return
	var rows: PackedInt32Array = list.selected_rows()
	if rows.is_empty() and list.cursor >= 0:
		rows.append(list.cursor)
	var by_group: Dictionary = list.paths_by_group(rows)
	var tracked: PackedStringArray = PackedStringArray()
	for group: String in ["unstaged", "conflicted"]:
		tracked.append_array(by_group.get(group, PackedStringArray()))
	var untracked: PackedStringArray = by_group.get("untracked", PackedStringArray())
	if tracked.is_empty() and untracked.is_empty():
		return
	var parts: PackedStringArray = PackedStringArray()
	if not tracked.is_empty():
		parts.append("Discard changes in %s? You can undo this with %s." % [
			_describe(tracked), Actions.shortcut_label(&"changes.undo_discard")])
	if not untracked.is_empty():
		parts.append("Move %s to the trash?" % _describe(untracked))
	_ask("\n".join(parts), func() -> void:
		if not tracked.is_empty():
			var job: int = session.discard_paths(tracked)
			if feedback != null:
				feedback.track(session, job, "Discarding", "Discarded changes in %s" % _describe(tracked),
						null, Callable(), undo_discard)
		if not untracked.is_empty():
			_trash(untracked))


func can_undo_discard() -> bool:
	return session != null and session.can_undo_discard()


func undo_discard() -> void:
	if can_undo_discard():
		session.undo_discard()


## The discard confirmation, for tests.
func confirm_dialog() -> ConfirmationDialog:
	return _confirm


func _discard_lines() -> void:
	if not session.can_apply_lines("discard"):
		return
	var rows: PackedInt32Array = _diff_view.selected_or_cursor()
	if rows.is_empty():
		return
	var path: String = String(session.diff_info().get("path", ""))
	var what: String = "the selected lines" if rows.size() > 1 else "the selected line"
	_ask("Discard %s in %s? You can undo this with %s." % [
		what, path.get_file(), Actions.shortcut_label(&"changes.undo_discard")],
		func() -> void: session.apply_lines("discard", rows))


func _ask(text: String, on_confirm: Callable) -> void:
	_confirm.title = "Discard changes"
	_confirm.dialog_text = text
	_confirm.ok_button_text = "Discard"
	_pending_discard = on_confirm
	_confirm.popup_centered()
	_confirm.get_ok_button().grab_focus()


func _trash(paths: PackedStringArray) -> void:
	var root: String = session.toplevel()
	for path: String in paths:
		var error: Error = OS.move_to_trash(ProjectSettings.globalize_path(root.path_join(path)))
		if error != OK:
			push_warning("cannot move %s to the trash: %s" % [path, error_string(error)])
	session.refresh()


static func _describe(paths: PackedStringArray) -> String:
	return paths[0].get_file() if paths.size() == 1 else "%d files" % paths.size()


## `stage` or `unstage` for the shown diff, or "" when its lines cannot be used.
func _line_mode() -> String:
	if session == null:
		return ""
	if session.can_apply_lines("stage"):
		return "stage"
	if session.can_apply_lines("unstage"):
		return "unstage"
	return ""


## Context menu for a list or the diff: the actions that apply right now.
func _show_menu(_row: int, at_position: Vector2, source: Control) -> void:
	_menu.clear()
	_menu_actions.clear()
	var ids: Array[StringName] = [&"changes.stage_selected", &"changes.discard", &"changes.undo_discard"]
	for id: StringName in ids:
		if not Actions.is_enabled(id):
			continue
		var action: ActionRegistry.Action = Actions.get_action(id)
		_menu.add_item(action.label, _menu_actions.size())
		_menu_actions.append(id)
	if _menu_actions.is_empty():
		return
	_menu.position = Vector2i(source.get_screen_position() + at_position)
	_menu.reset_size()
	_menu.popup()


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


## Right in a file list moves into the diff.
func _on_list_key(event: InputEvent, list: ChangeList) -> void:
	if event.is_action_pressed("ui_right", false, true) and _diff_view.row_count() > 0:
		_last_list = list
		_diff_view.grab_focus()
		if _diff_view.cursor < 0:
			_diff_view.select_only(0)
		list.accept_event()


## Left in the diff (when it is not scrolled sideways) goes back to the list.
func _on_diff_key(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", false, true) and _diff_view.h_scroll() <= 0.0:
		var list: ChangeList = _last_list if _last_list != null and _last_list.row_count() > 0 else _selected_list()
		if list == null:
			focus_files()
		else:
			list.grab_focus()
		_diff_view.accept_event()


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
	_diff_panel.clear()


func _load_full_diff() -> void:
	var info: Dictionary = session.diff_info()
	var group: String = String(info.get("kind", ""))
	session.select_diff(group, String(info.get("path", "")), true)


func _on_diff_changed() -> void:
	if session != null:
		_diff_panel.show_info(session.diff_info())


func diff_panel() -> DiffPanel:
	return _diff_panel


func _apply_theme() -> void:
	_files.custom_minimum_size.x = float(get_theme_constant(&"files_width", THEME_TYPE))
	_files.add_theme_constant_override(&"separation", get_theme_constant(&"separation", THEME_TYPE))
