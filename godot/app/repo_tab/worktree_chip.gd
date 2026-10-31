class_name WorktreeChip
extends PanelContainer
## One worktree in a repository tab's strip (PLAN §4): the folder name, the
## branch in muted text (left out when it is the folder's name), the changed
## files and ↑↓, and markers for an operation in progress, a lock or a missing
## folder. Click or Enter/Space shows the worktree; right-click or the
## context-menu key opens its menu.

signal chosen()
## `at_position` is on the screen.
signal menu_requested(at_position: Vector2)

## A row of `RepoSession.worktrees()`.
var worktree: Dictionary = {}
var selected: bool = false:
	set(value):
		selected = value
		_update_style()

var _hovered: bool = false
var _row: HBoxContainer = HBoxContainer.new()
var _name: Label = Label.new()
var _branch: Label = Label.new()
var _badge: Label = Label.new()
var _marker: TextureRect = TextureRect.new()
var _tooltip_content: VBoxContainer = null


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_row)
	_marker.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	for node: Control in [_marker, _name, _branch, _badge]:
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_row.add_child(node)
	_branch.theme_type_variation = &"DimLabel"
	_badge.theme_type_variation = &"ChipBadge"
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


## What the chip says, for tests: `name`, `branch`, `badge` texts.
func texts() -> Dictionary:
	return {"name": _name.text, "branch": _branch.text if _branch.visible else "", "badge": _badge.text}


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_show()


func _show() -> void:
	if worktree.is_empty():
		return
	var folder: String = String(worktree["name"])
	var branch: String = String(worktree["branch"])
	if bool(worktree["detached"]):
		branch = tr("detached %s") % String(worktree["head"]).left(7)
	_name.text = folder
	_branch.text = branch
	_branch.visible = not branch.is_empty() and branch != folder
	var parts: PackedStringArray = PackedStringArray()
	if int(worktree["changed"]) > 0:
		parts.append(str(int(worktree["changed"])))
	if int(worktree.get("ahead", 0)) > 0:
		parts.append("↑%d" % int(worktree["ahead"]))
	if int(worktree.get("behind", 0)) > 0:
		parts.append("↓%d" % int(worktree["behind"]))
	_badge.text = " ".join(parts)
	_badge.visible = not parts.is_empty()
	var marker: StringName = &""
	if bool(worktree["prunable"]):
		marker = &"StatusWarning"
	elif not String(worktree.get("operation", "")).is_empty() or int(worktree.get("conflicts", 0)) > 0:
		marker = &"GitConflict"
	elif bool(worktree["locked"]):
		marker = &"Lock"
	_marker.texture = AppTheme.icon(marker) if marker != &"" else null
	_marker.visible = marker != &""
	var tooltip: PackedStringArray = PackedStringArray([String(worktree["path"])])
	if bool(worktree["prunable"]):
		tooltip.append(tr("The folder is missing."))
	elif int(worktree["changed"]) < 0:
		tooltip.append(tr("Status not available yet"))
	else:
		var changed: int = int(worktree["changed"])
		if changed == 0:
			tooltip.append(tr("No changed files"))
		else:
			tooltip.append(tr("1 changed file") if changed == 1 else tr("%d changed files") % changed)
		var conflicts: int = int(worktree.get("conflicts", 0))
		if conflicts > 0:
			tooltip.append(tr("1 conflicted file") if conflicts == 1 else tr("%d conflicted files") % conflicts)
	if bool(worktree["locked"]):
		tooltip.append(tr("Locked") + (": " + String(worktree["lock_reason"]) if not String(worktree["lock_reason"]).is_empty() else ""))
	if not String(worktree.get("operation", "")).is_empty():
		tooltip.append(tr("%s in progress") % tr(String(worktree["operation"]).capitalize()))
	tooltip_text = "\n".join(tooltip)
	if is_instance_valid(_tooltip_content):
		_fill_tooltip(_tooltip_content, tooltip_text)


func _make_custom_tooltip(for_text: String) -> Control:
	_tooltip_content = VBoxContainer.new()
	_tooltip_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill_tooltip(_tooltip_content, for_text)
	return _tooltip_content


func _fill_tooltip(content: VBoxContainer, for_text: String) -> void:
	for child: Node in content.get_children():
		content.remove_child(child)
		child.queue_free()
	var text: Label = Label.new()
	text.theme_type_variation = &"TooltipLabel"
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.text = for_text
	content.add_child(text)
	if worktree.is_empty() or bool(worktree["prunable"]) or int(worktree["changed"]) < 0:
		return
	var tracking: HBoxContainer = null
	for icon_name: StringName in [&"GitPush", &"GitPull"]:
		var count: int = int(worktree.get("ahead" if icon_name == &"GitPush" else "behind", 0))
		if count <= 0:
			continue
		if tracking == null:
			tracking = HBoxContainer.new()
			tracking.mouse_filter = Control.MOUSE_FILTER_IGNORE
			content.add_child(tracking)
		var pair: HBoxContainer = HBoxContainer.new()
		pair.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tracking.add_child(pair)
		var icon: TextureRect = TextureRect.new()
		icon.texture = AppTheme.icon(icon_name)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pair.add_child(icon)
		var value: Label = Label.new()
		value.theme_type_variation = &"TooltipLabel"
		value.mouse_filter = Control.MOUSE_FILTER_IGNORE
		value.text = str(count)
		pair.add_child(value)


func _update_style() -> void:
	if selected:
		theme_type_variation = &"WorktreeChipSelected"
	elif _hovered:
		theme_type_variation = &"WorktreeChipHover"
	else:
		theme_type_variation = &"WorktreeChip"


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
	elif click.button_index == MOUSE_BUTTON_RIGHT:
		accept_event()
		menu_requested.emit(get_screen_position() + click.position)
