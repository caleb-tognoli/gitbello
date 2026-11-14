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
## The app logo. It keeps its own colours in both themes, so it lives outside
## `ICON_DIR` and is never recoloured.
const LOGO: String = "res://themes/branding/logo.svg"
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
## The ▾ part of every split button (toolbar, worktree strip, dialogs): the
## ARROW_DOWN icon with this padding each side, so the part is
## 12 + 2 × 8 = 28 px wide, behind a full-height 1 px line.
const SPLIT_ARROW_PADDING: int = 8
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
## White copies of icons, by name (see `tintable_icon`).
static var _tintable: Dictionary[StringName, DPITexture] = {}
## Icons drawn large, by `name:side:colours` (see `large_icon`).
static var _large: Dictionary[String, DPITexture] = {}
## How strongly the changed words of paired lines are tinted, in percent of
## the added or removed colour: the diff's word background, and the
## minimap's word blocks over its row tint. A variable so that
## `tests/visual/word_tint_sheet.tscn` can compare intensities; 40 keeps the
## syntax hues readable on it (M7.13 P6).
static var word_tint_percent: int = 40


class Palette:
	var light: bool
	var background: Color  ## Window, lists and content
	var surface: Color  ## Toolbars, sidebar, menus, dialogs
	var raised: Color  ## Buttons and fields
	var hover: Color
	var border: Color
	var text: Color
	var text_muted: Color
	var accent: Color
	var accent_text: Color  ## Text in the accent colour
	var error: Color
	## Commits to pull (commits to push are in the accent).
	var incoming: Color
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
	## The two sides of a conflict: ours (the checked-out branch) and theirs.
	var ours: Color
	var theirs: Color
	## Syntax colours by token kind name (`string.escape`); kinds left out
	## take their parent's colour or plain text (see `syntax_colors`).
	var syntax: Dictionary[String, Color] = {}


## Fills `p.syntax` from the theme's syntax hues: comments (doc comments
## too) in the muted text colour, the last CSV column in the text colour,
## and the base kinds without a hue of their own sharing one (constants and
## attributes the numbers', tags the variables', headings the macros',
## emphasis the annotations', links and diff headers the types'). Function
## names, operators and punctuation stay plain. No hue is green or red
## except a patch's added and removed lines: they would read as the diff's
## own colours (and are the pair red-green colour blindness confuses).
static func _syntax_palette(p: Palette, hues: Dictionary[String, Color]) -> void:
	p.syntax = hues.duplicate()
	p.syntax["comment"] = p.text_muted
	p.syntax["column.7"] = p.text
	var shared: Dictionary[String, String] = {
		"constant": "number", "attribute": "number", "tag": "variable",
		"markup.heading": "macro", "markup.emphasis": "annotation", "markup.link": "type",
		"diff.header": "type",
	}
	for kind_name: String in shared:
		p.syntax[kind_name] = hues[shared[kind_name]]


## `added` and `removed` replace the theme's colours of added and removed
## lines unless transparent (the user's choice, the same in both themes).
static func palette(light: bool, accent: Color = DEFAULT_ACCENT,
		added: Color = Color.TRANSPARENT, removed: Color = Color.TRANSPARENT) -> Palette:
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
		p.incoming = Color(0.6, 0.38, 0.0)
		p.shade = 0.6
		p.selected = p.background.blend(Color(accent, 0.15))
		p.selected_focus = p.background.blend(Color(accent, 0.22))
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
		p.ours = Color(0.13, 0.42, 0.85)
		p.theirs = Color(0.85, 0.45, 0.05)
		_syntax_palette(p, {
			"keyword": Color(0.55, 0.2, 0.7),
			"type": Color(0.0, 0.45, 0.55),
			"string": Color(0.47, 0.36, 0.2),
			"number": Color(0.7, 0.14, 0.5),
			"macro": Color(0.1, 0.36, 0.8),
			"variable": Color(0.645, 0.32, 0.0),
			"annotation": Color(0.5, 0.38, 0.0),
			"string.escape": Color(0.0, 0.46, 0.42),
			"key": Color(0.13, 0.33, 0.62),
			"diff.added": Color(0.096, 0.48, 0.144),
			"diff.removed": Color(0.75, 0.12, 0.12),
			"column.0": Color(0.1, 0.36, 0.8),
			"column.1": Color(0.645, 0.32, 0.0),
			"column.2": Color(0.55, 0.2, 0.7),
			"column.3": Color(0.47, 0.36, 0.2),
			"column.4": Color(0.0, 0.45, 0.55),
			"column.5": Color(0.7, 0.14, 0.5),
			"column.6": Color(0.5, 0.38, 0.0),
		})
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
		p.incoming = Color(0.98, 0.74, 0.35)
		p.shade = 1.0
		p.selected = p.background.blend(Color(accent, 0.18))
		p.selected_focus = p.background.blend(Color(accent, 0.26))
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
		p.ours = Color(0.35, 0.62, 1.0)
		p.theirs = Color(1.0, 0.62, 0.25)
		_syntax_palette(p, {
			"keyword": Color(0.78, 0.55, 0.95),
			"type": Color(0.4, 0.78, 0.85),
			"string": Color(0.86, 0.75, 0.6),
			"number": Color(0.95, 0.56, 0.78),
			"macro": Color(0.47, 0.69, 1.0),
			"variable": Color(0.95, 0.65, 0.4),
			"annotation": Color(0.9, 0.8, 0.45),
			"string.escape": Color(0.45, 0.84, 0.78),
			"key": Color(0.62, 0.85, 1.0),
			"diff.added": Color(0.5, 0.85, 0.55),
			"diff.removed": Color(0.97, 0.52, 0.52),
			"column.0": Color(0.5, 0.72, 1.0),
			"column.1": Color(0.95, 0.65, 0.4),
			"column.2": Color(0.78, 0.55, 0.95),
			"column.3": Color(0.86, 0.75, 0.6),
			"column.4": Color(0.4, 0.8, 0.85),
			"column.5": Color(0.95, 0.56, 0.78),
			"column.6": Color(0.9, 0.8, 0.45),
		})
	if added.a > 0.0:
		p.added = added
	if removed.a > 0.0:
		p.removed = removed
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


## The contrast diff text reaches on every background it is drawn on.
const MIN_TEXT_CONTRAST: float = 4.5
## Tables `readable_colors` keeps before it starts over (themes, accents
## and chosen colours each make their own).
const MAX_READABLE_TABLES: int = 256
## `readable_colors` results by `[colors, background, target]`.
static var _readable_tables: Dictionary[Array, PackedColorArray] = {}


## `color` readable on the opaque `background`: its OKLCH hue kept, as much
## of its chroma as sRGB holds, and its lightness moved, as little as it
## takes, until it reaches `target` (towards white or black, whichever
## stands further from the background). A colour that reaches it already is
## returned as it is.
static func readable(color: Color, background: Color, target: float = MIN_TEXT_CONTRAST) -> Color:
	if contrast_ratio(color, background) >= target:
		return color
	var lab: Vector3 = _oklab(color)
	var chroma: float = Vector2(lab.y, lab.z).length()
	var hue: float = atan2(lab.z, lab.y)
	var lighter: bool = contrast_ratio(Color.WHITE, background) >= contrast_ratio(Color.BLACK, background)
	# `fails` short of the target, `reaches` at it or past.
	var fails: float = lab.x
	var reaches: float = 1.0 if lighter else 0.0
	# 12 halvings: lightness within 1/4096, finer than an 8-bit step.
	for i: int in 12:
		var middle: float = (fails + reaches) / 2.0
		if contrast_ratio(_oklch_in_gamut(middle, chroma, hue), background) >= target:
			reaches = middle
		else:
			fails = middle
	var out: Color = _oklch_in_gamut(reaches, chroma, hue)
	out.a = color.a
	return out


## `readable` for each colour of `colors`; transparent ones (plain text)
## stay transparent. Kept for later calls with the same colours and
## background (every diff view shares them; a table takes a few
## milliseconds).
static func readable_colors(colors: PackedColorArray, background: Color,
		target: float = MIN_TEXT_CONTRAST) -> PackedColorArray:
	var key: Array = [colors, background, target]
	if _readable_tables.has(key):
		return _readable_tables[key]
	var out: PackedColorArray = PackedColorArray()
	out.resize(colors.size())
	var done: Dictionary[Color, Color] = {}
	for i: int in colors.size():
		var color: Color = colors[i]
		if color.a == 0.0:
			out[i] = color
			continue
		if not done.has(color):
			done[color] = readable(color, background, target)
		out[i] = done[color]
	if _readable_tables.size() >= MAX_READABLE_TABLES:
		_readable_tables.clear()
	_readable_tables[key] = out
	return out


## The opaque backgrounds diff text is drawn on, by name: lines unchanged,
## added and removed, their changed words, the resolver's ours, theirs and
## base, and the selection over each of these (`selection_<name>`).
static func diff_backgrounds(control: Control) -> Dictionary[StringName, Color]:
	var t: StringName = &"DiffView"
	var under: Color = control.get_theme_color(&"background", t)
	var out: Dictionary[StringName, Color] = {&"unchanged": under}
	for entry: Array in [[&"added", &"added_bg"], [&"removed", &"removed_bg"],
			[&"added_word", &"added_hl_bg"], [&"removed_word", &"removed_hl_bg"],
			[&"ours", &"ours_bg"], [&"theirs", &"theirs_bg"], [&"base", &"base_bg"]]:
		out[entry[0]] = under.blend(control.get_theme_color(entry[1], t))
	var selection: Color = control.get_theme_color(&"selection_bg", t)
	for name: StringName in out.keys():
		out[StringName("selection_" + name)] = out[name].blend(selection)
	return out


## The syntax colours of `DiffView` (`syntax_colors`, plain kinds
## transparent) made readable on each of `diff_backgrounds`, by name.
static func syntax_color_tables(control: Control) -> Dictionary[StringName, PackedColorArray]:
	var colors: PackedColorArray = syntax_colors(control, &"DiffView", Color.TRANSPARENT)
	var out: Dictionary[StringName, PackedColorArray] = {}
	var backgrounds: Dictionary[StringName, Color] = diff_backgrounds(control)
	for name: StringName in backgrounds:
		out[name] = readable_colors(colors, backgrounds[name])
	return out


## OKLab (lightness, a, b) of an sRGB colour (Björn Ottosson's matrices).
static func _oklab(color: Color) -> Vector3:
	var c: Color = color.srgb_to_linear()
	var l: float = _cbrt(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b)
	var m: float = _cbrt(0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b)
	var s: float = _cbrt(0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b)
	return Vector3(
			0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
			1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
			0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


## Linear sRGB of an OKLab colour, possibly outside [0, 1].
static func _linear_of_oklab(lightness: float, a: float, b: float) -> Vector3:
	var l: float = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3.0)
	var m: float = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3.0)
	var s: float = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3.0)
	return Vector3(
			4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
			-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
			-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)


