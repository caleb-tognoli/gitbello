class_name ImageDiffView
extends Control
## The old and new image of a diff (M7.8 P2), in one of the image modes:
## `split` (old | new, each in its half with a caption), `onion` (new over old
## with an opacity slider), `swipe` (a divider dragged across shows old on
## its left and new on its right), `difference` (changed pixels highlighted,
## a shader) or `single` (the only side, centred). Images of different sizes
## line up at their top-left corners in the overlay modes.
##
## Opens fitted: a large image shrinks to fit, a small one grows by whole
## steps (200%, 300%…). The wheel zooms at the cursor by whole levels (see
## `ZoomLevels`), a drag (left or middle button) pans, Shift+wheel and the
## horizontal wheel pan sideways and a double-click switches between fit and
## 100%. An image never leaves the view: smaller than it along an axis, it
## stays centred; larger, its edges stop at the view's. Split halves share
## zoom and pan. A zoom bar floats over the top-right corner (fit, zoom out,
## the zoom, which goes to 100%, and zoom in). Left/Right move the onion
## opacity or the divider by 10% (Shift: 1%) while it has focus. A
## checkerboard sits behind transparent pixels. Textures come from
## `set_side`; `decode` turns a side's bytes into an `Image` (callable from a
## worker thread).

## Zoom or pan changed.
signal view_changed()
## A right-click over `side` (OLD or NEW, shown) at `at`.
signal side_menu_requested(side: int, at: Vector2)

const THEME_TYPE: StringName = &"ImageDiff"
const OLD: int = 0
const NEW: int = 1
## A zoom step goes at least this far, to the next whole level.
const ZOOM_STEP: float = 1.25
const MIN_ZOOM: float = 0.02
const MAX_ZOOM: float = 64.0
const WHEEL_PAN: float = 48.0
## The zoom bar's buttons, in order.
const BAR_BUTTONS: Array[StringName] = [&"fit", &"zoom_out", &"actual", &"zoom_in"]
const DIFFERENCE_SHADER: Shader = preload("res://ui/image_diff/image_difference.gdshader")
const MODES: PackedStringArray = ["split", "onion", "swipe", "difference", "single"]

enum Drag { NONE, PAN, DIVIDER }

## How the images show; see the class description.
var mode: String = "split":
	set = set_mode
## Zoom, pan, divider and keys; off for the conflict card's previews.
var interactive: bool = true:
	set(value):
		interactive = value
		focus_mode = Control.FOCUS_ALL if value else Control.FOCUS_NONE
		_update_slider()
		_update_bar()
## Captions under the halves in split mode (old, new), drawn as given (the
## caller translates them; branch names stay as they are).
var captions: PackedStringArray = PackedStringArray(["Old", "New"]):
	set(value):
		captions = value
		queue_redraw()

var _textures: Array[Texture2D] = [null, null]
## The id of the bytes each side shows (set by the caller, to skip decoding
## the same image again).
var ids: PackedStringArray = PackedStringArray(["", ""])
## Size each side shows at 100% (an SVG renders sharper than this).
var _sizes: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
var _messages: PackedStringArray = PackedStringArray(["", ""])
## 0 fits the images to the view; otherwise the scale.
var _zoom: float = 0.0
## How far the images are moved from centred (kept inside `_pan_room`).
var _pan: Vector2 = Vector2.ZERO
## Wheel notches not zoomed by yet: touchpads scroll by parts of a notch.
var _wheel_notches: float = 0.0
## The zoom bar (an opaque backing, so disabled buttons do not show the
## image through), its row and its buttons by BAR_BUTTONS id.
var _bar: PanelContainer = PanelContainer.new()
var _bar_row: HBoxContainer = HBoxContainer.new()
var _bar_buttons: Dictionary[StringName, Button] = {}
var _onion: float = 0.5
var _swipe: float = 0.5
var _drag: Drag = Drag.NONE
var _checker: ImageTexture = null
var _blank: ImageTexture = null
var _slider: HSlider = HSlider.new()
## Draws the difference with the shader, above this control's checkerboard.
var _layer: Control = Control.new()
var _material: ShaderMaterial = ShaderMaterial.new()


