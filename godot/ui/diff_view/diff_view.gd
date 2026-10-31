class_name DiffView
extends VirtualList
## A file diff drawn in a monospace font, unified or side by side, with
## syntax colors and the changed words of paired lines highlighted.
##
## Unified rows come from `source.call(start, count)`: lines like
## `{index, kind, old, new, text, no_newline, hl, syntax}` (kind 0 = hunk
## header, 1 = context, 2 = added, 3 = removed; `hl` = changed `[start, end)`;
## `syntax` = `start, end, token` triples; `index` -1 for an unchanged line
## outside the hunks). Side-by-side rows come from
## `split_source.call(start, count)` as `{left, right}` lines (or {}).
## Only a window around the visible rows is fetched.
##
## The text is selected like plain text: drag, double-click a word (drag on
## by words), triple-click a line (drag on by lines), Shift+click to extend,
## Shift+Left/Right (with Ctrl, by words), Ctrl+A, Ctrl+C; side by side, on
## one side at a time. The arrow keys move a line at a time (Shift extends)
## and show a caret. `selected_or_cursor()` gives the lines the selection
## touches. A header row with `expand` (`up`, `down`, `both`, `all`) draws
## buttons for its `gap` that emit `expand_requested`, and says how many
## lines the gap hides (`hidden`); the end row is one button.
## With `pickable`, a gutter of commit checkboxes comes first, from each
## line's `picked` (`all`, `none`, `partial`, or empty for no box); clicking
## one emits `pick_clicked`.
## Conflicted files (the resolver) use the same rows: ours as removed lines,
## theirs as added ones, the base as kind 4, and a header per conflict block
## (`block` >= 0) with buttons that emit `block_action`. Their `side` (`ours`,
## `theirs`, `base`) draws them in the sides' own colours, with a bar at the
## gutter's edge instead of a +/− mark.

## A checkbox was clicked: the line indices of its row, and whether to pick
## them (the box was not `all`).
signal pick_clicked(lines: PackedInt32Array, include: bool)
## An expander was clicked: show more of gap `gap` (`up`, `down` or `all`).
signal expand_requested(gap: int, how: String)
## A conflict block's button was clicked: `ours`, `theirs` or `both`.
signal block_action(block: int, action: String)
## The Undo beside lines that a block choice just wrote was clicked.
signal undo_choice_requested()

const DIFF_THEME_TYPE: StringName = &"DiffView"
const FETCH_MARGIN: int = 128
const KIND_HUNK: int = 0
const KIND_CONTEXT: int = 1
const KIND_ADDED: int = 2
const KIND_REMOVED: int = 3
## The base of a conflict block (between ours and theirs).
const KIND_BASE: int = 4
## A conflict header's buttons: what each keeps (`%s` is the side's name)
## and the action whose shortcut its tooltip names.
const BLOCK_TIPS: Dictionary[String, String] = {
	"ours": "Keep the lines of %s (ours)",
	"theirs": "Keep the lines of %s (theirs)",
	"both": "Keep both, in either order",
}
const BLOCK_ACTIONS: Dictionary[String, StringName] = {
	"ours": &"conflict.use_ours", "theirs": &"conflict.use_theirs", "both": &"conflict.use_both",
}
## The arrows of the side-by-side block buttons, pointing at their side.
const SPLIT_ARROWS: PackedStringArray = ["◀  ", "  ▶"]
## How long the lines a block choice wrote stay highlighted, and how long
## their Undo shows (ms).
const FLASH_MSEC: int = 1200
const CHOICE_UNDO_MSEC: int = 6000
## Longest side name a block button shows before it is shortened with "…".
const BLOCK_NAME_CHARS: int = 18
const NO_NEWLINE_MARK: String = "   \\ no newline at end of file"
## Theme colors of `highlight::TokenKind` ids 0..4.
const SYNTAX_COLORS: Array[StringName] = [
	&"syntax_keyword", &"syntax_type", &"syntax_string", &"syntax_number", &"syntax_comment",
]
## The buttons of each `expand` value, left to right.
const EXPANDERS: Dictionary[String, Array] = {
	"up": ["up"], "down": ["down"], "both": ["down", "up"], "all": ["all"],
}
const EXPANDER_ICONS: Dictionary[String, StringName] = {
	"up": &"ExpandUp", "down": &"ExpandDown", "all": &"ExpandAll",
}
const EXPANDER_TIPS: Dictionary[String, String] = {
	"up": "Show more lines above",
	"down": "Show more lines below",
	"all": "Show the hidden lines",
}
## Width of the bar that marks a conflict side's lines in the gutter.
const CONFLICT_BAR_WIDTH: float = 3.0
## Expander buttons are this many rows wide.
const EXPANDER_WIDTH: float = 1.6
## What a drag extends by after the click that started it.
enum Unit { CHAR, WORD, LINE }
## Clicks this close in time (ms) and space (px) count as one double or
## triple click.
const MULTI_CLICK_MSEC: int = 450
const MULTI_CLICK_DISTANCE: float = 6.0
## Drag-scrolling speed per pixel the mouse is past the edge, per second.
const DRAG_SCROLL_RATE: float = 12.0

## Unified lines of a range; see the class docs.
var source: Callable = Callable()
## Side-by-side rows of a range; see the class docs.
var split_source: Callable = Callable()
## Show the old and new sides next to each other.
var side_by_side: bool = false:
	set = set_side_by_side
## Names of the two sides of a conflict (ours, theirs), such as the branches,
## for the block buttons ("Use main").
var side_names: PackedStringArray = PackedStringArray(["ours", "theirs"]):
	set(value):
		side_names = value
		queue_redraw()
## Conflict blocks in the file shown, for the headers ("Conflict 1 of 2").
var block_count: int = 0:
	set(value):
		block_count = value
		queue_redraw()
## Show the commit checkboxes' gutter.
var pickable: bool = false:
	set(value):
		if value != pickable:
			pickable = value
			queue_redraw()
			_update_h_range()

var _line_count: int = 0
var _split_count: int = 0
var _number_digits: int = 1
var _cache: Dictionary[int, Dictionary] = {}
var _h_scroll: HScrollBar = HScrollBar.new()
var _widest: float = 0.0

## Selection as `(row, column)` ends; `_sel_to` is the caret. Row -1: none.
var _sel_from: Vector2i = Vector2i(-1, 0)
var _sel_to: Vector2i = Vector2i(-1, 0)
## Side the selection is on: 0 unified or left, 1 right.
var _sel_side: int = 0
var _dragging: bool = false
var _drag_mouse: Vector2 = Vector2.ZERO
var _drag_unit: Unit = Unit.CHAR
## The word or line a double or triple click selected, which a drag keeps.
var _unit_from: Vector2i = Vector2i.ZERO
var _unit_to: Vector2i = Vector2i.ZERO
var _clicks: int = 0
var _last_click_msec: int = 0
var _last_click_at: Vector2 = Vector2.ZERO
## The caret shows after the keyboard moved it, not after the mouse.
var _keyboard_caret: bool = false
## `[row, how]` of the expander under the mouse, or [].
var _hover: Array = []
## `[row, action]` of the block button under the mouse, or [].
var _block_hover: Array = []
## Gap whose expander was pressed, until the rows change; -1 for none.
var _expanding_gap: int = -1
## Rows a block choice just wrote (`x` first, `y` count), what they say
## ("Used main"), how strongly they are highlighted (fading to 0) and until
## when their Undo shows; `x` -1 for none.
var _choice_rows: Vector2i = Vector2i(-1, 0)
var _choice_text: String = ""
var _choice_until: int = 0
var _choice_hover: bool = false
var flash_strength: float = 0.0:
	set(value):
		flash_strength = value
		queue_redraw()

