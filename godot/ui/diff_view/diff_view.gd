class_name DiffView
extends VirtualList
## A file diff drawn in a monospace font, unified or side by side, with
## syntax colors and the changed words of paired lines highlighted.
##
## Unified rows come from `source.call(start, count)`: lines like
## `{index, kind, old, new, text, no_newline, hl, syntax}` (kind 0 = hunk
## header, 1 = context, 2 = added, 3 = removed; `hl` = changed `[start, end)`;
## `syntax` = `start, end, token` triples). Side-by-side rows come from
## `split_source.call(start, count)` as `{left, right}` lines (or {}).
## Only a window around the visible rows is fetched. Rows can be selected
## and copied (Ctrl+C); `selected_or_cursor()` gives the selected lines.

const DIFF_THEME_TYPE: StringName = &"DiffView"
const FETCH_MARGIN: int = 128
const KIND_HUNK: int = 0
const KIND_CONTEXT: int = 1
const KIND_ADDED: int = 2
const KIND_REMOVED: int = 3
const NO_NEWLINE_MARK: String = "   \\ no newline at end of file"
## Theme colors of `highlight::TokenKind` ids 0..4.
const SYNTAX_COLORS: Array[StringName] = [
	&"syntax_keyword", &"syntax_type", &"syntax_string", &"syntax_number", &"syntax_comment",
]

## Unified lines of a range; see the class docs.
var source: Callable = Callable()
## Side-by-side rows of a range; see the class docs.
var split_source: Callable = Callable()
## Show the old and new sides next to each other.
var side_by_side: bool = false:
	set = set_side_by_side

var _line_count: int = 0
var _split_count: int = 0
var _number_digits: int = 1
var _cache: Dictionary[int, Dictionary] = {}
var _h_scroll: HScrollBar = HScrollBar.new()
var _widest: float = 0.0

var _font: Font = null
var _font_size: int = 0
var _char_width: float = 0.0
var _padding: float = 0.0
var _colors: Dictionary[StringName, Color] = {}
var _syntax: Array[Color] = []


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


## Shows a diff of `line_count` lines (`split_count` side-by-side rows);
## `max_line_number` sizes the number gutter. Keeps the scroll position when
## `keep_scroll` (a reload of the same file).
func show_lines(line_count: int, max_line_number: int, keep_scroll: bool, split_count: int = -1) -> void:
	_line_count = line_count
	_split_count = split_count if split_count >= 0 else line_count
	_number_digits = maxi(1, str(max_line_number).length())
	_cache.clear()
	if not keep_scroll:
		_widest = 0.0
		_h_scroll.value = 0.0
		clear_selection()
		cursor = -1
		set_scroll_offset(0.0)
	refresh()
	if keep_scroll:
		# Rows mean other lines now: keep only the cursor's row, so Enter can
		# stage line after line.
		_selected.clear()
		if cursor >= 0:
			_selected[cursor] = true
		_anchor = cursor
		selection_changed.emit()
	_update_h_range()


func set_side_by_side(value: bool) -> void:
	if value == side_by_side:
		return
	side_by_side = value
	_cache.clear()
	clear_selection()
	cursor = -1
	set_scroll_offset(0.0)
	refresh()
	_update_h_range()


## Horizontal scroll offset in pixels.
func h_scroll() -> float:
	return _h_scroll.value


func row_height() -> float:
	return float(maxi(1, get_theme_constant(&"row_height", DIFF_THEME_TYPE)))


## Data of a row: a line (unified) or `{left, right}` (side by side).
func row_data(row: int) -> Dictionary:
	if row < 0 or row >= row_count():
		return {}
	if not _cache.has(row):
		_fetch(row, 1)
	return _cache.get(row, {})


## The line shown on a unified row, or the new side (else old side) of a
## side-by-side row.
func line(row: int) -> Dictionary:
	var data: Dictionary = row_data(row)
	if not side_by_side:
		return data
	var right: Dictionary = data.get("right", {})
	return right if not right.is_empty() else data.get("left", {})


func line_text(row: int) -> String:
	return String(line(row).get("text", ""))


## Line indices of the selected rows (or the cursor's row), both sides of
## side-by-side rows included.
func selected_or_cursor() -> PackedInt32Array:
	var rows: PackedInt32Array = selected_rows()
	if rows.is_empty() and cursor >= 0:
		rows.append(cursor)
	var lines: PackedInt32Array = PackedInt32Array()
	for row: int in rows:
		for data: Dictionary in _row_lines(row):
			var index: int = int(data.get("index", -1))
			if index >= 0 and not lines.has(index):
				lines.append(index)
	lines.sort()
	return lines


