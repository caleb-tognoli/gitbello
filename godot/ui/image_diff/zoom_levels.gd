class_name ZoomLevels
extends RefCounted
## Zoom levels that keep pixels even (after spritesheetbelli's PixelZoom):
## whole zooms from 100% up and 1/2, 1/3, 1/4… below it, so every pixel of an
## image covers the same number of screen pixels.
##
## Zooms are in interface pixels, as views lay them out, but the levels are
## whole in screen pixels. With the interface scaled, a level is as many
## screen pixels as the whole part of the scale, see `unit`: at 150%, an image
## pixel is 1, 2, 3… screen pixels at 67%, 133%, 200%…

## Leeway for zooms that are whole but for rounding errors.
const EPSILON: float = 0.0001


## How many screen pixels an interface pixel covers where `item` is drawn.
static func screen_scale(item: CanvasItem) -> float:
	var window: Window = item.get_window() if item.is_inside_tree() else null
	return window.get_final_transform().get_scale().x if window != null else 1.0


## The first whole zoom from 100% up, with `scale` screen pixels to an
## interface pixel: e.g. 1 at 100%, 0.67 at 150% and 1 at 200%.
static func unit(scale: float) -> float:
	return maxf(floorf(scale + EPSILON), 1.0) / scale


## The largest whole zoom up to `zoom`.
static func round_down(zoom: float, scale: float = 1.0) -> float:
	var size: float = unit(scale)
	var units: float = zoom / size
	if units >= 1.0 - EPSILON:
		return floorf(units + EPSILON) * size
	return size / ceilf(1.0 / units - EPSILON)


## The whole zoom a step from `zoom` towards `zoom` × `factor`: the nearest
## whole zoom to that, but at least the next one, so steps grow with the zoom.
static func step(zoom: float, factor: float, scale: float = 1.0) -> float:
	var size: float = unit(scale)
	var level: float = _to_level(zoom / size)
	var target: float = roundf(_to_level(zoom * factor / size))
	if factor > 1.0:
		return _from_level(maxf(floorf(level + EPSILON) + 1.0, target)) * size
	return _from_level(minf(ceilf(level - EPSILON) - 1.0, target)) * size


## The whole zoom nearest `zoom`, the bigger one halfway.
static func nearest(zoom: float, scale: float = 1.0) -> float:
	var size: float = unit(scale)
	return _from_level(roundf(_to_level(zoom / size))) * size


## Numbers whole zooms one after another: 1, 2, 3… are 100%, 200%, 300%…,
## and 0, -1, -2… are 1/2, 1/3, 1/4…, in units (see `unit`).
static func _to_level(zoom: float) -> float:
	return zoom if zoom >= 1.0 else 2.0 - 1.0 / zoom


static func _from_level(level: float) -> float:
	return level if level >= 1.0 else 1.0 / (2.0 - level)
