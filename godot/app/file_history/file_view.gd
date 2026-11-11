class_name FileView
extends VBoxContainer
## One file over time (PLAN M8a): the commits that changed it, under every
## name it had, each with its diff of that file. A bar on top names the
## file and where its history is read from, and holds the Blame switch. Below,
## like History: the versions on the left (the uncommitted changes first,
## while there are any) under a field that filters them by message, author
## or hash and holds the Compact rows option, and, on the right, the selected
## version's commit over the diff of the file in it. Diffs are read-only. Two selected versions
## open in Compare; a version can be restored into the working copy (with
## Undo), opened, or shown in History. The view is named for the file, not
## for its history. Blame (M8b) is a switch in the bar: while it is on, the
## diff gives way to the file as the selected version has it (the working
## copy on the uncommitted changes) in a `BlameView`, under a strip that says which version that is
## and how far git is. Clicking a line's gutter focuses its commit: its
## details show over the file, its lines are tinted and its row in the
## versions is marked. **Blame before this commit** moves the selection to
## the version the line came from; **Show changes** turns Blame off on the
## line's commit.

## The user closed the view.
signal closed()
## A ref chip of the details was clicked: show the menu of `label`
## (`RefChip.ref_target`) at `at_position` (screen).
signal label_menu_requested(label: Dictionary, at_position: Vector2)
## Compare `left` with `right` (commits, the older first), filtered to `path`.
signal compare_requested(left: String, right: String, path: String)
## Show commit `oid` in History; `in_head` when the current branch has it.
signal history_requested(oid: String, in_head: bool)

## Every file view, so a blame option changed in one reaches all
## (`refresh_blame_options`).
const GROUP: StringName = &"file_views"
const DIFF_PANEL: PackedScene = preload("res://ui/diff_view/diff_panel.tscn")
const COMMIT_HEADER: PackedScene = preload("res://app/history/commit_header.tscn")
const FILTER_FIELD: PackedScene = preload("res://ui/filter_field/filter_field.tscn")
## The diff slot of the session this view shows.
const SLOT: String = "file"
## The diff's context menu: its actions, by item id.
const DIFF_MENU_ACTIONS: Array[StringName] = [&"diff.copy", &"diff.select_all", &"", &"diff.open_file", &"",
	&"diff.toggle_minimap"]
## A version's context menu.
const VERSION_MENU_ACTIONS: Array[StringName] = [&"file_history.compare_versions", &"",
	&"file_history.restore", &"file_history.open_version", &"", &"file_history.show_in_history", &"",
	&"file_history.copy_hash"]
## The blame's slot for the minimap and the next and previous change.
const BLAME_SLOT: String = "blame"
## A blamed line's context menu.
const BLAME_MENU_ACTIONS: Array[StringName] = [&"blame.before", &"blame.show_changes", &"",
	&"file_history.show_in_history", &"file_history.copy_hash", &"", &"diff.copy", &"diff.select_all", &"",
	&"file_history.open_version", &"", &"diff.toggle_minimap"]
## The blame options menu's items and their actions.
const BLAME_OPTIONS: Array[Array] = [["Ignore whitespace", &"blame.toggle_ignore_whitespace"],
	["Detect moved lines", &"blame.toggle_detect_moves"]]
## Characters of the start's name on its chip (the tooltip has all of it).
const MAX_START_CHARS: int = 40
## The options menu's Compact rows item.
const COMPACT_ID: int = 0

var session: RepoSession = null:
	set = set_session
## Shows Restore's progress and its Undo; set by the worktree view.
var feedback: Feedback = null
## Copies hashes; set by the worktree view.
var ops: RepoOps = null
## Formats unix times (the history's format), for the details' date.
var date_format: Callable = Callable():
	set(value):
		date_format = value
		_details_header.date_format = value

## Whether the selected version shows as its blame (its lines and who wrote
## them).
var _blame: bool = false
## `RepoSession.blame_info()` as last shown.
var _blame_info: Dictionary = {}
## The blame whose rows show (its version and path) and how many they are.
var _blame_key: String = ""
var _blame_lines: int = 0
## The line to put the caret on once the blame has its text; -1 for none.
var _pending_line: int = -1
## The version to select once the versions list it (Blame before).
var _pending_version: String = ""
## The line Blame before was asked on, kept until its version is found (the
## blame still showing must not use it up); -1 for none.
var _before_line: int = -1
## What blame said of the line whose commit was focused (`blame_line`).
var _focus_line: Dictionary = {}
## The strip's note in place of the counts ("" for none).
var _blame_note: String = ""
## The history shown (`{path, start, start_name}`), or empty.
var _request: Dictionary = {}
var _info: Dictionary = {}
## The version shown: a commit's oid, `working`, or "".
var _selected: String = ""
## The filter's text changed: bring the cursor into view when its rows come.
var _filter_pending: bool = false

