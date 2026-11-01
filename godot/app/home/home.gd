class_name Home
extends PanelContainer
## The Home page (PLAN §4 Home): find, open and add repositories. Shown when
## no tab is open and in the Home tab. A filter (focused when Home shows),
## the Add menu, running clones, the Recent cards and every repository of the
## library, sorted, optionally grouped by folder, pinned ones first. Status
## (branch, changes, commits to push and pull) is read only for rows on screen.

## The user chose repository `path` (a click, Enter, or a card).
signal chosen(path: String)

## The Add menu, in order (&"" is a separator).
const ADD_ACTIONS: Array[StringName] = [&"repo.clone", &"repo.add_existing", &"repo.scan", &"",
	&"repo.create", &"repo.init"]
## Sort and group choices, as saved.
enum Sort { NAME, OPENED, PATH }
enum Group { NONE, FOLDER }
## Home's own choices are saved as UI state under this key.
const STATE_KEY: String = "gitbello:home"
const THEME_TYPE: StringName = &"Home"

## Library operations (set by the shell).
var ops: LibraryOps = null:
	set(value):
		ops = value
		ops.clones_changed.connect(_rebuild_clones)
		queue_rebuild()
## `func(path: String) -> bool`: whether a tab shows repository `path`.
var is_open: Callable = Callable()

var _sort: Sort = Sort.NAME
var _group: Group = Group.NONE
## Collapsed folder groups, by folder.
var _collapsed: Dictionary[String, bool] = {}
## Paths whose summary was asked for since Home last showed.
var _requested: Dictionary[String, bool] = {}
## Row and card controls by path, to update when a summary arrives.
var _shown: Dictionary[String, Array] = {}
## Rows in list order (what ↑↓ and Enter move over), by path.
var _order: PackedStringArray = PackedStringArray()
var _rebuild_queued: bool = false
var _summaries_queued: bool = false

var _filter: FilterField = preload("res://ui/filter_field/filter_field.tscn").instantiate() as FilterField
var _add: MenuButton = MenuButton.new()
var _scroll: ScrollContainer = ScrollContainer.new()
## The scrolled content, kept clear of the scroll bar by `_fit_cards`.
var _scroll_box: MarginContainer = MarginContainer.new()
var _content: VBoxContainer = VBoxContainer.new()
var _clones: VBoxContainer = VBoxContainer.new()
var _recent_title: Label = Label.new()
## Recent cards in as many equal columns as fit, stretched to the full width.
var _recent: GridContainer = GridContainer.new()
var _all_title: Label = Label.new()
var _sort_choice: OptionButton = OptionButton.new()
var _group_choice: OptionButton = OptionButton.new()
var _list: VBoxContainer = VBoxContainer.new()
var _no_match: Label = Label.new()
## The context menu of rows and cards (right-click or ⋯), for `_menu_row`.
var _menu: PopupMenu = PopupMenu.new()
var _menu_row: Dictionary = {}
var _empty: EmptyState = preload("res://ui/empty_state/empty_state.tscn").instantiate() as EmptyState
var _body: MarginContainer = MarginContainer.new()