## The sRGB colour of OKLCH (`lightness`, `chroma`, `hue`), its chroma
## lowered as little as it takes to fit in sRGB.
static func _oklch_in_gamut(lightness: float, chroma: float, hue: float) -> Color:
	var fits: Callable = func(amount: float) -> bool:
		var linear: Vector3 = _linear_of_oklab(lightness, amount * cos(hue), amount * sin(hue))
		return linear.x >= -0.0001 and linear.y >= -0.0001 and linear.z >= -0.0001 \
				and linear.x <= 1.0001 and linear.y <= 1.0001 and linear.z <= 1.0001
	var c: float = chroma
	if not fits.call(c):
		var low: float = 0.0
		var high: float = chroma
		for i: int in 10:
			var middle: float = (low + high) / 2.0
			if fits.call(middle):
				low = middle
			else:
				high = middle
		c = low
	var rgb: Vector3 = _linear_of_oklab(lightness, c * cos(hue), c * sin(hue)).clamp(Vector3.ZERO, Vector3.ONE)
	return Color(rgb.x, rgb.y, rgb.z).linear_to_srgb()


static func _cbrt(x: float) -> float:
	return signf(x) * pow(absf(x), 1.0 / 3.0)


## The theme colour name of a syntax token kind (`string.escape` →
## `syntax_string_escape`).
static func syntax_color_name(kind_name: String) -> StringName:
	return StringName("syntax_" + kind_name.replace(".", "_"))


## One colour per syntax token kind, in core's id order
## (`RepoSession.syntax_kinds()`): the kind's own `syntax_<name>` colour of
## `theme_type`, else its parent's, else `plain` (drawn as plain text).
static func syntax_colors(control: Control, theme_type: StringName, plain: Color) -> PackedColorArray:
	var kinds: Array[Dictionary] = RepoSession.syntax_kinds()
	var ids: Dictionary[String, int] = {}
	var out: PackedColorArray = PackedColorArray()
	for kind: Dictionary in kinds:
		var name: String = kind["name"]
		var parent: String = kind["parent"]
		var color_name: StringName = syntax_color_name(name)
		var color: Color = plain
		if control.has_theme_color(color_name, theme_type):
			color = control.get_theme_color(color_name, theme_type)
		elif ids.has(parent):
			# Parents come before their children.
			color = out[ids[parent]]
		ids[name] = out.size()
		out.append(color)
	return out


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


static func build(light: bool, accent: Color = DEFAULT_ACCENT,
		added: Color = Color.TRANSPARENT, removed: Color = Color.TRANSPARENT) -> Theme:
	var p: Palette = palette(light, accent, added, removed)
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
	_add_home(theme, p)
	_add_shortcuts(theme, p)
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
	_variation(theme, &"HeaderSmall", &"Label")
	theme.set_color(&"font_color", &"HeaderSmall", p.text_muted)
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
			&"font_pressed_color", &"font_hover_pressed_color", &"icon_normal_color", &"icon_hover_color",
			&"icon_focus_color", &"icon_pressed_color", &"icon_hover_pressed_color"]:
		theme.set_color(color, &"PrimaryButton", accent_text)
	# A split button (FormDialog.set_menu): the primary button and its ▾ as one
	# control, a thin darker line between them
	_variation(theme, &"SplitPrimaryButton", &"PrimaryButton")
	_variation(theme, &"SplitMenuButton", &"PrimaryButton")
	for state: Array in [[&"normal", p.accent], [&"hover", p.accent.lightened(0.08)],
			[&"pressed", p.accent.darkened(0.1)], [&"hover_pressed", p.accent.darkened(0.1)],
			[&"disabled", p.raised]]:
		var left: StyleBoxFlat = _box(state[1], 4, margins)
		left.corner_radius_top_right = 0
		left.corner_radius_bottom_right = 0
		theme.set_stylebox(state[0], &"SplitPrimaryButton", left)
		var right: StyleBoxFlat = _box(state[1], 4, Vector4(SPLIT_ARROW_PADDING, margins.y, SPLIT_ARROW_PADDING, margins.w))
		right.corner_radius_top_left = 0
		right.corner_radius_bottom_left = 0
		right.border_width_left = 1
		right.border_color = p.border if state[0] == &"disabled" else p.accent.darkened(0.3)
		theme.set_stylebox(state[0], &"SplitMenuButton", right)
	# No focus ring: drawn inside one half only, it made the halves look
	# different sizes (Enter still presses the focused half)
	theme.set_stylebox(&"focus", &"SplitPrimaryButton", StyleBoxEmpty.new())
	theme.set_stylebox(&"focus", &"SplitMenuButton", StyleBoxEmpty.new())
	# The main button of a dialog that deletes or discards, in the error colour
	_variation(theme, &"DangerButton", &"PrimaryButton")
	var danger_text: Color = readable_text([p.error, p.error.lightened(0.08), p.error.darkened(0.1)], p.text)
	theme.set_stylebox(&"normal", &"DangerButton", _box(p.error, 4, margins))
	theme.set_stylebox(&"hover", &"DangerButton", _box(p.error.lightened(0.08), 4, margins))
	theme.set_stylebox(&"pressed", &"DangerButton", _box(p.error.darkened(0.1), 4, margins))
	theme.set_stylebox(&"hover_pressed", &"DangerButton", _box(p.error.darkened(0.1), 4, margins))
	theme.set_stylebox(&"focus", &"DangerButton", _box(Color.TRANSPARENT, 4, Vector4.ZERO, danger_text, 1))
	for color: StringName in [&"font_color", &"font_hover_color", &"font_focus_color",
			&"font_pressed_color", &"font_hover_pressed_color"]:
		theme.set_color(color, &"DangerButton", danger_text)
	# A secondary button that throws work away (the banner's Abort): text and
	# icon in the error colour
	_variation(theme, &"DangerTextButton", &"Button")
	for color: StringName in [&"font_color", &"font_hover_color", &"font_focus_color",
			&"font_pressed_color", &"font_hover_pressed_color", &"icon_normal_color", &"icon_hover_color",
			&"icon_focus_color", &"icon_pressed_color", &"icon_hover_pressed_color"]:
		theme.set_color(color, &"DangerTextButton", p.error)


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
	for color: StringName in [&"up_icon_modulate", &"down_icon_modulate"]:
		theme.set_color(color, &"SpinBox", p.text)
	for color: StringName in [&"up_hover_icon_modulate", &"down_hover_icon_modulate",
			&"up_pressed_icon_modulate", &"down_pressed_icon_modulate"]:
		theme.set_color(color, &"SpinBox", p.accent)
	for color: StringName in [&"up_disabled_icon_modulate", &"down_disabled_icon_modulate"]:
		theme.set_color(color, &"SpinBox", Color(p.text_muted, 0.6))
	_variation(theme, &"ErrorOutput", &"TextEdit")
	theme.set_color(&"font_readonly_color", &"ErrorOutput", p.error)
	theme.set_font(&"font", &"ErrorOutput", mono_font())
	theme.set_font_size(&"font_size", &"ErrorOutput", 12)
	_variation(theme, &"DiagnosticOutput", &"TextEdit")
	theme.set_font(&"font", &"DiagnosticOutput", mono_font())


static func _add_menus(theme: Theme, p: Palette) -> void:
	theme.set_font_size(&"font_size", &"MenuBar", 13)
	theme.set_font_size(&"font_size", &"PopupMenu", 14)
	for color: StringName in [&"font_color", &"font_hover_color", &"font_pressed_color",
			&"font_hover_pressed_color", &"font_focus_color"]:
		theme.set_color(color, &"MenuBar", p.text)
	theme.set_color(&"font_disabled_color", &"MenuBar", Color(p.text_muted, 0.6))
	var item: Vector4 = Vector4(8, 3, 8, 3)
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
	# The worktree list: smaller state icons with more room around them
	# The strip's list of every worktree: rows with the folder, its branch,
	# the changed files and the commits to push and pull; the shown one marked
	_variation(theme, &"WorktreeListPanel", &"PopupPanel")
	theme.set_stylebox(&"panel", &"WorktreeListPanel", _box(p.surface, 6, Vector4(4, 4, 4, 4), p.border, 1))
	_variation(theme, &"WorktreeListRows", &"VBoxContainer")
	theme.set_constant(&"separation", &"WorktreeListRows", 0)
	_variation(theme, &"WorktreeListLine", &"HBoxContainer")
	theme.set_constant(&"separation", &"WorktreeListLine", 8)
	_variation(theme, &"WorktreeListRow", &"Button")
	var list_row: Vector4 = Vector4(8, 5, 10, 5)
	theme.set_stylebox(&"normal", &"WorktreeListRow", _box(Color.TRANSPARENT, 4, list_row))
	theme.set_stylebox(&"hover", &"WorktreeListRow", _box(Color(p.accent, 0.3), 4, list_row))
	theme.set_stylebox(&"pressed", &"WorktreeListRow", _box(Color(p.accent, 0.15), 4, list_row))
	theme.set_stylebox(&"hover_pressed", &"WorktreeListRow", _box(Color(p.accent, 0.3), 4, list_row))
	theme.set_stylebox(&"focus", &"WorktreeListRow", _box(Color.TRANSPARENT, 4, Vector4.ZERO, p.accent, 1))
	# The first match of the worktree list's filter, which Enter chooses
	_variation(theme, &"WorktreeListRowTarget", &"WorktreeListRow")
	theme.set_stylebox(&"normal", &"WorktreeListRowTarget", _box(Color(p.accent, 0.3), 4, list_row))
	_variation(theme, &"WorktreeListChanges", &"Label")
	theme.set_color(&"font_color", &"WorktreeListChanges", p.modified)
	theme.set_font_size(&"font_size", &"WorktreeListChanges", 12)
	# The worktree list's filter, rows, line and footer of actions
	_variation(theme, &"WorktreeListBox", &"VBoxContainer")
	theme.set_constant(&"separation", &"WorktreeListBox", 4)
	_variation(theme, &"WorktreeListFooter", &"HBoxContainer")
	theme.set_constant(&"separation", &"WorktreeListFooter", 2)
	theme.set_color(&"icon_color", &"WorktreeList", Color(1, 1, 1, 0.6))
	theme.set_color(&"warning_color", &"WorktreeList", p.modified)
	theme.set_constant(&"width", &"WorktreeList", 380)
	theme.set_constant(&"max_height", &"WorktreeList", 400)
	theme.set_constant(&"empty_height", &"WorktreeList", 48)
	theme.set_constant(&"branch_width", &"WorktreeList", 240)


## Trees and item lists: sunk into the background, rows shaded with the text
## colour when hovered and in the accent colour when selected.
static func _add_lists(theme: Theme, p: Palette, _focus: StyleBox) -> void:
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


