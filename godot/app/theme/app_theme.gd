class_name AppTheme
extends RefCounted
## Builds the interface theme from a light or dark palette and an accent
## colour (PLAN §3.7), in the style of spritesheetbelli: chrome on a surface
## colour, lists and content sunk into the background, raised buttons and
## fields. Icons are Godot editor SVGs drawn for dark backgrounds; the light
## theme swaps their greys for darker ones (see `LIGHT_ICON_COLORS`).

const DEFAULT_ACCENT: Color = Color("4c9cff")
## The swatches offered in Settings, the default first.
const ACCENT_PRESETS: Array[Color] = [
	Color("4c9cff"), Color("2bb3a8"), Color("5cb85c"), Color("f0a030"),
	Color("ef6b5b"), Color("e0569a"), Color("9d7bff"),
]
const DARK_TEXT: Color = Color("e6e7ea")
const LIGHT_TEXT: Color = Color("1f2329")
## How readable text on selected rows is at least, as a contrast ratio
## (WCAG's AA level for text).
const MIN_CONTRAST: float = 4.5
## Every SVG in here is imported as a DPITexture and recoloured with the theme.
const ICON_DIR: String = "res://themes/icons"
## Icon colours in the light theme, from the Godot editor's
## (editor_color_map.cpp).
const LIGHT_ICON_COLORS: Dictionary[String, String] = {
	"#e0e0e0": "#5a5a5a",  # Common icon colour
	"#ffffff": "#414141",
	"#000000": "#bfbfbf",
	"#808080": "#808080",
	"#b3b3b3": "#363636",
	"#f9f9f9": "#606060",
	"#d6d6d6": "#474747",
	"#474747": "#d6d6d6",
	"#919191": "#6e6e6e",
}
## Icons that keep their colours in the light theme. The file status icons
## are white and tinted with their status colour where drawn.
const ICON_EXCEPTIONS: Array[StringName] = [&"StatusWarning", &"StatusSuccess",
	&"FileAdded", &"FileModified", &"FileDeleted", &"FileRenamed", &"FileConflict"]
## The common icon grey in each theme, to turn pressed icons into the accent.
const DARK_ICON_GREY: Color = Color("e0e0e0")
const LIGHT_ICON_GREY: Color = Color("5a5a5a")
const ARROW_DOWN: Texture2D = preload("res://themes/icons/GuiTreeArrowDown.svg")
const ARROW_RIGHT: Texture2D = preload("res://themes/icons/GuiTreeArrowRight.svg")
const CLOSE: Texture2D = preload("res://themes/icons/Close.svg")
## Frames of the busy spinner (see `spinner`).
const SPINNER_FRAMES: int = 8
## Monospace fonts tried in order (the first one installed wins).
const MONO_FONTS: PackedStringArray = [
	"JetBrains Mono", "Cascadia Mono", "Consolas", "SF Mono", "Menlo",
	"DejaVu Sans Mono", "Liberation Mono", "monospace",
]

## The icons recoloured so far, kept loaded so that they stay recoloured.
static var _icons: Dictionary[String, DPITexture] = {}
## The swatches made so far, by colour (see `swatch`).
static var _swatches: Dictionary[Color, DPITexture] = {}
## Spinner frames by `(frame, light)` and dots by colour (see `spinner`, `dot`).
static var _spinners: Dictionary[Vector2i, DPITexture] = {}
static var _dots: Dictionary[Color, DPITexture] = {}


class Palette:
	var light: bool
	var background: Color  ## Window, lists and content
	var surface: Color  ## Toolbars, sidebar, status bar, menus, dialogs
	var raised: Color  ## Buttons and fields
	var hover: Color
	var border: Color
	var text: Color
	var text_muted: Color
	var accent: Color
	var accent_text: Color  ## Text in the accent colour
	var error: Color
	## How strongly rows and scroll bars are shaded with the text colour.
	var shade: float
	var hovered: Color  ## Over hovered rows, selected or not
	var selected: Color  ## Selected rows while the list is not focused
	var selected_focus: Color
	var selected_text: Color  ## Readable on both selections
	var head: Color  ## The checked-out branch
	var lanes: Array[Color]
	var label_head: Color
	var label_branch: Color
	var label_remote: Color
	var label_tag: Color
	var added: Color
	var removed: Color
	var modified: Color
	var renamed: Color
	var syntax_keyword: Color
	var syntax_type: Color
	var syntax_string: Color
	var syntax_number: Color


static func palette(light: bool, accent: Color = DEFAULT_ACCENT) -> Palette:
	var p: Palette = Palette.new()
	p.light = light
	p.accent = accent
	if light:
		p.background = Color("e9eaee")
		p.surface = Color("f6f7f9")
		p.raised = Color("ffffff")
		p.hover = Color("e2e5eb")
		p.border = Color("c9cdd6")
		p.text = LIGHT_TEXT
		p.text_muted = Color("5d6470")
		p.accent_text = accent.darkened(0.35)
		p.error = Color("c43d2b")
		p.shade = 0.6
		p.selected = p.background.blend(Color(accent, 0.3))
		p.selected_focus = p.background.blend(Color(accent, 0.45))
		p.head = Color(0.1, 0.5, 0.22)
		p.lanes = [
			Color(0.13, 0.42, 0.85), Color(0.12, 0.6, 0.25), Color(0.88, 0.45, 0.05),
			Color(0.52, 0.3, 0.86), Color(0.85, 0.2, 0.27), Color(0.05, 0.6, 0.62),
			Color(0.72, 0.58, 0.05), Color(0.85, 0.28, 0.6),
		]
		p.label_head = Color(0.16, 0.52, 0.27)
		p.label_branch = Color(0.2, 0.42, 0.78)
		p.label_remote = Color(0.42, 0.45, 0.52)
		p.label_tag = Color(0.62, 0.45, 0.06)
		p.added = Color(0.1, 0.55, 0.2)
		p.removed = Color(0.78, 0.16, 0.16)
		p.modified = Color(0.7, 0.45, 0.0)
		p.renamed = Color(0.13, 0.4, 0.85)
		p.syntax_keyword = Color(0.55, 0.2, 0.7)
		p.syntax_type = Color(0.0, 0.45, 0.55)
		p.syntax_string = Color(0.15, 0.5, 0.1)
		p.syntax_number = Color(0.7, 0.35, 0.0)
	else:
		p.background = Color("1b1c1f")
		p.surface = Color("25262a")
		p.raised = Color("31333a")
		p.hover = Color("3b3e46")
		p.border = Color("454852")
		p.text = DARK_TEXT
		p.text_muted = Color("9da2ad")
		p.accent_text = accent.lightened(0.45)
		p.error = Color(1.0, 0.55, 0.45)
		p.shade = 1.0
		p.selected = p.background.blend(Color(accent, 0.4))
		p.selected_focus = p.background.blend(Color(accent, 0.6))
		p.head = Color(0.45, 0.8, 0.55)
		p.lanes = [
			Color(0.3, 0.6, 1.0), Color(0.36, 0.8, 0.45), Color(1.0, 0.62, 0.25),
			Color(0.7, 0.5, 1.0), Color(0.95, 0.38, 0.42), Color(0.25, 0.8, 0.8),
			Color(0.92, 0.8, 0.3), Color(0.95, 0.5, 0.75),
		]
		p.label_head = Color(0.22, 0.47, 0.3)
		p.label_branch = Color(0.22, 0.36, 0.6)
		p.label_remote = Color(0.3, 0.31, 0.36)
		p.label_tag = Color(0.5, 0.4, 0.18)
		p.added = Color(0.45, 0.8, 0.5)
		p.removed = Color(0.95, 0.45, 0.45)
		p.modified = Color(0.9, 0.72, 0.35)
		p.renamed = Color(0.45, 0.7, 1.0)
		p.syntax_keyword = Color(0.78, 0.55, 0.95)
		p.syntax_type = Color(0.4, 0.78, 0.85)
		p.syntax_string = Color(0.6, 0.82, 0.5)
		p.syntax_number = Color(0.95, 0.65, 0.4)
	p.hovered = Color(p.text, 0.07 * p.shade)
	# Ref labels carry light text in both themes, darkened until it reads.
	p.label_head = _readable_under(DARK_TEXT, p.label_head, Color.TRANSPARENT)
	p.label_branch = _readable_under(DARK_TEXT, p.label_branch, Color.TRANSPARENT)
	p.label_remote = _readable_under(DARK_TEXT, p.label_remote, Color.TRANSPARENT)
	p.label_tag = _readable_under(DARK_TEXT, p.label_tag, Color.TRANSPARENT)
	p.selected_text = readable_text(
			[p.selected, p.selected_focus, p.selected.blend(p.hovered), p.selected_focus.blend(p.hovered)],
			p.text)
	p.selected = _readable_under(p.selected_text, p.selected, p.hovered)
	p.selected_focus = _readable_under(p.selected_text, p.selected_focus, p.hovered)
	return p