func _ready() -> void:
	theme_type_variation = &"HomePage"
	_body.theme_type_variation = &"HomeMargins"
	var column: VBoxContainer = VBoxContainer.new()
	column.theme_type_variation = &"HomeColumn"
	var top: HBoxContainer = HBoxContainer.new()
	_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_filter.changed.connect(queue_rebuild)
	_filter.submitted.connect(func(_backwards: bool) -> void: _choose_first())
	_filter.done.connect(func() -> void: _focus_row(0))
	top.add_child(_filter)
	_add.theme_type_variation = &"PrimaryButton"
	_add.icon = AppTheme.icon(&"Add")
	_add.flat = false
	_add.get_popup().id_pressed.connect(func(id: int) -> void: Actions.run_action(ADD_ACTIONS[id], _add))
	_add.about_to_popup.connect(_fill_add_menu)
	top.add_child(_add)
	column.add_child(top)

	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Rows reached with ↑↓ scroll into view.
	_scroll.follow_focus = true
	_scroll.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _queue_summaries())
	_scroll.resized.connect(_queue_summaries)
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.theme_type_variation = &"HomeColumn"
	_content.add_child(_clones)
	_recent_title.theme_type_variation = &"HomeSection"
	_content.add_child(_recent_title)
	_recent.theme_type_variation = &"HomeCards"
	_content.add_child(_recent)
	_scroll.resized.connect(_fit_cards)
	_scroll.get_v_scroll_bar().visibility_changed.connect(_fit_cards)
	var all_row: HBoxContainer = HBoxContainer.new()
	_all_title.theme_type_variation = &"HomeSection"
	_all_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	all_row.add_child(_all_title)
	_sort_choice.flat = true
	_sort_choice.item_selected.connect(func(index: int) -> void:
		_sort = index as Sort
		Core.set_repo_ui_state(STATE_KEY, "sort", index)
		queue_rebuild())
	all_row.add_child(_sort_choice)
	_group_choice.flat = true
	_group_choice.item_selected.connect(func(index: int) -> void:
		_group = index as Group
		Core.set_repo_ui_state(STATE_KEY, "group", index)
		queue_rebuild())
	all_row.add_child(_group_choice)
	_content.add_child(all_row)
	_list.theme_type_variation = &"HomeList"
	_content.add_child(_list)
	_no_match.theme_type_variation = &"DimLabel"
	_no_match.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_content.add_child(_no_match)
	_scroll_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_box.add_child(_content)
	_scroll.add_child(_scroll_box)
	column.add_child(_scroll)
	column.add_child(_empty)
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(column)
	add_child(_body)
	_menu.id_pressed.connect(func(id: int) -> void: _on_row_menu(id, _menu_row))
	add_child(_menu)

	var saved: Dictionary = Core.repo_ui_state(STATE_KEY)
	_sort = clampi(int(saved.get("sort", Sort.NAME)), 0, Sort.size() - 1) as Sort
	_group = clampi(int(saved.get("group", Group.NONE)), 0, Group.size() - 1) as Group
	Core.library_changed.connect(func(_error: String) -> void: queue_rebuild())
	Core.repo_summary_ready.connect(_on_summary)
	resized.connect(_fit_width)
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree():
			on_shown())
	refresh_texts()
	rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		refresh_texts()
		rebuild()


## Called each time Home appears: the filter starts empty and takes the
## keys, summaries are read again.
func on_shown() -> void:
	_requested.clear()
	_filter.set_text("")
	rebuild()
	focus_filter()


func focus_filter() -> void:
	if is_visible_in_tree():
		_filter.focus_text.call_deferred()


func filter_field() -> FilterField:
	return _filter


func add_menu() -> MenuButton:
	return _add


## Paths of the rows listed now, in order (tests).
func listed() -> PackedStringArray:
	return _order


## Scrolls `path`'s row into view (its summary is read then).
func show_row(path: String) -> void:
	var row: Control = row_for(path)
	if row != null:
		_scroll.ensure_control_visible(row)
		_queue_summaries()


## Paths of the Recent cards (tests).
func recent_paths() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for card: Node in _recent.get_children():
		out.append(String(card.get_meta(&"path")))
	return out


## The row control of `path`, or null (tests).
func row_for(path: String) -> Control:
	for control: Control in _shown.get(Paths.normalized(path), []):
		if control.get_parent() == _list:
			return control
	return null


## The list's scroll container (tests).
func scroll_container() -> ScrollContainer:
	return _scroll


## The Recent card of `path`, or null (tests).
func card_for(path: String) -> Control:
	for card: Node in _recent.get_children():
		if Paths.same(String(card.get_meta(&"path")), path):
			return card as Control
	return null


func empty_state() -> EmptyState:
	return _empty


func set_sort(sort: Sort) -> void:
	_sort_choice.select(sort)
	_sort_choice.item_selected.emit(sort)


func set_group(group: Group) -> void:
	_group_choice.select(group)
	_group_choice.item_selected.emit(group)


