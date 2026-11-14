class_name BranchNameLayer
extends Control
## Draws the branch names of a `Tree`'s rows with their prefix muted:
## everything up to the last `/` (`feature/`, `origin/team/`) in
## `prefix_color`, the rest in the tree's font colour. It lies over the tree
## (add it as the tree's child), so the names show over a row's hover and
## selection boxes; the rows keep their text (for tests, tooltips and
## type-to-search) but draw it transparent, and their icons stay the tree's to
## draw. When a name is too wide the prefix gives way first (`feat…/login`),
## then the name itself.

var prefix_color: Color = Color.WHITE
var _tree: Tree = null
var _items: Array[TreeItem] = []
var _column: int = 0


## Lays the layer over `tree` (its parent), drawing names in `column`.
func _init(tree: Tree, column: int = 0) -> void:
	_tree = tree
	_column = column
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tree.add_child(self)
	tree.draw.connect(queue_redraw)


## Draws `item`'s name here from now on.
func add(item: TreeItem) -> void:
	item.set_custom_color(_column, Color(0.0, 0.0, 0.0, 0.0))
	_items.append(item)


## Forgets every row (call when the tree is cleared).
func clear() -> void:
	_items.clear()


## `[prefix, name]`: `feature/x` → `["feature/", "x"]`, `main` → `["", "main"]`.
static func split(text: String) -> PackedStringArray:
	var slash: int = text.rfind("/")
	return PackedStringArray([text.left(slash + 1), text.substr(slash + 1)])


func _draw() -> void:
	var visible_rect: Rect2 = Rect2(Vector2.ZERO, _tree.size)
	for item: TreeItem in _items:
		if not item.is_visible_in_tree():
			continue
		var rect: Rect2 = _tree.get_item_area_rect(item, _column)
		if visible_rect.intersects(rect):
			_draw_name(item, rect)


func _draw_name(item: TreeItem, rect: Rect2) -> void:
	var font: Font = _tree.get_theme_font(&"font")
	var font_size: int = _tree.get_theme_font_size(&"font_size")
	# Where Tree puts a cell's text: after the row's indent (which the area
	# rect leaves out), the inner margin and the icon.
	var x: float = rect.position.x + _indent(item) + float(_tree.get_theme_constant(&"inner_item_margin_left"))
	var icon: Texture2D = item.get_icon(_column)
	if icon != null:
		x += _icon_width(item, icon) + float(_tree.get_theme_constant(&"h_separation"))
	var room: float = rect.end.x - float(_tree.get_theme_constant(&"inner_item_margin_right")) - x
	if room <= 0.0:
		return
	var color: Color = _tree.get_theme_color(&"font_selected_color" if item.is_selected(_column) else &"font_color")
	var parts: PackedStringArray = split(item.get_text(_column))
	var top: float = roundf(rect.position.y + (rect.size.y - font.get_height(font_size)) / 2.0)
	var baseline: float = top + font.get_ascent(font_size)
	var prefix_width: float = _width(font, font_size, parts[0])
	var name_width: float = _width(font, font_size, parts[1])
	if prefix_width + name_width <= room:
		draw_string(font, Vector2(x, baseline), parts[0], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, prefix_color)
		draw_string(font, Vector2(x + prefix_width, baseline), parts[1], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
		return
	var slash_width: float = _width(font, font_size, "/")
	var prefix_room: float = room - name_width - slash_width
	if parts[0].is_empty() or prefix_room < _width(font, font_size, "…") * 3.0:
		_trimmed(parts[1], room, font, font_size).draw(get_canvas_item(), Vector2(x, top), color)
		return
	var prefix: TextLine = _trimmed(parts[0].trim_suffix("/"), prefix_room, font, font_size)
	prefix.draw(get_canvas_item(), Vector2(x, top), prefix_color)
	x += minf(prefix.get_line_width(), prefix_room)
	draw_string(font, Vector2(x, baseline), "/", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, prefix_color)
	draw_string(font, Vector2(x + slash_width, baseline), parts[1], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


## How far Tree indents `item`'s first column: `h_separation` with folding
## hidden (else `item_margin`), plus `item_margin` per level below the top
## shown level.
func _indent(item: TreeItem) -> float:
	if _column != 0:
		return 0.0
	var depth: int = 0
	var parent: TreeItem = item.get_parent()
	while parent != null and (parent != _tree.get_root() or not _tree.hide_root):
		depth += 1
		parent = parent.get_parent()
	var margin: int = _tree.get_theme_constant(&"item_margin")
	return float((_tree.get_theme_constant(&"h_separation") if _tree.hide_folding else margin) + margin * depth)


## The icon's drawn width, as Tree sizes it (its region, capped by the
## theme's and the cell's `icon_max_width`).
func _icon_width(item: TreeItem, icon: Texture2D) -> float:
	var region: Rect2 = item.get_icon_region(_column)
	var width: float = region.size.x if region.has_area() else icon.get_size().x
	var max_width: int = _tree.get_theme_constant(&"icon_max_width")
	var cell_max: int = item.get_icon_max_width(_column)
	if cell_max > 0 and (max_width == 0 or cell_max < max_width):
		max_width = cell_max
	return minf(width, float(max_width)) if max_width > 0 else width


static func _width(font: Font, font_size: int, text: String) -> float:
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


static func _trimmed(text: String, width: float, font: Font, font_size: int) -> TextLine:
	var line: TextLine = TextLine.new()
	line.add_string(text, font, font_size)
	line.width = maxf(1.0, width)
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return line