## The text colour most readable on every one of `backgrounds`: `text`, or the
## other theme's when it stands out more (a very light accent in the dark theme).
static func readable_text(backgrounds: Array[Color], text: Color) -> Color:
	var best: Color = text
	var best_contrast: float = 0.0
	for candidate: Color in [text, LIGHT_TEXT if text == DARK_TEXT else DARK_TEXT]:
		var contrast: float = INF
		for background: Color in backgrounds:
			contrast = minf(contrast, contrast_ratio(candidate, background))
		if contrast > best_contrast:
			best = candidate
			best_contrast = contrast
	return best


## The WCAG contrast ratio of two opaque colours, from 1 (the same) to 21.
static func contrast_ratio(a: Color, b: Color) -> float:
	var la: float = a.srgb_to_linear().get_luminance()
	var lb: float = b.srgb_to_linear().get_luminance()
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


## `background` darkened under light `text` or lightened under dark text, as
## little as it takes to reach `MIN_CONTRAST`, also when shaded as `hovered`.
static func _readable_under(text: Color, background: Color, hovered: Color) -> Color:
	var darken: bool = text.get_luminance() > 0.5
	for i: int in 30:
		var contrast: float = minf(contrast_ratio(text, background),
				contrast_ratio(text, background.blend(hovered)))
		if contrast >= MIN_CONTRAST:
			break
		background = background.darkened(0.05) if darken else background.lightened(0.05)
	return background


static func build(light: bool, accent: Color = DEFAULT_ACCENT) -> Theme:
	var p: Palette = palette(light, accent)
	recolor_icons(light)
	var theme: Theme = Theme.new()
	theme.default_font_size = 14
	_add_panels(theme, p)
	var focus: StyleBoxFlat = _box(Color.TRANSPARENT, 4, Vector4.ZERO, p.accent, 1)
	_add_buttons(theme, p, focus)
	_add_fields(theme, p)
	_add_menus(theme, p)
	_add_lists(theme, p, focus)
	_add_tabs(theme, p)
	_add_shell(theme, p)
	_add_history(theme, p)
	_add_changes(theme, p)
	_add_shell_p2(theme, p)
	_add_changes_p3(theme, p)
	return theme


static func _add_panels(theme: Theme, p: Palette) -> void:
	theme.set_stylebox(&"panel", &"Panel", _box(p.background))
	theme.set_stylebox(&"panel", &"PanelContainer", _box(p.background))
	theme.set_color(&"font_color", &"Label", p.text)
	theme.set_color(&"default_color", &"RichTextLabel", p.text)
	theme.set_color(&"selection_color", &"RichTextLabel", Color(p.accent, 0.35))
	theme.set_stylebox(&"focus", &"RichTextLabel", StyleBoxEmpty.new())
	var separator: StyleBoxLine = StyleBoxLine.new()
	separator.color = p.border
	theme.set_stylebox(&"separator", &"HSeparator", separator)
	var vseparator: StyleBoxLine = StyleBoxLine.new()
	vseparator.color = p.border
	vseparator.vertical = true
	theme.set_stylebox(&"separator", &"VSeparator", vseparator)
	for type: StringName in [&"HSplitContainer", &"VSplitContainer"]:
		var split: StyleBoxLine = StyleBoxLine.new()
		split.color = p.border
		split.vertical = type == &"HSplitContainer"
		theme.set_stylebox(&"split_bar_background", type, split)
		theme.set_constant(&"separation", type, 5)
		theme.set_constant(&"autohide", type, 0)
	theme.set_stylebox(&"background", &"ProgressBar", _box(p.raised, 3, Vector4(0, 3, 0, 3)))
	theme.set_stylebox(&"fill", &"ProgressBar", _box(p.accent, 3))
	theme.set_color(&"font_color", &"ProgressBar", p.text)
	for dialog: StringName in [&"AcceptDialog", &"ConfirmationDialog"]:
		theme.set_stylebox(&"panel", dialog, _box(p.surface, 0, Vector4(12, 12, 12, 12)))
	theme.set_constant(&"buttons_min_width", &"AcceptDialog", 90)
	theme.set_stylebox(&"panel", &"PopupPanel", _box(p.surface, 6, Vector4(12, 10, 12, 10), p.border, 1))
	theme.set_stylebox(&"panel", &"TooltipPanel", _box(p.raised, 4, Vector4(8, 6, 8, 6), p.border, 1))
	theme.set_color(&"font_color", &"TooltipLabel", p.text)
	# Labels
	_variation(theme, &"DimLabel", &"Label")
	theme.set_color(&"font_color", &"DimLabel", p.text_muted)
	_variation(theme, &"HeaderLabel", &"Label")
	theme.set_font_size(&"font_size", &"HeaderLabel", 28)
	_variation(theme, &"SectionHeader", &"Label")
	theme.set_color(&"font_color", &"SectionHeader", p.text_muted)
	theme.set_font_size(&"font_size", &"SectionHeader", 12)
	theme.set_stylebox(&"normal", &"SectionHeader", _box(Color.TRANSPARENT, 0, Vector4(8, 4, 8, 2)))
	_variation(theme, &"ErrorLabel", &"Label")
	theme.set_color(&"font_color", &"ErrorLabel", p.error)
	_variation(theme, &"AccentLabel", &"Label")
	theme.set_color(&"font_color", &"AccentLabel", p.accent_text)
	for color: StringName in [&"font_color", &"font_hover_color", &"font_pressed_color",
			&"font_focus_color", &"font_hover_pressed_color"]:
		theme.set_color(color, &"LinkButton", p.accent_text)


