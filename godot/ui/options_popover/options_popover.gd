class_name OptionsPopover
extends PopupPanel
## The options of a filter field or a pane (M7.15): sections (Filter, View)
## split by divider lines, each with a title and, for filters, a Clear button; in each, rows of a
## muted name and a control: a `SegmentedControl` for an either/or choice,
## `ToggleChip`s for on/off options, or a scrolling list of check rows for a
## dynamic set (the shelves' branches). Changes apply as they are made and
## the popover stays open; Tab moves between controls, Space / Enter toggle,
## Escape closes and gives the focus back to `return_focus`.
##
## Every option has an id and a default. `count()` is how many options
## marked `counted` differ from their default (the button's badge), and a
## section's Clear button shows while one of its counted options does.
## Labels are English keys, translated here; an `action` adds its shortcut
## to the control's tooltip. Styles are the `Options*` theme types.

## The user changed option `id` to `value` (a String for a choice, a bool
## for a chip or a check row). Not sent by `set_value`.
signal changed(id: String, value: Variant)

const THEME_TYPE: StringName = &"OptionsPopover"

## Focused again when the popover closes (the field it belongs to).
var return_focus: Control = null

var _sections: VBoxContainer = VBoxContainer.new()
var _rows: GridContainer = null
var _section: int = -1
## Per section: its Clear button (or null) and the action it runs.
var _clear_buttons: Array[Button] = []
var _clear_actions: Array[StringName] = []
## Per option id: its control (`SegmentedControl`, `ToggleChip` or
## `CheckBox`), default, whether it counts, and its section.
var _controls: Dictionary[String, Control] = {}
var _defaults: Dictionary[String, Variant] = {}
var _counted: Dictionary[String, bool] = {}
var _section_of: Dictionary[String, int] = {}
## Texts to translate again: `[object, property, key, action]` (the action
## adds its shortcut, for tooltips).
var _texts: Array[Array] = []
## The flow rows of chips and the scrolls of check rows, sized in `_fit`.
var _flows: Array[HFlowContainer] = []
var _scrolls: Array[ScrollContainer] = []
## The sections' title icons, tinted from the theme.
var _icons: Array[TextureRect] = []
## Rows without a name, across their section (their chips get the full width).
var _spanning: Array[Control] = []
## The first control, focused on opening.
var _first: Control = null


func _init() -> void:
	theme_type_variation = THEME_TYPE
	_sections.theme_type_variation = &"OptionsSections"
	add_child(_sections)
	about_to_popup.connect(_refresh_texts)
	popup_hide.connect(_give_back_focus)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_refresh_texts()
	elif what == NOTIFICATION_THEME_CHANGED:
		_apply_icon_theme()


## Starts a section titled `heading` (as written, not in capitals), below a
## divider line after the first, with an optional white `icon` before the title. With `clear_action`, a Clear button at its
## right runs that action while a counted option of the section is on.
func add_section(heading: String, clear_action: StringName = &"", icon: StringName = &"") -> void:
	if _sections.get_child_count() > 0:
		var divider: HSeparator = HSeparator.new()
		divider.theme_type_variation = &"OptionsDivider"
		_sections.add_child(divider)
	var section: VBoxContainer = VBoxContainer.new()
	section.theme_type_variation = &"OptionsSectionBox"
	_sections.add_child(section)
	var header: HBoxContainer = HBoxContainer.new()
	header.theme_type_variation = &"OptionsSectionHeader"
	section.add_child(header)
	if icon != &"":
		var glyph: TextureRect = TextureRect.new()
		glyph.texture = AppTheme.tintable_icon(icon)
		glyph.theme_type_variation = &"OptionsSectionIcon"
		glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		glyph.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		header.add_child(glyph)
		_icons.append(glyph)
	var label: Label = Label.new()
	label.theme_type_variation = &"OptionsSectionTitle"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(label)
	_track(label, &"text", heading)
	var clear: Button = null
	if clear_action != &"":
		clear = Button.new()
		clear.theme_type_variation = &"OptionsClear"
		clear.icon = AppTheme.tintable_icon(&"Close")
		clear.focus_mode = Control.FOCUS_ALL
		clear.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		clear.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		clear.hide()
		clear.pressed.connect(func() -> void: Actions.run_action(clear_action, clear))
		header.add_child(clear)
		_track(clear, &"text", "Clear")
		_track(clear, &"tooltip_text", "Clear all filters", clear_action)
	_rows = GridContainer.new()
	_rows.theme_type_variation = &"OptionsRows"
	_rows.columns = 2
	section.add_child(_rows)
	_section = _clear_buttons.size()
	_clear_buttons.append(clear)
	_clear_actions.append(clear_action)
	_apply_icon_theme()