func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_ALL if interactive else Control.FOCUS_NONE
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	_material.shader = DIFFERENCE_SHADER
	_layer.material = _material
	_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_layer.draw.connect(_draw_difference)
	add_child(_layer)
	_slider.min_value = 0.0
	_slider.max_value = 1.0
	_slider.step = 0.01
	_slider.value = _onion
	_slider.focus_mode = Control.FOCUS_NONE
	_slider.custom_minimum_size.x = 240.0
	_slider.value_changed.connect(func(value: float) -> void:
		_onion = value
		queue_redraw())
	add_child(_slider)
	_build_bar()
	resized.connect(_on_resized)
	_apply_theme()
	_update_slider()
	_update_bar()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()
	elif what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_slider.tooltip_text = tr("Opacity of the new image")
		_update_bar()
		queue_redraw()


func _apply_theme() -> void:
	var cell: int = maxi(1, get_theme_constant(&"checker_size", THEME_TYPE))
	var image: Image = Image.create_empty(cell * 2, cell * 2, false, Image.FORMAT_RGBA8)
	image.fill(get_theme_color(&"checker_light", THEME_TYPE))
	var dark: Color = get_theme_color(&"checker_dark", THEME_TYPE)
	image.fill_rect(Rect2i(0, 0, cell, cell), dark)
	image.fill_rect(Rect2i(cell, cell, cell, cell), dark)
	_checker = ImageTexture.create_from_image(image)
	var blank: Image = Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	blank.fill(Color.WHITE)
	_blank = ImageTexture.create_from_image(blank)
	_material.set_shader_parameter(&"changed_color", get_theme_color(&"changed_color", THEME_TYPE))
	_slider.tooltip_text = tr("Opacity of the new image")
	for id: StringName in [&"fit", &"zoom_out", &"zoom_in"]:
		_bar_buttons[id].icon = AppTheme.icon({&"fit": &"ZoomFit", &"zoom_out": &"ZoomOut", &"zoom_in": &"ZoomIn"}[id])
	_place_slider()
	_place_bar()
	queue_redraw()


func set_mode(value: String) -> void:
	mode = value if value in MODES else "split"
	if is_node_ready():
		_update_slider()
		_changed()


## Shows `texture` for `side` (OLD or NEW) at `logical_size` (its pixels at
## 100%; the texture may be larger, an SVG rendered sharper), or `text`
## in its place when `image` is null ("" leaves the place empty).
func set_side(side: int, image: Texture2D, logical_size: Vector2 = Vector2.ZERO, text: String = "") -> void:
	_textures[side] = image
	_sizes[side] = logical_size if logical_size != Vector2.ZERO \
			else (image.get_size() if image != null else Vector2.ZERO)
	_messages[side] = text
	_changed()


## Drops both images, back to fitted, the divider and opacity in the middle.
func clear() -> void:
	for side: int in 2:
		_textures[side] = null
		_sizes[side] = Vector2.ZERO
		_messages[side] = ""
		ids[side] = ""
	_onion = 0.5
	_swipe = 0.5
	_slider.set_value_no_signal(_onion)
	fit()


func texture(side: int) -> Texture2D:
	return _textures[side]


func message(side: int) -> String:
	return _messages[side]


## Fits the images to the view: a large image shrinks, a small one grows by
## whole steps.
func fit() -> void:
	_zoom = 0.0
	_pan = Vector2.ZERO
	_changed()


## Shows the images at 100% (the whole level nearest it), keeping the point
## under `anchor` in place.
func actual_size(anchor: Vector2 = Vector2(-1.0, -1.0)) -> void:
	set_zoom(actual_scale(), anchor)


## Whether the zoom follows the view's size (fitted).
func is_fit() -> bool:
	return _zoom == 0.0