## Buttons and everything drawn like them. Icons keep their own colours;
## pressed ones take the accent colour, the same in both themes although the
## light theme's icons are darker.
static func _add_buttons(theme: Theme, p: Palette, focus: StyleBox) -> void:
	var margins: Vector4 = Vector4(10, 4, 10, 4)
	var normal: StyleBoxFlat = _box(p.raised, 4, margins)
	var hover: StyleBoxFlat = _box(p.hover, 4, margins)
	var pressed: StyleBoxFlat = _box(Color(p.accent, 0.35), 4, margins)
	var disabled: StyleBoxFlat = _box(Color(p.raised, 0.5), 4, margins)
	# Same margins as the others so the text doesn't move when hovered
	var flat: StyleBoxEmpty = StyleBoxEmpty.new()
	flat.content_margin_left = margins.x
	flat.content_margin_top = margins.y
	flat.content_margin_right = margins.z
	flat.content_margin_bottom = margins.w
	var icon_grey: Color = LIGHT_ICON_GREY if p.light else DARK_ICON_GREY
	var icon_pressed: Color = p.accent * DARK_ICON_GREY / icon_grey
	icon_pressed.a = 1.0
	var icon_disabled: Color = Color(1, 1, 1, 0.55 if p.light else 0.4)
	for type: StringName in [&"Button", &"MenuButton", &"OptionButton", &"CheckBox", &"CheckButton"]:
		var is_flat: bool = type in [&"MenuButton", &"CheckBox", &"CheckButton"]
		theme.set_stylebox(&"normal", type, (flat as StyleBox) if is_flat else (normal as StyleBox))
		theme.set_stylebox(&"hover", type, hover)
		theme.set_stylebox(&"pressed", type, pressed)
		theme.set_stylebox(&"hover_pressed", type, pressed)
		theme.set_stylebox(&"disabled", type, (flat as StyleBox) if is_flat else (disabled as StyleBox))
		theme.set_stylebox(&"focus", type, focus)
		theme.set_constant(&"h_separation", type, 6)
		for color: StringName in [&"font_color", &"font_hover_color", &"font_focus_color",
				&"font_pressed_color", &"font_hover_pressed_color"]:
			theme.set_color(color, type, p.text)
		theme.set_color(&"font_disabled_color", type, Color(p.text_muted, 0.6))
		for color: StringName in [&"icon_normal_color", &"icon_hover_color", &"icon_focus_color"]:
			theme.set_color(color, type, Color.WHITE)
		theme.set_color(&"icon_pressed_color", type, icon_pressed)
		theme.set_color(&"icon_hover_pressed_color", type, icon_pressed)
		theme.set_color(&"icon_disabled_color", type, icon_disabled)
	# Check boxes stay subtle when on
	for type: StringName in [&"CheckBox", &"CheckButton"]:
		theme.set_stylebox(&"pressed", type, flat)
		theme.set_stylebox(&"hover_pressed", type, hover)
	theme.set_color(&"checkbox_checked_color", &"CheckBox", p.accent)
	theme.set_color(&"checkbox_unchecked_color", &"CheckBox", p.text_muted)
	theme.set_color(&"button_checked_color", &"CheckButton", p.accent)
	theme.set_color(&"button_unchecked_color", &"CheckButton", p.text_muted)
	theme.set_icon(&"arrow", &"OptionButton", ARROW_DOWN)
	# Flat until hovered or pressed, like Godot's toolbar buttons
	_variation(theme, &"ToolbarButton", &"Button")
	var tool: Vector4 = Vector4(6, 4, 6, 4)
	theme.set_stylebox(&"normal", &"ToolbarButton", _box(Color.TRANSPARENT, 4, tool))
	theme.set_stylebox(&"hover", &"ToolbarButton", _box(p.hover, 4, tool))
	theme.set_stylebox(&"pressed", &"ToolbarButton", _box(Color(p.accent, 0.25), 4, tool))
	theme.set_stylebox(&"hover_pressed", &"ToolbarButton", _box(Color(p.accent, 0.35), 4, tool))
	theme.set_stylebox(&"disabled", &"ToolbarButton", _box(Color.TRANSPARENT, 4, tool))
	# The main button of a dialog or form, in the accent colour
	_variation(theme, &"PrimaryButton", &"Button")
	var accent_text: Color = readable_text([p.accent, p.accent.lightened(0.08), p.accent.darkened(0.1)], p.text)
	theme.set_stylebox(&"normal", &"PrimaryButton", _box(p.accent, 4, margins))
	theme.set_stylebox(&"hover", &"PrimaryButton", _box(p.accent.lightened(0.08), 4, margins))
	theme.set_stylebox(&"pressed", &"PrimaryButton", _box(p.accent.darkened(0.1), 4, margins))
	theme.set_stylebox(&"hover_pressed", &"PrimaryButton", _box(p.accent.darkened(0.1), 4, margins))
	theme.set_stylebox(&"focus", &"PrimaryButton", _box(Color.TRANSPARENT, 4, Vector4.ZERO, accent_text, 1))
	for color: StringName in [&"font_color", &"font_hover_color", &"font_focus_color",
			&"font_pressed_color", &"font_hover_pressed_color"]:
		theme.set_color(color, &"PrimaryButton", accent_text)


## Text fields: raised, outlined, in the accent colour while focused.
static func _add_fields(theme: Theme, p: Palette) -> void:
	var margins: Vector4 = Vector4(8, 5, 8, 5)
	var field: StyleBoxFlat = _box(p.raised, 4, margins, p.border, 1)
	var field_focus: StyleBoxFlat = _box(p.raised, 4, margins, p.accent, 1)
	var read_only: StyleBoxFlat = _box(Color(p.raised, 0.5), 4, margins, p.border, 1)
	for type: StringName in [&"LineEdit", &"TextEdit"]:
		theme.set_stylebox(&"normal", type, field)
		theme.set_stylebox(&"focus", type, field_focus)
		theme.set_stylebox(&"read_only", type, read_only)
		theme.set_color(&"font_color", type, p.text)
		theme.set_color(&"font_placeholder_color", type, Color(p.text_muted, 0.7))
		theme.set_color(&"caret_color", type, p.text)
		theme.set_color(&"selection_color", type, Color(p.accent, 0.35))
		theme.set_color(&"font_selected_color", type, p.text)
	theme.set_color(&"font_uneditable_color", &"LineEdit", Color(p.text_muted, 0.7))
	theme.set_color(&"clear_button_color", &"LineEdit", p.text_muted)
	theme.set_color(&"clear_button_color_pressed", &"LineEdit", p.accent)
	theme.set_color(&"font_readonly_color", &"TextEdit", p.text)
	_variation(theme, &"ErrorOutput", &"TextEdit")
	theme.set_color(&"font_readonly_color", &"ErrorOutput", p.error)
	theme.set_font(&"font", &"ErrorOutput", mono_font())
	theme.set_font_size(&"font_size", &"ErrorOutput", 12)


