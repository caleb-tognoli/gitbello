class_name CountBadge
extends Label
## A count in a pill after a button's text, like GitHub Desktop's Changes
## tab: add it as the button's child and set `count` (zero hides it). The
## button grows to make room and its text moves to the left. Style from the
## `CountBadge` theme type.

const THEME_TYPE: StringName = &"CountBadge"

var count: int = 0:
	set = set_count

var _button: Button = null


func _ready() -> void:
	theme_type_variation = THEME_TYPE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_button = get_parent() as Button
	_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_button.resized.connect(_place)
	minimum_size_changed.connect(_place)
	set_count(count)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_place.call_deferred()


func set_count(value: int) -> void:
	count = value
	text = str(value)
	visible = value > 0
	if is_node_ready():
		_place()


## Widens the button by the badge and sets the badge after its text.
func _place() -> void:
	if not visible:
		_button.custom_minimum_size.x = 0.0
		return
	# The button's own size, without the room made for the badge.
	var natural: float = _button.get_minimum_size().x
	var gap: float = float(get_theme_constant(&"gap", THEME_TYPE))
	var badge: Vector2 = get_combined_minimum_size()
	_button.custom_minimum_size.x = natural + gap + badge.x
	var right: float = _button.get_theme_stylebox(&"normal").get_margin(SIDE_RIGHT)
	position = Vector2(natural - right + gap, roundf((_button.size.y - badge.y) / 2.0))
	size = badge