## Rebuilds every row from the library (cheap: the library is small).
func rebuild() -> void:
	_rebuild_queued = false
	if not is_node_ready():
		return
	for parent: Node in [_recent, _list]:
		for child: Node in parent.get_children():
			parent.remove_child(child)
			child.queue_free()
	_shown.clear()
	_order.clear()
	var rows: Array[Dictionary] = Core.library_rows()
	var empty: bool = rows.is_empty()
	_empty.visible = empty and ops != null and ops.clones().is_empty()
	_scroll.visible = not _empty.visible
	_rebuild_clones()
	if _empty.visible:
		return
	var query: String = _filter.text().strip_edges().to_lower()
	var matches: Array[Dictionary] = rows.filter(func(row: Dictionary) -> bool:
		return query.is_empty() or String(row["name"]).to_lower().contains(query) \
				or String(row["path"]).to_lower().replace("\\", "/").contains(query.replace("\\", "/")))
	_sort_rows(matches)
	# Recent: hidden while filtering, so the first row is the best match.
	var recent: PackedStringArray = Core.recent_repos(get_theme_constant(&"recent_count", THEME_TYPE)) \
			if query.is_empty() else PackedStringArray()
	var by_path: Dictionary[String, Dictionary] = {}
	for row: Dictionary in rows:
		by_path[Paths.normalized(String(row["path"]))] = row
	# Folder names shared by two cards get parent folders to tell them apart.
	var labels: PackedStringArray = Paths.short_labels(recent)
	for i: int in recent.size():
		var row: Dictionary = by_path.get(Paths.normalized(recent[i]), {})
		if not row.is_empty():
			var shown: String = String(row["display_name"]) if not String(row["display_name"]).is_empty() else labels[i]
			_recent.add_child(_card(row, shown))
	_recent_title.visible = _recent.get_child_count() > 0
	_recent.visible = _recent_title.visible
	_all_title.text = tr("All repositories (%d)") % rows.size() if query.is_empty() \
			else tr("%d of %d repositories") % [matches.size(), rows.size()]
	_no_match.visible = matches.is_empty()
	_no_match.text = tr("No repository matches “%s”.") % _filter.text().strip_edges()
	var pinned: Array[Dictionary] = matches.filter(func(r: Dictionary) -> bool: return bool(r["pinned"]))
	var others: Array[Dictionary] = matches.filter(func(r: Dictionary) -> bool: return not bool(r["pinned"]))
	for row: Dictionary in pinned:
		_add_row(row)
	if _group == Group.FOLDER and query.is_empty():
		var folders: Dictionary[String, Array] = {}
		for row: Dictionary in others:
			var folder: String = String(row["path"]).replace("\\", "/").get_base_dir()
			if not folders.has(folder):
				folders[folder] = []
			folders[folder].append(row)
		var names: Array[String] = []
		names.assign(folders.keys())
		names.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
		for folder: String in names:
			_add_group_header(folder, folders[folder].size())
			if not _collapsed.get(folder, false):
				for row: Dictionary in folders[folder]:
					_add_row(row)
	else:
		for row: Dictionary in others:
			_add_row(row)
	_queue_summaries()


func _sort_rows(rows: Array[Dictionary]) -> void:
	match _sort:
		Sort.NAME:
			rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return String(a["name"]).naturalnocasecmp_to(String(b["name"])) < 0)
		Sort.OPENED:
			rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return int(a["last_opened_at"]) > int(b["last_opened_at"]))
		Sort.PATH:
			rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return String(a["path"]).naturalnocasecmp_to(String(b["path"])) < 0)


## Rebuilds once, at the end of the frame (after the library or the tabs changed).
func queue_rebuild() -> void:
	if not _rebuild_queued:
		_rebuild_queued = true
		rebuild.call_deferred()


# --- Rows and cards ---------------------------------------------------------

