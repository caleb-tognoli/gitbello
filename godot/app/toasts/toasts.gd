class_name Toasts
extends VBoxContainer
## Notifications stacked at the bottom centre of the content area (PLAN §4
## Feedback). Three kinds:
## - errors (`show_toast`, mainly classified git errors from `Core.git_error`):
##   they stay until dismissed, with "Details" (the full command and stderr)
##   and buttons that fix known errors (a rejected push offers Pull);
## - successes (`show_success`): short, hidden after a few seconds unless
##   hovered, with Undo when the operation can really be undone;
## - progress (`show_progress`): a job started without a button to show it,
##   turned into its result by `finish_progress`.

const THEME_TYPE: StringName = &"Toasts"
## The same error for the same repository is shown at most once in this window.
const REPEAT_WINDOW_MSEC: int = 10_000
## Fix and Undo buttons are in this group (for tests and `fix_labels`).
const ACTION_GROUP: StringName = &"toast_actions"

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


## Shows an error toast; `details` (if any) opens in a dialog; each of
## `fixes` (`{label, run}`) is a button that runs it and closes the toast.
func show_toast(title: String, message: String, details: String = "", fixes: Array[Dictionary] = []) -> void:
	var panel: PanelContainer = _panel(&"ToastPanel", title, message)
	var row: HBoxContainer = panel.get_child(0).get_child(0) as HBoxContainer
	if not details.is_empty():
		var more: Button = Button.new()
		more.icon = AppTheme.icon(&"Info")
		more.tooltip_text = "Show error details"
		more.theme_type_variation = &"ToolbarButton"
		more.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		more.pressed.connect(func() -> void: _show_details(title, details))
		row.add_child(more)
		row.move_child(more, row.get_child_count() - 2)
	_add_actions(panel, fixes)
	add_child(panel)


## Shows a short success message, hidden after a few seconds (not while the
## mouse is over it). `undo` adds an Undo button.
func show_success(text: String, undo: Callable = Callable()) -> PanelContainer:
	var panel: PanelContainer = _panel(&"SuccessToastPanel", text, "")
	var actions: Array[Dictionary] = []
	if undo.is_valid():
		actions.append({"label": "Undo", "run": undo})
	_add_actions(panel, actions)
	add_child(panel)
	_expire(panel)
	return panel


## Shows a job's progress; update it with `update_progress` and end it with
## `finish_progress`. `cancel` adds a Cancel button.
func show_progress(text: String, cancel: Callable = Callable()) -> PanelContainer:
	var panel: PanelContainer = _panel(&"ProgressToastPanel", text, "", false)
	var bar: ProgressBar = ProgressBar.new()
	bar.indeterminate = true
	bar.show_percentage = false
	bar.name = "Progress"
	(panel.get_child(0) as VBoxContainer).add_child(bar)
	if cancel.is_valid():
		var actions: Array[Dictionary] = [{"label": "Cancel", "run": cancel}]
		_add_actions(panel, actions)
	add_child(panel)
	return panel


func update_progress(panel: PanelContainer, text: String, percent: int) -> void:
	if not is_instance_valid(panel):
		return
	(panel.find_child("Title", true, false) as Label).text = text
	var bar: ProgressBar = panel.find_child("Progress", true, false) as ProgressBar
	bar.indeterminate = percent < 0
	bar.value = maxf(0.0, float(percent))


## Ends a progress toast: with `text`, it becomes a success toast (and goes
## after a few seconds); without, it closes (errors get their own toast).
func finish_progress(panel: PanelContainer, text: String = "") -> void:
	if not is_instance_valid(panel):
		return
	if text.is_empty():
		panel.queue_free()
		return
	var at: int = panel.get_index()
	panel.queue_free()
	var done: PanelContainer = show_success(text)
	move_child(done, at)


func toast_count() -> int:
	var count: int = 0
	for child: Node in get_children():
		if not child.is_queued_for_deletion():
			count += 1
	return count


## Every toast's title text, oldest first (for tests).
func toast_texts() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for child: Node in get_children():
		if child.is_queued_for_deletion():
			continue
		var title: Label = child.find_child("Title", true, false) as Label
		if title != null:
			out.append(title.text)
	return out


## Labels of the fix and Undo buttons of every toast shown (for tests).
func fix_labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for button: Button in _action_buttons():
		out.append(button.text)
	return out


## Presses the fix button labelled `label` (for tests). Returns whether found.
func press_fix(label: String) -> bool:
	for button: Button in _action_buttons():
		if button.text == label:
			button.pressed.emit()
			return true
	return false


func _action_buttons() -> Array[Button]:
	var out: Array[Button] = []
	for node: Node in find_children("*", "Button", true, false):
		if node.is_in_group(ACTION_GROUP) and not node.is_queued_for_deletion():
			out.append(node as Button)
	return out


## A toast panel: a row with the title (and message) and a close button.
func _panel(variation: StringName, title: String, message: String, closable: bool = true) -> PanelContainer:
	var panel: PanelContainer = PanelContainer.new()
	panel.theme_type_variation = variation
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.custom_minimum_size.x = float(get_theme_constant(&"width", THEME_TYPE))
	var box: VBoxContainer = VBoxContainer.new()
	panel.add_child(box)
	var row: HBoxContainer = HBoxContainer.new()
	box.add_child(row)
	var texts: VBoxContainer = VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(texts)
	var title_label: Label = Label.new()
	title_label.name = "Title"
	title_label.text = title
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	texts.add_child(title_label)
	if not message.is_empty():
		var message_label: Label = Label.new()
		message_label.text = message
		message_label.theme_type_variation = &"DimLabel"
		message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		texts.add_child(message_label)
	if closable:
		var close: Button = Button.new()
		close.icon = AppTheme.CLOSE
		close.tooltip_text = "Dismiss"
		close.theme_type_variation = &"ToolbarButton"
		close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		close.pressed.connect(panel.queue_free)
		row.add_child(close)
	return panel


## Buttons along the bottom of a toast; each runs its action and closes it.
func _add_actions(panel: PanelContainer, actions: Array[Dictionary]) -> void:
	if actions.is_empty():
		return
	var row: HBoxContainer = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	for action: Dictionary in actions:
		var button: Button = Button.new()
		button.text = String(action["label"])
		button.add_to_group(ACTION_GROUP)
		button.pressed.connect(_run_action.bind(action["run"], panel))
		row.add_child(button)
	(panel.get_child(0) as VBoxContainer).add_child(row)


## Hides `panel` after the theme's seconds, waiting while the mouse is over it.
func _expire(panel: PanelContainer) -> void:
	var seconds: float = float(get_theme_constant(&"seconds", THEME_TYPE))
	var timer: SceneTreeTimer = get_tree().create_timer(seconds)
	# A toast can be dismissed before its timer fires. Capturing the node
	# directly makes Godot report a freed lambda capture before the guard runs.
	var target: WeakRef = weakref(panel)
	timer.timeout.connect(func() -> void:
		var current: PanelContainer = target.get_ref() as PanelContainer
		if not is_instance_valid(current) or current.is_queued_for_deletion():
			return
		if Rect2(Vector2.ZERO, current.size).has_point(current.get_local_mouse_position()):
			_expire(current)
		else:
			current.queue_free())


func _run_action(run: Callable, panel: Control) -> void:
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