var _bar: PanelContainer = PanelContainer.new()
var _icon: TextureRect = TextureRect.new()
var _path: PathLabel = PathLabel.new()
var _start: Label = Label.new()
## The Blame switch.
var _blame_button: Button = Button.new()
## The versions | the details (the shared left-pane width).
var _split: HSplitContainer = HSplitContainer.new()
var _left: VBoxContainer = VBoxContainer.new()
var _filter: FilterField = FILTER_FIELD.instantiate() as FilterField
var _options_button: Button = null
var _options_menu: PopupMenu = PopupMenu.new()
var _list: FileHistoryList = FileHistoryList.new()
var _loading: LoadingIndicator = LoadingIndicator.new()
var _message: Label = Label.new()
## The selected version's commit over its diff (as History's).
var _details: VSplitContainer = VSplitContainer.new()
var _details_header: CommitHeader = COMMIT_HEADER.instantiate() as CommitHeader
var _diff_panel: DiffPanel = DIFF_PANEL.instantiate() as DiffPanel
var _menu: PopupMenu = PopupMenu.new()
var _version_menu: PopupMenu = PopupMenu.new()
## The diff, or the blame under its strip.
var _lower: VBoxContainer = VBoxContainer.new()
var _blame_box: VBoxContainer = VBoxContainer.new()
var _blame_bar: PanelContainer = PanelContainer.new()
var _blame_version: Label = Label.new()
var _blame_status: Label = Label.new()
var _blame_options: Button = Button.new()
var _blame_options_menu: PopupMenu = PopupMenu.new()
var _blame_area: Control = Control.new()
var _blame_view: BlameView = BlameView.new()
var _blame_loading: LoadingIndicator = LoadingIndicator.new()
var _blame_message: Label = Label.new()
var _blame_menu: PopupMenu = PopupMenu.new()


func _ready() -> void:
	theme_type_variation = &"PaneColumn"
	_build_bar()
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_split)
	_left.theme_type_variation = &"PaneColumn"
	_split.add_child(_left)
	_build_filter()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left.add_child(_list)
	_list.version_changed.connect(_on_version_changed)
	_list.context_menu_requested.connect(_show_version_menu)
	_list.gui_input.connect(_on_list_key)
	_loading.area = "history"
	_list.add_child(_loading)
	_message.theme_type_variation = &"DimLabel"
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_message.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_message.hide()
	_list.add_child(_message)
	_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details.dragger_visibility = SplitContainer.DRAGGER_HIDDEN_COLLAPSED
	_split.add_child(_details)
	_details_header.copy_action = &"file_history.copy_hash"
	_details_header.links_parents = false
	_details_header.hide()
	_details.add_child(_details_header)
	_details_header.body_shown.connect(func(_shown: bool) -> void: _update_details_split())
	_details_header.label_menu_requested.connect(func(label: Dictionary, at: Vector2) -> void:
		label_menu_requested.emit(label, at))
	_lower.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_lower.theme_type_variation = &"PaneColumn"
	_details.add_child(_lower)
	_diff_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_lower.add_child(_diff_panel)
	_wire_diff()
	_build_blame()
	for entry: Array in [[_menu, DIFF_MENU_ACTIONS], [_version_menu, VERSION_MENU_ACTIONS],
			[_blame_menu, BLAME_MENU_ACTIONS]]:
		var menu: PopupMenu = entry[0]
		var ids: Array[StringName] = entry[1]
		add_child(menu)
		menu.id_pressed.connect(func(id: int) -> void: Actions.run_action(ids[id]))
	# Compact rows follow History's setting.
	add_to_group(HistoryView.GROUP)
	add_to_group(GROUP)
	# The blame's minimap follows the diffs' setting.
	add_to_group(DiffPanel.GROUP)
	set_compact(Core.history_compact())
	set_minimap_enabled(Core.diff_minimap())
	_apply_theme()
	_update_bar()
	_apply_mode()


## One-line rows, as History's Compact rows.
func set_compact(value: bool) -> void:
	_list.compact = value


## History's graph setting does not apply: the versions have no graph.
func set_show_graph(_value: bool) -> void:
	pass


func _build_bar() -> void:
	_bar.theme_type_variation = &"FileBar"
	add_child(_bar)
	var row: HBoxContainer = HBoxContainer.new()
	row.theme_type_variation = &"HeaderRow"
	_bar.add_child(row)
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_icon)
	_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_path)
	_start.theme_type_variation = &"FileHistoryStart"
	_start.mouse_filter = Control.MOUSE_FILTER_PASS
	_start.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_start.hide()
	row.add_child(_start)
	_blame_button.toggle_mode = true
	_blame_button.focus_mode = Control.FOCUS_NONE
	_blame_button.theme_type_variation = &"IconToggle"
	_blame_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_blame_button.toggled.connect(func(on: bool) -> void: set_blame(on))
	row.add_child(_blame_button)


## The field over the versions: the filter and the row options.
func _build_filter() -> void:
	var filter_bar: PanelContainer = PanelContainer.new()
	filter_bar.theme_type_variation = &"FilterBar"
	_filter.placeholder = tr("Filter commits")
	filter_bar.add_child(_filter)
	_left.add_child(filter_bar)
	_filter.changed.connect(_on_filter)
	_filter.done.connect(func() -> void: _list.grab_focus())
	_filter.submitted.connect(func(_backwards: bool) -> void: _list.grab_focus())
	_options_button = _filter.add_button(&"Filter", "Filter options")
	_options_button.pressed.connect(_show_options)
	_options_menu.add_check_item(tr("Compact rows"), COMPACT_ID)
	_options_menu.id_pressed.connect(func(_id: int) -> void:
		Actions.run_action(&"history.toggle_compact", _options_button))
	_options_menu.about_to_popup.connect(_update_options)
	add_child(_options_menu)


func _show_options() -> void:
	_options_menu.position = Vector2i(_options_button.get_screen_position()
			+ Vector2(0.0, _options_button.size.y))
	_options_menu.reset_size()
	_options_menu.popup()