static func _add_menus(theme: Theme, p: Palette) -> void:
	for color: StringName in [&"font_color", &"font_hover_color", &"font_pressed_color",
			&"font_hover_pressed_color", &"font_focus_color"]:
		theme.set_color(color, &"MenuBar", p.text)
	theme.set_color(&"font_disabled_color", &"MenuBar", Color(p.text_muted, 0.6))
	var item: Vector4 = Vector4(8, 4, 8, 4)
	theme.set_stylebox(&"normal", &"MenuBar", _box(Color.TRANSPARENT, 4, item))
	theme.set_stylebox(&"disabled", &"MenuBar", _box(Color.TRANSPARENT, 4, item))
	theme.set_stylebox(&"hover", &"MenuBar", _box(p.hover, 4, item))
	theme.set_stylebox(&"pressed", &"MenuBar", _box(p.hover, 4, item))
	theme.set_stylebox(&"panel", &"PopupMenu", _box(p.surface, 6, Vector4(4, 4, 4, 4), p.border, 1))
	theme.set_stylebox(&"hover", &"PopupMenu", _box(Color(p.accent, 0.3), 4))
	theme.set_color(&"font_color", &"PopupMenu", p.text)
	theme.set_color(&"font_hover_color", &"PopupMenu", p.text)
	theme.set_color(&"font_disabled_color", &"PopupMenu", Color(p.text_muted, 0.6))
	theme.set_color(&"font_accelerator_color", &"PopupMenu", p.text_muted)
	theme.set_color(&"font_separator_color", &"PopupMenu", p.text_muted)
	var defaults: Theme = ThemeDB.get_default_theme()
	for style: StringName in [&"separator", &"labeled_separator_left", &"labeled_separator_right"]:
		var line: StyleBoxLine = defaults.get_stylebox(style, &"PopupMenu").duplicate() as StyleBoxLine
		if line != null:
			line.color = p.border
			theme.set_stylebox(style, &"PopupMenu", line)
	theme.set_icon(&"submenu", &"PopupMenu", ARROW_RIGHT)


## Trees and item lists: sunk into the background, rows shaded with the text
## colour when hovered and in the accent colour when selected.
static func _add_lists(theme: Theme, p: Palette, focus: StyleBox) -> void:
	var margins: Vector4 = Vector4(4, 3, 4, 3)
	var hovered: StyleBoxFlat = _box(p.hovered, 3, margins)
	var cursor: StyleBoxFlat = _box(Color.TRANSPARENT, 3, margins, p.text_muted, 1)
	for type: StringName in [&"Tree", &"ItemList"]:
		theme.set_stylebox(&"panel", type, _box(p.background, 0, Vector4(4, 4, 4, 4)))
		theme.set_stylebox(&"focus", type, StyleBoxEmpty.new())
		theme.set_stylebox(&"hovered", type, hovered)
		theme.set_stylebox(&"selected", type, _box(p.selected, 3, margins))
		theme.set_stylebox(&"selected_focus", type, _box(p.selected_focus, 3, margins))
		theme.set_stylebox(&"hovered_selected", type, _box(p.selected.blend(p.hovered), 3, margins))
		theme.set_stylebox(&"hovered_selected_focus", type, _box(p.selected_focus.blend(p.hovered), 3, margins))
		theme.set_stylebox(&"cursor", type, cursor)
		theme.set_stylebox(&"cursor_unfocused", type, StyleBoxEmpty.new())
		theme.set_color(&"font_color", type, p.text)
		theme.set_color(&"font_hovered_color", type, p.text)
		theme.set_color(&"font_selected_color", type, p.selected_text)
		theme.set_color(&"font_hovered_selected_color", type, p.selected_text)
		theme.set_color(&"guide_color", type, Color(p.text, 0.0))
	theme.set_stylebox(&"hovered_dimmed", &"Tree", _box(Color(p.text, 0.03 * p.shade), 3, margins))
	theme.set_stylebox(&"button_hover", &"Tree", hovered)
	theme.set_stylebox(&"button_pressed", &"Tree", _box(Color(p.text, 0.3 * p.shade), 3, margins))
	for state: StringName in [&"title_button_normal", &"title_button_hover", &"title_button_pressed"]:
		var title: StyleBoxFlat = _box(p.surface, 0, Vector4(6, 3, 6, 3))
		title.border_color = p.border
		title.border_width_bottom = 1
		if state != &"title_button_normal":
			title.bg_color = p.hover
		theme.set_stylebox(state, &"Tree", title)
	theme.set_color(&"title_button_color", &"Tree", p.text_muted)
	theme.set_color(&"font_disabled_color", &"Tree", Color(p.text_muted, 0.6))
	theme.set_color(&"drop_position_color", &"Tree", p.accent)
	for color: StringName in [&"relationship_line_color", &"parent_hl_line_color", &"children_hl_line_color"]:
		theme.set_color(color, &"Tree", Color(p.border, 0.0))
	theme.set_constant(&"v_separation", &"Tree", 2)
	theme.set_constant(&"item_margin", &"Tree", 14)
	theme.set_constant(&"inner_item_margin_left", &"Tree", 4)
	theme.set_constant(&"inner_item_margin_right", &"Tree", 6)
	theme.set_icon(&"arrow", &"Tree", ARROW_DOWN)
	theme.set_icon(&"arrow_collapsed", &"Tree", ARROW_RIGHT)
	theme.set_constant(&"v_separation", &"ItemList", 4)
	# Scroll bars keep Godot's shapes, in the palette's colours
	var defaults: Theme = ThemeDB.get_default_theme()
	for type: StringName in [&"HScrollBar", &"VScrollBar"]:
		for entry: Array in [
			[&"scroll", Color(p.background, 0.6)],
			[&"grabber", Color(p.text, 0.3 * p.shade)],
			[&"grabber_highlight", Color(p.text, 0.55 * p.shade)],
			[&"grabber_pressed", Color(p.text_muted, 0.75)],
		]:
			var box: StyleBoxFlat = defaults.get_stylebox(entry[0], type).duplicate() as StyleBoxFlat
			if box != null:
				box.bg_color = entry[1]
				theme.set_stylebox(entry[0], type, box)


## The repo tabs on a strip of the window's background. The active one is the
## colour of the toolbar under it, which it joins, with the accent along its
## top (like the Godot editor's scene tabs).
static func _add_tabs(theme: Theme, p: Palette) -> void:
	_variation(theme, &"TabStrip", &"PanelContainer")
	theme.set_stylebox(&"panel", &"TabStrip", _box(p.background, 0, Vector4(4, 4, 4, 0)))
	var tab: Callable = func(color: Color, top: Color) -> StyleBoxFlat:
		var box: StyleBoxFlat = _box(color, 0, Vector4(12, 6, 8, 6))
		box.corner_radius_top_left = 4
		box.corner_radius_top_right = 4
		box.border_color = top
		box.border_width_top = 2
		return box
	theme.set_stylebox(&"tab_selected", &"TabBar", tab.call(p.surface, p.accent))
	theme.set_stylebox(&"tab_unselected", &"TabBar", tab.call(Color.TRANSPARENT, Color.TRANSPARENT))
	theme.set_stylebox(&"tab_hovered", &"TabBar", tab.call(Color(p.surface, 0.5), Color.TRANSPARENT))
	theme.set_stylebox(&"tab_disabled", &"TabBar", tab.call(Color.TRANSPARENT, Color.TRANSPARENT))
	theme.set_stylebox(&"tab_focus", &"TabBar", StyleBoxEmpty.new())
	theme.set_stylebox(&"button_pressed", &"TabBar", _box(Color(p.text, 0.25 * p.shade), 3))
	theme.set_stylebox(&"button_highlight", &"TabBar", _box(Color(p.text, 0.15 * p.shade), 3))
	theme.set_color(&"font_color", &"TabBar", p.text)
	theme.set_color(&"font_selected_color", &"TabBar", p.text)
	theme.set_color(&"font_hovered_color", &"TabBar", p.text)
	theme.set_color(&"font_unselected_color", &"TabBar", p.text_muted)
	theme.set_color(&"font_disabled_color", &"TabBar", Color(p.text_muted, 0.6))
	theme.set_color(&"drop_mark_color", &"TabBar", p.accent)
	theme.set_constant(&"h_separation", &"TabBar", 6)
	theme.set_icon(&"close", &"TabBar", CLOSE)