## A list row: pin, name, path, then the summary and the ⋯ menu.
func _add_row(row: Dictionary) -> void:
	var path: String = String(row["path"])
	var button: Button = Button.new()
	button.theme_type_variation = &"HomeRow"
	button.set_meta(&"path", path)
	button.tooltip_text = path
	button.pressed.connect(func() -> void: chosen.emit(path))
	button.gui_input.connect(_on_row_input.bind(button, row))
	var box: MarginContainer = MarginContainer.new()
	box.theme_type_variation = &"HomeRowBox"
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var line: HBoxContainer = HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pin: TextureRect = _icon(&"Pin" if bool(row["pinned"]) else &"")
	pin.name = "Pin"
	line.add_child(pin)
	var name_label: Label = _label(String(row["name"]), &"HomeRowName")
	name_label.name = "Name"
	line.add_child(name_label)
	var path_label: Label = _label(path.replace("\\", "/"), &"DimLabel")
	path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	path_label.custom_minimum_size.x = 40
	line.add_child(path_label)
	var status: HBoxContainer = HBoxContainer.new()
	status.name = "Status"
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(status)
	if is_open.is_valid() and bool(is_open.call(path)):
		var open_label: Label = _label(tr("open"), &"HomeOpenChip")
		open_label.name = "Open"
		line.add_child(open_label)
	var more: Button = Button.new()
	more.name = "More"
	more.icon = AppTheme.icon(&"More")
	more.tooltip_text = tr("More")
	more.theme_type_variation = &"ToolbarButton"
	more.focus_mode = Control.FOCUS_NONE
	more.pressed.connect(func() -> void:
		show_menu(row, more.get_screen_position() + more.size, true))
	line.add_child(more)
	box.add_child(line)
	button.add_child(box)
	box.minimum_size_changed.connect(func() -> void:
		button.custom_minimum_size.y = box.get_combined_minimum_size().y)
	button.custom_minimum_size.y = box.get_combined_minimum_size().y
	_list.add_child(button)
	_remember(path, button)
	_order.append(path)
	_apply_summary(button, Core.repo_summary(path))


## A Recent card: `title` (the name, told apart from other cards'), branch
## and status, and when it was last opened.
func _card(row: Dictionary, title: String) -> Button:
	var path: String = String(row["path"])
	var button: Button = Button.new()
	button.theme_type_variation = &"HomeCard"
	button.set_meta(&"path", path)
	button.tooltip_text = path
	button.custom_minimum_size.x = float(get_theme_constant(&"card_width", THEME_TYPE))
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(func() -> void: chosen.emit(path))
	button.gui_input.connect(_on_row_input.bind(button, row))
	var box: MarginContainer = MarginContainer.new()
	box.theme_type_variation = &"HomeCardBox"
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lines: VBoxContainer = VBoxContainer.new()
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.theme_type_variation = &"ChoiceRowLines"
	var name_label: Label = _label(title, &"HomeRowName")
	name_label.name = "Name"
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lines.add_child(name_label)
	var status: HBoxContainer = HBoxContainer.new()
	status.name = "Status"
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(status)
	lines.add_child(_label(_ago(int(row["last_opened_at"])), &"DimLabel"))
	box.add_child(lines)
	button.add_child(box)
	box.minimum_size_changed.connect(func() -> void:
		button.custom_minimum_size.y = box.get_combined_minimum_size().y)
	_remember(path, button)
	_apply_summary(button, Core.repo_summary(path))
	return button


func _add_group_header(folder: String, count: int) -> void:
	var header: Button = Button.new()
	header.theme_type_variation = &"DisclosureButton"
	header.icon = AppTheme.icon(&"GuiTreeArrowRight" if _collapsed.get(folder, false) else &"GuiTreeArrowDown")
	header.text = "%s (%d)" % [folder, count]
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.focus_mode = Control.FOCUS_NONE
	header.pressed.connect(func() -> void:
		_collapsed[folder] = not _collapsed.get(folder, false)
		queue_rebuild())
	_list.add_child(header)


func _remember(path: String, control: Control) -> void:
	var key: String = Paths.normalized(path)
	if not _shown.has(key):
		_shown[key] = []
	_shown[key].append(control)


