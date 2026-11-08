class_name CompareCommitList
extends CommitList
## The commits of a comparison (PLAN M7.12c), drawn as History's rows
## without the graph: an **All changes** row, then "Only on <right> (N)" and
## "Only on <left> (N)", each newest first (`RepoSession.compare_commits()`,
## fetched for a window around the visible rows). The cursor's commit
## narrows the files to its own; All changes shows the whole comparison.
## Ctrl/Shift select several commits to cherry-pick. The section headers are
## one-line rows that the cursor skips; clicking one folds its commits.

## The cursor moved to a commit (its `oid`) or to All changes ("").
signal focus_changed(oid: String)

## The side names for the section headers.
var _left_name: String = ""
var _right_name: String = ""
var _listed_right: int = 0
var _total: int = 0
var _file_count: int = 0
var _truncated: bool = false
## Folded sections ("right", "left"), kept while the sides keep their names.
var _collapsed: Dictionary[String, bool] = {}
## The rows, in runs: {kind, start (row), count, index (of the first
## commit, for `commit` runs)}.
var _runs: Array[Dictionary] = []
## The cursor before the last move, to skip headers in its direction.
var _last_cursor: int = -1
var _line: TextLine = TextLine.new()


func _init() -> void:
	super()
	show_graph = false
	follows_graph = false


func _ready() -> void:
	super()
	selection_changed.connect(_on_selection)


## Shows the comparison's commits (`RepoSession.compare_info()`), the
## cursor on `focus` (a commit's oid, or All changes for ""). Emits nothing.
func show_commits(info: Dictionary, left_name: String, right_name: String, focus: String) -> void:
	if left_name != _left_name or right_name != _right_name:
		_collapsed.clear()
	_left_name = left_name
	_right_name = right_name
	_total = int(info.get("commit_count", 0))
	_listed_right = int(info.get("listed_right", 0))
	_truncated = bool(info.get("commits_truncated", false))
	_file_count = int(info.get("all_file_count", 0))
	_layout()
	reload()
	var row: int = row_of(focus)
	set_block_signals(true)
	select_only(row if row >= 0 else 0)
	set_block_signals(false)
	_last_cursor = cursor
	if row >= 0:
		scroll_to_row(row)


## What row `row` is: `all`, `right` or `left` (a section header),
## `commit`, `more` (commits left out) or "".
func kind_at(row: int) -> String:
	var run: Dictionary = _run_of(row)
	return String(run.get("kind", ""))


## Whether section `kind` ("right" or "left") is folded.
func is_collapsed(kind: String) -> bool:
	return bool(_collapsed.get(kind, false))


## Folds or unfolds section `kind` ("right" or "left"). The cursor stays on
## its commit, or moves to All changes when that commit is folded away.
func toggle_section(kind: String) -> void:
	var focused: String = String(commit_at(cursor).get("oid", "")) if kind_at(cursor) == "commit" else ""
	_collapsed[kind] = not is_collapsed(kind)
	_layout()
	reload()
	var row: int = row_of(focused)
	if row < 0:
		select_only(0)
	else:
		set_block_signals(true)
		select_only(row)
		set_block_signals(false)
	_last_cursor = cursor


## The commit at `row` (`RepoSession.compare_commits` row), or empty.
func commit_at(row: int) -> Dictionary:
	return row_data(row) if kind_at(row) == "commit" else {}


## The row of commit `oid` (or of All changes for ""), or -1 (also when its
## section is folded).
func row_of(oid: String) -> int:
	if oid.is_empty():
		return 0
	if session == null:
		return -1
	var index: int = session.compare_commit_index(oid)
	for run: Dictionary in _runs:
		var first: int = int(run.get("index", -1))
		if run["kind"] == "commit" and index >= first and index < first + int(run["count"]):
			return int(run["start"]) + index - first
	return -1


## The selected commits, oldest first (as cherry-pick applies them).
func selected_commits() -> Array[Dictionary]:
	var commits: Array[Dictionary] = []
	for row: int in selected_rows():
		if kind_at(row) == "commit":
			var commit: Dictionary = commit_at(row).duplicate()
			commit["row"] = row
			commits.append(commit)
	commits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["time"]) != int(b["time"]):
			return int(a["time"]) < int(b["time"])
		return int(a["row"]) > int(b["row"]))
	return commits