## The selected lines with `+`/`-`/space prefixes, joined by newlines.
func selected_text() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for row: int in selected_rows():
		for data: Dictionary in _row_lines(row):
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


func _row_lines(row: int) -> Array[Dictionary]:
	var data: Dictionary = row_data(row)
	var out: Array[Dictionary] = []
	if not side_by_side:
		if not data.is_empty():
			out.append(data)
		return out
	var left: Dictionary = data.get("left", {})
	var right: Dictionary = data.get("right", {})
	if not left.is_empty():
		out.append(left)
	if not right.is_empty() and int(right.get("index", -1)) != int(left.get("index", -2)):
		out.append(right)
	return out


func _get_row_count() -> int:
	return _split_count if side_by_side else _line_count


func _prepare_rows(first: int, count: int) -> void:
	for index: int in range(first, first + count):
		if not _cache.has(index):
			var start: int = maxi(0, first - FETCH_MARGIN)
			_cache.clear()
			_fetch(start, first + count + FETCH_MARGIN - start)
			return


func _fetch(start: int, count: int) -> void:
	var fetch: Callable = split_source if side_by_side else source
	if not fetch.is_valid():
		return
	var rows: Array = fetch.call(start, count)
	var grew: bool = false
	for i: int in rows.size():
		var data: Dictionary = rows[i]
		_cache[start + i] = data
		var length: int = 0
		if side_by_side:
			length = maxi(String(data["left"].get("text", "")).length(), String(data["right"].get("text", "")).length())
		else:
			length = String(data.get("text", "")).length()
		if length * _char_width > _widest:
			_widest = length * _char_width
			grew = true
	if grew:
		_update_h_range.call_deferred()


## Width of a number gutter: `columns` number columns, the +/- mark, a space.
func _gutter_width(columns: int) -> float:
	return (_number_digits * columns + columns + 2) * _char_width + _padding * 2.0


func _baseline(rect: Rect2) -> float:
	return rect.position.y + (rect.size.y + _font.get_ascent(_font_size) - _font.get_descent(_font_size)) / 2.0


func _draw_row(index: int, rect: Rect2, selected_row: bool) -> void:
	var data: Dictionary = _cache.get(index, {})
	if data.is_empty():
		return
	if not side_by_side:
		_draw_side(data, rect, selected_row, 2)
		return
	var left: Dictionary = data["left"]
	var right: Dictionary = data["right"]
	if int(left.get("kind", -1)) == KIND_HUNK:
		_draw_side(left, rect, selected_row, 1)
		return
	var half: float = floorf(rect.size.x / 2.0)
	_draw_side(left, Rect2(rect.position, Vector2(half, rect.size.y)), selected_row, 1, true)
	_draw_side(right, Rect2(rect.position + Vector2(half, 0.0), Vector2(rect.size.x - half, rect.size.y)),
			selected_row, 1, false)


## Draws one line in `rect`: background, number gutter (`columns` 2 = old and
## new numbers; 1 = the side's own number), mark and text.
func _draw_side(data: Dictionary, rect: Rect2, selected_row: bool, columns: int, old_side: bool = false) -> void:
	var gutter: float = _gutter_width(columns)
	if data.is_empty():
		if not selected_row:
			draw_rect(rect, _colors[&"empty_bg"])
		return
	var kind: int = int(data["kind"])
	if not selected_row:
		var bg: Color = _row_bg(kind)
		if bg.a > 0.0:
			draw_rect(rect, bg)
		if kind != KIND_HUNK:
			draw_rect(Rect2(rect.position, Vector2(gutter, rect.size.y)), _colors[&"gutter_bg"])
	var baseline: float = _baseline(rect)
	var x: float = rect.position.x + _padding
	if kind != KIND_HUNK:
		var column: float = _number_digits * _char_width
		var numbers: Array[int] = [int(data["old"]), int(data["new"])]
		if columns == 1:
			numbers = [int(data["old"]) if old_side else int(data["new"])]
		for i: int in numbers.size():
			if numbers[i] > 0:
				var text: String = str(numbers[i])
				# Right-aligned by hand: a width limit can drop the last glyph.
				var right: float = x + column * (i + 1) + _char_width * i
				draw_string(_font, Vector2(right - text.length() * _char_width, baseline), text,
						HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, _colors[&"line_number_color"])
		var mark: String = "+" if kind == KIND_ADDED else ("-" if kind == KIND_REMOVED else "")
		if not mark.is_empty():
			var mark_color: Color = _colors[&"added_mark"] if kind == KIND_ADDED else _colors[&"removed_mark"]
			draw_string(_font, Vector2(x + (column + _char_width) * columns, baseline), mark,
					HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, mark_color)
	var text_left: float = rect.position.x + (_padding if kind == KIND_HUNK else gutter)
	_draw_text(data, kind, text_left, rect, baseline)