## The shell around the repo views: welcome screen, palette,
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
	_variation(theme, &"WelcomeBox", &"VBoxContainer")
	theme.set_constant(&"separation", &"WelcomeBox", 14)
	_variation(theme, &"RecentList", &"ItemList")
	theme.set_stylebox(&"panel", &"RecentList", _box(p.surface, 6, Vector4(6, 6, 6, 6), p.border, 1))
	_variation(theme, &"PalettePanel", &"PanelContainer")
	theme.set_stylebox(&"panel", &"PalettePanel", _box(p.surface, 6, Vector4(8, 8, 8, 8), p.border, 1))
	theme.set_constant(&"width", &"CommandPalette", 640)
	theme.set_constant(&"height", &"CommandPalette", 380)
	theme.set_constant(&"top", &"CommandPalette", 56)
	# Toasts: compact raised cards, the same for every kind; the icon's colour
	# tells errors (ToastPanel), successes and progress apart.
	var toast: StyleBoxFlat = _box(p.raised, 8, Vector4(10, 8, 6, 8), p.border, 1)
	toast.shadow_color = Color(0, 0, 0, 0.18 if p.light else 0.35)
	toast.shadow_size = 8
	toast.shadow_offset = Vector2(0, 2)
	for variation: StringName in [&"ToastPanel", &"SuccessToastPanel", &"ProgressToastPanel"]:
		_variation(theme, variation, &"PanelContainer")
		theme.set_stylebox(&"panel", variation, toast)
	theme.set_color(&"success_color", &"Toasts", p.added)
	theme.set_color(&"error_color", &"Toasts", p.error)
	_variation(theme, &"ToastBox", &"VBoxContainer")
	theme.set_constant(&"separation", &"ToastBox", 6)
	_variation(theme, &"ToastRow", &"HBoxContainer")
	theme.set_constant(&"separation", &"ToastRow", 8)
	_variation(theme, &"ToastTexts", &"VBoxContainer")
	theme.set_constant(&"separation", &"ToastTexts", 2)
	# Undo, Open, Cancel and fixes: text buttons in the accent colour.
	_variation(theme, &"ToastActionButton", &"Button")
	var action_margins: Vector4 = Vector4(8, 2, 8, 2)
	theme.set_stylebox(&"normal", &"ToastActionButton", _box(Color.TRANSPARENT, 4, action_margins))
	theme.set_stylebox(&"hover", &"ToastActionButton", _box(p.hover, 4, action_margins))
	theme.set_stylebox(&"pressed", &"ToastActionButton", _box(Color(p.accent, 0.25), 4, action_margins))
	theme.set_stylebox(&"hover_pressed", &"ToastActionButton", _box(Color(p.accent, 0.35), 4, action_margins))
	for color: StringName in [&"font_color", &"font_hover_color", &"font_focus_color",
			&"font_pressed_color", &"font_hover_pressed_color"]:
		theme.set_color(color, &"ToastActionButton", p.accent_text)
	# The time left of a success, and a job's progress: thin lines.
	_variation(theme, &"ToastCountdown", &"ProgressBar")
	theme.set_stylebox(&"background", &"ToastCountdown", _box(Color.TRANSPARENT, 1, Vector4(0, 1, 0, 1)))
	theme.set_stylebox(&"fill", &"ToastCountdown", _box(Color(p.accent, 0.55), 1))
	_variation(theme, &"ToastProgress", &"ProgressBar")
	theme.set_stylebox(&"background", &"ToastProgress", _box(p.hover, 2, Vector4(0, 2, 0, 2)))
	theme.set_stylebox(&"fill", &"ToastProgress", _box(p.accent, 2))
	theme.set_constant(&"seconds", &"Toasts", 6)
	theme.set_constant(&"undo_seconds", &"Toasts", 12)
	theme.set_constant(&"width", &"Toasts", 340)
	theme.set_constant(&"max_height", &"Toasts", 280)
	theme.set_constant(&"height_percent", &"Toasts", 33)
	theme.set_constant(&"edge_margin", &"Toasts", 16)
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
	# Delete forms: as narrow as their rows
	theme.set_constant(&"narrow_width", &"FormDialog", 360)
	theme.set_constant(&"label_width", &"FormDialog", 140)
	theme.set_constant(&"text_height", &"FormDialog", 90)
	theme.set_constant(&"note_width", &"FormDialog", 380)
	theme.set_constant(&"separation", &"FormDialog", 8)
	theme.set_constant(&"section_separation", &"FormDialog", 14)
	theme.set_color(&"success_color", &"FormDialog", p.added)
	theme.set_color(&"warning_color", &"FormDialog", p.modified)
	theme.set_color(&"error_color", &"FormDialog", p.error)
	theme.set_constant(&"icon_size", &"FormDialog", 16)
	# Room a dialog leaves around itself in the window (FormDialog.add_list)
	theme.set_constant(&"window_margin", &"FormDialog", 96)
	# A form's scrolling list (FormDialog.add_list): rows on the background
	_variation(theme, &"FormList", &"ScrollContainer")
	theme.set_stylebox(&"panel", &"FormList", _box(p.background, 4, Vector4(8, 6, 4, 6), p.border, 1))
	theme.set_constant(&"scrollbar_v_separation", &"FormList", 6)
	# A fold toggle (chevron and text) lined up with the text around it
	_variation(theme, &"DisclosureButton", &"Button")
	for state: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"focus", &"disabled"]:
		theme.set_stylebox(state, &"DisclosureButton", _box(Color.TRANSPARENT, 0, Vector4(0, 2, 4, 2)))
	theme.set_color(&"font_hover_color", &"DisclosureButton", p.text)
	theme.set_color(&"font_pressed_color", &"DisclosureButton", p.text)
	# A branch, tag or commit named in a dialog ("topic → main")
	_variation(theme, &"RefChip", &"PanelContainer")
	theme.set_stylebox(&"panel", &"RefChip", _box(p.raised, 4, Vector4(8, 3, 10, 3), p.border, 1))
	# The same chip as a button that picks another ref (the merge dialog's
	# source, with a ▾ after its name)
	_variation(theme, &"RefChipButton", &"Button")
	var chip_margins: Vector4 = Vector4(8, 3, 8, 3)
	theme.set_stylebox(&"normal", &"RefChipButton", _box(p.raised, 4, chip_margins, p.border, 1))
	theme.set_stylebox(&"hover", &"RefChipButton", _box(p.hover, 4, chip_margins, p.border, 1))
	theme.set_stylebox(&"pressed", &"RefChipButton", _box(p.hover, 4, chip_margins, p.accent, 1))
	theme.set_stylebox(&"hover_pressed", &"RefChipButton", _box(p.hover, 4, chip_margins, p.accent, 1))
	theme.set_stylebox(&"focus", &"RefChipButton", _box(Color.TRANSPARENT, 4, Vector4.ZERO, p.accent, 1))
	theme.set_stylebox(&"disabled", &"RefChipButton", _box(p.raised, 4, chip_margins, p.border, 1))
	theme.set_color(&"font_hover_color", &"RefChipButton", p.text)
	theme.set_color(&"font_pressed_color", &"RefChipButton", p.text)
	theme.set_color(&"font_hover_pressed_color", &"RefChipButton", p.text)
	theme.set_constant(&"h_separation", &"RefChipButton", 6)
	# One of a dialog's choices: a row with an icon, a title and a hint
	_variation(theme, &"ChoiceRow", &"Button")
	theme.set_stylebox(&"normal", &"ChoiceRow", _box(p.raised, 6, Vector4.ZERO, p.border, 1))
	theme.set_stylebox(&"hover", &"ChoiceRow", _box(p.hover, 6, Vector4.ZERO, p.border, 1))
	theme.set_stylebox(&"pressed", &"ChoiceRow", _box(p.hover, 6, Vector4.ZERO, p.accent, 1))
	theme.set_stylebox(&"hover_pressed", &"ChoiceRow", _box(p.hover, 6, Vector4.ZERO, p.accent, 1))
	theme.set_stylebox(&"focus", &"ChoiceRow", _box(Color.TRANSPARENT, 6, Vector4.ZERO, p.accent, 1))
	_variation(theme, &"ChoiceRowBox", &"MarginContainer")
	for side: String in ["left", "right"]:
		theme.set_constant(&"margin_" + side, &"ChoiceRowBox", 12)
	for side: String in ["top", "bottom"]:
		theme.set_constant(&"margin_" + side, &"ChoiceRowBox", 8)
	_variation(theme, &"ChoiceRowLines", &"VBoxContainer")
	theme.set_constant(&"separation", &"ChoiceRowLines", 0)
	# A one-line warning in a dialog, tinted
	_variation(theme, &"Callout", &"PanelContainer")
	theme.set_stylebox(&"panel", &"Callout", _box(p.background.blend(Color(p.modified, 0.12)), 4,
			Vector4(8, 6, 8, 6), Color(p.modified, 0.5), 1))
	# What a preview found, in tinted pills (the merge dialog's "No conflicts",
	# "12 files"): the tone's colour on a light wash of it
	theme.set_font_size(&"font_size", &"SummaryBadge", 12)
	theme.set_constant(&"icon_size", &"SummaryBadge", 12)
	theme.set_constant(&"separation", &"SummaryBadge", 4)
	theme.set_constant(&"gap", &"SummaryBadge", 6)
	for entry: Array in [[&"success", p.added, p.added], [&"error", p.error, p.error],
			[&"accent", p.accent_text, p.accent], [&"warning", p.modified, p.modified],
			[&"neutral", p.text_muted, p.text]]:
		theme.set_color(StringName(String(entry[0]) + "_color"), &"SummaryBadge", entry[1])
		theme.set_stylebox(entry[0], &"SummaryBadge", _box(Color(entry[2], 0.16), 9, Vector4(7, 1, 8, 2)))
	# The merge dialog: chips, badges, the strategy, then capped lists
	theme.set_constant(&"width", &"MergeDialog", 540)
	theme.set_constant(&"separation", &"MergeDialog", 10)
	theme.set_constant(&"list_rows", &"MergeDialog", 6)
	theme.set_constant(&"row_height", &"MergeDialog", 24)
	theme.set_constant(&"avatar_size", &"MergeDialog", 16)
	theme.set_font_size(&"chip_font_size", &"MergeDialog", 14)
	theme.set_constant(&"width", &"SettingsDialog", 840)
	theme.set_constant(&"height", &"SettingsDialog", 540)
	theme.set_constant(&"label_width", &"SettingsDialog", 220)