## Adds an either/or row named `label`: `choices` are `{id, icon, label}`
## with optional `tooltip` (a key; else the label) and `action`. `chosen` is
## chosen now; `default` (the first choice when "") is what `count` compares
## with when `counted`.
func add_segmented(id: String, label: String, choices: Array[Dictionary], chosen: String,
		default: String = "", counted: bool = false) -> SegmentedControl:
	var segmented: SegmentedControl = SegmentedControl.new()
	for choice: Dictionary in choices:
		var icon_name: StringName = StringName(choice.get("icon", ""))
		var button: Button = segmented.add_choice(String(choice["id"]),
				AppTheme.tintable_icon(icon_name) if icon_name != &"" else null, "")
		_track(button, &"text", String(choice["label"]))
		_track(button, &"tooltip_text", String(choice.get("tooltip", choice["label"])),
				StringName(choice.get("action", "")))
	segmented.set_value(chosen)
	segmented.selected.connect(func(picked: String) -> void: _on_changed(id, picked))
	_add_row(label, segmented)
	_register(id, segmented, default if not default.is_empty() else String(choices[0]["id"]), counted)
	return segmented


## Adds a row named `label` ("" for none) of toggle chips: `chips` are
## `{id, icon, label}` with optional `tooltip`, `action`, `value` (false),
## `default` (false), `counted` (true) and `tint` (the icon's colour while off).
func add_chips(label: String, chips: Array[Dictionary]) -> void:
	var flow: HFlowContainer = HFlowContainer.new()
	flow.theme_type_variation = &"OptionsChips"
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for entry: Dictionary in chips:
		var id: String = String(entry["id"])
		var chip: ToggleChip = ToggleChip.new()
		var icon_name: StringName = StringName(entry.get("icon", ""))
		if icon_name != &"":
			chip.icon = AppTheme.tintable_icon(icon_name)
		if entry.has("tint"):
			chip.tint = entry["tint"]
		chip.set_pressed_no_signal(bool(entry.get("value", false)))
		chip.toggled.connect(func(on: bool) -> void: _on_changed(id, on))
		flow.add_child(chip)
		_track(chip, &"text", String(entry["label"]))
		_track(chip, &"tooltip_text", String(entry.get("tooltip", entry["label"])), StringName(entry.get("action", "")))
		_register(id, chip, bool(entry.get("default", false)), bool(entry.get("counted", true)))
	_flows.append(flow)
	_add_row(label, flow)


## Adds a scrolling list of check rows across the section: `rows` are
## `{id, label}` with optional `icon`, `value` (false), `default` (false),
## `counted` (true), `translate` (true; false for names such as branches,
## which then show in full in the tooltip) and `count` (a `CountBadge` after
## the label). `{separator = true}` draws a line between rows.
func add_checks(rows: Array[Dictionary]) -> void:
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	AutoScroll.enable(scroll)
	var list: VBoxContainer = VBoxContainer.new()
	list.theme_type_variation = &"OptionsChecks"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for entry: Dictionary in rows:
		if bool(entry.get("separator", false)):
			list.add_child(HSeparator.new())
			continue
		var id: String = String(entry["id"])
		var check: CheckBox = CheckBox.new()
		check.theme_type_variation = &"OptionsCheck"
		check.focus_mode = Control.FOCUS_ALL
		var icon_name: StringName = StringName(entry.get("icon", ""))
		if icon_name != &"":
			check.icon = AppTheme.icon(icon_name)
		if bool(entry.get("translate", true)):
			_track(check, &"text", String(entry["label"]))
		else:
			check.text = String(entry["label"])
			check.tooltip_text = check.text
		check.set_pressed_no_signal(bool(entry.get("value", false)))
		check.toggled.connect(func(on: bool) -> void: _on_changed(id, on))
		list.add_child(check)
		if entry.has("count"):
			var badge: CountBadge = CountBadge.new()
			check.add_child(badge)
			badge.count = int(entry["count"])
		_register(id, check, bool(entry.get("default", false)), bool(entry.get("counted", true)))
	_scrolls.append(scroll)
	# Across both columns: the list is the section's content.
	var section: VBoxContainer = _rows.get_parent() as VBoxContainer
	section.add_child(scroll)


