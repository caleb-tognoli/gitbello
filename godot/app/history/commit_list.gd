class_name CommitList
extends VirtualList
## History rows driven by `RepoSession.graph_rows()` (a subclass can supply
## other rows of the same shape through `_fetch_rows`, without the graph:
## Compare's commits, M7.12c). Only a window around the visible rows is
## fetched. Rows have two lines (M7.10): the subject, then
## the author's avatar with the co-authors' after it, "Author +N · 3 h ago"
## and the ref chips on the right: the first branch and the first tag, each
## with "+N" for the others (`RefChip.summarize`), which emits
## `refs_requested`. `compact` keeps one line: the graph, the subject, and
## on the right an icon-only chip per kind of ref (`RefChip.shape_icons`)
## and the author's avatar. `show_graph` off leaves the graph out: the
## text starts at the left edge. A subclass can draw marks of its own after
## the ref chips (`_trailing_width`, `_draw_trailing`): a file history's
## line counts, for one.
## While a search is on
## (`set_search`), rows it does not match are dimmed (subject and graph dot)
## and the query is highlighted in the subjects of the rows it matches,
## and a `MarkStrip` beside the scroll bar shows where the matches are (the
## selected one stronger); clicking it scrolls there.

const LIST_THEME_TYPE: StringName = &"CommitList"
## Rows fetched beyond each edge of the visible range.
const FETCH_MARGIN: int = 64
## Height of the tallest letters (b, d, l) above the baseline, in ems of the
## UI font: two-line rows centre what is drawn, not the line boxes, whose
## ascent leaves empty space above the subject.
const INK_ASCENT: float = 0.75

## A "+N" chip of `row` (or a compact row's ref icons) was clicked: show all
## its refs at `at_position` (local), under the chip.
signal refs_requested(row: int, at_position: Vector2)

var session: RepoSession = null:
	set = set_session
## One-line rows (no author line); see `set_compact`.
var compact: bool = false:
	set = set_compact
## Draw the commit graph before the text; see `set_show_graph`.
var show_graph: bool = true:
	set = set_show_graph
## The rows are History's graph rows, reloaded when the graph changes (off
## for a subclass with rows of its own, which also leaves the graph out).
var follows_graph: bool = true

## Time spent in the last `_draw()`, for benchmarks.
var last_draw_usec: int = 0
## Time spent in the last `graph_rows` fetch, for benchmarks.
var last_fetch_usec: int = 0
## Number of rows drawn since creation, for smoke tests.
var rows_drawn: int = 0

## The search's query as typed, or "" without a search.
var _query: String = ""


## Shaped text of one row, rebuilt when the subject width changes.
class RowText:
	extends RefCounted
	var subject: TextLine
	## The chips and what each stands for (`RefChip.summarize` entries).
	var chips: Array[RefChip.Shaped] = []
	var chip_items: Array[Dictionary] = []
	## Width the chips take, including gaps.
	var labels_width: float = 0.0
	## "Author +N · 3 h ago" (two-line rows only).
	var meta: TextLine = null
	## Width of the subclass's marks after the chips (`_trailing_width`).
	var trailing_width: float = 0.0


var _graph: GraphView = GraphView.new()
var _strip: MarkStrip = MarkStrip.new()
var _rows: Dictionary[int, Dictionary] = {}
var _geometry: Dictionary[int, GraphView.RowGeometry] = {}
var _text: Dictionary[int, RowText] = {}
var _text_layout_width: float = -1.0
var _utc_offset_seconds: int = 0
var _utc_offset_known: bool = false
var _window_start: int = 0
var _window_end: int = 0
var _graph_lanes: int = 1


func _init() -> void:
	super()
	draws_unfocused_cursor = true


