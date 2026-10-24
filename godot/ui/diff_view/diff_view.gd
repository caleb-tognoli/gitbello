class_name DiffView
extends VirtualList
## Unified diff lines with old and new line numbers, drawn in a monospace font.
## Lines come from `source.call(start, count) -> Array[Dictionary]` with
## `{kind, old, new, text, no_newline}` (kind 0 = hunk header, 1 = context,
## 2 = added, 3 = removed), fetched for a window around the visible range.
## Rows can be selected and copied (Ctrl+C).

const DIFF_THEME_TYPE: StringName = &"DiffView"
const FETCH_MARGIN: int = 128
const KIND_HUNK: int = 0
const KIND_ADDED: int = 2
const KIND_REMOVED: int = 3
const NO_NEWLINE_MARK: String = "   \\ no newline at end of file"

## Returns the lines of a range; see the class docs.
var source: Callable = Callable()

var _line_count: int = 0
var _number_digits: int = 1
var _cache: Dictionary[int, Dictionary] = {}
var _h_scroll: HScrollBar = HScrollBar.new()
var _widest: float = 0.0

var _font: Font = null
var _font_size: int = 0
var _char_width: float = 0.0
var _padding: float = 0.0
var _colors: Dictionary[StringName, Color] = {}


func _ready() -> void:
	super()
	add_child(_h_scroll, false, Node.INTERNAL_MODE_FRONT)
	_h_scroll.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_h_scroll.value_changed.connect(func(_v: float) -> void: queue_redraw())
	resized.connect(_update_h_range)
	_update_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_update_theme()
		queue_redraw()


## Shows `line_count` lines; `max_line_number` sizes the number gutter.
## Keeps the scroll position when `keep_scroll` (a reload of the same file).
func show_lines(line_count: int, max_line_number: int, keep_scroll: bool) -> void:
	_line_count = line_count
	_number_digits = maxi(1, str(max_line_number).length())
	_cache.clear()
	if not keep_scroll:
		_widest = 0.0
		_h_scroll.value = 0.0
		clear_selection()
		cursor = -1
		set_scroll_offset(0.0)
	refresh()
	_update_h_range()


func row_height() -> float:
	return float(maxi(1, get_theme_constant(&"row_height", DIFF_THEME_TYPE)))


## Text of a line as shown (for tests and copying).
func line_text(index: int) -> String:
	return String(_line(index).get("text", ""))


func line(index: int) -> Dictionary:
	return _line(index)


## The selected lines, with `+`/`-`/space prefixes, joined by newlines.
func selected_text() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for index: int in selected_rows():
		var data: Dictionary = _line(index)
		match int(data.get("kind", -1)):
			KIND_HUNK:
				parts.append(String(data["text"]))
			KIND_ADDED:
				parts.append("+" + String(data["text"]))
			KIND_REMOVED:
				parts.append("-" + String(data["text"]))
			_:
				parts.append(" " + String(data.get("text", "")))
	return "\n".join(parts)


func _get_row_count() -> int:
	return _line_count


func _prepare_rows(first: int, count: int) -> void:
	for index: int in range(first, first + count):
		if not _cache.has(index):
			var start: int = maxi(0, first - FETCH_MARGIN)
			_cache.clear()
			_fetch(start, first + count + FETCH_MARGIN - start)
			return


func _fetch(start: int, count: int) -> void:
	if not source.is_valid():
		return
	var lines: Array = source.call(start, count)
	var grew: bool = false
	for i: int in lines.size():
		var data: Dictionary = lines[i]
		_cache[start + i] = data
		var width: float = String(data["text"]).length() * _char_width
		if width > _widest:
			_widest = width
			grew = true
	if grew:
		_update_h_range.call_deferred()


func _line(index: int) -> Dictionary:
	if index < 0 or index >= _line_count:
		return {}
	if not _cache.has(index):
		_fetch(index, 1)
	return _cache.get(index, {})


func _gutter_width() -> float:
	# Two number columns, the +/- mark and a space.
	return (_number_digits * 2 + 4) * _char_width + _padding * 2.0