## The shell around the repo views: status bar, welcome screen, palette,
## toasts, sidebar, git log, jobs and forms.
static func _add_shell(theme: Theme, p: Palette) -> void:
	_variation(theme, &"ShellLayout", &"VBoxContainer")
	theme.set_constant(&"separation", &"ShellLayout", 0)
	theme.set_constant(&"max_tab_width", &"Shell", 320)
	_variation(theme, &"ViewBar", &"PanelContainer")
	var bar: StyleBoxFlat = _box(p.surface, 0, Vector4(8, 5, 8, 5))
	bar.border_color = p.border
	bar.border_width_bottom = 1
	theme.set_stylebox(&"panel", &"ViewBar", bar)
	_variation(theme, &"ViewSwitch", &"HBoxContainer")
	theme.set_constant(&"separation", &"ViewSwitch", 4)
	_variation(theme, &"StatusBar", &"PanelContainer")
	var status: StyleBoxFlat = _box(p.surface, 0, Vector4(8, 3, 8, 3))
	status.border_color = p.border
	status.border_width_top = 1
	theme.set_stylebox(&"panel", &"StatusBar", status)
	_variation(theme, &"WelcomeBox", &"VBoxContainer")
	theme.set_constant(&"separation", &"WelcomeBox", 14)
	_variation(theme, &"RecentList", &"ItemList")
	theme.set_stylebox(&"panel", &"RecentList", _box(p.surface, 6, Vector4(6, 6, 6, 6), p.border, 1))
	_variation(theme, &"PalettePanel", &"PanelContainer")
	theme.set_stylebox(&"panel", &"PalettePanel", _box(p.surface, 6, Vector4(8, 8, 8, 8), p.border, 1))
	theme.set_constant(&"width", &"CommandPalette", 640)
	theme.set_constant(&"height", &"CommandPalette", 380)
	theme.set_constant(&"top", &"CommandPalette", 56)
	# Toasts report problems (M6.5 P2 adds other kinds): raised, with the error
	# colour along their left edge.
	_variation(theme, &"ToastPanel", &"PanelContainer")
	var toast: StyleBoxFlat = _box(p.raised, 6, Vector4(14, 8, 8, 8), p.border, 1)
	toast.border_color = p.error
	toast.border_width_left = 3
	toast.shadow_color = Color(0, 0, 0, 0.25 if p.light else 0.4)
	toast.shadow_size = 6
	theme.set_stylebox(&"panel", &"ToastPanel", toast)
	theme.set_constant(&"seconds", &"Toasts", 6)
	theme.set_constant(&"width", &"Toasts", 380)
	_variation(theme, &"SidebarTree", &"Tree")
	theme.set_stylebox(&"panel", &"SidebarTree", _box(p.surface, 0, Vector4(4, 6, 4, 6)))
	_variation(theme, &"SidebarSplit", &"HSplitContainer")
	theme.set_color(&"section_color", &"RepoSidebar", p.text_muted)
	theme.set_color(&"badge_color", &"RepoSidebar", p.text_muted)
	theme.set_color(&"head_color", &"RepoSidebar", p.head)
	theme.set_constant(&"width", &"RepoSidebar", 260)
	theme.set_constant(&"badge_width", &"RepoSidebar", 72)
	theme.set_color(&"error_color", &"GitLogPanel", p.error)
	theme.set_constant(&"time_width", &"GitLogPanel", 100)
	theme.set_constant(&"repo_width", &"GitLogPanel", 140)
	theme.set_constant(&"result_width", &"GitLogPanel", 150)
	theme.set_constant(&"height", &"GitLogPanel", 200)
	theme.set_constant(&"progress_width", &"JobsBar", 140)
	theme.set_constant(&"label_width", &"JobsBar", 380)
	theme.set_constant(&"separation", &"JobsBar", 8)
	theme.set_constant(&"width", &"FormDialog", 560)
	theme.set_constant(&"label_width", &"FormDialog", 140)
	theme.set_constant(&"text_height", &"FormDialog", 90)
	theme.set_constant(&"note_width", &"FormDialog", 380)
	theme.set_constant(&"separation", &"FormDialog", 8)
	theme.set_constant(&"section_separation", &"FormDialog", 14)


static func _add_history(theme: Theme, p: Palette) -> void:
	theme.set_color(&"selection_color", &"VirtualList", p.selected_focus)
	theme.set_color(&"cursor_color", &"VirtualList", Color(p.accent, 0.9))
	theme.set_constant(&"row_height", &"VirtualList", 24)
	for i: int in p.lanes.size():
		theme.set_color(StringName("lane_%d" % i), &"GraphView", p.lanes[i])
	theme.set_color(&"node_outline", &"GraphView", p.background)
	theme.set_constant(&"lane_width", &"GraphView", 14)
	theme.set_constant(&"line_width", &"GraphView", 2)
	theme.set_constant(&"max_lanes", &"GraphView", 24)
	theme.set_constant(&"node_radius", &"GraphView", 4)
	theme.set_color(&"subject_color", &"CommitList", p.text)
	theme.set_constant(&"padding", &"CommitList", 8)
	theme.set_constant(&"label_gap", &"CommitList", 4)
	theme.set_font_size(&"label_font_size", &"CommitList", 12)
	theme.set_color(&"label_color", &"CommitList", DARK_TEXT)
	for entry: Array in [[&"head", p.label_head], [&"branch", p.label_branch],
			[&"remote", p.label_remote], [&"tag", p.label_tag]]:
		theme.set_stylebox(StringName("label_%s" % entry[0]), &"CommitList",
				_box(entry[1], 3, Vector4(6, 1, 6, 1)))
	_add_commit_details(theme, p)


## The commit details, from most to least prominent: the summary, who and
## when, the hashes, then the message.
static func _add_commit_details(theme: Theme, p: Palette) -> void:
	_variation(theme, &"DetailsInfo", &"VBoxContainer")
	theme.set_constant(&"separation", &"DetailsInfo", 8)
	_variation(theme, &"CommitSummary", &"RichTextLabel")
	theme.set_font(&"normal_font", &"CommitSummary", bold_font())
	theme.set_font_size(&"normal_font_size", &"CommitSummary", 17)
	_variation(theme, &"DetailsRow", &"HFlowContainer")
	theme.set_constant(&"h_separation", &"DetailsRow", 18)
	theme.set_constant(&"v_separation", &"DetailsRow", 4)
	_variation(theme, &"DetailsGroup", &"HBoxContainer")
	theme.set_constant(&"separation", &"DetailsGroup", 6)
	_variation(theme, &"DetailsName", &"Label")
	theme.set_font(&"font", &"DetailsName", bold_font())
	_variation(theme, &"DetailsMeta", &"Label")
	theme.set_color(&"font_color", &"DetailsMeta", p.text_muted)
	theme.set_font_size(&"font_size", &"DetailsMeta", 13)
	_variation(theme, &"DetailsHash", &"Label")
	theme.set_font(&"font", &"DetailsHash", mono_font())
	theme.set_font_size(&"font_size", &"DetailsHash", 13)
	theme.set_color(&"font_color", &"DetailsHash", p.accent_text)
	_variation(theme, &"DetailsId", &"DetailsHash")
	theme.set_color(&"font_color", &"DetailsId", p.text_muted)
	_variation(theme, &"DetailsIconButton", &"ToolbarButton")
	var small: Vector4 = Vector4(3, 2, 3, 2)
	theme.set_stylebox(&"normal", &"DetailsIconButton", _box(Color.TRANSPARENT, 4, small))
	theme.set_stylebox(&"hover", &"DetailsIconButton", _box(p.hover, 4, small))
	theme.set_stylebox(&"pressed", &"DetailsIconButton", _box(Color(p.accent, 0.25), 4, small))
	theme.set_stylebox(&"hover_pressed", &"DetailsIconButton", _box(Color(p.accent, 0.35), 4, small))
	_variation(theme, &"CommitBody", &"RichTextLabel")
	theme.set_font_size(&"normal_font_size", &"CommitBody", 14)
	theme.set_constant(&"line_separation", &"CommitBody", 2)
	# Icons beside the details are dimmed with their text.
	theme.set_color(&"icon_tint", &"CommitDetails", Color(1, 1, 1, 0.65))
	theme.set_constant(&"icon_size", &"CommitDetails", 14)
	# Defaults of the two splits; the user's sizes are saved per repository.
	theme.set_constant(&"details_height", &"CommitDetails", 200)
	theme.set_constant(&"files_width", &"CommitDetails", 300)
	theme.set_constant(&"min_files_width", &"CommitDetails", 180)


