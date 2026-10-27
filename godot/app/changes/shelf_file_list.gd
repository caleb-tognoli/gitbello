class_name ShelfFileList
extends VirtualList
## The selected shelf's files, painted like the History file list.

signal current_changed(path: String)

var _files: Array[Dictionary] = []
var _painter: FileRowPainter = FileRowPainter.new()


func _ready() -> void:
	super()
	_painter.update_theme(self)
	selection_changed.connect(func() -> void: current_changed.emit(path_at(cursor)))


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_painter.update_theme(self)
		queue_redraw()


func show_files(files: Array[Dictionary], selected_path: String = "") -> void:
	_files = files
	refresh()
	var selected: int = -1
	for index: int in _files.size():
		if String(_files[index]["path"]) == selected_path:
			selected = index
	select_only(selected if selected >= 0 else (0 if not _files.is_empty() else -1))


func choose_path(path: String) -> bool:
	for index: int in _files.size():
		if String(_files[index]["path"]) == path:
			select_only(index)
			return true
	return false


func path_at(index: int) -> String:
	return String(_files[index]["path"]) if index >= 0 and index < _files.size() else ""


func _get_row_count() -> int:
	return _files.size()


func _draw_row(index: int, rect: Rect2, _selected_row: bool) -> void:
	_painter.draw(self, rect, _files[index])


func _get_tooltip(at: Vector2) -> String:
	return path_at(row_at(at))
