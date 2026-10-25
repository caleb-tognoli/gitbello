class_name FileRowPainter
extends RefCounted
## Draws one file row (`{path, original_path, code}`) the way every file
## list does: a colored status icon, the file name, then its folder dimmed.
## A renamed file reads `old.md → new.md`, a moved one's folder `{src → lib}`.
## With `show_picks`, a commit-selection checkbox comes first (from the row's
## `pick`; conflicted rows have none). Colors and sizes come from the
## `ChangeList` theme type.

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
## Status icon and name of each code.
const CODE_ICONS: Dictionary[String, StringName] = {
	"M": &"FileModified",
	"T": &"FileModified",
	"A": &"FileAdded",
	"D": &"FileDeleted",
	"R": &"FileRenamed",
	"C": &"FileRenamed",
	"?": &"FileAdded",
	"U": &"FileConflict",
}
const CODE_NAMES: Dictionary[String, String] = {
	"M": "Modified",
	"T": "Type changed",
	"A": "Added",
	"D": "Deleted",
	"R": "Renamed",
	"C": "Copied",
	"?": "Untracked",
	"U": "Conflicted",
}

var _font: Font = null
var _font_size: int = 0
var _padding: float = 0.0
var _code_width: float = 0.0
var _icon_size: float = 0.0
var _path_color: Color = Color.WHITE
var _dir_color: Color = Color.WHITE
var _code_colors: Dictionary[String, Color] = {}
## Draw the commit-selection checkbox before each row.
var show_picks: bool = false
var _picks: PickPainter = PickPainter.new()
var _renamed_dirs: Dictionary[String, String] = {}


## Reads the theme values from `control` (call again on theme changes).
func update_theme(control: Control) -> void:
	_font = control.get_theme_font(&"font", &"Label")
	_font_size = control.get_theme_font_size(&"font_size", &"Label")
	_padding = float(control.get_theme_constant(&"padding", THEME_TYPE))
	_code_width = float(control.get_theme_constant(&"code_width", THEME_TYPE))
	_icon_size = float(control.get_theme_constant(&"icon_size", THEME_TYPE))
	_path_color = control.get_theme_color(&"path_color", THEME_TYPE)
	_dir_color = control.get_theme_color(&"dir_color", THEME_TYPE)
	_picks.update_theme(control)
	_code_colors.clear()
	for code: String in CODE_COLORS:
		_code_colors[code] = control.get_theme_color(CODE_COLORS[code], THEME_TYPE)


func draw(canvas: CanvasItem, rect: Rect2, data: Dictionary) -> void:
	if data.is_empty() or _font == null:
		return
	var baseline: float = rect.position.y + (rect.size.y + _font.get_ascent(_font_size) - _font.get_descent(_font_size)) / 2.0
	var x: float = rect.position.x + _padding
	if show_picks:
		if not bool(data.get("conflicted", false)):
			_picks.draw(canvas, _picks.box_rect(rect, x), String(data.get("pick", "none")))
		x += pick_width()
	var code: String = String(data.get("code", ""))
	var icon: Texture2D = code_icon(code)
	if icon != null:
		var top: float = rect.position.y + (rect.size.y - _icon_size) / 2.0
		canvas.draw_texture_rect(icon, Rect2(x, top, _icon_size, _icon_size), false,
				_code_colors.get(code, _dir_color))
	x += _code_width
	var path: String = String(data["path"])
	var file: String = path.get_file()
	var dir: String = path.get_base_dir()
	var original: String = String(data.get("original_path", ""))
	var right: float = rect.end.x - _padding
	if not original.is_empty() and original != path:
		# Renamed: `old.md → new.md`, the old name dimmed; a changed folder
		# reads `src/{a → b}` (see `rename_dir`).
		if original.get_file() != file:
			var old_name: String = "%s → " % original.get_file()
			canvas.draw_string(_font, Vector2(x, baseline), old_name, HORIZONTAL_ALIGNMENT_LEFT,
					maxf(1.0, right - x), _font_size, _dir_color)
			x += _font.get_string_size(old_name, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x
		if original.get_base_dir() != dir:
			dir = rename_dir(original.get_base_dir(), dir)
	if x < right:
		canvas.draw_string(_font, Vector2(x, baseline), file, HORIZONTAL_ALIGNMENT_LEFT, maxf(1.0, right - x),
				_font_size, _path_color)
	x += _font.get_string_size(file, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x + _padding
	if not dir.is_empty() and x < right:
		canvas.draw_string(_font, Vector2(x, baseline), dir, HORIZONTAL_ALIGNMENT_LEFT, right - x,
				_font_size, _dir_color)


## A folder that changed in a rename, `prefix{old → new}suffix` (cached:
## rows are drawn every frame).
func rename_dir(old_dir: String, new_dir: String) -> String:
	var key: String = old_dir + "\n" + new_dir
	if not _renamed_dirs.has(key):
		if _renamed_dirs.size() > 256:
			_renamed_dirs.clear()
		var parts: PackedStringArray = Core.rename_parts(old_dir, new_dir)
		_renamed_dirs[key] = "%s{%s → %s}%s" % [parts[0], parts[1], parts[2], parts[3]]
	return _renamed_dirs[key]


## The status icon of `code` (white, to tint with `code_color`), or null.
static func code_icon(code: String) -> Texture2D:
	return AppTheme.icon(CODE_ICONS[code]) if CODE_ICONS.has(code) else null


## The colour of `code`'s icon in `control`'s theme.
static func code_color(control: Control, code: String) -> Color:
	return control.get_theme_color(CODE_COLORS.get(code, &"dir_color"), THEME_TYPE)


## "Added", "Modified", ... for `code`.
static func code_name(code: String) -> String:
	return CODE_NAMES.get(code, "")


## Width the checkbox takes (with its gap), when shown.
func pick_width() -> float:
	return _picks.size + _padding if show_picks else 0.0


## Whether `at` (in the row's coordinates) is on the checkbox of a row drawn in `rect`.
func is_on_pick(rect: Rect2, at: Vector2) -> bool:
	return show_picks and at.x >= rect.position.x and at.x < rect.position.x + _padding + pick_width()
