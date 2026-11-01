class_name MarkStrip
extends Control
## A thin strip of marks over the whole length of a list (PLAN M7.6), beside
## its scroll bar: one bucket of flags per pixel from `overview_source`, a
## stronger mark at `current` (the selected match), and a click or drag
## emits `jumped` with the fraction of the list there. `runs` merges equal
## buckets for drawing; `DiffMinimap`'s strip uses it too.

signal jumped(fraction: float)

const THEME_TYPE: StringName = &"MarkStrip"

## `(buckets) -> PackedByteArray`: a byte of flags per bucket, 0 for none.
var overview_source: Callable = Callable()
## Where the current mark is, 0..1 of the length; -1 for none.
var current: float = -1.0:
	set(value):
		if not is_equal_approx(value, current):
			current = value
			queue_redraw()

var _overview: PackedByteArray = PackedByteArray()
var _buckets: int = -1


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		refresh()


## Width the strip takes beside its list.
func strip_width() -> float:
	return float(get_theme_constant(&"width", THEME_TYPE))


## Fetches the marks again (they or the list's length changed).
func refresh() -> void:
	_buckets = -1
	queue_redraw()


## The flags, one bucket per pixel of height, fetched once per size and
## `refresh`.
func overview() -> PackedByteArray:
	var buckets: int = maxi(1, int(size.y))
	if buckets != _buckets:
		_overview = overview_source.call(buckets) if overview_source.is_valid() else PackedByteArray()
		_buckets = buckets
	return _overview


## Runs of equal, non-zero flags: `(first bucket, bucket count, flags)`.
static func runs(flags: PackedByteArray) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var start: int = 0
	for i: int in range(1, flags.size() + 1):
		if i < flags.size() and flags[i] == flags[start]:
			continue
		if flags[start] != 0:
			out.append(Vector3i(start, i - start, flags[start]))
		start = i
	return out


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), get_theme_color(&"background", THEME_TYPE))
	var flags: PackedByteArray = overview()
	var step: float = size.y / maxf(1.0, float(flags.size()))
	var min_mark: float = float(get_theme_constant(&"min_mark", THEME_TYPE))
	var mark: Color = get_theme_color(&"mark_color", THEME_TYPE)
	for run: Vector3i in runs(flags):
		draw_rect(Rect2(0.0, run.x * step, size.x, maxf(min_mark, run.y * step)), mark)
	if current >= 0.0:
		var height: float = float(get_theme_constant(&"current_height", THEME_TYPE))
		var top: float = clampf(current * size.y - height / 2.0, 0.0, maxf(0.0, size.y - height))
		draw_rect(Rect2(0.0, top, size.x, height), get_theme_color(&"current_color", THEME_TYPE))


func _gui_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
		jumped.emit(clampf(button.position.y / maxf(1.0, size.y), 0.0, 1.0))
		accept_event()
	elif motion != null and (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		jumped.emit(clampf(motion.position.y / maxf(1.0, size.y), 0.0, 1.0))
		accept_event()