# Theme values, cached because `_draw_row` runs for every visible row each frame.
var _font: Font = null
var _font_size: int = 0
var _padding: float = 0.0
var _label_gap: float = 0.0
var _subject_color: Color = Color.WHITE
var _dim_subject_color: Color = Color.WHITE
var _dim_node_alpha: float = 1.0
var _match_color: Color = Color.WHITE
## Ref chips drawn last frame: row -> `[[Rect2, summarize entry], ...]`.
var _label_rects: Dictionary[int, Array] = {}
## The author line drawn last frame (avatars and text): row -> Rect2.
var _meta_rects: Dictionary[int, Rect2] = {}
var _meta_font_size: int = 0
var _meta_color: Color = Color.WHITE
var _divider_color: Color = Color.TRANSPARENT
var _avatar_size: float = 0.0
var _avatar_step: float = 0.0
var _avatar_gap: float = 0.0
var _compact_avatar_size: float = 0.0
var _line_gap: float = 0.0
var _ring_color: Color = Color.WHITE
var _selection_color: Color = Color.WHITE
## Avatars drawn per row: the author and up to this many co-authors.
const MAX_AVATARS: int = 3
## "Now" for the relative dates, in whole minutes: the shaped author lines
## are rebuilt when it changes.
var _now_minute: int = -1


func _ready() -> void:
	super()
	_strip.visible = false
	_strip.overview_source = func(buckets: int) -> PackedByteArray:
		return session.search_overview(buckets) if session != null else PackedByteArray()
	_strip.jumped.connect(func(fraction: float) -> void:
		set_scroll_offset(fraction * row_count() * row_height() - size.y / 2.0))
	add_child(_strip, false, Node.INTERNAL_MODE_FRONT)
	_update_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_update_theme()
		_geometry.clear()
		_text.clear()
		queue_redraw()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		# The author lines' dates are translated.
		_text.clear()
		queue_redraw()


func _update_theme() -> void:
	_graph.update_theme(self)
	_font = get_theme_font(&"font", &"Label")
	_font_size = get_theme_font_size(&"font_size", &"Label")
	_padding = float(get_theme_constant(&"padding", LIST_THEME_TYPE))
	_label_gap = float(get_theme_constant(&"label_gap", LIST_THEME_TYPE))
	_subject_color = get_theme_color(&"subject_color", LIST_THEME_TYPE)
	_dim_subject_color = get_theme_color(&"dim_subject_color", LIST_THEME_TYPE)
	_dim_node_alpha = get_theme_color(&"dim_node_color", LIST_THEME_TYPE).a
	_match_color = get_theme_color(&"match_color", LIST_THEME_TYPE)
	_meta_font_size = get_theme_font_size(&"meta_font_size", LIST_THEME_TYPE)
	_meta_color = get_theme_color(&"meta_color", LIST_THEME_TYPE)
	_divider_color = get_theme_color(&"divider_color", LIST_THEME_TYPE)
	_avatar_size = float(get_theme_constant(&"avatar_size", LIST_THEME_TYPE))
	_avatar_step = _avatar_size - float(get_theme_constant(&"avatar_overlap", LIST_THEME_TYPE))
	_avatar_gap = float(get_theme_constant(&"avatar_gap", LIST_THEME_TYPE))
	_compact_avatar_size = float(get_theme_constant(&"compact_avatar_size", LIST_THEME_TYPE))
	_line_gap = float(get_theme_constant(&"line_gap", LIST_THEME_TYPE))
	_ring_color = get_theme_color(&"ring_color", AvatarPainter.THEME_TYPE)
	_selection_color = get_theme_color(&"selection_color", THEME_TYPE)


## Two-line rows are taller (`two_line_row_height`); compact ones use the
## list's row height.
func row_height() -> float:
	if compact:
		return super()
	return float(maxi(1, get_theme_constant(&"two_line_row_height", LIST_THEME_TYPE)))


## Switches between one-line and two-line rows, keeping the cursor's row
## in view.
func set_compact(value: bool) -> void:
	if compact == value:
		return
	var anchor: int = cursor if cursor >= 0 else first_visible_row()
	compact = value
	_geometry.clear()
	_text.clear()
	_text_layout_width = -1.0
	if not is_node_ready():
		return
	refresh()
	if anchor >= 0:
		set_scroll_offset(anchor * row_height() - size.y * 0.5 + row_height() * 0.5)
	queue_redraw()


## Draws the graph or leaves it out (the text moves to the left edge).
func set_show_graph(value: bool) -> void:
	if show_graph == value:
		return
	show_graph = value
	queue_redraw()