## The line's text from `left`, scrolled sideways: changed-word background,
## then syntax-colored segments, clipped to `rect`.
func _draw_text(data: Dictionary, kind: int, left: float, rect: Rect2, baseline: float) -> void:
	var text: String = String(data["text"])
	if bool(data.get("no_newline", false)):
		text += NO_NEWLINE_MARK
	var skip: int = int(_h_scroll.value / _char_width) if _char_width > 0.0 and kind != KIND_HUNK else 0
	var right: float = rect.end.x
	var column_x: Callable = func(column: int) -> float: return left + (column - skip) * _char_width
	var hl: PackedInt32Array = data.get("hl", PackedInt32Array())
	if hl.size() == 2 and hl[1] > hl[0]:
		var from: float = maxf(column_x.call(maxi(hl[0], skip)), left)
		var to: float = minf(column_x.call(hl[1]), right)
		if to > from:
			var hl_color: Color = _colors[&"added_hl_bg"] if kind == KIND_ADDED else _colors[&"removed_hl_bg"]
			draw_rect(Rect2(from, rect.position.y, to - from, rect.size.y), hl_color)
	var base: Color = _colors[&"hunk_color"] if kind == KIND_HUNK else _colors[&"text_color"]
	var segments: Array = _segments(text.length(), data.get("syntax", PackedInt32Array()), base)
	for segment: Array in segments:
		var start: int = maxi(int(segment[0]), skip)
		var end: int = int(segment[1])
		if end <= start:
			continue
		var x: float = column_x.call(start)
		if x >= right:
			break
		var chars: int = mini(end - start, int((right - x) / _char_width) + 1)
		draw_string(_font, Vector2(x, baseline), text.substr(start, chars), HORIZONTAL_ALIGNMENT_LEFT, -1,
				_font_size, segment[2])


## `[start, end, color]` runs covering `length` characters: syntax tokens in
## their colors, the gaps in `base`.
func _segments(length: int, syntax: PackedInt32Array, base: Color) -> Array:
	var out: Array = []
	var at: int = 0
	for i: int in range(0, syntax.size() - 2, 3):
		var start: int = clampi(syntax[i], at, length)
		var end: int = clampi(syntax[i + 1], start, length)
		if start > at:
			out.append([at, start, base])
		var kind: int = syntax[i + 2]
		out.append([start, end, _syntax[kind] if kind >= 0 and kind < _syntax.size() else base])
		at = end
	if at < length:
		out.append([at, length, base])
	return out


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
	var columns: int = 1 if side_by_side else 2
	var text_width: float = content_width() / (2.0 if side_by_side else 1.0) - _gutter_width(columns)
	var total: float = _widest + _char_width * 4.0
	_h_scroll.max_value = total
	_h_scroll.page = maxf(0.0, text_width)
	_h_scroll.visible = total > text_width and row_count() > 0
	_h_scroll.offset_right = -(_scroll_bar.size.x if _scroll_bar.visible else 0.0)


func _update_theme() -> void:
	_font = get_theme_font(&"font", DIFF_THEME_TYPE)
	_font_size = get_theme_font_size(&"font_size", DIFF_THEME_TYPE)
	_char_width = _font.get_char_size(ord("M"), _font_size).x
	_padding = float(get_theme_constant(&"padding", DIFF_THEME_TYPE))
	for color_name: StringName in [&"text_color", &"line_number_color", &"hunk_color", &"hunk_bg",
			&"added_bg", &"removed_bg", &"added_mark", &"removed_mark", &"gutter_bg", &"empty_bg",
			&"added_hl_bg", &"removed_hl_bg"]:
		_colors[color_name] = get_theme_color(color_name, DIFF_THEME_TYPE)
	_syntax.clear()
	for color_name: StringName in SYNTAX_COLORS:
		_syntax.append(get_theme_color(color_name, DIFF_THEME_TYPE))
	_update_h_range()
