extends SceneTree
## Draws the raster copies of the logo from its SVGs: `icon.png` (the window
## icon and boot splash), `icon.ico` (the Windows executable icon) and
## `icon_macos.png` (the macOS app icon, made into an `.icns` on export). Run it
## again after changing `logo.svg` or `logo_small.svg`:
##   godot --headless --path godot -s res://tools/export_branding.gd

const DIR: String = "res://themes/branding"
const PNG_SIZE: int = 256
## Sizes in the ICO. Up to `SMALL_MAX` they come from the heavier small logo.
const ICO_SIZES: Array[int] = [16, 20, 24, 32, 40, 48, 64, 128, 256]
const SMALL_MAX: int = 24
## The macOS icon's canvas and the logo inside it, with the margin of the
## system's icon grid.
const MACOS_SIZE: int = 1024
const MACOS_MARGIN: int = 100
## The SVGs are drawn on a 64 px canvas.
const SVG_SIZE: float = 64.0


func _init() -> void:
	var full: String = FileAccess.get_file_as_string(DIR.path_join("logo.svg"))
	var small: String = FileAccess.get_file_as_string(DIR.path_join("logo_small.svg"))
	if full.is_empty() or small.is_empty():
		push_error("export_branding: logo SVGs not found in %s" % DIR)
		quit(1)
		return
	var ok: bool = _render(full, PNG_SIZE).save_png(DIR.path_join("icon.png")) == OK
	var pngs: Array[PackedByteArray] = []
	for size: int in ICO_SIZES:
		pngs.append(_render(small if size <= SMALL_MAX else full, size).save_png_to_buffer())
	ok = _write_ico(DIR.path_join("icon.ico"), pngs) and ok
	var macos: Image = Image.create_empty(MACOS_SIZE, MACOS_SIZE, false, Image.FORMAT_RGBA8)
	var art: Image = _render(full, MACOS_SIZE - 2 * MACOS_MARGIN)
	art.convert(Image.FORMAT_RGBA8)
	macos.blit_rect(art, Rect2i(Vector2i.ZERO, art.get_size()), Vector2i(MACOS_MARGIN, MACOS_MARGIN))
	ok = macos.save_png(DIR.path_join("icon_macos.png")) == OK and ok
	quit(0 if ok else 1)


func _render(svg: String, size: int) -> Image:
	var image: Image = Image.new()
	image.load_svg_from_string(svg, size / SVG_SIZE)
	return image


## Writes an ICO whose entries are PNGs (read by Windows Vista and later).
func _write_ico(path: String, pngs: Array[PackedByteArray]) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("export_branding: cannot write %s" % path)
		return false
	file.store_16(0)
	file.store_16(1)
	file.store_16(pngs.size())
	var offset: int = 6 + 16 * pngs.size()
	for i: int in pngs.size():
		var size: int = ICO_SIZES[i]
		file.store_8(size % 256)  # 0 means 256
		file.store_8(size % 256)
		file.store_8(0)
		file.store_8(0)
		file.store_16(1)
		file.store_16(32)
		file.store_32(pngs[i].size())
		file.store_32(offset)
		offset += pngs[i].size()
	for png: PackedByteArray in pngs:
		file.store_buffer(png)
	file.close()
	return true