## Fills a row's or card's Status box from `summary` (see `Core.repo_summary`).
func _apply_summary(control: Control, summary: Dictionary) -> void:
	var status: HBoxContainer = control.find_child("Status", true, false) as HBoxContainer
	if status == null:
		return
	for child: Node in status.get_children():
		status.remove_child(child)
		child.queue_free()
	if summary.is_empty():
		return
	var row: bool = control.theme_type_variation == &"HomeRow"
	if bool(summary["missing"]):
		status.add_child(_icon(&"StatusWarning"))
		status.add_child(_label(tr("Folder missing"), &"ErrorLabel"))
		if row:
			var path: String = String(control.get_meta(&"path"))
			status.add_child(_small_button("Locate…", func() -> void: ops.relocate(path)))
			status.add_child(_small_button("Remove", func() -> void: ops.remove(path)))
		return
	if not (summary["error"] as Dictionary).is_empty():
		status.add_child(_label(tr("Not a repository"), &"ErrorLabel"))
		return
	var dot: StringName = &""
	if bool(summary["conflicts"]):
		dot = &"conflict_color"
	elif int(summary["changes"]) > 0:
		dot = &"changes_color"
	elif int(summary["ahead"]) > 0 or int(summary["behind"]) > 0:
		dot = &"sync_color"
	var branch: String = String(summary["branch"])
	var branch_label: Label = _label(branch if not branch.is_empty() else tr("detached"), &"HomeBranch")
	branch_label.name = "Branch"
	status.add_child(branch_label)
	if dot != &"":
		var picture: TextureRect = TextureRect.new()
		picture.texture = AppTheme.dot(get_theme_color(dot, &"RepoTabs"))
		picture.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		status.add_child(picture)
	if int(summary["ahead"]) > 0 or int(summary["behind"]) > 0:
		var counts: SyncCounts = SyncCounts.new()
		counts.name = "Counts"
		counts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		counts.set_counts(int(summary["ahead"]), int(summary["behind"]))
		status.add_child(counts)
	var tip: PackedStringArray = PackedStringArray([String(control.get_meta(&"path"))])
	if int(summary["changes"]) > 0:
		tip.append(tr("%d changed files") % int(summary["changes"]) if int(summary["changes"]) != 1
				else tr("1 changed file"))
	control.tooltip_text = "\n".join(tip)


func _on_summary(path: String) -> void:
	for control: Control in _shown.get(Paths.normalized(path), []):
		if is_instance_valid(control):
			_apply_summary(control, Core.repo_summary(path))


func _queue_summaries() -> void:
	if not _summaries_queued:
		_summaries_queued = true
		_request_summaries.call_deferred()


## Asks for the summaries of rows and cards on screen not asked for yet.
func _request_summaries() -> void:
	_summaries_queued = false
	if not is_visible_in_tree():
		return
	var view: Rect2 = _scroll.get_global_rect()
	var wanted: PackedStringArray = PackedStringArray()
	for key: String in _shown:
		if _requested.has(key):
			continue
		for control: Control in _shown[key]:
			if is_instance_valid(control) and control.is_visible_in_tree() \
					and view.intersects(control.get_global_rect()):
				_requested[key] = true
				wanted.append(String(control.get_meta(&"path")))
				break
	if not wanted.is_empty():
		Core.load_repo_summaries(wanted)


# --- Clones -----------------------------------------------------------------

func _rebuild_clones() -> void:
	for child: Node in _clones.get_children():
		_clones.remove_child(child)
		child.queue_free()
	if ops == null:
		return
	for clone: Dictionary in ops.clones():
		_clones.add_child(_clone_row(clone))
	_clones.visible = _clones.get_child_count() > 0
	var empty: bool = Core.library_rows().is_empty() and ops.clones().is_empty()
	if empty != _empty.visible:
		queue_rebuild()


func _clone_row(clone: Dictionary) -> PanelContainer:
	var job: int = int(clone["job"])
	var panel: PanelContainer = PanelContainer.new()
	panel.theme_type_variation = &"HomeCloneRow"
	var line: HBoxContainer = HBoxContainer.new()
	line.add_child(_icon(&"GitFetch"))
	var error: String = String(clone["error"])
	var title: Label = _label((tr("Cloning %s") if error.is_empty() else tr("Could not clone %s")) % String(clone["name"]), &"")
	title.tooltip_text = String(clone["url"])
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	line.add_child(title)
	if error.is_empty():
		var bar: ProgressBar = ProgressBar.new()
		bar.show_percentage = false
		bar.indeterminate = int(clone["percent"]) < 0
		bar.value = maxf(0.0, float(clone["percent"]))
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		line.add_child(bar)
		var text: Label = _label(String(clone["text"]), &"DimLabel")
		text.custom_minimum_size.x = float(get_theme_constant(&"clone_text_width", THEME_TYPE))
		text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		line.add_child(text)
		line.add_child(_small_button("Cancel", func() -> void: ops.cancel_clone(job)))
	else:
		var message: Label = _label(error, &"ErrorLabel")
		message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		message.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		message.tooltip_text = error
		message.mouse_filter = Control.MOUSE_FILTER_PASS
		line.add_child(message)
		line.add_child(_small_button("Retry", func() -> void: ops.retry_clone(job)))
		line.add_child(_small_button("Dismiss", func() -> void: ops.dismiss_clone(job)))
	panel.add_child(line)
	return panel


