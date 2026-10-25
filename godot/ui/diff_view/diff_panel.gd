class_name DiffPanel
extends VBoxContainer
## A file diff with its header (status icon, path, notes, +/− counts,
## unified or side by side) and the messages shown instead of lines
## (loading, binary, too large, no changes, errors). Callers pass `RepoSession.diff_info()`-style
## dictionaries to `show_info`. Every panel is in the `diff_panels` group so
## the layout can change everywhere at once.

const GROUP: StringName = &"diff_panels"
## What an empty diff says, by status code.
const EMPTY_MESSAGES: Dictionary[String, String] = {
	"A": "New empty file.",
	"D": "Deleted an empty file.",
}

## The user asked to load a diff past the size limit.
signal load_full_requested()

@onready var _status_icon: TextureRect = %StatusIcon
@onready var _path: Label = %DiffPath
@onready var _stats: Label = %DiffStats
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
	_path.text = ""
	_stats.text = ""
	show_message(_placeholder)


## Shows a diff described by `info` (`state`, `path`, `kind`, `content`,
## `notes`, `additions`, `deletions`, `line_count`, `max_line`, sizes, `error`).
func show_info(info: Dictionary) -> void:
	var state: String = String(info.get("state", "none"))
	if state == "none":
		clear()
		return
	var path: String = String(info["path"])
	var key: String = String(info["kind"]) + ":" + path
	var code: String = String(info.get("code", ""))
	_show_code(code)
	_path.text = path
	var notes: PackedStringArray = info.get("notes", PackedStringArray())
	var stats: PackedStringArray = PackedStringArray(notes)
	if int(info.get("additions", 0)) > 0 or int(info.get("deletions", 0)) > 0:
		stats.append("+%d −%d" % [int(info["additions"]), int(info["deletions"])])
	_stats.text = "  ·  ".join(stats)
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


func _apply_theme() -> void:
	var icon_size: float = float(get_theme_constant(&"icon_size", FileRowPainter.THEME_TYPE))
	_status_icon.custom_minimum_size = Vector2(icon_size, icon_size)
	_show_code(_code)


static func _size_text(bytes: int) -> String:
	if bytes < 0:
		return "none"
	return String.humanize_size(bytes)
