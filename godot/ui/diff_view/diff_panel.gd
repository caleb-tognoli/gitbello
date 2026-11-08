class_name DiffPanel
extends VBoxContainer
## A file diff with its header (status icon, path, notes, +/− counts,
## whole file, unified or side by side) and the messages shown instead of lines
## (loading, binary, too large, no changes, errors). The path reads like the
## file lists': its folder muted, a renamed file `docs/old.md → new.md`.
## Callers pass `RepoSession.diff_info()`-style dictionaries to `show_info`.
## A conflicted file (`content` `conflict`) shows its conflict blocks with a
## bar in the header (the sides' colours and names from `side_names`, the
## block at the cursor with previous / next, Show base), or a
## card with the choices of a conflict without blocks (`card_action`).
## The header's mode picker has a button per mode the diff offers
## (`diff_info`'s `viewer` and `modes`) and hides with fewer than two; a diff
## that does not offer its viewer's saved mode shows its first one without
## saving it. Every panel is in the `diff_panels` group so a mode chosen in one
## applies everywhere at once (`apply_saved_mode`).
## An image diff (`viewer` `image`, `diff_info`'s `image`) shows in an
## ImageDiffView with a Fit / 100% toggle and the sizes in the header; its
## bytes come from `set_image_source` and decode on worker threads, kept by
## side `id`. A binary image conflict's card previews ours and theirs.

const GROUP: StringName = &"diff_panels"
## Icon, title and description of each mode, by `viewer:mode`.
const MODES: Dictionary[String, Array] = {
	"text:unified": [&"Panels1", "Unified", "Old and new lines in one column"],
	"text:split": [&"Panels2Alt", "Side by side", "Old lines on the left, new lines on the right"],
	"image:split": [&"Panels2Alt", "Side by side", "Old image on the left, new image on the right"],
	"image:onion": [&"ImageOnion", "Onion skin", "New image over the old one, faded with the slider or Left/Right"],
	"image:swipe": [&"ImageSwipe", "Swipe", "Drag the divider: old image on its left, new on its right"],
	"image:difference": [&"ImageDifference", "Difference", "Changed pixels highlighted"],
}
## Decoded images kept, by side `id` (most recent last).
const IMAGE_CACHE: int = 6
## An SVG renders this much sharper than 100% (at most), for zooming in.
const SVG_SCALE: float = 4.0
const SVG_MAX_SIDE: float = 4096.0
## A larger image shows a preview this wide or tall until zoomed in past it.
const PREVIEW_SIDE: int = 2048
## Full-size images kept (in memory, not uploaded) behind their previews.
const FULL_IMAGES: int = 4
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
## Open was chosen on an image side (`old` or `new`) in its context menu.
signal open_side_requested(side: String)

@onready var _status_icon: TextureRect = %StatusIcon
@onready var _path: RichTextLabel = %DiffPath
@onready var _stats: Label = %DiffStats
@onready var _added: Label = %DiffAdded
@onready var _removed: Label = %DiffRemoved
@onready var _layout_gap: Control = %LayoutGap
@onready var _view: DiffView = %DiffView
@onready var _message: Control = %DiffMessage
## Over the diff while it loads: blocking for a new file, over the old lines
## while the shown one loads again.
var _loading: LoadingIndicator = LoadingIndicator.new()
@onready var _message_label: Label = %DiffMessageLabel
@onready var _load_anyway: Button = %LoadAnywayButton
@onready var _retry: Button = %RetryButton
@onready var _switch: HBoxContainer = %LayoutSwitch
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
## The resolver's part of the header: the sides' legend and the block at the
## cursor between previous and next.
var _conflict_bar: HBoxContainer = HBoxContainer.new()
var _legend: Array[Label] = []
var _block_position: Label = Label.new()
## The image viewer's context menu (Open) and the side it was opened on.
var _image_menu: PopupMenu = PopupMenu.new()
var _image_menu_side: String = ""
var _columns: Control = Control.new()
## Conflict blocks of the file shown (0 when it is no conflict).
var _blocks: int = 0
var _info: Dictionary = {}
## What draws the diff shown (`text`, `image`, `none`), the modes it offers in
## cycle order and the one shown.
var _viewer: String = "none"
var _modes: PackedStringArray = PackedStringArray()
var _mode: String = ""
var _image_view: ImageDiffView = ImageDiffView.new()
## The binary conflict card's ours | theirs previews.
var _preview: ImageDiffView = ImageDiffView.new()
## `func(side: String) -> Dictionary`: `RepoSession.image_side` of the slot.
var _image_source: Callable = Callable()
## Worker tasks by token, and what each decodes: `[view, side, id]`.
var _tasks: Dictionary[int, int] = {}
var _pending: Dictionary[int, Array] = {}
var _next_token: int = 1
## `id -> [texture, size at 100%, whether the texture is a preview]`, and
## the ids from oldest to newest use.
var _cache: Dictionary[String, Array] = {}
var _cache_order: PackedStringArray = PackedStringArray()
## Decoded images waiting to upload, one a frame:
## `[view, side, id, image, full image or null, size at 100%]`.
var _uploads: Array[Array] = []
## Full images behind previews by id, and the ids from oldest to newest use.
var _full: Dictionary[String, Image] = {}
var _full_order: PackedStringArray = PackedStringArray()
## Size at 100% of each decoded image by id (an SVG's is only known decoded).
var _decoded_sizes: Dictionary[String, Vector2] = {}
## The image diff shown and its notes, for the header.
var _image_info: Dictionary = {}
var _image_notes: PackedStringArray = PackedStringArray()
## `kind:path` of the diffs whose only changes are endings that were asked
## to show as a diff (Show diff on their card), for this session.
static var _eol_full: Dictionary[String, bool] = {}


