class_name DiffPanel
extends VBoxContainer
## A file diff with its header (status icon, path, notes, +/− counts,
## unified or side by side) and the messages shown instead of lines
## (loading, binary, too large, no changes, errors). A renamed or copied
## file's path reads `docs/{old.md → new.md}`, the old part dimmed. Callers pass `RepoSession.diff_info()`-style
## dictionaries to `show_info`. Every panel is in the `diff_panels` group so
## the layout can change everywhere at once.

const GROUP: StringName = &"diff_panels"
## What an empty diff says, by status code.
const EMPTY_MESSAGES: Dictionary[String, String] = {
	"A": "New empty file.",
	"D": "Deleted an empty file.",
	"R": "Renamed without changes.",
	"C": "Copied without changes.",
}

## The user asked to load a diff past the size limit.
signal load_full_requested()

@onready var _status_icon: TextureRect = %StatusIcon
@onready var _path: RichTextLabel = %DiffPath
@onready var _stats: Label = %DiffStats
@onready var _counts: Control = %Counts
@onready var _added: Label = %DiffAdded
@onready var _removed: Label = %DiffRemoved
@onready var _layout_gap: Control = %LayoutGap
@onready var _view: DiffView = %DiffView
@onready var _message: Control = %DiffMessage
@onready var _message_label: Label = %DiffMessageLabel
@onready var _load_anyway: Button = %LoadAnywayButton
@onready var _unified_button: Button = %UnifiedButton
@onready var _split_button: Button = %SplitButton

## `kind:path` of the diff shown, to keep the scroll position on reloads.
var _shown: String = ""
var _placeholder: String = ""
## Status code of the diff shown ("A", "M", ...), or "".
var _code: String = ""
## `[path, original_path, similarity]` of the header, redrawn on theme changes.
var _path_shown: Array = ["", "", -1]


func _ready() -> void:
	add_to_group(GROUP)
	_load_anyway.pressed.connect(func() -> void: load_full_requested.emit())
	var group: ButtonGroup = ButtonGroup.new()
	var shortcut: String = Actions.shortcut_label(&"diff.toggle_side_by_side")
	for entry: Array in [[_unified_button, &"Panels1", false, "Unified", "Old and new lines in one column"],
			[_split_button, &"Panels2Alt", true, "Side by side", "Old lines on the left, new lines on the right"]]:
		var button: Button = entry[0]
		button.icon = AppTheme.icon(entry[1])
		button.button_group = group
		var tip: String = "%s\n%s" % [String(entry[3]), String(entry[4])]
		button.tooltip_text = tip if shortcut.is_empty() else "%s\n%s switches" % [tip, shortcut]
		button.pressed.connect(func() -> void:
			if bool(entry[2]) != _view.side_by_side:
				Actions.run_action(&"diff.toggle_side_by_side"))
	set_side_by_side(Core.diff_side_by_side())
	_apply_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()


func view() -> DiffView:
	return _view


## The Unified or the Side by side button.
func layout_button(side_by_side: bool) -> Button:
	return _split_button if side_by_side else _unified_button


## Where lines come from: `func(start, count) -> Array` (see DiffView).
func set_source(source: Callable) -> void:
	_view.source = source


## Where side-by-side rows come from (see DiffView).
func set_split_source(source: Callable) -> void:
	_view.split_source = source


func set_side_by_side(value: bool) -> void:
	_view.side_by_side = value
	_unified_button.set_pressed_no_signal(not value)
	_split_button.set_pressed_no_signal(value)


## Clears the diff and shows `placeholder` (also used by later `clear()` calls).
func clear(placeholder: String = "") -> void:
	if not placeholder.is_empty():
		_placeholder = placeholder
	_shown = ""
	_view.show_lines(0, 0, false)
	_show_code("")
	_show_path("", "", -1)
	_stats.text = ""
	show_counts(_added, _removed, 0, 0)
	show_message(_placeholder)


