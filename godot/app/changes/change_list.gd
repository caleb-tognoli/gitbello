class_name ChangeList
extends VirtualList
## The changed files of a worktree, one list with commit checkboxes (PLAN §4
## Changes view): conflicted files first, then the rest by path. Rows come
## from `RepoSession.change_rows()` for a window around the visible range only.
## Highlighting rows (click, Shift, Ctrl) drives the diff and the context menu;
## the checkboxes are separate: clicking one toggles its file, Space, Enter or
## a double-click toggles the highlighted files.

## The user toggled the checkboxes of `paths`.
signal pick_toggled(paths: PackedStringArray, include: bool)
## The row under the cursor changed (an empty path when none).
signal current_changed(path: String)

## Rows fetched beyond each edge of the visible range.
const FETCH_MARGIN: int = 64
## Larger selections are not carried over a reload (only the cursor is).
const MAX_KEPT_SELECTION: int = 500
var session: RepoSession = null

var _count: int = 0
var _cache: Dictionary[int, Dictionary] = {}
## Highlighted paths and cursor path, recorded when the user changes the
## highlight (while rows and status still agree).
var _kept_paths: PackedStringArray = PackedStringArray()
var _kept_cursor: String = ""
var _reloading: bool = false
var _painter: FileRowPainter = FileRowPainter.new()


func _ready() -> void:
	super()
	_painter.show_picks = true
	_update_theme()
	selection_changed.connect(_on_selection_changed)
	row_activated.connect(func(_row: int) -> void: toggle_selection())


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_update_theme()
		queue_redraw()


## Re-reads the rows after a status change, keeping the highlight on the same
## paths. When the cursor's file left the list, the row that took its place
## gets the cursor.
func reload() -> void:
	var kept: PackedStringArray = _kept_paths
	var cursor_path: String = _kept_cursor
	var old_cursor: int = cursor
	_reloading = true
	_cache.clear()
	_count = session.change_count() if session != null else 0
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


## Re-reads the checkboxes only (the selection changed, the files did not).
func reload_picks() -> void:
	_cache.clear()
	queue_redraw()


## `{path, original_path, code, pick, conflicted, as_staged}` of a row, or {}.
func row(index: int) -> Dictionary:
	if index < 0 or index >= row_count():
		return {}
	if not _cache.has(index):
		_fetch(index, 1)
	return _cache.get(index, {})


func path_at(index: int) -> String:
	return String(row(index).get("path", ""))


## Paths of `rows`, in row order.
func paths(rows: PackedInt32Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if rows.is_empty() or session == null:
		return out
	var sorted: PackedInt32Array = rows.duplicate()
	sorted.sort()
	# Selections are mostly contiguous: fetch their span in one call.
	var first: int = sorted[0]
	var span: PackedStringArray = session.change_paths(first, sorted[sorted.size() - 1] - first + 1)
	for index: int in sorted:
		if index - first < span.size():
			out.append(span[index - first])
	return out


## The highlighted rows, or the cursor row when none is.
func highlighted_rows() -> PackedInt32Array:
	var rows: PackedInt32Array = selected_rows()
	if rows.is_empty() and cursor >= 0:
		rows = PackedInt32Array([cursor])
	return rows


## Toggles the checkboxes of the highlighted rows: all included unless they
## all already are. Conflicted files are skipped.
func toggle_selection() -> void:
	toggle_rows(highlighted_rows())


func toggle_rows(rows: PackedInt32Array) -> void:
	var include: bool = false
	var picked: PackedInt32Array = PackedInt32Array()
	for index: int in rows:
		var data: Dictionary = row(index)
		if data.is_empty() or bool(data.get("conflicted", false)):
			continue
		picked.append(index)
		include = include or String(data.get("pick", "none")) != "all"
	if not picked.is_empty():
		pick_toggled.emit(paths(picked), include)


## Clears the highlight and the cursor.
func deselect() -> void:
	cursor = -1
	_anchor = -1
	clear_selection()


## Puts the cursor on the first row when there is none (keyboard entry point).
func ensure_cursor() -> void:
	if cursor < 0 and row_count() > 0:
		select_only(0)


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
	var rows: Array[Dictionary] = session.change_rows(start, count)
	for j: int in rows.size():
		_cache[start + j] = rows[j]


func _find(path: String) -> int:
	if path.is_empty() or session == null:
		return -1
	return session.change_index(path)


## A click on a checkbox toggles that file without moving the highlight.
func _gui_input(event: InputEvent) -> void:
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT and not mouse.double_click:
		var index: int = row_at(mouse.position)
		if index >= 0 and _painter.is_on_pick(Rect2(0.0, 0.0, content_width(), row_height()), mouse.position):
			grab_focus()
			toggle_rows(PackedInt32Array([index]))
			accept_event()
			return
	super(event)


func _draw_row(index: int, rect: Rect2, _selected_row: bool) -> void:
	_painter.draw(self, rect, _cache.get(index, {}))


func _get_tooltip(at_position: Vector2) -> String:
	var data: Dictionary = row(row_at(at_position))
	if data.is_empty():
		return ""
	var tip: String = String(data["path"])
	if bool(data.get("conflicted", false)):
		tip += "\nConflicted: resolve it before committing."
	elif not FileRowPainter.code_name(String(data.get("code", ""))).is_empty():
		tip += "\n" + FileRowPainter.code_name(String(data["code"]))
	elif bool(data.get("as_staged", false)):
		tip += "\nStaged in part outside gitbello: committed as staged."
	return tip


func _on_selection_changed() -> void:
	if _reloading:
		return
	_kept_cursor = path_at(cursor)
	_kept_paths = PackedStringArray()
	var rows: PackedInt32Array = selected_rows()
	if rows.size() <= MAX_KEPT_SELECTION:
		_kept_paths = paths(rows)
	current_changed.emit(_kept_cursor)


func _update_theme() -> void:
	_painter.update_theme(self)
