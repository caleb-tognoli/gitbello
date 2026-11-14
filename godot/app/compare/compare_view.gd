class_name CompareView
extends VBoxContainer
## Compare (PLAN M7.12, laid out like History in M7.12c): two states of a
## worktree's repository. A bar on top with the left side (the base) ⇄ the
## right side, the commits only on each side and, at the right, the recent
## comparisons. Below, like History: the comparison's commits on the left
## (All changes, then each side's own commits) and, on the right, the
## selected commit's details over its files beside the diff of the selected
## file. Diffs read left → right and are read-only. The files are what the
## right side changed since the fork; when the left side has commits of its
## own, the Include pill on their section switches All changes to the full
## difference. Several commits
## can be cherry-picked; a file's menu restores it from either side (with
## Undo). Each side is a chip that opens a `ComparePicker`. A working-copy
## side follows the files; ref sides follow the refs.

## The user closed the comparison.
signal closed()
## A ref chip was clicked: show the menu of `label` (`RefChip.ref_target`)
## at `at_position` (screen), over the popup `over` (or null).
signal label_menu_requested(label: Dictionary, at_position: Vector2, over: Window)

const FILTER_FIELD: PackedScene = preload("res://ui/filter_field/filter_field.tscn")
const LIST_HEADER: PackedScene = preload("res://ui/list_header/list_header.tscn")
const DIFF_PANEL: PackedScene = preload("res://ui/diff_view/diff_panel.tscn")
const COMMIT_HEADER: PackedScene = preload("res://app/history/commit_header.tscn")
## The diff's context menu: its actions, by item id.
const DIFF_MENU_ACTIONS: Array[StringName] = [&"diff.copy", &"diff.select_all", &"", &"diff.open_file",
	&"file_history.open", &"", &"diff.toggle_minimap"]
## The file list's context menu.
const FILE_MENU_ACTIONS: Array[StringName] = [&"compare.restore_left", &"compare.restore_right", &"",
	&"diff.open_file", &"file_history.open"]
## The commit list's context menu.
const COMMIT_MENU_ACTIONS: Array[StringName] = [&"compare.cherry_pick", &"", &"compare.copy_hash"]
## Icons of the sides, by `compare_info` side kind.
const SIDE_ICONS: Dictionary[String, StringName] = {
	"branch": &"GitBranch", "remote": &"GitRemote", "tag": &"GitTag", "commit": &"GitCommit", "working": &"FileList",
}
## Characters of a side's name on its chip (the tooltip has all of it).
const MAX_CHIP_CHARS: int = 40

var session: RepoSession = null:
	set = set_session
## Shows Restore's progress and its Undo; set by the worktree view.
var feedback: Feedback = null
## Runs cherry-picks (confirmation, progress, the operation banner); set by
## the worktree view.
var ops: RepoOps = null
## Formats unix times (the history's format), for the details' date.
var date_format: Callable = Callable():
	set(value):
		date_format = value
		_details_header.date_format = value

## The request shown (`{left, right, working, mode}`), or empty.
var _request: Dictionary = {}
var _info: Dictionary = {}
## The request last saved among the recent comparisons.
var _recorded: Dictionary = {}

