class_name AutoScroll
extends CanvasLayer
## Browser-style middle-click autoscroll (PLAN M7.6) for every `VirtualList`,
## `ScrollContainer`, `Tree`, `ItemList` and `TextEdit` in a window.
##
## A quick middle click (released within `STICKY_MSEC` without leaving the
## dead zone) keeps scrolling until the next click or key; holding the button
## scrolls only while it is held. The speed grows with the mouse's distance
## from the click past a dead zone, on the axes the target can scroll. Any
## mouse button (swallowed), a wheel turn (which then scrolls as usual), Esc
## (swallowed), any other key (passed on), focus loss or the target hiding
## stops it. While it runs, the speed follows the OS cursor, also past the
## window's edge (headless runs use the input events' positions).
##
## One instance per window reads middle presses in `_input`, before the
## controls do, and starts on the innermost scrollable under the mouse (the
## hovered control, or a hit test where hover is not tracked, as in headless
## runs).
## Controls with a middle click of their own join `OWN_MIDDLE_CLICK`; line
## edits keep theirs, and so do text edits that paste the primary selection
## on a middle click (Linux). Call `enable(control)` for each scrollable: it
## adds the window's instance when there is none yet.

const THEME_TYPE: StringName = &"AutoScroll"
## Controls in this group (and their children) keep their middle click.
const OWN_MIDDLE_CLICK: StringName = &"own_middle_click"
## A middle click released this soon (ms) without leaving the dead zone
## keeps scrolling after the release.
const STICKY_MSEC: int = 250
## Above every other layer of the window.
const LAYER: int = 128
const META: StringName = &"auto_scroll"

enum Mode { IDLE, HOLD, STICKY }

var _mode: Mode = Mode.IDLE
var _target: Control = null
## Axes the target can scroll, 0 or 1 each.
var _axes: Vector2i = Vector2i.ZERO
var _anchor: Vector2 = Vector2.ZERO
## The mouse in the viewport's coordinates, from its last event.
var _mouse: Vector2 = Vector2.ZERO
var _pressed_msec: int = 0
## Whether the mouse left the dead zone since the press.
var _moved: bool = false
## Fractions of a pixel not scrolled yet.
var _carry: Vector2 = Vector2.ZERO
## Buttons whose press was swallowed, so their release is too.
var _swallow: Dictionary[MouseButton, bool] = {}
var _cursor: DisplayServer.CursorShape = DisplayServer.CURSOR_ARROW
var _marker: Control = Control.new()


## Makes middle-click autoscroll work in `control`'s window.
static func enable(control: Control) -> void:
	if control.is_inside_tree():
		_ensure(control.get_viewport())
	control.tree_entered.connect(func() -> void: _ensure(control.get_viewport()))


## The instance of `viewport`'s window, or null before `enable`.
static func of(viewport: Viewport) -> AutoScroll:
	if viewport == null or not viewport.has_meta(META):
		return null
	var node: Object = viewport.get_meta(META)
	return node as AutoScroll if is_instance_valid(node) else null


static func _ensure(viewport: Viewport) -> void:
	if viewport == null or of(viewport) != null:
		return
	var node: AutoScroll = AutoScroll.new()
	node.name = "AutoScroll"
	viewport.set_meta(META, node)
	viewport.add_child.call_deferred(node, false, Node.INTERNAL_MODE_FRONT)


func _init() -> void:
	layer = LAYER
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.draw.connect(_draw_marker)
	set_process(false)


func _ready() -> void:
	add_child(_marker)
	_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var window: Window = get_viewport() as Window
	if window != null:
		window.focus_exited.connect(stop)


func is_active() -> bool:
	return _mode != Mode.IDLE


## Whether it keeps scrolling after the middle button's release.
func is_sticky() -> bool:
	return _mode == Mode.STICKY


func target() -> Control:
	return _target


func stop() -> void:
	if _mode == Mode.IDLE:
		return
	_mode = Mode.IDLE
	_target = null
	_carry = Vector2.ZERO
	set_process(false)
	_marker.queue_redraw()
	_set_cursor(DisplayServer.CURSOR_ARROW)


func _input(event: InputEvent) -> void:
	var mouse: InputEventMouse = event as InputEventMouse
	if mouse != null:
		_mouse = mouse.position
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null:
		_on_button(button)
		return
	if _mode == Mode.IDLE:
		return
	if event is InputEventMouseMotion:
		# No hover effects while scrolling.
		get_viewport().set_input_as_handled()
		return
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed:
		stop()
		if key.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()


