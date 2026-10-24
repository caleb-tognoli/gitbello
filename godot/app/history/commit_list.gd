class_name CommitList
extends VirtualList
## History rows (graph, subject, hash, author, date) driven by
## `RepoSession.graph_rows()`. Only a window around the visible rows is fetched.

const LIST_THEME_TYPE: StringName = &"CommitList"
## Rows fetched beyond each edge of the visible range.
const FETCH_MARGIN: int = 64

var session: RepoSession = null:
	set = set_session

## Time spent in the last `_draw()`, for benchmarks.
var last_draw_usec: int = 0
## Time spent in the last `graph_rows` fetch, for benchmarks.
var last_fetch_usec: int = 0
## Number of rows drawn since creation, for smoke tests.
var rows_drawn: int = 0

var _graph: GraphView = GraphView.new()
var _rows: Dictionary[int, Dictionary] = {}
var _geometry: Dictionary[int, GraphView.RowGeometry] = {}
## Shaped text per row: subject, hash, author, date. Rebuilt when widths change.
var _text: Dictionary[int, Array] = {}
var _text_layout_width: float = -1.0
var _utc_offset_seconds: int = 0
var _utc_offset_known: bool = false
var _window_start: int = 0
var _window_end: int = 0
var _graph_lanes: int = 1

# Theme values, cached because `_draw_row` runs for every visible row each frame.
var _font: Font = null
var _font_size: int = 0
var _padding: float = 0.0
var _author_width: float = 0.0
var _date_width: float = 0.0
var _hash_width: float = 0.0
var _subject_color: Color = Color.WHITE
var _hash_color: Color = Color.WHITE
var _author_color: Color = Color.WHITE
var _date_color: Color = Color.WHITE


func _ready() -> void:
	super()
	_update_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_update_theme()
		_geometry.clear()
		_text.clear()
		queue_redraw()


func _update_theme() -> void:
	_graph.update_theme(self)
	_font = get_theme_font(&"font", &"Label")
	_font_size = get_theme_font_size(&"font_size", &"Label")
	_padding = float(get_theme_constant(&"padding", LIST_THEME_TYPE))
	_author_width = float(get_theme_constant(&"author_width", LIST_THEME_TYPE))
	_date_width = float(get_theme_constant(&"date_width", LIST_THEME_TYPE))
	_hash_width = float(get_theme_constant(&"hash_width", LIST_THEME_TYPE))
	_subject_color = get_theme_color(&"subject_color", LIST_THEME_TYPE)
	_hash_color = get_theme_color(&"hash_color", LIST_THEME_TYPE)
	_author_color = get_theme_color(&"author_color", LIST_THEME_TYPE)
	_date_color = get_theme_color(&"date_color", LIST_THEME_TYPE)


func set_session(value: RepoSession) -> void:
	if session != null and session.graph_changed.is_connected(_on_graph_changed):
		session.graph_changed.disconnect(_on_graph_changed)
	session = value
	if session != null:
		session.graph_changed.connect(_on_graph_changed)
	_clear_window()
	_graph_lanes = 1
	select_only(-1)
	set_scroll_offset(0.0)
	refresh()


func row_data(row: int) -> Dictionary:
	return _rows.get(row, {})


func _get_row_count() -> int:
	return session.graph_row_count() if session != null else 0


func _draw() -> void:
	var started: int = Time.get_ticks_usec()
	super()
	last_draw_usec = Time.get_ticks_usec() - started


func _prepare_rows(first: int, count: int) -> void:
	if session == null or (first >= _window_start and first + count <= _window_end):
		return
	var started: int = Time.get_ticks_usec()
	_clear_window()
	_window_start = maxi(0, first - FETCH_MARGIN)
	var fetched: Array[Dictionary] = session.graph_rows(_window_start, count + 2 * FETCH_MARGIN)
	for data: Dictionary in fetched:
		var row: int = data["row"]
		_rows[row] = data
		_graph_lanes = mini(maxi(_graph_lanes, int(data["width"])), _graph.max_lanes)
	_window_end = _window_start + fetched.size()
	last_fetch_usec = Time.get_ticks_usec() - started


func _draw_row(row: int, rect: Rect2, _selected_row: bool) -> void:
	var data: Dictionary = _rows.get(row, {})
	if data.is_empty():
		return
	rows_drawn += 1
	var geometry: GraphView.RowGeometry = _geometry.get(row)
	if geometry == null:
		geometry = _graph.build(data, rect.size.y)
		_geometry[row] = geometry
	_graph.draw(self, geometry, rect.position)

	var right: float = rect.end.x - _padding
	var date_x: float = right - _date_width
	var author_x: float = date_x - _padding - _author_width
	var hash_x: float = author_x - _padding - _hash_width
	var subject_x: float = rect.position.x + _graph.width_for(_graph_lanes) + _padding
	var subject_width: float = hash_x - _padding - subject_x
	if subject_width != _text_layout_width:
		_text.clear()
		_text_layout_width = subject_width
	var lines: Array = _text.get(row, [])
	if lines.is_empty():
		lines = [
			_shape(data["subject"], subject_width, HORIZONTAL_ALIGNMENT_LEFT),
			_shape(String(data["hash"]).left(7), _hash_width, HORIZONTAL_ALIGNMENT_LEFT),
			_shape(data["author"], _author_width, HORIZONTAL_ALIGNMENT_LEFT),
			_shape(_date(int(data["time"])), _date_width, HORIZONTAL_ALIGNMENT_RIGHT),
		]
		_text[row] = lines
	var canvas: RID = get_canvas_item()
	var top: float = rect.position.y + (rect.size.y - (lines[0] as TextLine).get_size().y) * 0.5
	if subject_width > 0.0:
		(lines[0] as TextLine).draw(canvas, Vector2(subject_x, top), _subject_color)
	(lines[1] as TextLine).draw(canvas, Vector2(hash_x, top), _hash_color)
	(lines[2] as TextLine).draw(canvas, Vector2(author_x, top), _author_color)
	(lines[3] as TextLine).draw(canvas, Vector2(date_x, top), _date_color)


func _shape(text: String, width: float, alignment: HorizontalAlignment) -> TextLine:
	var line: TextLine = TextLine.new()
	line.add_string(text, _font, _font_size)
	line.width = maxf(0.0, width)
	line.alignment = alignment
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return line


func _date(unix_time: int) -> String:
	if not _utc_offset_known:
		_utc_offset_seconds = int(Time.get_time_zone_from_system().get("bias", 0)) * 60
		_utc_offset_known = true
	return Time.get_datetime_string_from_unix_time(unix_time + _utc_offset_seconds, true).left(16)


func _clear_window() -> void:
	_rows.clear()
	_geometry.clear()
	_text.clear()
	_window_start = 0
	_window_end = 0


func _on_graph_changed(_start: int, _count: int) -> void:
	refresh()
