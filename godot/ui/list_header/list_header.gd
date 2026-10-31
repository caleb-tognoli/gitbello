class_name ListHeader
extends PanelContainer
## The line above a list, the same over every list: an optional check-all
## box, what the list holds ("3 changed files", "1,204 commits") and, on the
## right, an optional status (icon and text) and its line totals (`+12 −3`,
## hidden while both are zero). Every
## header has the same height, with or without the box. Clicking the text
## beside the box clicks the box. Sizes and colours come from the
## `ListHeader` theme type.

## The check-all box (or its text) was clicked: `include` unless it showed `all`.
signal check_toggled(include: bool)
## Right-click anywhere on the header, in screen coordinates.
signal context_menu_requested(at: Vector2)

const THEME_TYPE: StringName = &"ListHeader"

@onready var _check: PickBox = %Check
@onready var _label: Label = %Label
@onready var _added: Label = %Added
@onready var _removed: Label = %Removed
@onready var _status: HBoxContainer = %Status
@onready var _status_icon: TextureRect = %StatusIcon
@onready var _status_label: Label = %StatusLabel


func _ready() -> void:
	_check.hide()
	_check.toggled_to.connect(func(include: bool) -> void: check_toggled.emit(include))
	_label.gui_input.connect(_on_label_input)
	for control: Control in [self, _check, _label, _added, _removed]:
		control.gui_input.connect(_on_context_input.bind(control))
	show_counts(0, 0)
	_apply_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()


func set_text(value: String) -> void:
	_label.text = value


func text() -> String:
	return _label.text


## Shows the check-all box in `state` (`all`, `partial`, `none`).
func show_check(state: String, tooltip: String = "") -> void:
	_check.state = state
	_check.tooltip_text = tooltip
	_check.show()
	_label.tooltip_text = tooltip
	_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func hide_check() -> void:
	_check.hide()
	_label.tooltip_text = ""
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.mouse_default_cursor_shape = Control.CURSOR_ARROW


func check() -> PickBox:
	return _check


## `status` after `icon`, both in `color`, on the right.
func show_status(icon: Texture2D, status: String, color: Color, tooltip: String = "") -> void:
	_status_icon.texture = icon
	_status_icon.modulate = color
	_status_label.text = status
	_status_label.add_theme_color_override(&"font_color", color)
	_status.tooltip_text = tooltip
	_status.mouse_filter = Control.MOUSE_FILTER_PASS if not tooltip.is_empty() else Control.MOUSE_FILTER_IGNORE
	_status.show()


func hide_status() -> void:
	_status.hide()


## The status shown, or "".
func status_text() -> String:
	return _status_label.text if _status.visible else ""


## `+12` and `−3` on the right (hidden while both are zero).
func show_counts(additions: int, deletions: int) -> void:
	DiffPanel.show_counts(_added, _removed, additions, deletions)


## The totals shown, as `+12 −3`, or "".
func counts_text() -> String:
	return "%s %s" % [_added.text, _removed.text] if _added.get_parent().visible else ""


## `count` and `noun`, plural (`plural`, or `noun` + "s") unless one, with
## thousands separators: "1,204 commits".
static func count_text(count: int, noun: String, plural: String = "") -> String:
	var digits: String = str(count)
	var out: String = ""
	while digits.length() > 3:
		out = "," + digits.right(3) + out
		digits = digits.left(digits.length() - 3)
	var word: String = noun if count == 1 else (plural if not plural.is_empty() else noun + "s")
	return "%s%s %s" % [digits, out, TranslationServer.translate(word)]


func _on_label_input(event: InputEvent) -> void:
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if _check.visible and mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
		check_toggled.emit(_check.state != "all")
		_label.accept_event()


func _apply_theme() -> void:
	custom_minimum_size.y = float(get_theme_constant(&"height", THEME_TYPE))
	var icon_size: float = float(get_theme_constant(&"icon_size", &"ListHeaderStatus"))
	_status_icon.custom_minimum_size = Vector2(icon_size, icon_size)


func _on_context_input(event: InputEvent, source: Control) -> void:
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT:
		context_menu_requested.emit(source.get_screen_position() + mouse.position)
		source.accept_event()