static func _add_history(theme: Theme, p: Palette) -> void:
	theme.set_color(&"selection_color", &"VirtualList", p.selected_focus)
	theme.set_color(&"cursor_color", &"VirtualList", Color(p.accent, 0.9))
	theme.set_constant(&"row_height", &"VirtualList", 24)
	# Middle-click autoscroll: no scrolling within `dead_zone` px of the click,
	# then `speed_percent` / 100 × (distance past it)^1.5 px/s, at most `max_speed`.
	theme.set_constant(&"dead_zone", &"AutoScroll", 8)
	theme.set_constant(&"speed_percent", &"AutoScroll", 170)
	theme.set_constant(&"max_speed", &"AutoScroll", 6000)
	for i: int in p.lanes.size():
		theme.set_color(StringName("lane_%d" % i), &"GraphView", p.lanes[i])
	theme.set_color(&"node_outline", &"GraphView", p.background)
	theme.set_constant(&"lane_width", &"GraphView", 14)
	theme.set_constant(&"line_width", &"GraphView", 2)
	theme.set_constant(&"max_lanes", &"GraphView", 24)
	theme.set_constant(&"node_radius", &"GraphView", 4)
	theme.set_color(&"subject_color", &"CommitList", p.text)
	# History search: rows it does not match fade, the query is highlighted
	theme.set_color(&"dim_subject_color", &"CommitList", Color(p.text, 0.4))
	theme.set_color(&"dim_node_color", &"CommitList", Color(1, 1, 1, 0.35))
	theme.set_color(&"match_color", &"CommitList", Color(p.modified, 0.4))
	theme.set_constant(&"padding", &"CommitList", 8)
	theme.set_constant(&"label_gap", &"CommitList", 4)
	theme.set_constant(&"outgoing_icon_size", &"CommitList", 14)
	theme.set_color(&"outgoing_color", &"CommitList", p.accent)
	# Two-line rows (M7.10): the subject, then avatars and "Author +N · when".
	theme.set_constant(&"two_line_row_height", &"CommitList", 50)
	theme.set_constant(&"line_gap", &"CommitList", 3)
	theme.set_font_size(&"meta_font_size", &"CommitList", 12)
	theme.set_color(&"meta_color", &"CommitList", p.text_muted)
	theme.set_color(&"divider_color", &"CommitList", Color(p.border, 0.7))
	theme.set_constant(&"avatar_size", &"CommitList", 20)
	theme.set_constant(&"avatar_overlap", &"CommitList", 4)
	theme.set_constant(&"avatar_gap", &"CommitList", 6)
	# Compact rows: the author's avatar on the right, after the ref icons.
	theme.set_constant(&"compact_avatar_size", &"CommitList", 18)
	# Compare's Include pill on the left side's section (outlined off, filled on)
	var pill: Vector4 = Vector4(7, 1, 7, 1)
	theme.set_stylebox(&"include_off", &"CommitList", _box(Color.TRANSPARENT, 8, pill, p.border, 1))
	theme.set_stylebox(&"include_off_hover", &"CommitList", _box(p.hover, 8, pill, p.border, 1))
	theme.set_stylebox(&"include_on", &"CommitList", _box(Color(p.accent, 0.3), 8, pill, Color(p.accent, 0.6), 1))
	theme.set_stylebox(&"include_on_hover", &"CommitList", _box(Color(p.accent, 0.4), 8, pill, Color(p.accent, 0.8), 1))
	theme.set_color(&"include_color", &"CommitList", p.text_muted)
	theme.set_color(&"include_on_color", &"CommitList", p.text)
	theme.set_font_size(&"include_font_size", &"CommitList", 11)
	_add_avatars(theme, p)
	_add_ref_chips(theme, p)
	_add_commit_details(theme, p)


## Ref chips (`RefChip`, M7.10): branches square-cornered, tags round pills,
## each with its icon; a remote branch's "origin/" in a lighter ink.
static func _add_ref_chips(theme: Theme, p: Palette) -> void:
	theme.set_font_size(&"font_size", &"RefChip", 12)
	theme.set_color(&"text_color", &"RefChip", DARK_TEXT)
	theme.set_color(&"prefix_color", &"RefChip", Color(DARK_TEXT, 0.65))
	theme.set_constant(&"icon_size", &"RefChip", 12)
	theme.set_constant(&"icon_gap", &"RefChip", 3)
	theme.set_constant(&"max_width", &"RefChip", 160)
	for entry: Array in [[&"head", p.label_head], [&"branch", p.label_branch], [&"remote", p.label_remote]]:
		theme.set_stylebox(StringName("chip_%s" % entry[0]), &"RefChip", _box(entry[1], 3, Vector4(5, 1, 6, 1)))
	theme.set_stylebox(&"chip_tag", &"RefChip", _box(p.label_tag, 9, Vector4(6, 1, 8, 1)))