static func _add_changes(theme: Theme, p: Palette) -> void:
	_variation(theme, &"DiffHeader", &"PanelContainer")
	theme.set_stylebox(&"panel", &"DiffHeader", _box(p.background, 0, Vector4(8, 4, 8, 4)))
	theme.set_constant(&"files_width", &"ChangesView", 360)
	theme.set_constant(&"separation", &"ChangesView", 6)
	theme.set_constant(&"body_height", &"CommitBox", 96)
	theme.set_constant(&"output_height", &"CommitBox", 120)
	theme.set_color(&"path_color", &"ChangeList", p.text)
	theme.set_color(&"dir_color", &"ChangeList", p.text_muted)
	for entry: Array in [[&"added", p.added], [&"modified", p.modified], [&"deleted", p.removed],
			[&"renamed", p.renamed], [&"untracked", p.added], [&"conflict", p.error]]:
		theme.set_color(StringName("%s_color" % entry[0]), &"ChangeList", entry[1])
	theme.set_constant(&"padding", &"ChangeList", 8)
	theme.set_constant(&"code_width", &"ChangeList", 22)
	theme.set_constant(&"icon_size", &"ChangeList", 14)
	# Diff backgrounds are the git colours blended into the background, so they
	# follow both themes.
	theme.set_font(&"font", &"DiffView", mono_font())
	theme.set_font_size(&"font_size", &"DiffView", 13)
	theme.set_color(&"text_color", &"DiffView", p.text)
	theme.set_color(&"line_number_color", &"DiffView", p.text_muted)
	theme.set_color(&"hunk_color", &"DiffView", p.text_muted)
	theme.set_color(&"hunk_bg", &"DiffView", p.background.blend(Color(p.accent, 0.1)))
	theme.set_color(&"added_bg", &"DiffView", p.background.blend(Color(p.added, 0.16)))
	theme.set_color(&"removed_bg", &"DiffView", p.background.blend(Color(p.removed, 0.16)))
	theme.set_color(&"added_hl_bg", &"DiffView", p.background.blend(Color(p.added, 0.38)))
	theme.set_color(&"removed_hl_bg", &"DiffView", p.background.blend(Color(p.removed, 0.38)))
	theme.set_color(&"added_mark", &"DiffView", p.added)
	theme.set_color(&"removed_mark", &"DiffView", p.removed)
	theme.set_color(&"gutter_bg", &"DiffView", p.surface)
	theme.set_color(&"empty_bg", &"DiffView", p.surface)
	theme.set_color(&"syntax_keyword", &"DiffView", p.syntax_keyword)
	theme.set_color(&"syntax_type", &"DiffView", p.syntax_type)
	theme.set_color(&"syntax_string", &"DiffView", p.syntax_string)
	theme.set_color(&"syntax_number", &"DiffView", p.syntax_number)
	theme.set_color(&"syntax_comment", &"DiffView", p.text_muted)
	theme.set_color(&"message_color", &"DiffView", p.text_muted)
	theme.set_constant(&"row_height", &"DiffView", 20)
	theme.set_constant(&"padding", &"DiffView", 8)


