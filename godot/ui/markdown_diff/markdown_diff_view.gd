class_name MarkdownDiffView
extends ScrollContainer
## A Markdown file drawn as a document with what changed marked on it: the
## diff's Preview mode. Core parses both sides and compares their blocks;
## this view only lays them out. Blocks come from `source` (`RepoSession.
## markdown_blocks` of the panel's slot) in slices and are built within a
## frame budget, so a long document never stalls a frame.
##
## An added block has the added background and a mark down its left edge, a
## removed one the removed background; a changed block has a mark in the
## modified colour, with its removed words struck through on the removed
## background and its added words on the added one (code lines and table
## rows the same). Quotes draw a bar per depth, list items their bullet,
## number or check box in the indent; code blocks are coloured by the
## syntax system (each line by its side's tokens, `convert::markdown_blocks`).
## Pictures in the repository come from `image_source` once core read them
## (`show_blocks`'s `images_ready`), decode on worker threads and replace
## their text; web pictures stay text. `jump_to_change` scrolls to the next
## or previous changed block (F7 / Shift+F7). A link to a web page opens in
## the browser, one to a heading (`#anchor`) scrolls to it, one to a file of
## the repository emits `file_link_clicked`. Its scroll column is a
## `MarkdownStrip` with every changed block marked, placed beside it by
## `attach_strip` (a ScrollContainer lays out all its children).
##
## Core folds the unchanged blocks far from a change into gap rows (`kind`
## `gap`, see `convert::markdown_blocks`): each says how many blocks it
## hides and has buttons (`expand`: `up`, `down`, `both` or `all`) that call
## `expander` with its `gap`. A link to a heading inside a gap opens that gap
## and scrolls there once the rows come back.

## A link to a repository file was clicked: its path and the heading after
## `#` (empty for none).
signal file_link_clicked(path: String, anchor: String)

const THEME_TYPE: StringName = &"MarkdownDiff"
const TEXT_TYPE: StringName = &"MarkdownText"
## Blocks fetched per `source` call.
const SLICE: int = 64
## Microseconds spent building blocks per frame once the first screen is up.
const FRAME_BUDGET_USEC: int = 6000
## Frames a jump keeps the block it went to at the top while the blocks
## above it settle their heights.
const FOLLOW_FRAMES: int = 4
const BULLETS: PackedStringArray = ["•", "◦", "▪"]
## The bits of a span's `style` (`markdown::style` in core).
const STRONG: int = 1
const EMPHASIS: int = 2
const CODE: int = 4
const STRIKE: int = 8
const LINK: int = 16
const IMAGE: int = 32
## Pictures at most this wide (pixels) keep their size; wider ones scale
## with the column.
const SMALL_PICTURE: int = 320
## Decoded pictures kept, by id.
const PICTURE_CACHE: int = 96
## How a block changed, in `change_marks`.
const MARK_ADDED: int = 1
const MARK_REMOVED: int = 2
const MARK_CHANGED: int = 3
## The buttons of a gap row's `expand`, left to right, their icons and tips.
const EXPANDERS: Dictionary[String, Array] = {
	"up": ["up"], "down": ["down"], "both": ["up", "down"], "all": ["all"],
}
const EXPANDER_ICONS: Dictionary[String, StringName] = {
	"up": &"ExpandUp", "down": &"ExpandDown", "all": &"ExpandAll",
}
const EXPANDER_TIPS: Dictionary[String, String] = {
	"up": "More blocks above",
	"down": "More blocks below",
	"all": "All hidden blocks",
}

## `func(start: int, count: int) -> Array` of row dictionaries, blocks and
## gaps (see `convert::markdown_blocks`).
var source: Callable = Callable()
## `func(gap: int, how: String)`: opens part of a gap (`RepoSession.
## expand_markdown`); gap rows have no buttons without it.
var expander: Callable = Callable()
## `func(index: int) -> Dictionary`: picture `index` as `{format, bytes, id}`
## (`RepoSession.markdown_image`), empty while it is read.
var image_source: Callable = Callable()

