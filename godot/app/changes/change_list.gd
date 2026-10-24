class_name ChangeList
extends VirtualList
## Files of one or more change lists (`conflicted`, `unstaged`, `staged`,
## `untracked`), shown in that order. Rows come from
## `RepoSession.change_rows()` for a window around the visible range only.
## Activating rows (Enter, Space, double-click) asks to stage or unstage them.

## The user activated rows: `{group: PackedStringArray of paths}`.
signal stage_requested(paths_by_group: Dictionary)
## The row under the cursor changed (empty strings when none).
signal current_changed(group: String, path: String)

## Rows fetched beyond each edge of the visible range.
const FETCH_MARGIN: int = 64
## Larger selections are not carried over a reload (only the cursor is).
const MAX_KEPT_SELECTION: int = 500
var session: RepoSession = null
## Group ids shown, in order.
var groups: PackedStringArray = PackedStringArray()

## Rows per group, in `groups` order (as of the last reload).
var _counts: PackedInt32Array = PackedInt32Array()
var _cache: Dictionary[int, Dictionary] = {}
## Selected paths and cursor path, recorded when the user changes the
## selection (while rows and status still agree).
var _kept_paths: PackedStringArray = PackedStringArray()
var _kept_cursor: String = ""
var _reloading: bool = false
var _painter: FileRowPainter = FileRowPainter.new()


func _ready() -> void:
	super()
	_update_theme()
	selection_changed.connect(_on_selection_changed)
	row_activated.connect(func(_row: int) -> void: activate_selection())


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_update_theme()
		queue_redraw()


## Re-reads the lists after a status change, keeping the selection on the
## same paths. When the cursor's file left the list, the row that took its
## place gets the cursor, so Enter can be pressed repeatedly.
func reload() -> void:
	var kept: PackedStringArray = _kept_paths
	var cursor_path: String = _kept_cursor
	var old_cursor: int = cursor
	_reloading = true
	_cache.clear()
	_counts.resize(groups.size())
	for i: int in groups.size():
		_counts[i] = session.change_count(groups[i]) if session != null else 0
	refresh()
	_selected.clear()
	var new_cursor: int = _find(cursor_path)
	for path: String in kept:
		var index: int = _find(path)
		if index >= 0:
			_selected[index] = true
	if new_cursor < 0 and old_cursor >= 0 and row_count() > 0:
		new_cursor = mini(old_cursor, row_count() - 1)
		_selected[new_cursor] = true
	cursor = new_cursor
	_anchor = new_cursor
	if cursor >= 0:
		scroll_to_row(cursor)
	queue_redraw()
	_reloading = false
	selection_changed.emit()


## `{path, original_path, code, group}` of a row, or {}.
func row(index: int) -> Dictionary:
	if index < 0 or index >= row_count():
		return {}
	if not _cache.has(index):
		_fetch(index, 1)
	return _cache.get(index, {})


func path_at(index: int) -> String:
	return String(row(index).get("path", ""))


## Paths of `rows` grouped by list: `{group: PackedStringArray}`.
func paths_by_group(rows: PackedInt32Array) -> Dictionary:
	var out: Dictionary = {}
	if rows.is_empty():
		return out
	# Selections are mostly contiguous: fetch each group's span in one call.
	var start: int = 0
	for i: int in groups.size():
		var end: int = start + _counts[i]
		var first: int = -1
		var last: int = -1
		for index: int in rows:
			if index >= start and index < end:
				first = index if first < 0 else mini(first, index)
				last = maxi(last, index)
		if first >= 0:
			var span: PackedStringArray = session.change_paths(groups[i], first - start, last - first + 1)
			var picked: PackedStringArray = PackedStringArray()
			for index: int in rows:
				if index >= first and index <= last and index - first < span.size():
					picked.append(span[index - first])
			out[groups[i]] = picked
		start = end
	return out


## Asks to stage or unstage the selected rows (or the cursor row).
func activate_selection() -> void:
	var rows: PackedInt32Array = selected_rows()
	if rows.is_empty() and cursor >= 0:
		rows = PackedInt32Array([cursor])
	var paths: Dictionary = paths_by_group(rows)
	if not paths.is_empty():
		stage_requested.emit(paths)


## Clears the selection and the cursor (another list took the selection).
func deselect() -> void:
	cursor = -1
	_anchor = -1
	clear_selection()


## Puts the cursor on the first row when there is none (keyboard entry point).
func ensure_cursor() -> void:
	if cursor < 0 and row_count() > 0:
		select_only(0)


func _get_row_count() -> int:
	var total: int = 0
	for count: int in _counts:
		total += count
	return total


func _prepare_rows(first: int, count: int) -> void:
	for index: int in range(first, first + count):
		if not _cache.has(index):
			var start: int = maxi(0, first - FETCH_MARGIN)
			_cache.clear()
			_fetch(start, first + count + FETCH_MARGIN - start)
			return


## Caches rows `start..start + count`, one `change_rows` call per group.
func _fetch(start: int, count: int) -> void:
	var group_start: int = 0
	for i: int in groups.size():
		var group_end: int = group_start + _counts[i]
		var from: int = maxi(start, group_start)
		var to: int = mini(start + count, group_end)
		if from < to:
			var rows: Array[Dictionary] = session.change_rows(groups[i], from - group_start, to - from)
			for j: int in rows.size():
				_cache[from + j] = rows[j]
		group_start = group_end


func _find(path: String) -> int:
	if path.is_empty() or session == null:
		return -1
	var start: int = 0
	for i: int in groups.size():
		var index: int = session.change_index(groups[i], path)
		if index >= 0:
			return start + index
		start += _counts[i]
	return -1


func _draw_row(index: int, rect: Rect2, _selected_row: bool) -> void:
	_painter.draw(self, rect, _cache.get(index, {}))


func _get_tooltip(at_position: Vector2) -> String:
	return path_at(row_at(at_position))


func _on_selection_changed() -> void:
	if _reloading:
		return
	_kept_cursor = path_at(cursor)
	_kept_paths = PackedStringArray()
	var rows: PackedInt32Array = selected_rows()
	if rows.size() <= MAX_KEPT_SELECTION:
		for paths: PackedStringArray in paths_by_group(rows).values():
			_kept_paths.append_array(paths)
	var data: Dictionary = row(cursor)
	current_changed.emit(String(data.get("group", "")), String(data.get("path", "")))


func _update_theme() -> void:
	_painter.update_theme(self)
