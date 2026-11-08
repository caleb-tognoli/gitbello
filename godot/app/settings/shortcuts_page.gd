class_name ShortcutsPage
extends VBoxContainer
## The Keyboard page of Settings: every action with its shortcuts, grouped by
## category in folding sections. Click a shortcut's chip (or press Enter on it)
## and press the new keys; Escape cancels. A key another action already uses
## where this one works (see `ActionRegistry.contexts_overlap`) asks first:
## Reassign takes it from the other action. Hovering a row shows its clear
## and revert buttons; changed shortcuts have an accent dot.
##
## The toolbar filters by text, or with the keyboard button by pressing a
## shortcut, shows only the changed ones, and resets them all.

## Recording, choosing about a conflict or searching by keys: the page then
## owns Escape (the window must not close on it).
signal capturing_changed(on: bool)

const THEME_TYPE: StringName = &"ShortcutsPage"
const FILTER_FIELD: PackedScene = preload("res://ui/filter_field/filter_field.tscn")

var search: FilterField = FILTER_FIELD.instantiate() as FilterField
var key_search: Button
var changed_filter: Button = Button.new()
var reset_all: Button = Button.new()

var _scroll: ScrollContainer = ScrollContainer.new()
var _list: VBoxContainer = VBoxContainer.new()
var _empty: Label = Label.new()
var _confirm: ConfirmationDialog = ConfirmationDialog.new()
## id -> the row's controls (see `_add_row`).
var _rows: Dictionary[StringName, Dictionary] = {}
## Category (as shown) -> {header, button, count, ids}.
var _sections: Dictionary[String, Dictionary] = {}
var _collapsed: Dictionary[String, bool] = {}
## The action whose new shortcut is being pressed, or &"".
var _recording: StringName = &""
## {id, text, conflicts} while a clash waits for Reassign or Cancel.
var _pending: Dictionary = {}
var _key_mode: bool = false
## The shortcut pressed in key search, canonical.
var _key_query: String = ""
var _capturing: bool = false
var _refresh_queued: bool = false
var _built_ids: Array[StringName] = []


func _init() -> void:
	add_theme_constant_override(&"separation", 8)
	var toolbar: HBoxContainer = HBoxContainer.new()
	toolbar.theme_type_variation = &"ShortcutsToolbar"
	add_child(toolbar)
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(search)
	changed_filter.toggle_mode = true
	changed_filter.theme_type_variation = &"ToolbarButton"
	changed_filter.toggled.connect(func(_on: bool) -> void: _filter())
	toolbar.add_child(changed_filter)
	reset_all.theme_type_variation = &"ToolbarButton"
	reset_all.icon = AppTheme.icon(&"Reload")
	reset_all.pressed.connect(func() -> void: _confirm.popup_centered())
	toolbar.add_child(reset_all)

	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	AutoScroll.enable(_scroll)
	add_child(_scroll)
	var body: VBoxContainer = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(body)
	_list.add_theme_constant_override(&"separation", 0)
	body.add_child(_list)
	_empty.theme_type_variation = &"DimLabel"
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.custom_minimum_size.y = 80.0
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.hide()
	body.add_child(_empty)

	_confirm.confirmed.connect(Actions.reset_all_shortcuts)
	add_child(_confirm)
	Actions.actions_changed.connect(_queue_refresh)


func _ready() -> void:
	key_search = search.add_button(&"KeyCaps", "Search by keys")
	key_search.toggle_mode = true
	key_search.toggled.connect(set_key_search)
	search.changed.connect(func() -> void:
		if _key_mode and search.text().is_empty():
			_key_query = ""
		_filter())
	_confirm.get_ok_button().theme_type_variation = &"DangerButton"
	_translate()
	_rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_translate()
		_rebuild()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		cancel()


## Shows the page from the top with no filter.
func reset_view() -> void:
	cancel()
	set_key_search(false)
	search.set_text("")
	changed_filter.set_pressed_no_signal(false)
	_refresh()
	_scroll.scroll_vertical = 0


func focus_search() -> void:
	search.focus_text()


## Stops recording, a pending conflict and key search.
func cancel() -> void:
	_pending = {}
	_recording = &""
	_update_rows()
	_update_capturing()


