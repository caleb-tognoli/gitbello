extends SmokeTest
## Required project settings (PLAN §3.7) are on and the main scene shows the core version.


func run() -> void:
	expect_eq(ProjectSettings.get_setting("application/run/low_processor_mode"), true,
			"low processor mode")
	expect_eq(ProjectSettings.get_setting("display/window/dpi/allow_hidpi"), true, "HiDPI")
	expect_eq(ProjectSettings.get_setting("debug/gdscript/warnings/untyped_declaration"), 2,
			"untyped-declaration warning is an error")

	var main_path: String = ProjectSettings.get_setting("application/run/main_scene")
	var packed: PackedScene = load(main_path) as PackedScene
	expect(packed != null, "main scene loads")
	if packed == null:
		return

	var main: Node = packed.instantiate()
	add_child(main)
	await get_tree().process_frame
	var label: Label = main.get_node_or_null("%VersionLabel") as Label
	expect(label != null, "main scene has %VersionLabel")
	if label != null:
		expect(label.text.contains(Core.core_version()), "version label shows the core version")
	main.queue_free()