var _margin: MarginContainer = MarginContainer.new()
var _column: VBoxContainer = VBoxContainer.new()
var _strip: MarkdownStrip = MarkdownStrip.new()
## Every block shown, as fetched; `_built` of them have controls.
var _blocks: Array[Dictionary] = []
var _built: int = 0
## Indices of the changed blocks.
var _changes: PackedInt64Array = PackedInt64Array()
## The block the last jump went to (-1: none), the block kept at the top
## and the frames left following it.
var _current: int = -1
var _follow_block: int = -1
var _follow_frames: int = 0
## A heading the last link pointed to inside a gap: scrolled to once the
## gap opened.
var _pending_anchor: String = ""
## Whether core read the pictures of the blocks shown.
var _images_ready: bool = true
## Picture ids by index, for the blocks shown.
var _ids: Dictionary[int, String] = {}
## Decoded pictures and the ids that failed, by id; decodes in progress.
var _textures: Dictionary[String, Texture2D] = {}
var _failed: Dictionary[String, bool] = {}
var _tasks: Dictionary[String, int] = {}
## The syntax colours by token kind (`AppTheme.syntax_colors`), empty until used.
var _syntax: PackedColorArray = PackedColorArray()


func _init() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# The strip below scrolls instead of the bar.
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	follow_focus = false
	_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_margin)
	_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_column.add_theme_constant_override(&"separation", 0)
	_margin.add_child(_column)
	resized.connect(_fit_width)
	_strip.view = self
	_strip.hide()
	visibility_changed.connect(_show_strip)
	get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _strip.queue_redraw())
	_column.sort_children.connect(_strip.queue_redraw)
	_margin.resized.connect(_strip.queue_redraw)
	set_process(false)


func _exit_tree() -> void:
	# Every task must be waited for; results still queued find none.
	for id: String in _tasks:
		WorkerThreadPool.wait_for_task_completion(_tasks[id])
	_tasks.clear()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and not _blocks.is_empty():
		_drop_controls(0)
		_build_some()
		set_process(_built < _blocks.size() or _follow_frames > 0)
	if what == NOTIFICATION_THEME_CHANGED:
		place_strip()
		# The override below notifies again: only set it when it changes.
		var background: Color = get_theme_color(&"background", THEME_TYPE)
		var current: StyleBoxFlat = get_theme_stylebox(&"panel") as StyleBoxFlat
		if current == null or not has_theme_stylebox_override(&"panel") or current.bg_color != background:
			var box: StyleBoxFlat = StyleBoxFlat.new()
			box.bg_color = background
			add_theme_stylebox_override(&"panel", box)
			return
		_fit_width()
		_syntax = PackedColorArray()
		# Colours and sizes are baked into the blocks: build them again.
		if not _blocks.is_empty():
			_drop_controls(0)
			_build_some()
			set_process(_built < _blocks.size() or _follow_frames > 0)


## Shows `count` blocks from `source`, `changed_blocks` the indices of the
## changed ones. With `keep` (the same file again) the scroll position stays and only
## the blocks from the first one that differs are built again.
## `images_ready`: core read the pictures, so `image_source` has them.
func show_blocks(count: int, changed_blocks: PackedInt64Array, keep: bool, images_ready: bool = true) -> void:
	var data: Array[Dictionary] = []
	while data.size() < count and source.is_valid():
		var slice: Array = source.call(data.size(), mini(SLICE, count - data.size()))
		if slice.is_empty():
			break
		for block: Variant in slice:
			data.append(block as Dictionary)
	_changes = changed_blocks
	var pictures_came: bool = images_ready != _images_ready
	_images_ready = images_ready
	_ids.clear()
	if keep and data == _blocks and not pictures_came:
		return
	var same: int = 0
	if keep:
		var shared: int = mini(mini(data.size(), _blocks.size()), _built)
		while same < shared and data[same] == _blocks[same] \
				and not (pictures_came and not _block_images(data[same]).is_empty()):
			same += 1
	else:
		_current = -1
		_follow_block = -1
		_follow_frames = 0
		_pending_anchor = ""
		scroll_vertical = 0
	_drop_controls(same)
	_blocks = data
	_build_some()
	set_process(_built < _blocks.size() or _follow_frames > 0)
	_show_strip()
	_strip.queue_redraw()
	if not _pending_anchor.is_empty():
		var anchor: String = _pending_anchor
		_pending_anchor = ""
		scroll_to_anchor(anchor)


## Removes every block.
func clear() -> void:
	_drop_controls(0)
	_blocks.clear()
	_changes = PackedInt64Array()
	_current = -1
	_follow_block = -1
	_follow_frames = 0
	_pending_anchor = ""
	_ids.clear()
	_show_strip()
	set_process(false)


