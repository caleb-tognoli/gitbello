extends Node
## Saves screenshots of the logo in the app for visual review: the welcome
## screen and About, in the dark and light themes.
## Usage: godot --path godot res://tests/visual/branding_screenshots.tscn -- --out=<dir>
## Run with GITBELLO_CONFIG pointing at a scratch config file in an empty
## folder, so the library is empty and Home shows the welcome screen.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func _ready() -> void:
	var out: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	if out.is_empty():
		printerr("branding_screenshots: pass -- --out=<dir>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var step: int = 1
	for theme: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + theme))
		await _settle()
		_save(get_viewport(), out, "%02d-welcome_%s" % [step, theme])
		step += 1
		Actions.run_action(&"app.about")
		await _settle()
		_save(main.about_dialog(), out, "%02d-about_%s" % [step, theme])
		step += 1
		main.about_dialog().hide()
	Actions.run_action(&"view.theme_dark")
	get_tree().quit()


func _settle() -> void:
	for i: int in 30:
		await get_tree().process_frame


func _save(viewport: Viewport, dir: String, file_name: String) -> void:
	var path: String = dir.path_join(file_name + ".png")
	viewport.get_texture().get_image().save_png(path)
	print("SHOT ", path)
