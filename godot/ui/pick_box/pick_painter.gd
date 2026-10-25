class_name PickPainter
extends RefCounted
## Draws the commit-selection checkbox (PLAN §4 Changes view) the same way in
## file rows, the diff gutter and the check-all box: `all` (filled, a tick),
## `partial` (filled, a dash) or `none` (an empty box). Colors and the size
## come from the `PickBox` theme type.

const THEME_TYPE: StringName = &"PickBox"

var size: float = 14.0
var _border: Color = Color.WHITE
var _fill: Color = Color.WHITE
var _mark: Color = Color.BLACK


## Reads the theme values from `control` (call again on theme changes).
func update_theme(control: Control) -> void:
	size = float(control.get_theme_constant(&"size", THEME_TYPE))
	_border = control.get_theme_color(&"border_color", THEME_TYPE)
	_fill = control.get_theme_color(&"fill_color", THEME_TYPE)
	_mark = control.get_theme_color(&"mark_color", THEME_TYPE)


## The box's square, centred vertically in `rect` at `x`.
func box_rect(rect: Rect2, x: float) -> Rect2:
	return Rect2(x, rect.position.y + floorf((rect.size.y - size) / 2.0), size, size)


func draw(canvas: CanvasItem, box: Rect2, state: String) -> void:
	if state == "all" or state == "partial":
		canvas.draw_rect(box, _fill)
		var c: Vector2 = box.get_center()
		var s: float = box.size.x
		if state == "all":
			var tick: PackedVector2Array = PackedVector2Array([
				c + Vector2(-0.28, 0.0) * s, c + Vector2(-0.08, 0.2) * s, c + Vector2(0.28, -0.2) * s])
			canvas.draw_polyline(tick, _mark, maxf(1.5, s / 7.0), true)
		else:
			canvas.draw_line(c + Vector2(-0.25, 0.0) * s, c + Vector2(0.25, 0.0) * s, _mark, maxf(1.5, s / 7.0))
	else:
		canvas.draw_rect(box.grow(-0.5), _border, false, 1.0)