func block_count() -> int:
	return _blocks.size()


## How many blocks have controls yet (tests).
func built_count() -> int:
	return _built


## The control of block `index` once built, else null (tests).
func block_control(index: int) -> Control:
	return _column.get_child(index) as Control if index < _built else null


## The indices of the changed blocks.
func changes() -> PackedInt64Array:
	return _changes


## The block the last jump went to, or -1.
func current_change() -> int:
	return _current


## The scroll column with the change marks.
func scroll_strip() -> MarkdownStrip:
	return _strip


## The document's height in pixels, margins included.
func content_height() -> float:
	return _margin.size.y


## Where the changed blocks built so far are: a `(top, bottom, kind)` triple
## per block, in pixels from the document's top, `kind` a MARK_ constant.
func change_marks() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	for index: int in _changes:
		var control: Control = block_control(index)
		if control == null:
			break
		var kind: int = MARK_CHANGED
		match String(_blocks[index].get("change", "")):
			"added":
				kind = MARK_ADDED
			"removed":
				kind = MARK_REMOVED
		var top: float = _block_top(index)
		out.append_array([top, top + control.size.y, float(kind)])
	return out


## How many pictures block `index` draws (tests).
func block_picture_count(index: int) -> int:
	var control: Control = block_control(index)
	if control == null:
		return 0
	var count: int = 0
	for label: Node in control.find_children("*", "RichTextLabel", true, false):
		count += int(label.get_meta(&"pictures", 0))
	return count


## Scrolls to the heading whose anchor is `anchor` (as GitHub makes them);
## one inside a gap opens the gap first. Returns whether there is one.
func scroll_to_anchor(anchor: String) -> bool:
	if anchor.is_empty():
		return false
	for index: int in _blocks.size():
		var row: Dictionary = _blocks[index]
		if String(row.get("anchor", "")) == anchor and String(row.get("kind", "")) != "gap":
			_build_until(index)
			_follow_block = index
			_follow_frames = FOLLOW_FRAMES
			_follow()
			set_process(true)
			return true
	for row: Dictionary in _blocks:
		if String(row.get("kind", "")) != "gap" or not expander.is_valid():
			continue
		var anchors: PackedStringArray = row.get("anchors", PackedStringArray())
		if anchor in anchors:
			_pending_anchor = anchor
			expander.call(int(row.get("gap", -1)), "all")
			return true
	return false


## The gap rows' indices (tests).
func gap_rows() -> PackedInt64Array:
	var out: PackedInt64Array = PackedInt64Array()
	for index: int in _blocks.size():
		if String(_blocks[index].get("kind", "")) == "gap":
			out.append(index)
	return out


## Clicks expander `how` of gap row `index`, as the mouse would. Returns
## whether the row has it.
func press_expander(index: int, how: String) -> bool:
	if index < 0 or index >= _blocks.size() or not expander.is_valid():
		return false
	var row: Dictionary = _blocks[index]
	if String(row.get("kind", "")) != "gap" or not how in EXPANDERS.get(String(row.get("expand", "")), []):
		return false
	expander.call(int(row.get("gap", -1)), how)
	return true


## What gap row `index` says: how many blocks it hides ("" for a block).
func gap_label(index: int) -> String:
	if index < 0 or index >= _blocks.size() or String(_blocks[index].get("kind", "")) != "gap":
		return ""
	return _hidden_text(int(_blocks[index].get("hidden", 0)))


func _hidden_text(count: int) -> String:
	return tr("1 block hidden") if count == 1 else tr("%d blocks hidden") % count


## The text of block `index` as shown, changed words included (tests).
func block_text(index: int) -> String:
	var control: Control = block_control(index)
	if control == null:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for label: Node in control.find_children("*", "RichTextLabel", true, false):
		parts.append((label as RichTextLabel).get_parsed_text())
	return "\n".join(parts)