## Avatars without a picture: initials on one of these colours, chosen
## from the email (`AvatarPainter`). Muted mid tones with light text in the
## dark theme, pale ones with dark text in the light theme, so they read on
## the lists and the selection without competing with the graph lanes.
static func _add_avatars(theme: Theme, p: Palette) -> void:
	const HUES: Array[float] = [0.02, 0.08, 0.15, 0.30, 0.45, 0.55, 0.66, 0.76, 0.86, 0.94]
	theme.set_constant(&"colors", &"Avatar", HUES.size())
	for i: int in HUES.size():
		var fill: Color = Color.from_ok_hsl(HUES[i], 0.65, 0.76) if p.light 				else Color.from_ok_hsl(HUES[i], 0.42, 0.42)
		var text: Color = Color.from_ok_hsl(HUES[i], 0.70, 0.28) if p.light 				else Color.from_ok_hsl(HUES[i], 0.30, 0.94)
		theme.set_color(StringName("color_%d" % i), &"Avatar", fill)
		theme.set_color(StringName("text_%d" % i), &"Avatar", text)
	# Around avatars that overlap: the list's background.
	theme.set_color(&"ring_color", &"Avatar", p.background)


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
	# The people (M7.10): a card each, avatar beside name (and role) over email.
	_variation(theme, &"DetailsPeople", &"HFlowContainer")
	theme.set_constant(&"h_separation", &"DetailsPeople", 20)
	theme.set_constant(&"v_separation", &"DetailsPeople", 8)
	_variation(theme, &"DetailsPerson", &"HBoxContainer")
	theme.set_constant(&"separation", &"DetailsPerson", 8)
	_variation(theme, &"DetailsPersonLines", &"VBoxContainer")
	theme.set_constant(&"separation", &"DetailsPersonLines", 0)
	_variation(theme, &"DetailsRole", &"Label")
	theme.set_color(&"font_color", &"DetailsRole", p.text_muted)
	theme.set_font_size(&"font_size", &"DetailsRole", 12)
	theme.set_constant(&"avatar_size", &"CommitDetails", 30)
	_variation(theme, &"DetailsRefs", &"HFlowContainer")
	theme.set_constant(&"h_separation", &"DetailsRefs", 4)
	theme.set_constant(&"v_separation", &"DetailsRefs", 4)
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
	_variation(theme, &"DetailsParentLink", &"LinkButton")
	theme.set_font(&"font", &"DetailsParentLink", mono_font())
	theme.set_font_size(&"font_size", &"DetailsParentLink", 13)
	theme.set_color(&"font_color", &"DetailsParentLink", p.text_muted)
	theme.set_stylebox(&"focus", &"DetailsParentLink", theme.get_stylebox(&"focus", &"Button"))
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
	_variation(theme, &"DiffHeaderRow", &"HBoxContainer")
	theme.set_constant(&"separation", &"DiffHeaderRow", 6)
	theme.set_constant(&"layout_gap", &"DiffHeader", 10)
	# Line counts in the git colours: `+12 −3`
	for entry: Array in [[&"StatAdded", p.added], [&"StatRemoved", p.removed]]:
		_variation(theme, entry[0], &"Label")
		theme.set_color(&"font_color", entry[0], entry[1])
	_variation(theme, &"StatRow", &"HBoxContainer")
	theme.set_constant(&"separation", &"StatRow", 4)
	theme.set_constant(&"files_width", &"ChangesView", 360)
	theme.set_constant(&"separation", &"ChangesView", 6)
	theme.set_constant(&"body_height", &"CommitBox", 96)
	theme.set_constant(&"output_height", &"CommitBox", 120)
	theme.set_color(&"path_color", &"ChangeList", p.text)
	theme.set_color(&"dir_color", &"ChangeList", p.text_muted)
	for entry: Array in [[&"added", p.added], [&"modified", p.modified], [&"deleted", p.removed],
			[&"renamed", p.renamed], [&"untracked", p.added], [&"conflict", p.error]]:
		theme.set_color(StringName("%s_color" % entry[0]), &"ChangeList", entry[1])
	theme.set_color(&"resolved_color", &"ChangeList", p.added)
	theme.set_color(&"divider_color", &"ChangeList", p.border)
	theme.set_color(&"ignored_color", &"ChangeList", Color(p.text_muted, 0.75))
	theme.set_constant(&"padding", &"ChangeList", 8)
	theme.set_constant(&"code_width", &"ChangeList", 22)
	theme.set_constant(&"icon_size", &"ChangeList", 14)
	# The `EOL` chip of a file whose only changes are line endings.
	theme.set_color(&"chip_color", &"ChangeList", p.text_muted)
	theme.set_color(&"chip_bg", &"ChangeList", Color(p.text_muted, 0.16))
	theme.set_font_size(&"chip_font_size", &"ChangeList", 10)
	theme.set_constant(&"chip_radius", &"ChangeList", 3)
	# The image viewer (M7.8): a checkerboard behind transparent pixels, each
	# image's outline, the swipe divider and the difference highlight.
	var checker_light: Color = p.background.lerp(Color.WHITE, 0.12 if p.light else 0.06)
	var checker_dark: Color = p.background.lerp(Color.BLACK, 0.06 if p.light else 0.12)
	theme.set_color(&"checker_light", &"ImageDiff", checker_light)
	theme.set_color(&"checker_dark", &"ImageDiff", checker_dark)
	theme.set_color(&"outline_color", &"ImageDiff", p.border)
	theme.set_color(&"divider_color", &"ImageDiff", p.accent)
	theme.set_color(&"changed_color", &"ImageDiff", Color(1.0, 0.2, 0.75) if not p.light else Color(0.85, 0.0, 0.55))
	theme.set_color(&"caption_color", &"ImageDiff", p.text_muted)
	theme.set_color(&"message_color", &"ImageDiff", p.text_muted)
	theme.set_constant(&"checker_size", &"ImageDiff", 8)
	theme.set_constant(&"margin", &"ImageDiff", 12)
	theme.set_constant(&"gap", &"ImageDiff", 12)
	theme.set_constant(&"handle_size", &"ImageDiff", 14)
	theme.set_constant(&"card_preview_height", &"ImageDiff", 200)
	# Behind the zoom bar's buttons, which float over the image.
	_variation(theme, &"ImageZoomBar", &"PanelContainer")
	theme.set_stylebox(&"panel", &"ImageZoomBar", _box(p.background, 4))
	# Diff backgrounds are the git colours blended into the background, so they
	# follow both themes.
	theme.set_font(&"font", &"DiffView", mono_font())
	theme.set_font_size(&"font_size", &"DiffView", 13)
	theme.set_color(&"text_color", &"DiffView", p.text)
	# Under the rows (not drawn by the view): what text is made readable on
	theme.set_color(&"background", &"DiffView", p.background)
	theme.set_color(&"line_number_color", &"DiffView", p.text_muted)
	theme.set_color(&"hunk_color", &"DiffView", p.text_muted)
	theme.set_color(&"hunk_bg", &"DiffView", p.background.blend(Color(p.accent, 0.1)))
	theme.set_color(&"added_bg", &"DiffView", p.background.blend(Color(p.added, 0.16)))
	theme.set_color(&"removed_bg", &"DiffView", p.background.blend(Color(p.removed, 0.16)))
	var word_tint: float = word_tint_percent / 100.0
	theme.set_color(&"added_hl_bg", &"DiffView", p.background.blend(Color(p.added, word_tint)))
	theme.set_color(&"removed_hl_bg", &"DiffView", p.background.blend(Color(p.removed, word_tint)))
	theme.set_color(&"added_mark", &"DiffView", p.added)
	theme.set_color(&"removed_mark", &"DiffView", p.removed)
	theme.set_color(&"gutter_bg", &"DiffView", p.surface)
	theme.set_color(&"empty_bg", &"DiffView", p.surface)
	for kind_name: String in p.syntax:
		theme.set_color(syntax_color_name(kind_name), &"DiffView", p.syntax[kind_name])
	theme.set_color(&"message_color", &"DiffView", p.text_muted)
	theme.set_color(&"selection_bg", &"DiffView", Color(p.accent, 0.35))
	theme.set_color(&"caret_color", &"DiffView", p.text)
	theme.set_color(&"expander_color", &"DiffView", p.text_muted)
	theme.set_color(&"expander_hover_color", &"DiffView", p.text)
	theme.set_color(&"expander_hover_bg", &"DiffView", p.hover)
	# Conflict blocks (the resolver): ours and theirs in their own colours (not
	# the diff's red and green), the base between them, block buttons
	theme.set_color(&"ours_bg", &"DiffView", p.background.blend(Color(p.ours, 0.16)))
	theme.set_color(&"theirs_bg", &"DiffView", p.background.blend(Color(p.theirs, 0.14)))
	theme.set_color(&"ours_mark", &"DiffView", p.ours)
	theme.set_color(&"theirs_mark", &"DiffView", p.theirs)
	theme.set_color(&"base_bg", &"DiffView", p.background.blend(Color(p.text_muted, 0.12)))
	theme.set_color(&"base_mark", &"DiffView", p.text_muted)
	theme.set_color(&"block_header_bg", &"DiffView", p.surface)
	theme.set_color(&"block_header_color", &"DiffView", p.text_muted)
	theme.set_color(&"block_icon_color", &"DiffView", p.error)
	theme.set_color(&"choice_flash", &"DiffView", Color(p.added, 0.3))
	theme.set_color(&"block_button_bg", &"DiffView", p.raised)
	theme.set_color(&"block_button_hover_bg", &"DiffView", p.hover)
	theme.set_color(&"block_button_color", &"DiffView", p.text)
	theme.set_font_size(&"header_font_size", &"DiffView", 13)
	# A conflict without blocks: its icon and the binary sides' sizes
	theme.set_constant(&"card_icon_size", &"DiffView", 32)
	_variation(theme, &"ConflictCardTable", &"GridContainer")
	theme.set_constant(&"h_separation", &"ConflictCardTable", 8)
	theme.set_constant(&"v_separation", &"ConflictCardTable", 2)
	theme.set_constant(&"row_height", &"DiffView", 20)
	theme.set_constant(&"padding", &"DiffView", 8)
	# Marks over a whole list beside its scroll bar (History's search hits):
	# the selected one stronger and taller
	theme.set_color(&"background", &"MarkStrip", Color(p.text, 0.04))
	theme.set_color(&"mark_color", &"MarkStrip", Color(p.accent, 0.6))
	theme.set_color(&"current_color", &"MarkStrip", p.accent)
	theme.set_constant(&"width", &"MarkStrip", 6)
	theme.set_constant(&"min_mark", &"MarkStrip", 2)
	theme.set_constant(&"current_height", &"MarkStrip", 4)
	# How long a jump (a minimap click, the next change) eases, in ms
	theme.set_constant(&"ease_msec", &"DiffView", 120)
	# The diff's minimap (M7.6): rows in stronger tints than the diff's, text
	# as faint blocks, a box for the visible rows and a strip of change marks
	theme.set_color(&"background", &"DiffMinimap", p.background)
	theme.set_color(&"border_color", &"DiffMinimap", p.border)
	theme.set_color(&"context_bg", &"DiffMinimap", Color.TRANSPARENT)
	theme.set_color(&"header_bg", &"DiffMinimap", Color(p.accent, 0.18))
	theme.set_color(&"added_bg", &"DiffMinimap", Color(p.added, 0.38))
	theme.set_color(&"removed_bg", &"DiffMinimap", Color(p.removed, 0.38))
	theme.set_color(&"ours_bg", &"DiffMinimap", Color(p.ours, 0.4))
	theme.set_color(&"theirs_bg", &"DiffMinimap", Color(p.theirs, 0.4))
	theme.set_color(&"base_bg", &"DiffMinimap", Color(p.text_muted, 0.25))
	theme.set_color(&"resolved_bg", &"DiffMinimap", Color(p.added, 0.3))
	theme.set_color(&"added_word", &"DiffMinimap", Color(p.added, word_tint))
	theme.set_color(&"removed_word", &"DiffMinimap", Color(p.removed, word_tint))
	theme.set_color(&"text_color", &"DiffMinimap", Color(p.text, 0.45))
	for kind_name: String in p.syntax:
		var alpha: float = 0.6 if kind_name.begins_with("comment") else 0.75
		theme.set_color(syntax_color_name(kind_name), &"DiffMinimap", Color(p.syntax[kind_name], alpha))
	theme.set_color(&"divider_color", &"DiffMinimap", Color(p.text_muted, 0.7))
	theme.set_color(&"veil_color", &"DiffMinimap", Color(p.background, 0.6))
	theme.set_color(&"slider_color", &"DiffMinimap", Color(p.text, 0.16))
	theme.set_color(&"slider_hover_color", &"DiffMinimap", Color(p.text, 0.26))
	theme.set_color(&"strip_background", &"DiffMinimap", p.surface)
	theme.set_color(&"thumb_color", &"DiffMinimap", Color(p.text, 0.24))
	theme.set_color(&"thumb_hover_color", &"DiffMinimap", Color(p.text, 0.38))
	theme.set_color(&"selection_color", &"DiffMinimap", Color(p.accent, 0.5))
	theme.set_color(&"added_mark", &"DiffMinimap", p.added)
	theme.set_color(&"removed_mark", &"DiffMinimap", p.removed)
	theme.set_color(&"conflict_mark", &"DiffMinimap", p.error)
	theme.set_color(&"resolved_mark", &"DiffMinimap", p.added)
	# Sizes: the whole column, its strip, the strip alone (minimap off or a
	# narrow diff), a row and a character, the diff width under which only the
	# strip shows, the strip's thumb and visible-rows shade, and how opaque
	# marks of lines left out of the commit are
	theme.set_constant(&"width", &"DiffMinimap", 100)
	theme.set_constant(&"strip_width", &"DiffMinimap", 6)
	theme.set_constant(&"strip_only_width", &"DiffMinimap", 12)
	theme.set_constant(&"row_height", &"DiffMinimap", 2)
	theme.set_constant(&"char_width", &"DiffMinimap", 1)
	theme.set_constant(&"narrow_width", &"DiffMinimap", 600)
	theme.set_constant(&"min_thumb", &"DiffMinimap", 20)
	theme.set_constant(&"min_shade", &"DiffMinimap", 4)
	theme.set_constant(&"left_out_percent", &"DiffMinimap", 40)


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
	theme.set_constant(&"separation", &"ChipRow", 2)
	# Worktree chips: plain text with a hover background, the shown one filled
	var chip: Vector4 = Vector4(10, 4, 10, 4)
	for entry: Array in [[&"WorktreeChip", Color.TRANSPARENT], [&"WorktreeChipHover", p.hover],
			[&"WorktreeChipSelected", Color(p.accent, 0.25)]]:
		_variation(theme, entry[0], &"PanelContainer")
		theme.set_stylebox(&"panel", entry[0], _box(entry[1], 6, chip))
		theme.set_stylebox(&"focus", entry[0], _box(Color.TRANSPARENT, 6, Vector4.ZERO, p.accent, 2))
	theme.set_constant(&"max_width", &"WorktreeChip", 200)
	theme.set_constant(&"separation", &"WorktreeChip", 7)
	theme.set_constant(&"marker_size", &"WorktreeChip", 12)
	theme.set_color(&"changes_color", &"WorktreeChip", p.modified)
	theme.set_color(&"conflict_color", &"WorktreeChip", p.error)
	for entry: Array in [[&"WorktreeChipName", p.text_muted], [&"WorktreeChipNameSelected", p.text],
			[&"WorktreeChipNameMissing", Color(p.text_muted, 0.55)]]:
		_variation(theme, entry[0], &"Label")
		theme.set_color(&"font_color", entry[0], entry[1])
	# A chip's tooltip card: bold folder, branch, dim path, then status lines
	_variation(theme, &"WorktreeTooltip", &"VBoxContainer")
	theme.set_constant(&"separation", &"WorktreeTooltip", 4)
	theme.set_constant(&"icon_size", &"WorktreeTooltip", 16)
	theme.set_constant(&"path_width", &"WorktreeTooltip", 480)
	_variation(theme, &"WorktreeTooltipStatus", &"VBoxContainer")
	theme.set_constant(&"separation", &"WorktreeTooltipStatus", 2)
	_variation(theme, &"WorktreeTooltipTitle", &"TooltipLabel")
	theme.set_font(&"font", &"WorktreeTooltipTitle", bold_font())
	_variation(theme, &"WorktreeTooltipDim", &"TooltipLabel")
	theme.set_color(&"font_color", &"WorktreeTooltipDim", p.text_muted)
	# The worktree icon that starts the strip, and the line after the main worktree
	_variation(theme, &"WorktreeRowIcon", &"ToolbarButton")
	theme.set_color(&"icon_normal_color", &"WorktreeRowIcon", Color(1, 1, 1, 0.7))
	_variation(theme, &"ChipSeparator", &"VSeparator")
	theme.set_constant(&"separation", &"ChipSeparator", 9)
	var chip_line: StyleBoxLine = StyleBoxLine.new()
	chip_line.color = p.border
	chip_line.vertical = true
	chip_line.grow_begin = -5.0
	chip_line.grow_end = -5.0
	theme.set_stylebox(&"separator", &"ChipSeparator", chip_line)
	# Branch and Sync: big raised buttons with room for a ▾ part
	_variation(theme, &"HeaderRow", &"HBoxContainer")
	theme.set_constant(&"separation", &"HeaderRow", 8)
	_variation(theme, &"BigButton", &"Button")
	_variation(theme, &"BigMenuButton", &"BigButton")
	var big_arrow: float = ARROW_DOWN.get_width() + 2 * SPLIT_ARROW_PADDING
	for entry: Array in [[&"BigButton", Vector4(12, 7, 14, 7)], [&"BigMenuButton", Vector4(12, 7, 12 + big_arrow, 7)]]:
		var margins: Vector4 = entry[1]
		theme.set_stylebox(&"normal", entry[0], _box(p.raised, 6, margins, p.border, 1))
		theme.set_stylebox(&"hover", entry[0], _box(p.hover, 6, margins, p.border, 1))
		theme.set_stylebox(&"pressed", entry[0], _box(Color(p.accent, 0.35), 6, margins, p.accent, 1))
		theme.set_stylebox(&"hover_pressed", entry[0], _box(Color(p.accent, 0.35), 6, margins, p.accent, 1))
		theme.set_stylebox(&"disabled", entry[0], _box(Color(p.raised, 0.5), 6, margins, p.border, 1))
		theme.set_stylebox(&"focus", entry[0], _box(Color.TRANSPARENT, 6, Vector4.ZERO, p.accent, 1))
	theme.set_font_size(&"font_size", &"BigButton", 15)
	# Leaves room for the view switch beside them in a narrow window
	theme.set_constant(&"max_width", &"BigButton", 320)
	theme.set_constant(&"h_separation", &"BigButton", 8)
	theme.set_constant(&"arrow_width", &"BigButton", ARROW_DOWN.get_width() + 2 * SPLIT_ARROW_PADDING)
	theme.set_color(&"separator_color", &"BigButton", p.border)
	theme.set_color(&"progress_color", &"BigButton", p.accent)
	# The Changes | History | Shelves tabs: one recessed track, the shown tab
	# raised in the accent, a divider before Branch and Sync
	theme.set_constant(&"separation", &"ViewSwitch", 2)
	_variation(theme, &"ViewTabs", &"PanelContainer")
	theme.set_stylebox(&"panel", &"ViewTabs", _box(p.background, 6, Vector4(3, 3, 3, 3), p.border, 1))
	_variation(theme, &"ViewTab", &"Button")
	var tab: Vector4 = Vector4(12, 4, 12, 4)
	theme.set_stylebox(&"normal", &"ViewTab", _box(Color.TRANSPARENT, 4, tab))
	theme.set_stylebox(&"hover", &"ViewTab", _box(p.hover, 4, tab))
	theme.set_stylebox(&"pressed", &"ViewTab", _box(Color(p.accent, 0.35), 4, tab, p.accent, 1))
	theme.set_stylebox(&"hover_pressed", &"ViewTab", _box(Color(p.accent, 0.4), 4, tab, p.accent, 1))
	# A choice that cannot be made now (the merge dialog's strategies)
	theme.set_stylebox(&"disabled", &"ViewTab", _box(Color.TRANSPARENT, 4, tab))
	theme.set_color(&"font_color", &"ViewTab", p.text_muted)
	theme.set_color(&"icon_normal_color", &"ViewTab", Color(1, 1, 1, 0.6))
	_variation(theme, &"HeaderDivider", &"VSeparator")
	theme.set_constant(&"separation", &"HeaderDivider", 17)
	var divider: StyleBoxLine = StyleBoxLine.new()
	divider.color = p.border
	divider.vertical = true
	divider.grow_begin = -4.0
	divider.grow_end = -4.0
	theme.set_stylebox(&"separator", &"HeaderDivider", divider)
	_variation(theme, &"SegmentButton", &"Button")
	var segment: Vector4 = Vector4(10, 4, 10, 4)
	theme.set_stylebox(&"normal", &"SegmentButton", _box(p.raised, 4, segment))
	theme.set_stylebox(&"hover", &"SegmentButton", _box(p.hover, 4, segment))
	theme.set_stylebox(&"pressed", &"SegmentButton", _box(Color(p.accent, 0.35), 4, segment))
	theme.set_stylebox(&"hover_pressed", &"SegmentButton", _box(Color(p.accent, 0.4), 4, segment))
	# The number of changes on the Changes button, in a pill
	_variation(theme, &"CountBadge", &"Label")
	theme.set_stylebox(&"normal", &"CountBadge", _box(Color(p.text, 0.16), 8, Vector4(6, 0, 6, 1)))
	theme.set_color(&"font_color", &"CountBadge", p.text)
	theme.set_font_size(&"font_size", &"CountBadge", 11)
	theme.set_constant(&"gap", &"CountBadge", 6)
	# Commits to push and to pull in pills (an arrow and the count): outgoing
	# in the accent, incoming in amber, wherever ahead/behind shows
	theme.set_font(&"font", &"SyncCounts", bold_font())
	theme.set_font_size(&"font_size", &"SyncCounts", 11)
	theme.set_constant(&"padding", &"SyncCounts", 4)
	theme.set_constant(&"padding_vertical", &"SyncCounts", 1)
	theme.set_constant(&"icon_separation", &"SyncCounts", 2)
	theme.set_constant(&"separation", &"SyncCounts", 4)
	theme.set_constant(&"button_gap", &"SyncCounts", 8)
	for entry: Array in [[&"ahead", p.accent_text, p.accent], [&"behind", p.incoming, p.incoming]]:
		theme.set_color(StringName(String(entry[0]) + "_color"), &"SyncCounts", entry[1])
		theme.set_stylebox(entry[0], &"SyncCounts", _box(Color(entry[2], 0.2), 8))
	# Icon-only joined buttons (the diff layout): one outline, rounded
	# outside; IconToggle is one on its own (the diff's whole-file switch).
	_variation(theme, &"IconSwitch", &"HBoxContainer")
	theme.set_constant(&"separation", &"IconSwitch", 0)
	var icon_segment: Vector4 = Vector4(7, 4, 7, 4)
	for entry: Array in [[&"IconSegmentFirst", "first"], [&"IconSegmentMiddle", "middle"],
			[&"IconSegmentLast", "last"], [&"IconToggle", "alone"]]:
		_variation(theme, entry[0], &"SegmentButton")
		for state: Array in [[&"normal", p.raised], [&"hover", p.hover],
				[&"pressed", Color(p.accent, 0.35)], [&"hover_pressed", Color(p.accent, 0.4)]]:
			var box: StyleBoxFlat = _box(state[1], 4, icon_segment, p.border, 1)
			if entry[1] == "first":
				box.corner_radius_top_right = 0
				box.corner_radius_bottom_right = 0
			elif entry[1] in ["middle", "last"]:
				box.corner_radius_top_left = 0
				box.corner_radius_bottom_left = 0
				box.border_width_left = 0
				if entry[1] == "middle":
					box.corner_radius_top_right = 0
					box.corner_radius_bottom_right = 0
			theme.set_stylebox(state[0], entry[0], box)
	# Panes: the left columns, a status line, details
	_variation(theme, &"PaneColumn", &"VBoxContainer")
	theme.set_constant(&"separation", &"PaneColumn", 0)
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
	theme.set_color(&"icon_color", &"OperationBanner", p.error)
	# The rebase step in the banner, "2 / 5"
	_variation(theme, &"StepPill", &"Label")
	theme.set_stylebox(&"normal", &"StepPill", _box(Color(p.text, 0.12), 9, Vector4(7, 0, 7, 1)))
	theme.set_font_size(&"font_size", &"StepPill", 12)
	# Once every conflict is resolved, it turns green: ready to commit
	_variation(theme, &"OperationBannerReady", &"PanelContainer")
	var ready_banner: StyleBoxFlat = _box(p.background.blend(Color(p.added, 0.16)), 0, Vector4(12, 6, 8, 6))
	ready_banner.border_color = p.added
	ready_banner.border_width_bottom = 1
	theme.set_stylebox(&"panel", &"OperationBannerReady", ready_banner)
	theme.set_color(&"icon_color", &"OperationBannerReady", p.added)
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
	theme.set_color(&"icon_color", &"BranchPopover", Color(1, 1, 1, 0.6))
	# Remotes… and Tags…
	theme.set_constant(&"width", &"ManageDialog", 620)
	theme.set_constant(&"height", &"ManageDialog", 380)
	# Repository → Ignore rules…
	theme.set_constant(&"width", &"IgnoreRulesDialog", 960)
	theme.set_constant(&"height", &"IgnoreRulesDialog", 560)
	theme.set_constant(&"lines_width", &"IgnoreRulesDialog", 480)
	theme.set_constant(&"recap_separation", &"IgnoreRulesDialog", 6)
	theme.set_color(&"comment_color", &"IgnoreRulesDialog", p.text_muted)
	theme.set_color(&"negation_color", &"IgnoreRulesDialog", p.added)
	theme.set_color(&"tracked_color", &"IgnoreRulesDialog", p.modified)
	theme.set_color(&"unused_color", &"IgnoreRulesDialog", Color(p.text_muted, 0.8))
	theme.set_constant(&"bottom_margin", &"Toasts", 40)