## Where the rows' text starts: after the graph, or at the left edge.
func text_left() -> float:
	return (_graph.width_for(_graph_lanes) if show_graph else 0.0) + _padding


func set_session(value: RepoSession) -> void:
	if session != null:
		if session.graph_changed.is_connected(_on_graph_changed):
			session.graph_changed.disconnect(_on_graph_changed)
		if session.graph_reset.is_connected(_on_graph_reset):
			session.graph_reset.disconnect(_on_graph_reset)
	session = value
	if session != null and follows_graph:
		session.graph_changed.connect(_on_graph_changed)
		session.graph_reset.connect(_on_graph_reset)
	_clear_window()
	_graph_lanes = 1
	select_only(-1)
	set_scroll_offset(0.0)
	refresh()
	_update_strip()


func row_data(row: int) -> Dictionary:
	if _rows.has(row):
		return _rows[row]
	if session == null or row < 0:
		return {}
	var rows: Array[Dictionary] = _fetch_rows(row, 1)
	return rows[0] if not rows.is_empty() else {}


## Rows `start` to `start + count` (fewer at the end), each with its `row`.
func _fetch_rows(start: int, count: int) -> Array[Dictionary]:
	return session.graph_rows(start, count) if session != null else []


## Fetches the rows again (their source changed).
func reload() -> void:
	_clear_window()
	refresh()
	queue_redraw()


func _get_tooltip(at_position: Vector2) -> String:
	var row: int = row_at(at_position)
	var data: Dictionary = row_data(row)
	if data.is_empty() or session == null:
		return ""
	if (_meta_rects.get(row, Rect2()) as Rect2).has_point(at_position):
		return people_text(data)
	var item: Dictionary = _chip_item_at(row, at_position)
	if item.has("label"):
		return RefChip.tooltip(item["label"])
	if item.has("labels"):
		return RefChip.group_tooltip(item["labels"])
	if item.has("more"):
		var names: PackedStringArray = PackedStringArray()
		for ref_label: Dictionary in item["more"]:
			names.append(String(ref_label["name"]))
		return "\n".join(names)
	if not bool(data.get("outgoing", false)):
		return ""
	return CommitList.outgoing_text(session.history_info())


## The author line's tooltip: "Name <email>", each co-author, the exact time.
func people_text(data: Dictionary) -> String:
	var lines: PackedStringArray = PackedStringArray([CommitList.identity_text(
			String(data.get("author", "")), String(data.get("email", "")))])
	for person: Dictionary in data.get("coauthors", []):
		lines.append(tr("Co-author: %s") % CommitList.identity_text(
				String(person["name"]), String(person["email"])))
	lines.append(date_text(int(data.get("time", 0))))
	return "\n".join(lines)


## "Name <email>", or the one of them there is.
static func identity_text(person: String, email: String) -> String:
	if email.is_empty():
		return person
	return "<%s>" % email if person.is_empty() else "%s <%s>" % [person, email]


## "Outgoing · not in origin/main", or "· not on any remote" without an
## upstream (or with a gone one).
static func outgoing_text(info: Dictionary) -> String:
	var upstream: String = String(info.get("upstream", "")).trim_prefix("refs/remotes/").trim_prefix("refs/heads/")
	if upstream.is_empty() or bool(info.get("gone", false)):
		return TranslationServer.translate("Outgoing · not on any remote")
	return TranslationServer.translate("Outgoing · not in %s") % upstream


## Full hash of a row (fetched when it is outside the cached window), or "".
func hash_at(row: int) -> String:
	if row < 0 or session == null:
		return ""
	if _rows.has(row):
		return String(_rows[row].get("hash", ""))
	var rows: Array[Dictionary] = _fetch_rows(row, 1)
	return String(rows[0].get("hash", "")) if not rows.is_empty() else ""


## The ref label drawn at `at` (local coordinates) on `row`: `{name, kind,
## is_head}` with the full ref name, or empty.
func label_at(row: int, at: Vector2) -> Dictionary:
	var item: Dictionary = _chip_item_at(row, at)
	if item.has("label"):
		return RefChip.ref_target(item["label"])
	if item.has("labels") and (item["labels"] as Array).size() == 1:
		return RefChip.ref_target(item["labels"][0])
	return {}