func _ready() -> void:
	add_to_group(GROUP)
	_loading.area = "diff"
	_message.get_parent().add_child(_loading)
	_load_anyway.pressed.connect(func() -> void: load_full_requested.emit())
	_retry.pressed.connect(func() -> void: Actions.run_action(&"diff.retry", _retry))
	_update_layout_tooltips()
	set_minimap_enabled(Core.diff_minimap())
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
	card_action.connect(_on_card_action)
	_card_table.columns = 3
	_card_table.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_card_table.theme_type_variation = &"ConflictCardTable"
	_card_table.hide()
	_message_label.add_sibling(_card_table)
	_build_image_views()
	_apply_theme()


func _build_image_views() -> void:
	_image_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_image_view.hide()
	_view.add_sibling(_image_view)
	_image_view.view_changed.connect(func() -> void: _sharpen(_image_view))
	_image_view.side_menu_requested.connect(_show_image_menu)
	add_child(_image_menu)
	_image_menu.id_pressed.connect(func(_id: int) -> void: open_side_requested.emit(_image_menu_side))
	set_process(false)
	_preview.interactive = false
	_preview.mode = "split"
	_preview.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_preview.hide()
	_card.add_sibling(_preview)
	_card.get_parent().move_child(_preview, _card.get_index())


func _exit_tree() -> void:
	# Every task must be waited for; results still queued find no task.
	for token: int in _tasks:
		WorkerThreadPool.wait_for_task_completion(_tasks[token])
	_tasks.clear()
	_pending.clear()


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
	if what == NOTIFICATION_PREDELETE and _loading.get_parent() == null:
		_loading.free()  # Never added: freed without ever being ready.
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
	_retry.text = tr("Retry")
	var shortcut: String = Actions.shortcut_label(&"diff.cycle_mode")
	for child: Node in _switch.get_children():
		var button: Button = child as Button
		var entry: Array = MODES.get("%s:%s" % [_viewer, String(button.get_meta(&"mode"))], [])
		if entry.is_empty():
			continue
		var tip: String = "%s\n%s" % [tr(String(entry[1])), tr(String(entry[2]))]
		button.tooltip_text = tip if shortcut.is_empty() else tr("%s\n%s switches") % [tip, shortcut]


func view() -> DiffView:
	return _view


## The picker's button of `mode` (such as `split`), or null when it shows none.
func mode_button(mode_id: String) -> Button:
	if not _switch.visible:
		return null
	for child: Node in _switch.get_children():
		if String(child.get_meta(&"mode")) == mode_id:
			return child as Button
	return null


## Whether the picker shows (the diff offers two modes or more).
func picker_visible() -> bool:
	return _switch.visible


## The modes the diff shown offers, in cycle order.
func modes() -> PackedStringArray:
	return _modes


## The mode shown, such as `unified`; "" when the diff offers none.
func mode() -> String:
	return _mode


