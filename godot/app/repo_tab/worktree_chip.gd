class_name WorktreeChip
extends PanelContainer
## One worktree in a repository tab's strip (PLAN §4): its short folder name
## (the repository's name left out), then one marker: a lock, conflict (in
## the conflict colour) or missing-folder icon, else a dot when it has
## changed files. The branch,
## path and counts are in its tooltip card. Click or Enter/Space shows the
## worktree, middle-click its folder; right-click or the context-menu key
## opens its menu.

signal chosen()
## `at_position` is on the screen.
signal menu_requested(at_position: Vector2)
## Middle-click: show the worktree's folder in the file manager.
signal reveal_requested()

const THEME_TYPE: StringName = &"WorktreeChip"

## A row of `RepoSession.worktrees()`.
var worktree: Dictionary = {}
var selected: bool = false:
	set(value):
		selected = value
		_update_style()

var _hovered: bool = false
var _row: HBoxContainer = HBoxContainer.new()
var _name: Label = Label.new()
var _marker: TextureRect = TextureRect.new()
var _marker_name: StringName = &""
var _tooltip_content: VBoxContainer = null


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# Middle click shows the folder rather than autoscrolling the strip.
	add_to_group(AutoScroll.OWN_MIDDLE_CLICK)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_row)
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_marker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_marker.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for node: Control in [_name, _marker]:
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_row.add_child(node)
	mouse_entered.connect(func() -> void:
		_hovered = true
		_update_style())
	mouse_exited.connect(func() -> void:
		_hovered = false
		_update_style())
	_update_style()
	_show()


func set_worktree(value: Dictionary) -> void:
	worktree = value
	if is_node_ready():
		_show()


func path() -> String:
	return String(worktree.get("path", ""))


## What the chip shows, for tests: the `name` text and the `marker` (an icon
## name, `dot` for changed files, or "").
func texts() -> Dictionary:
	return {"name": _name.text, "marker": String(_marker_name)}


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_show()
	elif what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_show()


func _show() -> void:
	if worktree.is_empty():
		return
	_name.text = String(worktree.get("short_name", worktree["name"]))
	_marker_name = &""
	if bool(worktree["prunable"]):
		_marker_name = &"StatusWarning"
	elif not String(worktree.get("operation", "")).is_empty() or int(worktree.get("conflicts", 0)) > 0:
		_marker_name = &"GitConflict"
	elif bool(worktree["locked"]):
		_marker_name = &"Lock"
	elif int(worktree["changed"]) > 0:
		_marker_name = &"dot"
	# Icons scale down to `marker_size`; the dot keeps its own small size.
	var side: float = float(get_theme_constant(&"marker_size", THEME_TYPE))
	if _marker_name == &"dot":
		_marker.texture = AppTheme.dot(get_theme_color(&"changes_color", THEME_TYPE))
		_marker.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	else:
		_marker.texture = AppTheme.icon(_marker_name) if _marker_name != &"" else null
		_marker.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_marker.custom_minimum_size = Vector2(side, side)
	_marker.modulate = get_theme_color(&"conflict_color", THEME_TYPE) if _marker_name == &"GitConflict" else Color.WHITE
	_marker.visible = _marker_name != &""
	_update_name_style()
	var lines: PackedStringArray = PackedStringArray()
	for entry: Array in _details():
		lines.append(String(entry[1]))
	tooltip_text = "\n".join(lines)
	if is_instance_valid(_tooltip_content):
		_fill_tooltip(_tooltip_content)


## The tooltip's `[icon, text]` lines: folder, branch and path, then status.
func _details() -> Array[Array]:
	var detached: bool = bool(worktree["detached"])
	var out: Array[Array] = [[&"", String(worktree["name"])],
		[&"GitCommit" if detached else &"GitBranch", _branch_text()], [&"Folder", String(worktree["path"])]]
	if bool(worktree["prunable"]):
		out.append([&"StatusWarning", tr("The folder is missing.")])
		return out
	var changed: int = int(worktree["changed"])
	if changed < 0:
		out.append([&"", tr("Status not available yet")])
		return out
	if changed == 0:
		out.append([&"StatusSuccess", tr("No changed files")])
	else:
		out.append([&"FileModified", tr("1 changed file") if changed == 1 else tr("%d changed files") % changed])
	var conflicts: int = int(worktree.get("conflicts", 0))
	if conflicts > 0:
		out.append([&"GitConflict", tr("1 conflicted file") if conflicts == 1 else tr("%d conflicted files") % conflicts])
	var ahead: int = int(worktree.get("ahead", 0))
	if ahead > 0:
		out.append([&"GitAhead", tr("1 commit ahead") if ahead == 1 else tr("%d commits ahead") % ahead])
	var behind: int = int(worktree.get("behind", 0))
	if behind > 0:
		out.append([&"GitBehind", tr("1 commit behind") if behind == 1 else tr("%d commits behind") % behind])
	if not String(worktree.get("operation", "")).is_empty():
		out.append([&"GitConflict", tr("%s in progress") % tr(String(worktree["operation"]).capitalize())])
	if bool(worktree["locked"]):
		var reason: String = String(worktree["lock_reason"])
		out.append([&"Lock", tr("Locked") + (": " + reason if not reason.is_empty() else "")])
	return out


