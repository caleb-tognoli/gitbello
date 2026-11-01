class_name ToastLifetime
extends Timer
## A success toast's lifetime: paused while the toast is hovered or focused
## (or `visibility_guard` says so), drawn on `countdown`, and ended by a fade.

var visibility_guard: Callable = Callable()
## Shows the time left, from full to empty.
var countdown: ProgressBar = null
var fade_seconds: float = 0.0

## The full lifetime (`wait_time` changes when a deadline is postponed).
var _duration: float = 0.0

@onready var _panel: Control = get_parent() as Control


func _ready() -> void:
	one_shot = true
	_duration = wait_time
	timeout.connect(_on_timeout)
	_panel.mouse_entered.connect(_queue_refresh)
	_panel.mouse_exited.connect(_queue_refresh)
	_panel.item_rect_changed.connect(_queue_refresh)
	_panel.focus_entered.connect(_queue_refresh)
	_panel.focus_exited.connect(_queue_refresh)
	for node: Node in _panel.find_children("*", "Control", true, false):
		var control: Control = node as Control
		control.focus_entered.connect(_queue_refresh)
		control.focus_exited.connect(_queue_refresh)
	start()
	_queue_refresh()


func _process(_delta: float) -> void:
	if countdown != null and not paused and not is_stopped() and _duration > 0.0:
		countdown.value = 100.0 * clampf(time_left / _duration, 0.0, 1.0)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_queue_refresh()


func _queue_refresh() -> void:
	_refresh.call_deferred()


func _refresh() -> void:
	if _panel.is_queued_for_deletion():
		return
	paused = (visibility_guard.is_valid() and bool(visibility_guard.call())) \
			or _contains(get_viewport().gui_get_hovered_control()) \
			or _contains(get_viewport().gui_get_focus_owner())


func _contains(control: Control) -> bool:
	return control != null and (control == _panel or _panel.is_ancestor_of(control))


func _on_timeout() -> void:
	_refresh()
	if paused:
		start(0.001)
		return
	set_process(false)
	set_process_input(false)
	if fade_seconds <= 0.0:
		_panel.queue_free()
		return
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fade: Tween = _panel.create_tween()
	fade.tween_property(_panel, ^"modulate:a", 0.0, fade_seconds)
	fade.tween_callback(_panel.queue_free)