# --- Menus and keys ---------------------------------------------------------

func _fill_add_menu() -> void:
	var popup: PopupMenu = _add.get_popup()
	popup.clear()
	for i: int in ADD_ACTIONS.size():
		var id: StringName = ADD_ACTIONS[i]
		if id == &"":
			popup.add_separator()
			continue
		var action: ActionRegistry.Action = Actions.get_action(id)
		if action == null:
			continue
		popup.add_icon_item(Actions.icon(id), action.label, i)
		var shortcut: String = Actions.shortcut_label(id)
		if not shortcut.is_empty():
			popup.set_item_tooltip(popup.item_count - 1, shortcut)


enum RowItem { OPEN, PIN, RENAME, RELOCATE, SHOW, EDITOR, TERMINAL, COPY, REMOVE }


## Opens the menu of library entry `row` at screen position `at` (its top
## right corner with `from_right`, under the ⋯ button).
func show_menu(row: Dictionary, at: Vector2, from_right: bool = false) -> void:
	_menu_row = row
	_fill_row_menu(row)
	_menu.reset_size()
	_menu.position = Vector2i(at) - Vector2i(_menu.size.x if from_right else 0, 0)
	_menu.popup()


func row_menu() -> PopupMenu:
	return _menu


func _fill_row_menu(row: Dictionary) -> void:
	var popup: PopupMenu = _menu
	popup.clear()
	var add: Callable = func(icon_name: StringName, text: String, id: RowItem) -> void:
		popup.add_icon_item(AppTheme.icon(icon_name), tr(text), id)
	add.call(&"FolderAdd", "Open", RowItem.OPEN)
	add.call(&"Pin", "Unpin" if bool(row["pinned"]) else "Pin", RowItem.PIN)
	add.call(&"Rename", "Rename…", RowItem.RENAME)
	add.call(&"Folder", "Change location…", RowItem.RELOCATE)
	popup.add_separator()
	add.call(&"Folder", "Show in file manager", RowItem.SHOW)
	add.call(&"ExternalLink", "Open in editor", RowItem.EDITOR)
	add.call(&"Terminal", "Open terminal", RowItem.TERMINAL)
	add.call(&"ActionCopy", "Copy path", RowItem.COPY)
	popup.add_separator()
	add.call(&"Remove", "Remove from list", RowItem.REMOVE)


func _on_row_menu(id: int, row: Dictionary) -> void:
	var path: String = String(row["path"])
	match id as RowItem:
		RowItem.OPEN:
			chosen.emit(path)
		RowItem.PIN:
			ops.set_pinned(path, not bool(row["pinned"]))
		RowItem.RENAME:
			ops.rename(path, String(row["name"]))
		RowItem.RELOCATE:
			ops.relocate(path)
		RowItem.SHOW:
			ops.show_in_file_manager(path)
		RowItem.EDITOR:
			ops.open_in_editor(path)
		RowItem.TERMINAL:
			ops.open_terminal(path)
		RowItem.COPY:
			ops.copy_path(path)
		RowItem.REMOVE:
			ops.remove(path)


## Runs entry `item` of `path`'s row menu (tests).
func run_row_item(path: String, item: RowItem) -> void:
	for row: Dictionary in Core.library_rows():
		if Paths.same(String(row["path"]), path):
			_on_row_menu(item, row)


## A right-click on a row or card opens its menu where it was clicked; Up
## on the first row goes back to the filter.
func _on_row_input(event: InputEvent, control: Control, row: Dictionary) -> void:
	var mouse: InputEventMouseButton = event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT:
		show_menu(row, control.get_screen_position() + mouse.position)
		control.accept_event()
	elif event.is_action_pressed("ui_up", false, true) and control.get_parent() == _list \
			and not _order.is_empty() and Paths.same(String(row["path"]), _order[0]):
		_filter.focus_text()
		control.accept_event()


func _choose_first() -> void:
	if not _order.is_empty():
		chosen.emit(_order[0])


func _focus_row(index: int) -> void:
	if index < _order.size():
		var row: Control = row_for(_order[index])
		if row != null:
			row.grab_focus()


