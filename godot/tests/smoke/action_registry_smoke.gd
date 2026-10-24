extends SmokeTest
## Actions run by id and by shortcut, respect their enabled predicate, and
## shortcut overrides are saved to (and removed from) the config.

var _ran: int = 0
var _enabled: bool = true


func run() -> void:
	expect(Shortcuts.parse("Nope+X") == null, "unknown modifier is rejected")
	expect(Shortcuts.parse("") == null, "empty shortcut is rejected")
	var round_trip: InputEventKey = Shortcuts.parse("Ctrl+Shift+P")
	expect_eq(Shortcuts.from_event(round_trip), "Ctrl+Shift+P", "shortcut text round-trips")

	Actions.register(&"test.bump", "Bump", "Test", _bump,
			PackedStringArray(["Ctrl+Alt+F9"]), func() -> bool: return _enabled)
	expect(Actions.run_action(&"test.bump"), "runs by id")
	expect_eq(_ran, 1, "callback ran")
	expect_eq(Actions.action_for_event(Shortcuts.parse("Ctrl+Alt+F9")), &"test.bump",
			"default shortcut matches")
	expect_eq(Actions.action_for_event(Shortcuts.parse("Ctrl+F9")), &"",
			"modifiers must match exactly")

	_enabled = false
	expect(not Actions.run_action(&"test.bump"), "disabled action does not run")
	expect_eq(_ran, 1, "callback did not run while disabled")
	_enabled = true

	Actions.set_shortcut(&"test.bump", "Ctrl+Alt+F10")
	expect_eq(Actions.action_for_event(Shortcuts.parse("Ctrl+Alt+F9")), &"", "old shortcut released")
	expect_eq(Actions.action_for_event(Shortcuts.parse("Ctrl+Alt+F10")), &"test.bump", "new shortcut works")
	expect_eq(String(Core.keybindings().get("test.bump", "")), "Ctrl+Alt+F10", "override saved to config")

	Actions.set_shortcut(&"test.bump", "")
	expect_eq(Actions.action_for_event(Shortcuts.parse("Ctrl+Alt+F9")), &"test.bump", "reset restores default")
	expect(not Core.keybindings().has("test.bump"), "override removed from config")

	Actions.unregister(&"test.bump")
	expect(Actions.get_action(&"test.bump") == null, "unregistered")
	await get_tree().process_frame


func _bump() -> void:
	_ran += 1
