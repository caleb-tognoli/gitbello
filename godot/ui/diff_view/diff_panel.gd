class_name DiffPanel
extends VBoxContainer
## A file diff with its header (path, notes, +/− counts, layout toggle) and
## the messages shown instead of lines (loading, binary, too large, no
## changes, errors). Callers pass `RepoSession.diff_info()`-style
## dictionaries to `show_info`. Every panel is in the `diff_panels` group so
## the layout can change everywhere at once.

const GROUP: StringName = &"diff_panels"

## The user asked to load a diff past the size limit.
signal load_full_requested()

@onready var _path: Label = %DiffPath
@onready var _stats: Label = %DiffStats
@onready var _view: DiffView = %DiffView
@onready var _message: Control = %DiffMessage
@onready var _message_label: Label = %DiffMessageLabel
@onready var _load_anyway: Button = %LoadAnywayButton
@onready var _layout_button: Button = %LayoutButton

## `kind:path` of the diff shown, to keep the scroll position on reloads.
var _shown: String = ""
var _placeholder: String = ""


func _ready() -> void:
	add_to_group(GROUP)
	_load_anyway.pressed.connect(func() -> void: load_full_requested.emit())
	_layout_button.toggled.connect(func(on: bool) -> void:
		if on != _view.side_by_side:
			Actions.run_action(&"diff.toggle_side_by_side"))
	set_side_by_side(Core.diff_side_by_side())


func view() -> DiffView:
	return _view


## Where lines come from: `func(start, count) -> Array` (see DiffView).
func set_source(source: Callable) -> void:
	_view.source = source


## Where side-by-side rows come from (see DiffView).
func set_split_source(source: Callable) -> void:
	_view.split_source = source


func set_side_by_side(value: bool) -> void:
	_view.side_by_side = value
	_layout_button.set_pressed_no_signal(value)


## Clears the diff and shows `placeholder` (also used by later `clear()` calls).
func clear(placeholder: String = "") -> void:
	if not placeholder.is_empty():
		_placeholder = placeholder
	_shown = ""
	_view.show_lines(0, 0, false)
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
			show_message("No changes to show." if notes.is_empty() else "\n".join(notes))


func show_message(text: String, offer_full: bool = false) -> void:
	_message_label.text = text
	_load_anyway.visible = offer_full
	_message.show()


func message_text() -> String:
	return _message_label.text if _message.visible else ""


static func _size_text(bytes: int) -> String:
	if bytes < 0:
		return "none"
	return String.humanize_size(bytes)