## Option `id`'s value: a String for a choice, a bool otherwise; null when
## there is no such option.
func value(id: String) -> Variant:
	var node: Control = _controls.get(id)
	if node is SegmentedControl:
		return (node as SegmentedControl).value()
	if node is BaseButton:
		return (node as BaseButton).button_pressed
	return null


## Sets option `id` without sending `changed`.
func set_value(id: String, new_value: Variant) -> void:
	var node: Control = _controls.get(id)
	if node is SegmentedControl:
		(node as SegmentedControl).set_value(String(new_value))
	elif node is BaseButton:
		(node as BaseButton).set_pressed_no_signal(bool(new_value))
	_update_clear_buttons()


## How many counted options differ from their default.
func count() -> int:
	var total: int = 0
	for id: String in _controls:
		if _counted[id] and value(id) != _defaults[id]:
			total += 1
	return total


## Whether option `id` counts (is a filter rather than a view setting).
func is_counted(id: String) -> bool:
	return _counted.get(id, false)


## Sets every counted option back to its default without sending
## `changed`; returns whether any was not.
func reset_counted() -> bool:
	var any: bool = false
	for id: String in _controls:
		if _counted[id] and value(id) != _defaults[id]:
			set_value(id, _defaults[id])
			any = true
	return any


## Ids of the options, in the order they were added.
func ids() -> PackedStringArray:
	return PackedStringArray(_controls.keys())


## Option `id`'s control (`SegmentedControl`, `ToggleChip` or `CheckBox`).
func control(id: String) -> Control:
	return _controls.get(id)


## Section `index`'s Clear button, or null (for tests).
func clear_button(index: int) -> Button:
	return _clear_buttons[index]


## Opens under `anchor`, its right edge on the anchor's (moved left or right
## to stay in the window), with the first control focused.
func open_below(anchor: Control) -> void:
	_fit()
	_apply_icon_theme()
	var host: Window = anchor.get_window()
	# An embedded popover (headless, or a window that embeds its popups) is
	# placed in the host's canvas; a window of its own on the screen.
	var embedded: bool = host.gui_embed_subwindows
	var space: Transform2D = anchor.get_global_transform_with_canvas() if embedded else anchor.get_screen_transform()
	var bottom_left: Vector2 = space * Vector2(0.0, anchor.size.y)
	var bottom_right: Vector2 = space * anchor.size
	popup(Rect2i(Vector2i(bottom_left), Vector2i.ZERO))
	reset_size()
	var bounds: Rect2i = Rect2i(Vector2i.ZERO, Vector2i(host.get_visible_rect().size))
	if not embedded:
		size = Vector2i(Vector2(size) * host.content_scale_factor)
		bounds = Rect2i(host.position, host.size)
	var x: int = int(bottom_right.x) - size.x
	position = Vector2i(clampi(x, bounds.position.x, maxi(bounds.position.x, bounds.end.x - size.x)), int(bottom_left.y))
	if _first != null:
		# Focused for the keys, without the outline until a key moves it.
		_first.grab_focus.call_deferred(true)


## Adds a row: a name and `content` in the section's grid, or, without a
## name, `content` across the section (a new grid follows for named rows).
func _add_row(label: String, content: Control) -> void:
	var box: VBoxContainer = _rows.get_parent() as VBoxContainer
	if label.is_empty():
		box.add_child(content)
		_spanning.append(content)
		return
	if box.get_child(box.get_child_count() - 1) != _rows:
		var grid: GridContainer = GridContainer.new()
		grid.theme_type_variation = &"OptionsRows"
		grid.columns = 2
		box.add_child(grid)
		_rows = grid
	var name_label: Label = Label.new()
	name_label.theme_type_variation = &"OptionsRowLabel"
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rows.add_child(name_label)
	_track(name_label, &"text", label)
	_rows.add_child(content)


