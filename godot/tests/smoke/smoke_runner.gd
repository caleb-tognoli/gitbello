extends Node
## Headless smoke-test runner, launched by `cargo xtask smoke`.
## Checks that every script compiles, runs each `*_smoke.gd` in this folder,
## prints SMOKE PASSED or SMOKE FAILED, and quits with exit code 0 or 1.

const SMOKE_DIR: String = "res://tests/smoke"
const SKIP_DIRS: PackedStringArray = [".godot", "bin"]


func _ready() -> void:
	var failures: PackedStringArray = PackedStringArray()
	for path: String in _find_files("res://", ".gd"):
		var script: GDScript = load(path) as GDScript
		if script == null or not script.can_instantiate():
			failures.append("%s: script does not compile" % path)

	for path: String in _find_files(SMOKE_DIR, "_smoke.gd"):
		var script: GDScript = load(path) as GDScript
		if script == null or not script.can_instantiate():
			continue  # already reported as not compiling
		var test: SmokeTest = script.new() as SmokeTest
		if test == null:
			failures.append("%s: not a SmokeTest" % path)
			continue
		add_child(test)
		await test.run()
		for failure: String in test.failures:
			failures.append("%s: %s" % [path.get_file(), failure])
		print("%s %s" % ["ok  " if test.failures.is_empty() else "FAIL", path.get_file()])
		test.queue_free()

	if failures.is_empty():
		print("SMOKE PASSED")
		get_tree().quit(0)
	else:
		for failure: String in failures:
			printerr("  - %s" % failure)
		printerr("SMOKE FAILED: %d failure(s)" % failures.size())
		get_tree().quit(1)


func _find_files(dir_path: String, suffix: String) -> PackedStringArray:
	var found: PackedStringArray = PackedStringArray()
	for file: String in DirAccess.get_files_at(dir_path):
		if file.ends_with(suffix):
			found.append(dir_path.path_join(file))
	for sub: String in DirAccess.get_directories_at(dir_path):
		if not SKIP_DIRS.has(sub):
			found.append_array(_find_files(dir_path.path_join(sub), suffix))
	found.sort()
	return found