var _font: Font = null
var _font_size: int = 0
## The UI font, for conflict headers and their buttons.
var _ui_font: Font = null
var _ui_font_size: int = 0
var _button_box: StyleBoxFlat = StyleBoxFlat.new()
var _button_hover_box: StyleBoxFlat = StyleBoxFlat.new()
var _char_width: float = 0.0
var _padding: float = 0.0
var _colors: Dictionary[StringName, Color] = {}
var _syntax: Array[Color] = []
var _picks: PickPainter = PickPainter.new()


func _init() -> void:
	super()
	draws_selection = false


func _ready() -> void:
	super()
	add_child(_h_scroll, false, Node.INTERNAL_MODE_FRONT)
	_h_scroll.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_h_scroll.value_changed.connect(func(_v: float) -> void: queue_redraw())
	resized.connect(_update_h_range)
	mouse_exited.connect(func() -> void:
		_set_hover([])
		_block_hover = [])
	set_process(false)
	_update_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_update_theme()
		queue_redraw()
	elif what == NOTIFICATION_FOCUS_ENTER or what == NOTIFICATION_FOCUS_EXIT:
		queue_redraw()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		if not _hover.is_empty():
			tooltip_text = tr(EXPANDER_TIPS.get(String(_hover[1]), ""))
		queue_redraw()


## Shows a diff of `line_count` lines (`split_count` side-by-side rows);
## `max_line_number` sizes the number gutter. Keeps the scroll position when
## `keep_scroll` (a reload of the same file), and the selection too when the
## rows are the same.
func show_lines(line_count: int, max_line_number: int, keep_scroll: bool, split_count: int = -1) -> void:
	var rows_changed: bool = line_count != _line_count \
			or (split_count if split_count >= 0 else line_count) != _split_count
	_line_count = line_count
	_split_count = split_count if split_count >= 0 else line_count
	_number_digits = maxi(1, str(max_line_number).length())
	_cache.clear()
	if rows_changed or not keep_scroll:
		_expanding_gap = -1
		_choice_rows = Vector2i(-1, 0)
	if not keep_scroll:
		_widest = 0.0
		_h_scroll.value = 0.0
		set_scroll_offset(0.0)
	refresh()
	if not keep_scroll:
		_reset_selection()
	elif rows_changed:
		# Rows mean other lines now: keep only the caret's row, so Enter can
		# pick line after line.
		_collapse(mini(cursor, row_count() - 1))
	_update_h_range()


## Drops the fetched rows so they are read again (their picks changed).
func invalidate() -> void:
	_cache.clear()
	queue_redraw()


## The checkbox of `row`: its line's `picked`, both sides combined side by
## side (`all` or `none` when they agree, else `partial`); "" for no box.
func row_pick(row: int) -> String:
	var states: PackedStringArray = PackedStringArray()
	for data: Dictionary in _row_lines(row):
		var picked: String = String(data.get("picked", ""))
		if not picked.is_empty() and int(data.get("kind", -1)) != KIND_CONTEXT:
			states.append(picked)
	if states.is_empty():
		return ""
	for state: String in states:
		if state != states[0]:
			return "partial"
	return states[0]


## Whether every line with a checkbox among the selected rows (or the
## cursor's row) is picked.
func selection_fully_picked() -> bool:
	var rows: PackedInt32Array = selected_rows()
	if rows.is_empty() and cursor >= 0:
		rows.append(cursor)
	for row: int in rows:
		var state: String = row_pick(row)
		if not state.is_empty() and state != "all":
			return false
	return true


func set_side_by_side(value: bool) -> void:
	if value == side_by_side:
		return
	side_by_side = value
	_choice_rows = Vector2i(-1, 0)
	_cache.clear()
	set_scroll_offset(0.0)
	refresh()
	_reset_selection()
	_update_h_range()


## Horizontal scroll offset in pixels.
func h_scroll() -> float:
	return _h_scroll.value


func row_height() -> float:
	return float(maxi(1, get_theme_constant(&"row_height", DIFF_THEME_TYPE)))


## Data of a row: a line (unified) or `{left, right}` (side by side).
func row_data(row: int) -> Dictionary:
	if row < 0 or row >= row_count():
		return {}
	if not _cache.has(row):
		_fetch(row, 1)
	return _cache.get(row, {})


## The line shown on a unified row, or the new side (else old side) of a
## side-by-side row.
func line(row: int) -> Dictionary:
	var data: Dictionary = row_data(row)
	if not side_by_side:
		return data
	var right: Dictionary = data.get("right", {})
	return right if not right.is_empty() else data.get("left", {})


func line_text(row: int) -> String:
	return String(line(row).get("text", ""))


## Line indices of the rows the selection touches (or the cursor's row),
## both sides of side-by-side rows included.
func selected_or_cursor() -> PackedInt32Array:
	var rows: PackedInt32Array = selected_rows()
	if rows.is_empty() and cursor >= 0:
		rows.append(cursor)
	var lines: PackedInt32Array = PackedInt32Array()
	for row: int in rows:
		for data: Dictionary in _row_lines(row):
			var index: int = int(data.get("index", -1))
			if index >= 0 and not lines.has(index):
				lines.append(index)
	lines.sort()
	return lines


## Whether some text is selected.
func has_selection() -> bool:
	return _sel_from.x >= 0 and _sel_from != _sel_to


## Rows the selection touches; one that it only reaches at its start does
## not count.
func selected_rows() -> PackedInt32Array:
	var rows: PackedInt32Array = PackedInt32Array()
	if not has_selection():
		return rows
	var ends: Array[Vector2i] = _ordered()
	var last: int = ends[1].x - 1 if ends[1].y == 0 and ends[1].x > ends[0].x else ends[1].x
	for row: int in range(ends[0].x, mini(last, row_count() - 1) + 1):
		rows.append(row)
	return rows


func is_selected(row: int) -> bool:
	return selected_rows().has(row)


## The selected text, lines joined by newlines (hunk headers left out).
func selected_text() -> String:
	if not has_selection():
		return ""
	var ends: Array[Vector2i] = _ordered()
	var parts: PackedStringArray = PackedStringArray()
	for row: int in range(ends[0].x, mini(ends[1].x, row_count() - 1) + 1):
		var data: Dictionary = _side_line(row, _sel_side)
		if data.is_empty() or int(data.get("kind", KIND_HUNK)) == KIND_HUNK:
			continue
		var text: String = String(data.get("text", ""))
		var from: int = ends[0].y if row == ends[0].x else 0
		var to: int = ends[1].y if row == ends[1].x else text.length()
		parts.append(text.substr(from, maxi(0, to - from)))
	return "\n".join(parts)


## Selects the whole text of `row` and puts the caret there.
func select_only(row: int) -> void:
	_select_lines(row, row)
	_anchor = row
	if row >= 0:
		scroll_to_row(row)


func clear_selection() -> void:
	_collapse(cursor)


func select_all() -> void:
	if row_count() > 0:
		_select_lines(0, row_count() - 1)


## The expanders of `row` (`up`, `down`, `both`, `all`, or "").
func row_expanders(row: int) -> String:
	return String(_side_line(row, 0).get("expand", ""))


## Clicks expander `how` of `row`, as the mouse would.
func press_expander(row: int, how: String) -> void:
	var data: Dictionary = _side_line(row, 0)
	if EXPANDERS.get(String(data.get("expand", "")), []).has(how):
		_expanding_gap = int(data.get("gap", -1))
		queue_redraw()
		expand_requested.emit(_expanding_gap, how)


