class_name CommitList
extends VirtualList
## History rows (graph, ref labels and subject) driven by
## `RepoSession.graph_rows()`. Only a window around the visible rows is fetched.
## Hash, author and date are in the commit details.

const LIST_THEME_TYPE: StringName = &"CommitList"
## Rows fetched beyond each edge of the visible range.
const FETCH_MARGIN: int = 64
const LABEL_STYLES: Dictionary[String, StringName] = {
	"head": &"label_head",
	"branch": &"label_branch",
	"remote": &"label_remote",
	"tag": &"label_tag",
}

var session: RepoSession = null:
	set = set_session

## Time spent in the last `_draw()`, for benchmarks.
var last_draw_usec: int = 0
## Time spent in the last `graph_rows` fetch, for benchmarks.
var last_fetch_usec: int = 0
## Number of rows drawn since creation, for smoke tests.
var rows_drawn: int = 0


## Shaped text of one row, rebuilt when the subject width changes.
class RowText:
	extends RefCounted
	var subject: TextLine
	var labels: Array[TextLine] = []
	var label_styles: Array[StringName] = []
	## Width the labels take before the subject, including gaps.
	var labels_width: float = 0.0


var _graph: GraphView = GraphView.new()
var _rows: Dictionary[int, Dictionary] = {}
var _geometry: Dictionary[int, GraphView.RowGeometry] = {}
var _text: Dictionary[int, RowText] = {}
var _text_layout_width: float = -1.0
var _utc_offset_seconds: int = 0
var _utc_offset_known: bool = false
var _window_start: int = 0
var _window_end: int = 0
var _graph_lanes: int = 1

# Theme values, cached because `_draw_row` runs for every visible row each frame.
var _font: Font = null
var _font_size: int = 0
var _label_font_size: int = 0
var _padding: float = 0.0
var _label_gap: float = 0.0
var _subject_color: Color = Color.WHITE
var _label_color: Color = Color.WHITE
var _label_boxes: Dictionary[StringName, StyleBox] = {}
## Ref label pills drawn last frame: row -> `[[Rect2, label dict], ...]`.
var _label_rects: Dictionary[int, Array] = {}


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
	_label_font_size = get_theme_font_size(&"label_font_size", LIST_THEME_TYPE)
	_padding = float(get_theme_constant(&"padding", LIST_THEME_TYPE))
	_label_gap = float(get_theme_constant(&"label_gap", LIST_THEME_TYPE))
	_subject_color = get_theme_color(&"subject_color", LIST_THEME_TYPE)
	_label_color = get_theme_color(&"label_color", LIST_THEME_TYPE)
	for style: StringName in LABEL_STYLES.values():
		_label_boxes[style] = get_theme_stylebox(style, LIST_THEME_TYPE)


func set_session(value: RepoSession) -> void:
	if session != null:
		if session.graph_changed.is_connected(_on_graph_changed):
			session.graph_changed.disconnect(_on_graph_changed)
		if session.graph_reset.is_connected(_on_graph_reset):
			session.graph_reset.disconnect(_on_graph_reset)
	session = value
	if session != null:
		session.graph_changed.connect(_on_graph_changed)
		session.graph_reset.connect(_on_graph_reset)
	_clear_window()
	_graph_lanes = 1
	select_only(-1)
	set_scroll_offset(0.0)
	refresh()


func row_data(row: int) -> Dictionary:
	return _rows.get(row, {})


## Full hash of a row (fetched when it is outside the cached window), or "".
func hash_at(row: int) -> String:
	if row < 0 or session == null:
		return ""
	if _rows.has(row):
		return String(_rows[row]["hash"])
	var rows: Array[Dictionary] = session.graph_rows(row, 1)
	return String(rows[0]["hash"]) if not rows.is_empty() else ""


