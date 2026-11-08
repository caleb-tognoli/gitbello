class_name WorktreeStrip
extends PanelContainer
## The row of worktree chips at the top of a repository tab (PLAN §4): a
## worktree icon that opens the worktree list (a filter, every worktree and
## the worktree actions), the main worktree, a thin line, then the linked
## ones by folder name. When the chips do not fit, the row scrolls.

## A chip was activated: show worktree `path`.
signal worktree_chosen(path: String)
## A chip's context menu was requested; `at_position` is on the screen.
signal worktree_menu_requested(worktree: Dictionary, at_position: Vector2)
## A row's context menu was requested in the worktree list (`all_list()`).
signal list_menu_requested(worktree: Dictionary, at_position: Vector2)
## A chip was middle-clicked: show its folder.
signal worktree_reveal_requested(worktree: Dictionary)

var _row: HBoxContainer = HBoxContainer.new()
var _scroll: ScrollContainer = ScrollContainer.new()
var _chips: HBoxContainer = HBoxContainer.new()
## Between the main worktree's chip and the linked ones.
var _separator: VSeparator = VSeparator.new()
## Takes the room right of the chips while they fit.
var _spacer: Control = Control.new()
## The worktree icon starting the row: lists every worktree.
var _list_button: Button = Button.new()
var _all_list: WorktreeListPopover = WorktreeListPopover.new()
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
	AutoScroll.enable(_scroll)
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
	_update_tooltips()
	_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(_spacer)
	add_child(_all_list)
	_all_list.chosen.connect(func(path: String) -> void: worktree_chosen.emit(path))
	_all_list.menu_requested.connect(func(wt: Dictionary, at: Vector2) -> void: list_menu_requested.emit(wt, at))
	_update_overflow()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_update_tooltips()
		if _all_list.visible:
			_open_all_menu()


func _update_tooltips() -> void:
	_list_button.tooltip_text = tr("Worktrees")


## Shows `worktrees` (rows of `RepoSession.worktrees()`) with `selected_path`'s
## chip selected.
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
			_list_button.grab_focus()
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
## rest; past that the scroll takes it all (the worktree icon still lists
## every worktree).
func _update_overflow() -> void:
	var natural: float = _chips.get_combined_minimum_size().x + _scroll.get_combined_minimum_size().x + 1.0
	var room: float = _row.size.x - _list_button.get_combined_minimum_size().x \
			- 2.0 * float(_row.get_theme_constant(&"separation"))
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
	_all_list.open_below(_list_button, _worktrees, _selected)


## The list of every worktree (for tests).
func all_list() -> WorktreeListPopover:
	return _all_list

