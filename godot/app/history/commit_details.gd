class_name CommitDetails
extends VSplitContainer
## The selected commit (PLAN M4b, laid out in M6.5): its `CommitHeader`
## (summary, people, date, hash, refs and message) on top, then its files
## beside the diff of the selected file. The top part's height (this split)
## and the files' width (`files_split()`) are dragged by the user.

const THEME_TYPE: StringName = &"CommitDetails"
## The diff's context menu: its actions, by item id.
const DIFF_MENU_ACTIONS: Array[StringName] = [&"diff.copy", &"diff.select_all", &"", &"diff.open_file",
	&"file_history.open", &"", &"diff.toggle_minimap"]
## The file list's context menu: its actions, by item id.
const FILE_MENU_ACTIONS: Array[StringName] = [&"diff.open_file", &"file_history.open"]

var session: RepoSession = null:
	set = set_session
## Formats unix times (the commit list's local-time format).
var date_format: Callable = Callable():
	set(value):
		date_format = value
		if is_node_ready():
			_header.date_format = value

signal parent_requested(source: String, oid: String, origin: LinkButton)
## A ref chip was clicked: show the menu of `label` (`RefChip.ref_target`)
## at `at_position` (screen), over the popup `over` (or null).
signal label_menu_requested(label: Dictionary, at_position: Vector2, over: Window)

var _menu: PopupMenu = PopupMenu.new()
var _file_menu: PopupMenu = PopupMenu.new()
var _shown_oid: String = ""
var _requested_oid: String = ""


@onready var _files_box: VBoxContainer = %FilesBox
@onready var _split: HSplitContainer = %Split
@onready var _header: CommitHeader = %Header
@onready var _files_header: ListHeader = %FilesHeader
@onready var _files: CommitFileList = %Files
@onready var _diff_panel: DiffPanel = %CommitDiffPanel
## Over the file list while the selected commit loads.
var _loading: LoadingIndicator = LoadingIndicator.new()
## Over the file list of a commit without changed files (a merge, an empty
## commit).
var _files_empty: EmptyState = EmptyState.create_compact()


func _ready() -> void:
	_files.add_child(_files_empty)
	_files_empty.show_compact(&"FileList", "No changed files")
	_files.add_child(_loading)
	_header.date_format = date_format
	_header.body_shown.connect(func(shown: bool) -> void: collapsed = not shown)
	_header.label_menu_requested.connect(label_menu_requested.emit)
	_header.parent_requested.connect(func(source: String, oid: String, origin: LinkButton) -> void:
		if _shown_oid == source and _requested_oid == source:
			parent_requested.emit(source, oid, origin))
	dragger_visibility = SplitContainer.DRAGGER_HIDDEN_COLLAPSED
	_apply_theme()
	_files.current_changed.connect(_on_file_changed)
	_diff_panel.set_source(func(start: int, count: int) -> Array:
		return session.commit_diff_lines(start, count) if session != null else [])
	_diff_panel.set_image_source(func(side: String) -> Dictionary:
		return session.image_side("commit", side) if session != null else {})
	_diff_panel.set_split_source(func(start: int, count: int) -> Array:
		return session.diff_split_rows("commit", start, count) if session != null else [])
	_diff_panel.set_minimap_sources(
		func(split: bool, first: int, rows: int, columns: int, row_px: int, char_px: int,
				palette: PackedColorArray) -> PackedByteArray:
			if session == null:
				return PackedByteArray()
			return session.diff_minimap_tile("commit", split, first, rows, columns, row_px, char_px, palette),
		func(split: bool, buckets: int) -> PackedByteArray:
			return session.diff_overview("commit", split, buckets, true) if session != null else PackedByteArray(),
		func(split: bool, row: float) -> float:
			return session.diff_strip_position("commit", split, row, true) if session != null else 0.0,
		func(split: bool, fraction: float) -> Dictionary:
			return session.diff_strip_target("commit", split, fraction, true) if session != null else {})
	_diff_panel.set_change_source(func(split: bool, from_row: int, forward: bool) -> int:
		return session.diff_change_row("commit", split, from_row, forward) if session != null else -1)
	_diff_panel.load_full_requested.connect(func() -> void:
		session.select_commit_file(String(session.commit_diff_info().get("path", "")), true))
	_diff_panel.expand_requested.connect(func(gap: int, how: String) -> void:
		session.expand_diff("commit", gap, how))
	_diff_panel.whole_file_requested.connect(func(whole: bool) -> void:
		session.show_whole_diff("commit", whole))
	_files.gui_input.connect(_on_files_key)
	_diff_panel.view().gui_input.connect(_on_diff_key)
	_diff_panel.view().context_menu_requested.connect(_show_diff_menu)
	_diff_panel.open_side_requested.connect(func(side: String) -> void:
		if session != null:
			session.open_version("commit", side))
	add_child(_menu)
	_menu.id_pressed.connect(func(id: int) -> void: Actions.run_action(DIFF_MENU_ACTIONS[id]))
	_files.context_menu_requested.connect(_show_file_menu)
	add_child(_file_menu)
	_file_menu.id_pressed.connect(func(id: int) -> void: Actions.run_action(FILE_MENU_ACTIONS[id]))
	show_placeholder()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _loading.get_parent() == null:
		_loading.free()  # Never added: freed without ever being ready.
		_files_empty.free()
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		if session != null:
			_on_commit_loaded()
			_on_diff_changed()


func set_session(value: RepoSession) -> void:
	if session != null:
		session.commit_loaded.disconnect(_on_commit_loaded)
		session.commit_diff_changed.disconnect(_on_diff_changed)
	session = value
	_header.session = session
	show_placeholder()
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
	return _header.summary_text()


func body_text() -> String:
	return _header.body_text()