func _update_options() -> void:
	HistoryView.show_check_action(_options_menu, COMPACT_ID, "Compact rows", &"history.toggle_compact", _list.compact)


func _wire_diff() -> void:
	_diff_panel.set_source(func(start: int, count: int) -> Array:
		return session.slot_diff_lines(SLOT, start, count) if session != null else [])
	_diff_panel.set_image_source(func(side: String) -> Dictionary:
		return session.image_side(SLOT, side) if session != null else {})
	_diff_panel.set_split_source(func(start: int, count: int) -> Array:
		return session.diff_split_rows(SLOT, start, count) if session != null else [])
	_diff_panel.set_minimap_sources(
		func(split: bool, first: int, rows: int, columns: int, row_px: int, char_px: int,
				palette: PackedColorArray) -> PackedByteArray:
			if session == null:
				return PackedByteArray()
			return session.diff_minimap_tile(SLOT, split, first, rows, columns, row_px, char_px, palette),
		func(split: bool, buckets: int) -> PackedByteArray:
			return session.diff_overview(SLOT, split, buckets, true) if session != null else PackedByteArray(),
		func(split: bool, row: float) -> float:
			return session.diff_strip_position(SLOT, split, row, true) if session != null else 0.0,
		func(split: bool, fraction: float) -> Dictionary:
			return session.diff_strip_target(SLOT, split, fraction, true) if session != null else {})
	_diff_panel.set_change_source(func(split: bool, from_row: int, forward: bool) -> int:
		return session.diff_change_row(SLOT, split, from_row, forward) if session != null else -1)
	_diff_panel.load_full_requested.connect(func() -> void: _select(_selected, true))
	_diff_panel.expand_requested.connect(func(gap: int, how: String) -> void:
		session.expand_diff(SLOT, gap, how))
	_diff_panel.whole_file_requested.connect(func(whole: bool) -> void:
		session.show_whole_diff(SLOT, whole))
	_diff_panel.view().gui_input.connect(_on_diff_key)
	_diff_panel.view().context_menu_requested.connect(_show_diff_menu)
	_diff_panel.open_side_requested.connect(func(side: String) -> void:
		if session != null:
			session.open_version(SLOT, side))
	_diff_panel.clear("Select a version to see its changes.")


## The blame: a strip (the version, the counts, the options) over the lines.
func _build_blame() -> void:
	_blame_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_blame_box.theme_type_variation = &"PaneColumn"
	_blame_box.hide()
	_lower.add_child(_blame_box)
	_blame_bar.theme_type_variation = &"BlameBar"
	_blame_box.add_child(_blame_bar)
	var row: HBoxContainer = HBoxContainer.new()
	_blame_bar.add_child(row)
	_blame_version.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_blame_version.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_blame_version.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(_blame_version)
	_blame_status.theme_type_variation = &"DimLabel"
	row.add_child(_blame_status)
	_blame_options.icon = AppTheme.icon(&"Tools")
	_blame_options.focus_mode = Control.FOCUS_NONE
	_blame_options.theme_type_variation = &"DetailsIconButton"
	_blame_options.pressed.connect(_show_blame_options)
	row.add_child(_blame_options)
	for i: int in BLAME_OPTIONS.size():
		_blame_options_menu.add_check_item(tr(BLAME_OPTIONS[i][0]), i)
	_blame_options_menu.id_pressed.connect(func(id: int) -> void:
		Actions.run_action(BLAME_OPTIONS[id][1], _blame_options))
	_blame_options_menu.about_to_popup.connect(_update_blame_options)
	add_child(_blame_options_menu)
	_blame_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_blame_area.clip_contents = true
	_blame_box.add_child(_blame_area)
	_blame_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_blame_area.add_child(_blame_view)
	_blame_view.source = func(start: int, count: int) -> Array:
		return session.blame_lines(start, count) if session != null else []
	_blame_view.set_minimap_sources(
		func(_split: bool, first: int, rows: int, columns: int, row_px: int, char_px: int,
				palette: PackedColorArray) -> PackedByteArray:
			if session == null:
				return PackedByteArray()
			return session.diff_minimap_tile(BLAME_SLOT, false, first, rows, columns, row_px, char_px, palette),
		func(_split: bool, buckets: int) -> PackedByteArray:
			return session.diff_overview(BLAME_SLOT, false, buckets, true) if session != null else PackedByteArray(),
		func(_split: bool, row: float) -> float:
			return session.diff_strip_position(BLAME_SLOT, false, row, true) if session != null else 0.0,
		func(_split: bool, fraction: float) -> Dictionary:
			return session.diff_strip_target(BLAME_SLOT, false, fraction, true) if session != null else {})
	# The next and previous change step through the focused commit's lines.
	_blame_view.change_source = func(_split: bool, from_row: int, forward: bool) -> int:
		return session.diff_change_row(BLAME_SLOT, false, from_row, forward) if session != null else -1
	_blame_view.commit_clicked.connect(_on_commit_clicked)
	_blame_view.gui_input.connect(_on_blame_key)
	_blame_view.context_menu_requested.connect(func(_row: int, at_position: Vector2) -> void:
		_show_actions(_blame_menu, BLAME_MENU_ACTIONS, _blame_view.get_screen_position() + at_position))
	_blame_loading.area = "diff"
	_blame_area.add_child(_blame_loading)
	_blame_message.theme_type_variation = &"DimLabel"
	_blame_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_blame_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_blame_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_blame_message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blame_message.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_blame_message.hide()
	_blame_area.add_child(_blame_message)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _loading.get_parent() == null:
		_loading.free()
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		_filter.placeholder = tr("Filter commits")
		_options_button.tooltip_text = tr("Filter options")
		_update_bar()
		_apply_mode()
		if session != null:
			_on_history_changed()
			_on_blame_changed()


