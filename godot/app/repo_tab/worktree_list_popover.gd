class_name WorktreeListPopover
extends PopupPanel
## The strip's list of every worktree (its worktree icon), like the branch
## list: a filter, then one row each with its marker, folder and branch, the
## changed files and the commits to push and pull in pills (`SyncCounts`),
## the shown worktree's row highlighted, then the worktree actions: New
## worktree and From branch, Clean up and, while a folder is missing, Prune.
## Typing filters by folder or branch; Enter chooses the first match (the
## shown worktree when there is no filter), Down moves into the rows and Up on
## the first row back to the filter. Click or Enter on a row emits `chosen`,
## right-click or the menu key `menu_requested`; Escape returns focus to where
## it was. Each row's tooltip says its path and state.

## A row was chosen: show worktree `path`.
signal chosen(path: String)
## Right-click or the menu key on a row; `at_position` is on the screen.
signal menu_requested(worktree: Dictionary, at_position: Vector2)

const THEME_TYPE: StringName = &"WorktreeList"
const FILTER_FIELD: PackedScene = preload("res://ui/filter_field/filter_field.tscn")
## The footer's actions: `[id, icon, with its label]`.
const FOOTER: Array[Array] = [[&"task.new", &"Add", true], [&"worktree.add_existing", &"GitBranch", true],
	[&"", &"", false], [&"worktree.cleanup", &"Clear", false], [&"worktree.prune", &"StatusWarning", false]]

var _box: VBoxContainer = VBoxContainer.new()
var _filter: FilterField = FILTER_FIELD.instantiate() as FilterField
var _scroll: ScrollContainer = ScrollContainer.new()
var _rows: VBoxContainer = VBoxContainer.new()
var _empty: Label = Label.new()
var _footer: HBoxContainer = HBoxContainer.new()
var _footer_buttons: Dictionary[StringName, Button] = {}
## The row Enter in the filter chooses.
var _target: Button = null
## The row of the shown worktree.
var _selected_row: Button = null
## Takes the focus back when the list closes without a choice.
var _return_focus: Control = null
## The control the footer's actions start from.
var _anchor: Control = null
var _chose: bool = false
## The anchor window's UI scale, for the popup's size.
var _scale: float = 1.0


func _ready() -> void:
	theme_type_variation = &"WorktreeListPanel"
	_box.theme_type_variation = &"WorktreeListBox"
	add_child(_box)
	_filter.changed.connect(_apply_filter)
	_filter.submitted.connect(func(_backwards: bool) -> void:
		if _target != null:
			_target.pressed.emit())
	_filter.done.connect(func() -> void:
		if _target != null:
			_target.grab_focus())
	_box.add_child(_filter)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	AutoScroll.enable(_scroll)
	_box.add_child(_scroll)
	_rows.theme_type_variation = &"WorktreeListRows"
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows)
	_empty.theme_type_variation = &"DimLabel"
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.custom_minimum_size.y = float(get_theme_constant(&"empty_height", THEME_TYPE))
	_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty.hide()
	_box.add_child(_empty)
	_box.add_child(HSeparator.new())
	_footer.theme_type_variation = &"WorktreeListFooter"
	_box.add_child(_footer)
	for entry: Array in FOOTER:
		var id: StringName = entry[0]
		if id == &"":
			var spacer: Control = Control.new()
			spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_footer.add_child(spacer)
			continue
		var button: Button = Button.new()
		button.icon = AppTheme.icon(entry[1])
		button.theme_type_variation = &"ToolbarButton"
		button.focus_mode = Control.FOCUS_ALL
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.set_meta(&"labelled", entry[2])
		button.pressed.connect(func() -> void: _run(id))
		_footer.add_child(button)
		_footer_buttons[id] = button
	_footer_buttons[&"worktree.prune"].add_theme_color_override(&"icon_normal_color",
			get_theme_color(&"warning_color", THEME_TYPE))
	_footer_buttons[&"worktree.prune"].add_theme_color_override(&"icon_hover_color",
			get_theme_color(&"warning_color", THEME_TYPE))
	# The footer reads its actions when the list opens.
	_filter.placeholder = tr("Filter worktrees")
	popup_hide.connect(func() -> void:
		if not _chose and is_instance_valid(_return_focus) and _return_focus.is_inside_tree():
			_return_focus.grab_focus())


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		if visible:
			_update_texts()
		else:
			_filter.placeholder = tr("Filter worktrees")
		for row: Node in _rows.get_children():
			(row as Button).tooltip_text = _tooltip(row.get_meta(&"worktree") as Dictionary)


