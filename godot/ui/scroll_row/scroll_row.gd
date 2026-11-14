class_name ScrollRow
extends Container
## A row of controls (chips) that scrolls sideways when they do not fit. A ‹
## and a › button lie over its ends, on a fade in the row's background
## (`fade_color`), each only while there is more to see that way: they take
## no room, so nothing moves when one shows. A click scrolls the next
## control cut off (or under the other arrow) fully into view. The wheel,
## middle-click autoscroll and keyboard focus scroll it too. Add the controls
## to `content()`.

const THEME_TYPE: StringName = &"ScrollRow"
## Seconds an arrow's scroll takes.
const SCROLL_TIME: float = 0.15
## Pixels an arrow scrolls at least: a control cut off by less is passed
## over for the next one.
const MIN_STEP: float = 16.0

## The row started or stopped overflowing.
signal overflow_changed(overflowing: bool)


## The fade under an arrow: solid behind the button, then fading out into
## the row over `fade_width`.
class Fade:
	extends Control
	## -1 on the left end (fades to the right), 1 on the right end.
	var side: int = -1
	var solid: float = 0.0

	func _draw() -> void:
		var color: Color = get_theme_color(&"fade_color", ScrollRow.THEME_TYPE)
		var clear: Color = Color(color, 0.0)
		var w: float = size.x
		var h: float = size.y
		var edge: float = solid if side < 0 else w - solid
		draw_rect(Rect2(0.0 if side < 0 else edge, 0.0, solid, h), color)
		var inner: float = w if side < 0 else 0.0
		draw_polygon(PackedVector2Array([Vector2(edge, 0.0), Vector2(inner, 0.0), Vector2(inner, h), Vector2(edge, h)]),
				PackedColorArray([color, clear, clear, color]))


var _left: Button = Button.new()
var _right: Button = Button.new()
var _left_fade: Fade = Fade.new()
var _right_fade: Fade = Fade.new()
var _scroll: ScrollContainer = ScrollContainer.new()
var _content: HBoxContainer = HBoxContainer.new()
var _overflowing: bool = false
var _tween: Tween = null
## Where the running arrow scroll ends.
var _target: int = 0


func _init() -> void:
	theme_type_variation = THEME_TYPE
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	# Focus reveals controls clear of the arrows (`_on_focus_changed`).
	_scroll.follow_focus = false
	_scroll.add_child(_content)
	add_child(_scroll)
	_right_fade.side = 1
	for fade: Fade in [_left_fade, _right_fade]:
		fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fade.hide()
		add_child(fade)
	for entry: Array in [[_left, &"ChevronLeft", -1], [_right, &"ChevronRight", 1]]:
		var arrow: Button = entry[0]
		arrow.icon = AppTheme.icon(entry[1])
		arrow.theme_type_variation = &"ScrollRowArrow"
		arrow.focus_mode = Control.FOCUS_NONE
		arrow.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		arrow.pressed.connect(step.bind(int(entry[2])))
		arrow.hide()
		add_child(arrow)


func _ready() -> void:
	AutoScroll.enable(_scroll)
	resized.connect(_update)
	_content.minimum_size_changed.connect(_update)
	var bar: HScrollBar = _scroll.get_h_scroll_bar()
	bar.value_changed.connect(func(_value: float) -> void: _update_arrows())
	bar.changed.connect(_update_arrows)
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	_update()


func _get_minimum_size() -> Vector2:
	var height: float = _scroll.get_combined_minimum_size().y
	for arrow: Button in [_left, _right]:
		height = maxf(height, arrow.get_combined_minimum_size().y)
	return Vector2(0.0, height)


func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		fit_child_in_rect(_scroll, Rect2(Vector2.ZERO, size))
		var arrow_size: Vector2 = _right.get_combined_minimum_size()
		var top: float = roundf((size.y - arrow_size.y) / 2.0)
		fit_child_in_rect(_left, Rect2(Vector2(0.0, top), arrow_size))
		fit_child_in_rect(_right, Rect2(Vector2(size.x - arrow_size.x, top), arrow_size))
		var cover: float = cover_width()
		for fade: Fade in [_left_fade, _right_fade]:
			fade.solid = arrow_size.x
			fit_child_in_rect(fade, Rect2(Vector2(0.0 if fade.side < 0 else size.x - cover, 0.0), Vector2(cover, size.y)))
			fade.queue_redraw()
	elif what == NOTIFICATION_THEME_CHANGED:
		update_minimum_size()
		queue_sort()


## Holds the row's controls.
func content() -> HBoxContainer:
	return _content


func scroll_container() -> ScrollContainer:
	return _scroll


## Whether the controls are wider than the row (it then scrolls).
func overflows() -> bool:
	return _overflowing


