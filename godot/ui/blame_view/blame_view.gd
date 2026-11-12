class_name BlameView
extends DiffView
## A file's lines with who last changed each (PLAN M8b): the diff view's
## text, selection, minimap and number gutter, with a gutter before it that
## names each run of lines' commit.
##
## Rows come from `source` as `RepoSession.blame_lines` gives them: unchanged
## lines plus `commit`, `first`, `author`, `email`, `time`, `summary`, `age`,
## `working` and `focus`. The gutter names a commit on the first line of its
## run (and on the top row, so a long run keeps its name while it scrolls)
## with the author's avatar and name and, at its edge, the date. It
## draws a line between runs and a bar in the commit's age: faint for the
## file's oldest commit, the accent for its newest, the modified colour for
## lines not committed yet. Lines git has not reported yet have an empty
## gutter. The focused commit's lines are tinted. Clicking the gutter (or
## Enter on a line) emits `commit_clicked`. Colours and sizes come from the
## `BlameView` theme type.

## The gutter of `row` was clicked, or Enter pressed on it: its commit.
signal commit_clicked(oid: String, row: int)

const BLAME_THEME_TYPE: StringName = &"BlameView"
## Shaped gutter texts kept (cleared when full).
const TEXT_CACHE: int = 512

## Asks for the authors' profile pictures (`AvatarPainter`).
var session: RepoSession = null

## The commit whose gutter rows the mouse is over.
var _hover_commit: String = ""
var _meta_font_size: int = 0
var _gap: float = 0.0
var _bar: float = 0.0
var _avatar: float = 0.0
var _widths: Dictionary[StringName, float] = {}
var _blame_colors: Dictionary[StringName, Color] = {}
## Shaped gutter texts: "column|text" -> TextLine.
var _texts: Dictionary[String, TextLine] = {}
var _utc_offset: int = 0
var _now: int = 0


func _init() -> void:
	super()
	number_columns = 1


func _ready() -> void:
	super()
	mouse_exited.connect(func() -> void: _set_hover_commit(""))
	AvatarPictures.shared().changed.connect(func(_email: String) -> void: queue_redraw())
	_utc_offset = RelativeDate.local_offset()


## The commit of `row` ("" until git reports the line).
func commit_at(row: int) -> String:
	return String(row_data(row).get("commit", ""))


## Puts the caret on line `line` (0-based) and brings it to the middle.
func go_to_line(line_index: int) -> void:
	if row_count() == 0:
		return
	var row: int = clampi(line_index, 0, row_count() - 1)
	_collapse(row)
	_anchor = row
	set_scroll_offset(row * row_height() - (size.y - row_height()) / 2.0)


## The gutter's width (for tests and screenshots).
func gutter_width() -> float:
	return _lead_width()


## What the gutter says of `row`: `[author, date]`; both "" until git
## reports the line, and no date for a line not committed yet.
func gutter_texts(row: int) -> PackedStringArray:
	var data: Dictionary = row_data(row)
	if String(data.get("commit", "")).is_empty():
		return PackedStringArray(["", ""])
	if bool(data.get("working", false)):
		return PackedStringArray([tr("Not committed yet"), ""])
	return PackedStringArray([
		String(data.get("author", "")),
		RelativeDate.text(int(data.get("time", 0)), _now, _utc_offset),
	])


func _lead_width() -> float:
	return roundf(_bar + _padding * 2.0 + _avatar + _gap + _widths.get(&"author", 0.0) + _gap
			+ _widths.get(&"date", 0.0))


func _lead_hot(row: int) -> bool:
	return not commit_at(row).is_empty()


func _lead_pressed(row: int, _mouse: InputEventMouseButton) -> void:
	var oid: String = commit_at(row)
	if oid.is_empty():
		return
	_collapse(row)
	_anchor = row
	commit_clicked.emit(oid, row)


func _line_tint(data: Dictionary) -> Color:
	return _blame_colors[&"focus_line_bg"] if bool(data.get("focus", false)) else Color(0, 0, 0, 0)


func _draw() -> void:
	_now = int(Time.get_unix_time_from_system())
	super()


