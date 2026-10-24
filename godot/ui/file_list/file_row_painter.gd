class_name FileRowPainter
extends RefCounted
## Draws one file row (`{path, original_path, code}`) the way every file
## list does: a colored status letter, the file name, then its folder dimmed.
## Colors and sizes come from the `ChangeList` theme type.

const THEME_TYPE: StringName = &"ChangeList"
const CODE_COLORS: Dictionary[String, StringName] = {
	"M": &"modified_color",
	"T": &"modified_color",
	"A": &"added_color",
	"D": &"deleted_color",
	"R": &"renamed_color",
	"C": &"renamed_color",
	"?": &"untracked_color",
	"U": &"conflict_color",
}

var _font: Font = null
var _font_size: int = 0
var _padding: float = 0.0
var _code_width: float = 0.0
var _path_color: Color = Color.WHITE
var _dir_color: Color = Color.WHITE
var _code_colors: Dictionary[String, Color] = {}


## Reads the theme values from `control` (call again on theme changes).
func update_theme(control: Control) -> void:
	_font = control.get_theme_font(&"font", &"Label")
	_font_size = control.get_theme_font_size(&"font_size", &"Label")
	_padding = float(control.get_theme_constant(&"padding", THEME_TYPE))
	_code_width = float(control.get_theme_constant(&"code_width", THEME_TYPE))
	_path_color = control.get_theme_color(&"path_color", THEME_TYPE)
	_dir_color = control.get_theme_color(&"dir_color", THEME_TYPE)
	_code_colors.clear()
	for code: String in CODE_COLORS:
		_code_colors[code] = control.get_theme_color(CODE_COLORS[code], THEME_TYPE)


func draw(canvas: CanvasItem, rect: Rect2, data: Dictionary) -> void:
	if data.is_empty() or _font == null:
		return
	var baseline: float = rect.position.y + (rect.size.y + _font.get_ascent(_font_size) - _font.get_descent(_font_size)) / 2.0
	var x: float = rect.position.x + _padding
	var code: String = String(data.get("code", ""))
	canvas.draw_string(_font, Vector2(x, baseline), code, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size,
			_code_colors.get(code, _dir_color))
	x += _code_width
	var path: String = String(data["path"])
	var file: String = path.get_file()
	var original: String = String(data.get("original_path", ""))
	if not original.is_empty():
		file = "%s ← %s" % [file, original.get_file()]
	var right: float = rect.end.x - _padding
	canvas.draw_string(_font, Vector2(x, baseline), file, HORIZONTAL_ALIGNMENT_LEFT, maxf(1.0, right - x),
			_font_size, _path_color)
	x += _font.get_string_size(file, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x + _padding
	var dir: String = path.get_base_dir()
	if not dir.is_empty() and x < right:
		canvas.draw_string(_font, Vector2(x, baseline), dir, HORIZONTAL_ALIGNMENT_LEFT, right - x,
				_font_size, _dir_color)
