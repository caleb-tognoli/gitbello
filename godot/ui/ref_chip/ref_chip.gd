class_name RefChip
extends Control
## One ref as a chip (M7.10). A branch has the branch icon, or the cloud icon
## when its remote branch is at the same commit (`remotes` in the label); a
## remote branch the cloud icon with its remote's prefix muted; a tag a
## round pill with the tag icon; "+N" stands for refs left out. Compact
## rows show one icon-only chip per kind instead (`shape_icons`), with the
## count when there are several. The labels
## are `RepoSession.graph_rows()` refs: `{name, kind, is_head, remote,
## remotes}`. Theme type `RefChip`. Lists drawing many chips (`CommitList`)
## use `shape` and `paint` on their own canvas.

const THEME_TYPE: StringName = &"RefChip"
const STYLES: Dictionary[String, StringName] = {
	"head": &"chip_head",
	"branch": &"chip_branch",
	"remote": &"chip_remote",
	"tag": &"chip_tag",
	"more": &"chip_more",
}
const PREFIXES: Dictionary[String, String] = {
	"branch": "refs/heads/",
	"remote": "refs/remotes/",
	"tag": "refs/tags/",
}

## The label this control shows.
var label: Dictionary = {}:
	set = set_label

var _shaped: Shaped = null


## A chip ready to draw: its box, icon and text, and its size.
class Shaped:
	extends RefCounted
	var style: StringName = &"chip_branch"
	var icon: StringName = &""
	## The muted "origin/" of a remote branch, or null.
	var prefix: TextLine = null
	var text: TextLine = null
	var size: Vector2 = Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_reshape()


func set_label(value: Dictionary) -> void:
	label = value
	tooltip_text = RefChip.tooltip(label)
	_reshape()


func _get_minimum_size() -> Vector2:
	return _shaped.size if _shaped != null else Vector2.ZERO


func _draw() -> void:
	if _shaped != null:
		RefChip.paint(self, self, _shaped, Vector2.ZERO)


func _reshape() -> void:
	_shaped = RefChip.shape(self, label) if not label.is_empty() else null
	update_minimum_size()
	queue_redraw()


## Shapes `ref_label` with `control`'s theme, its name cut to the theme's
## `max_width` (or `max_width` when given).
static func shape(control: Control, ref_label: Dictionary, max_width: float = -1.0) -> Shaped:
	var chip: Shaped = Shaped.new()
	var kind: String = String(ref_label.get("kind", "branch"))
	chip.style = STYLES["head"] if bool(ref_label.get("is_head", false)) else STYLES.get(kind, STYLES["branch"])
	chip.icon = RefChip.icon_name(ref_label)
	var font: Font = control.get_theme_font(&"font", &"Label")
	var font_size: int = control.get_theme_font_size(&"font_size", THEME_TYPE)
	var title: String = String(ref_label.get("name", ""))
	var remote: String = String(ref_label.get("remote", ""))
	if kind == "remote" and not remote.is_empty() and title.begins_with(remote + "/"):
		chip.prefix = TextLine.new()
		chip.prefix.add_string(remote + "/", font, font_size)
		title = title.trim_prefix(remote + "/")
	var box: StyleBox = control.get_theme_stylebox(chip.style, THEME_TYPE)
	var icon_size: float = float(control.get_theme_constant(&"icon_size", THEME_TYPE))
	var icon_width: float = icon_size + float(control.get_theme_constant(&"icon_gap", THEME_TYPE))
	var prefix_width: float = chip.prefix.get_size().x if chip.prefix != null else 0.0
	if max_width < 0.0:
		max_width = float(control.get_theme_constant(&"max_width", THEME_TYPE))
	chip.text = TextLine.new()
	chip.text.add_string(title, font, font_size)
	chip.text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var room: float = max_width - box.get_minimum_size().x - icon_width - prefix_width
	if chip.text.get_size().x > room:
		chip.text.width = maxf(0.0, room)
	chip.size = Vector2(box.get_minimum_size().x + icon_width + prefix_width + chip.text.get_size().x,
			box.get_minimum_size().y + maxf(chip.text.get_size().y, icon_size))
	return chip


## An icon-only chip for `labels`, all of one kind: the first one's colour
## and icon, then how many there are when more than one.
static func shape_icons(control: Control, labels: Array) -> Shaped:
	var chip: Shaped = Shaped.new()
	var first: Dictionary = labels[0]
	var kind: String = String(first.get("kind", "branch"))
	chip.style = STYLES["head"] if bool(first.get("is_head", false)) else STYLES.get(kind, STYLES["branch"])
	chip.icon = RefChip.icon_name(first)
	var font: Font = control.get_theme_font(&"font", &"Label")
	var font_size: int = control.get_theme_font_size(&"font_size", THEME_TYPE)
	var box: StyleBox = control.get_theme_stylebox(chip.style, THEME_TYPE)
	var icon_size: float = float(control.get_theme_constant(&"icon_size", THEME_TYPE))
	var width: float = box.get_minimum_size().x + icon_size
	if labels.size() > 1:
		chip.text = TextLine.new()
		chip.text.add_string(str(labels.size()), font, font_size)
		width += float(control.get_theme_constant(&"icon_gap", THEME_TYPE)) + chip.text.get_size().x
	chip.size = Vector2(width, box.get_minimum_size().y + maxf(icon_size, font.get_height(font_size)))
	return chip