func left_arrow() -> Button:
	return _left


func right_arrow() -> Button:
	return _right


## The width an arrow and its fade cover at either end.
func cover_width() -> float:
	return _right.get_combined_minimum_size().x + float(get_theme_constant(&"fade_width", THEME_TYPE))


## Whether there is more to see on the left (`direction` -1) or the right (1).
func can_scroll(direction: int) -> bool:
	return _can_scroll_from(float(_target) if _scrolling() else _scroll.get_h_scroll_bar().value, direction)


func _can_scroll_from(value: float, direction: int) -> bool:
	var bar: HScrollBar = _scroll.get_h_scroll_bar()
	if direction < 0:
		return value > bar.min_value + 0.5
	return value < bar.max_value - bar.page - 0.5


## The part of the content, in its own coordinates, that shows at scroll
## `from`: the row less the ends an arrow covers there.
func _visible_span(from: float) -> Vector2:
	var cover: float = cover_width()
	return Vector2(from + (cover if _can_scroll_from(from, -1) else 0.0),
			from + _scroll.size.x - (cover if _can_scroll_from(from, 1) else 0.0))


## Scrolls the next control cut off, hidden or under an arrow on the left
## (`direction` -1) or the right (1) fully into view, passing over one cut
## off by less than `MIN_STEP`; by the row's width when one control is wider
## than it. `animate` false jumps there (tests).
func step(direction: int, animate: bool = true) -> void:
	var from: float = float(_target if _scrolling() else _scroll.scroll_horizontal)
	var shown: Vector2 = _visible_span(from)
	var cover: float = cover_width()
	var to: float = from
	var spans: Array[Vector2] = _spans()
	if direction > 0:
		for span: Vector2 in spans:
			if span.y > shown.y + MIN_STEP:
				# Its right edge just clear of the › that may still show there.
				to = span.y - _scroll.size.x + cover
				break
		if to <= from:
			to = from + shown.y - shown.x
	else:
		for i: int in range(spans.size() - 1, -1, -1):
			if spans[i].x < shown.x - MIN_STEP:
				to = spans[i].x - cover
				break
		if to >= from:
			to = from - (shown.y - shown.x)
	scroll_to(roundi(to), animate)


## Scrolls `control` (in `content()`, or inside one of its controls) fully
## into view clear of the arrows; its leading edge when it is wider than
## that.
func reveal(control: Control, animate: bool = false) -> void:
	var left: float = control.get_global_rect().position.x - _content.get_global_rect().position.x
	var right: float = left + control.size.x
	var from: float = float(_target if _scrolling() else _scroll.scroll_horizontal)
	var shown: Vector2 = _visible_span(from)
	var cover: float = cover_width()
	var to: float = from
	if left < shown.x or right - left > _scroll.size.x - 2.0 * cover:
		to = left - cover
	elif right > shown.y:
		to = right - _scroll.size.x + cover
	if roundi(to) != roundi(from):
		scroll_to(roundi(to), animate)


## Scrolls to `x` pixels from the start, within bounds.
func scroll_to(x: int, animate: bool = true) -> void:
	var bar: HScrollBar = _scroll.get_h_scroll_bar()
	var end: int = maxi(0, roundi(bar.max_value - bar.page))
	_target = clampi(x, 0, end)
	if _tween != null:
		_tween.kill()
		_tween = null
	if not animate or not is_inside_tree():
		_scroll.scroll_horizontal = _target
		_update_arrows()
		return
	_tween = create_tween()
	_tween.tween_property(_scroll, ^"scroll_horizontal", _target, SCROLL_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.finished.connect(func() -> void: _tween = null)
	_update_arrows()


func _spans() -> Array[Vector2]:
	var spans: Array[Vector2] = []
	for child: Node in _content.get_children():
		var control: Control = child as Control
		if control != null and control.visible and not control.is_queued_for_deletion():
			spans.append(Vector2(control.position.x, control.position.x + control.size.x))
	return spans


func _scrolling() -> bool:
	return _tween != null and _tween.is_running()


func _on_focus_changed(control: Control) -> void:
	if control != null and _content.is_ancestor_of(control):
		reveal(control)


func _update() -> void:
	var overflowing: bool = _content.get_combined_minimum_size().x > size.x
	if overflowing != _overflowing:
		_overflowing = overflowing
		overflow_changed.emit(overflowing)
	_update_arrows()


## Each arrow, with its fade, shows only while there is more that way.
func _update_arrows() -> void:
	for entry: Array in [[_left, _left_fade, -1], [_right, _right_fade, 1]]:
		var more: bool = _overflowing and can_scroll(int(entry[2]))
		(entry[0] as Button).visible = more
		(entry[1] as Fade).visible = more