## How many actions match `query` the way the filter field matches them.
func count_matches(query: String) -> int:
	var count: int = 0
	for id: StringName in _rows:
		if _matches_text(id, query.strip_edges().to_lower()):
			count += 1
	return count


## Turns searching by pressed keys on or off.
func set_key_search(on: bool) -> void:
	if key_search != null:
		key_search.set_pressed_no_signal(on)
	if on == _key_mode:
		return
	_key_mode = on
	_key_query = ""
	var box: LineEdit = search.text_box()
	box.editable = not on
	search.placeholder = tr("Press a shortcut…") if on else tr("Filter shortcuts")
	search.set_text("")
	if on:
		box.grab_focus()
	_update_capturing()
	_filter()


## Starts recording a new shortcut for `id`.
func record(id: StringName) -> void:
	if not _rows.has(id):
		return
	_pending = {}
	set_key_search(false)
	# Focus the first chip before the others go, so losing focus does not
	# stop the recording.
	var chip: Control = (_rows[id].chips as HBoxContainer).get_child(0) as Control
	chip.visible = true
	chip.grab_focus()
	_recording = id
	_update_rows()
	_update_capturing()


## Records `text` for `id` as if pressed (also used by tests): saves it, or
## asks first when another action uses the key.
func press(id: StringName, text: String) -> void:
	_recording = &""
	var clashes: Array[StringName] = Actions.conflicts(id, text)
	if clashes.is_empty():
		Actions.set_shortcut(id, text)
		_pending = {}
		_focus_chip(id)
	else:
		_pending = {"id": id, "text": text, "conflicts": clashes}
	_update_rows()
	_update_capturing()
	if not _pending.is_empty():
		(_rows[id].reassign as Button).grab_focus()


## Takes the pending key from the actions that use it and gives it to the
## action that asked for it.
func reassign() -> void:
	if _pending.is_empty():
		return
	var id: StringName = _pending.id
	var text: String = _pending.text
	for other: StringName in _pending.conflicts:
		Actions.release_shortcut(other, text)
	Actions.set_shortcut(id, text)
	_pending = {}
	_update_capturing()
	_focus_chip(id)


func row(id: StringName) -> Dictionary:
	return _rows.get(id, {})


func is_recording(id: StringName = &"") -> bool:
	return _recording != &"" and (id == &"" or _recording == id)


func pending() -> Dictionary:
	return _pending


## Whether `id`'s row shows with the current filters.
func is_row_shown(id: StringName) -> bool:
	return _rows.has(id) and (_rows[id].panel as Control).visible


func is_collapsed(category: String) -> bool:
	return _collapsed.get(category, false)


func toggle_section(category: String) -> void:
	_collapsed[category] = not is_collapsed(category)
	_filter()


func _input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if not _capturing or key == null or not key.pressed or key.echo or not is_visible_in_tree():
		return
	if not _pending.is_empty():
		# Enter goes to the focused Reassign or Cancel button.
		if key.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			var id: StringName = _pending.id
			cancel()
			_focus_chip(id)
		return
	get_viewport().set_input_as_handled()
	if key.keycode == KEY_ESCAPE:
		if _recording != &"":
			var id: StringName = _recording
			cancel()
			_focus_chip(id)
		else:
			set_key_search(false)
			search.focus_text()
		return
	var text: String = Shortcuts.from_event(key)
	if text.is_empty() or Shortcuts.parse(text) == null:
		return # a modifier alone: wait for the key
	if _recording != &"":
		press(_recording, text)
	else:
		_key_query = text
		search.set_text(Shortcuts.display(text))


func _queue_refresh() -> void:
	if not _refresh_queued:
		_refresh_queued = true
		_refresh.call_deferred()


func _refresh() -> void:
	_refresh_queued = false
	var ids: Array[StringName] = []
	for action: ActionRegistry.Action in Actions.with_shortcuts():
		ids.append(action.id)
	if ids != _built_ids:
		_rebuild()
		return
	for action: ActionRegistry.Action in Actions.with_shortcuts():
		(_rows[action.id].label as Label).text = action.label
	_update_rows()


func _rebuild() -> void:
	_refresh_queued = false
	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_rows.clear()
	_sections.clear()
	_built_ids.clear()
	for action: ActionRegistry.Action in Actions.with_shortcuts():
		if not _sections.has(action.category):
			_add_section(action.category)
		_add_row(action)
		(_sections[action.category].ids as Array).append(action.id)
		_built_ids.append(action.id)
	_update_rows()