## What `row`'s expanders say: the lines its gap hides, or that they load.
func expander_label(row: int) -> String:
	var data: Dictionary = _side_line(row, 0)
	if String(data.get("expand", "")).is_empty():
		return ""
	if int(data.get("gap", -1)) == _expanding_gap:
		return tr("Loading…")
	var hidden_count: int = int(data.get("hidden", -1))
	if String(data.get("text", "")).is_empty():
		if hidden_count <= 0:
			return tr("Show more lines")
		return tr("Show %d more line") % hidden_count if hidden_count == 1 else tr("Show %d more lines") % hidden_count
	if hidden_count <= 0:
		return ""
	return tr("1 line hidden") if hidden_count == 1 else tr("%d lines hidden") % hidden_count



## The conflict block a row belongs to (its header, a side or the base), or -1.
func row_block(row: int) -> int:
	for data: Dictionary in _row_lines(row):
		var block: int = int(data.get("block", -1))
		if block >= 0:
			return block
	return -1


## The header row of the next (or previous) conflict block from `from`,
## wrapping around; only block `block` when it is >= 0. -1 when none.
func find_block_header(from: int, forward: bool, block: int = -1) -> int:
	var count: int = row_count()
	for step: int in range(1, count + 1):
		var row: int = posmod(from + (step if forward else -step), count)
		var data: Dictionary = _side_line(row, 0)
		var found: int = int(data.get("block", -1))
		if int(data.get("kind", -1)) == KIND_HUNK and found >= 0 and (block < 0 or found == block):
			return row
	return -1


## Where button `action` of the conflict header on `row` is, in this
## control's coordinates (empty when the row is not a header).
func block_button_rect(row: int, action: String) -> Rect2:
	var data: Dictionary = _side_line(row, 0)
	if int(data.get("block", -1)) < 0 or int(data.get("kind", -1)) != KIND_HUNK:
		return Rect2()
	var top: float = row * row_height() - scroll_offset()
	var rect: Rect2 = Rect2(_pick_width(), top, content_width() - _pick_width(), row_height())
	for entry: Array in _block_rects(rect):
		if String(entry[0]) == action:
			return entry[1]
	return Rect2()


## Lines of block `block` on each side (`x` ours, `y` theirs).
func block_side_lines(block: int) -> Vector2i:
	var header: int = find_block_header(-1, true, block)
	var lines: Vector2i = Vector2i.ZERO
	if header < 0:
		return lines
	for row: int in range(header + 1, row_count()):
		if row_block(row) != block:
			break
		for data: Dictionary in _row_lines(row):
			match String(data.get("side", "")):
				"ours":
					lines.x += 1
				"theirs":
					lines.y += 1
	return lines


## Highlights `count` rows from `first` (what a block choice wrote, saying
## `text`) for a moment, with an Undo beside them for a few seconds.
func show_choice(first: int, count: int, text: String) -> void:
	_choice_rows = Vector2i(first, maxi(1, count))
	_choice_text = text
	_choice_until = Time.get_ticks_msec() + CHOICE_UNDO_MSEC
	flash_strength = 1.0
	create_tween().tween_property(self, "flash_strength", 0.0, FLASH_MSEC / 1000.0) \
			.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	get_tree().create_timer(CHOICE_UNDO_MSEC / 1000.0).timeout.connect(queue_redraw)


## Drops the Undo of the last block choice.
func clear_choice() -> void:
	_choice_rows = Vector2i(-1, 0)
	_choice_hover = false
	queue_redraw()


## Whether the Undo of the last block choice shows (for tests).
func choice_undo_shown() -> bool:
	return _choice_rows.x >= 0 and _choice_rows.x < row_count() and Time.get_ticks_msec() < _choice_until


## Where the choice's Undo button is, in this control's coordinates (empty
## when it does not show).
func choice_undo_rect() -> Rect2:
	if not choice_undo_shown():
		return Rect2()
	var label: String = tr("Undo")
	var width: float = _ui_font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, _ui_font_size).x \
			+ _icon_side() + _padding * 2.5
	var top: float = _choice_rows.x * row_height() - scroll_offset()
	return Rect2(content_width() - width - _padding * 0.5, top + 1.0, width, row_height() - 2.0)


## Clicks a conflict header's button, as the mouse would.
func press_block(row: int, action: String) -> void:
	var data: Dictionary = _side_line(row, 0)
	if int(data.get("block", -1)) >= 0 and int(data.get("kind", -1)) == KIND_HUNK:
		block_action.emit(int(data["block"]), action)


## Copies the selected text; false when nothing is selected.
func copy_selection() -> bool:
	if not has_selection():
		return false
	DisplayServer.clipboard_set(selected_text())
	return true


## Whether the caret is drawn (after keyboard moves).
func caret_shown() -> bool:
	return _keyboard_caret and has_focus() and _sel_to.x >= 0


# --- Selection ----------------------------------------------------------------


## `[start, end]` of the selection in reading order.
func _ordered() -> Array[Vector2i]:
	var forward: bool = _sel_from.x < _sel_to.x or (_sel_from.x == _sel_to.x and _sel_from.y <= _sel_to.y)
	if forward:
		return [_sel_from, _sel_to]
	return [_sel_to, _sel_from]


## The line on `side` of `row` (the row itself in the unified layout).
func _side_line(row: int, side: int) -> Dictionary:
	var data: Dictionary = row_data(row)
	if not side_by_side or data.is_empty():
		return data
	return data.get("right" if side == 1 else "left", {})


## Characters of `row`'s text on `side` (0 for headers and empty sides).
func _line_length(row: int, side: int) -> int:
	var data: Dictionary = _side_line(row, side)
	if data.is_empty() or int(data.get("kind", KIND_HUNK)) == KIND_HUNK:
		return 0
	return String(data.get("text", "")).length()


## Selects rows `from` to `to` whole (in that direction: the caret ends on
## `to`), on the side already chosen.
func _select_lines(from: int, to: int) -> void:
	if from < 0 or to < 0 or row_count() == 0:
		_reset_selection()
		return
	from = clampi(from, 0, row_count() - 1)
	to = clampi(to, 0, row_count() - 1)
	if from <= to:
		_sel_from = Vector2i(from, 0)
		_sel_to = Vector2i(to, _line_length(to, _sel_side))
	else:
		_sel_from = Vector2i(from, _line_length(from, _sel_side))
		_sel_to = Vector2i(to, 0)
	cursor = to
	queue_redraw()
	selection_changed.emit()


## No selection: the caret alone at the start of `row` (none for -1).
func _collapse(row: int) -> void:
	_sel_to = Vector2i(row, 0) if row >= 0 else Vector2i(-1, 0)
	_sel_from = _sel_to
	cursor = row
	queue_redraw()
	selection_changed.emit()


func _reset_selection() -> void:
	_dragging = false
	_sel_side = 0
	_collapse(-1)


## `[start, end]` of the word (or run of spaces, or single other character)
## at `at`; both at `at` on an empty line.
func _word_at(at: Vector2i) -> Array[Vector2i]:
	var text: String = String(_side_line(at.x, _sel_side).get("text", ""))
	if _line_length(at.x, _sel_side) == 0:
		return [Vector2i(at.x, 0), Vector2i(at.x, 0)]
	var column: int = clampi(at.y, 0, text.length() - 1)
	var kind: int = _char_class(text[column])
	var start: int = column
	var end: int = column + 1
	if kind != 2:
		while start > 0 and _char_class(text[start - 1]) == kind:
			start -= 1
		while end < text.length() and _char_class(text[end]) == kind:
			end += 1
	return [Vector2i(at.x, start), Vector2i(at.x, end)]


