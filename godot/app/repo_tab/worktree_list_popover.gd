class_name WorktreeListPopover
extends PopupPanel
## The strip's list of every worktree (its worktree icon): one row each with
## its marker, folder and branch, the changed files and the commits to push
## and pull in pills (`SyncCounts`); the shown worktree's row is highlighted.
## Click or Enter on a row emits `chosen`, the arrows move between rows and
## Escape returns focus to where it was; each row's tooltip says its path
## and state.

## A row was chosen: show worktree `path`.
signal chosen(path: String)

const THEME_TYPE: StringName = &"WorktreeList"

var _scroll: ScrollContainer = ScrollContainer.new()
var _rows: VBoxContainer = VBoxContainer.new()
## Takes the focus back when the list closes without a choice.
var _return_focus: Control = null
var _chose: bool = false


func _ready() -> void:
	theme_type_variation = &"WorktreeListPanel"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	AutoScroll.enable(_scroll)
	add_child(_scroll)
	_rows.theme_type_variation = &"WorktreeListRows"
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows)
	popup_hide.connect(func() -> void:
		if not _chose and is_instance_valid(_return_focus) and _return_focus.is_inside_tree():
			_return_focus.grab_focus())


## Opens under `anchor` with a row per `worktrees` (rows of
## `RepoSession.worktrees()`), `selected_path`'s focused.
func open_below(anchor: Control, worktrees: Array[Dictionary], selected_path: String) -> void:
	_return_focus = anchor if anchor.has_focus() else null
	_chose = false
	var focused: Button = fill(worktrees, selected_path)
	var scale: float = anchor.get_window().content_scale_factor
	var at: Vector2 = anchor.get_screen_transform() * Vector2(0.0, anchor.size.y)
	var content: Vector2 = _rows.get_combined_minimum_size()
	_scroll.custom_minimum_size = Vector2(content.x, minf(content.y, float(get_theme_constant(&"max_height", THEME_TYPE))))
	popup(Rect2i(Vector2i(at), Vector2i.ZERO))
	reset_size()
	size = Vector2i(Vector2(size) * scale)
	if focused != null:
		_focus_row.call_deferred(focused)


func _focus_row(row: Button) -> void:
	if is_instance_valid(row) and row.is_inside_tree() and visible:
		row.grab_focus()


## Builds the rows; returns the selected worktree's (else the first) row.
func fill(worktrees: Array[Dictionary], selected_path: String) -> Button:
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	var focused: Button = null
	for wt: Dictionary in worktrees:
		var row: Button = _row(wt, Paths.same(String(wt["path"]), selected_path))
		_rows.add_child(row)
		if focused == null or row.button_pressed:
			focused = row
	return focused


## The row with the focus, or -1.
func focused_index() -> int:
	var focused: Control = _rows.get_viewport().gui_get_focus_owner()
	return focused.get_index() if focused != null and focused.get_parent() == _rows else -1


## Chooses row `index` as a click would.
func choose(index: int) -> void:
	(_rows.get_child(index) as Button).pressed.emit()


## The rows, for tests: `name`, `branch`, `changes`, `ahead`, `behind`, the
## `marker` icon, the `tooltip` and whether it is the `selected` one.
func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row: Node in _rows.get_children():
		var counts: SyncCounts = row.find_child("Counts", true, false) as SyncCounts
		out.append({
			"name": (row.find_child("Name", true, false) as Label).text,
			"branch": (row.find_child("Branch", true, false) as Label).text,
			"changes": (row.find_child("Changes", true, false) as Label).text,
			"ahead": counts.ahead, "behind": counts.behind,
			"marker": String(row.get_meta(&"marker")), "tooltip": (row as Button).tooltip_text,
			"selected": (row as Button).button_pressed,
		})
	return out