func _draw_row(index: int, rect: Rect2, selected_row: bool) -> void:
	var data: Dictionary = _cache.get(index, {})
	if data.is_empty():
		return
	var kind: int = int(data["kind"])
	var gutter: float = _gutter_width()
	if not selected_row:
		var bg: Color = _row_bg(kind)
		if bg.a > 0.0:
			draw_rect(rect, bg)
		draw_rect(Rect2(rect.position, Vector2(gutter, rect.size.y)), _colors[&"gutter_bg"])
	var baseline: float = rect.position.y + (rect.size.y + _font.get_ascent(_font_size) - _font.get_descent(_font_size)) / 2.0
	var x: float = rect.position.x + _padding
	if kind != KIND_HUNK:
		var number_color: Color = _colors[&"line_number_color"]
		var old_no: int = int(data["old"])
		var new_no: int = int(data["new"])
		var column: float = _number_digits * _char_width
		# Right-aligned by hand: a width limit can drop the last glyph.
		if old_no > 0:
			var old_text: String = str(old_no)
			draw_string(_font, Vector2(x + column - old_text.length() * _char_width, baseline), old_text,
					HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, number_color)
		if new_no > 0:
			var new_text: String = str(new_no)
			draw_string(_font, Vector2(x + column * 2.0 + _char_width - new_text.length() * _char_width, baseline), new_text,
					HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, number_color)
		var mark: String = "+" if kind == KIND_ADDED else ("-" if kind == KIND_REMOVED else "")
		if not mark.is_empty():
			var mark_color: Color = _colors[&"added_mark"] if kind == KIND_ADDED else _colors[&"removed_mark"]
			draw_string(_font, Vector2(x + (column + _char_width) * 2.0, baseline), mark, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, mark_color)
	var text_x: float = rect.position.x + gutter - _h_scroll.value
	var clip: float = rect.end.x - gutter
	var text: String = String(data["text"])
	if bool(data.get("no_newline", false)):
		text += NO_NEWLINE_MARK
	var color: Color = _colors[&"hunk_color"] if kind == KIND_HUNK else _colors[&"text_color"]
	# Skip characters scrolled off to the left so long lines stay cheap.
	var skip: int = int(_h_scroll.value / _char_width) if _char_width > 0.0 else 0
	if skip > 0:
		text = text.substr(skip)
		text_x += skip * _char_width
	if clip > 0.0 and not text.is_empty():
		draw_string(_font, Vector2(maxf(text_x, rect.position.x + gutter), baseline), text, HORIZONTAL_ALIGNMENT_LEFT,
				clip + _char_width, _font_size, color)


func _row_bg(kind: int) -> Color:
	match kind:
		KIND_HUNK:
			return _colors[&"hunk_bg"]
		KIND_ADDED:
			return _colors[&"added_bg"]
		KIND_REMOVED:
			return _colors[&"removed_bg"]
	return Color(0, 0, 0, 0)


func _gui_input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_C and key.is_command_or_control_pressed():
		DisplayServer.clipboard_set(selected_text())
		accept_event()
		return
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.shift_pressed \
			and mouse.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var direction: float = -1.0 if mouse.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
		_h_scroll.value += direction * _char_width * 8.0
		accept_event()
		return
	if mouse != null and mouse.pressed and mouse.button_index in [MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		var direction: float = -1.0 if mouse.button_index == MOUSE_BUTTON_WHEEL_LEFT else 1.0
		_h_scroll.value += direction * _char_width * 8.0
		accept_event()
		return
	super(event)


func _update_h_range() -> void:
	var visible_width: float = maxf(0.0, content_width() - _gutter_width())
	var total: float = _widest + _char_width * 4.0
	_h_scroll.max_value = total
	_h_scroll.page = visible_width
	_h_scroll.visible = total > visible_width and _line_count > 0
	_h_scroll.offset_right = -(_scroll_bar.size.x if _scroll_bar.visible else 0.0)


func _update_theme() -> void:
	_font = get_theme_font(&"font", DIFF_THEME_TYPE)
	_font_size = get_theme_font_size(&"font_size", DIFF_THEME_TYPE)
	_char_width = _font.get_char_size(ord("M"), _font_size).x
	_padding = float(get_theme_constant(&"padding", DIFF_THEME_TYPE))
	for name: StringName in [&"text_color", &"line_number_color", &"hunk_color", &"hunk_bg",
			&"added_bg", &"removed_bg", &"added_mark", &"removed_mark", &"gutter_bg"]:
		_colors[name] = get_theme_color(name, DIFF_THEME_TYPE)
	_update_h_range()
