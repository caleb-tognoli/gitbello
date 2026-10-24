class_name SmokeTest
extends Node
## Base class for headless smoke tests run by `smoke_runner.gd`.
## Override `run()` and record problems with the `expect*` helpers.

var failures: PackedStringArray = PackedStringArray()


func run() -> void:
	await get_tree().process_frame


func expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func expect_eq(actual: Variant, expected: Variant, message: String) -> void:
	if typeof(actual) != typeof(expected) or actual != expected:
		failures.append("%s: expected %s, got %s" % [message, expected, actual])


## Waits up to `timeout_ms` (frames keep running) for `condition`; returns
## whether it became true.
func wait_until(condition: Callable, timeout_ms: int = 30_000) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await get_tree().process_frame
	return bool(condition.call())


## Sends a key press and release such as `Ctrl+Enter` through the viewport.
func press(shortcut: String) -> void:
	var event: InputEventKey = Shortcuts.parse(shortcut)
	if event == null:
		failures.append("bad shortcut in test: %s" % shortcut)
		return
	event.physical_keycode = event.keycode
	if event.keycode == KEY_SPACE:
		event.unicode = 32
	get_viewport().push_input(event)
	var release: InputEventKey = event.duplicate() as InputEventKey
	release.pressed = false
	get_viewport().push_input(release)


## Types `text` into the focused control, one key event per character.
func type_text(text: String) -> void:
	for ch: String in text:
		var event: InputEventKey = InputEventKey.new()
		event.pressed = true
		event.unicode = ch.unicode_at(0)
		event.keycode = OS.find_keycode_from_string(ch.to_upper()) if ch != " " else KEY_SPACE
		get_viewport().push_input(event)


## The `--fixtures=<dir>` argument from `cargo xtask smoke`, or "".
static func fixtures_dir() -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--fixtures="):
			return arg.trim_prefix("--fixtures=")
	return ""