## The scale the images show at (1.0 is 100%).
func scale_shown() -> float:
	return _zoom if _zoom > 0.0 else fit_scale()


## The scale that fits the images: what fits each side in its half (split),
## both together (overlays) or the only side, rounded down to a whole level
## from 100% up.
func fit_scale() -> float:
	var best: float = INF
	if mode == "split":
		for side: int in 2:
			if _sizes[side] != Vector2.ZERO:
				var area: Vector2 = _area(side).size
				best = minf(best, minf(area.x / _sizes[side].x, area.y / _sizes[side].y))
	else:
		var union: Vector2 = _union_size()
		if union != Vector2.ZERO:
			var area: Vector2 = _area(OLD).size
			best = minf(best, minf(area.x / union.x, area.y / union.y))
	if best == INF:
		return actual_scale()
	var screen: float = ZoomLevels.screen_scale(self)
	if best >= ZoomLevels.unit(screen) - ZoomLevels.EPSILON:
		best = ZoomLevels.round_down(best, screen)
	return clampf(best, MIN_ZOOM, MAX_ZOOM)


## 100%: the whole level nearest it with the interface scaled.
func actual_scale() -> float:
	return ZoomLevels.nearest(1.0, ZoomLevels.screen_scale(self))


## Zooms to `value` keeping the point under `anchor` in place (the view's
## centre by default). Never smaller than fitted or 100%, whichever is
## smaller; reaching the fit, it fits (and follows the view's size) again.
func set_zoom(value: float, anchor: Vector2 = Vector2(-1.0, -1.0)) -> void:
	if anchor.x < 0.0:
		anchor = size / 2.0
	var fitted: float = fit_scale()
	value = clampf(value, minf(fitted, actual_scale()), MAX_ZOOM)
	var old_scale: float = scale_shown()
	var to_fit: bool = absf(value - fitted) < ZoomLevels.EPSILON
	if is_equal_approx(value, old_scale) and to_fit == is_fit():
		return
	var side: int = NEW if mode == "split" and anchor.x >= _area(NEW).position.x else OLD
	var origin: Vector2 = _origin(side)
	_zoom = 0.0 if to_fit else value
	var moved: Vector2 = _origin(side)
	var wanted: Vector2 = anchor - (anchor - origin) * (value / old_scale)
	_pan = _clamped(_clamped(_pan) + wanted - moved)
	_changed()


## One whole level in, at `anchor`.
func zoom_in(anchor: Vector2 = Vector2(-1.0, -1.0)) -> void:
	set_zoom(ZoomLevels.step(scale_shown(), ZOOM_STEP, ZoomLevels.screen_scale(self)), anchor)


## One whole level out, at `anchor`.
func zoom_out(anchor: Vector2 = Vector2(-1.0, -1.0)) -> void:
	set_zoom(ZoomLevels.step(scale_shown(), 1.0 / ZOOM_STEP, ZoomLevels.screen_scale(self)), anchor)


## The side shown at `at` (OLD or NEW), or -1: in swipe the divider
## decides, in onion and difference the new side (else the old).
func side_at(at: Vector2) -> int:
	var shown: Array[int] = []
	for side: int in 2:
		if _textures[side] != null and side_rect(side).has_point(at):
			shown.append(side)
	if shown.is_empty():
		return -1
	if shown.size() == 1 or mode == "split":
		return shown[0]
	if mode == "swipe":
		return OLD if at.x < divider_x() else NEW
	return NEW


## Whether the images are larger than the view, so there is room to pan.
func can_pan() -> bool:
	return _pan_room() != Vector2.ZERO


func pan() -> Vector2:
	return _clamped(_pan)


## Moves the images by `delta`, as far as their edges allow.
func pan_by(delta: Vector2) -> void:
	var before: Vector2 = _clamped(_pan)
	_pan = _clamped(before + delta)
	if _pan != before:
		_changed()


## The zoom bar (for tests).
func zoom_bar() -> Control:
	return _bar


