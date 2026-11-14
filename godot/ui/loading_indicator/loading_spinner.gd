class_name LoadingSpinner
extends Control
## `LoadingIndicator`'s spinner at text size, for a line that says something
## is being checked ("Checking…" in a delete dialog's row). It redraws at
## `LoadingIndicator.FPS` frames a second, only while visible.

var _started_msec: int = Time.get_ticks_msec()
var _tick: Timer = Timer.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tick.wait_time = 1.0 / LoadingIndicator.FPS
	_tick.timeout.connect(queue_redraw)
	add_child(_tick)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_THEME_CHANGED:
			var side: float = float(get_theme_constant(&"inline_size", LoadingIndicator.THEME_TYPE))
			custom_minimum_size = Vector2(side, side)
		NOTIFICATION_READY, NOTIFICATION_VISIBILITY_CHANGED:
			# The timer is in the tree once this is ready.
			if not _tick.is_inside_tree():
				return
			if is_visible_in_tree():
				_tick.start()
			else:
				_tick.stop()


func _draw() -> void:
	var side: float = minf(size.x, size.y)
	var elapsed: float = float(Time.get_ticks_msec() - _started_msec) / 1000.0
	LoadingIndicator.draw_spinner(self, size * 0.5, side, elapsed)