## What draws the diff shown: `text`, `image` or `none`.
func viewer() -> String:
	return _viewer


## Whether the diff on screen offers more than one mode.
func can_cycle_mode() -> bool:
	return is_visible_in_tree() and _modes.size() >= 2


## Shows the next offered mode, wrapping, and saves it for this viewer.
func cycle_mode() -> void:
	if _modes.size() < 2:
		return
	choose_mode(_modes[(_modes.find(_mode) + 1) % _modes.size()])


## Shows `mode_id` and saves it for this viewer; every panel showing the same
## viewer follows.
func choose_mode(mode_id: String) -> void:
	if not mode_id in _modes:
		return
	Core.set_diff_mode(_viewer, mode_id)
	get_tree().call_group(GROUP, &"apply_saved_mode", _viewer)


## Shows `viewer_id`'s saved mode again (after it changed) if it is the viewer shown.
func apply_saved_mode(viewer_id: String) -> void:
	if viewer_id == _viewer:
		_set_offered(_viewer, _modes)


## Shows the modes `offered` of `viewer_id` in the picker (hidden for fewer
## than two) and switches to the saved mode, else the first one offered.
func _set_offered(viewer_id: String, offered: PackedStringArray) -> void:
	var rebuild: bool = viewer_id != _viewer or offered != _modes
	_viewer = viewer_id
	_modes = offered
	var saved: String = Core.diff_mode(viewer_id) if viewer_id != "none" else ""
	_mode = saved if saved in offered else (offered[0] if not offered.is_empty() else "")
	if rebuild:
		_build_switch()
	for child: Node in _switch.get_children():
		(child as Button).set_pressed_no_signal(String(child.get_meta(&"mode")) == _mode)
	if _viewer == "text":
		_view.side_by_side = _mode == "split"
	elif _viewer == "image":
		_image_view.mode = _mode
	_update_columns()


func _build_switch() -> void:
	for child: Node in _switch.get_children():
		_switch.remove_child(child)
		child.queue_free()
	_switch.visible = _modes.size() >= 2
	if not _switch.visible:
		return
	var group: ButtonGroup = ButtonGroup.new()
	for i: int in _modes.size():
		var id: String = _modes[i]
		var button: Button = Button.new()
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.button_group = group
		if i == 0:
			button.theme_type_variation = &"IconSegmentFirst"
		elif i == _modes.size() - 1:
			button.theme_type_variation = &"IconSegmentLast"
		else:
			button.theme_type_variation = &"IconSegmentMiddle"
		button.set_meta(&"mode", id)
		var entry: Array = MODES.get("%s:%s" % [_viewer, id], [])
		if not entry.is_empty():
			button.icon = AppTheme.icon(entry[0])
		button.pressed.connect(func() -> void:
			if id != _mode:
				choose_mode(id))
		_switch.add_child(button)
	_update_layout_tooltips()


## The Show whole file button.
func whole_file_button() -> Button:
	return _whole_button


## Whether the diff shown can switch between its changes and the whole file.
func can_toggle_whole_file() -> bool:
	return is_visible_in_tree() and _whole_button.visible


func can_retry() -> bool:
	return is_visible_in_tree() and _retry.visible


## Shows the whole file, or only the changes again.
func toggle_whole_file() -> void:
	if can_toggle_whole_file():
		_whole_button.button_pressed = not _whole_button.button_pressed


## Where an image diff's sides come from: `func(side: String) -> Dictionary`
## (`RepoSession.image_side` of the panel's slot, `old` or `new`).
func set_image_source(source: Callable) -> void:
	_image_source = source


## The image viewer (for tests).
func image_view() -> ImageDiffView:
	return _image_view


## The binary conflict card's previews (for tests).
func image_preview() -> ImageDiffView:
	return _preview


## Whether images are still decoding.
func images_pending() -> bool:
	return not _pending.is_empty() or not _uploads.is_empty()


## Where lines come from: `func(start, count) -> Array` (see DiffView).
func set_source(source: Callable) -> void:
	_view.source = source


## Where side-by-side rows come from (see DiffView).
func set_split_source(source: Callable) -> void:
	_view.split_source = source


## Where the minimap's tiles, overview and strip positions come from (see
## DiffMinimap).
func set_minimap_sources(tiles: Callable, overview: Callable,
		positions: Callable = Callable(), targets: Callable = Callable()) -> void:
	_view.set_minimap_sources(tiles, overview, positions, targets)