## A zoom bar button: `fit`, `zoom_out`, `actual` (shows the zoom) or
## `zoom_in` (for tests).
func zoom_bar_button(id: StringName) -> Button:
	return _bar_buttons.get(id)


## Opacity of the new image in onion mode, 0–1.
func onion_opacity() -> float:
	return _onion


func set_onion_opacity(value: float) -> void:
	_onion = clampf(value, 0.0, 1.0)
	_slider.set_value_no_signal(_onion)
	queue_redraw()


## Where the swipe divider is across the images, 0–1.
func swipe_position() -> float:
	return _swipe


func set_swipe_position(value: float) -> void:
	_swipe = clampf(value, 0.0, 1.0)
	queue_redraw()


## The onion skin's slider (for tests).
func onion_slider() -> HSlider:
	return _slider


## Where `side` is drawn, in this control's coordinates (empty without it).
func side_rect(side: int) -> Rect2:
	if _sizes[side] == Vector2.ZERO:
		return Rect2()
	var s: float = scale_shown()
	return Rect2(_origin(side), _sizes[side] * s)


## The swipe divider's x, in this control's coordinates.
func divider_x() -> float:
	var union: Rect2 = _union_rect()
	return union.position.x + union.size.x * _swipe


## Decodes `bytes` of `format` (`png`, `jpeg`, `webp`, `bmp`, `tga`, `svg`)
## into an image, or null. An SVG renders at `svg_scale`. Safe on a worker
## thread.
static func decode(bytes: PackedByteArray, format: String, svg_scale: float = 1.0) -> Image:
	var image: Image = Image.new()
	var error: Error = ERR_FILE_UNRECOGNIZED
	match format:
		"png":
			error = image.load_png_from_buffer(bytes)
		"jpeg":
			error = image.load_jpg_from_buffer(bytes)
		"webp":
			error = image.load_webp_from_buffer(bytes)
		"bmp":
			error = image.load_bmp_from_buffer(bytes)
		"tga":
			error = image.load_tga_from_buffer(bytes)
		"svg":
			error = image.load_svg_from_buffer(bytes, svg_scale)
	if error != OK or image.is_empty():
		return null
	return image


# Layout ---------------------------------------------------------------------

## The space each side has: halves in split mode (above their captions),
## the whole view otherwise (above the onion slider).
func _area(side: int) -> Rect2:
	var margin: float = float(get_theme_constant(&"margin", THEME_TYPE))
	var full: Rect2 = Rect2(Vector2.ZERO, size).grow(-margin)
	if mode == "split":
		var gap: float = float(get_theme_constant(&"gap", THEME_TYPE))
		var caption: float = _caption_height()
		var width: float = maxf(0.0, (full.size.x - gap) / 2.0)
		var x: float = full.position.x + (width + gap if side == NEW else 0.0)
		return Rect2(x, full.position.y, width, maxf(0.0, full.size.y - caption))
	if mode == "onion" and interactive:
		full.size.y = maxf(0.0, full.size.y - _slider.get_combined_minimum_size().y - margin)
	return full


func _caption_height() -> float:
	var font: Font = get_theme_font(&"font", &"Label")
	return font.get_height(get_theme_font_size(&"font_size", &"Label")) + 6.0


func _union_size() -> Vector2:
	return Vector2(maxf(_sizes[OLD].x, _sizes[NEW].x), maxf(_sizes[OLD].y, _sizes[NEW].y))


## Top-left of `side`: centred in its half (split) or, with the other side,
## at the top-left of both images centred together (overlays).
func _origin(side: int) -> Vector2:
	var s: float = scale_shown()
	var area: Rect2 = _area(side)
	var shown: Vector2 = (_sizes[side] if mode == "split" else _union_size()) * s
	return (area.get_center() - shown / 2.0 + _clamped(_pan)).round()


func _union_rect() -> Rect2:
	var s: float = scale_shown()
	var area: Rect2 = _area(OLD)
	var shown: Vector2 = _union_size() * s
	return Rect2((area.get_center() - shown / 2.0 + _clamped(_pan)).round(), shown)


