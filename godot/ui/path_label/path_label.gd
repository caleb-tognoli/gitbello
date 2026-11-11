class_name PathLabel
extends Control
## One path on one line, as the file lists write it: the folder muted, the
## file name in the text colour. When it is too narrow the folder is cut
## first (`src/compo…/file.rs`), then the name. Colours come from the
## `ChangeList` theme type.

const THEME_TYPE: StringName = &"ChangeList"

## The path, `/`-separated.
var path: String = "":
	set(value):
		if path == value:
			return
		path = value
		update_minimum_size()
		queue_redraw()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	size_flags_vertical = Control.SIZE_SHRINK_CENTER


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		update_minimum_size()
		queue_redraw()


func _get_minimum_size() -> Vector2:
	var font: Font = get_theme_font(&"font", &"Label")
	return Vector2(0.0, font.get_height(get_theme_font_size(&"font_size", &"Label")))


## The width the whole path takes.
func full_width() -> float:
	var font: Font = get_theme_font(&"font", &"Label")
	return font.get_string_size(path, HORIZONTAL_ALIGNMENT_LEFT, -1, get_theme_font_size(&"font_size", &"Label")).x


## Whether the path is drawn in full (not cut).
func fits() -> bool:
	return full_width() <= size.x


func _draw() -> void:
	if path.is_empty():
		return
	var font: Font = get_theme_font(&"font", &"Label")
	var font_size: int = get_theme_font_size(&"font_size", &"Label")
	var name_color: Color = get_theme_color(&"path_color", THEME_TYPE)
	var dir_color: Color = get_theme_color(&"dir_color", THEME_TYPE)
	var file: String = path.get_file()
	var folder: String = path.get_base_dir()
	var top: float = (size.y - font.get_height(font_size)) * 0.5
	var name_width: float = font.get_string_size(file, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var separator: float = font.get_string_size("/", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var ellipsis: float = font.get_string_size("…", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var folder_room: float = size.x - name_width - separator
	if folder.is_empty() or folder_room < ellipsis * 3.0:
		_line(file, font, font_size, size.x).draw(get_canvas_item(), Vector2(0.0, top), name_color)
		return
	var lead: TextLine = _line(folder, font, font_size, folder_room)
	lead.draw(get_canvas_item(), Vector2(0.0, top), dir_color)
	var x: float = minf(lead.get_line_width(), folder_room)
	_line("/", font, font_size, separator).draw(get_canvas_item(), Vector2(x, top), dir_color)
	_line(file, font, font_size, name_width).draw(get_canvas_item(), Vector2(x + separator, top), name_color)


func _line(text: String, font: Font, font_size: int, width: float) -> TextLine:
	var line: TextLine = TextLine.new()
	line.add_string(text, font, font_size)
	line.width = maxf(1.0, ceilf(width))
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return line
