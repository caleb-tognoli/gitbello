class_name CommitFileList
extends VirtualList
## Files changed by the loaded commit, from `RepoSession.commit_files()`,
## fetched for a window around the visible rows.

## The row under the cursor changed (empty `path` when none).
signal current_changed(path: String)

const FETCH_MARGIN: int = 64

var session: RepoSession = null

var _count: int = 0
var _cache: Dictionary[int, Dictionary] = {}
var _painter: FileRowPainter = FileRowPainter.new()


func _ready() -> void:
	super()
	_painter.update_theme(self)
	selection_changed.connect(func() -> void: current_changed.emit(path_at(cursor)))


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_painter.update_theme(self)
		queue_redraw()


## Shows `count` files of the newly loaded commit (no selection).
func show_files(count: int) -> void:
	_count = count
	_cache.clear()
	clear_selection()
	cursor = -1
	set_scroll_offset(0.0)
	refresh()


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
	var rows: Array[Dictionary] = session.commit_files(start, count)
	for i: int in rows.size():
		_cache[start + i] = rows[i]


func _draw_row(index: int, rect: Rect2, _selected_row: bool) -> void:
	_painter.draw(self, rect, _cache.get(index, {}))


func _get_tooltip(at_position: Vector2) -> String:
	var data: Dictionary = row(row_at(at_position))
	if data.is_empty():
		return ""
	var status: String = FileRowPainter.code_name(String(data.get("code", "")))
	return String(data["path"]) if status.is_empty() else "%s\n%s" % [data["path"], status]