func _add_section(category: String) -> void:
	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override(&"separation", 6)
	if not _sections.is_empty():
		var gap: Control = Control.new()
		gap.custom_minimum_size.y = 8.0
		_list.add_child(gap)
		header.set_meta(&"gap", gap)
	var button: Button = Button.new()
	button.theme_type_variation = &"ShortcutSection"
	button.text = category
	button.pressed.connect(func() -> void: toggle_section(category))
	header.add_child(button)
	var count: Label = Label.new()
	count.theme_type_variation = &"ShortcutSectionCount"
	header.add_child(count)
	var line: HSeparator = HSeparator.new()
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(line)
	_list.add_child(header)
	_sections[category] = {"header": header, "button": button, "count": count, "ids": []}


## A row: icon, label, context tag, changed dot, the chips, then the clear and
## revert buttons; a conflict strip under it while a clash waits.
func _add_row(action: ActionRegistry.Action) -> void:
	var id: StringName = action.id
	var panel: PanelContainer = PanelContainer.new()
	panel.theme_type_variation = &"ShortcutRow"
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var lines: VBoxContainer = VBoxContainer.new()
	lines.theme_type_variation = &"ShortcutRowLines"
	panel.add_child(lines)
	var main: HBoxContainer = HBoxContainer.new()
	main.add_theme_constant_override(&"separation", 8)
	main.custom_minimum_size.y = get_theme_constant(&"row_height", THEME_TYPE)
	lines.add_child(main)

	var icon_size: int = get_theme_constant(&"icon_size", THEME_TYPE)
	var icon: TextureRect = TextureRect.new()
	icon.texture = Actions.icon(id)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(icon_size, icon_size)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main.add_child(icon)
	var label: Label = Label.new()
	label.text = action.label
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	main.add_child(label)
	var context: Label = Label.new()
	context.theme_type_variation = &"ShortcutContext"
	context.text = tr(String(action.context))
	# No tag where the section already says it (Changes under Changes).
	context.visible = action.context != ActionRegistry.GLOBAL and context.text != action.category
	context.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	context.mouse_filter = Control.MOUSE_FILTER_PASS
	context.tooltip_text = tr("Works in %s") % context.text
	main.add_child(context)

	var dot_size: int = get_theme_constant(&"dot_size", THEME_TYPE)
	var dot_slot: CenterContainer = CenterContainer.new()
	dot_slot.custom_minimum_size.x = dot_size + 4
	dot_slot.mouse_filter = Control.MOUSE_FILTER_PASS
	main.add_child(dot_slot)
	var dot: Panel = Panel.new()
	dot.theme_type_variation = &"ShortcutModified"
	dot.custom_minimum_size = Vector2(dot_size, dot_size)
	dot.mouse_filter = Control.MOUSE_FILTER_PASS
	dot.tooltip_text = tr("Changed from the default")
	dot_slot.add_child(dot)

	var chips: HBoxContainer = HBoxContainer.new()
	chips.add_theme_constant_override(&"separation", 4)
	chips.alignment = BoxContainer.ALIGNMENT_END
	chips.custom_minimum_size.x = get_theme_constant(&"chip_width", THEME_TYPE)
	chips.mouse_filter = Control.MOUSE_FILTER_PASS
	main.add_child(chips)
	var clear: Button = _slot_button(main, &"Close", "Remove shortcut")
	clear.pressed.connect(func() -> void:
		cancel()
		Actions.set_shortcut(id, "none"))
	var revert: Button = _slot_button(main, &"Reload", "Revert to the default")
	revert.pressed.connect(func() -> void:
		cancel()
		Actions.set_shortcut(id, ""))

	var conflict: PanelContainer = PanelContainer.new()
	conflict.theme_type_variation = &"ShortcutConflict"
	conflict.hide()
	lines.add_child(conflict)
	var strip: HBoxContainer = HBoxContainer.new()
	strip.add_theme_constant_override(&"separation", 6)
	conflict.add_child(strip)
	var warning: TextureRect = TextureRect.new()
	warning.texture = AppTheme.icon(&"StatusWarning")
	warning.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	strip.add_child(warning)
	var message: Label = Label.new()
	message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	strip.add_child(message)
	var reassign_button: Button = Button.new()
	reassign_button.text = tr("Reassign")
	reassign_button.theme_type_variation = &"PrimaryButton"
	reassign_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	reassign_button.pressed.connect(reassign)
	strip.add_child(reassign_button)
	var cancel_button: Button = Button.new()
	cancel_button.text = tr("Cancel")
	cancel_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cancel_button.pressed.connect(func() -> void:
		cancel()
		_focus_chip(id))
	strip.add_child(cancel_button)

	_list.add_child(panel)
	var parts: Dictionary = {
		"panel": panel, "label": label, "context": context, "dot": dot, "chips": chips,
		"clear": clear, "revert": revert, "conflict": conflict, "message": message,
		"reassign": reassign_button, "category": action.category, "hovered": false,
	}
	_rows[id] = parts
	panel.mouse_entered.connect(func() -> void:
		parts.hovered = true
		_update_row(id))
	panel.mouse_exited.connect(func() -> void:
		parts.hovered = false
		_update_row(id))


