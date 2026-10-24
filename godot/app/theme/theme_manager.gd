class_name ThemeManager
extends RefCounted
## Picks light or dark (following the OS unless the user chose one) and the UI
## scale for HiDPI screens (PLAN §3.7).

const DARK: Theme = preload("res://themes/dark.tres")
const LIGHT: Theme = preload("res://themes/light.tres")

const BASE_DPI: float = 96.0


## `system`, `light` or `dark` to a theme.
static func theme_for(choice: String) -> Theme:
	match choice:
		"light":
			return LIGHT
		"dark":
			return DARK
		_:
			return DARK if DisplayServer.is_dark_mode() else LIGHT


## Applies the configured theme to `root` and its window. Themes do not pass
## through plain Node parents, so the root control gets it directly too.
static func apply(root: Control) -> void:
	var theme: Theme = theme_for(Core.theme_choice())
	root.theme = theme
	root.get_window().theme = theme


## UI scale for the screen `window` is on: the OS scale on macOS, otherwise
## derived from the DPI, rounded to quarters and clamped to 1..3.
static func ui_scale(window: Window) -> float:
	var screen: int = window.current_screen
	var scale: float = DisplayServer.screen_get_scale(screen)
	if scale <= 1.0:
		var dpi: int = DisplayServer.screen_get_dpi(screen)
		scale = float(dpi) / BASE_DPI if dpi > 0 else 1.0
	return clampf(roundf(scale * 4.0) / 4.0, 1.0, 3.0)