var _bar: PanelContainer = PanelContainer.new()
var _left_button: Button = Button.new()
var _swap_button: Button = Button.new()
var _right_button: Button = Button.new()
var _counts: SyncCounts = SyncCounts.new()
var _recent_button: Button = Button.new()
var _recent: CompareRecentPopover = CompareRecentPopover.new()
## The commits | the details (the shared left-pane width).
var _split: HSplitContainer = HSplitContainer.new()
var _left: VBoxContainer = VBoxContainer.new()
var _commits: CompareCommitList = CompareCommitList.new()
var _refs_popover: RefsPopover = RefsPopover.new()
## The selected commit's details over the files and diff (as History's).
var _details: VSplitContainer = VSplitContainer.new()
var _details_header: CommitHeader = COMMIT_HEADER.instantiate() as CommitHeader
var _files_split: HSplitContainer = HSplitContainer.new()
var _files_box: VBoxContainer = VBoxContainer.new()
var _filter: FilterField = FILTER_FIELD.instantiate() as FilterField
var _header: ListHeader = LIST_HEADER.instantiate() as ListHeader
var _files: CompareFileList = CompareFileList.new()
var _message: Label = Label.new()
## Instead of files: no differences, or the filter hides them all.
var _empty: EmptyState = EmptyState.create_compact()
var _diff_panel: DiffPanel = DIFF_PANEL.instantiate() as DiffPanel
var _picker: ComparePicker = ComparePicker.new()
## Which side the picker is choosing: `left` or `right`.
var _picking: String = ""
var _loading: LoadingIndicator = LoadingIndicator.new()
var _menu: PopupMenu = PopupMenu.new()
var _file_menu: PopupMenu = PopupMenu.new()
var _commit_menu: PopupMenu = PopupMenu.new()


func _ready() -> void:
	theme_type_variation = &"PaneColumn"
	_build_bar()
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_split)
	_left.theme_type_variation = &"PaneColumn"
	_split.add_child(_left)
	_commits.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left.add_child(_commits)
	_commits.focus_changed.connect(focus_commit)
	_commits.include_toggled.connect(func() -> void: Actions.run_action(&"compare.full_difference"))
	_commits.context_menu_requested.connect(_on_commit_context)
	_commits.refs_requested.connect(func(_row: int, at: Vector2, labels: Array) -> void:
		_refs_popover.open_at(labels, _commits.get_screen_transform() * at))
	add_child(_refs_popover)
	_refs_popover.menu_requested.connect(label_menu_requested.emit)
	_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details.dragger_visibility = SplitContainer.DRAGGER_HIDDEN_COLLAPSED
	_split.add_child(_details)
	_details_header.copy_action = &"compare.copy_hash"
	_details_header.links_parents = false
	_details_header.hide()
	_details.add_child(_details_header)
	_details_header.body_shown.connect(func(_shown: bool) -> void: _update_details_split())
	_details_header.label_menu_requested.connect(label_menu_requested.emit)
	_files_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_details.add_child(_files_split)
	_build_files()
	_diff_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_files_split.add_child(_diff_panel)
	_wire_diff()
	add_child(_picker)
	_picker.side_chosen.connect(_on_side_chosen)
	add_child(_recent)
	_recent.chosen.connect(func(recent: Dictionary) -> void:
		open(String(recent["left"]), String(recent["right"]), bool(recent["working"]), String(recent["mode"])))
	for entry: Array in [[_menu, DIFF_MENU_ACTIONS], [_file_menu, FILE_MENU_ACTIONS],
			[_commit_menu, COMMIT_MENU_ACTIONS]]:
		var menu: PopupMenu = entry[0]
		var ids: Array[StringName] = entry[1]
		add_child(menu)
		menu.id_pressed.connect(func(id: int) -> void: Actions.run_action(ids[id]))
	_apply_theme()
	_update_bar()


func _build_bar() -> void:
	_bar.theme_type_variation = &"CompareBar"
	add_child(_bar)
	var row: HBoxContainer = HBoxContainer.new()
	row.theme_type_variation = &"HeaderRow"
	_bar.add_child(row)
	for button: Button in [_swap_button, _recent_button]:
		button.theme_type_variation = &"ToolbarButton"
		button.focus_mode = Control.FOCUS_NONE
	_swap_button.pressed.connect(func() -> void: Actions.run_action(&"compare.swap", _swap_button))
	_recent_button.pressed.connect(func() -> void: Actions.run_action(&"compare.recent", _recent_button))
	for entry: Array in [[_left_button, "left"], [_right_button, "right"]]:
		var button: Button = entry[0]
		var which: String = entry[1]
		button.theme_type_variation = &"SegmentButton"
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(func() -> void: pick_side(which))
	row.add_child(_left_button)
	row.add_child(_swap_button)
	row.add_child(_right_button)
	row.add_child(_counts)
	_counts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_counts.mouse_filter = Control.MOUSE_FILTER_PASS
	var divider: VSeparator = VSeparator.new()
	divider.theme_type_variation = &"HeaderDivider"
	row.add_child(divider)
	row.add_child(_recent_button)


