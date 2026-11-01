class_name Toasts
extends VBoxContainer
## Notifications stacked at the bottom right of the content area (PLAN §4
## Feedback): compact cards with an icon for their kind. Three kinds:
## - errors (`show_toast`, mainly classified git errors from `Core.git_error`):
##   they stay until dismissed, with "Details" (the full command and stderr)
##   and buttons that fix known errors (a rejected push offers Pull);
## - successes (`show_success`): short, hidden after a few seconds unless
##   hovered or focused (a thin line shows the time left), with Undo when the
##   operation can really be undone. Callers show one only when it offers an
##   action or nothing else on screen shows the result;
## - progress (`show_progress`): a job started without a button to show it,
##   turned into its result by `finish_progress`.

const THEME_TYPE: StringName = &"Toasts"
## The same error for the same repository is shown at most once in this window.
const REPEAT_WINDOW_MSEC: int = 10_000
## Fix and Undo buttons are in this group (for tests and `fix_labels`).
const ACTION_GROUP: StringName = &"toast_actions"
## Seconds of the fade in, and of the fade out of an expiring success.
const FADE_SECONDS: float = 0.12

## `func(repo_path: String, error: Dictionary) -> Array[Dictionary]`: fixes
## for an error, each `{label, run: Callable}`.
var fix_provider: Callable = Callable()
## `func(repo_path: String, error: Dictionary) -> bool`: true when the error
## is followed up elsewhere (a dialog) and needs no toast.
var error_filter: Callable = Callable()

var _recent: Dictionary[String, int] = {}
var _scroll: ScrollContainer = ScrollContainer.new()
var _stack: VBoxContainer = VBoxContainer.new()
var _overflow: Label = Label.new()
var _layout_queued: bool = false
## Turns the spinners of progress toasts while there are any.
var _spin: Timer = Timer.new()
var _frame: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	alignment = BoxContainer.ALIGNMENT_END
	_scroll.name = "Scroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	add_child(_scroll)
	_stack.name = "Stack"
	_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_stack)
	_overflow.name = "Overflow"
	_overflow.theme_type_variation = &"DimLabel"
	_overflow.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_overflow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overflow)
	_stack.minimum_size_changed.connect(_queue_layout)
	_stack.child_exiting_tree.connect(func(_node: Node) -> void: _queue_layout())
	(get_parent() as Control).resized.connect(_queue_layout)
	Core.git_error.connect(_on_git_error)
	_spin.wait_time = BigButton.SPIN_SECONDS
	_spin.timeout.connect(_turn_spinners)
	add_child(_spin)
	_queue_layout()


func _notification(what: int) -> void:
	if what in [NOTIFICATION_THEME_CHANGED, NOTIFICATION_TRANSLATION_CHANGED] and is_node_ready():
		_queue_layout()
		if what == NOTIFICATION_THEME_CHANGED:
			for panel: Node in _stack.get_children():
				_set_icon(panel as PanelContainer)
		if what == NOTIFICATION_TRANSLATION_CHANGED:
			for child: Node in get_children():
				if child is AcceptDialog:
					var output: TextEdit = child.get_node_or_null("ErrorDetails") as TextEdit
					if output != null:
						output.tooltip_text = tr("Select text to copy; use %s to select all.") % Shortcuts.display("Ctrl+A")


func _queue_layout() -> void:
	if not _layout_queued:
		_layout_queued = true
		_layout.call_deferred()


func _layout() -> void:
	_layout_queued = false
	var available: Vector2 = (get_parent() as Control).size
	var edge: float = float(get_theme_constant(&"edge_margin", THEME_TYPE))
	var width: float = minf(float(get_theme_constant(&"width", THEME_TYPE)), maxf(1.0, available.x - 2.0 * edge))
	var limit: float = minf(float(get_theme_constant(&"max_height", THEME_TYPE)),
			available.y * float(get_theme_constant(&"height_percent", THEME_TYPE)) / 100.0)
	var height: float = _stack.get_combined_minimum_size().y
	var count: int = toast_count()
	_overflow.visible = count > 0 and height > limit
	_overflow.text = tr("%d notifications · scroll for more") % count
	var footer: float = _overflow.get_combined_minimum_size().y + float(get_theme_constant(&"separation")) if _overflow.visible else 0.0
	_scroll.visible = count > 0
	_scroll.custom_minimum_size.y = minf(height, maxf(0.0, limit - footer)) if count > 0 else 0.0
	custom_minimum_size.x = width
	size = Vector2(width, 0.0)
	reset_size()
	position = Vector2(maxf(0.0, available.x - edge - size.x),
			available.y - float(get_theme_constant(&"bottom_margin", THEME_TYPE)) - size.y)


