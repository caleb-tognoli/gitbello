class_name DiffPanel
extends VBoxContainer
## A file diff with its header (status icon, path, notes, +/− counts,
## whole file, unified or side by side) and the messages shown instead of lines
## (loading, binary, too large, no changes, errors). The path reads like the
## file lists': its folder muted, a renamed file `docs/old.md → new.md`.
## Callers pass `RepoSession.diff_info()`-style dictionaries to `show_info`.
## A conflicted file (`content` `conflict`) shows its conflict blocks with a
## bar in the header (the sides' colours and names from `side_names`, the
## block at the cursor with previous / next, Show base, Open in editor), or a
## card with the choices of a conflict without blocks (`card_action`).
## Every panel is in the `diff_panels` group so the layout can change
## everywhere at once.

const GROUP: StringName = &"diff_panels"
const BASE_TIP: String = "Show the base: the lines both sides started from"
## What an empty diff says, by status code.
const EMPTY_MESSAGES: Dictionary[String, String] = {
	"A": "New empty file.",
	"D": "Deleted an empty file.",
	"R": "Renamed without changes.",
	"C": "Copied without changes.",
}

## The user asked to load a diff past the size limit.
signal load_full_requested()
## The user asked for more of gap `gap` (`up`, `down` or `all`).
signal expand_requested(gap: int, how: String)
## The user asked for the whole file (`true`) or only the changes.
signal whole_file_requested(whole: bool)
## The user toggled Show base of a conflicted file.
signal base_requested(show: bool)
## A conflict card's button: `ours`, `theirs`, `keep`, `delete` or `recreate`.
signal card_action(id: String)
## The previous or next conflict block was asked for.
signal conflict_step_requested(forward: bool)
## The conflicted file was asked to open in the editor.
signal open_file_requested()

@onready var _status_icon: TextureRect = %StatusIcon
@onready var _path: RichTextLabel = %DiffPath
@onready var _stats: Label = %DiffStats
@onready var _counts: Control = %Counts
@onready var _added: Label = %DiffAdded
@onready var _removed: Label = %DiffRemoved
@onready var _layout_gap: Control = %LayoutGap
@onready var _view: DiffView = %DiffView
@onready var _message: Control = %DiffMessage
@onready var _message_label: Label = %DiffMessageLabel
@onready var _load_anyway: Button = %LoadAnywayButton
@onready var _unified_button: Button = %UnifiedButton
@onready var _split_button: Button = %SplitButton
@onready var _whole_button: Button = %WholeFileButton

## `kind:path` of the diff shown, to keep the scroll position on reloads.
var _shown: String = ""
var _placeholder: String = ""
## Status code of the diff shown ("A", "M", ...), or "".
var _code: String = ""
## `[path, original_path, similarity]` of the header, redrawn on theme changes.
var _path_shown: Array = ["", "", -1]
var _base_button: Button = Button.new()
## A conflict without blocks: an icon over the message, the sides' sizes for a
## binary file, and buttons named after the sides.
var _card: HBoxContainer = HBoxContainer.new()
var _card_icon: TextureRect = TextureRect.new()
var _card_table: GridContainer = GridContainer.new()
## The resolver's part of the header: the sides' legend, the block at the
## cursor between previous and next, and Open in editor.
var _conflict_bar: HBoxContainer = HBoxContainer.new()
var _legend: Array[Label] = []
var _block_position: Label = Label.new()
var _open_button: Button = Button.new()
var _columns: Control = Control.new()
## Conflict blocks of the file shown (0 when it is no conflict).
var _blocks: int = 0
var _info: Dictionary = {}


