class_name ToastLifetime
extends Timer

var visibility_guard: Callable = Callable()

@onready var _panel: Control = get_parent() as Control


func _ready() -> void:
	one_shot = true
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
	else:
		_panel.queue_free()
