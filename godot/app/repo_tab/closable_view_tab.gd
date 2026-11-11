class_name ClosableViewTab
extends RefCounted
## A button of the Changes | History | Shelves switch for a view that shows
## only while it has something open (Compare, File history): hidden until
## then, with a × inside it that runs the view's close action. It remembers
## the view shown before its own opened, to return there on close.

var button: Button = null
## The × inside the button.
var close: Button = Button.new()
## The view shown before this one opened (`WorktreeView.View`).
var opened_from: int = 0

var _close_action: StringName = &""


func _init(tab_button: Button, close_action: StringName) -> void:
	button = tab_button
	_close_action = close_action
	button.hide()
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	close.theme_type_variation = &"FilterFieldButton"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func() -> void: Actions.run_action(_close_action, close))
	button.add_child(close)
	button.resized.connect(place)
	close.minimum_size_changed.connect(place)


## Widens the button by its × and sets the × after the text.
func place() -> void:
	close.icon = AppTheme.icon(&"Close")
	close.tooltip_text = Actions.tooltip(_close_action)
	var natural: float = button.get_minimum_size().x
	var close_size: Vector2 = close.get_combined_minimum_size()
	var right: float = button.get_theme_stylebox(&"normal").get_margin(SIDE_RIGHT)
	button.custom_minimum_size.x = natural + close_size.x - right / 2.0
	close.size = close_size
	close.position = Vector2(natural - right, roundf((button.size.y - close_size.y) / 2.0))
