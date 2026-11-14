extends SmokeTest

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var command: String = "fetch origin"
	var stderr: String = "fatal: Cannot read 'space and é/[literal].git'\n\tsecond line\n"
	for index: int in 60:
		stderr += "%03d %s\n" % [index, "long-unbroken-path".repeat(20)]
	var details: String = "git %s\n\n%s" % [command, stderr]
	Core.git_error.emit("C:/fixture/error-details", {
		"kind": "other", "title": "Fetch failed", "message": "Cannot fetch", "command": command, "stderr": stderr,
	})
	var info: Button = null
	for node: Node in main.toasts().find_children("*", "Button", true, false):
		var button: Button = node as Button
		if button.tooltip_text == "Show error details":
			info = button
	expect(info != null, "classified error exposes the existing Info button")
	if info == null:
		main.queue_free()
		return
	info.pressed.emit()
	await get_tree().process_frame
	var dialog: AcceptDialog = _dialog(main.toasts())
	expect(dialog != null, "Info opens the actual details dialog")
	if dialog == null:
		main.queue_free()
		return
	var output: TextEdit = dialog.find_child("ErrorDetails", true, false) as TextEdit
	expect(output != null, "details use a selectable text control")
	if output == null:
		main.queue_free()
		return
	expect_eq(output.text, details, "full command, whitespace, Unicode and long output remain exact")
	expect(not output.editable, "details are read-only")
	expect(output.is_selecting_enabled(), "selection is enabled")
	expect(output.has_focus(), "details receive focus")
	expect(output.wrap_mode == TextEdit.LINE_WRAPPING_BOUNDARY, "long lines wrap")
	expect(output.get_v_scroll_bar().max_value > output.get_v_scroll_bar().page, "long output scrolls")
	expect(dialog.size.y <= main.get_viewport_rect().size.y, "dialog stays within the app height")
	expect(dialog.get_ok_button().get_global_rect().end.y <= float(dialog.size.y), "OK remains reachable")
	press("Ctrl+A", dialog)
	await get_tree().process_frame
	expect_eq(output.get_selected_text(), details, "native Select All includes output outside the viewport")
	press("Delete", dialog)
	press("Backspace", dialog)
	var typed: InputEventKey = InputEventKey.new()
	typed.pressed = true
	typed.keycode = KEY_X
	typed.unicode = 120
	dialog.push_input(typed)
	await get_tree().process_frame
	expect_eq(output.text, details, "typing and deletion cannot modify details")
	output.deselect()
	output.select(0, 0, 0, 3)
	expect_eq(output.get_selected_text(), "git", "a diagnostic substring can be selected")
	await _clipboard(output, dialog, details)
	var target: WeakRef = weakref(dialog)
	press("Escape", dialog)
	expect(await wait_until(func() -> bool: return target.get_ref() == null, 1000), "Escape frees the modal")
	if target.get_ref() != null:
		dialog.canceled.emit()
		await get_tree().process_frame
	info.pressed.emit()
	await get_tree().process_frame
	dialog = _dialog(main.toasts())
	output = dialog.find_child("ErrorDetails", true, false) as TextEdit
	expect(not output.has_selection(), "reopening starts without stale selection")
	expect_eq(output.text, details, "reopening preserves the diagnostic")
	target = weakref(dialog)
	dialog.get_ok_button().pressed.emit()
	expect(await wait_until(func() -> bool: return target.get_ref() == null, 1000), "OK frees the modal")
	info.pressed.emit()
	await get_tree().process_frame
	dialog = _dialog(main.toasts())
	target = weakref(dialog)
	dialog.notification(NOTIFICATION_WM_CLOSE_REQUEST)
	expect(await wait_until(func() -> bool: return target.get_ref() == null, 1000), "window-close frees the modal")
	main.queue_free()
	await get_tree().process_frame


func _clipboard(output: TextEdit, dialog: AcceptDialog, details: String) -> void:
	if DisplayServer.get_name() == "headless" or not OS.get_cmdline_user_args().has("--verify-clipboard"):
		print("SKIP native clipboard: use --verify-clipboard windowed with an empty scratch clipboard")
		return
	if not DisplayServer.clipboard_get().is_empty() or DisplayServer.clipboard_has_image():
		_fail("native clipboard verification requires an empty scratch clipboard")
		return
	var failures_before: int = failures.size()
	press("Ctrl+C", dialog)
	await get_tree().process_frame
	expect(DisplayServer.clipboard_get() == "git", "native Copy copies only the selected substring")
	press("Ctrl+A", dialog)
	await get_tree().process_frame
	expect_eq(output.get_selected_text(), details, "native Select All is ready before Copy")
	press("Ctrl+C", dialog)
	await get_tree().process_frame
	expect(DisplayServer.clipboard_get().replace("\r\n", "\n") == details, "native Copy includes the entire long diagnostic")
	await _paste_in_window(dialog, details)
	dialog.grab_focus()
	output.grab_focus()
	output.select(0, 4, 0, 9)
	output.get_menu().id_pressed.emit(TextEdit.MENU_COPY)
	expect(DisplayServer.clipboard_get() == "fetch", "native context menu copies a substring")
	press("Ctrl+V", dialog)
	press("Ctrl+X", dialog)
	await get_tree().process_frame
	expect_eq(output.text, details, "paste and cut cannot change read-only output")
	if DisplayServer.clipboard_get() in ["git", "fetch", details, details.replace("\n", "\r\n")] and not DisplayServer.clipboard_has_image():
		DisplayServer.clipboard_set("")
	if failures.size() == failures_before:
		print("NATIVE CLIPBOARD VERIFIED: substring, Select All, full Copy, context-menu Copy, readonly paste/cut")


func _paste_in_window(dialog: AcceptDialog, details: String) -> void:
	var receiving_window: Window = Window.new()
	receiving_window.title = "Clipboard paste verification"
	receiving_window.transient = true
	var receiver: TextEdit = TextEdit.new()
	receiving_window.add_child(receiver)
	receiver.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dialog.add_child(receiving_window)
	receiving_window.popup_centered(Vector2i(640, 240))
	receiver.grab_focus()
	await get_tree().process_frame
	expect(receiving_window.get_window_id() != dialog.get_window_id(), "paste receiver is a separate native window")
	expect(receiver.text.is_empty() and receiver.editable, "paste receiver starts empty and editable")
	press("Ctrl+V", receiving_window)
	await get_tree().process_frame
	var exact: bool = receiver.text.replace("\r\n", "\n") == details
	expect(exact, "native Ctrl+V pastes the exact long diagnostic into an independent editable receiver")
	if exact:
		print("NATIVE RECEIVER PASTE VERIFIED: exact %d-character diagnostic" % details.length())
	receiving_window.hide()
	receiving_window.queue_free()
	await get_tree().process_frame


func _dialog(toasts: Toasts) -> AcceptDialog:
	for child: Node in toasts.get_children():
		if child is AcceptDialog:
			return child as AcceptDialog
	return null