## How far the images may move from centred along each axis: as far as they
## are larger than the view (in split, the larger image in its half).
func _pan_room() -> Vector2:
	return (_union_size() * scale_shown() - _area(OLD).size).max(Vector2.ZERO) / 2.0


func _clamped(offset: Vector2) -> Vector2:
	var room: Vector2 = _pan_room()
	return offset.clamp(-room, room)


# Drawing --------------------------------------------------------------------

func _draw() -> void:
	var shown: float = scale_shown()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if shown > 1.0 \
			else (CanvasItem.TEXTURE_FILTER_LINEAR if is_equal_approx(shown, 1.0) else CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS)
	match mode:
		"split":
			for side: int in 2:
				_draw_area_clipped(side)
				_draw_caption(side)
		"onion":
			_draw_checker(_union_rect())
			_draw_image(OLD, 1.0)
			_draw_image(NEW, _onion)
			_draw_slider_ends()
		"swipe":
			_draw_checker(_union_rect())
			_draw_swipe()
		"difference":
			_draw_checker(_union_rect())
		"single":
			var side: int = NEW if _sizes[NEW] != Vector2.ZERO or _messages[NEW] != "" else OLD
			_draw_checker(side_rect(side))
			_draw_image(side, 1.0)
	_draw_messages()


## A split half: its checkerboard and image, kept inside the half.
func _draw_area_clipped(side: int) -> void:
	var area: Rect2 = _area(side)
	var rect: Rect2 = side_rect(side).intersection(area)
	if rect.has_area():
		_draw_checker(rect)
		_draw_part(side, rect, 1.0)
		_draw_outline(side_rect(side).intersection(area.grow(1.0)))


func _draw_checker(rect: Rect2) -> void:
	if rect.has_area() and _checker != null:
		draw_texture_rect_region(_checker, rect, Rect2(rect.position, rect.size))


func _draw_image(side: int, alpha: float) -> void:
	var rect: Rect2 = side_rect(side)
	if _textures[side] == null or not rect.has_area():
		return
	_draw_part(side, rect, alpha)
	_draw_outline(rect)


## The part of `side` that falls in `part` (a rect inside where it is drawn).
func _draw_part(side: int, part: Rect2, alpha: float) -> void:
	var image: Texture2D = _textures[side]
	if image == null or not part.has_area():
		return
	var rect: Rect2 = side_rect(side)
	var to_texture: Vector2 = image.get_size() / rect.size
	var source: Rect2 = Rect2((part.position - rect.position) * to_texture, part.size * to_texture)
	draw_texture_rect_region(image, part, source, Color(1, 1, 1, alpha))


func _draw_outline(rect: Rect2) -> void:
	if rect.has_area():
		draw_rect(rect, get_theme_color(&"outline_color", THEME_TYPE), false, 1.0)


func _draw_swipe() -> void:
	var x: float = divider_x()
	var view: Rect2 = Rect2(Vector2.ZERO, size)
	for side: int in 2:
		var rect: Rect2 = side_rect(side)
		var keep: Rect2 = Rect2(view.position, Vector2(x - view.position.x, view.size.y)) if side == OLD \
				else Rect2(Vector2(x, view.position.y), Vector2(view.end.x - x, view.size.y))
		_draw_part(side, rect.intersection(keep), 1.0)
		_draw_outline(rect)
	var union: Rect2 = _union_rect()
	var color: Color = get_theme_color(&"divider_color", THEME_TYPE)
	var top: float = maxf(union.position.y, 0.0)
	var bottom: float = minf(union.end.y, size.y)
	draw_line(Vector2(x, top), Vector2(x, bottom), color, 2.0)
	var handle: float = float(get_theme_constant(&"handle_size", THEME_TYPE))
	var middle: float = (top + bottom) / 2.0
	draw_circle(Vector2(x, middle), handle / 2.0, color, true, -1.0, true)
	var arrow: float = handle * 0.22
	var ink: Color = get_theme_color(&"font_color", &"Label").inverted()
	ink.a = 1.0
	for dir: float in [-1.0, 1.0]:
		var tip: Vector2 = Vector2(x + dir * handle * 0.32, middle)
		draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-dir * arrow, -arrow), tip + Vector2(-dir * arrow, arrow)]),
				Color.WHITE if ink.get_luminance() > 0.5 else Color.BLACK)