func _commit_index(row: int) -> int:
	var run: Dictionary = _run_of(row)
	if run.get("kind", "") != "commit":
		return -1
	return int(run["index"]) + row - int(run["start"])


## All changes, then each side's header and (unless folded) its commits,
## then "more" when the list was cut short.
func _layout() -> void:
	_runs.clear()
	var listed_left: int = _total - _listed_right
	_add_run("all", 1)
	for side: Array in [["right", _listed_right, 0], ["left", listed_left, _listed_right]]:
		var kind: String = side[0]
		var count: int = side[1]
		if count > 0:
			_add_run(kind, 1)
			if not is_collapsed(kind):
				_add_run("commit", count, int(side[2]))
	if _truncated:
		_add_run("more", 1)


func _add_run(kind: String, count: int, index: int = -1) -> void:
	var start: int = 0
	if not _runs.is_empty():
		start = int(_runs[-1]["start"]) + int(_runs[-1]["count"])
	_runs.append({"kind": kind, "start": start, "count": count, "index": index})


func _run_of(row: int) -> Dictionary:
	if row < 0:
		return {}
	for run: Dictionary in _runs:
		if row < int(run["start"]) + int(run["count"]):
			return run
	return {}


func _get_row_count() -> int:
	if _runs.is_empty():
		return 0
	return int(_runs[-1]["start"]) + int(_runs[-1]["count"])


## Section headers and "more" are one-line rows; All changes and the
## commits have History's height.
func _run_height(kind: String) -> float:
	if kind in ["right", "left", "more"]:
		return float(maxi(1, get_theme_constant(&"row_height", THEME_TYPE)))
	return row_height()


func row_top(row: int) -> float:
	var top: float = 0.0
	for run: Dictionary in _runs:
		var start: int = int(run["start"])
		var count: int = int(run["count"])
		var height: float = _run_height(String(run["kind"]))
		if row < start + count:
			return top + (row - start) * height
		top += count * height
	return top


func row_extent(row: int) -> float:
	return _run_height(kind_at(row))


func row_at_offset(offset: float) -> int:
	var top: float = 0.0
	for run: Dictionary in _runs:
		var count: int = int(run["count"])
		var height: float = _run_height(String(run["kind"]))
		if offset < top + count * height:
			return int(run["start"]) + int(maxf(0.0, offset - top) / height)
		top += count * height
	return _get_row_count()


## The short rows let a few more rows show.
func visible_row_count() -> int:
	return super() + 3


