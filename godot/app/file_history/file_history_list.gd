class_name FileHistoryList
extends CommitList
## The commits that changed one file (PLAN M8a), drawn as History's rows
## without the graph (`RepoSession.file_history_rows()`, fetched for a
## window around the visible rows). After the author line each row says what
## the commit did to the file: a chip when it added, renamed or deleted it,
## then the lines it added and removed. While the file has local changes an
## **Uncommitted changes** row comes first, one line with the same marks.
## Under a filter (`RepoSession.set_file_history_filter`) only the commits
## it matches are listed, its text marked in their subjects (`set_search`),
## and the uncommitted changes are left out. Ctrl+click selects a second
## version, to compare the two. The row of `marked` has a bar at its start
## (the commit the blame has the focus on). Colours and sizes come from the
## `FileHistory` theme type.

## The cursor moved to a commit (its `oid`), or to the uncommitted changes
## (`working`).
signal version_changed(oid: String, working: bool)

const HISTORY_THEME_TYPE: StringName = &"FileHistory"
## The chip of each change that has one, by `file_history_rows` code.
## The uncommitted changes use the status codes too: `?` is a file git does
## not track yet, `U` a conflicted one.
const CHIP_TEXTS: Dictionary[String, String] = {
	"A": "Added", "R": "Renamed", "D": "Deleted", "C": "Copied", "?": "Added", "U": "Conflicted",
}
const CHIP_COLORS: Dictionary[String, StringName] = {
	"A": &"added_color", "R": &"renamed_color", "D": &"deleted_color", "C": &"renamed_color",
	"?": &"added_color", "U": &"deleted_color",
}

## The commit whose row is marked (the blame's focused commit); "" for none.
var marked: String = "":
	set(value):
		if value != marked:
			marked = value
			queue_redraw()

var _has_working: bool = false
## The Uncommitted changes row (`file_history_info`'s `working`).
var _working: Dictionary = {}
var _count: int = 0
## Where each row's marks were drawn last frame: row -> Rect2.
var _mark_rects: Dictionary[int, Rect2] = {}
var _chip_box: StyleBoxFlat = StyleBoxFlat.new()


func _init() -> void:
	super()
	show_graph = false
	follows_graph = false


func _ready() -> void:
	super()
	selection_changed.connect(_on_selection)


## Shows the history (`RepoSession.file_history_info()`), the cursor kept on
## `keep` (a commit's oid, or `working`) when it is still listed. Emits
## nothing.
func show_history(info: Dictionary, keep: String) -> void:
	_has_working = bool(info.get("has_working", false))
	_working = info.get("working", {})
	_count = int(info.get("count", 0))
	var others: PackedStringArray = PackedStringArray()
	for commit: Dictionary in selected_versions():
		if String(commit["oid"]) != keep:
			others.append(String(commit["oid"]))
	reload()
	var row: int = row_of(keep)
	set_block_signals(true)
	select_only(row)
	for oid: String in others:
		var other: int = row_of(oid)
		if other >= 0 and row >= 0:
			_selected[other] = true
	set_block_signals(false)
	queue_redraw()


## Whether row `row` is the Uncommitted changes row.
func is_working_row(row: int) -> bool:
	return _has_working and row == 0


## The version at `row` (`file_history_rows` row), or empty.
func version_at(row: int) -> Dictionary:
	return {} if is_working_row(row) else row_data(row)


## The filter's matches have no strip: only they are listed.
func _update_strip() -> void:
	_strip.hide()


## The row of commit `oid`, of the uncommitted changes for `working`, or -1.
func row_of(oid: String) -> int:
	if oid == "working":
		return 0 if _has_working else -1
	if oid.is_empty() or session == null:
		return -1
	var index: int = session.file_history_index(oid)
	return index + _offset_rows() if index >= 0 else -1


## The selected commits, oldest first.
func selected_versions() -> Array[Dictionary]:
	var commits: Array[Dictionary] = []
	var rows: PackedInt32Array = selected_rows()
	rows.sort()
	rows.reverse()
	for row: int in rows:
		var commit: Dictionary = version_at(row)
		if not commit.is_empty():
			commits.append(commit)
	return commits