## Where `jump_to_change` finds change blocks (see DiffView.change_source).
func set_change_source(source: Callable) -> void:
	_view.change_source = source


## Shows the minimap's preview, or only its strip of change marks.
func set_minimap_enabled(value: bool) -> void:
	_view.set_minimap_enabled(value)


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
	_set_offered("none", PackedStringArray())
	_hide_images()
	_loading.hide_loading()
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
	_retry.hide()
	# A diff still loading keeps the picker it had (no flicker between files).
	if info.has("modes"):
		_set_offered(String(info.get("viewer", "none")), info["modes"])
	match state:
		"loading":
			_show_whole_button(false, false)
			if key != _shown:
				_view.show_lines(0, 0, false)
				_hide_images()
				_message.hide()
				_loading.show_loading(true, tr("Loading diff…"))
			else:
				_loading.show_loading(false, tr("Updating…"))
			return
		"error":
			_loading.hide_loading()
			var error: Dictionary = info.get("error", {})
			_view.show_lines(0, 0, false)
			_hide_images()
			_show_whole_button(false, false)
			show_message(tr("Cannot show this diff.\n%s") % tr(String(error.get("message", error.get("title", "")))))
			_retry.show()
			_set_offered("none", PackedStringArray())
			_shown = ""
			return
	_loading.hide_loading()
	var keep: bool = key == _shown
	_shown = key
	var whole: bool = bool(info.get("whole", false))
	_show_whole_button(bool(info.get("can_expand", false)) or whole, whole)
	_base_button.hide()
	_show_conflict_bar(0, PackedStringArray())
	var content: String = String(info.get("content", "text"))
	if _viewer == "image" and info.has("image") and content != "conflict":
		_show_images(info.get("image", {}), keep, translated_notes)
		return
	_hide_images()
	match content:
		"conflict":
			_show_conflict(info, keep)
		"text", "combined":
			if bool(info.get("eol_only", false)) and not _eol_full.has(key):
				_view.show_lines(0, 0, false)
				_show_whole_button(false, false)
				_set_offered("none", PackedStringArray())
				var buttons: Array = [["eol_show_diff", tr("Show diff"), AppTheme.icon(&"TextFile")]]
				# The working copy in Changes can get its endings back.
				if String(info.get("kind", "")) == "head":
					buttons.push_front(["eol_restore", tr("Restore line endings"), AppTheme.icon(&"Undo")])
				show_card(eol_card_text(info), buttons, code)
				return
			_message.hide()
			_view.show_lines(int(info["line_count"]), int(info["max_line"]), keep,
					int(info.get("split_count", info["line_count"])))
		"binary":
			_view.show_lines(0, 0, false)
			show_message(tr("Binary file: %s → %s") % [
				_size_text(int(info["old_size"])), _size_text(int(info["new_size"]))])
		"too_large":
			_view.show_lines(0, 0, false)
			var large: String = "This image is large (more than %s)." if is_image_path(path) else "This diff is large (more than %s)."
			show_message(tr(large) % _size_text(int(info["bytes"])), true)
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
			var image: Dictionary = info.get("image", {})
			if not image.is_empty() and not _too_large(image):
				if not keep:
					_preview.clear()
				var captions: PackedStringArray = PackedStringArray()
				for i: int in 2:
					var side_info: Dictionary = image.get("old" if i == 0 else "new", {})
					var width: int = int(side_info.get("width", -1))
					captions.append(names[i] if width < 0 else "%s  %d×%d" % [names[i], width, int(side_info.get("height", -1))])
				_preview.captions = captions
				_preview.show()
				_load_sides(_preview, image)
		_:
			show_message("No conflicts are left in this file; it is marked resolved.")


## An image diff: the viewer (fitted when the file first shows) with the
## sides' sizes in the header, or a message with Load anyway when a side is
## past the size limit.
func _show_images(image: Dictionary, keep: bool, notes: PackedStringArray) -> void:
	_view.show_lines(0, 0, false)
	_view.hide()
	_show_whole_button(false, false)
	show_counts(_added, _removed, 0, 0)
	_image_info = image
	_image_notes = notes
	_update_image_stats()
	if _too_large(image):
		_image_view.hide()
		_image_view.clear()
		var largest: int = maxi(int((image["old"] as Dictionary).get("size", -1)), int((image["new"] as Dictionary).get("size", -1)))
		show_message(tr("This image is large (%s).") % _size_text(largest), true)
		return
	_message.hide()
	if not keep:
		_image_view.clear()
	_image_view.mode = _mode
	_image_view.captions = PackedStringArray([tr("Old"), tr("New")])
	_image_view.show()
	_load_sides(_image_view, image)