## Opens under `anchor` with a row per `worktrees` (rows of
## `RepoSession.worktrees()`), `selected_path`'s highlighted, and the focus in
## an empty filter.
func open_below(anchor: Control, worktrees: Array[Dictionary], selected_path: String) -> void:
	_return_focus = anchor if anchor.has_focus() else null
	_anchor = anchor
	_chose = false
	fill(worktrees, selected_path)
	_update_texts()
	_scale = anchor.get_window().content_scale_factor
	var at: Vector2 = anchor.get_screen_transform() * Vector2(0.0, anchor.size.y)
	# The width fits every row, so filtering does not change it.
	_box.custom_minimum_size.x = maxf(float(get_theme_constant(&"width", THEME_TYPE)),
			_rows.get_combined_minimum_size().x)
	popup(Rect2i(Vector2i(at), Vector2i.ZERO))
	_fit()
	_filter.focus_text()


## Builds the rows with an empty filter; returns the selected worktree's
## (else the first) row.
func fill(worktrees: Array[Dictionary], selected_path: String) -> Button:
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	_selected_row = null
	var first: Button = null
	for wt: Dictionary in worktrees:
		var row: Button = _row(wt, Paths.same(String(wt["path"]), selected_path))
		_rows.add_child(row)
		if first == null:
			first = row
		if row.button_pressed:
			_selected_row = row
	if _selected_row == null:
		_selected_row = first
	_filter.set_text("")
	return _selected_row


## Filters the rows by folder or branch name (as typing would).
func set_filter(text: String) -> void:
	_filter.set_text(text)


func filter_field() -> FilterField:
	return _filter


## The footer button of action `id` (for tests).
func footer_button(id: StringName) -> Button:
	return _footer_buttons.get(id) as Button


## The row Enter in the filter would choose, as its index among the shown
## rows, or -1 (for tests).
func target_index() -> int:
	return _shown_rows().find(_target)


## The text shown when no row matches, or "" (for tests).
func empty_text() -> String:
	return _empty.text if _empty.visible else ""


## The shown row with the focus, or -1.
func focused_index() -> int:
	var focused: Control = _rows.get_viewport().gui_get_focus_owner()
	return _shown_rows().find(focused) if focused is Button else -1


## Chooses shown row `index` as a click would.
func choose(index: int) -> void:
	_shown_rows()[index].pressed.emit()


## The shown rows, for tests: `name`, `branch`, `changes`, `ahead`, `behind`,
## the `marker` icon, the `tooltip` and whether it is the `selected` one.
func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row: Button in _shown_rows():
		var counts: SyncCounts = row.find_child("Counts", true, false) as SyncCounts
		out.append({
			"name": (row.find_child("Name", true, false) as Label).text,
			"branch": (row.find_child("Branch", true, false) as Label).text,
			"changes": (row.find_child("Changes", true, false) as Label).text,
			"ahead": counts.ahead, "behind": counts.behind,
			"marker": String(row.get_meta(&"marker")), "tooltip": row.tooltip_text,
			"selected": row.button_pressed,
		})
	return out


func _shown_rows() -> Array[Button]:
	var out: Array[Button] = []
	for row: Node in _rows.get_children():
		if (row as Button).visible and not row.is_queued_for_deletion():
			out.append(row as Button)
	return out