func _branch_text() -> String:
	if bool(worktree["detached"]):
		var head: String = String(worktree["head"])
		return tr("Detached at %s") % head.left(7) if not head.is_empty() else tr("No branch yet")
	var branch: String = String(worktree["branch"])
	return branch if not branch.is_empty() else tr("No branch yet")


func _make_custom_tooltip(_for_text: String) -> Control:
	_tooltip_content = VBoxContainer.new()
	_tooltip_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_content.theme_type_variation = &"WorktreeTooltip"
	_fill_tooltip(_tooltip_content)
	return _tooltip_content


## The tooltip card: the folder in bold, the branch and the dimmed path
## (wrapped past the theme's `path_width`), then one icon line per state
## (changes, conflicts, ↑↓, operation, lock).
func _fill_tooltip(content: VBoxContainer) -> void:
	for child: Node in content.get_children():
		content.remove_child(child)
		child.queue_free()
	if worktree.is_empty():
		return
	var details: Array[Array] = _details()
	content.add_child(_tooltip_label(String(details[0][1]), &"WorktreeTooltipTitle"))
	content.add_child(_tooltip_line(details[1][0], String(details[1][1]), &"TooltipLabel"))
	var path_line: HBoxContainer = _tooltip_line(details[2][0], String(details[2][1]), &"WorktreeTooltipDim")
	var path_label: Label = path_line.get_child(1) as Label
	var widest: float = float(get_theme_constant(&"path_width", &"WorktreeTooltip"))
	if path_label.get_minimum_size().x > widest:
		path_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		path_label.custom_minimum_size.x = widest
	content.add_child(path_line)
	var status: VBoxContainer = VBoxContainer.new()
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status.theme_type_variation = &"WorktreeTooltipStatus"
	for entry: Array in details.slice(3):
		status.add_child(_tooltip_line(entry[0], String(entry[1]), &"TooltipLabel"))
	content.add_child(status)


func _tooltip_line(icon_name: StringName, text: String, variation: StringName) -> HBoxContainer:
	var line: HBoxContainer = HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon: TextureRect = TextureRect.new()
	icon.texture = AppTheme.icon(icon_name) if icon_name != &"" else null
	# The commits to push and pull take the arrows and colours of their pills.
	if icon_name in [&"GitAhead", &"GitBehind"]:
		icon.texture = AppTheme.tintable_icon(icon_name)
		icon.modulate = get_theme_color(&"ahead_color" if icon_name == &"GitAhead" else &"behind_color",
				SyncCounts.THEME_TYPE)
	icon.custom_minimum_size = Vector2.ONE * float(get_theme_constant(&"icon_size", &"WorktreeTooltip"))
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(icon)
	line.add_child(_tooltip_label(text, variation))
	return line


func _tooltip_label(text: String, variation: StringName) -> Label:
	var label: Label = Label.new()
	label.theme_type_variation = variation
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = text
	return label


func _update_style() -> void:
	if selected:
		theme_type_variation = &"WorktreeChipSelected"
	elif _hovered:
		theme_type_variation = &"WorktreeChipHover"
	else:
		theme_type_variation = THEME_TYPE
	_row.add_theme_constant_override(&"separation", get_theme_constant(&"separation", THEME_TYPE))
	_update_name_style()


## The name in full text when shown or hovered, dimmed when its folder is
## missing, muted otherwise; at most the theme's `max_width` wide, then "…".
func _update_name_style() -> void:
	if not worktree.is_empty() and bool(worktree["prunable"]):
		_name.theme_type_variation = &"WorktreeChipNameMissing"
	elif selected or _hovered:
		_name.theme_type_variation = &"WorktreeChipNameSelected"
	else:
		_name.theme_type_variation = &"WorktreeChipName"
	var widest: float = float(get_theme_constant(&"max_width", THEME_TYPE))
	var natural: float = _name.get_theme_font(&"font").get_string_size(_name.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			_name.get_theme_font_size(&"font_size")).x
	_name.custom_minimum_size.x = ceilf(minf(natural, widest))


func _draw() -> void:
	if has_focus():
		draw_style_box(get_theme_stylebox(&"focus"), Rect2(Vector2.ZERO, size))


func _gui_input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key != null:
		if not key.pressed or key.echo:
			return
		if key.is_action_pressed("ui_accept", false, true):
			accept_event()
			chosen.emit()
		elif key.keycode == KEY_MENU or (key.keycode == KEY_F10 and key.shift_pressed):
			accept_event()
			menu_requested.emit(get_screen_position() + Vector2(0.0, size.y))
		return
	var click: InputEventMouseButton = event as InputEventMouseButton
	if click == null or not click.pressed:
		return
	if click.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		chosen.emit()
	elif click.button_index == MOUSE_BUTTON_MIDDLE:
		accept_event()
		reveal_requested.emit()
	elif click.button_index == MOUSE_BUTTON_RIGHT:
		accept_event()
		menu_requested.emit(get_screen_position() + click.position)
