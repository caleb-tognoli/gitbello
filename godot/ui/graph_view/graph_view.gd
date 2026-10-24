class_name GraphView
extends RefCounted
## Draws history-graph lanes and nodes for one row from core's lane data
## (PLAN §3.7, §3.9). Used by the commit list, which owns the scroll container.
##
## Geometry is built once per row and cached by the caller; drawing a row is
## one `draw_multiline_colors` call plus a circle.

const THEME_TYPE: StringName = &"GraphView"
const PALETTE_SIZE: int = 8

enum SegmentKind { PASS = 0, IN = 1, OUT = 2 }


## Cached drawing data for one row, in row-local coordinates.
class RowGeometry:
	extends RefCounted
	var points: PackedVector2Array = PackedVector2Array()
	var colors: PackedColorArray = PackedColorArray()
	var node: Vector2 = Vector2.ZERO
	var node_color: Color = Color.WHITE
	## True when lanes beyond `max_lanes` were left out.
	var clipped: bool = false


var lane_width: float = 1.0
var line_width: float = 1.0
var node_radius: float = 1.0
var max_lanes: int = 1
var _palette: PackedColorArray = PackedColorArray()
var _node_outline: Color = Color.BLACK


## Reads sizes and colors from `control`'s theme. Call again on theme changes.
func update_theme(control: Control) -> void:
	lane_width = float(control.get_theme_constant(&"lane_width", THEME_TYPE))
	line_width = float(control.get_theme_constant(&"line_width", THEME_TYPE))
	node_radius = float(control.get_theme_constant(&"node_radius", THEME_TYPE))
	max_lanes = maxi(1, control.get_theme_constant(&"max_lanes", THEME_TYPE))
	_node_outline = control.get_theme_color(&"node_outline", THEME_TYPE)
	_palette.clear()
	for i: int in PALETTE_SIZE:
		_palette.append(control.get_theme_color(StringName("lane_%d" % i), THEME_TYPE))


## Pixel width of the graph area for rows using `lanes` columns.
func width_for(lanes: int) -> float:
	return clampi(lanes, 1, max_lanes) * lane_width


func color(index: int) -> Color:
	return _palette[index % _palette.size()] if not _palette.is_empty() else Color.WHITE


## Builds the geometry for a row Dictionary from `RepoSession.graph_rows()`.
func build(row: Dictionary, height: float) -> RowGeometry:
	var geometry: RowGeometry = RowGeometry.new()
	var segments: PackedInt32Array = row.get("segments", PackedInt32Array())
	var center: float = height * 0.5
	for i: int in range(0, segments.size() - 3, 4):
		var from: int = segments[i + 1]
		var to: int = segments[i + 2]
		if from >= max_lanes or to >= max_lanes:
			geometry.clipped = true
			continue
		var start_y: float = center if segments[i] == SegmentKind.OUT else 0.0
		var end_y: float = center if segments[i] == SegmentKind.IN else height
		geometry.points.append(Vector2(_x(from), start_y))
		geometry.points.append(Vector2(_x(to), end_y))
		geometry.colors.append(color(segments[i + 3]))
	var column: int = mini(int(row.get("column", 0)), max_lanes - 1)
	geometry.node = Vector2(_x(column), center)
	geometry.node_color = color(int(row.get("color", 0)))
	return geometry


func draw(canvas: CanvasItem, geometry: RowGeometry, origin: Vector2) -> void:
	canvas.draw_set_transform(origin)
	if not geometry.points.is_empty():
		canvas.draw_multiline_colors(geometry.points, geometry.colors, line_width, true)
	canvas.draw_circle(geometry.node, node_radius + 1.0, _node_outline, true, -1.0, true)
	canvas.draw_circle(geometry.node, node_radius, geometry.node_color, true, -1.0, true)
	canvas.draw_set_transform(Vector2.ZERO)


func _x(column: int) -> float:
	return (column + 0.5) * lane_width