func _update_image_stats() -> void:
	var stats: PackedStringArray = _image_notes.duplicate()
	var text: String = image_stats(_image_info, _decoded_sizes)
	if not text.is_empty():
		stats.append(text)
	_stats.text = "  ·  ".join(stats)


func _hide_images() -> void:
	_image_info = {}
	_view.show()
	if _image_view.visible:
		_image_view.hide()
		_image_view.clear()
	_preview.hide()


## Whether `path` has an extension the image viewer shows.
static func is_image_path(path: String) -> bool:
	return path.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp", "bmp", "tga", "svg"]


static func _too_large(image: Dictionary) -> bool:
	for key: String in ["old", "new"]:
		if String((image.get(key, {}) as Dictionary).get("state", "")) == "too_large":
			return true
	return false


## The header's sizes of an image diff: `512×512 → 640×480 · 12 KB → 14 KB`,
## one value where both sides match or only one exists. `decoded` gives the
## size of an image the header did not know (an SVG's), by side `id`.
static func image_stats(image: Dictionary, decoded: Dictionary[String, Vector2] = {}) -> String:
	var dims: PackedStringArray = PackedStringArray()
	var sizes: PackedStringArray = PackedStringArray()
	for key: String in ["old", "new"]:
		var side: Dictionary = image.get(key, {})
		if String(side.get("state", "missing")) == "missing":
			continue
		var width: int = int(side.get("width", -1))
		var height: int = int(side.get("height", -1))
		var known: Vector2 = decoded.get(String(side.get("id", "")), Vector2.ZERO)
		if width < 0 and known != Vector2.ZERO:
			width = roundi(known.x)
			height = roundi(known.y)
		dims.append("%d×%d" % [width, height] if width >= 0 else "?")
		sizes.append(_size_text(int(side.get("size", -1))))
	var parts: PackedStringArray = PackedStringArray()
	for values: PackedStringArray in [dims, sizes]:
		if values.size() == 2 and values[0] == values[1]:
			values.resize(1)
		if not values.is_empty() and not values.has("?"):
			parts.append(" → ".join(values))
	return "  ·  ".join(parts)


## Shows `image`'s sides in `target`: from the cache, else decoded on a worker
## thread (the side's place stays empty meanwhile); sides that cannot show
## get a message.
func _load_sides(target: ImageDiffView, image: Dictionary) -> void:
	var format: String = String(image.get("format", ""))
	for side: int in 2:
		var key: String = "old" if side == ImageDiffView.OLD else "new"
		var info: Dictionary = image.get(key, {})
		var id: String = String(info.get("id", ""))
		var width: int = int(info.get("width", -1))
		var dims: Vector2 = Vector2(width, int(info.get("height", -1))) if width > 0 else Vector2.ZERO
		match String(info.get("state", "missing")):
			"image":
				if target.ids[side] == id:
					continue
				target.ids[side] = id
				if _cache.has(id):
					_touch(id)
					target.set_side(side, _cache[id][0], _cache[id][1])
					continue
				target.set_side(side, null, dims)
				var bytes: PackedByteArray = PackedByteArray()
				if _image_source.is_valid():
					bytes = (_image_source.call(key) as Dictionary).get("bytes", PackedByteArray())
				var token: int = _next_token
				_next_token += 1
				_pending[token] = [target, side, id]
				_tasks[token] = WorkerThreadPool.add_task(_decode_task.bind(token, bytes, format), false, "Decode image")
			"too_many_pixels":
				target.ids[side] = ""
				target.set_side(side, null, Vector2.ZERO, tr("Too large to preview (%d×%d)") % [int(dims.x), int(dims.y)])
			"unreadable":
				target.ids[side] = ""
				target.set_side(side, null, Vector2.ZERO, tr("Cannot preview this image"))
			_:
				target.ids[side] = ""
				target.set_side(side, null)
	_sharpen(target)