## The files' column: the filter, the count and the list.
func _build_files() -> void:
	_files_box.theme_type_variation = &"PaneColumn"
	_files_split.add_child(_files_box)
	var filter_bar: PanelContainer = PanelContainer.new()
	filter_bar.theme_type_variation = &"FilterBar"
	_filter.placeholder = tr("Filter changed files")
	filter_bar.add_child(_filter)
	_files_box.add_child(filter_bar)
	_filter.changed.connect(_on_filter)
	_filter.done.connect(func() -> void: _files.grab_focus())
	_files_box.add_child(_header)
	_files.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_files_box.add_child(_files)
	_files.current_changed.connect(_on_file_changed)
	_files.gui_input.connect(_on_files_key)
	_files.context_menu_requested.connect(_show_file_menu)
	_files.add_child(_loading)
	_message.theme_type_variation = &"DimLabel"
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_message.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_message.hide()
	_files.add_child(_message)
	_files.add_child(_empty)


func _wire_diff() -> void:
	_diff_panel.set_source(func(start: int, count: int) -> Array:
		return session.compare_diff_lines(start, count) if session != null else [])
	_diff_panel.set_image_source(func(side: String) -> Dictionary:
		return session.image_side("compare", side) if session != null else {})
	_diff_panel.set_split_source(func(start: int, count: int) -> Array:
		return session.diff_split_rows("compare", start, count) if session != null else [])
	_diff_panel.set_minimap_sources(
		func(split: bool, first: int, rows: int, columns: int, row_px: int, char_px: int,
				palette: PackedColorArray) -> PackedByteArray:
			if session == null:
				return PackedByteArray()
			return session.diff_minimap_tile("compare", split, first, rows, columns, row_px, char_px, palette),
		func(split: bool, buckets: int) -> PackedByteArray:
			return session.diff_overview("compare", split, buckets, true) if session != null else PackedByteArray(),
		func(split: bool, row: float) -> float:
			return session.diff_strip_position("compare", split, row, true) if session != null else 0.0,
		func(split: bool, fraction: float) -> Dictionary:
			return session.diff_strip_target("compare", split, fraction, true) if session != null else {})
	_diff_panel.set_change_source(func(split: bool, from_row: int, forward: bool) -> int:
		return session.diff_change_row("compare", split, from_row, forward) if session != null else -1)
	_diff_panel.load_full_requested.connect(func() -> void:
		session.select_compare_file(String(session.compare_diff_info().get("path", "")), true))
	_diff_panel.expand_requested.connect(func(gap: int, how: String) -> void:
		session.expand_diff("compare", gap, how))
	_diff_panel.whole_file_requested.connect(func(whole: bool) -> void:
		session.show_whole_diff("compare", whole))
	_diff_panel.view().gui_input.connect(_on_diff_key)
	_diff_panel.view().context_menu_requested.connect(_show_diff_menu)
	_diff_panel.open_side_requested.connect(func(side: String) -> void:
		if session != null:
			session.open_version("compare", side))
	_diff_panel.clear("No file selected")


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _loading.get_parent() == null:
		_loading.free()
		_empty.free()
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		_filter.placeholder = tr("Filter changed files")
		_update_bar()
		if session != null:
			_on_compare_changed()


func set_session(value: RepoSession) -> void:
	if session != null:
		session.compare_changed.disconnect(_on_compare_changed)
		session.compare_diff_changed.disconnect(_on_diff_changed)
	session = value
	_files.session = session
	_commits.session = session
	_details_header.session = session
	_picker.session = session
	_request = {}
	if session != null:
		session.compare_changed.connect(_on_compare_changed)
		session.compare_diff_changed.connect(_on_diff_changed)


