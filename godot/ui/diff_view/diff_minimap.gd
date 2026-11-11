class_name DiffMinimap
extends Control
## The scroll column of a `DiffView` (PLAN M7.6): a VS Code-style minimap of
## the rows shown, rendered by core in tiles, beside a strip with the marks
## of the whole diff.
##
## The preview draws a row in `row_height` px. While the rows fit it starts
## at the top; past that it scrolls along, its offset the diff's scroll
## ratio times its overflow. A box marks the visible rows: drag it to
## scroll, click elsewhere to centre that row, turn the wheel to scroll the
## diff. The strip shows every change in the whole diff (conflict blocks,
## removed and added lines, dimmed when left out of the commit, blocks
## resolved this session), the selection and the visible rows; clicking or
## dragging it scrolls there. With strip sources it spans the whole file:
## the lines collapsed gaps hide take their room, and a click there opens
## the gap, then scrolls to the line.
## Without `enabled`, or in a diff narrower than `narrow_width`, only the
## strip shows, as wide as a scroll bar, with a thumb.
## Clicks ease the diff there (`DiffView.ease_to_offset`); drags and the wheel
## scroll it directly. After a draw, the tiles just above and below the
## visible ones are rendered on the next frames, one a frame.

const THEME_TYPE: StringName = &"DiffMinimap"
## Rows of a tile core renders at once.
const TILE_ROWS: int = 256
## Tiles kept; the least recently drawn go first.
const MAX_TILES: int = 12
## Theme colours of the tile palette, in core's `minimap::PALETTE_LEN` order.
const PALETTE_COLORS: Array[StringName] = [
	&"context_bg", &"header_bg", &"added_bg", &"removed_bg", &"ours_bg", &"theirs_bg", &"base_bg",
	&"resolved_bg", &"text_color", &"syntax_keyword", &"syntax_type", &"syntax_string",
	&"syntax_number", &"syntax_comment", &"divider_color", &"veil_color", &"added_word",
	&"removed_word",
]
## Overview flags (`RepoSession.diff_overview`).
const ADDED: int = 1
const REMOVED: int = 2
const CONFLICT: int = 4
const LEFT_OUT: int = 8
const RESOLVED: int = 16

enum Drag { NONE, BOX, STRIP }

## `(split, first_row, rows, columns, row_px, char_px, palette) -> PackedByteArray`:
## RGBA8 rows of the preview (`RepoSession.diff_minimap_tile`).
var tile_source: Callable = Callable()
## `(split, buckets) -> PackedByteArray`: the overview flags.
var overview_source: Callable = Callable()
## `(split, row) -> float`: where a (fractional) row starts on the strip,
## 0..1 (`RepoSession.diff_strip_position`); rows shown when unset.
var position_source: Callable = Callable()
## `(split, fraction) -> Dictionary`: the `{row, gap}` at a fraction of the
## strip (`RepoSession.diff_strip_target`).
var target_source: Callable = Callable()
## Show the preview; off leaves only the strip.
var enabled: bool = true
## The diff this scrolls.
var view: DiffView = null

var _tiles: Dictionary[int, ImageTexture] = {}
## Tile indices, least recently drawn first.
var _tile_order: Array[int] = []
## The scale and preview width the tiles were rendered for.
var _tile_scale: float = 0.0
var _tile_width: float = 0.0
## Colours that replace the theme's, by name: a view whose marks mean
## something else (the blame's focused commit) draws them in its own.
var color_overrides: Dictionary[StringName, Color] = {}:
	set(value):
		color_overrides = value
		_update_theme()
		reset()

var _palette: PackedColorArray = PackedColorArray()
var _overview: PackedByteArray = PackedByteArray()
var _overview_buckets: int = -1
var _drag: Drag = Drag.NONE
var _drag_y: float = 0.0
var _drag_scroll: float = 0.0
var _box_hovered: bool = false
## Tiles to render ahead, one a frame.
var _prefetch: Array[int] = []
## Where on the strip a click opened a gap, to scroll there once its lines
## show; -1 for none.
var _pending_fraction: float = -1.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_exited.connect(func() -> void: _set_box_hovered(false))
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _ready() -> void:
	set_process(false)
	_update_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_update_theme()
		reset()
	elif what == NOTIFICATION_RESIZED:
		_overview_buckets = -1


func has_sources() -> bool:
	return tile_source.is_valid() and overview_source.is_valid()


