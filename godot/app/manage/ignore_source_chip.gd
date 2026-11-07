class_name IgnoreSourceChip
extends PanelContainer
## One file of ignore rules in the viewer's chip row, styled like a worktree
## chip: its icon, short name and how many paths it hides, with a warning
## when a rule matches tracked files. Click chooses it, middle-click opens the
## file, right-click opens its menu.

signal chosen()
## `at_position` is on the screen.
signal menu_requested(at_position: Vector2)
signal open_requested()

## A row of `RepoSession.ignore_sources()`.
var source: Dictionary = {}
var selected: bool = false:
	set(value):
		selected = value
		_update_style()

var _hovered: bool = false
var _row: HBoxContainer = HBoxContainer.new()
var _icon: TextureRect = TextureRect.new()
var _name: Label = Label.new()
var _count: Label = Label.new()
var _warning: TextureRect = TextureRect.new()


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	add_to_group(AutoScroll.OWN_MIDDLE_CLICK)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_row)
	for icon: TextureRect in [_icon, _warning]:
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_warning.texture = AppTheme.icon(&"StatusWarning")
	for node: Control in [_icon, _name, _count, _warning]:
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_row.add_child(node)
	mouse_entered.connect(func() -> void:
		_hovered = true
		_update_style())
	mouse_exited.connect(func() -> void:
		_hovered = false
		_update_style())
	_show()


func set_source(value: Dictionary) -> void:
	source = value
	if is_node_ready():
		_show()


## The chip's `name  count` (for tests).
func text() -> String:
	return "%s  %s" % [_name.text, _count.text]


## A source's short name: the `.gitignore` path, "My computer" for
## `info/exclude`, "Global setting" for the global file.
static func label(row: Dictionary) -> String:
	match String(row.get("kind", "")):
		"local":
			return TranslationServer.translate("My computer")
		"global":
			return TranslationServer.translate("Global setting")
	return String(row.get("name", ""))


## The icon of a kind of source; the Ignore dialog's Where uses the same.
static func icon_name(kind: String) -> StringName:
	match kind:
		"local":
			return &"User"
		"global":
			return &"Tools"
	return &"GitIgnore"


func _notification(what: int) -> void:
	if (what == NOTIFICATION_TRANSLATION_CHANGED or what == NOTIFICATION_THEME_CHANGED) and is_node_ready():
		_show()


func _show() -> void:
	if source.is_empty():
		return
	var exists: bool = bool(source["exists"])
	var side: float = float(get_theme_constant(&"marker_size", &"WorktreeChip"))
	_icon.texture = AppTheme.icon(icon_name(String(source["kind"])))
	_icon.custom_minimum_size = Vector2(side, side)
	_warning.custom_minimum_size = Vector2(side, side)
	_warning.modulate = get_theme_color(&"tracked_color", IgnoreRulesDialog.THEME_TYPE)
	_name.text = label(source)
	_count.text = str(int(source["hidden_count"])) if exists else ""
	_count.visible = exists
	_count.theme_type_variation = &"DimLabel"
	_warning.visible = int(source["tracked_count"]) > 0
	var lines: PackedStringArray = PackedStringArray([String(source["path"])])
	if not exists:
		lines.append(tr("Not created yet"))
	else:
		lines.append(IgnoreRulesDialog.hides_text(int(source["hidden_count"]), int(source["tracked_count"])))
	tooltip_text = "\n".join(lines)
	_update_style()


func _update_style() -> void:
	if selected:
		theme_type_variation = &"WorktreeChipSelected"
	elif _hovered:
		theme_type_variation = &"WorktreeChipHover"
	else:
		theme_type_variation = &"WorktreeChip"
	_row.add_theme_constant_override(&"separation", get_theme_constant(&"separation", &"WorktreeChip"))
	if not source.is_empty() and not bool(source["exists"]):
		_name.theme_type_variation = &"WorktreeChipNameMissing"
	elif selected or _hovered:
		_name.theme_type_variation = &"WorktreeChipNameSelected"
	else:
		_name.theme_type_variation = &"WorktreeChipName"


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
		open_requested.emit()
	elif click.button_index == MOUSE_BUTTON_RIGHT:
		accept_event()
		menu_requested.emit(get_screen_position() + click.position)