func set_session(value: RepoSession) -> void:
	if session != null:
		session.file_history_changed.disconnect(_on_history_changed)
		session.file_history_diff_changed.disconnect(_on_diff_changed)
		session.blame_changed.disconnect(_on_blame_changed)
		session.blame_version_found.disconnect(_on_blame_version)
	session = value
	_list.session = session
	_request = {}
	if session != null:
		session.file_history_changed.connect(_on_history_changed)
		session.file_history_diff_changed.connect(_on_diff_changed)
		session.blame_changed.connect(_on_blame_changed)
		session.blame_version_found.connect(_on_blame_version)


# --- Opening and closing --------------------------------------------------------

## Opens the history of `path` (repository-relative), read from `start` (a
## revision; "" for HEAD, which the history then follows). `start_name` is
## what the bar calls a fixed start. `blame` turns Blame on, with the caret
## on line `line` (0-based; -1 for the top). A history that is already open
## stays as it is (Blame too, unless it is asked for).
func open(path: String, start: String = "", start_name: String = "", blame: bool = false,
		line: int = -1) -> void:
	if session == null or path.is_empty():
		return
	if has_history() and path == shown_path() and start == String(_request["start"]) \
			and bool(_info.get("open", false)) and (_info.get("error", {}) as Dictionary).is_empty():
		if blame:
			set_blame(true, line)
		return
	_blame = blame
	_reset_blame()
	_pending_line = line if blame else -1
	# A new history starts without a filter; clearing the field must not
	# filter the one being left.
	_request = {}
	_filter.set_text("")
	_filter_pending = false
	_request = {"path": path, "start": start, "start_name": start_name}
	_info = {}
	_selected = ""
	_list.show_history({}, "")
	_list.set_scroll_offset(0.0)
	_details_header.hide()
	_update_details_split()
	_diff_panel.clear("Select a version to see its changes.")
	session.open_file_history(path, start, start_name)
	_apply_mode()
	_on_history_changed()


func has_history() -> bool:
	return not _request.is_empty()


## The history shown: `{path, start, start_name}`, or empty.
func shown_request() -> Dictionary:
	return _request.duplicate()


## The file whose history shows (as it is named where the history starts).
func shown_path() -> String:
	return String(_request.get("path", ""))


func close() -> void:
	if session != null:
		session.close_file_history()
	_request = {}
	_info = {}
	_selected = ""
	_blame = false
	_reset_blame()
	_list.show_history({}, "")
	_apply_mode()
	closed.emit()


# --- State ----------------------------------------------------------------------

func _on_history_changed() -> void:
	if session == null or _request.is_empty():
		return
	_info = session.file_history_info()
	if not bool(_info.get("open", false)):
		return
	_update_bar()
	_list.show_history(_info, _selected)
	var error: Dictionary = _info.get("error", {})
	var loading: bool = bool(_info.get("loading", false))
	var rows: int = _list.row_count()
	_message.hide()
	if not error.is_empty():
		_loading.hide_loading()
		_message.text = tr("Could not read the history: %s") % String(error.get("stderr", error.get("message", "")))
		_message.show()
	elif loading and rows == 0:
		_loading.show_loading(true, tr("Loading history…"))
	elif loading:
		_loading.show_loading(false, tr("Loading…"))
	else:
		_loading.hide_loading()
		if rows == 0:
			_message.text = tr("No commits match the filter.") if is_filtered() else tr("No commit changed this file.")
			_message.show()
	var reveal: bool = _filter_pending
	_filter_pending = false
	if not _pending_version.is_empty():
		# The version Blame before found is listed now, or never will be.
		var found: int = _list.row_of(_pending_version)
		if found >= 0 or not loading:
			_pending_version = ""
		if found >= 0:
			_list.select_only(found)
			_list.scroll_to_row(found)
			return
	if _list.cursor < 0:
		if rows > 0:
			# The first rows of a new history, or the shown version left it.
			_list.select_only(0)
			if reveal:
				_list.scroll_to_row(0)
			return
		if not _selected.is_empty():
			_selected = ""
			_details_header.hide()
			_diff_panel.clear("")
			if is_blame():
				_blame_selected()
	elif reveal:
		_list.scroll_to_row(_list.cursor)
	_show_details()


## Lists only the commits the field's text matches.
func _on_filter() -> void:
	if session == null or _request.is_empty():
		return
	_filter_pending = true
	_list.set_search(_filter.text())
	session.set_file_history_filter(_filter.text())


## Whether a filter narrows the versions.
func is_filtered() -> bool:
	return not String(_info.get("filter", "")).is_empty()


## Focuses the filter (Find).
func focus_filter() -> void:
	_filter.focus_text()


func _on_version_changed(oid: String, working: bool) -> void:
	_select("working" if working else oid, false)


## Shows version `which` (a commit's oid, or `working`).
func _select(which: String, full: bool) -> void:
	if session == null or which.is_empty():
		return
	_selected = which
	session.select_file_version("" if which == "working" else which, full)
	if is_blame():
		_blame_selected()
	_show_details()
	_on_diff_changed()