## Shows an error toast; `details` (if any) opens in a dialog; each of
## `fixes` (`{label, run}`) is a button that runs it and closes the toast.
func show_toast(title: String, message: String, details: String = "", fixes: Array[Dictionary] = []) -> void:
	var panel: PanelContainer = _panel(&"ToastPanel", title, message)
	if not details.is_empty():
		var more: Button = Button.new()
		more.name = "Details"
		more.icon = AppTheme.icon(&"Info")
		more.tooltip_text = tr("Show error details")
		more.theme_type_variation = &"ToolbarButton"
		more.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		more.pressed.connect(func() -> void: _show_details(title, details))
		var row: HBoxContainer = _row(panel)
		row.add_child(more)
		row.move_child(more, row.get_child_count() - 2)
	# Fixes go along the bottom, on the right like a success's Undo: there can
	# be several, with longer labels.
	_add_actions(panel, fixes, panel.get_child(0) as VBoxContainer)
	_add(panel)


## Shows a short success message, pausing its remaining lifetime while
## hovered or focused. `undo` adds an Undo button (or a `label` one, such as
## Open) and a longer lifetime.
func show_success(text: String, undo: Callable = Callable(), label: String = "Undo") -> PanelContainer:
	var panel: PanelContainer = _panel(&"SuccessToastPanel", text, "")
	var actions: Array[Dictionary] = []
	if undo.is_valid():
		actions.append({"label": label, "run": undo})
	_add_actions(panel, actions)
	_add(panel)
	_expire(panel, undo.is_valid())
	return panel


## Shows a job's progress; update it with `update_progress` and end it with
## `finish_progress`. `cancel` adds a Cancel button.
func show_progress(text: String, cancel: Callable = Callable()) -> PanelContainer:
	var panel: PanelContainer = _panel(&"ProgressToastPanel", text, "", false)
	var bar: ProgressBar = ProgressBar.new()
	bar.name = "Progress"
	bar.theme_type_variation = &"ToastProgress"
	bar.indeterminate = true
	bar.show_percentage = false
	(panel.get_child(0) as VBoxContainer).add_child(bar)
	if cancel.is_valid():
		var actions: Array[Dictionary] = [{"label": "Cancel", "run": cancel}]
		_add_actions(panel, actions)
	_add(panel)
	if _spin.is_stopped():
		_spin.start()
	return panel


func update_progress(panel: PanelContainer, text: String, percent: int) -> void:
	if not is_instance_valid(panel):
		return
	(panel.find_child("Title", true, false) as Label).text = text
	var bar: ProgressBar = panel.find_child("Progress", true, false) as ProgressBar
	bar.indeterminate = percent < 0
	bar.value = maxf(0.0, float(percent))


## Ends a progress toast: with `text`, it becomes a success toast (and goes
## after a few seconds), with `undo` as in `show_success`; without, it closes
## (errors get their own toast).
func finish_progress(panel: PanelContainer, text: String = "", undo: Callable = Callable()) -> void:
	if not is_instance_valid(panel):
		return
	if text.is_empty():
		panel.queue_free()
		return
	var at: int = panel.get_index()
	panel.queue_free()
	var done: PanelContainer = show_success(text, undo)
	# The progress card was already showing: no second fade in.
	done.modulate.a = 1.0
	_stack.move_child(done, at)


func toast_count() -> int:
	var count: int = 0
	for child: Node in _stack.get_children():
		if not child.is_queued_for_deletion():
			count += 1
	return count


## Every toast's title text, oldest first (for tests).
func toast_texts() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for child: Node in _stack.get_children():
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


## A toast panel: a row with the kind's icon, the title (and message) and a
## close button.
func _panel(variation: StringName, title: String, message: String, closable: bool = true) -> PanelContainer:
	var panel: PanelContainer = PanelContainer.new()
	panel.theme_type_variation = variation
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var box: VBoxContainer = VBoxContainer.new()
	box.theme_type_variation = &"ToastBox"
	panel.add_child(box)
	var row: HBoxContainer = HBoxContainer.new()
	row.name = "Row"
	row.theme_type_variation = &"ToastRow"
	box.add_child(row)
	var icon: TextureRect = TextureRect.new()
	icon.name = "Icon"
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(icon)
	var texts: VBoxContainer = VBoxContainer.new()
	texts.name = "Texts"
	texts.theme_type_variation = &"ToastTexts"
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(texts)
	var title_label: Label = Label.new()
	title_label.name = "Title"
	title_label.text = tr(title)
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	texts.add_child(title_label)
	if not message.is_empty():
		var message_label: Label = Label.new()
		message_label.name = "Message"
		message_label.text = tr(message)
		message_label.theme_type_variation = &"DimLabel"
		message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		texts.add_child(message_label)
	if closable:
		var close: Button = Button.new()
		close.name = "Close"
		close.icon = AppTheme.CLOSE
		close.tooltip_text = tr("Dismiss")
		close.theme_type_variation = &"ToolbarButton"
		close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		close.pressed.connect(panel.queue_free)
		row.add_child(close)
	return panel


func _row(panel: PanelContainer) -> HBoxContainer:
	return panel.get_child(0).get_child(0) as HBoxContainer