## Selects from `from` to `to` (the caret).
func _select_span(from: Vector2i, to: Vector2i) -> void:
	_sel_from = from
	_sel_to = to
	cursor = to.x
	queue_redraw()
	selection_changed.emit()


## The caret moved one character (or with `by_word`, one word) left or right
## of `at`, across line ends.
func _step(at: Vector2i, forward: bool, by_word: bool) -> Vector2i:
	var text: String = String(_side_line(at.x, _sel_side).get("text", ""))
	var length: int = _line_length(at.x, _sel_side)
	var column: int = mini(at.y, length)
	if forward:
		if column >= length:
			return Vector2i(at.x + 1, 0) if at.x + 1 < row_count() else at
		if not by_word:
			return Vector2i(at.x, column + 1)
		while column < length and _char_class(text[column]) == 1:
			column += 1
		var start_kind: int = _char_class(text[mini(column, length - 1)])
		column += 1
		while column < length and _char_class(text[column]) == start_kind and start_kind != 2:
			column += 1
		return Vector2i(at.x, column)
	if column <= 0:
		return Vector2i(at.x - 1, _line_length(at.x - 1, _sel_side)) if at.x > 0 else at
	if not by_word:
		return Vector2i(at.x, column - 1)
	while column > 0 and _char_class(text[column - 1]) == 1:
		column -= 1
	if column == 0:
		return Vector2i(at.x, 0)
	var kind: int = _char_class(text[column - 1])
	column -= 1
	while column > 0 and _char_class(text[column - 1]) == kind and kind != 2:
		column -= 1
	return Vector2i(at.x, column)


## 0 = word character, 1 = space, 2 = anything else.
static func _char_class(c: String) -> int:
	if c == " ":
		return 1
	if c == "_" or c.is_valid_int() or c.is_valid_unicode_identifier():
		return 0
	return 2


## Selected columns `[from, to)` of `row` on `side`, `to` one past the text
## when the selection goes on to the next row; (-1, -1) when none.
func _selected_columns(row: int, side: int, length: int) -> Vector2i:
	if not has_selection() or side != _sel_side:
		return Vector2i(-1, -1)
	var ends: Array[Vector2i] = _ordered()
	if row < ends[0].x or row > ends[1].x:
		return Vector2i(-1, -1)
	var from: int = ends[0].y if row == ends[0].x else 0
	var to: int = ends[1].y if row == ends[1].x else length + 1
	return Vector2i(from, to) if to > from else Vector2i(-1, -1)


# --- Geometry -------------------------------------------------------------------


## Width of the checkbox gutter (0 when not `pickable`).
func _pick_width() -> float:
	return _picks.size + _padding if pickable else 0.0


## Width of a number gutter: `columns` number columns, the +/- mark, a space.
func _gutter_width(columns: int) -> float:
	return (_number_digits * columns + columns + 2) * _char_width + _padding * 2.0


## Left edge and width of `side` (0 for the unified layout or the left side).
func _side_span(side: int) -> Vector2:
	var left: float = _pick_width()
	var width: float = content_width() - left
	if not side_by_side:
		return Vector2(left, width)
	var half: float = floorf(width / 2.0)
	return Vector2(left + half, width - half) if side == 1 else Vector2(left, half)


## Where column 0 of `side`'s text is drawn (0 = unified or left, 1 = right),
## before scrolling sideways.
func text_left(side: int) -> float:
	return _text_left(side)


func _text_left(side: int) -> float:
	return _side_span(side).x + _gutter_width(1 if side_by_side else 2)


## The side under `x` (always 0 unified).
func _side_at(x: float) -> int:
	return 1 if side_by_side and x >= _side_span(1).x else 0


## The `(row, column)` at `at` on `side`, clamped to the rows and the text.
func _position_at(at: Vector2, side: int) -> Vector2i:
	if row_count() == 0:
		return Vector2i(-1, 0)
	var row: int = int(floorf((at.y + scroll_offset()) / row_height()))
	if row < 0:
		return Vector2i(0, 0)
	if row >= row_count():
		return Vector2i(row_count() - 1, _line_length(row_count() - 1, side))
	var skip: int = int(_h_scroll.value / _char_width) if _char_width > 0.0 else 0
	var column: int = roundi((at.x - _text_left(side)) / maxf(_char_width, 1.0)) + skip
	return Vector2i(row, clampi(column, 0, _line_length(row, side)))


func _baseline(rect: Rect2) -> float:
	return rect.position.y + (rect.size.y + _font.get_ascent(_font_size) - _font.get_descent(_font_size)) / 2.0


## `[how, rect]` per expander button of a header row drawn from `left`.
## The end row (no text) is one button across the row.
func _expander_rects(data: Dictionary, left: float, rect: Rect2) -> Array:
	var out: Array = []
	var hows: Array = EXPANDERS.get(String(data.get("expand", "")), [])
	if hows.size() == 1 and String(data.get("text", "")).is_empty():
		out.append([hows[0], Rect2(left, rect.position.y, rect.end.x - left, rect.size.y)])
		return out
	var width: float = roundf(rect.size.y * EXPANDER_WIDTH)
	var x: float = left + _padding * 0.25
	for how: String in hows:
		out.append([how, Rect2(x, rect.position.y, width, rect.size.y)])
		x += width
	return out


## `[action, rect, label]` per button of a conflict header drawn in `rect`:
## right-aligned unified; side by side, each side's button next to the
## divider on its own half ("◀ Use main" | "Use topic ▶") and Both at the end.
func _block_rects(rect: Rect2) -> Array:
	var out: Array = []
	var top: float = rect.position.y + 1.0
	var height: float = rect.size.y - 2.0
	var gap: float = _padding * 0.5
	if side_by_side:
		var middle: float = _side_span(1).x
		var ours: String = SPLIT_ARROWS[0] + block_label("ours")
		var ours_width: float = _block_button_width(ours, false)
		out.append(["ours", Rect2(middle - gap - ours_width, top, ours_width, height), ours])
		var theirs: String = block_label("theirs") + SPLIT_ARROWS[1]
		out.append(["theirs", Rect2(middle + gap, top, _block_button_width(theirs, false), height), theirs])
		var both_width: float = _block_button_width(block_label("both"), true)
		out.append(["both", Rect2(rect.end.x - gap - both_width, top, both_width, height), block_label("both")])
		return out
	var x: float = rect.end.x - gap
	for action: String in ["both", "theirs", "ours"]:
		var label: String = block_label(action)
		var width: float = _block_button_width(label, action == "both")
		x -= width
		out.push_front([action, Rect2(x, top, width, height), label])
		x -= gap
	return out


## What a conflict header's button says: "Use main", "Use topic", "Both".
func block_label(action: String) -> String:
	if action == "both":
		return tr("Both")
	var side_name: String = side_names[0 if action == "ours" else 1] if side_names.size() == 2 else action
	if side_name.length() > BLOCK_NAME_CHARS:
		side_name = side_name.left(BLOCK_NAME_CHARS - 1) + "…"
	return tr("Use %s") % side_name


## Width of a block button showing `label` (and a ▾ when `menu`, else a swatch).
func _block_button_width(label: String, menu: bool) -> float:
	var width: float = _ui_font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, _ui_font_size).x + _padding * 2.0
	if menu:
		width += _icon_side() + _padding * 0.25
	else:
		width += _swatch_side() + _padding * 0.5
	return roundf(width)


## Diameter of a block button's colour dot.
func _swatch_side() -> float:
	return roundf(row_height() * 0.4)


## Side of the icons drawn in a row.
func _icon_side() -> float:
	return minf(16.0, row_height() - 4.0)