func _on_button(button: InputEventMouseButton) -> void:
	if not button.pressed:
		if _swallow.has(button.button_index):
			_swallow.erase(button.button_index)
			get_viewport().set_input_as_handled()
			if button.button_index == MOUSE_BUTTON_MIDDLE and _mode == Mode.HOLD:
				if not _moved and Time.get_ticks_msec() - _pressed_msec <= STICKY_MSEC:
					_mode = Mode.STICKY
				else:
					stop()
		return
	var wheel: bool = button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN,
			MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]
	if _mode != Mode.IDLE:
		stop()
		if not wheel:
			_swallow[button.button_index] = true
			get_viewport().set_input_as_handled()
		return
	if button.button_index == MOUSE_BUTTON_MIDDLE and _start(button.position):
		_swallow[MOUSE_BUTTON_MIDDLE] = true
		get_viewport().set_input_as_handled()


## Starts on the innermost scrollable under the mouse; false when there is
## none or a control there keeps its own middle click.
func _start(at: Vector2) -> bool:
	var node: Node = get_viewport().gui_get_hovered_control()
	if node == null:
		node = control_at(get_viewport(), at)
	while node != null:
		var control: Control = node as Control
		if control != null:
			if control.is_in_group(OWN_MIDDLE_CLICK) or control is LineEdit or _pastes(control):
				return false
			var axes: Vector2i = scroll_axes(control)
			if axes != Vector2i.ZERO:
				_begin(control, axes)
				return true
		if node is Window:
			break
		node = node.get_parent()
	return false


## The topmost control at `at` that takes the mouse, as the viewport picks
## it (children before parents, later siblings first, clipped by
## `clip_contents`), searching controls and canvas layers from the top.
static func control_at(viewport: Viewport, at: Vector2) -> Control:
	var layers: Array[Node] = [viewport]
	for child: Node in viewport.get_children(true):
		if child is CanvasLayer and (child as CanvasLayer).visible:
			layers.append(child)
	layers.sort_custom(func(a: Node, b: Node) -> bool: return _layer(a) > _layer(b))
	for node: Node in layers:
		var hit: Control = _control_in(node, at)
		if hit != null:
			return hit
	return null


static func _layer(node: Node) -> int:
	return (node as CanvasLayer).layer if node is CanvasLayer else 0


static func _control_in(node: Node, at: Vector2) -> Control:
	for i: int in range(node.get_child_count(true) - 1, -1, -1):
		var child: Node = node.get_child(i, true)
		var control: Control = child as Control
		if control == null:
			# Controls under a plain node are roots of their own; skip other
			# canvas items, layers (searched apart) and windows.
			if not (child is CanvasItem or child is CanvasLayer or child is Window):
				var nested: Control = _control_in(child, at)
				if nested != null:
					return nested
			continue
		if not control.visible:
			continue
		var inside: bool = control.get_global_rect().has_point(at)
		if control.clip_contents and not inside:
			continue
		var hit: Control = _control_in(control, at)
		if hit != null:
			return hit
		if inside and control.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			return control
	return null


func _begin(control: Control, axes: Vector2i) -> void:
	_target = control
	_axes = axes
	_mode = Mode.HOLD
	_anchor = _mouse
	_pressed_msec = Time.get_ticks_msec()
	_moved = false
	_carry = Vector2.ZERO
	set_process(true)
	_marker.queue_redraw()
	_set_cursor(DisplayServer.CURSOR_MOVE if axes == Vector2i.ONE
			else DisplayServer.CURSOR_VSIZE if axes.y == 1 else DisplayServer.CURSOR_HSIZE)


## Whether `control` is a text edit whose middle click pastes the primary
## selection.
static func _pastes(control: Control) -> bool:
	var text: TextEdit = control as TextEdit
	return text != null and text.middle_mouse_paste_enabled 			and DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD_PRIMARY)


## Axes `control` can scroll now (0 or 1 each): a `VirtualList` by its rows
## (and a `DiffView` sideways), the others by their scroll bars.
static func scroll_axes(control: Control) -> Vector2i:
	var list: VirtualList = control as VirtualList
	if list != null:
		return list.scroll_axes()
	var scroll: ScrollContainer = control as ScrollContainer
	if scroll != null:
		return Vector2i(
			1 if scroll.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED
					and _can_scroll(scroll.get_h_scroll_bar()) else 0,
			1 if scroll.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED
					and _can_scroll(scroll.get_v_scroll_bar()) else 0)
	# These hide a bar they do not need.
	var bars: Array[ScrollBar] = _bars(control)
	return Vector2i(1 if bars[0] != null and bars[0].visible and _can_scroll(bars[0]) else 0,
			1 if bars[1] != null and bars[1].visible and _can_scroll(bars[1]) else 0)