## Shows the rows whose folder or branch contains the filter; the first match
## (or, with no filter, the shown worktree) is what Enter chooses.
func _apply_filter() -> void:
	var query: String = _filter.text().strip_edges().to_lower()
	_target = null
	for node: Node in _rows.get_children():
		var row: Button = node as Button
		var wt: Dictionary = row.get_meta(&"worktree") as Dictionary
		row.visible = query.is_empty() or String(wt["name"]).to_lower().contains(query) \
				or _branch_text(wt).to_lower().contains(query)
		if row.visible and _target == null and not query.is_empty():
			_target = row
	if query.is_empty():
		_target = _selected_row
	# A match Enter would choose looks hovered.
	for node: Node in _rows.get_children():
		var row: Button = node as Button
		row.theme_type_variation = &"WorktreeListRowTarget" if row == _target and not query.is_empty() \
				else &"WorktreeListRow"
	_empty.text = tr("No matching worktrees")
	_empty.visible = _target == null
	_scroll.visible = not _empty.visible
	if _target != null:
		_reveal.call_deferred(_target)
	_fit()


## Scrolls `row` into view unless a refill has dropped it meanwhile.
func _reveal(row: Button) -> void:
	if is_instance_valid(row) and row.get_parent() == _rows and row.visible:
		_scroll.ensure_control_visible(row)


## Sizes the list to its shown rows, up to the theme's `max_height`.
func _fit() -> void:
	if not visible:
		return
	var content: float = 0.0
	var shown: Array[Button] = _shown_rows()
	for row: Button in shown:
		content += row.get_combined_minimum_size().y
	content += float(_rows.get_theme_constant(&"separation")) * maxf(0.0, float(shown.size() - 1))
	_scroll.custom_minimum_size.y = minf(content, float(get_theme_constant(&"max_height", THEME_TYPE)))
	reset_size()
	size = Vector2i(Vector2(get_contents_minimum_size()) * _scale)


func _update_texts() -> void:
	_filter.placeholder = tr("Filter worktrees")
	for id: StringName in _footer_buttons:
		var button: Button = _footer_buttons[id]
		var action: ActionRegistry.Action = Actions.get_action(id)
		if action == null:
			button.hide()
			continue
		var enabled: bool = action.is_enabled()
		button.text = (tr("From branch…") if id == &"worktree.add_existing" else action.label) \
				if bool(button.get_meta(&"labelled")) else ""
		button.tooltip_text = Actions.tooltip(id)
		button.disabled = not enabled
		# Prune only shows while a folder is missing.
		button.visible = enabled or id != &"worktree.prune"


## Closes the list and runs action `id` from the strip's icon.
func _run(id: StringName) -> void:
	_chose = true
	hide()
	Actions.run_action(id, _anchor if is_instance_valid(_anchor) else null)


func _row(wt: Dictionary, selected: bool) -> Button:
	var row: Button = Button.new()
	row.theme_type_variation = &"WorktreeListRow"
	row.toggle_mode = true
	row.set_pressed_no_signal(selected)
	row.focus_mode = Control.FOCUS_ALL
	row.tooltip_text = _tooltip(wt)
	row.set_meta(&"worktree", wt)
	var path: String = String(wt["path"])
	row.pressed.connect(func() -> void:
		_chose = true
		hide()
		chosen.emit(path))
	row.gui_input.connect(func(event: InputEvent) -> void: _on_row_input(row, event))
	var line: HBoxContainer = HBoxContainer.new()
	line.theme_type_variation = &"WorktreeListLine"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(line)
	var marker: TextureRect = TextureRect.new()
	row.set_meta(&"marker", _marker(wt))
	marker.texture = AppTheme.icon(_marker(wt))
	marker.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	marker.modulate = get_theme_color(&"conflict_color", &"WorktreeChip") if _marker(wt) == &"GitConflict" \
			else get_theme_color(&"icon_color", THEME_TYPE)
	line.add_child(marker)
	var name_label: Label = _label("Name", String(wt["name"]), &"")
	line.add_child(name_label)
	var branch: Label = _label("Branch", _branch_text(wt), &"DimLabel")
	branch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# A long branch name is cut short; the tooltip has the folder's path.
	var widest: float = float(get_theme_constant(&"branch_width", THEME_TYPE))
	if branch.get_minimum_size().x > widest:
		branch.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		branch.custom_minimum_size.x = widest
	line.add_child(branch)
	var changed: int = int(wt["changed"])
	line.add_child(_label("Changes", str(changed) if changed > 0 else "", &"WorktreeListChanges"))
	var counts: SyncCounts = SyncCounts.new()
	counts.name = "Counts"
	counts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	counts.set_counts(int(wt.get("ahead", 0)), int(wt.get("behind", 0)))
	line.add_child(counts)
	# A button's children don't size it: make room for the line.
	var style: StyleBox = row.get_theme_stylebox(&"normal")
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_left = style.get_margin(SIDE_LEFT)
	line.offset_top = style.get_margin(SIDE_TOP)
	line.offset_right = -style.get_margin(SIDE_RIGHT)
	line.offset_bottom = -style.get_margin(SIDE_BOTTOM)
	row.custom_minimum_size = line.get_combined_minimum_size() + style.get_minimum_size()
	return row


