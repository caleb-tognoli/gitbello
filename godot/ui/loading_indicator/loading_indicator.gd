class_name LoadingIndicator
extends Control
## Shows that a panel is loading, drawn over it without taking clicks.
##
## Two cases: nothing to show yet (`blocking`: an empty list or diff) and old
## content kept while it loads again (an overlay that leaves it usable). Each
## area has its style (`STYLES`):
##
## - `bar` (the Changes list, History): a thin sliding bar along the top edge,
##   with the caption in the middle while nothing is shown.
## - `spinner` (diffs): a turning spinner and the caption; over old content, a
##   small pill with a spinner in a corner.
## - `quiet` (a commit's files): the caption only; over old content, a small
##   pill in a corner.
##
## Nothing appears for the first `SHOW_DELAY` seconds (fast loads never
## flash), and after `ELAPSED_AFTER` seconds the caption counts the seconds,
## so a slow load still shows it is alive. Animations tick at a few frames a
## second and only while shown.

const STYLES: Dictionary[String, String] = {
	"changes": "bar", "diff": "spinner", "history": "bar", "details": "quiet",
}
const SHOW_DELAY: float = 0.2
const ELAPSED_AFTER: float = 2.0
## Seconds per animation frame, by style.
const TICK: Dictionary[String, float] = {"quiet": 1.0, "spinner": 0.1, "bar": 0.05}
const THEME_TYPE: StringName = &"LoadingIndicator"

## The area shown loading: one of `STYLES`' keys.
@export var area: String = "diff"

var _active: bool = false
var _blocking: bool = false
var _caption: String = ""
var _started_msec: int = 0
var _frame: int = 0
var _tick: Timer = Timer.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	_tick.one_shot = false
	_tick.timeout.connect(_on_tick)
	add_child(_tick)


## Starts showing a load: `blocking` when there is nothing to show meanwhile.
## Calling it again while active only updates the caption and the case.
func show_loading(blocking: bool, caption: String = "") -> void:
	_caption = caption
	_blocking = blocking
	if not _active:
		_active = true
		_started_msec = Time.get_ticks_msec()
		_frame = 0
		visible = false
		_tick.start(SHOW_DELAY)
	elif visible:
		_restart_tick()
	queue_redraw()


func hide_loading() -> void:
	_active = false
	visible = false
	_tick.stop()


func is_loading() -> bool:
	return _active


func is_blocking() -> bool:
	return _active and _blocking


## The area's style.
func current_style() -> String:
	return STYLES.get(area, "quiet")


## The caption with the seconds so far, once the load takes a while.
func caption_text() -> String:
	var text: String = _caption if not _caption.is_empty() else tr("Loading…")
	var seconds: int = int(_elapsed())
	if _elapsed() >= ELAPSED_AFTER:
		text = "%s · %s" % [text, tr("%d s") % seconds]
	return text


## Pretends the load started `seconds` ago (screenshots of a slow load).
func pretend_elapsed(seconds: float) -> void:
	_started_msec = Time.get_ticks_msec() - int(seconds * 1000.0)
	queue_redraw()


func _elapsed() -> float:
	return float(Time.get_ticks_msec() - _started_msec) / 1000.0


func _restart_tick() -> void:
	_tick.start(TICK.get(current_style(), 1.0))


func _on_tick() -> void:
	if not _active:
		_tick.stop()
		return
	if not visible:
		visible = true
		_restart_tick()
	_frame += 1
	queue_redraw()


func _draw() -> void:
	if not _active:
		return
	var style: String = current_style()
	if _blocking:
		# Nothing below is worth showing (stale rows of another file).
		draw_rect(Rect2(Vector2.ZERO, size), get_theme_color(&"backdrop", THEME_TYPE))
		if style == "spinner":
			_draw_spinner_center()
			return
		if style == "bar":
			_draw_bar()
		_draw_caption_center(0.0)
		return
	match style:
		"spinner":
			_draw_pill(true)
		"bar":
			_draw_bar()
		_:
			_draw_pill(false)


func _font() -> Font:
	return get_theme_default_font()


func _font_size() -> int:
	return get_theme_default_font_size()


func _draw_caption_center(offset_y: float) -> void:
	var font: Font = _font()
	var font_size: int = _font_size()
	var text: String = caption_text()
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var at: Vector2 = Vector2((size.x - width) * 0.5, size.y * 0.5 + offset_y + font.get_ascent(font_size) * 0.5)
	draw_string(font, at.round(), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
			get_theme_color(&"caption_color", THEME_TYPE))


func _draw_spinner_center() -> void:
	var side: float = float(get_theme_constant(&"spinner_size", THEME_TYPE))
	var texture: Texture2D = AppTheme.spinner(_frame, ThemeManager.light)
	var gap: float = float(get_theme_constant(&"gap", THEME_TYPE))
	var top: float = size.y * 0.5 - side - gap * 0.5
	draw_texture_rect(texture, Rect2(Vector2((size.x - side) * 0.5, top).round(), Vector2(side, side)), false)
	_draw_caption_center(gap + float(_font_size()) * 0.5)


## A small rounded label in the top right corner, with a spinner when asked.
func _draw_pill(spin: bool) -> void:
	var font: Font = _font()
	var font_size: int = _font_size() - 1
	var text: String = caption_text()
	var pad: float = float(get_theme_constant(&"pill_padding", THEME_TYPE))
	var margin: float = float(get_theme_constant(&"pill_margin", THEME_TYPE))
	var icon: float = float(font_size) if spin else 0.0
	var text_width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var width: float = text_width + pad * 2.0 + (icon + pad * 0.5 if spin else 0.0)
	var height: float = float(font_size) + pad * 1.4
	var rect: Rect2 = Rect2(Vector2(size.x - width - margin, margin).round(), Vector2(width, height)).abs()
	var box: StyleBox = get_theme_stylebox(&"pill", THEME_TYPE)
	draw_style_box(box, rect)
	var x: float = rect.position.x + pad
	if spin:
		var texture: Texture2D = AppTheme.spinner(_frame, ThemeManager.light)
		draw_texture_rect(texture, Rect2(Vector2(x, rect.position.y + (height - icon) * 0.5).round(), Vector2(icon, icon)), false)
		x += icon + pad * 0.5
	var baseline: float = rect.position.y + (height + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	draw_string(font, Vector2(x, baseline).round(), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
			get_theme_color(&"caption_color", THEME_TYPE))


## An indeterminate bar along the top edge: a segment sliding across.
func _draw_bar() -> void:
	var height: float = float(get_theme_constant(&"bar_height", THEME_TYPE))
	draw_rect(Rect2(0.0, 0.0, size.x, height), get_theme_color(&"bar_track", THEME_TYPE))
	var period: int = 40  # frames per sweep (2 s at the bar's tick)
	var t: float = float(_frame % period) / float(period)
	var segment: float = maxf(size.x * 0.3, 40.0)
	var x: float = -segment + t * (size.x + segment)
	var start: float = clampf(x, 0.0, size.x)
	var end: float = clampf(x + segment, 0.0, size.x)
	if end > start:
		draw_rect(Rect2(start, 0.0, end - start, height), get_theme_color(&"bar_color", THEME_TYPE))