## Whether `at` (local coordinates) is on a chip that opens the popover of
## `row`'s refs: a "+N", or a compact row's ref icons.
func more_at(row: int, at: Vector2) -> bool:
	var item: Dictionary = _chip_item_at(row, at)
	return item.has("more") or item.has("labels")


## Where `row`'s chips were drawn last frame: `[[Rect2, summarize entry]]`.
func chip_rects(row: int) -> Array:
	return _label_rects.get(row, [])


func _chip_item_at(row: int, at: Vector2) -> Dictionary:
	for hit: Array in _label_rects.get(row, []):
		if (hit[0] as Rect2).has_point(at):
			return hit[1]
	return {}


func _gui_input(event: InputEvent) -> void:
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		var row: int = row_at(mouse.position)
		for hit: Array in _label_rects.get(row, []):
			var rect: Rect2 = hit[0]
			var item: Dictionary = hit[1]
			# A click on +N or the icons lists the refs; a right-click on an
			# icon of one ref is that ref's menu (`label_at`).
			var lists: bool = item.has("more") or (item.has("labels") and (mouse.button_index == MOUSE_BUTTON_LEFT
					or (item["labels"] as Array).size() > 1))
			if rect.has_point(mouse.position) and lists:
				accept_event()
				refs_requested.emit(row, Vector2(rect.position.x, rect.end.y))
				return
	super(event)


## Dims the rows `query` does not match ("" ends it). The match flags
## come with the rows: call `reload_matches` when the search reports.
func set_search(query: String) -> void:
	_query = query.strip_edges()
	_update_strip()
	queue_redraw()


func search_query() -> String:
	return _query


## Fetches the rows again for their new match flags.
func reload_matches() -> void:
	_clear_window()
	_update_strip()
	queue_redraw()


## The strip of matches beside the scroll bar.
func match_strip() -> MarkStrip:
	return _strip


## Shows the strip while a search has matches, with their marks fetched again.
func _update_strip() -> void:
	_strip.visible = not _query.is_empty() and session != null 			and int(session.search_info().get("matches", 0)) > 0
	_strip.refresh()
	queue_redraw()


func _scroll_column_width() -> float:
	return super() + (_strip.strip_width() if _strip.visible else 0.0)


## Local date and time (`YYYY-MM-DD HH:MM`) of a unix time.
func date_text(unix_time: int) -> String:
	return _date(unix_time)


func _get_row_count() -> int:
	return session.graph_row_count() if session != null else 0


func _draw() -> void:
	var started: int = Time.get_ticks_usec()
	if _strip.visible:
		# Beside the scroll bar, which shows and hides with the row count.
		var width: float = _strip.strip_width()
		_strip.position = Vector2(size.x - _scroll_column_width(), 0.0)
		_strip.size = Vector2(width, size.y)
		var current: bool = cursor >= 0 and session.search_match_index(cursor) >= 0
		_strip.current = (cursor + 0.5) / maxf(1.0, float(row_count())) if current else -1.0
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
	var fetched: Array[Dictionary] = _fetch_rows(_window_start, count + 2 * FETCH_MARGIN)
	for data: Dictionary in fetched:
		var row: int = data["row"]
		_rows[row] = data
		_graph_lanes = mini(maxi(_graph_lanes, int(data.get("width", 1))), _graph.max_lanes)
	_window_end = _window_start + fetched.size()
	last_fetch_usec = Time.get_ticks_usec() - started