## The shell of M6.5 P2: menu strip, header buttons, worktree chips, the
## branch list, the operation banner, the busy overlay, toasts and panes.
static func _add_shell_p2(theme: Theme, p: Palette) -> void:
	_variation(theme, &"MenuStrip", &"PanelContainer")
	theme.set_stylebox(&"panel", &"MenuStrip", _box(p.background, 0, Vector4(4, 2, 4, 0)))
	# The repo tabs' attention dots (PLAN §4 Repo tabs)
	theme.set_color(&"conflict_color", &"RepoTabs", p.error)
	theme.set_color(&"changes_color", &"RepoTabs", p.modified)
	theme.set_color(&"sync_color", &"RepoTabs", p.accent)
	# The worktree strip under the tabs, joined to the active tab like a toolbar
	_variation(theme, &"WorktreeStrip", &"PanelContainer")
	var strip: StyleBoxFlat = _box(p.surface, 0, Vector4(8, 6, 8, 6))
	strip.border_color = p.border
	strip.border_width_bottom = 1
	theme.set_stylebox(&"panel", &"WorktreeStrip", strip)
	_variation(theme, &"ChipRow", &"HBoxContainer")
	theme.set_constant(&"separation", &"ChipRow", 6)
	var chip: Vector4 = Vector4(10, 4, 10, 4)
	for entry: Array in [[&"WorktreeChip", Color.TRANSPARENT, p.border],
			[&"WorktreeChipHover", p.hover, p.border],
			[&"WorktreeChipSelected", Color(p.accent, 0.25), p.accent]]:
		_variation(theme, entry[0], &"PanelContainer")
		theme.set_stylebox(&"panel", entry[0], _box(entry[1], 12, chip, entry[2], 1))
	_variation(theme, &"ChipBadge", &"Label")
	theme.set_color(&"font_color", &"ChipBadge", p.modified)
	theme.set_font_size(&"font_size", &"ChipBadge", 12)
	# Branch and Sync: big raised buttons with room for a ▾ part
	_variation(theme, &"HeaderRow", &"HBoxContainer")
	theme.set_constant(&"separation", &"HeaderRow", 8)
	_variation(theme, &"BigButton", &"Button")
	_variation(theme, &"BigMenuButton", &"BigButton")
	for entry: Array in [[&"BigButton", Vector4(12, 7, 14, 7)], [&"BigMenuButton", Vector4(12, 7, 40, 7)]]:
		var margins: Vector4 = entry[1]
		theme.set_stylebox(&"normal", entry[0], _box(p.raised, 6, margins, p.border, 1))
		theme.set_stylebox(&"hover", entry[0], _box(p.hover, 6, margins, p.border, 1))
		theme.set_stylebox(&"pressed", entry[0], _box(Color(p.accent, 0.35), 6, margins, p.accent, 1))
		theme.set_stylebox(&"hover_pressed", entry[0], _box(Color(p.accent, 0.35), 6, margins, p.accent, 1))
		theme.set_stylebox(&"disabled", entry[0], _box(Color(p.raised, 0.5), 6, margins, p.border, 1))
		theme.set_stylebox(&"focus", entry[0], _box(Color.TRANSPARENT, 6, Vector4.ZERO, p.accent, 1))
	theme.set_font_size(&"font_size", &"BigButton", 15)
	theme.set_constant(&"h_separation", &"BigButton", 8)
	theme.set_constant(&"arrow_width", &"BigButton", 28)
	theme.set_color(&"separator_color", &"BigButton", p.border)
	theme.set_color(&"progress_color", &"BigButton", p.accent)
	# The Changes | History switch: joined buttons, the shown one in the accent
	theme.set_constant(&"separation", &"ViewSwitch", 2)
	_variation(theme, &"SegmentButton", &"Button")
	var segment: Vector4 = Vector4(10, 4, 10, 4)
	theme.set_stylebox(&"normal", &"SegmentButton", _box(p.raised, 4, segment))
	theme.set_stylebox(&"hover", &"SegmentButton", _box(p.hover, 4, segment))
	theme.set_stylebox(&"pressed", &"SegmentButton", _box(Color(p.accent, 0.35), 4, segment))
	theme.set_stylebox(&"hover_pressed", &"SegmentButton", _box(Color(p.accent, 0.4), 4, segment))
	# Icon-only joined buttons (the diff layout): one outline, rounded outside
	_variation(theme, &"IconSwitch", &"HBoxContainer")
	theme.set_constant(&"separation", &"IconSwitch", 0)
	var icon_segment: Vector4 = Vector4(7, 4, 7, 4)
	for entry: Array in [[&"IconSegmentFirst", true], [&"IconSegmentLast", false]]:
		_variation(theme, entry[0], &"SegmentButton")
		for state: Array in [[&"normal", p.raised], [&"hover", p.hover],
				[&"pressed", Color(p.accent, 0.35)], [&"hover_pressed", Color(p.accent, 0.4)]]:
			var box: StyleBoxFlat = _box(state[1], 4, icon_segment, p.border, 1)
			if entry[1]:
				box.corner_radius_top_right = 0
				box.corner_radius_bottom_right = 0
			else:
				box.corner_radius_top_left = 0
				box.corner_radius_bottom_left = 0
				box.border_width_left = 0
			theme.set_stylebox(state[0], entry[0], box)
	# Panes: a header row over each left column, a status line, details
	_variation(theme, &"PaneColumn", &"VBoxContainer")
	theme.set_constant(&"separation", &"PaneColumn", 0)
	_variation(theme, &"PaneHeader", &"PanelContainer")
	theme.set_stylebox(&"panel", &"PaneHeader", _box(p.background, 0, Vector4(8, 6, 8, 4)))
	_variation(theme, &"StatusLine", &"Label")
	theme.set_color(&"font_color", &"StatusLine", p.text_muted)
	theme.set_font_size(&"font_size", &"StatusLine", 12)
	theme.set_stylebox(&"normal", &"StatusLine", _box(Color.TRANSPARENT, 0, Vector4(10, 0, 8, 4)))
	_variation(theme, &"DetailsHeader", &"PanelContainer")
	var details: StyleBoxFlat = _box(p.background, 0, Vector4(14, 12, 14, 10))
	details.border_color = p.border
	details.border_width_bottom = 1
	theme.set_stylebox(&"panel", &"DetailsHeader", details)
	theme.set_constant(&"min_left_width", &"Panes", 300)
	theme.set_constant(&"default_left_width", &"Panes", 440)
	# An operation in progress: the only red element (PLAN §4)
	_variation(theme, &"OperationBanner", &"PanelContainer")
	var banner: StyleBoxFlat = _box(p.background.blend(Color(p.error, 0.18)), 0, Vector4(12, 6, 8, 6))
	banner.border_color = p.error
	banner.border_width_bottom = 1
	theme.set_stylebox(&"panel", &"OperationBanner", banner)
	# The busy overlay dims one worktree's panes
	_variation(theme, &"BusyOverlay", &"Panel")
	theme.set_stylebox(&"panel", &"BusyOverlay", _box(Color(p.background, 0.7)))
	_variation(theme, &"BusyPanel", &"PanelContainer")
	theme.set_stylebox(&"panel", &"BusyPanel", _box(p.surface, 8, Vector4(24, 16, 24, 16), p.border, 1))
	# The branch list
	theme.set_constant(&"width", &"BranchPopover", 380)
	theme.set_constant(&"height", &"BranchPopover", 440)
	theme.set_color(&"section_color", &"BranchPopover", p.text_muted)
	theme.set_color(&"badge_color", &"BranchPopover", p.text_muted)
	theme.set_color(&"head_color", &"BranchPopover", p.head)
	# Remotes… and Tags…
	theme.set_constant(&"width", &"ManageDialog", 620)
	theme.set_constant(&"height", &"ManageDialog", 380)
	# Toasts of successes and progress (errors are ToastPanel)
	for entry: Array in [[&"SuccessToastPanel", p.accent], [&"ProgressToastPanel", p.border]]:
		_variation(theme, entry[0], &"PanelContainer")
		var toast: StyleBoxFlat = _box(p.raised, 6, Vector4(14, 8, 8, 8), entry[1], 1)
		toast.border_width_left = 3
		toast.shadow_color = Color(0, 0, 0, 0.25 if p.light else 0.4)
		toast.shadow_size = 6
		theme.set_stylebox(&"panel", entry[0], toast)
	theme.set_constant(&"bottom_margin", &"Toasts", 40)