## The Changes view of M6.5 P3: commit checkboxes, the list header, the
## commit panel and empty states with suggested actions.
static func _add_changes_p3(theme: Theme, p: Palette) -> void:
	theme.set_constant(&"size", &"PickBox", 14)
	theme.set_color(&"border_color", &"PickBox", p.text_muted)
	theme.set_color(&"fill_color", &"PickBox", p.accent)
	theme.set_color(&"mark_color", &"PickBox", readable_text([p.accent], DARK_TEXT))
	theme.set_constant(&"dim_percent", &"PickBox", 40)
	# The line above every list (changed files, commits, a commit's files):
	# one height and one text style, with or without the check-all box. A
	# tinted band with a divider, so it stays apart from a selected first row.
	_variation(theme, &"ListHeader", &"PanelContainer")
	var header: StyleBoxFlat = _box(p.surface, 0, Vector4(8, 0, 10, 0))
	header.border_color = p.border
	header.border_width_bottom = 1
	theme.set_stylebox(&"panel", &"ListHeader", header)
	theme.set_constant(&"height", &"ListHeader", 30)
	_variation(theme, &"ListHeaderRow", &"HBoxContainer")
	theme.set_constant(&"separation", &"ListHeaderRow", 8)
	_variation(theme, &"ListHeaderLabel", &"Label")
	theme.set_color(&"font_color", &"ListHeaderLabel", p.text_muted)
	theme.set_font_size(&"font_size", &"ListHeaderLabel", 13)
	for entry: Array in [[&"ListHeaderAdded", &"StatAdded"], [&"ListHeaderRemoved", &"StatRemoved"]]:
		_variation(theme, entry[0], entry[1])
		theme.set_font_size(&"font_size", entry[0], 13)
	# A short status on the right of a list header ("1 of 2 resolved").
	_variation(theme, &"ListHeaderStatus", &"Label")
	theme.set_font_size(&"font_size", &"ListHeaderStatus", 13)
	theme.set_constant(&"icon_size", &"ListHeaderStatus", 14)
	# The filter over a list: one field filling the bar, with a search icon
	# (in line with the list's checkboxes), a flat text box, a divider and the
	# options button. A line under it, in the accent colour and thicker while
	# focused. Its own vertical padding sets the bar's height.
	_variation(theme, &"FilterBar", &"PanelContainer")
	theme.set_stylebox(&"panel", &"FilterBar", _box(p.background))
	# Compare's bar of sides: a filter bar with a line under it.
	_variation(theme, &"CompareBar", &"PanelContainer")
	var compare_bar: StyleBoxFlat = _box(p.background)
	compare_bar.border_color = p.border
	compare_bar.border_width_bottom = 1
	theme.set_stylebox(&"panel", &"CompareBar", compare_bar)
	# File history (M8a): a row says what its commit did to the file, as a
	# chip in the change's colour and the lines added and removed; the bar's
	# "as of …" names a start other than the current branch.
	for entry: Array in [[&"added", p.added], [&"renamed", p.renamed], [&"deleted", p.removed]]:
		theme.set_color(StringName("%s_color" % entry[0]), &"FileHistory", entry[1])
	theme.set_color(&"stat_added_color", &"FileHistory", p.added)
	theme.set_color(&"stat_removed_color", &"FileHistory", p.removed)
	theme.set_font_size(&"chip_font_size", &"FileHistory", 10)
	theme.set_font_size(&"stat_font_size", &"FileHistory", 12)
	theme.set_constant(&"chip_radius", &"FileHistory", 3)
	theme.set_constant(&"chip_padding", &"FileHistory", 4)
	theme.set_constant(&"mark_gap", &"FileHistory", 6)
	# Blame (M8b): the gutter before the file's lines names each run's
	# commit; a bar in the commit's age, from faint (the file's oldest) to
	# the accent (its newest); the focused commit's lines tinted.
	theme.set_font_size(&"meta_font_size", &"BlameView", 12)
	theme.set_constant(&"gap", &"BlameView", 8)
	theme.set_constant(&"age_bar_width", &"BlameView", 3)
	theme.set_constant(&"avatar_size", &"BlameView", 16)
	theme.set_constant(&"author_width", &"BlameView", 116)
	theme.set_constant(&"date_width", &"BlameView", 78)
	theme.set_color(&"author_color", &"BlameView", p.text)
	theme.set_color(&"meta_color", &"BlameView", p.text_muted)
	theme.set_color(&"separator_color", &"BlameView", p.border)
	theme.set_color(&"focus_bg", &"BlameView", Color(p.accent, 0.28))
	theme.set_color(&"focus_line_bg", &"BlameView", Color(p.accent, 0.12))
	theme.set_color(&"minimap_focus_bg", &"BlameView", Color(p.accent, 0.4))
	theme.set_color(&"minimap_focus_mark", &"BlameView", p.accent)
	theme.set_color(&"hover_bg", &"BlameView", p.hover)
	theme.set_color(&"age_old_color", &"BlameView", Color(p.accent, 0.12))
	theme.set_color(&"age_new_color", &"BlameView", p.accent)
	theme.set_color(&"working_color", &"BlameView", p.modified)
	theme.set_color(&"working_text_color", &"BlameView", p.text_muted)
	# The row of the commit a blamed line was clicked on, in the versions
	theme.set_color(&"marked_color", &"FileHistory", p.accent)
	theme.set_constant(&"marked_width", &"FileHistory", 3)
	# The strip over the blame: which version it reads, how far it is
	_variation(theme, &"BlameBar", &"PanelContainer")
	var blame_bar: StyleBoxFlat = _box(p.surface, 0, Vector4(10, 4, 6, 4))
	blame_bar.border_color = p.border
	blame_bar.border_width_bottom = 1
	theme.set_stylebox(&"panel", &"BlameBar", blame_bar)
	# Its bar names the file: a line of text, padded like a list header.
	_variation(theme, &"FileBar", &"PanelContainer")
	var file_bar: StyleBoxFlat = _box(p.background, 0, Vector4(10, 8, 10, 8))
	file_bar.border_color = p.border
	file_bar.border_width_bottom = 1
	theme.set_stylebox(&"panel", &"FileBar", file_bar)
	_variation(theme, &"FileHistoryStart", &"Label")
	theme.set_color(&"font_color", &"FileHistoryStart", p.text_muted)
	theme.set_font_size(&"font_size", &"FileHistoryStart", 12)
	theme.set_stylebox(&"normal", &"FileHistoryStart", _box(Color(p.text_muted, 0.16), 3, Vector4(6, 1, 6, 1)))
	var filter: StyleBoxFlat = _box(p.raised, 0, Vector4(8, 6, 4, 6))
	filter.border_color = p.border
	filter.border_width_bottom = 1
	_variation(theme, &"FilterField", &"PanelContainer")
	theme.set_stylebox(&"panel", &"FilterField", filter)
	var filter_focus: StyleBoxFlat = filter.duplicate() as StyleBoxFlat
	filter_focus.border_color = p.accent
	filter_focus.border_width_bottom = 2
	_variation(theme, &"FilterFieldFocus", &"FilterField")
	theme.set_stylebox(&"panel", &"FilterFieldFocus", filter_focus)
	theme.set_color(&"icon_color", &"FilterField", p.text_muted)
	theme.set_constant(&"icon_size", &"FilterField", 14)
	_variation(theme, &"FilterFieldRow", &"HBoxContainer")
	theme.set_constant(&"separation", &"FilterFieldRow", 2)
	_variation(theme, &"FilterFieldText", &"LineEdit")
	var flat_text: StyleBoxFlat = _box(Color.TRANSPARENT, 0, Vector4(4, 5, 4, 5))
	for state: StringName in [&"normal", &"focus", &"read_only"]:
		theme.set_stylebox(state, &"FilterFieldText", flat_text)
	# The search's match count after the text ("3/41"), muted; "No matches" in red.
	_variation(theme, &"FilterFieldCount", &"Label")
	theme.set_color(&"font_color", &"FilterFieldCount", p.text_muted)
	theme.set_font_size(&"font_size", &"FilterFieldCount", 12)
	_variation(theme, &"FilterFieldCountError", &"FilterFieldCount")
	theme.set_color(&"font_color", &"FilterFieldCountError", p.error)
	_variation(theme, &"FilterFieldDivider", &"VSeparator")
	theme.set_constant(&"separation", &"FilterFieldDivider", 5)
	var divider: StyleBoxLine = StyleBoxLine.new()
	divider.color = p.border
	divider.vertical = true
	divider.grow_begin = -5.0
	divider.grow_end = -5.0
	theme.set_stylebox(&"separator", &"FilterFieldDivider", divider)
	_variation(theme, &"FilterFieldButton", &"ToolbarButton")
	var tool_small: Vector4 = Vector4(5, 3, 5, 3)
	theme.set_stylebox(&"normal", &"FilterFieldButton", _box(Color.TRANSPARENT, 3, tool_small))
	theme.set_stylebox(&"hover", &"FilterFieldButton", _box(p.hover, 3, tool_small))
	theme.set_stylebox(&"pressed", &"FilterFieldButton", _box(Color(p.accent, 0.25), 3, tool_small))
	theme.set_stylebox(&"hover_pressed", &"FilterFieldButton", _box(Color(p.accent, 0.35), 3, tool_small))
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
	theme.set_constant(&"logo_size", &"EmptyState", 96)
	theme.set_constant(&"icon_size", &"EmptyState", 48)
	theme.set_constant(&"compact_icon_size", &"EmptyState", 36)
	theme.set_color(&"icon_tint", &"EmptyState", Color(1.0, 1.0, 1.0, 0.45))
	# The compact form: a muted icon over a short title, one small button.
	_variation(theme, &"EmptyStateCompactBox", &"VBoxContainer")
	theme.set_constant(&"separation", &"EmptyStateCompactBox", 8)
	_variation(theme, &"EmptyStateCompactTitle", &"Label")
	theme.set_font_size(&"font_size", &"EmptyStateCompactTitle", 15)
	theme.set_color(&"font_color", &"EmptyStateCompactTitle", p.text_muted)
	_variation(theme, &"EmptyStateButton", &"Button")
	var small: Vector4 = Vector4(10, 4, 10, 4)
	theme.set_stylebox(&"normal", &"EmptyStateButton", _box(p.raised, 4, small, p.border, 1))
	theme.set_stylebox(&"hover", &"EmptyStateButton", _box(p.hover, 4, small, p.border, 1))
	theme.set_stylebox(&"pressed", &"EmptyStateButton", _box(Color(p.accent, 0.35), 4, small, p.accent, 1))
	theme.set_stylebox(&"hover_pressed", &"EmptyStateButton", _box(Color(p.accent, 0.35), 4, small, p.accent, 1))
	theme.set_stylebox(&"focus", &"EmptyStateButton", _box(Color.TRANSPARENT, 4, Vector4.ZERO, p.accent, 1))
	_variation(theme, &"AboutRow", &"HBoxContainer")
	theme.set_constant(&"separation", &"AboutRow", 18)
	theme.set_constant(&"logo_size", &"AboutDialog", 72)
	theme.set_constant(&"text_width", &"AboutDialog", 380)
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
	_variation(theme, &"ShelfNames", &"ItemList")
	theme.set_stylebox(&"panel", &"ShelfNames", _box(p.background, 0, Vector4(8, 2, 8, 2)))
	theme.set_constant(&"v_separation", &"ShelfNames", 8)
	theme.set_color(&"group_color", &"ShelfNames", p.text_muted)
	theme.set_color(&"group_background", &"ShelfNames", p.surface)
	_variation(theme, &"ShelfTitle", &"ToolbarButton")
	theme.set_font(&"font", &"ShelfTitle", bold_font())
	theme.set_font_size(&"font_size", &"ShelfTitle", 17)
	_variation(theme, &"ShelfNameEdit", &"LineEdit")
	theme.set_font(&"font", &"ShelfNameEdit", bold_font())
	theme.set_font_size(&"font_size", &"ShelfNameEdit", 17)
	_variation(theme, &"ShelfDiscardButton", &"ToolbarButton")
	for color: StringName in [&"font_hover_color", &"font_pressed_color", &"font_hover_pressed_color"]:
		theme.set_color(color, &"ShelfDiscardButton", p.error)
	var icon_grey: Color = LIGHT_ICON_GREY if p.light else DARK_ICON_GREY
	var discard_icon: Color = p.error * DARK_ICON_GREY / icon_grey
	discard_icon.a = 1.0
	for color: StringName in [&"icon_hover_color", &"icon_pressed_color", &"icon_hover_pressed_color"]:
		theme.set_color(color, &"ShelfDiscardButton", discard_icon)
	# Match ToolbarButton's normal padding so hovering cannot clip the label.
	for state: StringName in [&"hover", &"pressed", &"hover_pressed"]:
		theme.set_stylebox(state, &"ShelfDiscardButton", _box(Color(p.error, 0.12), 4, Vector4(6, 4, 6, 4)))
	_variation(theme, &"ShelfBranchPicker", &"PopupPanel")
	theme.set_stylebox(&"panel", &"ShelfBranchPicker", _box(p.raised, 6, Vector4(8, 8, 8, 8), p.border, 1))
	theme.set_constant(&"width", &"ShelfBranchPicker", 300)
	theme.set_constant(&"max_height", &"ShelfBranchPicker", 360)
	theme.set_constant(&"padding", &"ShelfBranchPicker", 16)
	theme.set_constant(&"files_width", &"ShelfView", 240)
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