## Shows a diff described by `info` (`state`, `path`, `kind`, `content`,
## `code`, `original_path`, `similarity`, `notes`, `additions`, `deletions`,
## `line_count`, `max_line`, sizes, `error`).
func show_info(info: Dictionary) -> void:
	var state: String = String(info.get("state", "none"))
	if state == "none":
		clear()
		return
	var path: String = String(info["path"])
	var key: String = String(info["kind"]) + ":" + path
	var code: String = String(info.get("code", ""))
	_show_code(code)
	_show_path(path, String(info.get("original_path", "")), int(info.get("similarity", -1)))
	var notes: PackedStringArray = info.get("notes", PackedStringArray())
	_stats.text = "  ·  ".join(notes)
	show_counts(_added, _removed, int(info.get("additions", 0)), int(info.get("deletions", 0)))
	match state:
		"loading":
			if key != _shown:
				_view.show_lines(0, 0, false)
				show_message("Loading…")
			return
		"error":
			var error: Dictionary = info.get("error", {})
			_view.show_lines(0, 0, false)
			show_message("Cannot show this diff.\n%s" % String(error.get("message", error.get("title", ""))))
			_shown = ""
			return
	var keep: bool = key == _shown
	_shown = key
	match String(info.get("content", "text")):
		"text", "combined":
			_message.hide()
			_view.show_lines(int(info["line_count"]), int(info["max_line"]), keep,
					int(info.get("split_count", info["line_count"])))
		"binary":
			_view.show_lines(0, 0, false)
			show_message("Binary file: %s → %s" % [
				_size_text(int(info["old_size"])), _size_text(int(info["new_size"]))])
		"too_large":
			_view.show_lines(0, 0, false)
			show_message("This diff is large (more than %s)." % _size_text(int(info["bytes"])), true)
		"empty":
			_view.show_lines(0, 0, false)
			show_message("\n".join(notes) if not notes.is_empty() else EMPTY_MESSAGES.get(code, "No changes to show."))


func show_message(text: String, offer_full: bool = false) -> void:
	_message_label.text = text
	_load_anyway.visible = offer_full
	_message.show()


func message_text() -> String:
	return _message_label.text if _message.visible else ""


## The status icon of `code` ("A", "M", ...), tinted like the file lists'.
func _show_code(code: String) -> void:
	_code = code
	_status_icon.texture = FileRowPainter.code_icon(code)
	_status_icon.visible = _status_icon.texture != null
	_status_icon.self_modulate = FileRowPainter.code_color(self, code)
	_status_icon.tooltip_text = FileRowPainter.code_name(code)


## Status code of the diff shown ("A", "M", ...), or "".
func status_code() -> String:
	return _code


## `+12` and `−3` in `added` and `removed` (hidden while both are zero).
static func show_counts(added: Label, removed: Label, additions: int, deletions: int) -> void:
	added.text = "+%d" % additions
	removed.text = "−%d" % deletions
	added.get_parent().visible = additions > 0 or deletions > 0


## The `+` and `−` counts shown, as `+12 −3`, or "".
func counts_text() -> String:
	return "%s %s" % [_added.text, _removed.text] if _counts.visible else ""


## The header's path as shown, such as `docs/{a.md → b.md}`.
func path_text() -> String:
	return _path.get_parsed_text()


## `path`, or for a rename or copy `prefix{old → new}suffix` with the old
## part dimmed (`old → new` when the paths share nothing); the tooltip says
## where it came from and how similar it is.
func _show_path(path: String, original: String, similarity: int) -> void:
	_path_shown = [path, original, similarity]
	_path.clear()
	_path.tooltip_text = path
	if original.is_empty() or original == path:
		_path.add_text(path)
		return
	var parts: PackedStringArray = Core.rename_parts(original, path)
	var braces: bool = not parts[0].is_empty() or not parts[3].is_empty()
	var dim: Color = get_theme_color(&"font_color", &"DimLabel")
	_path.add_text(parts[0])
	_path.push_color(dim)
	_path.add_text("%s%s → " % ["{" if braces else "", parts[1]])
	_path.pop()
	_path.add_text(parts[2])
	_path.push_color(dim)
	_path.add_text("}" if braces else "")
	_path.pop()
	_path.add_text(parts[3])
	_path.tooltip_text = "%s from %s" % ["Copied" if _code == "C" else "Renamed", original]
	if similarity >= 0:
		_path.tooltip_text += " · %d%% similar" % similarity


func _apply_theme() -> void:
	var icon_size: float = float(get_theme_constant(&"icon_size", FileRowPainter.THEME_TYPE))
	_status_icon.custom_minimum_size = Vector2(icon_size, icon_size)
	_layout_gap.custom_minimum_size.x = float(get_theme_constant(&"layout_gap", &"DiffHeader"))
	_show_code(_code)
	# Not sized to its text, so a long path can't widen the panel: one line.
	var font: Font = get_theme_font(&"normal_font", &"RichTextLabel")
	_path.custom_minimum_size.y = font.get_height(get_theme_font_size(&"normal_font_size", &"RichTextLabel"))
	_show_path(_path_shown[0], _path_shown[1], _path_shown[2])


static func _size_text(bytes: int) -> String:
	if bytes < 0:
		return "none"
	return String.humanize_size(bytes)