## Adds `panel` to the stack, fading it in.
func _add(panel: PanelContainer) -> void:
	_stack.add_child(panel)
	_set_icon(panel)
	_queue_layout()
	panel.modulate.a = 0.0
	panel.create_tween().tween_property(panel, ^"modulate:a", 1.0, FADE_SECONDS)


## The kind's icon: a check for successes, a warning for errors, a spinner
## for progress.
func _set_icon(panel: PanelContainer) -> void:
	var icon: TextureRect = panel.find_child("Icon", true, false) as TextureRect
	if icon == null:
		return
	# As tall as the title's first line, so the icon centres on it.
	var title: Label = panel.find_child("Title", true, false) as Label
	icon.custom_minimum_size.y = title.get_theme_font(&"font").get_height(title.get_theme_font_size(&"font_size"))
	match panel.theme_type_variation:
		&"SuccessToastPanel":
			icon.texture = AppTheme.tintable_icon(&"StatusSuccess")
			icon.modulate = get_theme_color(&"success_color", THEME_TYPE)
		&"ToastPanel":
			icon.texture = AppTheme.tintable_icon(&"StatusWarning")
			icon.modulate = get_theme_color(&"error_color", THEME_TYPE)
		_:
			icon.texture = AppTheme.spinner(_frame, ThemeManager.light)
			icon.modulate = Color.WHITE


func _turn_spinners() -> void:
	_frame += 1
	var spinning: bool = false
	for node: Node in _stack.get_children():
		var panel: PanelContainer = node as PanelContainer
		if panel.theme_type_variation == &"ProgressToastPanel" and not panel.is_queued_for_deletion():
			_set_icon(panel)
			spinning = true
	if not spinning:
		_spin.stop()


## Buttons for the actions, at the end of the title row (or on the right of a
## row in `parent`); each runs its action and closes the toast.
func _add_actions(panel: PanelContainer, actions: Array[Dictionary], parent: Container = null) -> void:
	if actions.is_empty():
		return
	var row: HBoxContainer = HBoxContainer.new()
	row.name = "Actions"
	row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	for action: Dictionary in actions:
		var button: Button = Button.new()
		button.text = tr(String(action["label"]))
		button.theme_type_variation = &"ToastActionButton"
		button.add_to_group(ACTION_GROUP)
		button.pressed.connect(_run_action.bind(action["run"], panel))
		row.add_child(button)
	if parent != null:
		row.alignment = BoxContainer.ALIGNMENT_END
		parent.add_child(row)
		return
	var title_row: HBoxContainer = _row(panel)
	title_row.add_child(row)
	var close: Node = title_row.get_node_or_null(^"Close")
	if close != null:
		title_row.move_child(close, -1)


func _expire(panel: PanelContainer, has_undo: bool) -> void:
	var duration: StringName = &"undo_seconds" if has_undo else &"seconds"
	var countdown: ProgressBar = ProgressBar.new()
	countdown.name = "Countdown"
	countdown.theme_type_variation = &"ToastCountdown"
	countdown.show_percentage = false
	countdown.value = 100.0
	countdown.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(panel.get_child(0) as VBoxContainer).add_child(countdown)
	var timer: ToastLifetime = ToastLifetime.new()
	timer.wait_time = float(get_theme_constant(duration, THEME_TYPE))
	timer.countdown = countdown
	timer.fade_seconds = FADE_SECONDS
	timer.visibility_guard = _capacity_hides_actions.bind(panel)
	_scroll.get_v_scroll_bar().value_changed.connect(timer._queue_refresh.unbind(1))
	_scroll.resized.connect(timer._queue_refresh)
	panel.add_child(timer)


func _capacity_hides_actions(panel: PanelContainer) -> bool:
	if _scroll.get_global_rect().encloses(panel.get_global_rect()):
		return false
	for button: Node in panel.find_children("*", "Button", true, false):
		if button.is_in_group(ACTION_GROUP):
			return true
	return false


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
	var title: String = "%s: %s" % [repo_path.get_file(), tr(String(error.get("title", "git failed")))]
	var details: String = "git %s\n\n%s" % [String(error.get("command", "")), String(error.get("stderr", ""))]
	var fixes: Array[Dictionary] = []
	if fix_provider.is_valid():
		fixes.assign(fix_provider.call(repo_path, error))
	show_toast(title, String(error.get("message", "")), details, fixes)


func _show_details(title: String, details: String) -> void:
	var dialog: AcceptDialog = AcceptDialog.new()
	dialog.title = title
	var output: TextEdit = TextEdit.new()
	output.name = "ErrorDetails"
	output.theme_type_variation = &"DiagnosticOutput"
	output.editable = false
	output.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	output.text = details
	output.tooltip_text = tr("Select text to copy; use %s to select all.") % Shortcuts.display("Ctrl+A")
	output.gui_input.connect(func(event: InputEvent) -> void:
		if event.is_action_pressed(&"ui_cancel"):
			output.accept_event()
			dialog.canceled.emit())
	dialog.add_child(output)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.5)
	output.grab_focus()
