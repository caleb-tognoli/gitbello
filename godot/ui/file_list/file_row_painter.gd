class_name FileRowPainter
extends RefCounted
## Draws one file row (`{path, original_path, code}`) the way every file
## list does, like GitHub Desktop: a colored status icon, then the full path
## with everything but the file name muted. When the row is too narrow the
## folder is cut first, so the file name stays visible as long as it can.
## With `show_picks`, a commit-selection checkbox comes first (from the row's
## `pick`), dimmed where it cannot be changed: a conflicted file (empty) or a
## `locked` row. A `resolved` file shows a tick instead of its status icon.
## During amend, files already in the original commit also have a commit icon.
## A file whose only changes are line endings (`endings_only`) ends with an
## `EOL` chip.
## An `ignored` row ("Show ignored files") is drawn muted, with no checkbox.
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
	"!": &"ignored_color",
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
	"!": &"GitIgnore",
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
	"!": "Ignored",
}

var _font: Font = null
var _font_size: int = 0
var _padding: float = 0.0
var _code_width: float = 0.0
var _icon_size: float = 0.0
var _path_color: Color = Color.WHITE
var _dir_color: Color = Color.WHITE
var _code_colors: Dictionary[String, Color] = {}
var _resolved_color: Color = Color.WHITE
var _chip_color: Color = Color.WHITE
var _chip_font_size: int = 0
var _chip_box: StyleBoxFlat = StyleBoxFlat.new()
var _ignored_color: Color = Color.WHITE
## Draw the commit-selection checkbox before each row.
var show_picks: bool = false
var _picks: PickPainter = PickPainter.new()


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
	_resolved_color = control.get_theme_color(&"resolved_color", THEME_TYPE)
	_chip_color = control.get_theme_color(&"chip_color", THEME_TYPE)
	_chip_font_size = control.get_theme_font_size(&"chip_font_size", THEME_TYPE)
	_chip_box.bg_color = control.get_theme_color(&"chip_bg", THEME_TYPE)
	_chip_box.set_corner_radius_all(control.get_theme_constant(&"chip_radius", THEME_TYPE))
	_ignored_color = control.get_theme_color(&"ignored_color", THEME_TYPE)
	_code_colors.clear()
	for code: String in CODE_COLORS:
		_code_colors[code] = control.get_theme_color(CODE_COLORS[code], THEME_TYPE)


