class_name IgnoreHiddenList
extends VirtualList
## What one line of an ignore file decides, in the rules viewer (M7.7b): the
## tracked files it matches first (they stay tracked), then the untracked
## paths it hides, a folder whose contents are all ignored as one row. Rows
## come from `RepoSession.ignore_hidden()` for a window around the visible
## range only.

## Rows fetched beyond each edge of the visible range.
const FETCH_MARGIN: int = 64

var session: RepoSession = null
var _source: int = -1
var _line: int = -1
var _count: int = 0
var _cache: Dictionary[int, Dictionary] = {}
var _font: Font = null
var _font_size: int = 0
var _padding: float = 0.0
var _code_width: float = 0.0
var _icon_size: float = 0.0
var _path_color: Color = Color.WHITE
var _dir_color: Color = Color.WHITE
var _tracked_color: Color = Color.WHITE


func _ready() -> void:
	super()
	_update_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_update_theme()
		queue_redraw()


## Shows what line `line` (an index) of source `source` decides; -1 for none.
func show_line(source: int, line: int) -> void:
	_source = source
	_line = line
	reload()


## Re-reads the rows (the rules were reloaded).
func reload() -> void:
	_cache.clear()
	_count = session.ignore_hidden_count(_source, _line) if session != null and _line >= 0 else 0
	cursor = mini(cursor, _count - 1)
	clear_selection()
	refresh()
	queue_redraw()


## `{path, is_dir, tracked}` of a row, or {}.
func row(index: int) -> Dictionary:
	if index < 0 or index >= _count:
		return {}
	if not _cache.has(index):
		_fetch(index, 1)
	return _cache.get(index, {})


## The rows as shown, `path/` for folders and `(tracked) path` for tracked
## files (for tests).
func texts() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for index: int in _count:
		out.append(_text(row(index)))
	return out


func _get_row_count() -> int:
	return _count


func _prepare_rows(first: int, count: int) -> void:
	for index: int in range(first, first + count):
		if not _cache.has(index):
			var start: int = maxi(0, first - FETCH_MARGIN)
			_cache.clear()
			_fetch(start, first + count + FETCH_MARGIN - start)
			return


func _fetch(start: int, count: int) -> void:
	if session == null:
		return
	var rows: Array[Dictionary] = session.ignore_hidden(_source, _line, start, count)
	for j: int in rows.size():
		_cache[start + j] = rows[j]


static func _text(data: Dictionary) -> String:
	if data.is_empty():
		return ""
	var path: String = String(data["path"]) + ("/" if bool(data["is_dir"]) else "")
	return ("(%s) " % TranslationServer.translate("tracked") + path) if bool(data["tracked"]) else path


func _draw_row(index: int, rect: Rect2, _selected_row: bool) -> void:
	var data: Dictionary = _cache.get(index, {})
	if data.is_empty() or _font == null:
		return
	var tracked: bool = bool(data["tracked"])
	var is_dir: bool = bool(data["is_dir"])
	var x: float = rect.position.x + _padding
	var icon: Texture2D = AppTheme.icon(&"StatusWarning" if tracked else (&"Folder" if is_dir else &"TextFile"))
	if icon != null:
		var top: float = rect.position.y + (rect.size.y - _icon_size) / 2.0
		draw_texture_rect(icon, Rect2(x, top, _icon_size, _icon_size), false, _tracked_color if tracked else _dir_color)
	x += _code_width
	var path: String = String(data["path"]) + ("/" if is_dir else "")
	var dir: String = path.trim_suffix("/").get_base_dir()
	var lead: String = dir + "/" if not dir.is_empty() else ""
	var baseline: float = rect.position.y + (rect.size.y + _font.get_ascent(_font_size) - _font.get_descent(_font_size)) / 2.0
	var room: float = rect.end.x - _padding - x
	draw_string(_font, Vector2(x, baseline), lead, HORIZONTAL_ALIGNMENT_LEFT, room, _font_size, _dir_color)
	var lead_width: float = _font.get_string_size(lead, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x
	draw_string(_font, Vector2(x + lead_width, baseline), path.substr(lead.length()), HORIZONTAL_ALIGNMENT_LEFT,
			maxf(1.0, room - lead_width), _font_size, _tracked_color if tracked else _path_color)


func _get_tooltip(at_position: Vector2) -> String:
	var data: Dictionary = row(row_at(at_position))
	if data.is_empty():
		return ""
	var tip: String = String(data["path"]) + ("/" if bool(data["is_dir"]) else "")
	if bool(data["tracked"]):
		tip += "\n" + tr("Tracked: the rule matches it, but git keeps tracking it until you stop tracking it.")
	elif bool(data["is_dir"]):
		tip += "\n" + tr("Everything in this folder is ignored.")
	return tip


func _update_theme() -> void:
	_font = get_theme_font(&"font", &"Label")
	_font_size = get_theme_font_size(&"font_size", &"Label")
	_padding = float(get_theme_constant(&"padding", FileRowPainter.THEME_TYPE))
	_code_width = float(get_theme_constant(&"code_width", FileRowPainter.THEME_TYPE))
	_icon_size = float(get_theme_constant(&"icon_size", FileRowPainter.THEME_TYPE))
	_path_color = get_theme_color(&"path_color", FileRowPainter.THEME_TYPE)
	_dir_color = get_theme_color(&"dir_color", FileRowPainter.THEME_TYPE)
	_tracked_color = get_theme_color(&"tracked_color", IgnoreRulesDialog.THEME_TYPE)
