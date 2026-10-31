class_name BigButton
extends Button
## A large header button (Branch, Sync; PLAN §4): an icon and a caption, an
## optional ▾ part on the right that asks for a menu instead of pressing, and
## a busy state that shows a running job (spinner, text and progress line).

## The ▾ part was clicked (only with `has_menu`).
signal menu_requested()

const THEME_TYPE: StringName = &"BigButton"
## Seconds per spinner frame.
const SPIN_SECONDS: float = 0.08

## Whether the right edge has a ▾ part (see `menu_requested`).
@export var has_menu: bool = false:
	set(value):
		has_menu = value
		theme_type_variation = &"BigMenuButton" if value else THEME_TYPE
		queue_redraw()

var _busy: bool = false
var _percent: int = -1
var _idle_text: String = ""
var _idle_icon: Texture2D = null
var _idle_disabled: bool = false
var _frame: int = 0
var _spin: Timer = Timer.new()


func _ready() -> void:
	theme_type_variation = &"BigMenuButton" if has_menu else THEME_TYPE
	_spin.wait_time = SPIN_SECONDS
	_spin.timeout.connect(_next_frame)
	add_child(_spin)


## Shows a running job (`busy`): the spinner, `text` and, when `percent` is
## known, a progress line; the button is disabled until it ends.
func set_busy(busy: bool, text_value: String, percent: int) -> void:
	if busy and not _busy:
		_idle_text = text
		_idle_icon = icon
		_idle_disabled = disabled
		_spin.start()
	elif not busy and _busy:
		_spin.stop()
		text = _idle_text
		icon = _idle_icon
		disabled = _idle_disabled
	_busy = busy
	_percent = percent if busy else -1
	if busy:
		text = text_value
		disabled = true
		icon = AppTheme.spinner(_frame, ThemeManager.light)
	queue_redraw()


func is_busy() -> bool:
	return _busy


## Sets the caption and icon (kept for when a job ends, while busy).
func show_state(caption: String, state_icon: Texture2D, enabled: bool) -> void:
	if _busy:
		_idle_text = caption
		_idle_icon = state_icon
		_idle_disabled = not enabled
		return
	text = caption
	icon = state_icon
	disabled = not enabled


func _gui_input(event: InputEvent) -> void:
	var click: InputEventMouseButton = event as InputEventMouseButton
	if has_menu and click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT \
			and click.position.x >= size.x - _arrow_width():
		accept_event()
		menu_requested.emit()


func _draw() -> void:
	if has_menu:
		var arrow: Texture2D = AppTheme.ARROW_DOWN
		var width: float = _arrow_width()
		var x: float = size.x - width
		var line: Color = get_theme_color(&"separator_color", THEME_TYPE)
		# Full height, like the line of every split button.
		draw_line(Vector2(x, 0.0), Vector2(x, size.y), line, 1.0)
		var at: Vector2 = Vector2(x + (width - arrow.get_width()) * 0.5, (size.y - arrow.get_height()) * 0.5)
		draw_texture(arrow, at, Color(1, 1, 1, 0.5 if disabled and not _busy else 1.0))
	if _busy and _percent >= 0:
		var bar: Color = get_theme_color(&"progress_color", THEME_TYPE)
		var height: float = 2.0
		draw_rect(Rect2(4.0, size.y - height - 2.0, (size.x - 8.0) * clampf(_percent / 100.0, 0.0, 1.0), height), bar)


func _arrow_width() -> float:
	return float(get_theme_constant(&"arrow_width", THEME_TYPE)) if has_menu else 0.0


func _next_frame() -> void:
	_frame = (_frame + 1) % AppTheme.SPINNER_FRAMES
	icon = AppTheme.spinner(_frame, ThemeManager.light)