func _draw_row(row: int, rect: Rect2, _selected_row: bool) -> void:
	var data: Dictionary = _rows.get(row, {})
	if data.is_empty():
		return
	rows_drawn += 1
	var dimmed: bool = not _query.is_empty() and not bool(data.get("match", false))
	if show_graph:
		var geometry: GraphView.RowGeometry = _geometry.get(row)
		if geometry == null:
			geometry = _graph.build(data, rect.size.y)
			_geometry[row] = geometry
		_graph.draw(self, geometry, rect.position, _dim_node_alpha if dimmed else 1.0)
	var subject_x: float = rect.position.x + text_left()
	var icon_size: float = float(get_theme_constant(&"outgoing_icon_size", LIST_THEME_TYPE))
	# Two-line rows keep a column for the push icon; compact ones put it
	# before the subject, only on the commits to push.
	var subject_width: float = rect.end.x - _padding - subject_x
	if not compact:
		subject_width -= icon_size + _label_gap
	var minute: int = floori(Time.get_unix_time_from_system() / 60.0)
	if subject_width != _text_layout_width or (not compact and minute != _now_minute):
		_text.clear()
		_text_layout_width = subject_width
		_now_minute = minute
	var text: RowText = _text.get(row)
	if text == null:
		text = _shape_row(data, subject_width, rect.end.x - _padding - subject_x)
		_text[row] = text
	# The subject's line: the whole row when compact, else its top line.
	var band: Rect2 = rect
	var meta_band: Rect2 = Rect2()
	if not compact:
		var subject_height: float = text.subject.get_size().y
		var meta_height: float = maxf(text.meta.get_size().y, _avatar_size)
		# Same space above the subject's letters as below the avatars, with
		# the divider's pixel left out at the bottom.
		var slack: float = maxf(0.0, text.subject.get_line_ascent() - _font_size * INK_ASCENT)
		var ink_height: float = subject_height - slack + _line_gap + meta_height
		var top: float = roundf(rect.position.y + (rect.size.y - 1.0 - ink_height) * 0.5 - slack)
		band = Rect2(rect.position.x, top, rect.size.x, subject_height)
		meta_band = Rect2(rect.position.x, top + subject_height + _line_gap, rect.size.x, meta_height)
	if bool(data.get("outgoing", false)):
		var icon_x: float = subject_x if compact else rect.end.x - _padding - icon_size
		var icon_rect: Rect2 = Rect2(icon_x, band.position.y + (band.size.y - icon_size) * 0.5, icon_size, icon_size)
		var color: Color = get_theme_color(&"outgoing_color", LIST_THEME_TYPE)
		if dimmed:
			color.a *= _dim_node_alpha
		draw_texture_rect(AppTheme.icon(&"GitPush"), icon_rect, false, color)
	if compact:
		_draw_compact_text(row, data, text, rect, subject_x, subject_width, dimmed)
	else:
		_draw_two_line_text(row, data, text, band, meta_band, subject_x, subject_width, dimmed, _selected_row)
		_draw_divider(row, rect, subject_x)


## The line under a two-line row, from where its text starts (the graph
## stays unbroken), so each author line reads with its subject. Left out
## after the last row and beside a selected row, whose highlight already
## separates it.
func _draw_divider(row: int, rect: Rect2, subject_x: float) -> void:
	if row + 1 >= row_count() or is_selected(row) or is_selected(row + 1):
		return
	var y: float = rect.end.y - 0.5
	draw_line(Vector2(subject_x, y), Vector2(rect.end.x - _padding, y), _divider_color, 1.0)