## Scrolls to the next (`forward`) or previous changed block, wrapping.
func jump_to_change(forward: bool) -> void:
	if _changes.is_empty():
		return
	_build_until(int(_changes[_changes.size() - 1]))
	var top: float = float(scroll_vertical)
	var pick: int = -1
	if forward:
		for index: int in _changes:
			if index != _current and _block_top(index) > top + 1.0:
				pick = index
				break
		if pick < 0:
			pick = int(_changes[0])
	else:
		for i: int in range(_changes.size() - 1, -1, -1):
			var index: int = int(_changes[i])
			if index != _current and _block_top(index) < top - 1.0:
				pick = index
				break
		if pick < 0:
			pick = int(_changes[_changes.size() - 1])
	_current = pick
	_follow_block = pick
	_follow_frames = FOLLOW_FRAMES
	_follow()
	set_process(true)


func _process(_delta: float) -> void:
	if _follow_frames > 0:
		_follow_frames -= 1
		_follow()
	if _built < _blocks.size():
		_build_some()
	set_process(_built < _blocks.size() or _follow_frames > 0)


## Keeps the block the last jump went to near the top.
func _follow() -> void:
	if _follow_block >= 0 and _follow_block < _built:
		var gap: float = float(get_theme_constant(&"gap", THEME_TYPE))
		scroll_vertical = maxi(0, int(_block_top(_follow_block) - gap * 2.0))


## Where block `index` starts, in pixels from the document's top.
func _block_top(index: int) -> float:
	var control: Control = block_control(index)
	return _column.position.y + control.position.y if control != null else INF


## Adds the scroll strip beside this view, down its parent's right edge,
## and leaves it room. Call once the view is in its (non-container) parent.
func attach_strip() -> void:
	add_sibling(_strip)
	_strip.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	place_strip()
	_show_strip()


func place_strip() -> void:
	if _strip.get_parent() == null:
		return
	var width: float = _strip.strip_width()
	_strip.offset_left = -width
	_strip.offset_right = 0.0
	offset_right = -width


func _show_strip() -> void:
	_strip.visible = visible and not _blocks.is_empty()


## Centres the column at its widest, with the margin on each side.
func _fit_width() -> void:
	var margin: int = get_theme_constant(&"margin", THEME_TYPE)
	var widest: int = get_theme_constant(&"max_width", THEME_TYPE)
	var side: int = maxi(margin, int((size.x - float(widest)) / 2.0))
	_margin.add_theme_constant_override(&"margin_left", side)
	_margin.add_theme_constant_override(&"margin_right", side)
	_margin.add_theme_constant_override(&"margin_top", margin)
	_margin.add_theme_constant_override(&"margin_bottom", margin)


func _drop_controls(from: int) -> void:
	var children: Array[Node] = _column.get_children()
	for i: int in range(from, children.size()):
		_column.remove_child(children[i])
		children[i].queue_free()
	_built = mini(_built, from)


## Builds blocks until the frame's budget is spent.
func _build_some() -> void:
	var until: int = Time.get_ticks_usec() + FRAME_BUDGET_USEC
	while _built < _blocks.size():
		_column.add_child(_make_block(_blocks[_built]))
		_built += 1
		if Time.get_ticks_usec() > until:
			break


func _build_until(index: int) -> void:
	while _built <= index and _built < _blocks.size():
		_column.add_child(_make_block(_blocks[_built]))
		_built += 1


func _diff_color(color_name: StringName) -> Color:
	return get_theme_color(color_name, DiffView.DIFF_THEME_TYPE)


## The block's background and its mark of how it changed down the left edge.
func _block_box(change: String, top: float, bottom: float) -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	var mark: int = get_theme_constant(&"mark_width", THEME_TYPE)
	box.border_width_left = mark
	match change:
		"added":
			box.bg_color = _diff_color(&"added_bg")
			box.border_color = _diff_color(&"added_mark")
		"removed":
			box.bg_color = _diff_color(&"removed_bg")
			box.border_color = _diff_color(&"removed_mark")
		"changed":
			box.bg_color = Color.TRANSPARENT
			box.border_color = get_theme_color(&"changed_mark", THEME_TYPE)
		_:
			box.bg_color = Color.TRANSPARENT
			box.border_color = Color.TRANSPARENT
	box.content_margin_left = float(mark + 10)
	box.content_margin_right = 10.0
	box.content_margin_top = top
	box.content_margin_bottom = bottom
	return box