## The ref label drawn at `at` (local coordinates) on `row`: `{name, kind,
## is_head}` with the full ref name, or empty.
func label_at(row: int, at: Vector2) -> Dictionary:
	for hit: Array in _label_rects.get(row, []):
		if (hit[0] as Rect2).has_point(at):
			var label: Dictionary = hit[1]
			var short: String = String(label["name"])
			var kind: String = String(label["kind"])
			var prefix: String = {"branch": "refs/heads/", "remote": "refs/remotes/", "tag": "refs/tags/"}.get(kind, "")
			return {"name": prefix + short, "short": short, "kind": kind, "is_head": bool(label["is_head"])}
	return {}


## Local date and time (`YYYY-MM-DD HH:MM`) of a unix time.
func date_text(unix_time: int) -> String:
	return _date(unix_time)


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
	# The graph area fits the fetched window, so a wide stretch of history
	# does not leave a gap everywhere else.
	_graph_lanes = 1
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

	var subject_x: float = rect.position.x + _graph.width_for(_graph_lanes) + _padding
	var subject_width: float = rect.end.x - _padding - subject_x
	if subject_width != _text_layout_width:
		_text.clear()
		_text_layout_width = subject_width
	var text: RowText = _text.get(row)
	if text == null:
		text = _shape_row(data, subject_width)
		_text[row] = text

	var canvas: RID = get_canvas_item()
	var top: float = rect.position.y + (rect.size.y - text.subject.get_size().y) * 0.5
	var x: float = subject_x
	var hits: Array = []
	var labels: Array = data.get("refs", [])
	for i: int in text.labels.size():
		var width: float = _draw_label(canvas, text.labels[i], text.label_styles[i], x, rect)
		if i < labels.size():
			hits.append([Rect2(x, rect.position.y, width, rect.size.y), labels[i]])
		x += width + _label_gap
	_label_rects[row] = hits
	if subject_width - text.labels_width > 0.0:
		text.subject.draw(canvas, Vector2(subject_x + text.labels_width, top), _subject_color)


## Draws one ref label pill at `x`; returns its width.
func _draw_label(canvas: RID, line: TextLine, style: StringName, x: float, rect: Rect2) -> float:
	var box: StyleBox = _label_boxes[style]
	var size: Vector2 = line.get_size()
	var pill: Rect2 = Rect2(
			x,
			rect.position.y + (rect.size.y - size.y - box.get_minimum_size().y) * 0.5,
			size.x + box.get_minimum_size().x,
			size.y + box.get_minimum_size().y)
	draw_style_box(box, pill)
	line.draw(canvas, pill.position + Vector2(box.get_margin(SIDE_LEFT), box.get_margin(SIDE_TOP)), _label_color)
	return pill.size.x


func _shape_row(data: Dictionary, subject_width: float) -> RowText:
	var text: RowText = RowText.new()
	for label: Dictionary in data.get("refs", []):
		var line: TextLine = TextLine.new()
		line.add_string(String(label["name"]), _font, _label_font_size)
		var style: StringName = LABEL_STYLES["head"] if bool(label["is_head"]) \
				else LABEL_STYLES.get(String(label["kind"]), &"label_branch")
		text.labels.append(line)
		text.label_styles.append(style)
		text.labels_width += line.get_size().x + _label_boxes[style].get_minimum_size().x + _label_gap
	text.subject = _shape(data["subject"], subject_width - text.labels_width)
	return text


func _shape(value: String, width: float) -> TextLine:
	var line: TextLine = TextLine.new()
	line.add_string(value, _font, _font_size)
	line.width = maxf(0.0, width)
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return line


func _date(unix_time: int) -> String:
	if not _utc_offset_known:
		_utc_offset_seconds = int(Time.get_time_zone_from_system().get("bias", 0)) * 60
		_utc_offset_known = true
	return Time.get_datetime_string_from_unix_time(unix_time + _utc_offset_seconds, true).left(16)


func _clear_window() -> void:
	_label_rects.clear()
	_rows.clear()
	_geometry.clear()
	_text.clear()
	_window_start = 0
	_window_end = 0


func _on_graph_changed(_start: int, _count: int) -> void:
	refresh()


## A new load replaced the graph: drop cached rows, keep the scroll position.
func _on_graph_reset() -> void:
	_clear_window()
	_graph_lanes = 1
	refresh()