# --- Opening and closing --------------------------------------------------------

## Opens a comparison of `left` with `right` (or the working copy when
## `working`); `mode` is `fork`, `exact` or "" for the default (since the
## fork); `filter` starts the file filter with a path.
func open(left: String, right: String, working: bool, mode: String = "", filter: String = "") -> void:
	if session == null:
		return
	var request: Dictionary = {"left": left, "right": "" if working else right, "working": working, "mode": mode}
	# Clearing the field must not filter (and select in) the comparison
	# being replaced.
	_request = {}
	_filter.set_text("")
	_request = request
	_info = {}
	_files.show_files(0)
	_commits.show_commits({}, "", "", "")
	_details_header.hide()
	_diff_panel.clear("No file selected")
	session.open_compare(left, right, working, mode)
	if not filter.is_empty():
		_filter.set_text(filter)
	_on_compare_changed()


func has_comparison() -> bool:
	return not _request.is_empty()


## The comparison shown: `{left, right, working, mode}`, or empty.
func shown_request() -> Dictionary:
	return _request.duplicate()


func close() -> void:
	if session != null:
		session.close_compare()
	_request = {}
	_info = {}
	_files.show_files(0)
	_commits.show_commits({}, "", "", "")
	closed.emit()


## Whether the sides can swap: not while the working copy is a side (it is
## always on the right).
func can_swap() -> bool:
	return has_comparison() and not bool(_request.get("working", false))


func swap() -> void:
	if not can_swap():
		return
	open(String(_request["right"]), String(_request["left"]), false, String(_request["mode"]))


## `fork` or `exact`; since the fork only when the sides share history.
func set_mode(mode: String) -> void:
	if not has_comparison() or session == null:
		return
	if mode == "fork" and not bool(_info.get("can_fork", true)):
		return
	_request["mode"] = mode
	session.set_compare_mode(mode)
	_on_compare_changed()


func shown_mode() -> String:
	return String(_info.get("mode", _request.get("mode", "")))


## Whether the files are the full difference (asked for, or the sides share
## no history) rather than what the right side changed since the fork.
func shows_full_difference() -> bool:
	return shown_mode() == "exact"


## Switches All changes between the changes since the fork and the full
## difference (the Include pill), and selects All changes to show it.
func toggle_full_difference() -> void:
	if not can_toggle_full_difference():
		return
	var mode: String = "fork" if shows_full_difference() else "exact"
	if not focused_commit().is_empty():
		session.focus_compare_commit("")
		_files.show_files(0)
	set_mode(mode)


## Whether the full difference can be toggled: the sides share history and
## the left side has commits of its own (otherwise both give the same files).
func can_toggle_full_difference() -> bool:
	return has_comparison() and bool(_info.get("can_fork", false)) \
			and (int(_info.get("only_left", 0)) > 0 or shows_full_difference())


## Opens the picker of `which` side (`left` or `right`) under its chip.
func pick_side(which: String) -> void:
	if not has_comparison() or not is_visible_in_tree():
		return
	_picking = which
	var right: bool = which == "right"
	var current: String = String(_request["right"] if right else _request["left"])
	_picker.open_below(_right_button if right else _left_button, right, current)


func picker() -> ComparePicker:
	return _picker


func _on_side_chosen(spec: String, working: bool) -> void:
	if _picking == "left":
		open(spec, String(_request["right"]), bool(_request["working"]))
	else:
		open(String(_request["left"]), spec, working)


## The repository's recent comparisons, newest first, without the open one.
func recent_comparisons() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if session == null:
		return out
	for entry: Dictionary in Core.compare_recent(_repo_key()):
		if String(entry["left"]) != String(_request.get("left", "")) \
				or bool(entry["working"]) != bool(_request.get("working", false)) \
				or (not bool(entry["working"]) and String(entry["right"]) != String(_request.get("right", ""))):
			out.append(entry)
	return out