func _register(id: String, control_node: Control, default: Variant, counted: bool) -> void:
	_controls[id] = control_node
	_defaults[id] = default
	_counted[id] = counted
	_section_of[id] = _section
	if _first == null:
		_first = control_node
		if control_node is SegmentedControl:
			_first = control_node.get_child(0) as Control


func _on_changed(id: String, new_value: Variant) -> void:
	_update_clear_buttons()
	changed.emit(id, new_value)


func _update_clear_buttons() -> void:
	for i: int in _clear_buttons.size():
		if _clear_buttons[i] == null:
			continue
		var on: bool = false
		for id: String in _controls:
			if _section_of[id] == i and _counted[id] and value(id) != _defaults[id]:
				on = true
		_clear_buttons[i].visible = on


func _track(object: Object, property: StringName, key: String, action: StringName = &"") -> void:
	_texts.append([object, property, key, action])
	_set_text(object, property, key, action)


func _refresh_texts() -> void:
	for entry: Array in _texts:
		_set_text(entry[0], entry[1], String(entry[2]), entry[3])
	_update_clear_buttons()


static func _set_text(object: Object, property: StringName, key: String, action: StringName) -> void:
	var text: String = String(TranslationServer.translate(key)) if not key.is_empty() else ""
	if action != &"":
		var shortcut: String = Actions.shortcut_label(action)
		if not shortcut.is_empty():
			text = "%s (%s)" % [text, shortcut]
	object.set(property, text)


## Sizes each row of chips to hold them on as few lines as the popover's
## `max_width` allows, and each list of check rows to its rows up to
## `checks_max_height`: the containers would otherwise size to their
## widest chip or their first row.
func _fit() -> void:
	var max_width: float = float(get_theme_constant(&"max_width", THEME_TYPE))
	# A section of unnamed rows leaves its grid empty: no gap for it.
	for grid: Node in _sections.find_children("*", "GridContainer", true, false):
		(grid as GridContainer).visible = grid.get_child_count() > 0
	var label_width: float = 0.0
	var labels: Array[Label] = []
	for child: Node in _sections.find_children("*", "Label", true, false):
		var label: Label = child as Label
		if label.theme_type_variation == &"OptionsRowLabel":
			label.custom_minimum_size.x = 0.0
			label_width = maxf(label_width, label.get_combined_minimum_size().x)
			labels.append(label)
	# One label column across the sections (each has a grid of its own).
	for label: Label in labels:
		label.custom_minimum_size.x = label_width
	var room: float = max_width
	if _rows != null:
		room = maxf(0.0, max_width - label_width - float(_rows.get_theme_constant(&"h_separation")))
	for flow: HFlowContainer in _flows:
		var gap: float = float(flow.get_theme_constant(&"h_separation"))
		var line: float = 0.0
		for child: Node in flow.get_children():
			line += (child as Control).get_combined_minimum_size().x + (gap if line > 0.0 else 0.0)
		flow.custom_minimum_size.x = minf(line, max_width if flow in _spanning else room)
	var max_height: float = float(get_theme_constant(&"checks_max_height", THEME_TYPE))
	for scroll: ScrollContainer in _scrolls:
		var list: Control = scroll.get_child(0) as Control
		var natural: Vector2 = list.get_combined_minimum_size()
		scroll.custom_minimum_size = Vector2(minf(natural.x, max_width), minf(natural.y, max_height))


## Sizes and tints the sections' title icons.
func _apply_icon_theme() -> void:
	var icon_size: float = float(get_theme_constant(&"icon_size", &"OptionsSectionIcon"))
	var color: Color = get_theme_color(&"icon_color", &"OptionsSectionIcon")
	for glyph: TextureRect in _icons:
		glyph.custom_minimum_size = Vector2(icon_size, icon_size)
		glyph.self_modulate = color


func _give_back_focus() -> void:
	if is_instance_valid(return_focus) and return_focus.is_visible_in_tree():
		return_focus.grab_focus()


## Escape closes, whatever has the focus (the popover's own input, before
## its controls see the key).
func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel", false, true):
		set_input_as_handled()
		hide()