## The horizontal and vertical scroll bars of a `Tree`, `ItemList` or
## `TextEdit` (null where it has none).
static func _bars(control: Control) -> Array[ScrollBar]:
	var bars: Array[ScrollBar] = [null, null]
	var text: TextEdit = control as TextEdit
	var items: ItemList = control as ItemList
	if text != null:
		bars = [text.get_h_scroll_bar(), text.get_v_scroll_bar()]
	elif items != null:
		bars = [null, items.get_v_scroll_bar()]
	elif control is Tree:
		# A tree keeps its bars as internal children.
		for child: Node in control.get_children(true):
			if child is HScrollBar:
				bars[0] = child as ScrollBar
			elif child is VScrollBar:
				bars[1] = child as ScrollBar
	return bars


static func _can_scroll(bar: ScrollBar) -> bool:
	return bar.max_value - bar.page > bar.min_value


## Pixels one step of `scroll_by` scrolls `control` on each axis: a line of a
## `TextEdit` vertically (its offset counts lines), else a pixel.
static func step_size(control: Control) -> Vector2:
	var text: TextEdit = control as TextEdit
	return Vector2(1.0, float(maxi(1, text.get_line_height()))) if text != null else Vector2.ONE


## Scrolls `control` by `delta` whole steps (`step_size`).
static func scroll_by(control: Control, delta: Vector2i) -> void:
	var list: VirtualList = control as VirtualList
	if list != null:
		list.scroll_by(Vector2(delta))
		return
	var scroll: ScrollContainer = control as ScrollContainer
	if scroll != null:
		scroll.scroll_horizontal += delta.x
		scroll.scroll_vertical += delta.y
		return
	var text: TextEdit = control as TextEdit
	if text != null:
		text.scroll_horizontal += delta.x
		text.scroll_vertical += delta.y
		return
	var bars: Array[ScrollBar] = _bars(control)
	for axis: int in 2:
		if bars[axis] != null and delta[axis] != 0:
			bars[axis].value += delta[axis]


## Speed in pixels a second for an offset of `distance` pixels from the
## anchor on one axis.
func speed(distance: float) -> float:
	var dead: float = float(_marker.get_theme_constant(&"dead_zone", THEME_TYPE))
	var past: float = absf(distance) - dead
	if past <= 0.0:
		return 0.0
	var rate: float = _marker.get_theme_constant(&"speed_percent", THEME_TYPE) / 100.0
	var top: float = float(_marker.get_theme_constant(&"max_speed", THEME_TYPE))
	return signf(distance) * minf(top, rate * pow(past, 1.5))


func _process(delta: float) -> void:
	if not is_instance_valid(_target) or not _target.is_visible_in_tree():
		stop()
		return
	if DisplayServer.get_name() != "headless":
		_mouse = os_mouse()
	var from_anchor: Vector2 = _mouse - _anchor
	var dead: float = float(_marker.get_theme_constant(&"dead_zone", THEME_TYPE))
	if absf(from_anchor.x) > dead or absf(from_anchor.y) > dead:
		_moved = true
	var step: Vector2 = Vector2(speed(from_anchor.x) * _axes.x, speed(from_anchor.y) * _axes.y) * delta 			/ step_size(_target) + _carry
	var whole: Vector2i = Vector2i(int(step.x), int(step.y))
	_carry = step - Vector2(whole)
	if whole != Vector2i.ZERO:
		scroll_by(_target, whole)


## The OS cursor in this viewport's coordinates, wherever it is on screen
## (the last event's position when the window is not a native one).
func os_mouse() -> Vector2:
	var viewport: Viewport = get_viewport()
	var host: Window = viewport as Window
	while host != null and host.is_embedded():
		host = host.get_embedder() as Window
	if host == null:
		return _mouse
	var local: Vector2i = DisplayServer.mouse_get_position() - DisplayServer.window_get_position(host.get_window_id())
	return viewport.get_screen_transform().affine_inverse() * Vector2(local)


func _set_cursor(shape: DisplayServer.CursorShape) -> void:
	if shape == _cursor:
		return
	_cursor = shape
	DisplayServer.cursor_set_shape(shape)


func _draw_marker() -> void:
	if _mode == Mode.IDLE:
		return
	var icon_name: StringName = &"AutoScroll" if _axes == Vector2i.ONE \
			else &"AutoScrollVertical" if _axes.y == 1 else &"AutoScrollHorizontal"
	var texture: Texture2D = AppTheme.icon(icon_name)
	if texture != null:
		_marker.draw_texture(texture, (_anchor - texture.get_size() / 2.0).round())