## The selected version's commit over its diff (as History shows it):
## what the row says until the commit is read; nothing for the uncommitted
## changes.
func _show_details() -> void:
	if is_blame():
		_show_blame_details()
		return
	var commit: Dictionary = current_version()
	if commit.is_empty():
		_details_header.hide()
		_update_details_split()
		return
	var details: Dictionary = session.file_version_details()
	if String(details.get("oid", "")) != String(commit["oid"]):
		if _details_header.visible and _details_header.commit_oid() == String(commit["oid"]):
			return
		details = {
			"oid": commit["oid"], "parents": PackedStringArray(), "author": commit["author"],
			"email": commit["email"], "time": commit["time"], "committer": commit["author"],
			"committer_email": commit["email"], "commit_time": commit["time"], "summary": commit["subject"],
			"body": "", "coauthors": commit.get("coauthors", []), "refs": [],
		}
	_details_header.show_info(details)
	_details_header.show()
	_update_details_split()


## The details can only be resized while they have a message body.
func _update_details_split() -> void:
	_details.collapsed = not _details_header.visible or not _details_header.has_body()


func _on_diff_changed() -> void:
	if session == null or _selected.is_empty():
		return
	var info: Dictionary = session.slot_diff_info(SLOT)
	if String(info.get("state", "none")) == "none":
		return
	_diff_panel.show_info(info)


func retry() -> void:
	if session == null or not has_history():
		return
	if not (_info.get("error", {}) as Dictionary).is_empty():
		open(String(_request["path"]), String(_request["start"]), String(_request["start_name"]), _blame)
	elif is_blame():
		_blame_selected()
	elif _diff_panel.can_retry():
		_select(_selected, false)


# --- Versions -------------------------------------------------------------------

## The commit under the cursor (`file_history_rows` row), or empty (also for
## the uncommitted changes).
func current_version() -> Dictionary:
	return _list.version_at(_list.cursor)


## Whether the cursor is on the uncommitted changes.
func on_working_row() -> bool:
	return _list.cursor >= 0 and _list.is_working_row(_list.cursor)


## The selected commits, oldest first.
func selected_versions() -> Array[Dictionary]:
	return _list.selected_versions()


## Whether exactly two versions are selected.
func can_compare_versions() -> bool:
	return has_history() and selected_versions().size() == 2 and _list.selected_rows().size() == 2


## Opens Compare on the two selected versions, the older on the left,
## filtered to the file as the newer one names it.
func compare_versions() -> void:
	if not can_compare_versions():
		return
	var pair: Array[Dictionary] = selected_versions()
	compare_requested.emit(String(pair[0]["oid"]), String(pair[1]["oid"]), String(pair[1]["path"]))


## Whether the version under the cursor can be written into the working
## copy: one commit, in which the file exists.
func can_restore() -> bool:
	if session == null or not has_history() or _list.selected_rows().size() != 1:
		return false
	var commit: Dictionary = current_version()
	return not commit.is_empty() and bool(commit.get("exists", false))


## Why Restore is off.
func restore_reason() -> String:
	if on_working_row():
		return tr("These are already your files.")
	var commit: Dictionary = current_version()
	if not commit.is_empty() and not bool(commit.get("exists", false)):
		return tr("This commit deleted the file.")
	return tr("Select one version of the file.")


## Writes the file as the version under the cursor has it into the working
## copy, under the name the history was opened with, with Undo in the toast.
func restore() -> void:
	if not can_restore():
		return
	var commit: Dictionary = current_version()
	var path: String = shown_path()
	var job: int = session.restore_file_version(String(commit["oid"]))
	if feedback != null:
		feedback.track(session, job, "Restoring",
				tr("Restored %s from “%s”") % [path.get_file(), String(commit["subject"])],
				null, Callable(), func() -> void:
					if session.can_undo_discard():
						session.undo_discard())


## Whether a version's file can be opened: a row is shown.
func can_open_version() -> bool:
	return has_history() and not _diff_panel.shown_path().is_empty()


## Opens the file as the shown version has it in the default app (the
## working copy itself for the uncommitted changes).
func open_version() -> void:
	if session != null and can_open_version():
		session.open_version(SLOT, "shown")


## The commit that Open in History and Copy commit hash act on: the blamed
## line's while blaming, else the version under the cursor; "" for none.
func target_commit() -> String:
	if is_blame():
		var line: Dictionary = blame_target()
		return "" if bool(line.get("working", true)) else String(line.get("commit", ""))
	return String(current_version().get("oid", "")) if has_history() else ""


## Whether History can show the commit under the cursor (the blamed line's
## commit while blaming).
func can_show_in_history() -> bool:
	if is_blame():
		return not target_commit().is_empty()
	return has_history() and not current_version().is_empty() and _list.selected_rows().size() == 1


func show_in_history() -> void:
	if can_show_in_history():
		# A history read from HEAD lists only what the current branch has.
		history_requested.emit(target_commit(), String(_request.get("start", "")).is_empty())


func _show_version_menu(row: int, at_position: Vector2) -> void:
	if _list.is_working_row(row) and _list.selected_rows().size() <= 1:
		return
	_show_actions(_version_menu, VERSION_MENU_ACTIONS, _list.get_screen_position() + at_position)