func _make_block(block: Dictionary) -> Control:
	var kind: String = String(block.get("kind", "paragraph"))
	if kind == "gap":
		return _make_gap(block)
	var level: int = int(block.get("level", 0))
	var quote: int = int(block.get("quote", 0))
	var indent: int = int(block.get("indent", 0))
	var gap: float = float(get_theme_constant(&"gap", THEME_TYPE))
	var top: float = gap / 2.0
	if kind == "heading" and level <= 3:
		top += gap
	var panel: PanelContainer = PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var box: StyleBoxFlat = _block_box(String(block.get("change", "same")), top, gap / 2.0)
	panel.add_theme_stylebox_override(&"panel", box)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 0)
	panel.add_child(row)
	var quote_width: int = get_theme_constant(&"quote_width", THEME_TYPE)
	var indent_width: int = get_theme_constant(&"indent", THEME_TYPE)
	var gutter_width: int = quote * quote_width + indent * indent_width
	if gutter_width > 0:
		var gutter: Control = Control.new()
		gutter.mouse_filter = Control.MOUSE_FILTER_IGNORE
		gutter.custom_minimum_size.x = float(gutter_width)
		row.add_child(gutter)
		var marker: Control = _make_marker(block, indent_width)
		if marker != null:
			marker.position.x = float(quote * quote_width + (indent - 1) * indent_width)
			gutter.add_child(marker)
	var content: Control = _make_content(block, kind, level)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(content)
	var underline: bool = kind == "heading" and level <= 2
	if quote > 0 or underline:
		panel.draw.connect(_draw_block_marks.bind(panel, quote, underline, box))
	return panel


## A gap row: its expander buttons and how many blocks it hides, on the
## text diff's hunk header background.
func _make_gap(row: Dictionary) -> Control:
	var half: int = roundi(float(get_theme_constant(&"gap", THEME_TYPE)) / 2.0)
	var wrapper: MarginContainer = MarginContainer.new()
	wrapper.mouse_filter = Control.MOUSE_FILTER_PASS
	wrapper.add_theme_constant_override(&"margin_top", half)
	wrapper.add_theme_constant_override(&"margin_bottom", half)
	var panel: PanelContainer = PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = _diff_color(&"hunk_bg")
	box.set_corner_radius_all(4)
	box.content_margin_left = 4.0
	box.content_margin_right = 10.0
	box.content_margin_top = 2.0
	box.content_margin_bottom = 2.0
	panel.add_theme_stylebox_override(&"panel", box)
	wrapper.add_child(panel)
	var line: HBoxContainer = HBoxContainer.new()
	line.add_theme_constant_override(&"separation", 2)
	panel.add_child(line)
	var gap_index: int = int(row.get("gap", -1))
	if expander.is_valid():
		for how: String in EXPANDERS.get(String(row.get("expand", "")), []):
			var button: Button = Button.new()
			button.theme_type_variation = &"DetailsIconButton"
			button.icon = AppTheme.icon(EXPANDER_ICONS[how])
			button.focus_mode = Control.FOCUS_NONE
			button.tooltip_text = tr(EXPANDER_TIPS[how])
			button.pressed.connect(func() -> void: expander.call(gap_index, how))
			line.add_child(button)
	var label: Label = Label.new()
	label.text = _hidden_text(int(row.get("hidden", 0)))
	label.add_theme_color_override(&"font_color", _diff_color(&"hunk_color"))
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(label)
	return wrapper


## A quote's bars down the whole block (so a quote's blocks join up) and the
## line under a large heading.
func _draw_block_marks(panel: PanelContainer, quote: int, underline: bool, box: StyleBoxFlat) -> void:
	var quote_width: float = float(get_theme_constant(&"quote_width", THEME_TYPE))
	var color: Color = get_theme_color(&"quote_bar", THEME_TYPE)
	for q: int in quote:
		var x: float = box.content_margin_left + float(q) * quote_width
		panel.draw_rect(Rect2(x, 0.0, 3.0, panel.size.y), color)
	if underline:
		var y: float = panel.size.y - box.content_margin_bottom + 2.0
		var left: float = box.content_margin_left
		panel.draw_line(Vector2(left, y), Vector2(panel.size.x - box.content_margin_right, y),
				get_theme_color(&"rule_color", THEME_TYPE), 1.0)