## Difference mode: one rect over both images, coloured by the shader.
func _draw_difference() -> void:
	if mode != "difference" or _blank == null:
		return
	var union: Rect2 = _union_rect()
	if not union.has_area():
		return
	for side: int in 2:
		var key: String = "old" if side == OLD else "new"
		var has: bool = _textures[side] != null
		_material.set_shader_parameter(StringName("has_" + key), has)
		_material.set_shader_parameter(StringName(key + "_size"), _sizes[side] if has else Vector2.ONE)
		if has:
			_material.set_shader_parameter(StringName(key + "_tex"), _textures[side])
	_material.set_shader_parameter(&"area_size", _union_size())
	_layer.draw_texture_rect(_blank, union, false)


func _draw_caption(side: int) -> void:
	if side >= captions.size() or _sizes[side] == Vector2.ZERO and _messages[side].is_empty():
		return
	var area: Rect2 = _area(side)
	var font: Font = get_theme_font(&"font", &"Label")
	var font_size: int = get_theme_font_size(&"font_size", &"Label")
	var text: String = captions[side]
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	# Right under the image, or under the half when the image fills it.
	var rect: Rect2 = side_rect(side)
	var bottom: float = minf(rect.end.y, area.end.y) if rect.has_area() else area.get_center().y + font.get_height(font_size)
	var y: float = bottom + font.get_ascent(font_size) + 4.0
	draw_string(font, Vector2(area.get_center().x - width / 2.0, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			font_size, get_theme_color(&"caption_color", THEME_TYPE))


## A side's message where its image would be: in its half (split), else
## stacked at the top of the view.
func _draw_messages() -> void:
	var font: Font = get_theme_font(&"font", &"Label")
	var font_size: int = get_theme_font_size(&"font_size", &"Label")
	var color: Color = get_theme_color(&"message_color", THEME_TYPE)
	var line: int = 0
	for side: int in 2:
		if _messages[side].is_empty() or _textures[side] != null:
			continue
		var area: Rect2 = _area(side) if mode == "split" or mode == "single" else _area(OLD)
		var text: String = _messages[side]
		if mode != "split" and mode != "single":
			text = "%s: %s" % [captions[side] if side < captions.size() else "", text]
		var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var y: float = area.get_center().y if mode == "split" or mode == "single" \
				else area.position.y + font.get_ascent(font_size) + line * font.get_height(font_size)
		draw_string(font, Vector2(area.get_center().x - width / 2.0, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1,
				font_size, color)
		line += 1


# Input ----------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if not interactive:
		return
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null:
		_on_button(button)
		return
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null and _drag != Drag.NONE:
		if _drag == Drag.DIVIDER:
			var union: Rect2 = _union_rect()
			if union.size.x > 0.0:
				set_swipe_position((motion.position.x - union.position.x) / union.size.x)
		else:
			pan_by(motion.relative)
		accept_event()
		return
	if motion != null:
		_update_cursor(motion.position)
	var gesture: InputEventPanGesture = event as InputEventPanGesture
	if gesture != null:
		pan_by(-gesture.delta * 10.0)
		accept_event()
		return
	var magnify: InputEventMagnifyGesture = event as InputEventMagnifyGesture
	if magnify != null:
		set_zoom(scale_shown() * magnify.factor, magnify.position)
		accept_event()
		return
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed and (key.keycode == KEY_LEFT or key.keycode == KEY_RIGHT) \
			and not key.ctrl_pressed and not key.alt_pressed and mode in ["onion", "swipe"]:
		var step: float = (0.01 if key.shift_pressed else 0.1) * (-1.0 if key.keycode == KEY_LEFT else 1.0)
		if mode == "onion":
			set_onion_opacity(_onion + step)
		else:
			set_swipe_position(_swipe + step)
		accept_event()


func _on_button(button: InputEventMouseButton) -> void:
	match button.button_index:
		MOUSE_BUTTON_LEFT:
			if not button.pressed:
				_drag = Drag.NONE
			elif button.double_click and not (mode == "swipe" and _near_divider(button.position)):
				_drag = Drag.NONE
				_toggle_fit(button.position)
			else:
				grab_focus()
				if mode == "swipe" and _near_divider(button.position):
					_drag = Drag.DIVIDER
					var union: Rect2 = _union_rect()
					if union.size.x > 0.0:
						set_swipe_position((button.position.x - union.position.x) / union.size.x)
				else:
					_drag = Drag.PAN if can_pan() else Drag.NONE
			_update_cursor(button.position)
			accept_event()
		MOUSE_BUTTON_MIDDLE:
			_drag = Drag.PAN if button.pressed and can_pan() else Drag.NONE
			_update_cursor(button.position)
			accept_event()
		MOUSE_BUTTON_RIGHT:
			if button.pressed:
				var side: int = side_at(button.position)
				if side >= 0:
					side_menu_requested.emit(side, button.position)
			accept_event()
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
			if not button.pressed:
				return
			var notches: float = button.factor if button.factor > 0.0 else 1.0
			var vertical: bool = button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]
			var towards: float = 1.0 if button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT] else -1.0
			if vertical and not button.shift_pressed:
				_wheel_zoom(towards * notches, button.position)
			else:
				pan_by(Vector2(towards * WHEEL_PAN * notches, 0.0))
			accept_event()