func _row(wt: Dictionary, selected: bool) -> Button:
	var row: Button = Button.new()
	row.theme_type_variation = &"WorktreeListRow"
	row.toggle_mode = true
	row.set_pressed_no_signal(selected)
	row.focus_mode = Control.FOCUS_ALL
	row.tooltip_text = _tooltip(wt)
	var path: String = String(wt["path"])
	row.pressed.connect(func() -> void:
		_chose = true
		hide()
		chosen.emit(path))
	var line: HBoxContainer = HBoxContainer.new()
	line.theme_type_variation = &"WorktreeListLine"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(line)
	var marker: TextureRect = TextureRect.new()
	row.set_meta(&"marker", _marker(wt))
	marker.texture = AppTheme.icon(_marker(wt))
	marker.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	marker.modulate = get_theme_color(&"conflict_color", &"WorktreeChip") if _marker(wt) == &"GitConflict" \
			else get_theme_color(&"icon_color", THEME_TYPE)
	line.add_child(marker)
	var name_label: Label = _label("Name", String(wt["name"]), &"")
	line.add_child(name_label)
	var branch: Label = _label("Branch", _branch_text(wt), &"DimLabel")
	branch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# A long branch name is cut short; the tooltip has the folder's path.
	var widest: float = float(get_theme_constant(&"branch_width", THEME_TYPE))
	if branch.get_minimum_size().x > widest:
		branch.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		branch.custom_minimum_size.x = widest
	line.add_child(branch)
	var changed: int = int(wt["changed"])
	line.add_child(_label("Changes", str(changed) if changed > 0 else "", &"WorktreeListChanges"))
	var counts: SyncCounts = SyncCounts.new()
	counts.name = "Counts"
	counts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	counts.set_counts(int(wt.get("ahead", 0)), int(wt.get("behind", 0)))
	line.add_child(counts)
	# A button's children don't size it: make room for the line.
	var style: StyleBox = row.get_theme_stylebox(&"normal")
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_left = style.get_margin(SIDE_LEFT)
	line.offset_top = style.get_margin(SIDE_TOP)
	line.offset_right = -style.get_margin(SIDE_RIGHT)
	line.offset_bottom = -style.get_margin(SIDE_BOTTOM)
	row.custom_minimum_size = line.get_combined_minimum_size() + style.get_minimum_size()
	return row


func _label(node_name: String, text: String, variation: StringName) -> Label:
	var label: Label = Label.new()
	label.name = node_name
	label.text = text
	label.theme_type_variation = variation
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.visible = not text.is_empty()
	return label


## A missing folder, an operation or conflicts, a lock, else the worktree icon.
static func _marker(wt: Dictionary) -> StringName:
	if bool(wt["prunable"]):
		return &"StatusWarning"
	if int(wt.get("conflicts", 0)) > 0 or not String(wt.get("operation", "")).is_empty():
		return &"GitConflict"
	if bool(wt["locked"]):
		return &"Lock"
	return &"GitWorktree"


func _branch_text(wt: Dictionary) -> String:
	if bool(wt["detached"]):
		return tr("detached %s") % String(wt["head"]).left(7)
	return String(wt["branch"])


func _tooltip(wt: Dictionary) -> String:
	var lines: PackedStringArray = PackedStringArray([String(wt["path"])])
	var changed: int = int(wt["changed"])
	if changed > 0:
		lines.append(tr("1 changed file") if changed == 1 else tr("%d changed files") % changed)
	var conflicts: int = int(wt.get("conflicts", 0))
	if conflicts > 0:
		lines.append(tr("1 conflicted file") if conflicts == 1 else tr("%d conflicted files") % conflicts)
	var ahead: int = int(wt.get("ahead", 0))
	if ahead > 0:
		lines.append(tr("1 commit ahead") if ahead == 1 else tr("%d commits ahead") % ahead)
	var behind: int = int(wt.get("behind", 0))
	if behind > 0:
		lines.append(tr("1 commit behind") if behind == 1 else tr("%d commits behind") % behind)
	var operation: String = String(wt.get("operation", ""))
	if not operation.is_empty():
		lines.append(tr("%s in progress") % tr(operation.capitalize()))
	if bool(wt["locked"]):
		var reason: String = String(wt["lock_reason"])
		lines.append(tr("Locked") + (": " + reason if not reason.is_empty() else ""))
	if bool(wt["prunable"]):
		lines.append(tr("The folder is missing."))
	return "\n".join(lines)
