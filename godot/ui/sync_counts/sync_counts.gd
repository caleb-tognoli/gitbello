class_name SyncCounts
extends Control
## The commits to push and to pull, each in a pill: an arrow and the count,
## outgoing in the accent and incoming in amber. A zero count is left out.
## In a container it sizes itself; as a Button's child it sits after the
## button's text and widens the button (like `CountBadge`). `draw_counts`
## draws the same pills elsewhere, such as a tree cell. Style from the
## `SyncCounts` theme type.

const THEME_TYPE: StringName = &"SyncCounts"

var ahead: int = 0
var behind: int = 0
## As a Button's child: whether it widens the button (a `BigButton` makes
## room itself and calls `place_after`).
var widen_button: bool = true
## As a Button's child: sit at its right edge instead (a fixed-width button).
var at_right: bool = false

var _button: Button = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_button = get_parent() as Button
	if _button != null and (widen_button or at_right):
		_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_button.resized.connect(_place_in_button)
	_refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_refresh()


func set_counts(ahead_count: int, behind_count: int) -> void:
	ahead = maxi(ahead_count, 0)
	behind = maxi(behind_count, 0)
	if is_node_ready():
		_refresh()


func is_empty() -> bool:
	return ahead == 0 and behind == 0


## The room the pills take after a button's text, gap included (0 when empty).
func room() -> float:
	if is_empty():
		return 0.0
	return float(get_theme_constant(&"button_gap", THEME_TYPE)) + measure(self, ahead, behind).x


## Sets the pills after a button's text that ends at `text_end`.
func place_after(text_end: float) -> void:
	var pills: Vector2 = measure(self, ahead, behind)
	size = pills
	position = Vector2(text_end + float(get_theme_constant(&"button_gap", THEME_TYPE)),
			roundf((get_parent_control().size.y - pills.y) / 2.0))


## The size of the pills for `ahead` and `behind`, in `control`'s theme.
static func measure(control: Control, ahead_count: int, behind_count: int) -> Vector2:
	var font: Font = control.get_theme_font(&"font", THEME_TYPE)
	var font_size: int = control.get_theme_font_size(&"font_size", THEME_TYPE)
	var width: float = 0.0
	for count: int in [ahead_count, behind_count]:
		if count > 0:
			width += _pill_width(control, font, font_size, count) \
					+ (float(control.get_theme_constant(&"separation", THEME_TYPE)) if width > 0.0 else 0.0)
	return Vector2(ceilf(width), _pill_height(control, font, font_size)) if width > 0.0 else Vector2.ZERO


## Draws the pills on `canvas`, centred vertically in `rect`, from its left
## edge or (with `align_right`) up to its right edge.
static func draw_counts(canvas: Control, rect: Rect2, ahead_count: int, behind_count: int,
		align_right: bool = false) -> void:
	var total: Vector2 = measure(canvas, ahead_count, behind_count)
	if total == Vector2.ZERO:
		return
	var font: Font = canvas.get_theme_font(&"font", THEME_TYPE)
	var font_size: int = canvas.get_theme_font_size(&"font_size", THEME_TYPE)
	var pad: float = float(canvas.get_theme_constant(&"padding", THEME_TYPE))
	var icon_gap: float = float(canvas.get_theme_constant(&"icon_separation", THEME_TYPE))
	var x: float = rect.end.x - total.x if align_right else rect.position.x
	var top: float = roundf(rect.position.y + (rect.size.y - total.y) / 2.0)
	for entry: Array in [[ahead_count, &"ahead", &"GitAhead"], [behind_count, &"behind", &"GitBehind"]]:
		var count: int = entry[0]
		if count <= 0:
			continue
		var width: float = _pill_width(canvas, font, font_size, count)
		var color: Color = canvas.get_theme_color(StringName(String(entry[1]) + "_color"), THEME_TYPE)
		canvas.draw_style_box(canvas.get_theme_stylebox(entry[1], THEME_TYPE), Rect2(x, top, width, total.y))
		var icon_size: float = float(font_size)
		canvas.draw_texture_rect(AppTheme.tintable_icon(entry[2]),
				Rect2(x + pad, top + (total.y - icon_size) / 2.0, icon_size, icon_size), false, color)
		var baseline: float = top + (total.y - font.get_height(font_size)) / 2.0 + font.get_ascent(font_size)
		canvas.draw_string(font, Vector2(x + pad + icon_size + icon_gap, baseline), str(count),
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
		x += width + float(canvas.get_theme_constant(&"separation", THEME_TYPE))


func _get_minimum_size() -> Vector2:
	return measure(self, ahead, behind)


func _draw() -> void:
	draw_counts(self, Rect2(Vector2.ZERO, size), ahead, behind)


func _refresh() -> void:
	visible = not is_empty()
	update_minimum_size()
	queue_redraw()
	if _button != null and (widen_button or at_right):
		_place_in_button()


## Widens the parent button by the pills and sets them after its text, or
## sets them at its right edge.
func _place_in_button() -> void:
	var right: float = _button.get_theme_stylebox(&"normal").get_margin(SIDE_RIGHT)
	if at_right:
		place_after(_button.size.x - right - room())
		return
	if is_empty():
		_button.custom_minimum_size.x = 0.0
		return
	var natural: float = _button.get_minimum_size().x
	_button.custom_minimum_size.x = natural + room()
	place_after(natural - right)


static func _pill_width(control: Control, font: Font, font_size: int, count: int) -> float:
	var pad: float = float(control.get_theme_constant(&"padding", THEME_TYPE))
	var icon_gap: float = float(control.get_theme_constant(&"icon_separation", THEME_TYPE))
	var text: float = font.get_string_size(str(count), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	return ceilf(pad + float(font_size) + icon_gap + text + pad + 1.0)


static func _pill_height(control: Control, font: Font, font_size: int) -> float:
	return ceilf(font.get_height(font_size)) + 2.0 * float(control.get_theme_constant(&"padding_vertical", THEME_TYPE))