## Opens the recent comparisons under the bar's Recent button.
func show_recent() -> void:
	if not has_comparison() or not is_visible_in_tree():
		return
	_recent.open_below(_recent_button, recent_comparisons())


func recent_popover() -> CompareRecentPopover:
	return _recent


## Recent comparisons are kept per repository, under its main worktree.
func _repo_key() -> String:
	var main: String = session.main_worktree()
	return main if not main.is_empty() else session.toplevel()


# --- State ----------------------------------------------------------------------

func _on_compare_changed() -> void:
	if session == null or _request.is_empty():
		return
	_info = session.compare_info()
	_update_bar()
	var state: String = String(_info.get("state", "none"))
	_message.hide()
	_empty.hide()
	match state:
		"loading":
			_loading.show_loading(true, tr("Comparing…"))
			_header.set_text("")
			_header.show_counts(0, 0)
		"error":
			_loading.hide_loading()
			_files.show_files(0)
			_commits.show_commits({}, "", "", "")
			_details_header.hide()
			_header.set_text("")
			_header.show_counts(0, 0)
			_message.text = _error_text(_info.get("error", {}))
			_message.show()
			_diff_panel.clear("")
		"ready":
			_remember()
			_commits.show_commits(_info, _side_name("left"), _side_name("right"), focused_commit())
			_show_details()
			match String(_info.get("focus_state", "none")):
				"loading":
					_loading.show_loading(true, tr("Loading commit…"))
					_files.show_files(0)
					_header.set_text("")
					_header.show_counts(0, 0)
					return
				"error":
					_loading.hide_loading()
					_files.show_files(0)
					_message.text = tr("Could not compare: %s") % String(
							(_info.get("focus_error", {}) as Dictionary).get("stderr", ""))
					_message.show()
					return
			if bool(_info.get("reloading", false)):
				_loading.show_loading(false, tr("Updating…"))
			else:
				_loading.hide_loading()
			_show_files()


## Saves the comparison among the repository's recent ones once it loaded.
func _remember() -> void:
	if _recorded == _request:
		return
	_recorded = _request.duplicate()
	# Commit sides keep their subjects, to list them by name.
	var names: PackedStringArray = PackedStringArray()
	for which: String in ["left", "right"]:
		var side_name: String = _side_name(which)
		names.append("" if side_name == String(_request[which]) else side_name)
	var error: String = Core.add_compare_recent(_repo_key(), String(_request["left"]), String(_request["right"]),
			bool(_request["working"]), String(_request["mode"]), names[0], names[1])
	if not error.is_empty():
		push_warning(error)


func _show_files() -> void:
	var total: int = int(_info.get("file_count", 0))
	var shown: int = int(_info.get("shown_count", 0))
	var text: String = ListHeader.count_text(total, "changed file")
	if shown != total:
		text = tr("%d of %s") % [shown, text]
	_header.set_text(text)
	_header.show_counts(int(_info.get("additions", 0)), int(_info.get("deletions", 0)))
	var keep: String = _files.path_at(_files.cursor)
	if keep.is_empty():
		keep = String(session.compare_diff_info().get("path", ""))
	_files.show_files(shown, keep)
	if _files.cursor < 0 and shown > 0:
		_files.select_only(0)
	if total == 0:
		if focused_commit().is_empty():
			_empty.show_compact(&"GitCompare", "No differences")
		else:
			_empty.show_compact(&"FileList", "No changed files")
		_empty.show()
		_diff_panel.blank()
	elif shown == 0:
		_empty.show_no_match(func() -> void: _filter.clear_filters())
		_empty.show()
		_diff_panel.blank()
	else:
		_empty.hide()


## The focused commit's details over the files (as History shows them);
## nothing for All changes.
func _show_details() -> void:
	var details: Dictionary = session.compare_focus_details() if not focused_commit().is_empty() else {}
	if details.is_empty() or not String(details.get("oid", "")).begins_with(focused_commit()):
		_details_header.hide()
	else:
		_details_header.show_info(details)
		_details_header.show()
	_update_details_split()