## Home (PLAN §4 Home, M7.5): the filter and Add on top, the Recent cards,
## and the repository rows, flat until hovered.
## The Keyboard page of Settings: rows of actions with their shortcuts as key
## caps, in chips that record a new shortcut when clicked.
static func _add_shortcuts(theme: Theme, p: Palette) -> void:
	theme.set_constant(&"row_height", &"ShortcutsPage", 30)
	theme.set_constant(&"icon_size", &"ShortcutsPage", 16)
	theme.set_constant(&"slot_width", &"ShortcutsPage", 26)
	theme.set_constant(&"dot_size", &"ShortcutsPage", 6)
	theme.set_constant(&"chip_width", &"ShortcutsPage", 132)
	for entry: Array in [[&"ShortcutRow", Color.TRANSPARENT], [&"ShortcutRowHover", Color(p.hover, 0.55)]]:
		_variation(theme, entry[0], &"PanelContainer")
		theme.set_stylebox(&"panel", entry[0], _box(entry[1], 4, Vector4(6, 1, 4, 1)))
	_variation(theme, &"ShortcutRowLines", &"VBoxContainer")
	theme.set_constant(&"separation", &"ShortcutRowLines", 4)
	# Section headers fold their rows
	_variation(theme, &"ShortcutSection", &"Button")
	var section: Vector4 = Vector4(2, 10, 2, 4)
	for state: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"focus"]:
		var box: StyleBoxFlat = _box(Color.TRANSPARENT, 0, section)
		if state == &"focus":
			box.border_color = p.accent
			box.border_width_bottom = 1
		theme.set_stylebox(state, &"ShortcutSection", box)
	theme.set_color(&"font_color", &"ShortcutSection", p.text_muted)
	theme.set_color(&"font_focus_color", &"ShortcutSection", p.text_muted)
	theme.set_color(&"font_hover_color", &"ShortcutSection", p.text)
	theme.set_color(&"font_pressed_color", &"ShortcutSection", p.text_muted)
	theme.set_color(&"font_hover_pressed_color", &"ShortcutSection", p.text)
	theme.set_font(&"font", &"ShortcutSection", bold_font())
	theme.set_font_size(&"font_size", &"ShortcutSection", 13)
	theme.set_constant(&"h_separation", &"ShortcutSection", 6)
	_variation(theme, &"ShortcutSectionCount", &"Label")
	theme.set_color(&"font_color", &"ShortcutSectionCount", Color(p.text_muted, 0.75))
	theme.set_font_size(&"font_size", &"ShortcutSectionCount", 12)
	# Where the shortcut works, as a small tag
	_variation(theme, &"ShortcutContext", &"Label")
	theme.set_color(&"font_color", &"ShortcutContext", p.text_muted)
	theme.set_font_size(&"font_size", &"ShortcutContext", 11)
	theme.set_stylebox(&"normal", &"ShortcutContext", _box(Color(p.text_muted, 0.13), 3, Vector4(6, 0, 6, 1)))
	_variation(theme, &"ShortcutModified", &"Panel")
	theme.set_stylebox(&"panel", &"ShortcutModified", _box(p.accent, 3))
	# The chip around a shortcut's key caps
	var chip: Vector4 = Vector4(4, 3, 4, 3)
	for entry: Array in [[&"ShortcutChip", Color.TRANSPARENT, Color.TRANSPARENT],
			[&"ShortcutChipHover", p.hover, p.border],
			[&"ShortcutChipFocus", Color.TRANSPARENT, p.accent],
			[&"ShortcutChipRecording", Color(p.accent, 0.16), p.accent],
			[&"ShortcutChipConflict", Color(p.modified, 0.14), p.modified]]:
		_variation(theme, entry[0], &"PanelContainer")
		theme.set_stylebox(&"panel", entry[0], _box(entry[1], 5, chip, entry[2], 1))
	_variation(theme, &"ShortcutChipKeys", &"HBoxContainer")
	theme.set_constant(&"separation", &"ShortcutChipKeys", 3)
	_variation(theme, &"ShortcutChipText", &"Label")
	theme.set_color(&"font_color", &"ShortcutChipText", p.text_muted)
	theme.set_font_size(&"font_size", &"ShortcutChipText", 12)
	_variation(theme, &"ShortcutChipPrompt", &"Label")
	theme.set_color(&"font_color", &"ShortcutChipPrompt", p.accent_text)
	theme.set_font_size(&"font_size", &"ShortcutChipPrompt", 12)
	# One key cap: raised, with a deeper bottom edge
	_variation(theme, &"KeyCap", &"PanelContainer")
	var cap: StyleBoxFlat = _box(p.raised, 4, Vector4(6, 1, 6, 2), p.border, 1)
	cap.border_width_bottom = 2
	theme.set_stylebox(&"panel", &"KeyCap", cap)
	_variation(theme, &"KeyCapLabel", &"Label")
	theme.set_color(&"font_color", &"KeyCapLabel", p.text)
	theme.set_font_size(&"font_size", &"KeyCapLabel", 12)
	_variation(theme, &"KeyCapSeparator", &"Label")
	theme.set_color(&"font_color", &"KeyCapSeparator", p.text_muted)
	theme.set_font_size(&"font_size", &"KeyCapSeparator", 11)
	# A clash with another action, under the row
	_variation(theme, &"ShortcutConflict", &"PanelContainer")
	theme.set_stylebox(&"panel", &"ShortcutConflict", _box(p.background.blend(Color(p.modified, 0.12)), 4,
			Vector4(8, 4, 4, 4), Color(p.modified, 0.5), 1))
	_variation(theme, &"ShortcutsToolbar", &"HBoxContainer")
	theme.set_constant(&"separation", &"ShortcutsToolbar", 6)