## `[row, action]` of the conflict header button at `at`, or [].
func _block_at(at: Vector2) -> Array:
	var row: int = row_at(at)
	if row < 0:
		return []
	var data: Dictionary = _side_line(row, 0)
	if data.is_empty() or int(data.get("kind", -1)) != KIND_HUNK or int(data.get("block", -1)) < 0:
		return []
	var top: float = row * row_height() - scroll_offset()
	var rect: Rect2 = Rect2(_pick_width(), top, content_width() - _pick_width(), row_height())
	for entry: Array in _block_rects(rect):
		if (entry[1] as Rect2).has_point(at):
			return [row, entry[0]]
	return []


## `[row, how]` of the expander at `at`, or [].
func _expander_at(at: Vector2) -> Array:
	var row: int = row_at(at)
	if row < 0:
		return []
	var data: Dictionary = _side_line(row, 0)
	if data.is_empty() or int(data.get("kind", -1)) != KIND_HUNK:
		return []
	var top: float = row * row_height() - scroll_offset()
	var rect: Rect2 = Rect2(0.0, top, content_width(), row_height())
	for entry: Array in _expander_rects(data, _pick_width(), rect):
		if (entry[1] as Rect2).has_point(at):
			return [row, entry[0]]
	return []


# --- Data -----------------------------------------------------------------------


func _row_lines(row: int) -> Array[Dictionary]:
	var data: Dictionary = row_data(row)
	var out: Array[Dictionary] = []
	if not side_by_side:
		if not data.is_empty():
			out.append(data)
		return out
	var left: Dictionary = data.get("left", {})
	var right: Dictionary = data.get("right", {})
	if not left.is_empty():
		out.append(left)
	if not right.is_empty() and int(right.get("index", -1)) != int(left.get("index", -2)):
		out.append(right)
	return out


func _get_row_count() -> int:
	return _split_count if side_by_side else _line_count


func _prepare_rows(first: int, count: int) -> void:
	for index: int in range(first, first + count):
		if not _cache.has(index):
			var start: int = maxi(0, first - FETCH_MARGIN)
			_cache.clear()
			_fetch(start, first + count + FETCH_MARGIN - start)
			return


func _fetch(start: int, count: int) -> void:
	var fetch: Callable = split_source if side_by_side else source
	if not fetch.is_valid():
		return
	var rows: Array = fetch.call(start, count)
	var grew: bool = false
	for i: int in rows.size():
		var data: Dictionary = rows[i]
		_cache[start + i] = data
		var length: int = 0
		if side_by_side:
			length = maxi(String(data["left"].get("text", "")).length(), String(data["right"].get("text", "")).length())
		else:
			length = String(data.get("text", "")).length()
		if length * _char_width > _widest:
			_widest = length * _char_width
			grew = true
	if grew:
		_update_h_range.call_deferred()


# --- Drawing --------------------------------------------------------------------


func _draw_row(index: int, rect: Rect2, _selected_row: bool) -> void:
	var data: Dictionary = _cache.get(index, {})
	if data.is_empty():
		return
	if pickable:
		var gutter: float = _pick_width()
		draw_rect(Rect2(rect.position, Vector2(gutter, rect.size.y)), _colors[&"gutter_bg"])
		var state: String = row_pick(index)
		if not state.is_empty():
			_picks.draw(self, _picks.box_rect(rect, rect.position.x + _padding * 0.5), state)
		rect = Rect2(rect.position + Vector2(gutter, 0.0), Vector2(rect.size.x - gutter, rect.size.y))
	if _choice_rows.x >= 0 and index >= _choice_rows.x and index < _choice_rows.x + _choice_rows.y:
		_draw_choice(index, rect)
		return
	_draw_line_row(data, index, rect)


## A row of the diff (after the checkbox gutter).
func _draw_line_row(data: Dictionary, index: int, rect: Rect2) -> void:
	if not side_by_side:
		_draw_side(data, index, 0, rect, 2)
		return
	var left: Dictionary = data["left"]
	var right: Dictionary = data["right"]
	if int(left.get("kind", -1)) in [KIND_HUNK, KIND_BASE]:
		_draw_side(left, index, 0, rect, 1)
		return
	var half: float = floorf(rect.size.x / 2.0)
	_draw_side(left, index, 0, Rect2(rect.position, Vector2(half, rect.size.y)), 1)
	_draw_side(right, index, 1, Rect2(rect.position + Vector2(half, 0.0), Vector2(rect.size.x - half, rect.size.y)), 1)