## Zooms a whole level once the wheel has turned a whole notch (touchpads
## send parts of one), in when `notches` is positive.
func _wheel_zoom(notches: float, anchor: Vector2) -> void:
	if signf(notches) != signf(_wheel_notches):
		_wheel_notches = 0.0
	_wheel_notches += notches
	if absf(_wheel_notches) < 1.0 - ZoomLevels.EPSILON:
		return
	_wheel_notches = 0.0
	if notches > 0.0:
		zoom_in(anchor)
	else:
		zoom_out(anchor)


## A double-click: fitted, 100% at `at` (or a level in when the fit already
## is 100%); zoomed, fits again.
func _toggle_fit(at: Vector2) -> void:
	if not is_fit():
		fit()
	elif absf(fit_scale() - actual_scale()) < ZoomLevels.EPSILON:
		zoom_in(at)
	else:
		set_zoom(actual_scale(), at)


func _update_cursor(at: Vector2) -> void:
	var shape: CursorShape = Control.CURSOR_ARROW
	if _drag == Drag.DIVIDER or (_drag == Drag.NONE and mode == "swipe" and _near_divider(at)):
		shape = Control.CURSOR_HSIZE
	elif _drag == Drag.PAN or can_pan():
		shape = Control.CURSOR_DRAG
	mouse_default_cursor_shape = shape


func _near_divider(at: Vector2) -> bool:
	var handle: float = float(get_theme_constant(&"handle_size", THEME_TYPE))
	return absf(at.x - divider_x()) <= handle and _union_rect().grow(handle).has_point(at)


func _changed() -> void:
	queue_redraw()
	_layer.queue_redraw()
	_update_bar()
	view_changed.emit()


func _on_resized() -> void:
	_place_slider()
	_place_bar()
	_update_bar()


# Zoom bar --------------------------------------------------------------------

