class_name AvatarPainter
extends RefCounted
## Draws a person as a round avatar (M7.10): their initials on a colour
## chosen from their email, from the `Avatar` theme type's palette
## (`color_0`… with `text_0`…, `colors` of them), or their profile picture
## once `AvatarPictures` has it.

const THEME_TYPE: StringName = &"Avatar"


## One or two letters: the first of the first and last words of `name`, or
## the first of the email's local part. "?" when both are empty.
static func initials(name: String, email: String) -> String:
	var words: PackedStringArray = PackedStringArray()
	for word: String in name.strip_edges().split(" ", false):
		var first: String = _first_letter(word)
		if not first.is_empty():
			words.append(first)
	if words.size() >= 2:
		return (words[0] + words[words.size() - 1]).to_upper()
	if words.size() == 1:
		return words[0].to_upper()
	var local: String = email.strip_edges().get_slice("@", 0)
	var letter: String = _first_letter(local)
	return letter.to_upper() if not letter.is_empty() else "?"


## Which palette entry `email` (or `name`, without one) gets: the same one
## every time, in every list.
static func color_index(name: String, email: String, colors: int) -> int:
	var key: String = email.strip_edges().to_lower()
	if key.is_empty():
		key = name.strip_edges().to_lower()
	# FNV-1a, so the index does not change between Godot versions.
	var value: int = 2166136261
	for byte: int in key.to_utf8_buffer():
		value = ((value ^ byte) * 16777619) & 0xffffffff
	return value % maxi(1, colors)


## The fill and text colours of `email`'s avatar, from `control`'s theme.
static func colors_for(control: Control, name: String, email: String) -> PackedColorArray:
	var count: int = maxi(1, control.get_theme_constant(&"colors", THEME_TYPE))
	var index: int = color_index(name, email, count)
	return PackedColorArray([
		control.get_theme_color(StringName("color_%d" % index), THEME_TYPE),
		control.get_theme_color(StringName("text_%d" % index), THEME_TYPE),
	])


## Draws the avatar of `name`/`email` centred at `center` on `canvas` (a
## CanvasItem drawing in its `_draw`), `diameter` wide. `ring` (alpha > 0)
## draws a border of `ring_width` around it in that colour, to separate
## avatars that overlap. `alpha` fades the whole avatar (dimmed rows).
## `session` asks for the picture (see `AvatarPictures.texture`); the canvas
## redraws on `AvatarPictures.changed`.
static func draw(canvas: CanvasItem, control: Control, center: Vector2, diameter: float,
		name: String, email: String, font: Font, ring: Color = Color(0, 0, 0, 0),
		ring_width: float = 1.5, alpha: float = 1.0, session: RepoSession = null) -> void:
	var radius: float = diameter * 0.5
	if ring.a > 0.0:
		canvas.draw_circle(center, radius + ring_width, ring, true, -1.0, true)
	var picture: Texture2D = AvatarPictures.shared().texture(email, session)
	if picture != null:
		canvas.draw_texture_rect(picture, Rect2(center - Vector2(radius, radius), Vector2(diameter, diameter)),
				false, Color(1, 1, 1, alpha))
		return
	var colors: PackedColorArray = colors_for(control, name, email)
	var fill: Color = colors[0]
	var ink: Color = colors[1]
	fill.a *= alpha
	ink.a *= alpha
	# Antialiased: a plain filled circle has stair-stepped edges at avatar sizes.
	canvas.draw_circle(center, radius, fill, true, -1.0, true)
	var text: String = initials(name, email)
	var size: int = maxi(6, int(round(diameter * (0.42 if text.length() > 1 else 0.5))))
	var extent: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	var baseline: float = center.y + (font.get_ascent(size) - font.get_descent(size)) * 0.5
	canvas.draw_string(font, Vector2(center.x - extent.x * 0.5, baseline), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)


static func _first_letter(word: String) -> String:
	for i: int in word.length():
		var c: String = word[i]
		if c.to_upper() != c.to_lower() or c.is_valid_int():
			return c
	return ""
