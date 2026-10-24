class_name Toasts
extends VBoxContainer
## Short notifications in the corner, mainly classified git errors
## (`Core.git_error`). "Details" opens the full command and stderr.

const THEME_TYPE: StringName = &"Toasts"
## The same error for the same repository is shown at most once in this window.
const REPEAT_WINDOW_MSEC: int = 10_000

var _recent: Dictionary[String, int] = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	alignment = BoxContainer.ALIGNMENT_END
	Core.git_error.connect(_on_git_error)


## Shows a toast; `details` (if any) opens in a dialog.
func show_toast(title: String, message: String, details: String = "") -> void:
	var panel: PanelContainer = PanelContainer.new()
	panel.theme_type_variation = &"ToastPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var row: HBoxContainer = HBoxContainer.new()
	panel.add_child(row)
	var text: Label = Label.new()
	text.text = title if message.is_empty() else "%s\n%s" % [title, message]
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(text)
	if not details.is_empty():
		var more: Button = Button.new()
		more.text = "Details"
		more.flat = true
		more.pressed.connect(func() -> void: _show_details(title, details))
		row.add_child(more)
	var close: Button = Button.new()
	close.text = "✕"
	close.flat = true
	close.pressed.connect(panel.queue_free)
	row.add_child(close)
	add_child(panel)
	get_tree().create_timer(float(get_theme_constant(&"seconds", THEME_TYPE))).timeout.connect(
			func() -> void:
				if is_instance_valid(panel):
					panel.queue_free())


func toast_count() -> int:
	return get_child_count()


func _on_git_error(repo_path: String, error: Dictionary) -> void:
	var key: String = repo_path + "|" + String(error.get("kind", "")) + "|" + String(error.get("command", ""))
	var now: int = Time.get_ticks_msec()
	if _recent.has(key) and now - _recent[key] < REPEAT_WINDOW_MSEC:
		return
	_recent[key] = now
	var title: String = "%s: %s" % [repo_path.get_file(), String(error.get("title", "git failed"))]
	var details: String = "git %s\n\n%s" % [String(error.get("command", "")), String(error.get("stderr", ""))]
	show_toast(title, String(error.get("message", "")), details)


func _show_details(title: String, details: String) -> void:
	var dialog: AcceptDialog = AcceptDialog.new()
	dialog.title = title
	dialog.dialog_text = details
	dialog.dialog_autowrap = true
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.5)
