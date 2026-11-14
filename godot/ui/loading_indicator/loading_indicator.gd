class_name LoadingIndicator
extends Control
## Shows that a panel is loading, drawn over it without taking clicks.
##
## Two cases: nothing to show yet (`blocking`: an empty list or diff), where a
## spinner in the accent colour turns in the middle with the caption below
## it, and old content kept while it loads again, where a thin line slides
## along the top edge and the content stays usable.
##
## Nothing appears for the first `SHOW_DELAY` seconds (fast loads never
## flash). The animation redraws at `FPS` frames a second, only while shown.

const SHOW_DELAY: float = 0.2
const FPS: float = 30.0
## Seconds per turn of the spinner.
const TURN: float = 0.9
## How much of the circle the spinner's arc covers.
const ARC: float = 0.3
## Seconds per sweep of the loading line.
const SWEEP: float = 1.6
const THEME_TYPE: StringName = &"LoadingIndicator"

var _active: bool = false
var _blocking: bool = false
var _caption: String = ""
var _started_msec: int = 0
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
		visible = false
		_tick.start(SHOW_DELAY)
	queue_redraw()


func hide_loading() -> void:
	_active = false
	visible = false
	_tick.stop()


func is_loading() -> bool:
	return _active


func is_blocking() -> bool:
	return _active and _blocking


## Whether the indicator is drawn (past the show delay).
func is_shown() -> bool:
	return _active and visible


## The caption under the spinner while nothing is shown.
func caption_text() -> String:
	return _caption if not _caption.is_empty() else tr("Loading…")


func _on_tick() -> void:
	if not _active:
		_tick.stop()
		return
	if not visible:
		visible = true
		_tick.start(1.0 / FPS)
	queue_redraw()


func _draw() -> void:
	if not _active:
		return
	if _blocking:
		# Nothing below is worth showing (stale rows of another file).
		draw_rect(Rect2(Vector2.ZERO, size), get_theme_color(&"backdrop", THEME_TYPE))
		_draw_center()
		return
	_draw_line()


## The spinner in the middle, with the caption under it.
func _draw_center() -> void:
	var side: float = float(get_theme_constant(&"spinner_size", THEME_TYPE))
	var gap: float = float(get_theme_constant(&"gap", THEME_TYPE))
	var font: Font = get_theme_default_font()
	var font_size: int = get_theme_default_font_size()
	var text: String = caption_text()
	var text_height: float = font.get_height(font_size)
	var top: float = (size.y - side - gap - text_height) * 0.5
	_draw_spinner(Vector2(size.x * 0.5, top + side * 0.5), side)
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var baseline: Vector2 = Vector2((size.x - width) * 0.5, top + side + gap + font.get_ascent(font_size))
	draw_string(font, baseline.round(), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
			get_theme_color(&"caption_color", THEME_TYPE))


## A faint ring with an arc turning around it, `side` pixels across.
func _draw_spinner(center: Vector2, side: float) -> void:
	draw_spinner(self, center, side, _elapsed())


## The spinner on `item` (with this theme type's colours), `elapsed` seconds
## into its turning; `LoadingSpinner` draws the same one inline.
static func draw_spinner(item: Control, center: Vector2, side: float, elapsed: float) -> void:
	var width: float = maxf(side * 0.12, 1.5)
	var radius: float = (side - width) * 0.5
	item.draw_arc(center, radius, 0.0, TAU, 48, item.get_theme_color(&"spinner_track", THEME_TYPE), width, true)
	var turn: float = fmod(elapsed / TURN, 1.0)
	var start: float = turn * TAU - PI * 0.5
	item.draw_arc(center, radius, start, start + ARC * TAU, 24, item.get_theme_color(&"spinner_color", THEME_TYPE),
			width, true)


## An indeterminate line along the top edge: a segment sliding across a
## faint track, easing in and out.
func _draw_line() -> void:
	var height: float = float(get_theme_constant(&"line_height", THEME_TYPE))
	draw_rect(Rect2(0.0, 0.0, size.x, height), get_theme_color(&"spinner_track", THEME_TYPE))
	var t: float = ease(fmod(_elapsed() / SWEEP, 1.0), -1.6)
	var segment: float = maxf(size.x * 0.3, 40.0)
	var x: float = -segment + t * (size.x + segment)
	var start: float = clampf(x, 0.0, size.x)
	var end: float = clampf(x + segment, 0.0, size.x)
	if end > start:
		draw_rect(Rect2(start, 0.0, end - start, height), get_theme_color(&"spinner_color", THEME_TYPE))


func _elapsed() -> float:
	return float(Time.get_ticks_msec() - _started_msec) / 1000.0