## The two-line row's text: the subject on `band`; on `meta_band` the
## avatars, "Author +N · when" and the ref labels on the right.
func _draw_two_line_text(row: int, data: Dictionary, text: RowText, band: Rect2, meta_band: Rect2,
		subject_x: float, subject_width: float, dimmed: bool, selected: bool) -> void:
	var canvas: RID = get_canvas_item()
	var origin: Vector2 = Vector2(subject_x, band.position.y)
	if not _query.is_empty() and not dimmed:
		_draw_match(text.subject, String(data["subject"]), origin, subject_width)
	text.subject.draw(canvas, origin, _dim_subject_color if dimmed else _subject_color)

	var alpha: float = _dim_node_alpha if dimmed else 1.0
	var right: float = meta_band.end.x - _padding
	_draw_chips(row, text, right - maxf(0.0, text.labels_width - _label_gap), meta_band)
	if text.trailing_width > 0.0:
		_draw_trailing(row, data, Rect2(right - text.trailing_width, meta_band.position.y,
				text.trailing_width, meta_band.size.y), alpha)

	var people: Array[Dictionary] = [{"name": String(data.get("author", "")), "email": String(data.get("email", ""))}]
	for person: Dictionary in data.get("coauthors", []):
		if people.size() >= MAX_AVATARS:
			break
		people.append(person)
	var center_y: float = meta_band.position.y + meta_band.size.y * 0.5
	var ring: Color = _ring_color.blend(_selection_color) if selected else _ring_color
	# Right to left, so each avatar overlaps the next.
	for i: int in range(people.size() - 1, -1, -1):
		var center: Vector2 = Vector2(subject_x + _avatar_size * 0.5 + i * _avatar_step, center_y)
		AvatarPainter.draw(self, self, center, _avatar_size, String(people[i]["name"]),
				String(people[i]["email"]), AppTheme.bold_font(),
				ring if people.size() > 1 else Color(0, 0, 0, 0), 2.0, alpha)
	var avatars_width: float = _avatar_size + (people.size() - 1) * _avatar_step
	var meta_x: float = subject_x + avatars_width + _avatar_gap
	var meta_color: Color = _meta_color
	meta_color.a *= alpha
	text.meta.draw(canvas, Vector2(meta_x, center_y - text.meta.get_size().y * 0.5), meta_color)
	_meta_rects[row] = Rect2(subject_x, meta_band.position.y,
			meta_x - subject_x + text.meta.get_size().x, meta_band.size.y)


## The compact row: the subject (after the push icon on a commit to push),
## then on the right the ref icons and the author's avatar (its tooltip
## names the people).
func _draw_compact_text(row: int, data: Dictionary, text: RowText, rect: Rect2,
		subject_x: float, subject_width: float, dimmed: bool) -> void:
	var canvas: RID = get_canvas_item()
	var right: float = subject_x + subject_width
	var center: Vector2 = Vector2(right - _compact_avatar_size * 0.5, rect.position.y + rect.size.y * 0.5)
	AvatarPainter.draw(self, self, center, _compact_avatar_size, String(data.get("author", "")),
			String(data.get("email", "")), AppTheme.bold_font(), Color(0, 0, 0, 0), 0.0,
			_dim_node_alpha if dimmed else 1.0)
	_meta_rects[row] = Rect2(right - _compact_avatar_size, rect.position.y, _compact_avatar_size, rect.size.y)
	var chips_x: float = right - _compact_avatar_size - _avatar_gap - maxf(0.0, text.labels_width - _label_gap)
	_draw_chips(row, text, chips_x, rect)
	if text.trailing_width > 0.0:
		_draw_trailing(row, data, Rect2(right - _compact_avatar_size - _avatar_gap - text.trailing_width,
				rect.position.y, text.trailing_width, rect.size.y), _dim_node_alpha if dimmed else 1.0)
	var top: float = rect.position.y + (rect.size.y - text.subject.get_size().y) * 0.5
	var origin: Vector2 = Vector2(subject_x + _outgoing_width(data), top)
	if not _query.is_empty() and not dimmed:
		_draw_match(text.subject, String(data["subject"]), origin, text.subject.width)
	text.subject.draw(canvas, origin, _dim_subject_color if dimmed else _subject_color)


## Highlights where the query appears in a subject (none when the row
## matched by author or hash).
func _draw_match(line: TextLine, subject: String, origin: Vector2, width: float) -> void:
	var at: int = subject.findn(_query)
	if at < 0:
		return
	var server: TextServer = TextServerManager.get_primary_interface()
	var height: float = line.get_size().y
	for span: Vector2 in server.shaped_text_get_selection(line.get_rid(), at, at + _query.length()):
		var left: float = clampf(span.x, 0.0, width)
		var right: float = clampf(span.y, 0.0, width)
		if right > left:
			draw_rect(Rect2(origin.x + left, origin.y, right - left, height), _match_color)


## Draws `row`'s chips from `x`, centred on `band`, and keeps where they are.
func _draw_chips(row: int, text: RowText, x: float, band: Rect2) -> void:
	var hits: Array = []
	for i: int in text.chips.size():
		var chip: RefChip.Shaped = text.chips[i]
		RefChip.paint(self, self, chip, Vector2(x, roundf(band.position.y + (band.size.y - chip.size.y) * 0.5)))
		hits.append([Rect2(x, band.position.y, chip.size.x, band.size.y), text.chip_items[i]])
		x += chip.size.x + _label_gap
	_label_rects[row] = hits


