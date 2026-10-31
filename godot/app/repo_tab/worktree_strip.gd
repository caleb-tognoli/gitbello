class_name WorktreeStrip
extends PanelContainer
## The row of worktree chips at the top of a repository tab (PLAN §4): the
## main worktree first, then the linked ones by folder name, then + (new
## worktree) right after the last chip, with a ▾ for cleanup, adding a
## worktree for a branch and pruning. When the chips do not fit, the row
## scrolls and a ▾ at its end lists them all.

## A chip was clicked: show worktree `path`.
signal worktree_chosen(path: String)
## Right-click on a chip; `at_position` is on the screen.
signal worktree_menu_requested(worktree: Dictionary, at_position: Vector2)

const TASK_MENU: Array[StringName] = [&"worktree.cleanup", &"worktree.add_existing", &"", &"worktree.prune"]

var _row: HBoxContainer = HBoxContainer.new()
var _scroll: ScrollContainer = ScrollContainer.new()
var _chips: HBoxContainer = HBoxContainer.new()
## Takes the room right of the buttons while the chips fit.
var _spacer: Control = Control.new()
## New worktree and its ▾, joined into one split chip.
var _actions: HBoxContainer = HBoxContainer.new()
var _new_task: Button = Button.new()
var _task_menu_button: Button = Button.new()
var _task_menu: PopupMenu = PopupMenu.new()
var _task_ids: Array[StringName] = []
var _all_button: Button = Button.new()
var _all_menu: PopupMenu = PopupMenu.new()
var _worktrees: Array[Dictionary] = []
var _selected: String = ""


func _ready() -> void:
	theme_type_variation = &"WorktreeStrip"
	add_child(_row)
	_row.resized.connect(_update_overflow)
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chips.theme_type_variation = &"ChipRow"
	_chips.minimum_size_changed.connect(_update_overflow)
	_scroll.add_child(_chips)
	_row.add_child(_scroll)
	_all_button.icon = AppTheme.ARROW_DOWN
	_all_button.tooltip_text = "All worktrees"
	_all_button.theme_type_variation = &"ChipIconButton"
	_all_button.focus_mode = Control.FOCUS_NONE
	_all_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_all_button.pressed.connect(_open_all_menu)
	_row.add_child(_all_button)
	_actions.theme_type_variation = &"ChipSplit"
	_actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_row.add_child(_actions)
	_new_task.icon = AppTheme.icon(&"Add")
	_update_tooltips()
	_new_task.theme_type_variation = &"ChipAction"
	_new_task.focus_mode = Control.FOCUS_NONE
	_new_task.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_new_task.pressed.connect(func() -> void: Actions.run_action(&"task.new", _new_task))
	_actions.add_child(_new_task)
	_task_menu_button.icon = AppTheme.ARROW_DOWN
	_task_menu_button.tooltip_text = "More worktree actions"
	_task_menu_button.theme_type_variation = &"ChipActionMenu"
	_task_menu_button.focus_mode = Control.FOCUS_NONE
	_task_menu_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_task_menu_button.pressed.connect(_open_task_menu)
	_actions.add_child(_task_menu_button)
	_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(_spacer)
	add_child(_task_menu)
	_task_menu.id_pressed.connect(func(id: int) -> void: Actions.run_action(_task_ids[id]))
	add_child(_all_menu)
	_all_menu.id_pressed.connect(func(id: int) -> void:
		worktree_chosen.emit(String(_worktrees[id]["path"])))
	_update_overflow()


## Shows `worktrees` (rows of `RepoSession.worktrees()`) with `selected_path`'s
## chip selected.
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_update_tooltips()


func _update_tooltips() -> void:
	_all_button.tooltip_text = tr("All worktrees")
	var shortcut: String = Actions.shortcut_label(&"task.new")
	_new_task.tooltip_text = tr("New worktree") + (" (%s)" % shortcut if not shortcut.is_empty() else "")
	_task_menu_button.tooltip_text = tr("More worktree actions")


func show_worktrees(worktrees: Array[Dictionary], selected_path: String) -> void:
	_worktrees = _ordered(worktrees)
	_selected = selected_path
	var existing: Array[Node] = _chips.get_children()
	for i: int in _worktrees.size():
		var chip: WorktreeChip = existing[i] as WorktreeChip if i < existing.size() else null
		if chip == null:
			chip = WorktreeChip.new()
			chip.chosen.connect(func() -> void: worktree_chosen.emit(chip.path()))
			chip.menu_requested.connect(func(at: Vector2) -> void:
				worktree_menu_requested.emit(chip.worktree, at))
			_chips.add_child(chip)
		chip.set_worktree(_worktrees[i])
		chip.selected = Paths.same(chip.path(), selected_path)
	for i: int in range(_worktrees.size(), existing.size()):
		existing[i].queue_free()
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
## all and ▾ lists every worktree.
func _update_overflow() -> void:
	var natural: float = _chips.get_combined_minimum_size().x + _scroll.get_combined_minimum_size().x + 1.0
	var room: float = _row.size.x - _actions.get_combined_minimum_size().x \
			- 2.0 * float(_row.get_theme_constant(&"separation"))
	var fits: bool = natural <= room
	_all_button.visible = not fits
	_spacer.visible = fits
	_scroll.size_flags_stretch_ratio = natural
	_spacer.size_flags_stretch_ratio = maxf(room - natural, 1.0)


func _open_all_menu() -> void:
	_all_menu.clear()
	for i: int in _worktrees.size():
		var wt: Dictionary = _worktrees[i]
		_all_menu.add_radio_check_item("%s  ·  %s" % [String(wt["name"]), String(wt["branch"])], i)
		_all_menu.set_item_checked(i, Paths.same(String(wt["path"]), _selected))
	_popup_under(_all_menu, _all_button)


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
