class_name Toasts
extends VBoxContainer
## Short notifications in the corner, mainly classified git errors
## (`Core.git_error`). "Details" opens the full command and stderr; known
## errors also get buttons that fix them (a rejected push offers Pull).

const THEME_TYPE: StringName = &"Toasts"
## The same error for the same repository is shown at most once in this window.
const REPEAT_WINDOW_MSEC: int = 10_000

## `func(repo_path: String, error: Dictionary) -> Array[Dictionary]`: fixes
## for an error, each `{label, run: Callable}`.
var fix_provider: Callable = Callable()
## `func(repo_path: String, error: Dictionary) -> bool`: true when the error
## is followed up elsewhere (a dialog) and needs no toast.
var error_filter: Callable = Callable()

var _recent: Dictionary[String, int] = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	alignment = BoxContainer.ALIGNMENT_END
	Core.git_error.connect(_on_git_error)


## Shows a toast; `details` (if any) opens in a dialog; each of `fixes`
## (`{label, run}`) is a button that runs it and closes the toast.
func show_toast(title: String, message: String, details: String = "", fixes: Array[Dictionary] = []) -> void:
	var panel: PanelContainer = PanelContainer.new()
	panel.theme_type_variation = &"ToastPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var box: VBoxContainer = VBoxContainer.new()
	panel.add_child(box)
	var row: HBoxContainer = HBoxContainer.new()
	box.add_child(row)
	var text: Label = Label.new()
	text.text = title if message.is_empty() else "%s
%s" % [title, message]
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
	if not fixes.is_empty():
		var actions: HBoxContainer = HBoxContainer.new()
		actions.alignment = BoxContainer.ALIGNMENT_END
		for fix: Dictionary in fixes:
			var button: Button = Button.new()
			button.text = String(fix["label"])
			button.pressed.connect(_run_fix.bind(fix["run"], panel))
			actions.add_child(button)
		box.add_child(actions)
	add_child(panel)
	get_tree().create_timer(float(get_theme_constant(&"seconds", THEME_TYPE))).timeout.connect(
			func() -> void:
				if is_instance_valid(panel):
					panel.queue_free())


func toast_count() -> int:
	return get_child_count()


## Labels of the fix buttons of every toast shown (for tests).
func fix_labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for button: Button in _fix_buttons():
		out.append(button.text)
	return out


## Presses the fix button labelled `label` (for tests). Returns whether found.
func press_fix(label: String) -> bool:
	for button: Button in _fix_buttons():
		if button.text == label:
			button.pressed.emit()
			return true
	return false


## Fix buttons are the non-flat ones.
func _fix_buttons() -> Array[Button]:
	var out: Array[Button] = []
	for node: Node in find_children("*", "Button", true, false):
		if not (node as Button).flat:
			out.append(node as Button)
	return out


func _run_fix(run: Callable, panel: Control) -> void:
	panel.queue_free()
	run.call()


func _on_git_error(repo_path: String, error: Dictionary) -> void:
	if String(error.get("kind", "")) == "cancelled":
		return
	if error_filter.is_valid() and bool(error_filter.call(repo_path, error)):
		return
	var key: String = repo_path + "|" + String(error.get("kind", "")) + "|" + String(error.get("command", ""))
	var now: int = Time.get_ticks_msec()
	if _recent.has(key) and now - _recent[key] < REPEAT_WINDOW_MSEC:
		return
	_recent[key] = now
	var title: String = "%s: %s" % [repo_path.get_file(), String(error.get("title", "git failed"))]
	var details: String = "git %s\n\n%s" % [String(error.get("command", "")), String(error.get("stderr", ""))]
	var fixes: Array[Dictionary] = []
	if fix_provider.is_valid():
		fixes.assign(fix_provider.call(repo_path, error))
	show_toast(title, String(error.get("message", "")), details, fixes)


func _show_details(title: String, details: String) -> void:
	var dialog: AcceptDialog = AcceptDialog.new()
	dialog.title = title
	dialog.dialog_text = details
	dialog.dialog_autowrap = true
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.5)
