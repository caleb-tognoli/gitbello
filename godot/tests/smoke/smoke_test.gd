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
