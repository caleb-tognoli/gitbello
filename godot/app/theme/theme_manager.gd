class_name ThemeManager
extends RefCounted
## Picks light or dark (following the OS unless the user chose one), the
## accent colour and the UI scale for HiDPI screens (PLAN §3.7), and applies
## the theme `AppTheme` builds from them.

const BASE_DPI: float = 96.0

## Whether the theme applied last is the light one.
static var light: bool = false
## The accent colour of the theme applied last.
static var accent: Color = AppTheme.DEFAULT_ACCENT


## Whether `choice` (`system`, `light` or `dark`) means the light theme.
static func is_light(choice: String) -> bool:
	match choice:
		"light":
			return true
		"dark":
			return false
		_:
			return not DisplayServer.is_dark_mode()


## The configured accent colour, or the default one.
static func configured_accent() -> Color:
	var text: String = String(Core.settings().get("accent", ""))
	return Color.from_string(text, AppTheme.DEFAULT_ACCENT) if not text.is_empty() else AppTheme.DEFAULT_ACCENT


## Builds the configured theme into the project theme (an empty resource in
## project.godot), so every control and window uses it whatever its parents
## are (themes do not pass through plain Node parents), then tells them.
static func apply(root: Node) -> void:
	light = is_light(Core.theme_choice())
	accent = configured_accent()
	var project_theme: Theme = ThemeDB.get_project_theme()
	if project_theme == null:
		push_error("gui/theme/custom is not set: the theme cannot be applied")
		return
	project_theme.clear()
	project_theme.merge_with(AppTheme.build(light, accent))
	root.get_tree().root.propagate_notification(Control.NOTIFICATION_THEME_CHANGED)


## UI scale for the screen `window` is on: the OS scale on macOS, otherwise
## derived from the DPI, rounded to quarters and clamped to 1..3.
static func ui_scale(window: Window) -> float:
	var screen: int = window.current_screen
	var scale: float = DisplayServer.screen_get_scale(screen)
	if scale <= 1.0:
		var dpi: int = DisplayServer.screen_get_dpi(screen)
		scale = float(dpi) / BASE_DPI if dpi > 0 else 1.0
	return clampf(roundf(scale * 4.0) / 4.0, 1.0, 3.0)