## The summary, people, ids, refs and message above the files.
func header() -> CommitHeader:
	return _header


## The commit's line totals as shown, `+12 −3`, or "" when hidden.
func totals_text() -> String:
	return _files_header.counts_text()


## The line above the files: their count and the commit's totals.
func files_header() -> ListHeader:
	return _files_header


## Asks for commit `oid`; the panel fills in when it arrives.
func show_commit(oid: String) -> void:
	if session == null or oid.is_empty():
		show_placeholder()
		return
	_requested_oid = oid
	if _shown_oid != oid:
		_shown_oid = ""
	session.load_commit(oid)
	if String(session.commit_info().get("oid", "")) == oid:
		_on_commit_loaded()
	elif _shown_oid != oid:
		# The files of the previous commit would mislead: show the load.
		_files.show_files(0)
		_files_empty.hide()
		_files_header.set_text("")
		_files_header.show_counts(0, 0)
		_loading.show_loading(true, tr("Loading commit…"))


## Shows no commit (while the history loads): "No file selected" in the
## diff, or nothing at all when `blank` (a history without commits, whose
## list says so).
func show_placeholder(blank: bool = false) -> void:
	_loading.hide_loading()
	_requested_oid = ""
	_shown_oid = ""
	_header.show_text("")
	_files_header.set_text("")
	_files_header.show_counts(0, 0)
	_files.show_files(0)
	_files_empty.hide()
	if blank:
		_diff_panel.blank()
	else:
		_diff_panel.clear("No file selected")


## Shows "Compare commits" while two commits are selected.
func show_pair_action(shown: bool) -> void:
	_header.show_pair_action(shown)


func pair_button() -> Button:
	return _header.pair_button()


## The file list's loading indicator (smoke tests and screenshots).
func loading_indicator() -> LoadingIndicator:
	return _loading


## Focuses the file list (cursor on the first file).
func focus_files() -> void:
	_files.grab_focus()
	if _files.cursor < 0 and _files.row_count() > 0:
		_files.select_only(0)


func _on_commit_loaded() -> void:
	var info: Dictionary = session.commit_info()
	if info.is_empty() or _requested_oid.is_empty() or not String(info["oid"]).begins_with(_requested_oid):
		return
	_loading.hide_loading()
	var oid: String = String(info["oid"])
	_requested_oid = oid
	_shown_oid = oid
	_header.show_info(info)
	var count: int = int(info["file_count"])
	_files_header.set_text(ListHeader.count_text(count, "changed file"))
	_files_header.show_counts(int(info.get("additions", 0)), int(info.get("deletions", 0)))
	_files.show_files(count)
	_files_empty.visible = count == 0
	if count > 0:
		_files.select_only(0)
	else:
		_diff_panel.blank()


## The people's cards (`CommitHeader.people`), for tests.
func people() -> Array[Dictionary]:
	return _header.people()


## The ref chips shown, for tests.
func ref_chips() -> Array[RefChip]:
	return _header.ref_chips()


func parent_links() -> Array[LinkButton]:
	return _header.parent_links()


func commit_oid() -> String:
	return _shown_oid


func _on_file_changed(path: String) -> void:
	if path.is_empty():
		return
	session.select_commit_file(path, false)
	_on_diff_changed()


func retry_diff() -> void:
	if session == null or not _diff_panel.can_retry():
		return
	var info: Dictionary = session.commit_diff_info()
	if String(info.get("state", "")) != "error":
		return
	session.select_commit_file(String(info.get("path", "")), false)
	_on_diff_changed()


func _on_diff_changed() -> void:
	_diff_panel.show_info(session.commit_diff_info())


## The diff's context menu: Copy (when text is selected), Select all and
## the minimap toggle.
func _show_diff_menu(_row: int, at_position: Vector2) -> void:
	_menu.clear()
	for i: int in DIFF_MENU_ACTIONS.size():
		if DIFF_MENU_ACTIONS[i] == &"":
			_menu.add_separator()
			continue
		_menu.add_icon_item(Actions.icon(DIFF_MENU_ACTIONS[i]), Actions.get_action(DIFF_MENU_ACTIONS[i]).label, i)
		_menu.set_item_disabled(_menu.item_count - 1, not Actions.is_enabled(DIFF_MENU_ACTIONS[i]))
		if DIFF_MENU_ACTIONS[i] == &"diff.toggle_minimap":
			_menu.set_item_as_checkable(_menu.item_count - 1, true)
			_menu.set_item_checked(_menu.item_count - 1, Core.diff_minimap())
	_menu.position = Vector2i(_diff_panel.view().get_screen_position() + at_position)
	_menu.reset_size()
	_menu.popup()


## The diff's context menu, for tests.
func diff_menu() -> PopupMenu:
	return _menu


## The file list's context menu (the right-clicked file is selected): Open.
func _show_file_menu(_row: int, at_position: Vector2) -> void:
	_file_menu.clear()
	for i: int in FILE_MENU_ACTIONS.size():
		_file_menu.add_icon_item(Actions.icon(FILE_MENU_ACTIONS[i]), Actions.get_action(FILE_MENU_ACTIONS[i]).label, i)
		_file_menu.set_item_disabled(_file_menu.item_count - 1, not Actions.is_enabled(FILE_MENU_ACTIONS[i]))
	_file_menu.position = Vector2i(_files.get_screen_position() + at_position)
	_file_menu.reset_size()
	_file_menu.popup()


## The file list's context menu, for tests.
func file_menu() -> PopupMenu:
	return _file_menu


## The file list (for tests).
func files() -> CommitFileList:
	return _files


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
	_files_box.custom_minimum_size.x = float(get_theme_constant(&"min_files_width", THEME_TYPE))