func _draw_lead(index: int, data: Dictionary, rect: Rect2) -> void:
	draw_rect(rect, _colors[&"gutter_bg"])
	var oid: String = String(data.get("commit", ""))
	if oid.is_empty():
		return
	var working: bool = bool(data.get("working", false))
	if bool(data.get("focus", false)):
		draw_rect(rect, _blame_colors[&"focus_bg"])
	elif oid == _hover_commit:
		draw_rect(rect, _blame_colors[&"hover_bg"])
	var bar: Color = _blame_colors[&"working_color"] if working else _blame_colors[&"age_old_color"].lerp(
			_blame_colors[&"age_new_color"], clampf(float(data.get("age", 0.0)), 0.0, 1.0))
	draw_rect(Rect2(rect.position, Vector2(_bar, rect.size.y)), bar)
	var first: bool = bool(data.get("first", false))
	if first and index > 0:
		draw_rect(Rect2(rect.position.x + _bar, rect.position.y, rect.size.x - _bar, 1.0), _blame_colors[&"separator_color"])
	if not first and index != first_visible_row():
		return
	var x: float = rect.position.x + _bar + _padding
	var center: float = rect.position.y + rect.size.y * 0.5
	if working:
		_draw_gutter_text(&"author", tr("Not committed yet"), x, center, _blame_colors[&"working_text_color"],
				rect.end.x - _padding - x)
		return
	var author: String = String(data.get("author", ""))
	AvatarPainter.draw(self, self, Vector2(x + _avatar * 0.5, center), _avatar, author,
			String(data.get("email", "")), AppTheme.bold_font(), Color(0, 0, 0, 0), 1.5, 1.0,
			session)
	x += _avatar + _gap
	var author_width: float = _widths[&"author"]
	_draw_gutter_text(&"author", author, x, center, _blame_colors[&"author_color"], author_width)
	x += author_width + _gap
	var date: TextLine = _text(&"date", RelativeDate.text(int(data.get("time", 0)), _now, _utc_offset), _widths[&"date"])
	# Dates end at the gutter's edge.
	date.draw(get_canvas_item(), Vector2(rect.end.x - _padding - date.get_size().x,
			roundf(center - date.get_size().y * 0.5)), _blame_colors[&"meta_color"])


func _draw_gutter_text(column: StringName, text: String, x: float, center: float, color: Color, width: float) -> void:
	var shaped: TextLine = _text(column, text, width)
	shaped.draw(get_canvas_item(), Vector2(x, roundf(center - shaped.get_size().y * 0.5)), color)


## `text` shaped for `column`, cut with "…" at `width`.
func _text(column: StringName, text: String, width: float) -> TextLine:
	var key: String = "%s|%s" % [column, text]
	var shaped: TextLine = _texts.get(key)
	if shaped == null:
		if _texts.size() >= TEXT_CACHE:
			_texts.clear()
		shaped = TextLine.new()
		shaped.add_string(text, _ui_font, _meta_font_size)
		shaped.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_texts[key] = shaped
	shaped.width = maxf(0.0, width)
	return shaped


func _gui_input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode in [KEY_ENTER, KEY_KP_ENTER] \
			and cursor >= 0 and not commit_at(cursor).is_empty():
		commit_clicked.emit(commit_at(cursor), cursor)
		accept_event()
		return
	super(event)


func _on_mouse_motion(motion: InputEventMouseMotion) -> void:
	super(motion)
	var row: int = row_at(motion.position)
	_set_hover_commit(commit_at(row) if row >= 0 and motion.position.x < _lead_width() else "")


func _set_hover_commit(oid: String) -> void:
	if oid != _hover_commit:
		_hover_commit = oid
		queue_redraw()


## Over the gutter: the commit's subject, its author and exact date, and
## its short hash.
func _get_tooltip(at_position: Vector2) -> String:
	var row: int = row_at(at_position)
	if row < 0 or at_position.x >= _lead_width():
		return tooltip_text
	var data: Dictionary = row_data(row)
	if String(data.get("commit", "")).is_empty():
		return ""
	if bool(data.get("working", false)):
		return tr("Not committed yet")
	return "%s\n%s · %s\n%s" % [String(data.get("summary", "")), String(data.get("author", "")),
			RelativeDate.exact(int(data.get("time", 0)), _utc_offset), String(data["commit"]).left(7)]


func _update_theme() -> void:
	super()
	_texts.clear()
	_meta_font_size = get_theme_font_size(&"meta_font_size", BLAME_THEME_TYPE)
	_gap = float(get_theme_constant(&"gap", BLAME_THEME_TYPE))
	_bar = float(get_theme_constant(&"age_bar_width", BLAME_THEME_TYPE))
	_avatar = float(get_theme_constant(&"avatar_size", BLAME_THEME_TYPE))
	for column: StringName in [&"author", &"date"]:
		_widths[column] = float(get_theme_constant(StringName("%s_width" % column), BLAME_THEME_TYPE))
	for color_name: StringName in [&"author_color", &"meta_color", &"separator_color",
			&"focus_bg", &"focus_line_bg", &"hover_bg", &"age_old_color", &"age_new_color", &"working_color",
			&"working_text_color"]:
		_blame_colors[color_name] = get_theme_color(color_name, BLAME_THEME_TYPE)
	# The minimap marks the focused commit's lines in the focus colour.
	_minimap.color_overrides = {
		&"resolved_bg": get_theme_color(&"minimap_focus_bg", BLAME_THEME_TYPE),
		&"resolved_mark": get_theme_color(&"minimap_focus_mark", BLAME_THEME_TYPE),
	}
	_update_h_range()