## Fills `menu` with `ids` and opens it.
func _show_actions(menu: PopupMenu, ids: Array[StringName], at: Vector2) -> void:
	menu.clear()
	for i: int in ids.size():
		if ids[i] == &"":
			menu.add_separator()
			continue
		menu.add_icon_item(Actions.icon(ids[i]), Actions.get_action(ids[i]).label, i)
		menu.set_item_disabled(menu.item_count - 1, not Actions.is_enabled(ids[i]))
		if ids[i] == &"diff.toggle_minimap":
			menu.set_item_as_checkable(menu.item_count - 1, true)
			menu.set_item_checked(menu.item_count - 1, Core.diff_minimap())
	menu.position = Vector2i(at)
	menu.reset_size()
	menu.popup()


# --- Blame ----------------------------------------------------------------------

## Whether Blame is on.
func is_blame() -> bool:
	return _blame


## Blame on shows the selected version's blame instead of its diff (with the
## caret on line `line` when it is >= 0); off shows the diff again.
func set_blame(on: bool, line: int = -1) -> void:
	if on == _blame:
		_apply_mode()
		if is_blame() and line >= 0:
			if _blame_view.visible and _blame_view.row_count() > 0:
				_blame_view.go_to_line(line)
			else:
				_pending_line = line
		return
	_blame = on
	_reset_blame()
	_pending_line = line if is_blame() else -1
	_apply_mode()
	if is_blame():
		_blame_selected()
	elif session != null:
		session.close_blame()
	_show_details()


func toggle_blame() -> void:
	set_blame(not _blame)


## What depends on Blame: its switch and the diff or the blame.
func _apply_mode() -> void:
	_blame_button.text = tr("Blame")
	_blame_button.icon = AppTheme.icon(&"User")
	_blame_button.set_pressed_no_signal(_blame)
	_blame_button.tooltip_text = _with_shortcut(tr("Who last changed each line"), &"file_history.blame")
	_blame_button.visible = has_history()
	_diff_panel.visible = not is_blame()
	_blame_box.visible = is_blame()
	_blame_options.tooltip_text = tr("Blame options")
	if not is_blame():
		_list.marked = ""


static func _with_shortcut(text: String, action: StringName) -> String:
	var shortcut: String = Actions.shortcut_label(action)
	return text if shortcut.is_empty() else "%s (%s)" % [text, shortcut]


## Forgets the blame shown (another file, or Blame was turned off).
func _reset_blame() -> void:
	_blame_info = {}
	_blame_key = ""
	_blame_lines = 0
	_blame_note = ""
	_focus_line = {}
	_pending_version = ""
	_pending_line = -1
	_before_line = -1
	_blame_view.hide()
	_blame_message.hide()
	_blame_loading.hide_loading()


## Blames the version under the cursor, with the options set.
func _blame_selected() -> void:
	if session == null or not has_history():
		return
	_blame_note = ""
	if _selected.is_empty():
		session.close_blame()
	else:
		session.blame_file_version("" if _selected == "working" else _selected,
				Core.blame_ignore_whitespace(), Core.blame_detect_moves())
	_on_blame_changed()


## A blame option changed: blame again with it.
func refresh_blame_options() -> void:
	if is_blame():
		_blame_selected()


func _on_blame_changed() -> void:
	if session == null or not is_blame() or not has_history():
		return
	var info: Dictionary = session.blame_info()
	_blame_info = info
	var open: bool = bool(info.get("open", false))
	var state: String = String(info.get("state", "")) if open else "closed"
	var lines: int = int(info.get("lines", 0))
	var key: String = "%s\n%s" % [String(info.get("oid", "")), String(info.get("path", ""))] if open else ""
	var message: String = ""
	match state:
		"closed":
			var commit: Dictionary = current_version()
			if _selected.is_empty():
				message = tr("Select a version to blame.")
			elif not commit.is_empty() and not bool(commit.get("exists", true)):
				message = tr("This commit deleted the file.")
			else:
				message = tr("This version has no file to blame.")
		"binary":
			message = tr("Binary files have no lines to blame.")
		"too_large":
			message = tr("This file is too large to blame.")
		"missing":
			message = tr("The file is not in the working copy.")
		"error":
			var error: Dictionary = info.get("error", {})
			message = tr("Could not blame the file: %s") % String(error.get("stderr", error.get("message", "")))
		"done":
			if lines == 0:
				message = tr("The file is empty.")
	_blame_message.visible = not message.is_empty()
	_blame_message.text = message
	if not message.is_empty():
		_blame_loading.hide_loading()
		_blame_view.hide()
		_blame_key = ""
		_pending_line = -1
	elif lines == 0:
		# The text is being read; a blame that runs again keeps its rows.
		if key != _blame_key:
			_blame_view.hide()
		_blame_loading.show_loading(not _blame_view.visible, tr("Loading file…"))
	else:
		_blame_loading.hide_loading()
		var shown: bool = _blame_view.visible
		_blame_view.show()
		if shown and key == _blame_key and lines == _blame_lines:
			_blame_view.invalidate()
		else:
			_blame_view.show_lines(lines, lines, key == _blame_key)
		_blame_key = key
		_blame_lines = lines
		if _pending_line >= 0:
			_blame_view.go_to_line(_pending_line)
			_pending_line = -1
	if state == "done" and lines > 0 and not String(info.get("focus", "")).is_empty() \
			and session.diff_change_row(BLAME_SLOT, false, 0, true) < 0:
		# This version has no line of the focused commit: let go of it.
		_blame_info["focus"] = ""
		session.focus_blame_commit("")
	_list.marked = String(_blame_info.get("focus", "")) if open else ""
	_update_blame_bar()
	_show_blame_details()


