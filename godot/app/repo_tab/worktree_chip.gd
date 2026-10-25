class_name WorktreeChip
extends PanelContainer
## One worktree in a repository tab's strip (PLAN §4): the folder name, the
## branch in muted text (left out when it is the folder's name), the changed
## files and ↑↓, and markers for an operation in progress, a lock or a missing
## folder. A click shows the worktree; right-click opens its menu.

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


func _ready() -> void:
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


func _show() -> void:
	if worktree.is_empty():
		return
	var name: String = String(worktree["name"])
	var branch: String = String(worktree["branch"])
	if bool(worktree["detached"]):
		branch = "detached " + String(worktree["head"]).left(7)
	_name.text = name
	_branch.text = branch
	_branch.visible = not branch.is_empty() and branch != name
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
		tooltip.append("The folder is missing.")
	if bool(worktree["locked"]):
		tooltip.append("Locked" + (": " + String(worktree["lock_reason"]) if not String(worktree["lock_reason"]).is_empty() else ""))
	if not String(worktree.get("operation", "")).is_empty():
		tooltip.append("%s in progress" % String(worktree["operation"]).capitalize())
	tooltip_text = "\n".join(tooltip)


func _update_style() -> void:
	if selected:
		theme_type_variation = &"WorktreeChipSelected"
	elif _hovered:
		theme_type_variation = &"WorktreeChipHover"
	else:
		theme_type_variation = &"WorktreeChip"


func _gui_input(event: InputEvent) -> void:
	var click: InputEventMouseButton = event as InputEventMouseButton
	if click == null or not click.pressed:
		return
	if click.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		chosen.emit()
	elif click.button_index == MOUSE_BUTTON_RIGHT:
		accept_event()
		menu_requested.emit(get_screen_position() + click.position)
