class_name CompareFileList
extends VirtualList
## The files that differ in a comparison (`RepoSession.compare_files()`,
## the ones its filter shows), fetched for a window around the visible rows.
## Each row is drawn like the other file lists (the line counts are in the
## list's header and the diff's).

## The row under the cursor changed (empty `path` when none).
signal current_changed(path: String)

const FETCH_MARGIN: int = 64

var session: RepoSession = null

var _count: int = 0
var _cache: Dictionary[int, Dictionary] = {}
var _painter: FileRowPainter = FileRowPainter.new()


func _ready() -> void:
	super()
	multi_select = false
	_update_theme()
	selection_changed.connect(func() -> void: current_changed.emit(path_at(cursor)))


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_update_theme()
		queue_redraw()


## Shows `count` files: the cursor stays on `keep_path` when it is among
## them (no selection otherwise). Emits `current_changed` either way.
func show_files(count: int, keep_path: String = "") -> void:
	_count = count
	_cache.clear()
	refresh()
	var kept: int = session.compare_file_index(keep_path) if session != null and not keep_path.is_empty() else -1
	if kept < 0:
		set_scroll_offset(0.0)
	select_only(kept)
	if kept >= 0:
		scroll_to_row(kept)


func row(index: int) -> Dictionary:
	if index < 0 or index >= _count or session == null:
		return {}
	if not _cache.has(index):
		_fetch(index, 1)
	return _cache.get(index, {})


func path_at(index: int) -> String:
	return String(row(index).get("path", ""))


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
	var rows: Array[Dictionary] = session.compare_files(start, count)
	for i: int in rows.size():
		_cache[start + i] = rows[i]


func _draw_row(index: int, rect: Rect2, _selected_row: bool) -> void:
	var data: Dictionary = _cache.get(index, {})
	if data.is_empty():
		return
	_painter.draw(self, rect, data)


func _get_tooltip(at_position: Vector2) -> String:
	var data: Dictionary = row(row_at(at_position))
	if data.is_empty():
		return ""
	var status: String = tr("Untracked") if bool(data.get("untracked", false)) \
			else FileRowPainter.code_name(String(data.get("code", "")))
	var lines: PackedStringArray = PackedStringArray([String(data["path"])])
	if not String(data.get("original_path", "")).is_empty():
		lines.append(tr("From %s") % String(data["original_path"]))
	if not status.is_empty():
		lines.append(status)
	if int(data.get("additions", -1)) < 0:
		lines.append(tr("Binary file"))
	return "\n".join(lines)


func _update_theme() -> void:
	_painter.update_theme(self)