## Up on the first row goes back to the filter; right-click or the menu key
## asks for the worktree's menu.
func _on_row_input(row: Button, event: InputEvent) -> void:
	var wt: Dictionary = row.get_meta(&"worktree") as Dictionary
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT:
		menu_requested.emit(wt, row.get_screen_transform() * mouse.position)
		row.accept_event()
		return
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_MENU:
		menu_requested.emit(wt, row.get_screen_transform() * Vector2(0.0, row.size.y))
		row.accept_event()
		return
	if event.is_action_pressed("ui_up", false, true):
		var shown: Array[Button] = _shown_rows()
		if not shown.is_empty() and shown[0] == row:
			_filter.focus_text()
			row.accept_event()


func _label(node_name: String, text: String, variation: StringName) -> Label:
	var label: Label = Label.new()
	label.name = node_name
	label.text = text
	label.theme_type_variation = variation
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.visible = not text.is_empty()
	return label


## A missing folder, an operation or conflicts, a lock, else the worktree icon.
static func _marker(wt: Dictionary) -> StringName:
	if bool(wt["prunable"]):
		return &"StatusWarning"
	if int(wt.get("conflicts", 0)) > 0 or not String(wt.get("operation", "")).is_empty():
		return &"GitConflict"
	if bool(wt["locked"]):
		return &"Lock"
	return &"GitWorktree"


func _branch_text(wt: Dictionary) -> String:
	if bool(wt["detached"]):
		return tr("detached %s") % String(wt["head"]).left(7)
	return String(wt["branch"])


func _tooltip(wt: Dictionary) -> String:
	var lines: PackedStringArray = PackedStringArray([String(wt["path"])])
	var changed: int = int(wt["changed"])
	if changed > 0:
		lines.append(tr("1 changed file") if changed == 1 else tr("%d changed files") % changed)
	var conflicts: int = int(wt.get("conflicts", 0))
	if conflicts > 0:
		lines.append(tr("1 conflicted file") if conflicts == 1 else tr("%d conflicted files") % conflicts)
	var ahead: int = int(wt.get("ahead", 0))
	if ahead > 0:
		lines.append(tr("1 commit ahead") if ahead == 1 else tr("%d commits ahead") % ahead)
	var behind: int = int(wt.get("behind", 0))
	if behind > 0:
		lines.append(tr("1 commit behind") if behind == 1 else tr("%d commits behind") % behind)
	var operation: String = String(wt.get("operation", ""))
	if not operation.is_empty():
		lines.append(tr("%s in progress") % tr(operation.capitalize()))
	if bool(wt["locked"]):
		var reason: String = String(wt["lock_reason"])
		lines.append(tr("Locked") + (": " + reason if not reason.is_empty() else ""))
	if bool(wt["prunable"]):
		lines.append(tr("The folder is missing."))
	return "\n".join(lines)