func draw(canvas: CanvasItem, rect: Rect2, data: Dictionary) -> void:
	if data.is_empty() or _font == null:
		return
	var baseline: float = rect.position.y + (rect.size.y + _font.get_ascent(_font_size) - _font.get_descent(_font_size)) / 2.0
	var x: float = rect.position.x + _padding
	var ignored: bool = bool(data.get("ignored", false))
	if show_picks:
		var conflicted: bool = bool(data.get("conflicted", false))
		if not ignored:
			_picks.draw(canvas, _picks.box_rect(rect, x), "none" if conflicted else String(data.get("pick", "none")),
					conflicted or bool(data.get("locked", false)))
		x += pick_width()
	var code: String = String(data.get("code", ""))
	var resolved: bool = bool(data.get("resolved", false))
	var icon: Texture2D = AppTheme.icon(&"StatusSuccess") if resolved else code_icon(code)
	if icon != null:
		var top: float = rect.position.y + (rect.size.y - _icon_size) / 2.0
		canvas.draw_texture_rect(icon, Rect2(x, top, _icon_size, _icon_size), false,
				_resolved_color if resolved else _code_colors.get(code, _dir_color))
	x += _code_width
	var path: String = String(data["path"]) + ("/" if bool(data.get("ignored_dir", false)) else "")
	var name: String = path.trim_suffix("/").get_file() + ("/" if path.ends_with("/") else "")
	var lead: PackedStringArray = path_lead(path, String(data.get("original_path", "")))
	var room: float = rect.end.x - _padding - x
	var right: float = rect.end.x - _padding
	if bool(data.get("amending", false)) and bool(data.get("in_original_commit", false)):
		var commit_icon: Texture2D = AppTheme.icon(&"GitCommit")
		if commit_icon != null:
			room -= _icon_size + _padding
			right -= _icon_size + _padding
			canvas.draw_texture_rect(commit_icon, Rect2(rect.end.x - _padding - _icon_size,
					rect.position.y + (rect.size.y - _icon_size) / 2.0, _icon_size, _icon_size), false, _dir_color)
	if bool(data.get("endings_only", false)):
		room -= _draw_chip(canvas, "EOL", right, rect) + _padding
	var name_color: Color = _ignored_color if ignored else _path_color
	var name_width: float = _text_width(name)
	var lead_width: float = _text_width(lead[0] + lead[1])
	var text_top: float = rect.position.y + (rect.size.y - _font.get_height(_font_size)) / 2.0
	var canvas_item: RID = canvas.get_canvas_item()
	if lead_width + name_width <= room:
		canvas.draw_string(_font, Vector2(x, baseline), lead[0] + lead[1], HORIZONTAL_ALIGNMENT_LEFT, -1,
				_font_size, _dir_color)
		canvas.draw_string(_font, Vector2(x + lead_width, baseline), name, HORIZONTAL_ALIGNMENT_LEFT, -1,
				_font_size, name_color)
		return
	# Too narrow: the folder gives way first (`src/compo…/file.rs`), then the name.
	var separator_width: float = _text_width(lead[1])
	var folder_room: float = room - name_width - separator_width
	if lead[0].is_empty() or folder_room < _text_width("…") * 3.0:
		_trimmed(name, room).draw(canvas_item, Vector2(x, text_top), name_color)
		return
	var folder: TextLine = _trimmed(lead[0], folder_room)
	folder.draw(canvas_item, Vector2(x, text_top), _dir_color)
	x += minf(folder.get_line_width(), folder_room)
	canvas.draw_string(_font, Vector2(x, baseline), lead[1], HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, _dir_color)
	canvas.draw_string(_font, Vector2(x + separator_width, baseline), name, HORIZONTAL_ALIGNMENT_LEFT, -1,
			_font_size, name_color)


