extends Node

const TEST: GDScript = preload("res://tests/smoke/diff_retry_smoke.gd")


func _ready() -> void:
	var test: SmokeTest = TEST.new() as SmokeTest
	add_child(test)
	await test.run()
	print("RETRY PREVIEW ", "PASSED" if test.failures.is_empty() else str(test.failures))
	get_tree().quit(0 if test.failures.is_empty() else 1)