## The details can only be resized while they have a message body.
func _update_details_split() -> void:
	_details.collapsed = not _details_header.visible or not _details_header.has_body()


## What a failed comparison says.
func _error_text(error: Dictionary) -> String:
	if String(error.get("kind", "")) == "unknown_revision":
		return tr("Unknown revision: %s. Pick another side.") % _unknown_side()
	return tr("Could not compare: %s") % String(error.get("stderr", error.get("message", "")))


## The side git did not know, as asked.
func _unknown_side() -> String:
	var stderr: String = String((_info.get("error", {}) as Dictionary).get("stderr", ""))
	for side: String in [String(_request.get("left", "")), String(_request.get("right", ""))]:
		if not side.is_empty() and stderr.contains("`%s`" % side.strip_edges()):
			return side
	return String(_request.get("left", ""))


func _on_filter() -> void:
	if session == null or not has_comparison():
		return
	session.set_compare_filter(_filter.text())
	_info = session.compare_info()
	if String(_info.get("state", "")) == "ready" and String(_info.get("focus_state", "none")) in ["none", "ready"]:
		_message.hide()
		_empty.hide()
		_show_files()


func _on_file_changed(path: String) -> void:
	if session == null:
		return
	if path.is_empty():
		session.clear_compare_diff()
		return
	session.select_compare_file(path, false)
	_on_diff_changed()


func _on_diff_changed() -> void:
	if session == null:
		return
	var info: Dictionary = session.compare_diff_info()
	if String(info.get("state", "none")) == "none":
		return
	_diff_panel.show_info(info)


func retry() -> void:
	if session == null or not has_comparison():
		return
	if String(_info.get("state", "")) == "error":
		session.reload_compare()
		_on_compare_changed()
	elif _diff_panel.can_retry():
		session.select_compare_file(String(session.compare_diff_info().get("path", "")), false)
		_on_diff_changed()


# --- Commits --------------------------------------------------------------------

## The commit the files are narrowed to, or "".
func focused_commit() -> String:
	return String(_info.get("focus", ""))


## Narrows the files to commit `oid`'s own ("" for all of them), and
## selects it in the list.
func focus_commit(oid: String) -> void:
	if session == null or not has_comparison() or oid == focused_commit():
		return
	session.focus_compare_commit(oid)
	_files.show_files(0)
	_on_compare_changed()


## The selected commits, oldest first.
func selected_commits() -> Array[Dictionary]:
	return _commits.selected_commits()


## Whether the selected commits can be cherry-picked onto HEAD: none of
## them already there, a merge commit only alone, nothing in progress.
func can_cherry_pick() -> bool:
	var commits: Array[Dictionary] = selected_commits()
	if commits.is_empty() or session == null or not session.operation().is_empty():
		return false
	for commit: Dictionary in commits:
		if bool(commit["in_head"]) or (commits.size() > 1 and int(commit["parents"]) > 1):
			return false
	return true


func cherry_pick_reason() -> String:
	var commits: Array[Dictionary] = selected_commits()
	if commits.is_empty():
		return tr("Select commits in the comparison.")
	if session != null and not session.operation().is_empty():
		return tr("Finish the operation in progress first.")
	for commit: Dictionary in commits:
		if bool(commit["in_head"]):
			return tr("%s is already in the current branch.") % ("“%s”" % String(commit["subject"]))
		if commits.size() > 1 and int(commit["parents"]) > 1:
			return tr("A merge commit can only be cherry-picked alone.")
	return ""


func cherry_pick() -> void:
	if not can_cherry_pick() or ops == null:
		return
	var commits: Array[Dictionary] = selected_commits()
	if commits.size() == 1:
		ops.cherry_pick(String(commits[0]["oid"]), String(commits[0]["subject"]))
		return
	var oids: PackedStringArray = PackedStringArray()
	for commit: Dictionary in commits:
		oids.append(String(commit["oid"]))
	ops.cherry_pick_commits(oids)