# --- Helpers ----------------------------------------------------------------

func _label(text: String, variation: StringName) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.theme_type_variation = variation
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return label


func _icon(icon_name: StringName) -> TextureRect:
	var picture: TextureRect = TextureRect.new()
	var side: float = float(get_theme_constant(&"icon_size", THEME_TYPE))
	picture.custom_minimum_size = Vector2(side, side)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if icon_name != &"":
		picture.texture = AppTheme.icon(icon_name)
	return picture


func _small_button(text: String, pressed: Callable) -> Button:
	var button: Button = Button.new()
	button.text = tr(text)
	button.theme_type_variation = &"ToolbarButton"
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(pressed)
	return button


## "2 min ago", "yesterday"… for a unix time (-1: never).
static func _ago(when: int) -> String:
	if when < 0:
		return TranslationServer.translate("Never opened")
	var seconds: int = maxi(0, int(Time.get_unix_time_from_system()) - when)
	if seconds < 60:
		return TranslationServer.translate("Just now")
	if seconds < 3600:
		return TranslationServer.translate("%d min ago") % floori(seconds / 60.0)
	if seconds < 86400:
		return TranslationServer.translate("%d h ago") % floori(seconds / 3600.0)
	var days: int = floori(seconds / 86400.0)
	if days == 1:
		return TranslationServer.translate("Yesterday")
	if days < 30:
		return TranslationServer.translate("%d days ago") % days
	return Time.get_date_string_from_unix_time(when)


## As many card columns as fit `card_width` wide cards; the cards stretch to
## share the rest, so a full Recent covers the width.
## The width comes from the scroll container, less the scroll bar and a gap
## when it shows: the content's own width cannot shrink below the cards.
func _fit_cards() -> void:
	var bar: VScrollBar = _scroll.get_v_scroll_bar()
	# The scroll container already keeps its bar's width free; add a gap.
	var clear: int = get_theme_constant(&"scrollbar_gap", THEME_TYPE) if bar.visible else 0
	_scroll_box.add_theme_constant_override(&"margin_right", clear)
	var gap: float = float(_recent.get_theme_constant(&"h_separation"))
	var card: float = float(get_theme_constant(&"card_width", THEME_TYPE))
	var room: float = _scroll.size.x - (bar.size.x if bar.visible else 0.0) - float(clear)
	var fit: int = maxi(1, floori((room + gap) / (card + gap)))
	if _recent.columns != fit:
		_recent.columns = fit


## Keeps the content at a readable width in wide windows.
func _fit_width() -> void:
	var room: float = size.x
	var widest: float = float(get_theme_constant(&"max_width", THEME_TYPE))
	var side: int = maxi(get_theme_constant(&"margin", THEME_TYPE), int((room - widest) / 2.0))
	_body.add_theme_constant_override(&"margin_left", side)
	_body.add_theme_constant_override(&"margin_right", side)


## Labels, choices and the empty state's buttons (call again once the
## actions are registered).
func refresh_texts() -> void:
	_filter.placeholder = tr("Filter repositories")
	_add.text = tr("Add")
	_recent_title.text = tr("Recent")
	var sort_labels: PackedStringArray = PackedStringArray([tr("Sort: Name"), tr("Sort: Last opened"), tr("Sort: Path")])
	var group_labels: PackedStringArray = PackedStringArray([tr("No groups"), tr("Group by folder")])
	for pair: Array in [[_sort_choice, sort_labels, int(_sort)], [_group_choice, group_labels, int(_group)]]:
		var choice: OptionButton = pair[0]
		choice.clear()
		for text: String in pair[1]:
			choice.add_item(text)
		choice.select(int(pair[2]))
	_empty.set_logo(AppTheme.logo())
	_empty.show_state("No repositories yet",
			"Clone one, add a folder you already have, or create a new one. You can also drop a folder here.", [
		{"id": &"repo.clone", "icon": &"GitFetch"},
		{"id": &"repo.add_existing", "icon": &"FolderAdd"},
		{"id": &"repo.create", "icon": &"Add"},
		{"id": &"repo.scan", "icon": &"Search"},
	])
	var first: Button = _empty.first_button()
	if first != null:
		first.theme_type_variation = &"PrimarySuggestionButton"