## The strip: the version blamed, then how far git is or what it found.
func _update_blame_bar() -> void:
	var commit: Dictionary = current_version()
	if on_working_row():
		_blame_version.text = tr("Working copy")
		_blame_version.tooltip_text = tr("The file as it is on disk, uncommitted lines included")
	elif commit.is_empty():
		_blame_version.text = ""
		_blame_version.tooltip_text = ""
	else:
		_blame_version.text = tr("As of %s") % ("%s  %s" % [String(commit["oid"]).left(7), String(commit["subject"])])
		_blame_version.tooltip_text = tr("The file as this commit left it")
	var lines: int = int(_blame_info.get("lines", 0))
	if not _blame_note.is_empty():
		_blame_status.text = _blame_note
	elif not bool(_blame_info.get("open", false)) or lines == 0 or _blame_message.visible:
		_blame_status.text = ""
	elif bool(_blame_info.get("loading", false)):
		_blame_status.text = tr("Blaming… %d%%") % int(100.0 * int(_blame_info.get("blamed", 0)) / lines)
	else:
		_blame_status.text = "%s · %s" % [DiffView.lines_text(lines),
				ListHeader.count_text(int(_blame_info.get("commits", 0)), "commit")]


## The focused commit over the blame: what its line says until the commit
## is read; nothing without a focus, or for lines not committed yet.
func _show_blame_details() -> void:
	var focus: String = String(_blame_info.get("focus", ""))
	var details: Dictionary = session.blame_details() if session != null and not focus.is_empty() else {}
	if String(details.get("oid", "")) != focus or focus.is_empty():
		if not focus.is_empty() and _details_header.visible and _details_header.commit_oid() == focus:
			return
		if focus.is_empty() or String(_focus_line.get("commit", "")) != focus or bool(_focus_line.get("working", true)):
			_details_header.hide()
			_update_details_split()
			return
		details = {
			"oid": focus, "parents": PackedStringArray(), "author": _focus_line["author"],
			"email": _focus_line["email"], "time": _focus_line["time"], "committer": _focus_line["author"],
			"committer_email": _focus_line["email"], "commit_time": _focus_line["time"],
			"summary": _focus_line["summary"], "body": "", "coauthors": [], "refs": [],
		}
	_details_header.show_info(details)
	_details_header.show()
	_update_details_split()


## A line's gutter was clicked: focuses its commit, or lets go of it when it
## has the focus already.
func _on_commit_clicked(oid: String, row: int) -> void:
	if session == null:
		return
	_focus_line = session.blame_line(row)
	session.focus_blame_commit("" if oid == String(_blame_info.get("focus", "")) else oid)


## The commit the blame has the focus on ("" for none).
func blame_focus() -> String:
	return String(_blame_info.get("focus", "")) if is_blame() else ""


## The line the blame's actions act on: the caret's, else the first of the
## focused commit's; -1 without one.
func blame_target_row() -> int:
	if session == null or not is_blame() or not _blame_view.visible:
		return -1
	if _blame_view.cursor >= 0 or blame_focus().is_empty():
		return _blame_view.cursor
	return session.diff_change_row(BLAME_SLOT, false, _blame_view.row_count() - 1, true)


## What blame says of that line (`RepoSession.blame_line`), or empty.
func blame_target() -> Dictionary:
	var row: int = blame_target_row()
	return session.blame_line(row) if row >= 0 else {}


## Whether the blamed line has an earlier version to blame.
func can_blame_before() -> bool:
	return not String(blame_target().get("previous", "")).is_empty()


func blame_before_reason() -> String:
	var line: Dictionary = blame_target()
	if line.is_empty():
		return tr("Select a line of the blame.")
	if bool(line.get("working", false)):
		return tr("This line is not committed yet.")
	return tr("This commit added the file.")


## Blames the file as it was before the blamed line's commit: selects the
## version the line came from.
func blame_before() -> void:
	if not can_blame_before():
		return
	var row: int = blame_target_row()
	_blame_note = ""
	session.blame_before(row)
	_before_line = row


func _on_blame_version(oid: String) -> void:
	if not is_blame():
		return
	var line: int = _before_line
	_before_line = -1
	if oid.is_empty():
		_blame_note = tr("No earlier version in this file's history.")
		_update_blame_bar()
		return
	# The version's blame puts the caret back on the line.
	_pending_line = line
	var row: int = _list.row_of(oid)
	if row >= 0:
		_list.select_only(row)
		_list.scroll_to_row(row)
		return
	# Hidden by the filter, or not listed yet.
	_pending_version = oid
	if is_filtered():
		_filter.set_text("")
		_on_filter()


## Whether the blamed line's commit is one of the versions.
func can_show_blame_changes() -> bool:
	var oid: String = target_commit()
	return is_blame() and not oid.is_empty() and _list.row_of(oid) >= 0


func show_blame_changes_reason() -> String:
	var line: Dictionary = blame_target()
	if line.is_empty():
		return tr("Select a line of the blame.")
	if bool(line.get("working", false)):
		return tr("This line is not committed yet.")
	return tr("That commit is not among the versions listed.")


## Blame off, on the blamed line's commit: what it changed in the file.
func show_blame_changes() -> void:
	if not can_show_blame_changes():
		return
	var row: int = _list.row_of(target_commit())
	set_blame(false)
	_list.select_only(row)
	_list.scroll_to_row(row)


func _show_blame_options() -> void:
	_blame_options_menu.position = Vector2i(_blame_options.get_screen_position()
			+ Vector2(0.0, _blame_options.size.y))
	_blame_options_menu.reset_size()
	_blame_options_menu.popup()