## A list item's bullet, number or check box, right-aligned in its indent.
func _make_marker(block: Dictionary, width: int) -> Control:
	var marker: String = String(block.get("marker", ""))
	if marker.is_empty():
		return null
	if marker == "task":
		var check: TextureRect = TextureRect.new()
		check.texture = get_theme_icon(&"checked" if bool(block.get("checked", false)) else &"unchecked", &"CheckBox")
		check.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		check.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var line: float = _line_height()
		check.size = Vector2(float(width) - 4.0, line)
		return check
	var label: Label = Label.new()
	label.text = "%d." % int(block.get("number", 0)) if marker == "ordered" \
			else BULLETS[(maxi(int(block.get("indent", 1)), 1) - 1) % BULLETS.size()]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.add_theme_color_override(&"font_color", get_theme_color(&"muted_color", THEME_TYPE))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size = Vector2(float(width) - 6.0, _line_height())
	return label


func _line_height() -> float:
	var font: Font = get_theme_font(&"normal_font", TEXT_TYPE)
	return font.get_height(get_theme_font_size(&"normal_font_size", TEXT_TYPE))


func _make_content(block: Dictionary, kind: String, level: int) -> Control:
	match kind:
		"code":
			return _make_code(block)
		"table":
			return _make_table(block)
		"rule":
			var rule: Control = Control.new()
			rule.custom_minimum_size.y = float(get_theme_constant(&"gap", THEME_TYPE)) + 2.0
			rule.draw.connect(func() -> void:
				var y: float = roundf(rule.size.y / 2.0)
				rule.draw_rect(Rect2(0.0, y - 1.0, rule.size.x, 2.0), get_theme_color(&"rule_color", THEME_TYPE)))
			return rule
	var label: RichTextLabel = _rich()
	var spans: Array = block.get("spans", [])
	if kind == "heading":
		label.push_font_size(get_theme_font_size(StringName("h%d_font_size" % clampi(level, 1, 6)), THEME_TYPE))
		label.push_bold()
		_add_spans(label, spans, true)
		label.pop()
		label.pop()
	else:
		_add_spans(label, spans, false)
	return label


func _rich() -> RichTextLabel:
	var label: RichTextLabel = RichTextLabel.new()
	label.theme_type_variation = TEXT_TYPE
	label.bbcode_enabled = false
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.selection_enabled = true
	label.context_menu_enabled = true
	label.meta_clicked.connect(_on_meta_clicked)
	return label


## Adds `spans` (`{text, style, link, change, target, path, anchor,
## image}`) to `label`; in a heading (`bold`) strong text is already bold.
func _add_spans(label: RichTextLabel, spans: Array, bold: bool) -> void:
	for value: Variant in spans:
		var span: Dictionary = value as Dictionary
		var style: int = int(span.get("style", 0))
		var change: String = String(span.get("change", "same"))
		var text: String = String(span.get("text", ""))
		var pushed: int = 0
		if change == "added":
			label.push_bgcolor(_diff_color(&"added_hl_bg"))
			pushed += 1
		elif change == "removed":
			label.push_bgcolor(_diff_color(&"removed_hl_bg"))
			label.push_strikethrough(get_theme_color(&"default_color", TEXT_TYPE))
			pushed += 2
		if style & CODE != 0:
			label.push_mono()
			pushed += 1
			if change == "same":
				label.push_bgcolor(get_theme_color(&"code_bg", THEME_TYPE))
				pushed += 1
		elif style & STRONG != 0 and style & EMPHASIS != 0 and not bold:
			label.push_bold_italics()
			pushed += 1
		elif style & STRONG != 0 and not bold:
			label.push_bold()
			pushed += 1
		elif style & EMPHASIS != 0:
			label.push_italics()
			pushed += 1
		if style & STRIKE != 0:
			label.push_strikethrough(get_theme_color(&"default_color", TEXT_TYPE))
			pushed += 1
		var link: String = String(span.get("link", ""))
		if style & (LINK | IMAGE) != 0 and not link.is_empty():
			var meta: Dictionary = {
				"link": link,
				"target": String(span.get("target", "")),
				"path": String(span.get("path", "")),
				"anchor": String(span.get("anchor", "")),
			}
			label.push_meta(meta, RichTextLabel.META_UNDERLINE_ON_HOVER, link)
			pushed += 1
		var picture: Texture2D = _picture(int(span.get("image", -1))) if style & IMAGE != 0 else null
		if picture != null:
			_add_picture(label, picture, change, text if not text.is_empty() else link)
		else:
			if style & (LINK | IMAGE) != 0:
				label.push_color(get_theme_color(&"link_color" if style & LINK != 0 else &"muted_color", THEME_TYPE))
				pushed += 1
			if style & IMAGE != 0:
				label.push_italics()
				pushed += 1
				text = "[%s]" % text
			label.add_text(text)
		for i: int in pushed:
			label.pop()