## A right-click on a ref chip is that ref's menu; elsewhere the commits'.
func _on_commit_context(row: int, at_position: Vector2) -> void:
	var label: Dictionary = _commits.label_at(row, at_position)
	if not label.is_empty():
		label_menu_requested.emit(label, _commits.get_screen_position() + at_position, null)
		return
	if _commits.kind_at(row) != "commit":
		return
	var onto: String = session.current_branch() if session != null else ""
	_show_actions(_commit_menu, COMMIT_MENU_ACTIONS, _commits.get_screen_position() + at_position, {
		&"compare.cherry_pick": tr("Cherry-pick onto %s") % (onto if not onto.is_empty() else "HEAD"),
	})


# --- Files ----------------------------------------------------------------------

## The file under the cursor in the list, or "".
func current_file() -> String:
	return _files.path_at(_files.cursor)


## Where the current file's history is read from: `{start, start_name}`,
## the commit the files are narrowed to, else the right side ("" for the
## working copy: HEAD).
func file_history_start() -> Dictionary:
	if not focused_commit().is_empty():
		return {"start": focused_commit(), "start_name": _details_header.summary_text()}
	if bool(_request.get("working", false)):
		return {"start": "", "start_name": ""}
	var side: Dictionary = _info.get("right", {})
	return {"start": String(side.get("oid", _request.get("right", ""))), "start_name": _side_name("right")}


## Whether the current file can be restored from `which` side (`left` or
## `right`): not from the working copy.
func can_restore(which: String) -> bool:
	if session == null or not has_comparison() or current_file().is_empty():
		return false
	if String(_info.get("state", "")) != "ready":
		return false
	return which == "left" or focused_commit() != "" or not bool(_request.get("working", false))


## Writes the current file as `which` side has it into the working copy,
## with Undo in the toast.
func restore(which: String) -> void:
	if not can_restore(which):
		return
	var path: String = current_file()
	var job: int = session.restore_compare_files(PackedStringArray([path]), which)
	if feedback != null:
		feedback.track(session, job, "Restoring", tr("Restored %s from %s") % [path.get_file(), restore_side_name(which)],
				null, Callable(), func() -> void:
					if session.can_undo_discard():
						session.undo_discard())


## What Restore names a side: a narrowed commit's sides are its parent and
## itself.
func restore_side_name(which: String) -> String:
	if focused_commit().is_empty():
		return _side_name(which)
	return tr("the parent commit") if which == "left" else tr("this commit")


func _show_file_menu(_row: int, at_position: Vector2) -> void:
	_show_actions(_file_menu, FILE_MENU_ACTIONS, _files.get_screen_position() + at_position, {
		&"compare.restore_left": tr("Restore from %s") % restore_side_name("left"),
		&"compare.restore_right": tr("Restore from %s") % restore_side_name("right"),
	})


## Fills `menu` with `ids` (labels from `labels` where given) and opens it.
func _show_actions(menu: PopupMenu, ids: Array[StringName], at: Vector2, labels: Dictionary) -> void:
	menu.clear()
	for i: int in ids.size():
		if ids[i] == &"":
			menu.add_separator()
			continue
		var label: String = String(labels.get(ids[i], Actions.get_action(ids[i]).label))
		menu.add_icon_item(Actions.icon(ids[i]), label, i)
		menu.set_item_disabled(menu.item_count - 1, not Actions.is_enabled(ids[i]))
	menu.position = Vector2i(at)
	menu.reset_size()
	menu.popup()


# --- The bar --------------------------------------------------------------------

