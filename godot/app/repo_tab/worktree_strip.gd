class_name WorktreeStrip
extends PanelContainer
## The row of worktree chips at the top of a repository tab (PLAN §4): a
## worktree icon that lists them all, the main worktree, a thin line, the
## linked ones by folder name, then + (new worktree) right after the last
## chip, with a ▾ for cleanup, adding a worktree for a branch and pruning.
## When the chips do not fit, the row scrolls.

## A chip was activated: show worktree `path`.
signal worktree_chosen(path: String)
## A chip's context menu was requested; `at_position` is on the screen.
signal worktree_menu_requested(worktree: Dictionary, at_position: Vector2)
## A chip was middle-clicked: show its folder.
signal worktree_reveal_requested(worktree: Dictionary)

const TASK_MENU: Array[StringName] = [&"worktree.cleanup", &"worktree.add_existing", &"", &"worktree.prune"]

var _row: HBoxContainer = HBoxContainer.new()
var _scroll: ScrollContainer = ScrollContainer.new()
var _chips: HBoxContainer = HBoxContainer.new()
## Between the main worktree's chip and the linked ones.
var _separator: VSeparator = VSeparator.new()
## Takes the room right of the buttons while the chips fit.
var _spacer: Control = Control.new()
## New worktree and its ▾, joined into one split chip.
var _actions: HBoxContainer = HBoxContainer.new()
var _new_task: Button = Button.new()
var _task_menu_button: Button = Button.new()
var _task_menu: PopupMenu = PopupMenu.new()
var _task_ids: Array[StringName] = []
## The worktree icon starting the row: lists every worktree.
var _list_button: Button = Button.new()
var _all_menu: PopupMenu = PopupMenu.new()
var _worktrees: Array[Dictionary] = []
var _selected: String = ""
var _reveal_pending: bool = false
var _revealed_path: String = ""
var _revealed_layout: Array[Rect2] = []


func _ready() -> void:
	theme_type_variation = &"WorktreeStrip"
	add_child(_row)
	_row.resized.connect(_update_overflow)
	_scroll.resized.connect(_queue_reveal)
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.follow_focus = true
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chips.theme_type_variation = &"ChipRow"
	_chips.minimum_size_changed.connect(_update_overflow)
	_chips.sort_children.connect(_queue_reveal)
	_separator.theme_type_variation = &"ChipSeparator"
	_separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_separator.hide()
	_chips.add_child(_separator)
	_list_button.icon = AppTheme.icon(&"GitWorktree")
	_list_button.theme_type_variation = &"WorktreeRowIcon"
	_list_button.focus_mode = Control.FOCUS_ALL
	_list_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_list_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_list_button.pressed.connect(_open_all_menu)
	_row.add_child(_list_button)
	_scroll.add_child(_chips)
	_row.add_child(_scroll)
	_actions.theme_type_variation = &"ChipSplit"
	_actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_row.add_child(_actions)
	_new_task.icon = AppTheme.icon(&"Add")
	_update_tooltips()
	_new_task.theme_type_variation = &"ChipAction"
	_new_task.focus_mode = Control.FOCUS_ALL
	_new_task.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_new_task.pressed.connect(func() -> void: Actions.run_action(&"task.new", _new_task))
	_actions.add_child(_new_task)
	_task_menu_button.icon = AppTheme.ARROW_DOWN
	_task_menu_button.tooltip_text = "More worktree actions"
	_task_menu_button.theme_type_variation = &"ChipActionMenu"
	_task_menu_button.focus_mode = Control.FOCUS_ALL
	_task_menu_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_task_menu_button.pressed.connect(_open_task_menu)
	_actions.add_child(_task_menu_button)
	_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(_spacer)
	add_child(_task_menu)
	_task_menu.id_pressed.connect(func(id: int) -> void: Actions.run_action(_task_ids[id]))
	_all_menu.theme_type_variation = &"WorktreeListMenu"
	add_child(_all_menu)
	_all_menu.id_pressed.connect(func(id: int) -> void:
		worktree_chosen.emit(String(_worktrees[id]["path"])))
	_update_overflow()