## Draws `picture` at its size, or scaled with the column when wider than
## SMALL_PICTURE; a removed one faded.
func _add_picture(label: RichTextLabel, picture: Texture2D, change: String, tooltip: String) -> void:
	label.set_meta(&"pictures", int(label.get_meta(&"pictures", 0)) + 1)
	var tint: Color = Color(1.0, 1.0, 1.0, 0.5) if change == "removed" else Color.WHITE
	var width: int = picture.get_width()
	if width <= SMALL_PICTURE:
		label.add_image(picture, width, 0, tint, INLINE_ALIGNMENT_CENTER, Rect2(), null, false, tooltip)
		return
	var column: float = float(get_theme_constant(&"max_width", THEME_TYPE))
	var percent: int = clampi(roundi(float(width) / column * 100.0), 1, 100)
	label.add_image(picture, percent, 0, tint, INLINE_ALIGNMENT_CENTER, Rect2(), null, false, tooltip,
			RichTextLabel.IMAGE_UNIT_PERCENT)


## The decoded picture `index`, or null: not read yet, failed, or decoding
## (its block is built again once it is).
func _picture(index: int) -> Texture2D:
	if index < 0 or not _images_ready or not image_source.is_valid():
		return null
	var id: String = _ids.get(index, "")
	if id.is_empty():
		var data: Dictionary = image_source.call(index)
		id = String(data.get("id", ""))
		if id.is_empty():
			return null
		_ids[index] = id
		if not _textures.has(id) and not _failed.has(id) and not _tasks.has(id):
			var bytes: PackedByteArray = data.get("bytes", PackedByteArray())
			_tasks[id] = WorkerThreadPool.add_task(
					_decode_task.bind(id, bytes, String(data.get("format", ""))), false, "Decode picture")
	return _textures.get(id, null)


## On a worker thread: the picture of `bytes`.
func _decode_task(id: String, bytes: PackedByteArray, format: String) -> void:
	_decoded.call_deferred(id, ImageDiffView.decode(bytes, format))


func _decoded(id: String, image: Image) -> void:
	if _tasks.has(id):
		WorkerThreadPool.wait_for_task_completion(_tasks[id])
		_tasks.erase(id)
	if image == null:
		_failed[id] = true
		return
	_textures[id] = ImageTexture.create_from_image(image)
	while _textures.size() > PICTURE_CACHE:
		_textures.erase(_textures.keys()[0])
	for index: int in _built:
		for picture: int in _block_images(_blocks[index]):
			if _ids.get(picture, "") == id:
				_rebuild(index)
				break


## The picture indices `block`'s spans draw.
func _block_images(block: Dictionary) -> PackedInt64Array:
	var out: PackedInt64Array = PackedInt64Array()
	var groups: Array = [block.get("spans", [])]
	for row: Variant in block.get("rows", []):
		groups.append_array((row as Dictionary).get("cells", []))
	for spans: Variant in groups:
		for span: Variant in spans:
			var picture: int = int((span as Dictionary).get("image", -1))
			if picture >= 0:
				out.append(picture)
	return out


## Builds block `index` again in place.
func _rebuild(index: int) -> void:
	var old: Node = _column.get_child(index)
	var fresh: Control = _make_block(_blocks[index])
	_column.add_child(fresh)
	_column.move_child(fresh, index)
	_column.remove_child(old)
	old.queue_free()


## The colours of the syntax token kinds, readable on `background`.
func _code_palette(background: Color) -> PackedColorArray:
	if _syntax.is_empty():
		_syntax = AppTheme.syntax_colors(self, DiffView.DIFF_THEME_TYPE, Color.TRANSPARENT)
	return AppTheme.readable_colors(_syntax, background)