func _ready() -> void:
	add_to_group(GROUP)
	_load_anyway.pressed.connect(func() -> void: load_full_requested.emit())
	var group: ButtonGroup = ButtonGroup.new()
	for entry: Array in [[_unified_button, &"Panels1", false, "Unified", "Old and new lines in one column"],
			[_split_button, &"Panels2Alt", true, "Side by side", "Old lines on the left, new lines on the right"]]:
		var button: Button = entry[0]
		button.icon = AppTheme.icon(entry[1])
		button.button_group = group
		button.set_meta(&"title", entry[3])
		button.set_meta(&"description", entry[4])
		button.pressed.connect(func() -> void:
			if bool(entry[2]) != _view.side_by_side:
				Actions.run_action(&"diff.toggle_side_by_side"))
	_update_layout_tooltips()
	set_side_by_side(Core.diff_side_by_side())
	_view.expand_requested.connect(func(gap: int, how: String) -> void: expand_requested.emit(gap, how))
	_whole_button.icon = AppTheme.icon(&"ExpandAll")
	_whole_button.toggled.connect(func(on: bool) -> void: whole_file_requested.emit(on))
	_base_button.text = "Base"
	_base_button.icon = AppTheme.icon(&"GitCommit")
	_base_button.toggle_mode = true
	_base_button.focus_mode = Control.FOCUS_NONE
	_base_button.theme_type_variation = &"IconToggle"
	_base_button.tooltip_text = BASE_TIP
	_base_button.toggled.connect(func(on: bool) -> void: base_requested.emit(on))
	_base_button.hide()
	_whole_button.add_sibling(_base_button)
	_build_conflict_bar()
	_card.alignment = BoxContainer.ALIGNMENT_CENTER
	_load_anyway.add_sibling(_card)
	_card.hide()
	_card_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_card_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_card_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_card_icon.hide()
	_message_label.add_sibling(_card_icon)
	_message_label.get_parent().move_child(_card_icon, _message_label.get_index())
	_card_table.columns = 3
	_card_table.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_card_table.theme_type_variation = &"ConflictCardTable"
	_card_table.hide()
	_message_label.add_sibling(_card_table)
	_apply_theme()


func _build_conflict_bar() -> void:
	_conflict_bar.theme_type_variation = &"DiffHeaderRow"
	for i: int in 2:
		var legend: Label = Label.new()
		legend.theme_type_variation = &"DimLabel"
		_legend.append(legend)
		var swatch: TextureRect = TextureRect.new()
		swatch.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		swatch.name = "Swatch"
		var pair: HBoxContainer = HBoxContainer.new()
		pair.theme_type_variation = &"StatRow"
		pair.add_child(swatch)
		pair.add_child(legend)
		_conflict_bar.add_child(pair)
	var gap: Control = Control.new()
	gap.custom_minimum_size.x = 8.0
	_conflict_bar.add_child(gap)
	for entry: Array in [[&"conflict.previous", false], [&"conflict.next", true]]:
		var button: Button = Button.new()
		button.theme_type_variation = &"IconToggle"
		button.focus_mode = Control.FOCUS_NONE
		button.icon = Actions.icon(entry[0])
		var action: ActionRegistry.Action = Actions.get_action(entry[0])
		var shortcut: String = Actions.shortcut_label(entry[0])
		button.tooltip_text = action.label if shortcut.is_empty() else "%s (%s)" % [action.label, shortcut]
		var forward: bool = entry[1]
		button.pressed.connect(func() -> void: conflict_step_requested.emit(forward))
		if forward:
			_block_position.theme_type_variation = &"DimLabel"
			_block_position.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_conflict_bar.add_child(_block_position)
		_conflict_bar.add_child(button)
	_conflict_bar.hide()
	_stats.add_sibling(_conflict_bar)
	_open_button.theme_type_variation = &"IconToggle"
	_open_button.focus_mode = Control.FOCUS_NONE
	_open_button.icon = AppTheme.icon(&"ExternalLink")
	_open_button.tooltip_text = "Open in editor to edit by hand"
	_open_button.pressed.connect(func() -> void: open_file_requested.emit())
	_open_button.hide()
	_base_button.add_sibling(_open_button)
	_view.selection_changed.connect(_update_block_position)
	# Side by side, each column's side above it, pinned while the lines scroll.
	var stack: Control = _view.get_parent()
	stack.add_sibling(_columns)
	move_child(_columns, stack.get_index())
	_columns.draw.connect(_draw_columns)
	_view.resized.connect(_columns.queue_redraw)
	_columns.hide()


## Shows the column names while side by side shows conflict blocks.
func _update_columns() -> void:
	_columns.visible = _blocks > 0 and _view.side_by_side
	_columns.queue_redraw()