## On a worker thread: the image (an SVG rendered sharper, for zooming in)
## and its size at 100%. A large one also gets a preview at most
## PREVIEW_SIDE wide or tall, with mipmaps, which shows first: the full
## image uploads only once zoomed in past it.
func _decode_task(token: int, bytes: PackedByteArray, format: String) -> void:
	var image: Image = ImageDiffView.decode(bytes, format)
	var logical: Vector2 = Vector2(image.get_size()) if image != null else Vector2.ZERO
	if image != null and format == "svg":
		var longest: float = maxf(logical.x, logical.y)
		var svg_scale: float = clampf(SVG_MAX_SIDE / longest, 1.0, SVG_SCALE) if longest > 0.0 else 1.0
		if svg_scale > 1.0:
			var sharp: Image = ImageDiffView.decode(bytes, format, svg_scale)
			if sharp != null:
				image = sharp
	var preview: Image = image
	var full: Image = null
	if image != null and maxi(image.get_width(), image.get_height()) > PREVIEW_SIDE:
		full = image
		preview = image.duplicate() as Image
		while maxi(preview.get_width(), preview.get_height()) > PREVIEW_SIDE * 2:
			preview.shrink_x2()
		var longest_side: int = maxi(preview.get_width(), preview.get_height())
		if longest_side > PREVIEW_SIDE:
			var ratio: float = float(PREVIEW_SIDE) / longest_side
			preview.resize(maxi(1, roundi(preview.get_width() * ratio)), maxi(1, roundi(preview.get_height() * ratio)),
					Image.INTERPOLATE_BILINEAR)
	if preview != null:
		preview.generate_mipmaps()
	_arrived.call_deferred(token, preview, full, logical)


func _arrived(token: int, preview: Image, full: Image, logical: Vector2) -> void:
	if _tasks.has(token):
		WorkerThreadPool.wait_for_task_completion(_tasks[token])
		_tasks.erase(token)
	var job: Array = _pending.get(token, [])
	_pending.erase(token)
	if job.is_empty():
		return
	if preview == null:
		var target: ImageDiffView = job[0]
		if target.ids[job[1]] == job[2]:
			target.set_side(job[1], null, Vector2.ZERO, tr("Cannot preview this image"))
		return
	_uploads.append([job[0], job[1], job[2], preview, full, logical])
	set_process(true)


## Uploads one decoded image a frame (each takes milliseconds on the main
## thread), dropping those no longer shown.
func _process(_delta: float) -> void:
	while not _uploads.is_empty():
		var upload: Array = _uploads.pop_front()
		var target: ImageDiffView = upload[0]
		var side: int = upload[1]
		var id: String = upload[2]
		var image: Image = upload[3]
		var full: Image = upload[4]
		var logical: Vector2 = upload[5]
		if not is_instance_valid(target) or target.ids[side] != id:
			continue
		var texture: ImageTexture = ImageTexture.create_from_image(image)
		if full != null:
			_full[id] = full
			_touch_full(id)
		var preview: bool = full != null or (_full.has(id) and image != _full[id])
		_cache[id] = [texture, logical, preview]
		_touch(id)
		if not _decoded_sizes.has(id):
			_decoded_sizes[id] = logical
			if _decoded_sizes.size() > IMAGE_CACHE * 4:
				_decoded_sizes.erase(_decoded_sizes.keys()[0])
			if not _image_info.is_empty():
				_update_image_stats()
		target.set_side(side, texture, logical)
		_sharpen(target)
		return
	set_process(false)


## Queues the full image of a side showing its preview once `target` shows
## it larger than the preview.
func _sharpen(target: ImageDiffView) -> void:
	for side: int in 2:
		var id: String = target.ids[side]
		if not _cache.has(id) or not bool(_cache[id][2]) or not _full.has(id) or target.texture(side) == null:
			continue
		var logical: Vector2 = _cache[id][1]
		var shown: float = target.scale_shown() * maxf(logical.x, logical.y) * get_viewport().get_final_transform().get_scale().x
		var texture: Texture2D = target.texture(side)
		if shown <= maxf(texture.get_width(), texture.get_height()) * 1.01:
			continue
		var queued: bool = false
		for upload: Array in _uploads:
			queued = queued or (upload[2] == id and upload[3] == _full[id])
		if not queued:
			_uploads.append([target, side, id, _full[id], null, logical])
			set_process(true)