func _slot_button(row_box: HBoxContainer, icon_name: StringName, tooltip: String) -> Button:
	var slot: CenterContainer = CenterContainer.new()
	slot.custom_minimum_size.x = get_theme_constant(&"slot_width", THEME_TYPE)
	slot.mouse_filter = Control.MOUSE_FILTER_PASS
	row_box.add_child(slot)
	var button: Button = Button.new()
	button.icon = AppTheme.icon(icon_name)
	button.theme_type_variation = &"ToolbarButton"
	button.tooltip_text = tr(tooltip)
	button.set_meta(&"tooltip", tooltip)
	button.focus_mode = Control.FOCUS_NONE
	slot.add_child(button)
	return button


func _update_rows() -> void:
	for id: StringName in _rows:
		_update_row(id)
	var changed: int = Actions.modified_count()
	changed_filter.text = tr("Changed") if changed == 0 else "%s  %d" % [tr("Changed"), changed]
	reset_all.disabled = changed == 0
	_filter()


func _update_row(id: StringName) -> void:
	if not _rows.has(id):
		return
	var parts: Dictionary = _rows[id]
	var shortcuts: PackedStringArray = Actions.shortcuts(id)
	var modified: bool = Actions.is_modified(id)
	var chips: HBoxContainer = parts.chips
	var waiting: bool = not _pending.is_empty() and _pending.id == id
	var texts: PackedStringArray = shortcuts
	if _recording == id or waiting:
		texts = PackedStringArray([_pending.text if waiting else ""])
	elif texts.is_empty():
		texts = PackedStringArray([""])
	# Reuse the chips so the focused one keeps focus.
	while chips.get_child_count() > texts.size():
		var extra: Node = chips.get_child(chips.get_child_count() - 1)
		chips.remove_child(extra)
		extra.queue_free()
	while chips.get_child_count() < texts.size():
		var chip: ShortcutChip = ShortcutChip.new()
		chip.activated.connect(func() -> void: record(id))
		chip.focus_entered.connect(func() -> void: _update_row.call_deferred(id))
		chip.focus_exited.connect(func() -> void: _on_chip_focus_exited(id))
		chips.add_child(chip)
	var focused: bool = false
	for i: int in texts.size():
		var chip: ShortcutChip = chips.get_child(i) as ShortcutChip
		chip.set_shortcut(texts[i])
		var state: ShortcutChip.State = ShortcutChip.State.NORMAL
		if _recording == id:
			state = ShortcutChip.State.RECORDING
		elif waiting:
			state = ShortcutChip.State.CONFLICT
		if chip.state != state:
			chip.set_state(state)
		chip.tooltip_text = tr("Change shortcut") if not texts[i].is_empty() else tr("Add shortcut")
		focused = focused or chip.has_focus()
	var active: bool = bool(parts.hovered) or focused or _recording == id or waiting
	# The Add chip shows only on a hovered or focused row.
	if shortcuts.is_empty() and _recording != id and not waiting:
		(chips.get_child(0) as Control).visible = active
	else:
		(chips.get_child(0) as Control).visible = true
	(parts.dot as Control).visible = modified
	(parts.clear as Control).visible = active and not shortcuts.is_empty() and _recording != id and not waiting
	(parts.revert as Control).visible = active and modified and _recording != id and not waiting
	(parts.panel as PanelContainer).theme_type_variation = &"ShortcutRowHover" if active else &"ShortcutRow"
	var conflict: Control = parts.conflict
	conflict.visible = waiting
	if waiting:
		var names: PackedStringArray = PackedStringArray()
		for other: StringName in _pending.conflicts:
			var action: ActionRegistry.Action = Actions.get_action(other)
			names.append("%s → %s" % [action.category, action.label])
		(parts.message as Label).text = tr("%s is already used by %s") % [
				Shortcuts.display(String(_pending.text)), ", ".join(names)]


