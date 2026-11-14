class_name ToggleChip
extends Button
## An on/off option in a pill (M7.15): an icon and a short label, outlined
## while off and filled with the accent while on. Give it a white icon
## (`AppTheme.tintable_icon`) so the theme's icon colours apply as they are.
## `tint` colours the icon while off, such as a file status's colour.
## Styles are the `ToggleChip` theme type.

const THEME_TYPE: StringName = &"ToggleChip"
const OFF_ICON_COLORS: Array[StringName] = [&"icon_normal_color", &"icon_hover_color", &"icon_focus_color"]

## The icon's colour while off; transparent keeps the theme's.
var tint: Color = Color.TRANSPARENT:
	set(value):
		tint = value
		for color: StringName in OFF_ICON_COLORS:
			if tint.a > 0.0:
				add_theme_color_override(color, tint)
			else:
				remove_theme_color_override(color)


func _init() -> void:
	toggle_mode = true
	focus_mode = Control.FOCUS_ALL
	theme_type_variation = THEME_TYPE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
