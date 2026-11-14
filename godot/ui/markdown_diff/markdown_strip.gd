class_name MarkdownStrip
extends Control
## The scroll column of a `MarkdownDiffView`, drawn like the text diff's
## strip: every changed block marked over the whole document in its colour
## (added, removed, changed), and a thumb for what is on screen. Drag the
## thumb to scroll, click elsewhere to centre that point, turn the wheel to
## scroll. Marks come from `MarkdownDiffView.change_marks` (the blocks built
## so far, so a long document fills in over its first frames).

## Pixels the wheel scrolls per notch.
const WHEEL_STEP: float = 60.0

## The preview this scrolls.
var view: MarkdownDiffView = null

## The drag in progress: the grab point inside the thumb, or -1 for none.
var _grab: float = -1.0
var _thumb_hovered: bool = false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


## The width the strip takes beside the preview.
func strip_width() -> float:
	return float(get_theme_constant(&"strip_only_width", DiffMinimap.THEME_TYPE))


## The thumb's top and height in pixels; the height is 0 when the whole
## document fits.
func thumb() -> Vector2:
	if view == null:
		return Vector2.ZERO
	var content: float = view.content_height()
	var shown: float = view.size.y
	if content <= shown or size.y <= 0.0:
		return Vector2.ZERO
	var height: float = maxf(float(get_theme_constant(&"min_thumb", DiffMinimap.THEME_TYPE)), shown / content * size.y)
	var room: float = maxf(0.0, size.y - height)
	var top: float = float(view.scroll_vertical) / maxf(1.0, content - shown) * room
	return Vector2(top, height)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _color(&"strip_background"))
	if view == null:
		return
	var content: float = maxf(1.0, view.content_height())
	var marks: PackedFloat32Array = view.change_marks()
	var colors: Dictionary[int, Color] = {
		MarkdownDiffView.MARK_ADDED: _color(&"added_mark"),
		MarkdownDiffView.MARK_REMOVED: _color(&"removed_mark"),
		MarkdownDiffView.MARK_CHANGED: get_theme_color(&"changed_mark", MarkdownDiffView.THEME_TYPE),
	}
	var min_mark: float = float(get_theme_constant(&"min_shade", DiffMinimap.THEME_TYPE))
	for i: int in range(0, marks.size() - 2, 3):
		var top: float = marks[i] / content * size.y
		var height: float = maxf(min_mark, (marks[i + 1] - marks[i]) / content * size.y)
		draw_rect(Rect2(0.0, minf(top, size.y - height), size.x, height), colors.get(int(marks[i + 2]), Color.TRANSPARENT))
	var bar: Vector2 = thumb()
	if bar.y > 0.0:
		var hovered: bool = _thumb_hovered or _grab >= 0.0
		draw_rect(Rect2(0.0, bar.x, size.x, bar.y), _color(&"thumb_hover_color" if hovered else &"thumb_color"))


func _color(color_name: StringName) -> Color:
	return get_theme_color(color_name, DiffMinimap.THEME_TYPE)


func _gui_input(event: InputEvent) -> void:
	if view == null:
		return
	var button: InputEventMouseButton = event as InputEventMouseButton
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if button != null:
		if button.pressed and button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var direction: float = -1.0 if button.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
			view.scroll_vertical = int(float(view.scroll_vertical) + direction * WHEEL_STEP * maxf(1.0, button.factor))
			accept_event()
		elif button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				var bar: Vector2 = thumb()
				if bar.y <= 0.0:
					accept_event()
					return
				var y: float = button.position.y
				_grab = y - bar.x if y >= bar.x and y <= bar.x + bar.y else bar.y / 2.0
				_scroll_to_thumb(y - _grab)
			else:
				_grab = -1.0
			queue_redraw()
			accept_event()
	elif motion != null:
		if _grab >= 0.0 and (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			_scroll_to_thumb(motion.position.y - _grab)
			accept_event()
		var bar: Vector2 = thumb()
		var over: bool = bar.y > 0.0 and motion.position.y >= bar.x and motion.position.y <= bar.x + bar.y
		if over != _thumb_hovered:
			_thumb_hovered = over
			queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and view != null:
		view.place_strip()
	if what == NOTIFICATION_MOUSE_EXIT and _thumb_hovered:
		_thumb_hovered = false
		queue_redraw()


## Scrolls so the thumb's top is at `top`.
func _scroll_to_thumb(top: float) -> void:
	var bar: Vector2 = thumb()
	var room: float = maxf(1.0, size.y - bar.y)
	var overflow: float = maxf(0.0, view.content_height() - view.size.y)
	view.scroll_vertical = int(clampf(top / room, 0.0, 1.0) * overflow)