## Marks the full image `id` as just used, keeping FULL_IMAGES of them.
func _touch_full(id: String) -> void:
	var at: int = _full_order.find(id)
	if at >= 0:
		_full_order.remove_at(at)
	_full_order.append(id)
	while _full_order.size() > FULL_IMAGES:
		_full.erase(_full_order[0])
		_full_order.remove_at(0)


## Marks `id` as just used, dropping the oldest images past IMAGE_CACHE.
func _touch(id: String) -> void:
	var at: int = _cache_order.find(id)
	if at >= 0:
		_cache_order.remove_at(at)
	_cache_order.append(id)
	while _cache_order.size() > IMAGE_CACHE:
		_cache.erase(_cache_order[0])
		_cache_order.remove_at(0)


## The image viewer's context menu over `side` (OLD or NEW) at `at`: Open.
func _show_image_menu(side: int, at: Vector2) -> void:
	_image_menu_side = "old" if side == ImageDiffView.OLD else "new"
	_image_menu.clear()
	_image_menu.add_icon_item(Actions.icon(&"diff.open_file"), tr("Open"), 0)
	_image_menu.position = Vector2i(_image_view.get_screen_position() + at)
	_image_menu.reset_size()
	_image_menu.popup()


## The image viewer's context menu (for tests).
func image_menu() -> PopupMenu:
	return _image_menu


## The path of the file shown (worktree-relative), or "".
func shown_path() -> String:
	return String(_path_shown[0])


## The image viewer on screen with images to zoom, or null (the zoom actions
## act on it).
func zoomable_images() -> ImageDiffView:
	if not _image_view.is_visible_in_tree() or not _image_view.zoom_bar().visible:
		return null
	return _image_view


## A side's colour as the resolver's buttons show it (0 ours, 1 theirs).
func _side_dot(side: int) -> Texture2D:
	return AppTheme.dot(get_theme_color(&"ours_mark" if side == 0 else &"theirs_mark", DiffView.DIFF_THEME_TYPE))


## The card of a diff whose only changes are its endings and its final
## newline: each change on a line of its own.
static func eol_card_text(info: Dictionary) -> String:
	var endings: Dictionary = info.get("endings", {})
	var parts: PackedStringArray = PackedStringArray()
	if not endings.is_empty():
		parts.append(DiffView.endings_label(endings))
	match String(info.get("final_newline", "")):
		"added":
			parts.append(TranslationServer.translate("Newline added at the end"))
		"removed":
			parts.append(TranslationServer.translate("Newline removed from the end"))
	return "\n".join(parts)


func _on_card_action(id: String) -> void:
	if id == "eol_show_diff" and not _shown.is_empty():
		_eol_full[_shown] = true
		show_info(_info)


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
	_retry.hide()
	_card.hide()
	_preview.hide()
	_card_icon.hide()
	_card_table.hide()
	_message.show()


## The diff's loading indicator (smoke tests and screenshots).
func loading_indicator() -> LoadingIndicator:
	return _loading


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


## `+12` and `−3` in `added` and `removed`; a zero count is left out (`+12`
## alone), and both hide while both are zero.
static func show_counts(added: Label, removed: Label, additions: int, deletions: int) -> void:
	added.text = "+%d" % additions
	removed.text = "−%d" % deletions
	added.visible = additions > 0
	removed.visible = deletions > 0
	added.get_parent().visible = additions > 0 or deletions > 0


## The counts `added` and `removed` show, as `+12 −3`, `+12` or "".
static func shown_counts(added: Label, removed: Label) -> String:
	var parts: PackedStringArray = PackedStringArray()
	if added.get_parent().visible:
		for label: Label in [added, removed]:
			if label.visible:
				parts.append(label.text)
	return " ".join(parts)


## The `+` and `−` counts shown, as `+12 −3`, `+12` or "".
func counts_text() -> String:
	return shown_counts(_added, _removed)


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
	# As tall as its icon buttons even when none shows, so hiding the picker
	# does not move the lines.
	(_switch.get_parent() as Control).custom_minimum_size.y = _whole_button.get_combined_minimum_size().y
	_columns.custom_minimum_size.y = _view.row_height() + 4.0
	var preview_height: float = float(get_theme_constant(&"card_preview_height", ImageDiffView.THEME_TYPE))
	_preview.custom_minimum_size = Vector2(preview_height * 2.4, preview_height)
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