## Whether the preview shows (else only the strip).
func is_full() -> bool:
	return enabled and view != null \
			and view.size.x >= float(get_theme_constant(&"narrow_width", THEME_TYPE))


## Width the column takes from the diff: 0 without sources or rows.
func column_width() -> float:
	if not has_sources() or view == null or view.row_count() == 0:
		return 0.0
	return float(get_theme_constant(&"width" if is_full() else &"strip_only_width", THEME_TYPE))


## Drops the rendered tiles and the overview, so they are fetched again.
func reset() -> void:
	_tiles.clear()
	_tile_order.clear()
	_prefetch.clear()
	_overview_buckets = -1
	queue_redraw()


func tile_count() -> int:
	return _tiles.size()


func row_height() -> float:
	return float(maxi(1, get_theme_constant(&"row_height", THEME_TYPE)))


func preview_width() -> float:
	return maxf(0.0, size.x - float(get_theme_constant(&"strip_width", THEME_TYPE))) if is_full() else 0.0


func strip_rect() -> Rect2:
	if not is_full():
		return Rect2(Vector2.ZERO, size)
	var width: float = float(get_theme_constant(&"strip_width", THEME_TYPE))
	return Rect2(size.x - width, 0.0, width, size.y)


## How far the preview is scrolled, in pixels.
func map_offset() -> float:
	var content: float = view.row_count() * row_height()
	if content <= size.y or view.max_scroll_offset() <= 0.0:
		return 0.0
	return view.scroll_offset() / view.max_scroll_offset() * (content - size.y)


## The visible rows' box in the preview.
func box_rect() -> Rect2:
	var visible_rows: float = view.size.y / view.row_height()
	var top: float = view.scroll_offset() / view.row_height() * row_height() - map_offset()
	return Rect2(0.0, top, preview_width(), minf(visible_rows, float(view.row_count())) * row_height())


## The row under `y` in the preview.
func row_at(y: float) -> int:
	return clampi(int((y + map_offset()) / row_height()), 0, maxi(0, view.row_count() - 1))


## The row under `y` in the strip (which covers every row).
func strip_row_at(y: float) -> float:
	return float(strip_target(y).get("row", 0.0))


## `{row, gap}` under `y` in the strip: the (fractional) row, and the
## collapsed gap there (-1 for none).
func strip_target(y: float) -> Dictionary:
	var fraction: float = clampf(y / maxf(1.0, size.y), 0.0, 1.0)
	if target_source.is_valid():
		return target_source.call(view.side_by_side, fraction)
	return {"row": fraction * view.row_count(), "gap": -1}


## Where (fractional) row `row` starts on the strip, 0..1.
func strip_position(row: float) -> float:
	if position_source.is_valid():
		return float(position_source.call(view.side_by_side, row))
	return row / maxf(1.0, float(view.row_count()))


## The rows changed: after a click opened a gap, scrolls to where it was.
func rows_shown() -> void:
	if _pending_fraction < 0.0:
		return
	var fraction: float = _pending_fraction
	_pending_fraction = -1.0
	center_on(strip_row_at(fraction * size.y), true)


func _scale() -> float:
	var window: Window = get_window()
	return window.content_scale_factor if window != null else 1.0


func _update_theme() -> void:
	_palette = PackedColorArray()
	for color_name: StringName in PALETTE_COLORS:
		_palette.append(_color(color_name))


## Theme colour `color_name`, or the view's own for it (`color_overrides`).
func _color(color_name: StringName) -> Color:
	return color_overrides[color_name] if color_overrides.has(color_name) else get_theme_color(color_name, THEME_TYPE)


# --- Drawing --------------------------------------------------------------------


func _draw() -> void:
	if view == null or view.row_count() == 0 or size.x <= 0.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), get_theme_color(&"background", THEME_TYPE))
	if is_full():
		_draw_tiles()
		var box: Rect2 = box_rect()
		var drawn: bool = _box_hovered or _drag == Drag.BOX
		draw_rect(box, get_theme_color(&"slider_hover_color" if drawn else &"slider_color", THEME_TYPE))
	_draw_strip()
	draw_line(Vector2(0.5, 0.0), Vector2(0.5, size.y), get_theme_color(&"border_color", THEME_TYPE))


