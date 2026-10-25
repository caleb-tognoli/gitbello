class_name PickBox
extends Control
## A checkbox with a partial state (`all`, `partial`, `none`), drawn like the
## file rows' boxes. Clicking it asks to include everything unless
## everything already is.

## The user clicked: `include` is true unless the box showed `all`.
signal toggled_to(include: bool)

var state: String = "none":
	set(value):
		state = value
		queue_redraw()

var _painter: PickPainter = PickPainter.new()


func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_painter.update_theme(self)
	custom_minimum_size = Vector2(_painter.size, _painter.size)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_painter.update_theme(self)
		custom_minimum_size = Vector2(_painter.size, _painter.size)
		queue_redraw()


func _draw() -> void:
	_painter.draw(self, _painter.box_rect(Rect2(Vector2.ZERO, size), 0.0), state)


func _gui_input(event: InputEvent) -> void:
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
		toggled_to.emit(state != "all")
		accept_event()