## Shapes a row's text: in a compact row the labels share the subject's
## `subject_width`; in a two-line row the subject has all of it and the
## author line `line_width` less the avatars and the labels.
func _shape_row(data: Dictionary, subject_width: float, line_width: float) -> RowText:
	var text: RowText = RowText.new()
	var refs: Array = data.get("refs", [])
	for item: Dictionary in RefChip.group_kinds(refs) if compact else RefChip.summarize(refs):
		var chip: RefChip.Shaped
		if item.has("labels"):
			chip = RefChip.shape_icons(self, item["labels"])
		elif item.has("label"):
			chip = RefChip.shape(self, item["label"])
		else:
			chip = RefChip.shape_more(self, (item["more"] as Array).size())
		text.chips.append(chip)
		text.chip_items.append(item)
		text.labels_width += chip.size.x + _label_gap
	text.trailing_width = _trailing_width(data)
	if text.trailing_width > 0.0:
		text.labels_width += text.trailing_width + _label_gap
	if compact:
		text.subject = _shape(data["subject"], subject_width - _outgoing_width(data)
				- text.labels_width - _compact_avatar_size - _avatar_gap)
		return text
	text.subject = _shape(data["subject"], subject_width)
	var coauthors: int = (data.get("coauthors", []) as Array).size()
	var avatars: int = mini(1 + coauthors, MAX_AVATARS)
	var avatars_width: float = _avatar_size + (avatars - 1) * _avatar_step + _avatar_gap
	text.meta = _shape(meta_text(data), line_width - avatars_width - text.labels_width,
			_meta_font_size)
	return text


## Width of what a subclass draws at the right of a row, after its ref
## chips (on the author line; in a compact row before the avatar): 0 for
## nothing. The row's text leaves it free.
func _trailing_width(_data: Dictionary) -> float:
	return 0.0


## Draws a row's marks in `rect` (`_trailing_width` wide, the height of the
## line they are on), faded by `alpha` on a dimmed row.
func _draw_trailing(_row: int, _data: Dictionary, _rect: Rect2, _alpha: float) -> void:
	pass


## Room the push icon takes before a compact row's subject: none unless the
## commit is to push.
func _outgoing_width(data: Dictionary) -> float:
	if not bool(data.get("outgoing", false)):
		return 0.0
	return float(get_theme_constant(&"outgoing_icon_size", LIST_THEME_TYPE)) + _label_gap


## "Author +2 · 3 h ago": the author (or their email), how many co-authors
## and the relative date.
func meta_text(data: Dictionary) -> String:
	var author: String = String(data.get("author", ""))
	if author.is_empty():
		author = String(data.get("email", ""))
	var coauthors: int = (data.get("coauthors", []) as Array).size()
	if coauthors > 0:
		author += " +%d" % coauthors
	var now: int = int(Time.get_unix_time_from_system())
	return "%s · %s" % [author, RelativeDate.text(int(data.get("time", 0)), now, _offset())]


func _shape(value: String, width: float, font_size: int = -1) -> TextLine:
	var line: TextLine = TextLine.new()
	line.add_string(value, _font, _font_size if font_size < 0 else font_size)
	line.width = maxf(0.0, width)
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return line


func _date(unix_time: int) -> String:
	return RelativeDate.exact(unix_time, _offset())


func _offset() -> int:
	if not _utc_offset_known:
		_utc_offset_seconds = RelativeDate.local_offset()
		_utc_offset_known = true
	return _utc_offset_seconds


func _clear_window() -> void:
	_label_rects.clear()
	_meta_rects.clear()
	_rows.clear()
	_geometry.clear()
	_text.clear()
	_window_start = 0
	_window_end = 0


func _on_graph_changed(_start: int, _count: int) -> void:
	refresh()
	_strip.refresh()


## A new load replaced the graph: drop cached rows, keep the scroll position.
func _on_graph_reset() -> void:
	_clear_window()
	_graph_lanes = 1
	refresh()