static func _add_home(theme: Theme, p: Palette) -> void:
	_variation(theme, &"HomePage", &"PanelContainer")
	theme.set_stylebox(&"panel", &"HomePage", _box(p.background))
	_variation(theme, &"HomeMargins", &"MarginContainer")
	theme.set_constant(&"margin_top", &"HomeMargins", 20)
	theme.set_constant(&"margin_bottom", &"HomeMargins", 12)
	_variation(theme, &"HomeColumn", &"VBoxContainer")
	theme.set_constant(&"separation", &"HomeColumn", 12)
	_variation(theme, &"HomeList", &"VBoxContainer")
	theme.set_constant(&"separation", &"HomeList", 2)
	_variation(theme, &"HomeSection", &"Label")
	theme.set_color(&"font_color", &"HomeSection", p.text_muted)
	theme.set_font(&"font", &"HomeSection", bold_font())
	theme.set_font_size(&"font_size", &"HomeSection", 13)
	_variation(theme, &"HomeRowName", &"Label")
	theme.set_font(&"font", &"HomeRowName", bold_font())
	_variation(theme, &"HomeBranch", &"Label")
	theme.set_color(&"font_color", &"HomeBranch", p.text_muted)
	_variation(theme, &"HomeOpenChip", &"Label")
	theme.set_color(&"font_color", &"HomeOpenChip", p.accent_text)
	theme.set_stylebox(&"normal", &"HomeOpenChip", _box(Color(p.accent, 0.15), 4, Vector4(6, 1, 6, 1)))
	theme.set_font_size(&"font_size", &"HomeOpenChip", 12)
	_variation(theme, &"HomeRow", &"Button")
	theme.set_stylebox(&"normal", &"HomeRow", _box(Color.TRANSPARENT, 4))
	theme.set_stylebox(&"hover", &"HomeRow", _box(p.hovered, 4))
	theme.set_stylebox(&"pressed", &"HomeRow", _box(p.selected, 4))
	theme.set_stylebox(&"hover_pressed", &"HomeRow", _box(p.selected, 4))
	theme.set_stylebox(&"focus", &"HomeRow", _box(Color.TRANSPARENT, 4, Vector4.ZERO, p.accent, 1))
	_variation(theme, &"HomeRowBox", &"MarginContainer")
	for side: String in ["left", "right"]:
		theme.set_constant(&"margin_" + side, &"HomeRowBox", 8)
	for side: String in ["top", "bottom"]:
		theme.set_constant(&"margin_" + side, &"HomeRowBox", 4)
	_variation(theme, &"HomeCard", &"ChoiceRow")
	_variation(theme, &"HomeCardBox", &"ChoiceRowBox")
	_variation(theme, &"HomeCloneRow", &"PanelContainer")
	theme.set_stylebox(&"panel", &"HomeCloneRow", _box(p.surface, 6, Vector4(10, 6, 8, 6), p.border, 1))
	theme.set_constant(&"recent_count", &"Home", 8)
	theme.set_constant(&"card_width", &"Home", 210)
	theme.set_constant(&"scrollbar_gap", &"Home", 8)
	_variation(theme, &"HomeCards", &"GridContainer")
	theme.set_constant(&"h_separation", &"HomeCards", 8)
	theme.set_constant(&"v_separation", &"HomeCards", 8)
	theme.set_constant(&"max_width", &"Home", 1040)
	theme.set_constant(&"margin", &"Home", 24)
	theme.set_constant(&"icon_size", &"Home", 16)
	theme.set_constant(&"no_match_height", &"Home", 180)
	theme.set_constant(&"clone_text_width", &"Home", 220)
	theme.set_constant(&"width", &"ScanDialog", 760)
	_add_loading(theme, p)


## `LoadingIndicator`: the caption, the spinner and the corner pill over
## content that is loading again.
static func _add_loading(theme: Theme, p: Palette) -> void:
	const T: StringName = &"LoadingIndicator"
	theme.set_color(&"caption_color", T, p.text_muted)
	theme.set_color(&"backdrop", T, p.background)
	theme.set_color(&"spinner_color", T, p.accent)
	theme.set_color(&"spinner_track", T, Color(p.accent, 0.18))
	theme.set_constant(&"spinner_size", T, 26)
	# LoadingSpinner's, beside text ("Checking…")
	theme.set_constant(&"inline_size", T, 13)
	theme.set_constant(&"gap", T, 12)
	theme.set_constant(&"line_height", T, 3)


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


## The gitbello logo, drawn from its SVG at the interface's scale.
static func logo() -> Texture2D:
	return load(LOGO) as Texture2D


## The icon `name` (an SVG in `ICON_DIR` without its extension).
static func icon(name: StringName) -> Texture2D:
	return load(ICON_DIR.path_join("%s.svg" % name)) as Texture2D


## The icon `name` drawn `side` pixels wide (empty states): the SVG
## rasterised at that size rather than the 16 px icon stretched, in the
## current theme's colours (call again after a theme change).
static func large_icon(name: StringName, side: int) -> Texture2D:
	var source: DPITexture = icon(name) as DPITexture
	if source == null or source.get_width() <= 0 or side <= 0:
		return icon(name)
	var key: String = "%s:%d:%s" % [name, side, str(source.color_map.hash())]
	if not _large.has(key):
		var copy: DPITexture = source.duplicate() as DPITexture
		copy.base_scale = source.base_scale * float(side) / float(source.get_width())
		_large[key] = copy
	return _large[key]


## The icon `name` in white, for a colour given by `modulate`: the shared
## icon is grey, darker in the light theme, which would darken the colour.
static func tintable_icon(name: StringName) -> Texture2D:
	if name in ICON_EXCEPTIONS:
		return icon(name)
	if not _tintable.has(name):
		var copy: DPITexture = (icon(name) as DPITexture).duplicate() as DPITexture
		copy.color_map = {DARK_ICON_GREY: Color.WHITE}
		_tintable[name] = copy
	return _tintable[name]


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