## The Changes view of M6.5 P3: commit checkboxes, the list header, the
## commit panel and empty states with suggested actions.
static func _add_changes_p3(theme: Theme, p: Palette) -> void:
	theme.set_constant(&"size", &"PickBox", 14)
	theme.set_color(&"border_color", &"PickBox", p.text_muted)
	theme.set_color(&"fill_color", &"PickBox", p.accent)
	theme.set_color(&"mark_color", &"PickBox", readable_text([p.accent], DARK_TEXT))
	_variation(theme, &"ListHeader", &"PanelContainer")
	var header: StyleBoxFlat = _box(p.background, 0, Vector4(8, 4, 8, 4))
	header.border_color = p.border
	header.border_width_bottom = 1
	theme.set_stylebox(&"panel", &"ListHeader", header)
	_variation(theme, &"ListHeaderRow", &"HBoxContainer")
	theme.set_constant(&"separation", &"ListHeaderRow", 8)
	_variation(theme, &"CommitPanel", &"PanelContainer")
	var commit: StyleBoxFlat = _box(p.surface, 0, Vector4(8, 8, 8, 8))
	commit.border_color = p.border
	commit.border_width_top = 1
	theme.set_stylebox(&"panel", &"CommitPanel", commit)
	_variation(theme, &"EmptyStateBox", &"VBoxContainer")
	theme.set_constant(&"separation", &"EmptyStateBox", 10)
	_variation(theme, &"EmptyStateTitle", &"Label")
	theme.set_font_size(&"font_size", &"EmptyStateTitle", 22)
	_variation(theme, &"SuggestionList", &"VBoxContainer")
	theme.set_constant(&"separation", &"SuggestionList", 8)
	_variation(theme, &"SuggestionButton", &"Button")
	var margins: Vector4 = Vector4(14, 10, 14, 10)
	theme.set_stylebox(&"normal", &"SuggestionButton", _box(p.raised, 6, margins, p.border, 1))
	theme.set_stylebox(&"hover", &"SuggestionButton", _box(p.hover, 6, margins, p.border, 1))
	theme.set_stylebox(&"pressed", &"SuggestionButton", _box(Color(p.accent, 0.35), 6, margins, p.accent, 1))
	theme.set_stylebox(&"hover_pressed", &"SuggestionButton", _box(Color(p.accent, 0.35), 6, margins, p.accent, 1))
	theme.set_stylebox(&"disabled", &"SuggestionButton", _box(Color(p.raised, 0.5), 6, margins, p.border, 1))
	theme.set_stylebox(&"focus", &"SuggestionButton", _box(Color.TRANSPARENT, 6, Vector4.ZERO, p.accent, 1))
	theme.set_font_size(&"font_size", &"SuggestionButton", 15)
	theme.set_constant(&"h_separation", &"SuggestionButton", 10)
	theme.set_constant(&"button_width", &"EmptyState", 340)
	# M6.5 P4: the Shelved section and the offer to restore left changes
	_variation(theme, &"OfferBar", &"PanelContainer")
	var offer: StyleBoxFlat = _box(p.background.blend(Color(p.accent, 0.18)), 0, Vector4(10, 6, 8, 6))
	offer.border_color = p.accent
	offer.border_width_bottom = 1
	theme.set_stylebox(&"panel", &"OfferBar", offer)
	_variation(theme, &"SectionHeaderButton", &"Button")
	var section: Vector4 = Vector4(8, 4, 8, 4)
	theme.set_stylebox(&"normal", &"SectionHeaderButton", _box(p.background, 0, section, p.border, 0))
	theme.set_stylebox(&"hover", &"SectionHeaderButton", _box(p.hover, 0, section))
	theme.set_stylebox(&"pressed", &"SectionHeaderButton", _box(p.hover, 0, section))
	theme.set_color(&"font_color", &"SectionHeaderButton", p.text_muted)
	theme.set_color(&"icon_normal_color", &"SectionHeaderButton", p.text_muted)
	_variation(theme, &"ShelfTree", &"Tree")
	theme.set_stylebox(&"panel", &"ShelfTree", _box(p.background, 0, Vector4(0, 2, 0, 2)))
	theme.set_constant(&"row_height", &"ShelfList", 26)
	theme.set_constant(&"max_height", &"ShelfList", 220)
	theme.set_color(&"group_color", &"ShelfList", p.text_muted)
	# The first suggestion (Open repository…) in the accent colour
	_variation(theme, &"PrimarySuggestionButton", &"SuggestionButton")
	var accent_text: Color = readable_text([p.accent, p.accent.lightened(0.08), p.accent.darkened(0.1)], p.text)
	theme.set_stylebox(&"normal", &"PrimarySuggestionButton", _box(p.accent, 6, margins))
	theme.set_stylebox(&"hover", &"PrimarySuggestionButton", _box(p.accent.lightened(0.08), 6, margins))
	theme.set_stylebox(&"pressed", &"PrimarySuggestionButton", _box(p.accent.darkened(0.1), 6, margins))
	theme.set_stylebox(&"hover_pressed", &"PrimarySuggestionButton", _box(p.accent.darkened(0.1), 6, margins))
	for color: StringName in [&"font_color", &"font_hover_color", &"font_focus_color", &"font_pressed_color",
			&"font_hover_pressed_color", &"icon_normal_color", &"icon_hover_color", &"icon_focus_color",
			&"icon_pressed_color", &"icon_hover_pressed_color"]:
		theme.set_color(color, &"PrimarySuggestionButton", accent_text)


## Frame `frame` of the busy spinner, in the icon grey of the light or dark
## theme.
static func spinner(frame: int, light: bool) -> Texture2D:
	var key: Vector2i = Vector2i(frame % SPINNER_FRAMES, 1 if light else 0)
	if not _spinners.has(key):
		var grey: String = (LIGHT_ICON_GREY if light else DARK_ICON_GREY).to_html(false)
		var angle: float = 360.0 * float(key.x) / float(SPINNER_FRAMES)
		var svg: String = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" fill="none" stroke="#%s" stroke-width="2" stroke-linecap="round">' % grey
		svg += '<circle cx="8" cy="8" r="5.5" stroke-opacity=".25"/>'
		svg += '<path d="M8 2.5a5.5 5.5 0 0 1 5.5 5.5" transform="rotate(%.1f 8 8)"/></svg>' % angle
		_spinners[key] = DPITexture.create_from_string(svg)
	return _spinners[key]


## A small dot of `color`, such as a repo tab's attention dot.
static func dot(color: Color) -> Texture2D:
	if not _dots.has(color):
		var svg: String = '<svg xmlns="http://www.w3.org/2000/svg" width="12" height="16">'
		svg += '<circle cx="6" cy="8" r="3.5" fill="#%s"/></svg>' % color.to_html(false)
		_dots[color] = DPITexture.create_from_string(svg)
	return _dots[color]


## The interface font, bolder: titles and names.
static func bold_font() -> Font:
	var font: FontVariation = FontVariation.new()
	font.base_font = ThemeDB.fallback_font
	font.variation_embolden = 0.6
	return font


static func mono_font() -> SystemFont:
	var font: SystemFont = SystemFont.new()
	font.font_names = MONO_FONTS
	return font


## The colours swapped in the icons: none in the dark theme.
static func icon_color_map(light: bool) -> Dictionary:
	var colors: Dictionary = {}
	if light:
		for from: String in LIGHT_ICON_COLORS:
			colors[Color(from)] = Color(LIGHT_ICON_COLORS[from])
	return colors


## Recolours every icon in place, so the controls that show one follow the
## theme. Each is drawn again from its SVG at the interface's scale. The
## exceptions are loaded too: an icon only drawn with `draw_texture_rect`
## (no node holds it) would otherwise be freed after each draw.
static func recolor_icons(light: bool) -> void:
	var colors: Dictionary = icon_color_map(light)
	for file: String in ResourceLoader.list_directory(ICON_DIR):
		if file.get_extension() != "svg":
			continue
		if not _icons.has(file):
			var loaded: DPITexture = load(ICON_DIR.path_join(file)) as DPITexture
			if loaded == null:
				push_warning("%s isn't imported as a DPITexture" % file)
				continue
			_icons[file] = loaded
		if StringName(file.get_basename()) in ICON_EXCEPTIONS:
			continue
		if _icons[file].color_map != colors:
			_icons[file].color_map = colors


## The icon `name` (an SVG in `ICON_DIR` without its extension).
static func icon(name: StringName) -> Texture2D:
	return load(ICON_DIR.path_join("%s.svg" % name)) as Texture2D


## A dot of `color` the size of an icon, such as an accent colour to pick.
## Its rim is a little darker, so it shows on a background of about its colour.
static func swatch(color: Color) -> Texture2D:
	if not _swatches.has(color):
		var svg: String = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16">'
		svg += '<circle cx="8" cy="8" r="6" fill="#%s" stroke="#%s"/></svg>' % [
				color.to_html(false), color.darkened(0.25).to_html(false)]
		_swatches[color] = DPITexture.create_from_string(svg)
	return _swatches[color]


static func _variation(theme: Theme, variation: StringName, base: StringName) -> void:
	theme.set_type_variation(variation, base)


static func _box(color: Color, radius: int = 0, margins: Vector4 = Vector4.ZERO,
		border_color: Color = Color.TRANSPARENT, border: int = 0) -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.content_margin_left = margins.x
	box.content_margin_top = margins.y
	box.content_margin_right = margins.z
	box.content_margin_bottom = margins.w
	if border > 0:
		box.border_color = border_color
		box.set_border_width_all(border)
	return box