## Adds a code line's `text` coloured by its `syntax` triples (start, end,
## kind id).
func _add_code_line(label: RichTextLabel, text: String, syntax: PackedInt32Array, palette: PackedColorArray) -> void:
	var at: int = 0
	var i: int = 0
	while i + 2 < syntax.size():
		var start: int = clampi(syntax[i], at, text.length())
		var end: int = clampi(syntax[i + 1], start, text.length())
		var kind: int = syntax[i + 2]
		i += 3
		if start > at:
			label.add_text(text.substr(at, start - at))
		if end > start:
			var color: Color = palette[kind] if kind >= 0 and kind < palette.size() else Color.TRANSPARENT
			if color.a > 0.0:
				label.push_color(color)
				label.add_text(text.substr(start, end - start))
				label.pop()
			else:
				label.add_text(text.substr(start, end - start))
		at = end
	if at < text.length():
		label.add_text(text.substr(at))


func _make_code(block: Dictionary) -> Control:
	var frame: PanelContainer = PanelContainer.new()
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = get_theme_color(&"code_bg", THEME_TYPE)
	box.set_corner_radius_all(4)
	box.set_content_margin_all(float(get_theme_constant(&"code_padding", THEME_TYPE)))
	frame.add_theme_stylebox_override(&"panel", box)
	var label: RichTextLabel = _rich()
	label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	label.push_mono()
	label.push_font_size(get_theme_font_size(&"code_font_size", THEME_TYPE))
	var lines: Array = block.get("lines", [])
	var plain: PackedColorArray = _code_palette(box.bg_color)
	var on_added: PackedColorArray = _code_palette(box.bg_color.blend(_diff_color(&"added_hl_bg")))
	var on_removed: PackedColorArray = _code_palette(box.bg_color.blend(_diff_color(&"removed_hl_bg")))
	for i: int in lines.size():
		var line: Dictionary = lines[i] as Dictionary
		var text: String = String(line.get("text", ""))
		var change: String = String(line.get("change", "same"))
		var syntax: PackedInt32Array = line.get("syntax", PackedInt32Array())
		if i > 0:
			label.add_text("\n")
		if change == "same":
			_add_code_line(label, text, syntax, plain)
		else:
			var added: bool = change == "added"
			label.push_bgcolor(_diff_color(&"added_hl_bg" if added else &"removed_hl_bg"))
			if text.is_empty():
				label.add_text(" ")
			else:
				_add_code_line(label, text, syntax, on_added if added else on_removed)
			label.pop()
	label.pop()
	label.pop()
	frame.add_child(label)
	return frame


func _make_table(block: Dictionary) -> Control:
	var label: RichTextLabel = _rich()
	var aligns: PackedStringArray = block.get("aligns", PackedStringArray())
	var rows: Array = block.get("rows", [])
	var columns: int = maxi(aligns.size(), 1)
	label.push_table(columns)
	var border: Color = get_theme_color(&"table_border", THEME_TYPE)
	for r: int in rows.size():
		var row: Dictionary = rows[r] as Dictionary
		var change: String = String(row.get("change", "same"))
		var background: Color = Color.TRANSPARENT
		match change:
			"added":
				background = _diff_color(&"added_bg")
			"removed":
				background = _diff_color(&"removed_bg")
			_:
				if r == 0:
					background = get_theme_color(&"table_header_bg", THEME_TYPE)
		var cells: Array = row.get("cells", [])
		for c: int in columns:
			label.push_cell()
			label.set_cell_border_color(border)
			label.set_cell_padding(Rect2(8.0, 4.0, 8.0, 4.0))
			label.set_cell_row_background_color(background, background)
			var align: String = aligns[c] if c < aligns.size() else ""
			label.push_paragraph(HORIZONTAL_ALIGNMENT_CENTER if align == "center"
					else HORIZONTAL_ALIGNMENT_RIGHT if align == "right" else HORIZONTAL_ALIGNMENT_LEFT)
			if r == 0:
				label.push_bold()
			var spans: Array = cells[c] if c < cells.size() else []
			_add_spans(label, spans, r == 0)
			if r == 0:
				label.pop()
			label.pop()
			label.pop()
	label.pop()
	return label


func _on_meta_clicked(meta: Variant) -> void:
	var data: Dictionary = meta as Dictionary if meta is Dictionary else {"link": String(meta), "target": "web"}
	var link: String = String(data.get("link", ""))
	match String(data.get("target", "")):
		"web":
			if link.begins_with("http://") or link.begins_with("https://") or link.begins_with("mailto:"):
				OS.shell_open(link)
		"anchor":
			scroll_to_anchor(String(data.get("anchor", "")))
		"file":
			file_link_clicked.emit(String(data.get("path", "")), String(data.get("anchor", "")))
