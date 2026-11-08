extends Node
## Walks Settings → Keyboard (M7.11) in numbered shots, driven by input events
## sent to the windows: Ctrl+/ opens it, hovering a row and an unbound row,
## recording a shortcut, a conflict and Reassign, the filter, key search, the
## Changed filter, a folded section, Settings' search pointing at shortcuts,
## Reset All, then the page, a hovered row and a conflict in the light theme.
## Pass --out=<directory>; launch windowed with GITBELLO_CONFIG set to a
## scratch config (it saves shortcuts there). No repository is opened.

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _out: String = ""
var _step: int = 1
var _main: Main = null
var _settings: SettingsWindow = null
var _page: ShortcutsPage = null


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if _out.is_empty() or OS.get_environment("GITBELLO_CONFIG").is_empty():
		printerr("shortcuts_screenshots: pass --out and set GITBELLO_CONFIG to a scratch config")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_window().size = Vector2i(1200, 760)
	Actions.reset_all_shortcuts()
	Actions.run_action(&"view.theme_dark")
	_main = MAIN.instantiate() as Main
	add_child(_main)
	await _frames(10)
	_settings = _main.settings_window()
	_page = _settings.shortcuts

	_key("Ctrl+Slash", get_viewport())
	await _frames(5)
	if not _settings.visible:
		printerr("shortcuts_screenshots: Ctrl+/ did not open Settings")
		get_tree().quit(1)
		return
	await _shot("opened")

	await _hover(_row_label(&"sync.fetch"))
	await _shot("hover-row")
	await _hover(_row_label(&"app.about"))
	await _shot("hover-unbound-row")
	await _click(_chip(&"app.about"))
	await _shot("recording")
	_key("Ctrl+K")
	await _shot("conflict")
	await _click(_page.row(&"app.about").reassign as Control)
	await _shot("reassigned")

	await _click(_page.search.text_box())
	_type("fetch")
	await _shot("filter-text")
	_page.search.clear_filters()
	await _click(_page.key_search)
	await _shot("key-search-waiting")
	_key("Ctrl+B")
	await _shot("key-search-found")
	_key("Escape")
	await _click(_page.changed_filter)
	await _shot("changed-only")
	await _click(_page.changed_filter)
	await _click(_section_button("App"))
	await _shot("app-folded")
	await _click(_section_button("App"))

	await _click_item(_settings.categories, 0)
	await _click(_settings.search.text_box())
	_type("palette")
	await _shot("settings-search")
	await _click(_settings._shortcut_hits)
	await _shot("search-carried-over")
	_page.search.clear_filters()

	await _click(_page.reset_all)
	await _frames(10)
	await _shot("reset-confirm", _page._confirm)
	await _click(_page._confirm.get_ok_button(), _page._confirm)
	await _shot("after-reset")

	Actions.run_action(&"view.theme_light")
	await _shot("light")
	await _hover(_row_label(&"changes.commit"))
	await _shot("light-hover-row")
	await _hover(_row_label(&"app.about"))
	await _click(_chip(&"app.about"))
	_key("Ctrl+Shift+P")
	await _shot("light-conflict")
	_key("Escape")
	Actions.run_action(&"view.theme_dark")
	Actions.reset_all_shortcuts()
	get_tree().quit(0)


func _row_label(id: StringName) -> Control:
	var row: Dictionary = _page.row(id)
	_page._scroll.ensure_control_visible(row.panel as Control)
	return row.label as Control


func _chip(id: StringName) -> Control:
	return (_page.row(id).chips as HBoxContainer).get_child(0) as Control


func _section_button(category: String) -> Control:
	return _page._sections[category].button as Control


func _frames(count: int) -> void:
	for i: int in count:
		await get_tree().process_frame


## Moves the real pointer there (pushed motion alone does not put the mouse
## inside a separate window), then sends the motion too.
func _motion(at: Vector2, window: Viewport) -> void:
	window.warp_mouse(at)
	await _frames(3)
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	window.push_input(motion)


## Waits for a scroll to settle, then points at `control`.
func _hover(control: Control) -> void:
	await _frames(3)
	await _motion(control.get_global_rect().get_center(), _settings)


func _click(control: Control, window: Viewport = null) -> void:
	var target: Viewport = window if window != null else _settings
	await _frames(3)
	var at: Vector2 = control.get_global_rect().get_center()
	await _motion(at, target)
	for pressed: bool in [true, false]:
		var button: InputEventMouseButton = InputEventMouseButton.new()
		button.button_index = MOUSE_BUTTON_LEFT
		button.pressed = pressed
		button.position = at
		button.global_position = at
		target.push_input(button)


func _click_item(list: ItemList, index: int) -> void:
	var rect: Rect2 = list.get_item_rect(index)
	var at: Vector2 = list.get_global_rect().position + rect.get_center()
	await _motion(at, _settings)
	for pressed: bool in [true, false]:
		var button: InputEventMouseButton = InputEventMouseButton.new()
		button.button_index = MOUSE_BUTTON_LEFT
		button.pressed = pressed
		button.position = at
		button.global_position = at
		_settings.push_input(button)


func _key(shortcut: String, window: Viewport = null) -> void:
	var event: InputEventKey = Shortcuts.parse(shortcut)
	event.physical_keycode = event.keycode
	var target: Viewport = window if window != null else _settings
	target.push_input(event)
	var release: InputEventKey = event.duplicate() as InputEventKey
	release.pressed = false
	target.push_input(release)


func _type(text: String) -> void:
	for ch: String in text:
		var event: InputEventKey = InputEventKey.new()
		event.pressed = true
		event.unicode = ch.unicode_at(0)
		event.keycode = OS.find_keycode_from_string(ch.to_upper())
		_settings.push_input(event)


func _shot(file_name: String, window: Window = null) -> void:
	await _frames(20)
	var source: Window = window if window != null else _settings
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	source.get_texture().get_image().save_png(path)
	print("SHOT ", path)
	_step += 1