## The "+N" chip for `count` refs left out.
static func shape_more(control: Control, count: int) -> Shaped:
	var chip: Shaped = Shaped.new()
	chip.style = STYLES["more"]
	chip.text = TextLine.new()
	chip.text.add_string("+%d" % count, control.get_theme_font(&"font", &"Label"),
			control.get_theme_font_size(&"font_size", THEME_TYPE))
	var box: StyleBox = control.get_theme_stylebox(chip.style, THEME_TYPE)
	chip.size = box.get_minimum_size() + chip.text.get_size()
	return chip


## Draws `chip` on `canvas` (in its `_draw`) with its top-left at `at`,
## using `control`'s theme.
static func paint(canvas: CanvasItem, control: Control, chip: Shaped, at: Vector2) -> void:
	var box: StyleBox = control.get_theme_stylebox(chip.style, THEME_TYPE)
	canvas.draw_style_box(box, Rect2(at, chip.size))
	var more: bool = chip.style == STYLES["more"]
	var color: Color = control.get_theme_color(&"more_color" if more else &"text_color", THEME_TYPE)
	var rid: RID = canvas.get_canvas_item()
	var center_y: float = at.y + chip.size.y * 0.5
	var x: float = at.x + box.get_margin(SIDE_LEFT)
	if not chip.icon.is_empty():
		var icon_size: float = float(control.get_theme_constant(&"icon_size", THEME_TYPE))
		canvas.draw_texture_rect(AppTheme.tintable_icon(chip.icon),
				Rect2(x, center_y - icon_size * 0.5, icon_size, icon_size), false, color)
		x += icon_size + float(control.get_theme_constant(&"icon_gap", THEME_TYPE))
	if chip.prefix != null:
		chip.prefix.draw(rid, Vector2(x, center_y - chip.prefix.get_size().y * 0.5),
				control.get_theme_color(&"prefix_color", THEME_TYPE))
		x += chip.prefix.get_size().x
	if chip.text != null:
		chip.text.draw(rid, Vector2(x, center_y - chip.text.get_size().y * 0.5), color)


## The icon of `ref_label`: the tag, the cloud for a remote branch or a
## branch with its remote branch at the same commit, else the branch.
static func icon_name(ref_label: Dictionary) -> StringName:
	match String(ref_label.get("kind", "branch")):
		"tag":
			return &"GitTag"
		"remote":
			return &"GitRemote"
	return &"GitRemote" if not (ref_label.get("remotes", []) as Array).is_empty() else &"GitBranch"


## The chip's tooltip: its name, and the remote branches it stands for.
static func tooltip(ref_label: Dictionary) -> String:
	var title: String = String(ref_label.get("name", ""))
	var remotes: Array = ref_label.get("remotes", [])
	if remotes.is_empty():
		return title
	return "%s\n%s" % [title,TranslationServer.translate("Also on %s") % ", ".join(PackedStringArray(remotes))]


## The tooltip of an icon-only chip: the one ref's, or every name.
static func group_tooltip(labels: Array) -> String:
	if labels.size() == 1:
		return RefChip.tooltip(labels[0])
	var names: PackedStringArray = PackedStringArray()
	for ref_label: Dictionary in labels:
		names.append(String(ref_label["name"]))
	return "
".join(names)


## The ref the menus act on: `{name, short, kind, is_head}` with the full
## ref name.
static func ref_target(ref_label: Dictionary) -> Dictionary:
	var short: String = String(ref_label["name"])
	var kind: String = String(ref_label["kind"])
	return {"name": PREFIXES.get(kind, "") + short, "short": short, "kind": kind,
		"is_head": bool(ref_label.get("is_head", false))}


## What a row shows of `refs` (sorted: current branch, branches, remote
## branches, tags): `[{label}]` for the first branch and the first tag, each
## followed by `{more: [labels left out]}` when there are others.
static func summarize(refs: Array) -> Array[Dictionary]:
	var branches: Array = []
	var tags: Array = []
	for ref_label: Dictionary in refs:
		(tags if String(ref_label["kind"]) == "tag" else branches).append(ref_label)
	var out: Array[Dictionary] = []
	for group: Array in [branches, tags]:
		if group.is_empty():
			continue
		out.append({"label": group[0]})
		if group.size() > 1:
			out.append({"more": group.slice(1)})
	return out


## A compact row's refs by kind: `[{labels: branches}, {labels: tags}]`,
## the empty ones left out.
static func group_kinds(refs: Array) -> Array[Dictionary]:
	var branches: Array = []
	var tags: Array = []
	for ref_label: Dictionary in refs:
		(tags if String(ref_label["kind"]) == "tag" else branches).append(ref_label)
	var out: Array[Dictionary] = []
	for group: Array in [branches, tags]:
		if not group.is_empty():
			out.append({"labels": group})
	return out