## A row a block choice just wrote: the row, a fading highlight, and on the
## first one "✓ Used main" and Undo while they show.
func _draw_choice(index: int, rect: Rect2) -> void:
	_draw_line_row(_cache.get(index, {}), index, rect)
	if flash_strength > 0.0:
		var flash: Color = _colors[&"choice_flash"]
		draw_rect(rect, Color(flash, flash.a * flash_strength))
	if index != _choice_rows.x or not choice_undo_shown():
		return
	var button: Rect2 = choice_undo_rect()
	var icon_side: float = _icon_side()
	var font_size: int = _ui_font_size
	var label_width: float = _ui_font.get_string_size(_choice_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var pill: Rect2 = Rect2(button.position.x - label_width - icon_side - _padding * 2.0, button.position.y,
			button.end.x - button.position.x + label_width + icon_side + _padding * 2.0, button.size.y)
	draw_rect(pill.grow(2.0), _colors[&"empty_bg"])
	var baseline: float = rect.position.y + (rect.size.y + _ui_font.get_ascent(font_size) - _ui_font.get_descent(font_size)) / 2.0
	var x: float = pill.position.x + _padding * 0.5
	draw_texture_rect(AppTheme.icon(&"StatusSuccess"), Rect2(x, rect.get_center().y - icon_side / 2.0, icon_side, icon_side),
			false)
	x += icon_side + _padding * 0.5
	draw_string(_ui_font, Vector2(x, baseline), _choice_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, _colors[&"block_header_color"])
	draw_style_box(_button_hover_box if _choice_hover else _button_box, button)
	x = button.position.x + _padding
	draw_texture_rect(AppTheme.icon(&"Undo"), Rect2(x, rect.get_center().y - icon_side / 2.0, icon_side, icon_side), false,
			_colors[&"block_button_color"])
	draw_string(_ui_font, Vector2(x + icon_side + _padding * 0.5, baseline), tr("Undo"), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
			_colors[&"block_button_color"])


## Draws one line of `row` in `rect`: background, number gutter (`columns`
## 2 = old and new numbers; 1 = the side's own number; a header's expanders
## instead), mark (a conflict side's bar) and text.
func _draw_side(data: Dictionary, row: int, side: int, rect: Rect2, columns: int) -> void:
	var gutter: float = _gutter_width(columns)
	if data.is_empty():
		draw_rect(rect, _colors[&"empty_bg"])
		return
	var kind: int = int(data["kind"])
	var conflict_side: String = String(data.get("side", "")) if int(data.get("block", -1)) >= 0 else ""
	var bg: Color = _row_bg(kind, conflict_side)
	if bg.a > 0.0:
		draw_rect(rect, bg)
	var baseline: float = _baseline(rect)
	if kind == KIND_HUNK and int(data.get("block", -1)) >= 0:
		_draw_block_header(data, row, rect)
		return
	if kind == KIND_HUNK:
		var span: Vector2 = _draw_expanders(data, row, rect)
		var text_rect: Rect2 = Rect2(rect.position, Vector2(span.y - rect.position.x, rect.size.y))
		_draw_text(data, kind, row, side, maxf(rect.position.x + gutter, span.x), text_rect, baseline)
		return
	draw_rect(Rect2(rect.position, Vector2(gutter, rect.size.y)), _colors[&"gutter_bg"])
	var x: float = rect.position.x + _padding
	var column: float = _number_digits * _char_width
	var numbers: Array[int] = [int(data["old"]), int(data["new"])]
	if columns == 1:
		numbers = [int(data["old"]) if side == 0 else int(data["new"])]
	for i: int in numbers.size():
		if numbers[i] > 0:
			var text: String = str(numbers[i])
			# Right-aligned by hand: a width limit can drop the last glyph.
			var right: float = x + column * (i + 1) + _char_width * i
			draw_string(_font, Vector2(right - text.length() * _char_width, baseline), text,
					HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, _colors[&"line_number_color"])
	if conflict_side in ["ours", "theirs", "base"]:
		draw_rect(Rect2(rect.position, Vector2(CONFLICT_BAR_WIDTH, rect.size.y)), _colors[StringName(conflict_side + "_mark")])
		_draw_text(data, kind, row, side, rect.position.x + gutter, rect, baseline)
		# Side by side, the column says the side; only the base gets a tag.
		if (conflict_side == "base" or not side_by_side) \
				and String(_side_line(row - 1, side).get("side", "")) != conflict_side:
			_draw_side_tag(conflict_side, rect, bg)
		return
	var mark: String = String({KIND_ADDED: "+", KIND_REMOVED: "-", KIND_BASE: "|"}.get(kind, ""))
	if not mark.is_empty():
		var mark_color: Color = _colors[&"base_mark"]
		if kind == KIND_ADDED:
			mark_color = _colors[&"added_mark"]
		elif kind == KIND_REMOVED:
			mark_color = _colors[&"removed_mark"]
		draw_string(_font, Vector2(x + (column + _char_width) * columns, baseline), mark,
				HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, mark_color)
	_draw_text(data, kind, row, side, rect.position.x + gutter, rect, baseline)


## Draws a header's expander buttons and what they show (right-aligned; on
## the end row, after its icon); returns where the header text can start and
## end.
func _draw_expanders(data: Dictionary, row: int, rect: Rect2) -> Vector2:
	var end: float = rect.position.x
	var label: String = expander_label(row)
	var label_left: float = -1.0
	var any_hovered: bool = false
	for entry: Array in _expander_rects(data, rect.position.x, rect):
		var how: String = entry[0]
		var button: Rect2 = entry[1]
		var hovered: bool = _hover == [row, how]
		any_hovered = any_hovered or hovered
		if hovered:
			draw_rect(button.grow_individual(0.0, -1.0, 0.0, -1.0), _colors[&"expander_hover_bg"])
		var icon: Texture2D = AppTheme.icon(EXPANDER_ICONS[how])
		var side: float = minf(16.0, button.size.y - 4.0)
		var icon_width: float = roundf(button.size.y * EXPANDER_WIDTH)
		var icon_center: Vector2 = Vector2(button.position.x + icon_width / 2.0, button.get_center().y)
		var icon_rect: Rect2 = Rect2(icon_center - Vector2(side, side) / 2.0, Vector2(side, side))
		draw_texture_rect(icon, icon_rect, false,
				_colors[&"expander_hover_color"] if hovered else _colors[&"expander_color"])
		end = button.position.x + icon_width + _padding * 0.5
		if button.size.x > icon_width:
			label_left = end
	if label.is_empty():
		return Vector2(end, rect.end.x)
	var color: Color = _colors[&"expander_hover_color"] if any_hovered else _colors[&"expander_color"]
	var label_width: float = _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x
	var x: float = label_left if label_left >= 0.0 else rect.end.x - label_width - _padding
	if label_left < 0.0 and x < end + _char_width * 20.0:
		return Vector2(end, rect.end.x)
	draw_string(_font, Vector2(x, _baseline(rect)), label, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, color)
	return Vector2(end, x - _padding)


## A conflict header across `rect`: the conflict icon and "Conflict 1 of 3"
## in the UI font, then the block's buttons (each side's with its colour).
func _draw_block_header(data: Dictionary, row: int, rect: Rect2) -> void:
	var icon_side: float = _icon_side()
	var x: float = rect.position.x + _padding
	var icon_rect: Rect2 = Rect2(x, rect.get_center().y - icon_side / 2.0, icon_side, icon_side)
	draw_texture_rect(AppTheme.tintable_icon(&"GitConflict"), icon_rect, false, _colors[&"block_icon_color"])
	x += icon_side + _padding * 0.5
	var baseline: float = rect.position.y \
			+ (rect.size.y + _ui_font.get_ascent(_ui_font_size) - _ui_font.get_descent(_ui_font_size)) / 2.0
	var buttons: Array = _block_rects(rect)
	var limit: float = (buttons[0][1] as Rect2).position.x - _padding
	var title: String = tr("Conflict %d of %d") % [int(data["block"]) + 1, block_count] if block_count > 0 \
			else String(data.get("text", ""))
	draw_string(_ui_font, Vector2(x, baseline), title, HORIZONTAL_ALIGNMENT_LEFT,
			maxf(0.0, limit - x), _ui_font_size, _colors[&"block_header_color"])
	if caret_shown() and row == _sel_to.x:
		draw_rect(Rect2(rect.position + Vector2(0.0, 1.0), Vector2(2.0, rect.size.y - 2.0)), _colors[&"caret_color"])
	var color: Color = _colors[&"block_button_color"]
	for entry: Array in buttons:
		var action: String = entry[0]
		var button: Rect2 = entry[1]
		draw_style_box(_button_hover_box if _block_hover == [row, action] else _button_box, button)
		var text_x: float = button.position.x + _padding
		var label: String = entry[2]
		if action == "both":
			draw_string(_ui_font, Vector2(text_x, baseline), label, HORIZONTAL_ALIGNMENT_LEFT, -1, _ui_font_size, color)
			var arrow: Rect2 = Rect2(button.end.x - _padding * 0.75 - icon_side, button.get_center().y - icon_side / 2.0,
					icon_side, icon_side)
			draw_texture_rect(AppTheme.icon(&"ChevronDown"), arrow, false, color)
			continue
		# The swatch goes right before the name, after a leading arrow.
		if label.begins_with(SPLIT_ARROWS[0]):
			draw_string(_ui_font, Vector2(text_x, baseline), SPLIT_ARROWS[0], HORIZONTAL_ALIGNMENT_LEFT, -1,
					_ui_font_size, color)
			text_x += _ui_font.get_string_size(SPLIT_ARROWS[0], HORIZONTAL_ALIGNMENT_LEFT, -1, _ui_font_size).x
			label = label.trim_prefix(SPLIT_ARROWS[0])
		var swatch: float = _swatch_side()
		draw_circle(Vector2(text_x + swatch / 2.0, button.get_center().y), swatch / 2.0, _colors[StringName(action + "_mark")],
				true, -1.0, true)
		text_x += swatch + _padding * 0.5
		draw_string(_ui_font, Vector2(text_x, baseline), label, HORIZONTAL_ALIGNMENT_LEFT, -1, _ui_font_size, color)


## The line's text from `left`, scrolled sideways: changed-word background,
## selection, then syntax-colored segments, clipped to `rect`; the caret.
func _draw_text(data: Dictionary, kind: int, row: int, side: int, left: float, rect: Rect2, baseline: float) -> void:
	var text: String = String(data["text"])
	var length: int = text.length()
	if bool(data.get("no_newline", false)):
		text += NO_NEWLINE_MARK
	var skip: int = int(_h_scroll.value / _char_width) if _char_width > 0.0 and kind != KIND_HUNK else 0
	var right: float = rect.end.x
	var column_x: Callable = func(column: int) -> float: return left + (column - skip) * _char_width
	var spans: Array[Array] = []
	var hl: PackedInt32Array = data.get("hl", PackedInt32Array())
	if hl.size() == 2 and hl[1] > hl[0]:
		spans.append([hl[0], hl[1], _colors[&"added_hl_bg"] if kind == KIND_ADDED else _colors[&"removed_hl_bg"]])
	var selected: Vector2i = _selected_columns(row, side, length)
	if selected.x >= 0:
		spans.append([selected.x, selected.y, _colors[&"selection_bg"]])
	for span: Array in spans:
		var from: float = maxf(column_x.call(maxi(int(span[0]), skip)), left)
		var to: float = minf(column_x.call(int(span[1])), right)
		if to > from:
			draw_rect(Rect2(from, rect.position.y, to - from, rect.size.y), span[2])
	var base: Color = _colors[&"hunk_color"] if kind == KIND_HUNK else _colors[&"text_color"]
	var segments: Array = _segments(text.length(), data.get("syntax", PackedInt32Array()), base)
	for segment: Array in segments:
		var start: int = maxi(int(segment[0]), skip)
		var end: int = int(segment[1])
		if end <= start:
			continue
		var x: float = column_x.call(start)
		if x >= right:
			break
		var chars: int = mini(end - start, int((right - x) / _char_width) + 1)
		draw_string(_font, Vector2(x, baseline), text.substr(start, chars), HORIZONTAL_ALIGNMENT_LEFT, -1,
				_font_size, segment[2])
	if caret_shown() and row == _sel_to.x and side == _sel_side:
		var caret: float = column_x.call(_sel_to.y)
		if caret >= left and caret < right:
			draw_rect(Rect2(caret, rect.position.y + 2.0, 1.0, rect.size.y - 4.0), _colors[&"caret_color"])


## `[start, end, color]` runs covering `length` characters: syntax tokens in
## their colors, the gaps in `base`.
func _segments(length: int, syntax: PackedInt32Array, base: Color) -> Array:
	var out: Array = []
	var at: int = 0
	for i: int in range(0, syntax.size() - 2, 3):
		var start: int = clampi(syntax[i], at, length)
		var end: int = clampi(syntax[i + 1], start, length)
		if start > at:
			out.append([at, start, base])
		var kind: int = syntax[i + 2]
		out.append([start, end, _syntax[kind] if kind >= 0 and kind < _syntax.size() else base])
		at = end
	if at < length:
		out.append([at, length, base])
	return out


## The background of a line of `kind`; a conflict's ours and theirs (`side`)
## have their own.
func _row_bg(kind: int, side: String = "") -> Color:
	if side == "ours" or side == "theirs":
		return _colors[StringName(side + "_bg")]
	match kind:
		KIND_HUNK:
			return _colors[&"block_header_bg"] if side == "header" else _colors[&"hunk_bg"]
		KIND_ADDED:
			return _colors[&"added_bg"]
		KIND_REMOVED:
			return _colors[&"removed_bg"]
		KIND_BASE:
			return _colors[&"base_bg"]
	return Color(0, 0, 0, 0)


# --- Input ----------------------------------------------------------------------


func _gui_input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_C and key.is_command_or_control_pressed():
		copy_selection()
		accept_event()
		return
	if key != null and key.pressed and key.shift_pressed and key.keycode in [KEY_LEFT, KEY_RIGHT] \
			and row_count() > 0:
		var caret: Vector2i = _sel_to if _sel_to.x >= 0 else Vector2i(maxi(cursor, 0), 0)
		var from: Vector2i = _sel_from if _sel_from.x >= 0 else caret
		var to: Vector2i = _step(caret, key.keycode == KEY_RIGHT, key.is_command_or_control_pressed())
		_keyboard_caret = true
		_select_span(from, to)
		scroll_to_row(to.x)
		accept_event()
		return
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null:
		_on_mouse_motion(motion)
		return
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if mouse != null and mouse.button_index == MOUSE_BUTTON_LEFT:
		if mouse.pressed:
			_on_left_press(mouse)
		else:
			_dragging = false
		accept_event()
		return
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT:
		_on_right_press(mouse)
		accept_event()
		return
	if mouse != null and mouse.pressed and mouse.shift_pressed \
			and mouse.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var direction: float = -1.0 if mouse.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
		_h_scroll.value += direction * _char_width * 8.0
		accept_event()
		return
	if mouse != null and mouse.pressed and mouse.button_index in [MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		var direction: float = -1.0 if mouse.button_index == MOUSE_BUTTON_WHEEL_LEFT else 1.0
		_h_scroll.value += direction * _char_width * 8.0
		accept_event()
		return
	super(event)


func _on_left_press(mouse: InputEventMouseButton) -> void:
	grab_focus()
	var at: Vector2 = mouse.position
	var row: int = row_at(at)
	if pickable and at.x < _pick_width() and row >= 0:
		if not row_pick(row).is_empty():
			var lines: PackedInt32Array = PackedInt32Array()
			for data: Dictionary in _row_lines(row):
				lines.append(int(data.get("index", -1)))
			pick_clicked.emit(lines, row_pick(row) != "all")
		return
	var expander: Array = _expander_at(at)
	if not expander.is_empty():
		press_expander(int(expander[0]), String(expander[1]))
		return
	var block_button: Array = _block_at(at)
	if not block_button.is_empty():
		select_only(int(block_button[0]))
		press_block(int(block_button[0]), String(block_button[1]))
		return
	if choice_undo_rect().has_point(at):
		clear_choice()
		undo_choice_requested.emit()
		return
	_keyboard_caret = false
	var now: int = Time.get_ticks_msec()
	var repeated: bool = now - _last_click_msec < MULTI_CLICK_MSEC \
			and at.distance_to(_last_click_at) < MULTI_CLICK_DISTANCE
	_clicks = _clicks % 3 + 1 if repeated else 1
	_last_click_msec = now
	_last_click_at = at
	var extend: bool = mouse.shift_pressed and _sel_to.x >= 0 and _clicks == 1
	if not extend:
		_sel_side = _side_at(at.x)
	var spot: Vector2i = _position_at(at, _sel_side)
	if spot.x < 0:
		return
	_dragging = true
	_drag_mouse = at
	match _clicks:
		2:
			var word: Array[Vector2i] = _word_at(spot)
			_drag_unit = Unit.WORD
			_unit_from = word[0]
			_unit_to = word[1]
			_select_span(word[0], word[1])
		3:
			_drag_unit = Unit.LINE
			_select_lines(spot.x, spot.x)
			_unit_from = _sel_from
			_unit_to = _sel_to
		_:
			_drag_unit = Unit.CHAR
			_select_span(_sel_from if extend else spot, spot)
	_anchor = spot.x


## Right-click outside the selection selects the clicked line, so the menu
## acts on what it shows.
func _on_right_press(mouse: InputEventMouseButton) -> void:
	grab_focus()
	var row: int = row_at(mouse.position)
	if row < 0:
		return
	if context_menu_requested.get_connections().is_empty():
		return
	if not selected_rows().has(row):
		_sel_side = _side_at(mouse.position.x)
		select_only(row)
	context_menu_requested.emit(row, mouse.position)


func _on_mouse_motion(motion: InputEventMouseMotion) -> void:
	if _dragging and (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_drag_mouse = motion.position
		_drag_to(motion.position)
		set_process(true)
		return
	_dragging = false
	var expander: Array = _expander_at(motion.position)
	_set_hover(expander)
	var block_button: Array = _block_at(motion.position)
	if block_button != _block_hover:
		_block_hover = block_button
		if expander.is_empty():
			tooltip_text = _block_tip(String(block_button[1])) if not block_button.is_empty() else ""
		queue_redraw()
	if not block_button.is_empty():
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		return
	var over_undo: bool = choice_undo_rect().has_point(motion.position)
	if over_undo != _choice_hover:
		_choice_hover = over_undo
		tooltip_text = tr("Undo this choice (%s)") % Actions.shortcut_label(&"conflict.undo") if over_undo else ""
		queue_redraw()
	if over_undo:
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		return
	var over_box: bool = pickable and motion.position.x < _pick_width() \
			and row_at(motion.position) >= 0 and not row_pick(row_at(motion.position)).is_empty()
	if not expander.is_empty() or over_box:
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	elif motion.position.x >= _text_left(_side_at(motion.position.x)) and row_at(motion.position) >= 0:
		mouse_default_cursor_shape = Control.CURSOR_IBEAM
	else:
		mouse_default_cursor_shape = Control.CURSOR_ARROW


## The name of a conflict side (`ours`, `theirs`, `base`) at the right of
## `rect`, on its first line, over a pill of the line's background `bg`.
func _draw_side_tag(conflict_side: String, rect: Rect2, bg: Color) -> void:
	var text: String = "base"
	if conflict_side != "base":
		text = side_names[0 if conflict_side == "ours" else 1] if side_names.size() == 2 else conflict_side
	var tag_size: int = _ui_font_size - 2
	var width: float = _ui_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, tag_size).x + _padding
	var pill: Rect2 = Rect2(rect.end.x - width - _padding * 0.5, rect.position.y + 2.0, width, rect.size.y - 4.0)
	draw_rect(pill.grow_individual(_padding * 0.5, 2.0, _padding * 0.5, 2.0), bg if bg.a > 0.0 else _colors[&"empty_bg"])
	var baseline: float = pill.position.y + (pill.size.y + _ui_font.get_ascent(tag_size) - _ui_font.get_descent(tag_size)) / 2.0
	draw_string(_ui_font, Vector2(pill.position.x + _padding * 0.5, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, tag_size,
			_colors[StringName(conflict_side + "_mark")])


## A block button's tooltip: what it keeps and its shortcut.
func _block_tip(action: String) -> String:
	var tip: String = tr(BLOCK_TIPS.get(action, ""))
	if action != "both":
		tip = tip % (side_names[0 if action == "ours" else 1] if side_names.size() == 2 else action)
	var shortcut: String = Actions.shortcut_label(BLOCK_ACTIONS.get(action, &""))
	return tip if shortcut.is_empty() else "%s (%s)" % [tip, shortcut]


func _set_hover(expander: Array) -> void:
	if expander != _hover:
		_hover = expander
		tooltip_text = tr(EXPANDER_TIPS.get(String(expander[1]), "")) if not expander.is_empty() else ""
		queue_redraw()


## Extends the selection to `at`, by the unit the drag started with.
func _drag_to(at: Vector2) -> void:
	var spot: Vector2i = _position_at(at, _sel_side)
	if spot.x < 0:
		return
	var before: bool = spot.x < _unit_from.x or (spot.x == _unit_from.x and spot.y < _unit_from.y)
	var from: Vector2i = _sel_from
	var to: Vector2i = spot
	match _drag_unit:
		Unit.WORD:
			var word: Array[Vector2i] = _word_at(spot)
			from = _unit_to if before else _unit_from
			to = word[0] if before else word[1]
		Unit.LINE:
			from = _unit_to if before else _unit_from
			to = Vector2i(spot.x, 0) if before else Vector2i(spot.x, _line_length(spot.x, _sel_side))
	if from != _sel_from or to != _sel_to:
		_select_span(from, to)


## While dragging past an edge, scrolls towards the mouse and extends the
## selection.
func _process(delta: float) -> void:
	if not _dragging:
		set_process(false)
		return
	var dy: float = 0.0
	if _drag_mouse.y < 0.0:
		dy = _drag_mouse.y
	elif _drag_mouse.y > size.y:
		dy = _drag_mouse.y - size.y
	var dx: float = 0.0
	var span: Vector2 = _side_span(_sel_side)
	if _drag_mouse.x < _text_left(_sel_side) and _h_scroll.value > 0.0:
		dx = _drag_mouse.x - _text_left(_sel_side)
	elif _drag_mouse.x > span.x + span.y:
		dx = _drag_mouse.x - span.x - span.y
	if dy == 0.0 and dx == 0.0:
		set_process(false)
		return
	set_scroll_offset(scroll_offset() + dy * DRAG_SCROLL_RATE * delta)
	_h_scroll.value += dx * DRAG_SCROLL_RATE * delta
	_drag_to(_drag_mouse)


## Arrow keys, Page Up/Down, Home and End: whole lines (Shift extends from
## the line where it started).
func _move_cursor(row: int, extend: bool) -> void:
	_keyboard_caret = true
	if extend and _anchor >= 0:
		_select_lines(_anchor, row)
	else:
		_select_lines(row, row)
		_anchor = row
	scroll_to_row(row)


## Ctrl+A.
func _select_range(from: int, to: int, _keep: bool) -> void:
	_select_lines(from, to)


func _update_h_range() -> void:
	var columns: int = 1 if side_by_side else 2
	var text_width: float = (content_width() - _pick_width()) / (2.0 if side_by_side else 1.0) - _gutter_width(columns)
	var total: float = _widest + _char_width * 4.0
	_h_scroll.max_value = total
	_h_scroll.page = maxf(0.0, text_width)
	_h_scroll.visible = total > text_width and row_count() > 0
	_h_scroll.offset_right = -(_scroll_bar.size.x if _scroll_bar.visible else 0.0)


func _update_theme() -> void:
	_font = get_theme_font(&"font", DIFF_THEME_TYPE)
	_font_size = get_theme_font_size(&"font_size", DIFF_THEME_TYPE)
	_char_width = _font.get_char_size(ord("M"), _font_size).x
	_padding = float(get_theme_constant(&"padding", DIFF_THEME_TYPE))
	for color_name: StringName in [&"text_color", &"line_number_color", &"hunk_color", &"hunk_bg",
			&"added_bg", &"removed_bg", &"added_mark", &"removed_mark", &"gutter_bg", &"empty_bg",
			&"added_hl_bg", &"removed_hl_bg", &"selection_bg", &"caret_color", &"expander_color",
			&"expander_hover_color", &"expander_hover_bg", &"base_bg", &"base_mark", &"ours_bg", &"ours_mark", &"theirs_bg", &"theirs_mark", &"block_button_bg",
			&"block_button_hover_bg", &"block_button_color", &"block_header_bg", &"block_header_color",
			&"block_icon_color", &"choice_flash"]:
		_colors[color_name] = get_theme_color(color_name, DIFF_THEME_TYPE)
	_ui_font = get_theme_font(&"font", &"Label")
	_ui_font_size = get_theme_font_size(&"header_font_size", DIFF_THEME_TYPE)
	for entry: Array in [[_button_box, &"block_button_bg"], [_button_hover_box, &"block_button_hover_bg"]]:
		var box: StyleBoxFlat = entry[0]
		box.bg_color = _colors[entry[1]]
		box.set_corner_radius_all(3)
	_picks.update_theme(self)
	_syntax.clear()
	for color_name: StringName in SYNTAX_COLORS:
		_syntax.append(get_theme_color(color_name, DIFF_THEME_TYPE))
	_update_h_range()