func _update_bar() -> void:
	if not is_node_ready():
		return
	_swap_button.icon = AppTheme.icon(&"Swap")
	_swap_button.disabled = not can_swap()
	_swap_button.tooltip_text = Actions.tooltip(&"compare.swap") if can_swap() \
			else tr("The working copy stays on the right.")
	_recent_button.icon = AppTheme.icon(&"History")
	_recent_button.tooltip_text = Actions.tooltip(&"compare.recent")
	_show_side(_left_button, "left")
	_show_side(_right_button, "right")
	var loaded: bool = _info.has("left")
	var ahead: int = int(_info.get("only_right", 0))
	var behind: int = int(_info.get("only_left", 0))
	_counts.set_counts(ahead, behind)
	_counts.tooltip_text = "\n".join([tr("%d commits only on %s") % [ahead, _side_name("right")],
			tr("%d commits only on %s") % [behind, _side_name("left")]]) if loaded else ""


## The chip of `which` side: its icon and name (a commit's subject), the
## full name and commit in the tooltip.
func _show_side(button: Button, which: String) -> void:
	var side: Dictionary = _info.get(which, {})
	var kind: String = String(side.get("kind", ""))
	if kind.is_empty():
		kind = "working" if which == "right" and bool(_request.get("working", false)) else "commit"
	button.icon = AppTheme.icon(SIDE_ICONS.get(kind, &"GitCommit"))
	var label: String = _side_name(which)
	button.text = label if label.length() <= MAX_CHIP_CHARS else label.left(MAX_CHIP_CHARS - 1) + "…"
	var tip: PackedStringArray = PackedStringArray([tr("Base (left side)") if which == "left" else tr("Compared (right side)")])
	if not String(side.get("full_name", "")).is_empty():
		tip.append(String(side["full_name"]))
	if not String(side.get("oid", "")).is_empty():
		tip.append(String(side["oid"]))
	tip.append(tr("Click to pick another side"))
	button.tooltip_text = "\n".join(tip)


## What a side is called: its short name, a commit's subject, "Working
## copy", or as asked.
func _side_name(which: String) -> String:
	var side: Dictionary = _info.get(which, {})
	if String(side.get("kind", "")) == "working" or (which == "right" and bool(_request.get("working", false))):
		return tr("Working copy")
	var label: String = String(side.get("subject", ""))
	if label.is_empty():
		label = String(side.get("name", ""))
	if label.is_empty():
		label = String(_request.get(which, ""))
	return label


func _apply_theme() -> void:
	_left.custom_minimum_size.x = float(get_theme_constant(&"min_left_width", &"Panes"))
	_files_box.custom_minimum_size.x = float(get_theme_constant(&"min_files_width", CommitDetails.THEME_TYPE))
	_update_bar()


# --- Keys and menus -------------------------------------------------------------

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


## Focuses the commit list.
func focus_files() -> void:
	_commits.grab_focus()


# --- For the shell and tests ----------------------------------------------------

## The split between the commits and the details (its offset is the shared
## left-pane width).
func files_split() -> HSplitContainer:
	return _split


## The details over the files (its offset is the details' height, shared
## with History).
func details_split() -> VSplitContainer:
	return _details


## The files beside the diff (its offset is the files' width, shared with
## History).
func files_diff_split() -> HSplitContainer:
	return _files_split


func left_pane() -> Control:
	return _left


func file_list() -> CompareFileList:
	return _files


func commit_list() -> CompareCommitList:
	return _commits


## The selected commit's details (hidden for All changes).
func details_header() -> CommitHeader:
	return _details_header


func diff_panel() -> DiffPanel:
	return _diff_panel


func filter_field() -> FilterField:
	return _filter


func list_header() -> ListHeader:
	return _header


## The bar's buttons, by name: left, swap, right, recent.
func bar_button(which: String) -> BaseButton:
	return {"left": _left_button, "swap": _swap_button, "right": _right_button, "recent": _recent_button}[which]


func counts() -> SyncCounts:
	return _counts


## The message or empty state shown instead of files (an error, no
## differences), or "".
func message_text() -> String:
	if _empty.visible:
		return _empty.title()
	return _message.text if _message.visible else ""


func loading_indicator() -> LoadingIndicator:
	return _loading


func file_menu() -> PopupMenu:
	return _file_menu


func commit_menu() -> PopupMenu:
	return _commit_menu