func _update_blame_options() -> void:
	var checked: Array[bool] = [Core.blame_ignore_whitespace(), Core.blame_detect_moves()]
	for i: int in BLAME_OPTIONS.size():
		HistoryView.show_check_action(_blame_options_menu, i, BLAME_OPTIONS[i][0], BLAME_OPTIONS[i][1], checked[i])


## The blame's minimap follows the diffs' (`DiffPanel.GROUP`).
func set_minimap_enabled(value: bool) -> void:
	_blame_view.set_minimap_enabled(value)


func _on_blame_key(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", false, true) and _blame_view.h_scroll() <= 0.0 and _left.visible:
		_list.grab_focus()
		_blame_view.accept_event()


# --- The bar --------------------------------------------------------------------

func _update_bar() -> void:
	if not is_node_ready():
		return
	_icon.texture = AppTheme.icon(&"TextFile")
	_path.path = shown_path()
	var names: PackedStringArray = _info.get("names", PackedStringArray())
	var tip: PackedStringArray = PackedStringArray([shown_path()])
	for i: int in range(1, names.size()):
		tip.append(tr("Also: %s") % names[i])
	_path.tooltip_text = "\n".join(tip)
	var start_name: String = String(_request.get("start_name", ""))
	var fixed: bool = not String(_request.get("start", "")).is_empty()
	if start_name.is_empty():
		start_name = String(_request.get("start", "")).left(7)
	_start.visible = fixed
	_start.text = tr("as of %s") % (start_name if start_name.length() <= MAX_START_CHARS
			else start_name.left(MAX_START_CHARS - 1) + "…")
	_start.tooltip_text = "\n".join(PackedStringArray([
		tr("The history is read from here, not from the current branch."), start_name,
		String(_request.get("start", ""))]))
	# The field counts the filter's matches, as History's search does.
	if not _filter.is_node_ready():
		return
	var matches: int = int(_info.get("count", 0))
	if not has_history() or not is_filtered():
		_filter.set_count("")
	elif matches == 0 and not bool(_info.get("loading", true)):
		_filter.set_count(tr("No matches"), true)
	else:
		_filter.set_count(ListHeader.number_text(matches))


func _apply_theme() -> void:
	_left.custom_minimum_size.x = float(get_theme_constant(&"min_left_width", &"Panes"))
	_update_bar()


# --- Keys and menus -------------------------------------------------------------

## Right in the versions moves into the diff (or the blame).
func _on_list_key(event: InputEvent) -> void:
	var view: DiffView = _blame_view if is_blame() else _diff_panel.view()
	if event.is_action_pressed("ui_right", false, true) and view.row_count() > 0:
		view.grab_focus()
		if view.cursor < 0:
			view.select_only(0)
		_list.accept_event()


func _on_diff_key(event: InputEvent) -> void:
	var view: DiffView = _diff_panel.view()
	if event.is_action_pressed("ui_left", false, true) and view.h_scroll() <= 0.0:
		_list.grab_focus()
		view.accept_event()


func _show_diff_menu(_row: int, at_position: Vector2) -> void:
	_show_actions(_menu, DIFF_MENU_ACTIONS, _diff_panel.view().get_screen_position() + at_position)


## Focuses the versions (the blame when they are hidden).
func focus_files() -> void:
	if _left.visible:
		_list.grab_focus()
	else:
		_blame_view.grab_focus()


# --- For the shell and tests ----------------------------------------------------

## The split between the versions and the details (its offset is the
## shared left-pane width).
func files_split() -> HSplitContainer:
	return _split


## The details over the diff (its offset is the details' height, shared
## with History).
func details_split() -> VSplitContainer:
	return _details


func left_pane() -> Control:
	return _left


func version_list() -> FileHistoryList:
	return _list


## The selected version's commit (hidden for the uncommitted changes).
func details_header() -> CommitHeader:
	return _details_header


func diff_panel() -> DiffPanel:
	return _diff_panel


## The bar's path, its "as of …" chip and its commit count.
func path_label() -> PathLabel:
	return _path


func start_text() -> String:
	return _start.text if _start.visible else ""


## Whether the versions are still being read.
func is_loading() -> bool:
	return has_history() and bool(_info.get("loading", true))


## What the filter's field says of its matches, or "".
func filter_count_text() -> String:
	return _filter.count_text()


## The message shown instead of versions (an error, no commits), or "".
func message_text() -> String:
	return _message.text if _message.visible else ""


func loading_indicator() -> LoadingIndicator:
	return _loading


func version_menu() -> PopupMenu:
	return _version_menu


## The field that filters the versions, its options button and their menu.
func filter_field() -> FilterField:
	return _filter


func options_button() -> Button:
	return _options_button


func options_menu() -> PopupMenu:
	return _options_menu


func diff_menu() -> PopupMenu:
	return _menu


## The blame: its lines, the strip over them and what it says, the message
## shown instead of lines (or ""), the menus.
func blame_view() -> BlameView:
	return _blame_view


func blame_version_text() -> String:
	return _blame_version.text


func blame_status_text() -> String:
	return _blame_status.text


func blame_message_text() -> String:
	return _blame_message.text if _blame_message.visible else ""


func blame_menu() -> PopupMenu:
	return _blame_menu


func blame_options_button() -> Button:
	return _blame_options


func blame_options_menu() -> PopupMenu:
	return _blame_options_menu


func blame_button() -> Button:
	return _blame_button