func _fetch_rows(start: int, count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if session == null:
		return out
	var end: int = mini(start + count, row_count())
	# One fetch for the commits among the rows.
	var first: int = -1
	var last: int = -1
	for row: int in range(start, end):
		var index: int = _commit_index(row)
		if index >= 0:
			first = index if first < 0 else first
			last = index
	var commits: Array[Dictionary] = []
	if first >= 0:
		commits = session.compare_commits(first, last - first + 1)
	for row: int in range(start, end):
		var kind: String = kind_at(row)
		var data: Dictionary = {"row": row, "kind": kind}
		if kind == "commit":
			var at: int = _commit_index(row) - first
			if at < 0 or at >= commits.size():
				continue
			data = commits[at].duplicate()
			data["row"] = row
			data["kind"] = kind
		out.append(data)
	return out


## A click on a section header folds it; one on "more" does nothing.
func _gui_input(event: InputEvent) -> void:
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		var kind: String = kind_at(row_at(mouse.position))
		if kind in ["right", "left", "more"]:
			grab_focus()
			if kind != "more" and mouse.button_index == MOUSE_BUTTON_LEFT and not mouse.double_click:
				toggle_section(kind)
			accept_event()
			return
	super(event)


## Moves off a section header in the direction the cursor went.
func _on_selection() -> void:
	var kind: String = kind_at(cursor)
	if kind in ["right", "left", "more"]:
		var step: int = -1 if cursor < _last_cursor else 1
		var row: int = cursor + step
		while row >= 0 and row < row_count() and kind_at(row) not in ["all", "commit"]:
			row += step
		if row < 0 or row >= row_count():
			row = _last_cursor
		select_only(row)
		return
	_last_cursor = cursor
	match kind:
		"all":
			focus_changed.emit("")
		"commit":
			focus_changed.emit(String(commit_at(cursor).get("oid", "")))


func _draw_row(row: int, rect: Rect2, selected_row: bool) -> void:
	var kind: String = kind_at(row)
	if kind == "commit":
		super(row, rect, selected_row)
		return
	var padding: float = float(get_theme_constant(&"padding", LIST_THEME_TYPE))
	var inner: Rect2 = rect.grow_individual(-padding, 0.0, -padding, 0.0)
	match kind:
		"all":
			var font_size: int = get_theme_font_size(&"font_size", &"Label")
			var meta_size: int = get_theme_font_size(&"meta_font_size", LIST_THEME_TYPE)
			var title: TextLine = _text_line(tr("All changes"), inner.size.x, font_size)
			var meta: TextLine = _text_line(ListHeader.count_text(_file_count, "changed file"), inner.size.x, meta_size)
			var gap: float = float(get_theme_constant(&"line_gap", LIST_THEME_TYPE))
			var top: float = rect.position.y + (rect.size.y - title.get_size().y - gap - meta.get_size().y) * 0.5
			title.draw(get_canvas_item(), Vector2(inner.position.x, top), get_theme_color(&"subject_color", LIST_THEME_TYPE))
			meta.draw(get_canvas_item(), Vector2(inner.position.x, top + title.get_size().y + gap),
					get_theme_color(&"meta_color", LIST_THEME_TYPE))
		"right":
			_draw_section(tr("Only on %s (%d)") % [_right_name, _listed_right], inner, is_collapsed(kind))
		"left":
			_draw_section(tr("Only on %s (%d)") % [_left_name, _total - _listed_right], inner, is_collapsed(kind))
		"more":
			_draw_section(tr("More commits are not listed"), inner, false, false)


## A section's name, after its fold arrow, centred in its row.
func _draw_section(text: String, rect: Rect2, collapsed: bool, arrow: bool = true) -> void:
	var color: Color = get_theme_color(&"section_color", ComparePicker.THEME_TYPE)
	var x: float = rect.position.x
	if arrow:
		var icon: Texture2D = AppTheme.icon(&"GuiTreeArrowRight" if collapsed else &"GuiTreeArrowDown")
		var icon_size: Vector2 = icon.get_size()
		draw_texture(icon, Vector2(x, roundf(rect.position.y + (rect.size.y - icon_size.y) * 0.5)), color)
		x += icon_size.x + float(get_theme_constant(&"label_gap", LIST_THEME_TYPE))
	var line: TextLine = _text_line(text, rect.end.x - x, get_theme_font_size(&"meta_font_size", LIST_THEME_TYPE))
	line.draw(get_canvas_item(), Vector2(x, roundf(rect.position.y + (rect.size.y - line.get_size().y) * 0.5)), color)


## No line under the last commit of a section.
func _draw_divider(row: int, rect: Rect2, subject_x: float) -> void:
	if kind_at(row + 1) == "commit":
		super(row, rect, subject_x)


func _text_line(text: String, width: float, font_size: int) -> TextLine:
	_line = TextLine.new()
	_line.width = maxf(0.0, width)
	_line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_line.add_string(text, get_theme_font(&"font", &"Label"), font_size)
	return _line


func _get_tooltip(at_position: Vector2) -> String:
	var row: int = row_at(at_position)
	match kind_at(row):
		"all":
			return tr("Every file the comparison changes")
		"commit":
			var shown: String = super(at_position)
			if not shown.is_empty():
				return shown
			var data: Dictionary = commit_at(row)
			var lines: PackedStringArray = PackedStringArray()
			if int(data.get("parents", 0)) > 1:
				lines.append(tr("Merge commit"))
			if bool(data.get("in_head", false)):
				lines.append(tr("Already in the current branch"))
			return "\n".join(lines)
	return ""