## Shows `worktrees` (rows of `RepoSession.worktrees()`) with `selected_path`'s
## chip selected.
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_update_tooltips()
		if _all_menu.visible:
			_open_all_menu()


func _update_tooltips() -> void:
	_list_button.tooltip_text = tr("Worktrees")
	var shortcut: String = Actions.shortcut_label(&"task.new")
	_new_task.tooltip_text = tr("New worktree") + (" (%s)" % shortcut if not shortcut.is_empty() else "")
	_task_menu_button.tooltip_text = tr("More worktree actions")


func show_worktrees(worktrees: Array[Dictionary], selected_path: String) -> void:
	var focused: WorktreeChip = get_viewport().gui_get_focus_owner() as WorktreeChip
	var focused_path: String = focused.path() if focused != null and focused.get_parent() == _chips else ""
	_worktrees = _ordered(worktrees)
	_selected = selected_path
	var existing: Array[WorktreeChip] = chips()
	var restore: WorktreeChip = null
	var selected_chip: WorktreeChip = null
	for i: int in _worktrees.size():
		var chip: WorktreeChip = existing[i] if i < existing.size() else null
		if chip == null:
			chip = WorktreeChip.new()
			chip.chosen.connect(func() -> void: worktree_chosen.emit(chip.path()))
			chip.menu_requested.connect(func(at: Vector2) -> void:
				worktree_menu_requested.emit(chip.worktree, at))
			chip.reveal_requested.connect(func() -> void: worktree_reveal_requested.emit(chip.worktree))
			_chips.add_child(chip)
		chip.set_worktree(_worktrees[i])
		chip.selected = Paths.same(chip.path(), selected_path)
		if chip.selected:
			selected_chip = chip
		if Paths.same(chip.path(), focused_path):
			restore = chip
	for i: int in range(_worktrees.size(), existing.size()):
		existing[i].hide()
		existing[i].queue_free()
	_separator.visible = _worktrees.size() > 1 and bool(_worktrees[0]["is_main"])
	_chips.move_child(_separator, mini(1, _chips.get_child_count() - 1))
	if not focused_path.is_empty():
		if restore != null:
			restore.grab_focus()
		elif selected_chip != null:
			selected_chip.grab_focus()
		else:
			_new_task.grab_focus()
	_update_overflow()


func chips() -> Array[WorktreeChip]:
	var out: Array[WorktreeChip] = []
	for node: Node in _chips.get_children():
		if node is WorktreeChip and not node.is_queued_for_deletion():
			out.append(node as WorktreeChip)
	return out


## The path of chip `index` (0-based, in strip order), or "".
func path_at(index: int) -> String:
	return String(_worktrees[index]["path"]) if index >= 0 and index < _worktrees.size() else ""


func new_task_button() -> Button:
	return _new_task


func list_button() -> Button:
	return _list_button


## Whether the chips are wider than the strip (it then scrolls).
func overflows() -> bool:
	return not _spacer.visible


## The main worktree first, then the linked ones by folder name.
static func _ordered(worktrees: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for wt: Dictionary in worktrees:
		if not bool(wt["bare"]):
			out.append(wt)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a["is_main"]) != bool(b["is_main"]):
			return bool(a["is_main"])
		return String(a["name"]).naturalnocasecmp_to(String(b["name"])) < 0)
	return out


## While the chips fit, the scroll gets their own width and the spacer the
## rest, so the buttons follow the last chip; past that the scroll takes it
## all (the worktree icon still lists every worktree).
func _update_overflow() -> void:
	var natural: float = _chips.get_combined_minimum_size().x + _scroll.get_combined_minimum_size().x + 1.0
	var room: float = _row.size.x - _actions.get_combined_minimum_size().x \
			- _list_button.get_combined_minimum_size().x - 3.0 * float(_row.get_theme_constant(&"separation"))
	var fits: bool = natural <= room
	_spacer.visible = fits
	_scroll.size_flags_stretch_ratio = natural
	_spacer.size_flags_stretch_ratio = maxf(room - natural, 1.0)
	_queue_reveal()


