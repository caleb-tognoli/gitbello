extends SmokeTest
## The Rust AppCore autoload is loaded, callable from GDScript, and emits signals.

var _pong_message: String = ""


func run() -> void:
	var core: AppCore = get_node_or_null("/root/Core") as AppCore
	expect(core != null, "Core autoload is an AppCore")
	if core == null:
		return

	expect(not core.core_version().is_empty(), "core_version() is not empty")

	core.pong.connect(_on_pong)
	core.ping("smoke")
	core.pong.disconnect(_on_pong)
	expect(_pong_message.contains("smoke"), "ping() emits pong with the greeting")
	expect(_pong_message.contains(core.core_version()), "greeting includes the core version")
	await get_tree().process_frame


func _on_pong(message: String) -> void:
	_pong_message = message