func _on_chip_focus_exited(id: StringName) -> void:
	# Clicking elsewhere stops recording (not a conflict: its buttons take focus).
	if _recording == id:
		_recording = &""
		_update_capturing()
	_update_row.call_deferred(id)


func _focus_chip(id: StringName) -> void:
	if _rows.has(id):
		_update_row(id)
		var chip: Control = (_rows[id].chips as HBoxContainer).get_child(0) as Control
		if chip != null and chip.is_visible_in_tree():
			chip.grab_focus()


func _update_capturing() -> void:
	var on: bool = _recording != &"" or not _pending.is_empty() or _key_mode
	if on != _capturing:
		_capturing = on
		capturing_changed.emit(on)


func _matches_text(id: StringName, query: String) -> bool:
	if query.is_empty():
		return true
	var action: ActionRegistry.Action = Actions.get_action(id)
	if action == null:
		return false
	var shortcuts: PackedStringArray = Actions.shortcuts(id)
	var shown: PackedStringArray = PackedStringArray()
	for shortcut: String in shortcuts:
		shown.append(Shortcuts.display(shortcut))
	var described: String = " ".join([action.label, action.category, tr(String(action.context)),
			" ".join(shortcuts), " ".join(shown), String(id)])
	return query in described.to_lower()


func _matches_keys(id: StringName) -> bool:
	if _key_query.is_empty():
		return true
	var event: InputEventKey = Shortcuts.parse(_key_query)
	for shortcut: String in Actions.shortcuts(id):
		if Shortcuts.matches(event, Shortcuts.parse(shortcut)):
			return true
	return false


func _filter() -> void:
	if not is_node_ready():
		return
	var query: String = "" if _key_mode else search.text().strip_edges().to_lower()
	var filtering: bool = not query.is_empty() or not _key_query.is_empty() or changed_filter.button_pressed
	var any: bool = false
	for category: String in _sections:
		var section: Dictionary = _sections[category]
		var matched: int = 0
		for id: StringName in section.ids:
			var shown: bool = _matches_text(id, query) and _matches_keys(id) \
					and (not changed_filter.button_pressed or Actions.is_modified(id))
			# Keep the row being edited in view whatever the filter says.
			shown = shown or _recording == id or (not _pending.is_empty() and _pending.id == id)
			if shown:
				matched += 1
			(_rows[id].panel as Control).visible = shown and (filtering or not is_collapsed(category))
		var header: Control = section.header
		header.visible = matched > 0
		if header.has_meta(&"gap"):
			(header.get_meta(&"gap") as Control).visible = matched > 0
		(section.count as Label).text = str(matched)
		var button: Button = section.button
		button.icon = AppTheme.ARROW_RIGHT if is_collapsed(category) and not filtering else AppTheme.ARROW_DOWN
		any = any or matched > 0
	_empty.visible = not any
	_empty.text = tr("No shortcuts use these keys") if not _key_query.is_empty() else tr("No shortcuts match")


func _translate() -> void:
	search.placeholder = tr("Press a shortcut…") if _key_mode else tr("Filter shortcuts")
	if key_search != null:
		key_search.tooltip_text = tr("Search by keys")
	changed_filter.tooltip_text = tr("Show only the shortcuts you changed")
	reset_all.text = tr("Reset All…")
	reset_all.tooltip_text = tr("Restore every shortcut to its default")
	_confirm.title = tr("Reset shortcuts")
	_confirm.dialog_text = tr("Restore every shortcut to its default?")
	_confirm.ok_button_text = tr("Reset")
	_confirm.cancel_button_text = tr("Cancel")