func _queue_reveal() -> void:
	if _reveal_pending or not is_inside_tree():
		return
	_reveal_pending = true
	await get_tree().process_frame
	await get_tree().process_frame
	_reveal_pending = false
	var layout: Array[Rect2] = [Rect2(Vector2.ZERO, _scroll.size)]
	var selected_chip: WorktreeChip = null
	for chip: WorktreeChip in chips():
		layout.append(chip.get_rect())
		if Paths.same(chip.path(), _selected):
			selected_chip = chip
	if selected_chip != null:
		layout.append(selected_chip.get_rect())
	if Paths.same(_revealed_path, _selected) and layout == _revealed_layout:
		return
	_revealed_path = _selected
	_revealed_layout = layout
	if selected_chip == null:
		return
	if selected_chip.size.x > _scroll.size.x:
		_scroll.scroll_horizontal += roundi(selected_chip.global_position.x - _scroll.global_position.x)
	else:
		_scroll.ensure_control_visible(selected_chip)


func _open_all_menu() -> void:
	_all_menu.clear()
	for i: int in _worktrees.size():
		var wt: Dictionary = _worktrees[i]
		var branch: String = String(wt["branch"])
		if bool(wt["detached"]):
			branch = tr("detached %s") % String(wt["head"]).left(7)
		var counts: PackedStringArray = PackedStringArray()
		var tooltip: PackedStringArray = PackedStringArray([String(wt["path"])])
		var changed: int = int(wt["changed"])
		if changed > 0:
			counts.append(str(changed))
			tooltip.append(tr("1 changed file") if changed == 1 else tr("%d changed files") % changed)
		var conflicts: int = int(wt.get("conflicts", 0))
		if conflicts > 0:
			tooltip.append(tr("1 conflicted file") if conflicts == 1 else tr("%d conflicted files") % conflicts)
		for direction: String in ["ahead", "behind"]:
			var count: int = int(wt.get(direction, 0))
			if count > 0:
				counts.append(("↑" if direction == "ahead" else "↓") + str(count))
				if direction == "ahead":
					tooltip.append(tr("1 commit ahead") if count == 1 else tr("%d commits ahead") % count)
				else:
					tooltip.append(tr("1 commit behind") if count == 1 else tr("%d commits behind") % count)
		var operation: String = String(wt.get("operation", ""))
		if not operation.is_empty():
			tooltip.append(tr("%s in progress") % tr(operation.capitalize()))
		if bool(wt["locked"]):
			var reason: String = String(wt["lock_reason"])
			tooltip.append(tr("Locked") + (": " + reason if not reason.is_empty() else ""))
		if bool(wt["prunable"]):
			tooltip.append(tr("The folder is missing."))
		var marker: StringName = &""
		if bool(wt["prunable"]):
			marker = &"StatusWarning"
		elif conflicts > 0 or not operation.is_empty():
			marker = &"GitConflict"
		elif bool(wt["locked"]):
			marker = &"Lock"
		var label: String = "%s  ·  %s" % [String(wt["name"]), branch]
		if not counts.is_empty():
			label += "  " + " ".join(counts)
		_all_menu.add_radio_check_item(label, i)
		if marker != &"":
			_all_menu.set_item_icon(i, AppTheme.icon(marker))
		_all_menu.set_item_tooltip(i, "\n".join(tooltip))
		_all_menu.set_item_checked(i, Paths.same(String(wt["path"]), _selected))
	_popup_under(_all_menu, _list_button)


func _open_task_menu() -> void:
	_task_menu.clear()
	_task_ids.clear()
	for id: StringName in TASK_MENU:
		if id == &"":
			_task_menu.add_separator()
			continue
		var action: ActionRegistry.Action = Actions.get_action(id)
		if action == null:
			continue
		_task_menu.add_icon_item(Actions.icon(id), action.label, _task_ids.size())
		_task_menu.set_item_disabled(_task_menu.item_count - 1, not action.is_enabled())
		_task_ids.append(id)
	_popup_under(_task_menu, _task_menu_button)


func _popup_under(menu: PopupMenu, anchor: Control) -> void:
	var window: Window = get_window()
	var rect: Rect2 = anchor.get_global_rect()
	menu.position = window.position + Vector2i((rect.position + Vector2(0.0, rect.size.y)) * window.content_scale_factor)
	menu.reset_size()
	menu.popup()