func _draw_tiles() -> void:
	var ui_scale: float = _scale()
	var width: float = preview_width()
	if ui_scale != _tile_scale or width != _tile_width:
		_tiles.clear()
		_tile_order.clear()
		_tile_scale = ui_scale
		_tile_width = width
	var height: float = row_height()
	var offset: float = map_offset()
	var first: int = int(offset / height)
	var last: int = mini(view.row_count(), ceili((offset + size.y) / height))
	if last <= first:
		return
	var first_tile: int = floori(first / float(TILE_ROWS))
	var last_tile: int = floori((last - 1) / float(TILE_ROWS))
	for tile: int in range(first_tile, last_tile + 1):
		var texture: ImageTexture = _tile(tile)
		if texture != null:
			var top: float = tile * TILE_ROWS * height - offset
			draw_texture_rect(texture, Rect2(0.0, top, width, TILE_ROWS * height), false)
	_prefetch.clear()
	for tile: int in [last_tile + 1, first_tile - 1]:
		if tile >= 0 and tile * TILE_ROWS < view.row_count() and not _tiles.has(tile):
			_prefetch.append(tile)
	set_process(not _prefetch.is_empty())


func _process(_delta: float) -> void:
	if _prefetch.is_empty() or view == null or not is_full() or not has_sources():
		_prefetch.clear()
		set_process(false)
		return
	var tile: int = _prefetch.pop_front()
	if not _tiles.has(tile):
		_tile(tile)


## Whether tile `tile` is rendered.
func has_tile(tile: int) -> bool:
	return _tiles.has(tile)


## Tile `tile`, rendered by core on first use.
func _tile(tile: int) -> ImageTexture:
	if _tiles.has(tile):
		_tile_order.erase(tile)
		_tile_order.append(tile)
		return _tiles[tile]
	var columns: int = maxi(1, roundi(_tile_width * _tile_scale))
	var row_px: int = maxi(1, roundi(row_height() * _tile_scale))
	var char_px: int = maxi(1, roundi(get_theme_constant(&"char_width", THEME_TYPE) * _tile_scale))
	var bytes: PackedByteArray = tile_source.call(view.side_by_side, tile * TILE_ROWS, TILE_ROWS,
			columns, row_px, char_px, _palette)
	if bytes.size() != columns * TILE_ROWS * row_px * 4:
		return null
	var image: Image = Image.create_from_data(columns, TILE_ROWS * row_px, false, Image.FORMAT_RGBA8, bytes)
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	_tiles[tile] = texture
	_tile_order.append(tile)
	while _tile_order.size() > MAX_TILES:
		_tiles.erase(_tile_order.pop_front())
	return texture


func _draw_strip() -> void:
	var strip: Rect2 = strip_rect()
	draw_rect(strip, get_theme_color(&"strip_background", THEME_TYPE))
	var flags: PackedByteArray = overview()
	var step: float = size.y / maxf(1.0, float(flags.size()))
	for run: Vector3i in MarkStrip.runs(flags):
		_draw_marks(strip, run.x * step, run.y * step, run.z)
	var rows: float = maxf(1.0, float(view.row_count()))
	var selection: Vector2i = view.selection_rows()
	if selection.x >= 0:
		var top: float = strip_position(selection.x) * size.y
		var bottom: float = maxf(top + 2.0, strip_position(selection.y + 1) * size.y)
		draw_rect(Rect2(strip.position.x, top, strip.size.x, bottom - top),
				get_theme_color(&"selection_color", THEME_TYPE))
	var first_row: float = view.scroll_offset() / view.row_height()
	var last_row: float = minf(rows, first_row + view.size.y / view.row_height())
	var shown_top: float = strip_position(first_row) * size.y
	var thumb: float = float(get_theme_constant(&"min_thumb" if not is_full() else &"min_shade", THEME_TYPE))
	var shown: float = maxf(thumb, strip_position(last_row) * size.y - shown_top)
	shown_top = clampf(shown_top, 0.0, maxf(0.0, size.y - shown))
	var hovered: bool = not is_full() and (_box_hovered or _drag == Drag.STRIP)
	draw_rect(Rect2(strip.position.x, shown_top, strip.size.x, shown),
			get_theme_color(&"thumb_hover_color" if hovered else &"thumb_color", THEME_TYPE))