## "● main  ours" over the left column, "● topic  theirs" over the right one,
## lined up with the text.
func _draw_columns() -> void:
	var font: Font = get_theme_font(&"font", &"Label")
	var font_size: int = get_theme_font_size(&"header_font_size", DiffView.DIFF_THEME_TYPE)
	var height: float = _columns.size.y
	_columns.draw_rect(Rect2(Vector2.ZERO, _columns.size), get_theme_color(&"gutter_bg", DiffView.DIFF_THEME_TYPE))
	var baseline: float = (height + font.get_ascent(font_size) - font.get_descent(font_size)) / 2.0
	for i: int in 2:
		var x: float = _view.text_left(i)
		var dot: float = roundf(height * 0.4)
		_columns.draw_circle(Vector2(x - dot, height / 2.0), dot / 2.0,
				get_theme_color(&"ours_mark" if i == 0 else &"theirs_mark", DiffView.DIFF_THEME_TYPE), true, -1.0, true)
		var name_text: String = _legend[i].text
		_columns.draw_string(font, Vector2(x + 4.0, baseline), name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
				get_theme_color(&"text_color", DiffView.DIFF_THEME_TYPE))
		x += 4.0 + font.get_string_size(name_text + "  ", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		_columns.draw_string(font, Vector2(x, baseline), ["ours", "theirs"][i], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
				get_theme_color(&"line_number_color", DiffView.DIFF_THEME_TYPE))


## "1 of 3" for the block at the diff's cursor, else "3 conflicts".
func _update_block_position() -> void:
	var block: int = _view.row_block(_view.cursor) if _view.cursor >= 0 else -1
	if block >= 0:
		_block_position.text = tr("%d of %d") % [block + 1, _blocks]
	else:
		_block_position.text = tr("1 conflict") if _blocks == 1 else tr("%d conflicts") % _blocks


## The resolver's header part for `blocks` conflict blocks between sides
## `names` (ours, theirs); hidden for 0.
func _show_conflict_bar(blocks: int, names: PackedStringArray) -> void:
	_blocks = blocks
	_view.block_count = blocks
	_conflict_bar.visible = blocks > 0
	_open_button.visible = blocks > 0
	_update_columns()
	if blocks == 0:
		return
	for i: int in 2:
		_legend[i].text = names[i] if names.size() == 2 else ["ours", "theirs"][i]
		_legend[i].tooltip_text = "%s (%s)" % [_legend[i].text, ["ours", "theirs"][i]]
		_legend[i].mouse_filter = Control.MOUSE_FILTER_PASS
		var swatch: TextureRect = _legend[i].get_parent().get_node("Swatch")
		swatch.texture = AppTheme.swatch(get_theme_color(&"ours_mark" if i == 0 else &"theirs_mark", DiffView.DIFF_THEME_TYPE))
	_update_block_position()


## The legend's names, "1 of 3" and whether the bar shows (for tests).
func conflict_bar_text() -> String:
	if not _conflict_bar.visible:
		return ""
	return "%s · %s · %s" % [_legend[0].text, _legend[1].text, _block_position.text]


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		_update_layout_tooltips()
		if not _info.is_empty():
			show_info(_info)
		else:
			show_message(tr(_placeholder))
		_show_code(_code)
		_show_path(_path_shown[0], _path_shown[1], _path_shown[2])


func _update_layout_tooltips() -> void:
	var shortcut: String = Actions.shortcut_label(&"diff.toggle_side_by_side")
	for button: Button in [_unified_button, _split_button]:
		var tip: String = "%s\n%s" % [tr(String(button.get_meta(&"title"))), tr(String(button.get_meta(&"description")))]
		button.tooltip_text = tip if shortcut.is_empty() else tr("%s\n%s switches") % [tip, shortcut]


func view() -> DiffView:
	return _view


## The Unified or the Side by side button.
func layout_button(side_by_side: bool) -> Button:
	return _split_button if side_by_side else _unified_button


## The Show whole file button.
func whole_file_button() -> Button:
	return _whole_button


## Whether the diff shown can switch between its changes and the whole file.
func can_toggle_whole_file() -> bool:
	return is_visible_in_tree() and _whole_button.visible


## Shows the whole file, or only the changes again.
func toggle_whole_file() -> void:
	if can_toggle_whole_file():
		_whole_button.button_pressed = not _whole_button.button_pressed


## Where lines come from: `func(start, count) -> Array` (see DiffView).
func set_source(source: Callable) -> void:
	_view.source = source


## Where side-by-side rows come from (see DiffView).
func set_split_source(source: Callable) -> void:
	_view.split_source = source


func set_side_by_side(value: bool) -> void:
	_view.side_by_side = value
	_unified_button.set_pressed_no_signal(not value)
	_split_button.set_pressed_no_signal(value)
	_update_columns()


## Clears the diff and shows `placeholder` (also used by later `clear()` calls).
func clear(placeholder: String = "") -> void:
	if not placeholder.is_empty():
		_placeholder = placeholder
	_info = {}
	_shown = ""
	_view.show_lines(0, 0, false)
	_show_code("")
	_show_path("", "", -1)
	_stats.text = ""
	show_counts(_added, _removed, 0, 0)
	_show_whole_button(false, false)
	_base_button.hide()
	_show_conflict_bar(0, PackedStringArray())
	show_message(tr(_placeholder))


## Shows a diff described by `info` (`state`, `path`, `kind`, `content`,
## `code`, `original_path`, `similarity`, `notes`, `additions`, `deletions`,
## `line_count`, `max_line`, `can_expand`, `whole`, sizes, `error`).
func show_info(info: Dictionary) -> void:
	_info = info.duplicate(true)
	var state: String = String(info.get("state", "none"))
	if state == "none":
		clear()
		return
	var path: String = String(info["path"])
	var key: String = String(info["kind"]) + ":" + path
	var code: String = String(info.get("code", ""))
	_show_code(code)
	_show_path(path, String(info.get("original_path", "")), int(info.get("similarity", -1)))
	var notes: PackedStringArray = info.get("notes", PackedStringArray())
	var translated_notes: PackedStringArray = PackedStringArray()
	for note: String in notes:
		translated_notes.append(tr(note))
	_stats.text = "  ·  ".join(translated_notes)
	show_counts(_added, _removed, int(info.get("additions", 0)), int(info.get("deletions", 0)))
	match state:
		"loading":
			if key != _shown:
				_view.show_lines(0, 0, false)
				show_message(tr("Loading…"))
			return
		"error":
			var error: Dictionary = info.get("error", {})
			_view.show_lines(0, 0, false)
			show_message(tr("Cannot show this diff.\n%s") % tr(String(error.get("message", error.get("title", "")))))
			_shown = ""
			return
	var keep: bool = key == _shown
	_shown = key
	var whole: bool = bool(info.get("whole", false))
	_show_whole_button(bool(info.get("can_expand", false)) or whole, whole)
	_base_button.hide()
	_show_conflict_bar(0, PackedStringArray())
	match String(info.get("content", "text")):
		"conflict":
			_show_conflict(info, keep)
		"text", "combined":
			_message.hide()
			_view.show_lines(int(info["line_count"]), int(info["max_line"]), keep,
					int(info.get("split_count", info["line_count"])))
		"binary":
			_view.show_lines(0, 0, false)
			show_message(tr("Binary file: %s → %s") % [
				_size_text(int(info["old_size"])), _size_text(int(info["new_size"]))])
		"too_large":
			_view.show_lines(0, 0, false)
			show_message(tr("This diff is large (more than %s).") % _size_text(int(info["bytes"])), true)
		"empty":
			_view.show_lines(0, 0, false)
			show_message("\n".join(translated_notes) if not notes.is_empty() else tr(EMPTY_MESSAGES.get(code, "No changes to show.")))


## A conflicted file: its blocks (scrolled to the first one when it first
## shows), or the card of a conflict without blocks.
func _show_conflict(info: Dictionary, keep: bool) -> void:
	var conflict: Dictionary = info.get("conflict", {})
	var kind: String = String(conflict.get("kind", ""))
	var blocks: int = int(conflict.get("blocks", 0))
	var side: String = "we" if String(conflict.get("side", "")) == "ours" else "they"
	if kind in ["content", "add_add"] and blocks > 0:
		_message.hide()
		_card.hide()
		_base_button.visible = true
		_base_button.disabled = not bool(conflict.get("has_base", false))
		_base_button.set_pressed_no_signal(bool(conflict.get("show_base", false)) and not _base_button.disabled)
		_base_button.tooltip_text = BASE_TIP if not _base_button.disabled \
				else "These conflict markers have no base; recreate them to see it"
		_view.show_lines(int(info["line_count"]), int(info["max_line"]), keep, int(info.get("split_count", info["line_count"])))
		_show_conflict_bar(blocks, info.get("side_names", PackedStringArray()))
		if not keep:
			var first: int = int(conflict.get("first_split_row" if _view.side_by_side else "first_row", -1))
			if first >= 0:
				_view.select_only(first)
		return
	_view.show_lines(0, 0, false)
	var names: PackedStringArray = info.get("side_names", PackedStringArray(["ours", "theirs"]))
	# `side` is the one that deleted the file, or the only one that has it.
	var one: int = 0 if side == "we" else 1
	var named: String = names[one]
	var unnamed: String = names[1 - one]
	match kind:
		"modify_delete":
			show_card(tr("%s deleted it · %s changed it") % [named, unnamed],
					[["keep", tr("Keep %s's version") % unnamed, _side_dot(1 - one)],
					["delete", tr("Delete it, as %s did") % named, _side_dot(one)]], "D")
		"added_by_one":
			show_card(tr("Only %s has it · %s probably renamed it") % [named, unnamed],
					[["keep", "Keep it", _side_dot(one)], ["delete", "Delete it", AppTheme.icon(&"Remove")]], "A")
		"both_deleted":
			show_card(tr("%s and %s both deleted or renamed it") % [names[0], names[1]],
					[["delete", "Delete it", AppTheme.icon(&"Remove")]], "D")
		"binary":
			show_card("Both changed this binary file",
					[["ours", tr("Use %s") % names[0], _side_dot(0)], ["theirs", tr("Use %s") % names[1], _side_dot(1)]], "U",
					[[names[0], int(conflict.get("ours_size", -1))], [names[1], int(conflict.get("theirs_size", -1))]])
		_:
			show_message("No conflicts are left in this file; it is marked resolved.")


## A side's colour as the resolver's buttons show it (0 ours, 1 theirs).
func _side_dot(side: int) -> Texture2D:
	return AppTheme.dot(get_theme_color(&"ours_mark" if side == 0 else &"theirs_mark", DiffView.DIFF_THEME_TYPE))


## A message with buttons (`[id, label, icon]`) that emit `card_action`, over
## the status icon of `code` and, for a binary file, `sizes` as
## `[side name, bytes]` rows.
func show_card(text: String, buttons: Array, code: String = "U", sizes: Array = []) -> void:
	show_message(text)
	for child: Node in _card.get_children():
		_card.remove_child(child)
		child.queue_free()
	for button_info: Array in buttons:
		var button: Button = Button.new()
		button.text = String(button_info[1])
		button.icon = button_info[2] as Texture2D
		var id: String = String(button_info[0])
		button.pressed.connect(func() -> void: card_action.emit(id))
		_card.add_child(button)
	_card.show()
	var side: float = float(get_theme_constant(&"card_icon_size", DiffView.DIFF_THEME_TYPE))
	_card_icon.custom_minimum_size = Vector2(side, side)
	_card_icon.texture = FileRowPainter.code_icon(code)
	_card_icon.self_modulate = FileRowPainter.code_color(self, code)
	_card_icon.show()
	for child: Node in _card_table.get_children():
		_card_table.remove_child(child)
		child.queue_free()
	for i: int in sizes.size():
		var swatch: TextureRect = TextureRect.new()
		swatch.texture = AppTheme.swatch(get_theme_color(&"ours_mark" if i == 0 else &"theirs_mark", DiffView.DIFF_THEME_TYPE))
		swatch.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		_card_table.add_child(swatch)
		var side_label: Label = Label.new()
		side_label.text = String(sizes[i][0])
		_card_table.add_child(side_label)
		var size_label: Label = Label.new()
		size_label.theme_type_variation = &"DimLabel"
		size_label.text = _size_text(int(sizes[i][1]))
		size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_card_table.add_child(size_label)
	_card_table.visible = not sizes.is_empty()


## The card's button labels (for tests).
func card_buttons() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if _card.visible and _message.visible:
		for child: Node in _card.get_children():
			out.append((child as Button).text)
	return out


## The Show base toggle (for tests).
func base_button() -> Button:
	return _base_button


func _show_whole_button(shown: bool, pressed: bool) -> void:
	_whole_button.visible = shown
	_whole_button.set_pressed_no_signal(pressed)
	var shortcut: String = Actions.shortcut_label(&"diff.toggle_whole_file")
	var tip: String = tr("Show only the changes") if pressed else tr("Show the whole file")
	_whole_button.tooltip_text = tip if shortcut.is_empty() else "%s (%s)" % [tip, shortcut]


func show_message(text: String, offer_full: bool = false) -> void:
	_message_label.text = text
	_load_anyway.visible = offer_full
	_card.hide()
	_card_icon.hide()
	_card_table.hide()
	_message.show()


func message_text() -> String:
	return _message_label.text if _message.visible else ""


## The status icon of `code` ("A", "M", ...), tinted like the file lists'.
func _show_code(code: String) -> void:
	_code = code
	_status_icon.texture = FileRowPainter.code_icon(code)
	_status_icon.visible = _status_icon.texture != null
	_status_icon.self_modulate = FileRowPainter.code_color(self, code)
	_status_icon.tooltip_text = FileRowPainter.code_name(code)


## Status code of the diff shown ("A", "M", ...), or "".
func status_code() -> String:
	return _code


## `+12` and `−3` in `added` and `removed` (hidden while both are zero).
static func show_counts(added: Label, removed: Label, additions: int, deletions: int) -> void:
	added.text = "+%d" % additions
	removed.text = "−%d" % deletions
	added.get_parent().visible = additions > 0 or deletions > 0


## The `+` and `−` counts shown, as `+12 −3`, or "".
func counts_text() -> String:
	return "%s %s" % [_added.text, _removed.text] if _counts.visible else ""


## The header's path as shown, such as `docs/a.md → b.md`.
func path_text() -> String:
	return _path.get_parsed_text()


## `path` like the file lists show it: everything before the file name
## muted (`FileRowPainter.path_lead`, so a rename reads `docs/old.md → new.md`);
## the tooltip says where a renamed or copied file came from and how similar it is.
func _show_path(path: String, original: String, similarity: int) -> void:
	_path_shown = [path, original, similarity]
	_path.clear()
	_path.tooltip_text = path
	var lead: PackedStringArray = FileRowPainter.path_lead(path, original)
	_path.push_color(FileRowPainter.dir_color(self))
	_path.add_text(lead[0] + lead[1])
	_path.pop()
	_path.add_text(path.get_file())
	if original.is_empty() or original == path:
		return
	_path.tooltip_text = tr("Copied from %s") % original if _code == "C" else tr("Renamed from %s") % original
	if similarity >= 0:
		_path.tooltip_text += tr(" · %d%% similar") % similarity


func _apply_theme() -> void:
	var icon_size: float = float(get_theme_constant(&"icon_size", FileRowPainter.THEME_TYPE))
	_status_icon.custom_minimum_size = Vector2(icon_size, icon_size)
	_layout_gap.custom_minimum_size.x = float(get_theme_constant(&"layout_gap", &"DiffHeader"))
	_columns.custom_minimum_size.y = _view.row_height() + 4.0
	_show_code(_code)
	# Wide enough for "12 conflicts", so stepping does not move the buttons.
	_block_position.custom_minimum_size.x = _block_position.get_theme_font(&"font").get_string_size(
			tr("%d conflicts") % 12, HORIZONTAL_ALIGNMENT_LEFT, -1, _block_position.get_theme_font_size(&"font_size")).x
	if _blocks > 0:
		_show_conflict_bar(_blocks, PackedStringArray([_legend[0].text, _legend[1].text]))
	# Not sized to its text, so a long path can't widen the panel: one line.
	var font: Font = get_theme_font(&"normal_font", &"RichTextLabel")
	_path.custom_minimum_size.y = font.get_height(get_theme_font_size(&"normal_font_size", &"RichTextLabel"))
	_show_path(_path_shown[0], _path_shown[1], _path_shown[2])


static func _size_text(bytes: int) -> String:
	if bytes < 0:
		return TranslationServer.translate(&"none")
	return String.humanize_size(bytes)
