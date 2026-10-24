class_name Shortcuts
extends RefCounted
## Shortcut text <-> key events. Text looks like `Ctrl+Shift+P`; `Ctrl` means
## Cmd on macOS (Godot's command-or-control remap).


## Parses `Ctrl+Shift+P`; returns null for empty or invalid text.
static func parse(text: String) -> InputEventKey:
	var parts: PackedStringArray = text.strip_edges().split("+", false)
	if parts.is_empty():
		return null
	var event: InputEventKey = InputEventKey.new()
	for i: int in parts.size() - 1:
		match parts[i].strip_edges().to_lower():
			"ctrl", "cmd", "command", "cmdorctrl":
				event.command_or_control_autoremap = true
			"shift":
				event.shift_pressed = true
			"alt", "option":
				event.alt_pressed = true
			"meta", "super", "win":
				event.meta_pressed = true
			_:
				return null
	var key_name: String = parts[parts.size() - 1].strip_edges()
	var keycode: Key = OS.find_keycode_from_string(key_name)
	if keycode == KEY_NONE:
		return null
	event.keycode = keycode
	event.pressed = true
	return event


## Canonical text for a pressed key event (modifier-only presses give "").
static func from_event(event: InputEventKey) -> String:
	var keycode: Key = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
	if keycode in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META, KEY_NONE]:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	if event.is_command_or_control_pressed():
		parts.append("Ctrl")
	if event.shift_pressed:
		parts.append("Shift")
	if event.alt_pressed:
		parts.append("Alt")
	if event.meta_pressed and not OS.has_feature("macos"):
		parts.append("Meta")
	parts.append(OS.get_keycode_string(keycode))
	return "+".join(parts)


## Text to show users (`Cmd` instead of `Ctrl` on macOS).
static func display(text: String) -> String:
	if OS.has_feature("macos"):
		return text.replace("Ctrl+", "Cmd+")
	return text


## Whether `event` presses exactly `shortcut` (modifiers included).
static func matches(event: InputEventKey, shortcut: InputEventKey) -> bool:
	if shortcut == null or not event.pressed:
		return false
	var keycode: Key = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
	return keycode == shortcut.keycode \
			and event.is_command_or_control_pressed() == shortcut.is_command_or_control_pressed() \
			and event.shift_pressed == shortcut.shift_pressed \
			and event.alt_pressed == shortcut.alt_pressed