func _offset_rows() -> int:
	return 1 if _has_working else 0


func _get_row_count() -> int:
	return _count + _offset_rows()


func _fetch_rows(start: int, count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if session == null:
		return out
	var offset: int = _offset_rows()
	var end: int = mini(start + count, _get_row_count())
	if start < offset and end > start:
		var working: Dictionary = _working.duplicate()
		working.merge({"row": 0, "kind": "working", "subject": ""})
		out.append(working)
	var first: int = maxi(start, offset) - offset
	var wanted: int = end - offset - first
	if wanted <= 0:
		return out
	var rows: Array[Dictionary] = session.file_history_rows(first, wanted)
	for i: int in rows.size():
		var data: Dictionary = rows[i]
		data["row"] = offset + first + i
		data["kind"] = "commit"
		# Every listed commit matches the filter.
		data["match"] = true
		# The details show a commit's refs; the rows say what it did to the file.
		data["refs"] = []
		out.append(data)
	return out


func _on_selection() -> void:
	if cursor < 0:
		return
	if is_working_row(cursor):
		version_changed.emit("", true)
		return
	var oid: String = String(version_at(cursor).get("oid", ""))
	if not oid.is_empty():
		version_changed.emit(oid, false)


func _update_theme() -> void:
	super()
	_chip_box.set_corner_radius_all(get_theme_constant(&"chip_radius", HISTORY_THEME_TYPE))


func _draw() -> void:
	_mark_rects.clear()
	super()


func _draw_row(row: int, rect: Rect2, selected_row: bool) -> void:
	if not is_working_row(row):
		super(row, rect, selected_row)
		if not marked.is_empty() and String(_rows.get(row, {}).get("oid", "")) == marked:
			draw_rect(Rect2(rect.position, Vector2(float(get_theme_constant(&"marked_width", HISTORY_THEME_TYPE)),
					rect.size.y)), get_theme_color(&"marked_color", HISTORY_THEME_TYPE))
		return
	# One line in the middle of the row, its marks on the right.
	var data: Dictionary = _rows.get(row, {})
	var inner: Rect2 = rect.grow_individual(-_padding, 0.0, -_padding, 0.0)
	var marks_width: float = _trailing_width(data)
	var title: TextLine = _shape(tr("Uncommitted changes"),
			inner.size.x - (marks_width + _label_gap if marks_width > 0.0 else 0.0))
	title.draw(get_canvas_item(), Vector2(inner.position.x,
			roundf(rect.position.y + (rect.size.y - title.get_size().y) * 0.5)), _subject_color)
	if marks_width > 0.0:
		_draw_trailing(row, data, Rect2(inner.end.x - marks_width, rect.position.y, marks_width, rect.size.y), 1.0)
	if not compact:
		_draw_divider(row, rect, inner.position.x)


## The chip's text ("" without one) and the two counts as text ("" for a
## binary file, or a side without lines).
func _marks(data: Dictionary) -> PackedStringArray:
	var chip: String = tr(CHIP_TEXTS[String(data.get("code", ""))]) if CHIP_TEXTS.has(String(data.get("code", ""))) else ""
	var added: int = int(data.get("additions", -1))
	var removed: int = int(data.get("deletions", -1))
	return PackedStringArray([chip, "+%d" % added if added > 0 else "", "−%d" % removed if removed > 0 else ""])


func _trailing_width(data: Dictionary) -> float:
	if not String(data.get("kind", "")) in ["commit", "working"]:
		return 0.0
	var marks: PackedStringArray = _marks(data)
	var gap: float = float(get_theme_constant(&"mark_gap", HISTORY_THEME_TYPE))
	var width: float = 0.0
	if not marks[0].is_empty():
		width += _chip_size(marks[0]).x + gap
	for text: String in [marks[1], marks[2]]:
		if not text.is_empty():
			width += _stat_width(text) + gap
	return maxf(0.0, width - gap)


func _draw_trailing(row: int, data: Dictionary, rect: Rect2, alpha: float) -> void:
	var marks: PackedStringArray = _marks(data)
	var gap: float = float(get_theme_constant(&"mark_gap", HISTORY_THEME_TYPE))
	var x: float = rect.position.x
	var center: float = rect.position.y + rect.size.y * 0.5
	_mark_rects[row] = rect
	if not marks[0].is_empty():
		var color: Color = get_theme_color(CHIP_COLORS[String(data["code"])], HISTORY_THEME_TYPE)
		color.a *= alpha
		var chip_size: Vector2 = _chip_size(marks[0])
		var chip: Rect2 = Rect2(x, roundf(center - chip_size.y * 0.5), chip_size.x, chip_size.y)
		_chip_box.bg_color = Color(color, color.a * 0.16)
		draw_style_box(_chip_box, chip)
		var font_size: int = get_theme_font_size(&"chip_font_size", HISTORY_THEME_TYPE)
		var baseline: float = chip.position.y + (chip.size.y + _font.get_ascent(font_size) - _font.get_descent(font_size)) * 0.5
		draw_string(_font, Vector2(chip.position.x + _chip_inset(), baseline), marks[0], HORIZONTAL_ALIGNMENT_LEFT,
				-1, font_size, color)
		x += chip_size.x + gap
	var stat_size: int = get_theme_font_size(&"stat_font_size", HISTORY_THEME_TYPE)
	var stat_baseline: float = center + (_font.get_ascent(stat_size) - _font.get_descent(stat_size)) * 0.5
	for entry: Array in [[marks[1], &"stat_added_color"], [marks[2], &"stat_removed_color"]]:
		var text: String = entry[0]
		if text.is_empty():
			continue
		var color: Color = get_theme_color(entry[1], HISTORY_THEME_TYPE)
		color.a *= alpha
		draw_string(_font, Vector2(x, stat_baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, stat_size, color)
		x += _stat_width(text) + gap


func _chip_inset() -> float:
	return float(get_theme_constant(&"chip_padding", HISTORY_THEME_TYPE))


func _chip_size(text: String) -> Vector2:
	var font_size: int = get_theme_font_size(&"chip_font_size", HISTORY_THEME_TYPE)
	var text_size: Vector2 = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	return Vector2(text_size.x + _chip_inset() * 2.0, text_size.y)


func _stat_width(text: String) -> float:
	return _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			get_theme_font_size(&"stat_font_size", HISTORY_THEME_TYPE)).x


## What `row`'s marks say, in words: "Renamed from src/a.rs", the counts.
func marks_text(row: int) -> String:
	var working: bool = is_working_row(row)
	var data: Dictionary = row_data(row)
	if data.is_empty():
		return ""
	var lines: PackedStringArray = PackedStringArray()
	match String(data.get("code", "")):
		"A", "?":
			lines.append(tr("Not in the last commit") if working else tr("Added in this commit"))
		"D":
			lines.append(tr("Deleted since the last commit") if working else tr("Deleted in this commit"))
		"R":
			lines.append(tr("Renamed from %s") % String(data.get("original_path", "")))
		"C":
			lines.append(tr("Copied from %s") % String(data.get("original_path", "")))
		"U":
			lines.append(tr("Has conflicts"))
	var added: int = int(data.get("additions", -1))
	var removed: int = int(data.get("deletions", -1))
	if added >= 0:
		lines.append(tr("%d lines added, %d removed") % [added, removed])
	elif not working:
		lines.append(tr("Binary file"))
	return "\n".join(lines)


func _get_tooltip(at_position: Vector2) -> String:
	var row: int = row_at(at_position)
	if (_mark_rects.get(row, Rect2()) as Rect2).has_point(at_position):
		return marks_text(row)
	if is_working_row(row):
		return tr("What you changed in the file since the last commit")
	var shown: String = super(at_position)
	if not shown.is_empty():
		return shown
	return tr("Merge commit") if int(version_at(row).get("parents", 0)) > 1 else ""