func _build_bar() -> void:
	_bar.theme_type_variation = &"ImageZoomBar"
	_bar_row.theme_type_variation = &"IconSwitch"
	_bar.add_child(_bar_row)
	for i: int in BAR_BUTTONS.size():
		var id: StringName = BAR_BUTTONS[i]
		var button: Button = Button.new()
		button.name = "Zoom_" + String(id)
		button.focus_mode = Control.FOCUS_NONE
		button.theme_type_variation = &"IconSegmentFirst" if i == 0 \
				else (&"IconSegmentLast" if i == BAR_BUTTONS.size() - 1 else &"IconSegmentMiddle")
		_bar_buttons[id] = button
		_bar_row.add_child(button)
	_bar_buttons[&"actual"].custom_minimum_size.x = 52.0
	_bar_buttons[&"fit"].pressed.connect(fit)
	_bar_buttons[&"zoom_out"].pressed.connect(func() -> void: zoom_out())
	_bar_buttons[&"actual"].pressed.connect(func() -> void: actual_size())
	_bar_buttons[&"zoom_in"].pressed.connect(func() -> void: zoom_in())
	_bar.resized.connect(_place_bar)
	add_child(_bar)


## The zoom shown, which buttons can act and their tooltips (with the
## actions' shortcuts); the bar shows while an image does.
func _update_bar() -> void:
	if not is_node_ready():
		return
	_bar.visible = interactive and (_textures[OLD] != null or _textures[NEW] != null)
	if not _bar.visible:
		return
	var shown: float = scale_shown()
	var floor_scale: float = minf(fit_scale(), actual_scale())
	_bar_buttons[&"actual"].text = "%d%%" % maxi(1, roundi(shown * 100.0))
	_bar_buttons[&"fit"].disabled = is_fit()
	_bar_buttons[&"zoom_out"].disabled = shown <= floor_scale + ZoomLevels.EPSILON
	_bar_buttons[&"zoom_in"].disabled = shown >= MAX_ZOOM - ZoomLevels.EPSILON
	for entry: Array in [[&"fit", "Fit to the view", &"image.zoom_fit"], [&"zoom_out", "Zoom out", &"image.zoom_out"],
			[&"actual", "Actual size", &"image.zoom_actual"], [&"zoom_in", "Zoom in", &"image.zoom_in"]]:
		var shortcut: String = Actions.shortcut_label(entry[2])
		_bar_buttons[entry[0]].tooltip_text = tr(String(entry[1])) if shortcut.is_empty() \
				else "%s (%s)" % [tr(String(entry[1])), shortcut]


func _place_bar() -> void:
	var margin: float = float(get_theme_constant(&"margin", THEME_TYPE))
	var bar_size: Vector2 = _bar.get_combined_minimum_size()
	_bar.size = bar_size
	_bar.position = Vector2(size.x - bar_size.x - margin, margin).round()


func _update_slider() -> void:
	_slider.visible = mode == "onion" and interactive
	_place_slider()


## "Old" and "New" at the slider's ends.
func _draw_slider_ends() -> void:
	if not _slider.visible or captions.size() < 2:
		return
	var font: Font = get_theme_font(&"font", &"Label")
	var font_size: int = get_theme_font_size(&"font_size", &"Label")
	var color: Color = get_theme_color(&"caption_color", THEME_TYPE)
	var gap: float = float(get_theme_constant(&"gap", THEME_TYPE))
	var y: float = _slider.position.y + (_slider.size.y + font.get_ascent(font_size) - font.get_descent(font_size)) / 2.0
	var old_width: float = font.get_string_size(captions[OLD], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, Vector2(_slider.position.x - gap - old_width, y), captions[OLD], HORIZONTAL_ALIGNMENT_LEFT, -1,
			font_size, color)
	draw_string(font, Vector2(_slider.position.x + _slider.size.x + gap, y), captions[NEW], HORIZONTAL_ALIGNMENT_LEFT, -1,
			font_size, color)


func _place_slider() -> void:
	var margin: float = float(get_theme_constant(&"margin", THEME_TYPE))
	var slider_size: Vector2 = _slider.get_combined_minimum_size()
	_slider.size = slider_size
	_slider.position = Vector2(((size.x - slider_size.x) / 2.0), size.y - slider_size.y - margin).round()
	queue_redraw()