func _draw_marks(strip: Rect2, top: float, height: float, flags: int) -> void:
	var alpha: float = get_theme_constant(&"left_out_percent", THEME_TYPE) / 100.0 if flags & LEFT_OUT else 1.0
	var added: Color = get_theme_color(&"added_mark", THEME_TYPE)
	var removed: Color = get_theme_color(&"removed_mark", THEME_TYPE)
	var height_px: float = maxf(1.0, height)
	if flags & CONFLICT:
		draw_rect(Rect2(strip.position.x, top, strip.size.x, height_px),
				Color(get_theme_color(&"conflict_mark", THEME_TYPE), alpha))
	elif flags & RESOLVED:
		draw_rect(Rect2(strip.position.x, top, strip.size.x, height_px),
				_color(&"resolved_mark"))
	elif flags & ADDED and flags & REMOVED:
		var half: float = strip.size.x / 2.0
		draw_rect(Rect2(strip.position.x, top, half, height_px), Color(removed, alpha))
		draw_rect(Rect2(strip.position.x + half, top, strip.size.x - half, height_px), Color(added, alpha))
	elif flags & (ADDED | REMOVED):
		draw_rect(Rect2(strip.position.x, top, strip.size.x, height_px),
				Color(added if flags & ADDED else removed, alpha))


## The overview flags, one bucket per pixel of height, fetched once per
## size and diff.
func overview() -> PackedByteArray:
	var buckets: int = maxi(1, int(size.y))
	if buckets != _overview_buckets:
		_overview = overview_source.call(view.side_by_side, buckets) if has_sources() else PackedByteArray()
		_overview_buckets = buckets
	return _overview


# --- Input ----------------------------------------------------------------------


func _gui_input(event: InputEvent) -> void:
	if view == null or view.row_count() == 0:
		return
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.pressed:
		view.finish_ease()
	if button != null:
		if button.pressed and button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var direction: float = -1.0 if button.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
			var factor: float = button.factor if button.factor > 0.0 else 1.0
			view.set_scroll_offset(view.scroll_offset()
					+ direction * factor * VirtualList.WHEEL_ROWS * view.row_height())
			accept_event()
		elif button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_press(button.position)
			else:
				_drag = Drag.NONE
				_update_cursor(button.position)
				queue_redraw()
			accept_event()
		return
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion == null:
		return
	if _drag != Drag.NONE and (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_drag_to(motion.position.y)
		accept_event()
	else:
		_set_box_hovered(box_rect().has_point(motion.position) if is_full()
				else strip_rect().has_point(motion.position))
	_update_cursor(motion.position)


## The drag cursor over the box and while dragging it, a hand elsewhere.
func _update_cursor(at: Vector2) -> void:
	var on_box: bool = _drag == Drag.BOX or (_drag == Drag.NONE and is_full()
			and at.x < preview_width() and box_rect().has_point(at))
	mouse_default_cursor_shape = Control.CURSOR_DRAG if on_box else Control.CURSOR_POINTING_HAND


func _press(at: Vector2) -> void:
	if is_full() and at.x < preview_width():
		if not box_rect().has_point(at):
			center_on(row_at(at.y), true)
		_drag = Drag.BOX
		_drag_y = at.y
		_drag_scroll = view.target_scroll_offset()
	else:
		_drag = Drag.STRIP
		var target: Dictionary = strip_target(at.y)
		var gap: int = int(target.get("gap", -1))
		if gap >= 0:
			_pending_fraction = clampf(at.y / maxf(1.0, size.y), 0.0, 1.0)
			view.expand_gap(gap)
		center_on(float(target.get("row", 0.0)), true)
	_update_cursor(at)
	queue_redraw()


func _drag_to(y: float) -> void:
	if _drag == Drag.STRIP:
		center_on(strip_row_at(y))
		return
	var travel: float = minf(size.y, view.row_count() * row_height()) - box_rect().size.y
	if travel > 0.0:
		view.set_scroll_offset(_drag_scroll + (y - _drag_y) * view.max_scroll_offset() / travel)


## Scrolls the diff so that `row` is in the middle, eased with `eased`.
func center_on(row: float, eased: bool = false) -> void:
	var offset: float = row * view.row_height() - view.size.y / 2.0
	if eased:
		view.ease_to_offset(offset)
	else:
		view.set_scroll_offset(offset)


func _set_box_hovered(hovered: bool) -> void:
	if hovered != _box_hovered:
		_box_hovered = hovered
		queue_redraw()