## Draws `text` in a small chip ending at `right`, centred in `rect`;
## returns its width.
func _draw_chip(canvas: CanvasItem, text: String, right: float, rect: Rect2) -> float:
	var text_size: Vector2 = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _chip_font_size)
	var inset: float = roundf(_padding / 2.0)
	var chip: Rect2 = Rect2(right - text_size.x - inset * 2.0, roundf(rect.get_center().y - text_size.y / 2.0),
			text_size.x + inset * 2.0, text_size.y)
	canvas.draw_style_box(_chip_box, chip)
	var baseline: float = chip.position.y + (chip.size.y + _font.get_ascent(_chip_font_size) - _font.get_descent(_chip_font_size)) / 2.0
	canvas.draw_string(_font, Vector2(chip.position.x + inset, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			_chip_font_size, _chip_color)
	return chip.size.x


## What goes before a row's file name, muted: `[folder, separator]`, such as
## `["src/ui", "/"]`. A file renamed in its folder reads `docs/old.md → new.md`;
## a moved one shows only its new path (the tooltip and the diff header say
## where it came from).
static func path_lead(path: String, original: String) -> PackedStringArray:
	var dir: String = path.trim_suffix("/").get_base_dir()
	if original.is_empty() or original == path or original.get_base_dir() != dir:
		return PackedStringArray([dir, "/" if not dir.is_empty() else ""])
	return PackedStringArray([original, " → "])


## The tooltip line of a renamed or copied row (`original_path`, `code` and
## an optional `similarity`): "Renamed from src/util.rs · 92% similar", or "".
static func rename_tip(data: Dictionary) -> String:
	var original: String = String(data.get("original_path", ""))
	if original.is_empty() or original == String(data.get("path", "")):
		return ""
	var tip: String = TranslationServer.translate(&"Copied from %s" if String(data.get("code", "")) == "C"
			else &"Renamed from %s") % original
	var similarity: int = int(data.get("similarity", -1))
	if similarity >= 0:
		tip += TranslationServer.translate(&" · %d%% similar") % similarity
	return tip


## `text` cut from the left to fit `room` (`…ore/util.rs`), keeping at least
## its last `keep` characters (or "" when `keep` is 0 and nothing fits);
## `measure` gives a string's width.
static func left_trimmed(text: String, room: float, keep: int, measure: Callable) -> String:
	if float(measure.call(text)) <= room:
		return text
	for start: int in range(1, text.length() - keep):
		var cut: String = "…" + text.substr(start)
		if float(measure.call(cut)) <= room:
			return cut
	return "…" + text.right(keep) if keep > 0 else ""


## The diff header's path in `room`: `[muted lead, file name]`. A rename or
## copy shows both full paths, `src/util.rs → lib/core/` before `util.rs`.
## When too wide the old path's folders give way first (`…/util.rs → lib/`),
## then the new path's folders (`…/util.rs → util.rs`), then the old name
## (`… → util.rs`); the new name stays whole.
static func header_path(path: String, original: String, room: float, measure: Callable) -> PackedStringArray:
	var name: String = path.get_file()
	var dir: String = path.get_base_dir()
	var new_lead: String = dir + "/" if not dir.is_empty() else ""
	var old: String = "" if original.is_empty() or original == path else original
	var arrow: String = " → " if not old.is_empty() else ""
	var width: Callable = func(lead: String) -> float: return float(measure.call(lead + name))
	if room <= 0.0 or float(width.call(old + arrow + new_lead)) <= room:
		return PackedStringArray([old + arrow + new_lead, name])
	var old_cut: String = old
	if not old.is_empty():
		var keep: int = mini(original.get_file().length() + 1, old.length())
		old_cut = left_trimmed(old, room - float(width.call(arrow + new_lead)), keep, measure)
		if old_cut.length() > old.length():
			old_cut = old
	var new_cut: String = left_trimmed(new_lead, room - float(width.call(old_cut + arrow)), 0, measure)
	if float(width.call(old_cut + arrow + new_cut)) <= room:
		return PackedStringArray([old_cut + arrow + new_cut, name])
	if not old.is_empty() and float(width.call("…" + arrow)) <= room:
		return PackedStringArray(["…" + arrow, name])
	return PackedStringArray(["", name])


func _text_width(text: String) -> float:
	return _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x


## `text` on one line of `width`, cut with an ellipsis when it doesn't fit.
func _trimmed(text: String, width: float) -> TextLine:
	var line: TextLine = TextLine.new()
	line.add_string(text, _font, _font_size)
	line.width = maxf(1.0, width)
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return line


## The status icon of `code` (white, to tint with `code_color`), or null.
static func code_icon(code: String) -> Texture2D:
	return AppTheme.icon(CODE_ICONS[code]) if CODE_ICONS.has(code) else null


## The colour of `code`'s icon in `control`'s theme.
static func code_color(control: Control, code: String) -> Color:
	return control.get_theme_color(CODE_COLORS.get(code, &"dir_color"), THEME_TYPE)


## The muted colour of a path's folder in `control`'s theme.
static func dir_color(control: Control) -> Color:
	return control.get_theme_color(&"dir_color", THEME_TYPE)


## "Added", "Modified", ... for `code`.
static func code_name(code: String) -> String:
	return TranslationServer.translate(CODE_NAMES.get(code, ""))


## Width the checkbox takes (with its gap), when shown.
func pick_width() -> float:
	return _picks.size + _padding if show_picks else 0.0


## Whether `at` (in the row's coordinates) is on the checkbox of a row drawn in `rect`.
func is_on_pick(rect: Rect2, at: Vector2) -> bool:
	return show_picks and at.x >= rect.position.x and at.x < rect.position.x + _padding + pick_width()
