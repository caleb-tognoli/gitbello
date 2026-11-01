class_name AppMenuBar
extends MenuBar


class MenuPopup:
	extends PopupMenu
	signal menu_key(event: InputEvent)

	func _unhandled_key_input(event: InputEvent) -> void:
		menu_key.emit(event)

## The menu bar (PLAN §4): every entry is an action of the registry, so its
## label, shortcut and enabled state match the palette and the shortcuts.
## Entries are refreshed each time a menu opens; a disabled one says why in
## its tooltip. On macOS it becomes the system's global menu where Godot
## supports it (`prefer_global_menu`).

## Menus and their actions, in order; &"" is a separator, a String names a
## submenu filled by `dynamic_menus`, and an Array is a static action submenu.
const MENUS: Array[Array] = [
	["File", [&"home.open", &"", &"repo.add_existing", "Open recent", &"repo.clone", &"repo.scan",
		["New repository", [&"repo.create", &"repo.init"]], &"", &"tab.close", &"", &"app.settings", &"", &"app.quit"]],
	["Edit", [&"diff.copy", &"diff.select_all", &"",
		["Undo", [&"changes.undo_discard", &"shelf.undo_discard", &"conflict.undo", &"commit.undo"]], &"",
		&"view.find", &"history.next_match", &"history.previous_match"]],
	["Repository", [&"sync.fetch", &"sync.pull", &"sync.push", &"", &"task.new",
		["Worktrees", [&"worktree.add_existing", &"worktree.cleanup", &"worktree.prune"]], &"",
		&"repo.open_in_editor", &"repo.open_terminal", &"repo.show_in_file_manager", &"",
		["Remotes and tags", [&"repo.remotes", &"repo.tags"]],
		["Shelves", [&"changes.shelve", &"shelf.restore_left"]], &"",
		&"operation.continue", &"operation.open_resolver", &"operation.abort", &"", &"repo.refresh"]],
	["Branch", [&"branch.switch", &"branch.new", &"", &"branch.merge", &"", &"branch.rename", &"branch.set_upstream"]],
	["View", [&"view.changes", &"view.history", &"view.shelves", &"", &"diff.toggle_side_by_side", &"diff.toggle_whole_file",
		&"diff.toggle_minimap", &"",
		&"app.command_palette", &"view.toggle_git_log"]],
	["Help", [&"app.keyboard_shortcuts", &"app.about"]],
]
const RADIO_ACTIONS: Array[StringName] = [&"view.changes", &"view.history", &"view.shelves"]
const CHECK_ACTIONS: Array[StringName] = [&"diff.toggle_side_by_side", &"diff.toggle_whole_file",
	&"diff.toggle_minimap", &"view.toggle_git_log"]
const OPERATION_ACTIONS: Array[StringName] = [&"operation.continue", &"operation.open_resolver", &"operation.abort"]

## Submenu name -> `func() -> Array[Dictionary]` of `{label, run: Callable}`.
var dynamic_menus: Dictionary[String, Callable] = {}
## Action id -> current checked state, supplied by the shell.
var checked_states: Dictionary[StringName, Callable] = {}

## Per menu: item index -> action id.
var _items: Dictionary[PopupMenu, Array] = {}
var _focus_before_menu: Control = null
var _keyboard_menu_open: bool = false


func _ready() -> void:
	prefer_global_menu = true
	flat = true
	for entry: Array in MENUS:
		var menu_popup: MenuPopup = MenuPopup.new()
		menu_popup.name = String(entry[0])
		add_child(menu_popup)
		_items[menu_popup] = []
		menu_popup.about_to_popup.connect(_fill.bind(menu_popup, entry[1]))
		menu_popup.id_pressed.connect(_on_id.bind(menu_popup))
		menu_popup.menu_key.connect(_on_popup_input)
	_translate_titles()
	# Filled once the shell has registered its actions, then on each opening.
	_refresh_all.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_translate_titles()
		_refresh_all()


func _unhandled_key_input(event: InputEvent) -> void:
	_handle_menu_key(event)


func _on_popup_input(event: InputEvent) -> void:
	_handle_menu_key(event)


func _handle_menu_key(event: InputEvent) -> void:
	if is_native_menu() or OS.has_feature("macos"):
		return
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_F10 and not key.shift_pressed and not key.alt_pressed \
			and not key.is_command_or_control_pressed() and not key.meta_pressed:
		if _any_menu_visible():
			_close_menus()
		else:
			_open_menu(0)
		get_viewport().set_input_as_handled()
		return
	if not key.alt_pressed or key.shift_pressed or key.is_command_or_control_pressed() or key.meta_pressed:
		return
	var keycode: Key = key.keycode if key.keycode != KEY_NONE else key.physical_keycode
	var letter: String = OS.get_keycode_string(keycode).to_lower()
	for i: int in get_menu_count():
		if tr(String(MENUS[i][0])).left(1).to_lower() == letter:
			_open_menu(i)
			get_viewport().set_input_as_handled()
			return


func _open_menu(index: int) -> void:
	if not _keyboard_menu_open:
		_focus_before_menu = get_viewport().gui_get_focus_owner()
	_keyboard_menu_open = true
	for entry: Array in MENUS:
		menu(String(entry[0])).hide()
	var x: float = 0.0
	var font: Font = get_theme_font(&"font")
	var font_size: int = get_theme_font_size(&"font_size")
	var box: StyleBox = get_theme_stylebox(&"normal")
	for i: int in index:
		x += font.get_string_size(get_menu_title(i), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x \
				+ box.get_minimum_size().x + float(get_theme_constant(&"h_separation"))
	var popup: PopupMenu = get_menu_popup(index)
	var at: Vector2 = get_screen_position() + Vector2(x, size.y)
	popup.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


func _any_menu_visible() -> bool:
	for entry: Array in MENUS:
		if menu(String(entry[0])).visible:
			return true
	return false


func _close_menus() -> void:
	for entry: Array in MENUS:
		menu(String(entry[0])).hide()
	_keyboard_menu_open = false
	if is_instance_valid(_focus_before_menu) and _focus_before_menu.is_inside_tree():
		_focus_before_menu.grab_focus()
	_focus_before_menu = null


func _translate_titles() -> void:
	for i: int in get_menu_count():
		var title: String = tr(String(MENUS[i][0]))
		set_menu_title(i, title)
		var shortcut: String = "Alt+" + title.left(1).to_upper()
		set_menu_tooltip(i, "" if is_native_menu() or OS.has_feature("macos") else shortcut)


## The menu named `title`, or null (for tests).
func menu(title: String) -> PopupMenu:
	return get_node_or_null(title) as PopupMenu


## Labels of menu `title` and its submenus (for tests): disabled ones end
## with " (disabled)".
func labels(title: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	_fill_title(title)
	var popup: PopupMenu = menu(title)
	if popup != null:
		_collect_labels(popup, out)
	return out


func _collect_labels(popup: PopupMenu, out: PackedStringArray) -> void:
	for i: int in popup.item_count:
		if popup.is_item_separator(i):
			continue
		out.append(popup.get_item_text(i) + (" (disabled)" if popup.is_item_disabled(i) else ""))
		var sub: PopupMenu = popup.get_item_submenu_node(i)
		if sub != null:
			_collect_labels(sub, out)


## Runs the entry labelled `label` in menu `title` or a submenu (for tests).
func press(title: String, label: String) -> bool:
	_fill_title(title)
	var popup: PopupMenu = menu(title)
	return popup != null and _press_label(popup, label)


func _press_label(popup: PopupMenu, label: String) -> bool:
	for i: int in popup.item_count:
		if popup.get_item_text(i) == label and not popup.is_item_disabled(i):
			_on_id(popup.get_item_id(i), popup)
			return true
		var sub: PopupMenu = popup.get_item_submenu_node(i)
		if sub != null and _press_label(sub, label):
			return true
	return false


func _fill_title(title: String) -> void:
	for entry: Array in MENUS:
		if entry[0] == title:
			_fill(menu(title), entry[1])


func _refresh_all() -> void:
	for entry: Array in MENUS:
		var popup: PopupMenu = menu(String(entry[0]))
		if popup != null:
			_fill(popup, entry[1])


func _fill(popup: PopupMenu, ids: Array) -> void:
	popup.clear(true)
	var items: Array = []
	for id: Variant in ids:
		if id is StringName and id == &"":
			if popup.item_count > 0 and not popup.is_item_separator(popup.item_count - 1):
				popup.add_separator()
			continue
		if id is String:
			_add_submenu(popup, String(id))
			continue
		if id is Array:
			_add_action_submenu(popup, String(id[0]), id[1])
			continue
		var action: ActionRegistry.Action = Actions.get_action(id)
		if action == null:
			continue
		if id in OPERATION_ACTIONS and not Actions.is_enabled(&"operation.abort"):
			continue
		var index: int = popup.item_count
		if id in RADIO_ACTIONS:
			popup.add_radio_check_item(action.label, items.size())
		elif id in CHECK_ACTIONS:
			popup.add_check_item(action.label, items.size())
		else:
			popup.add_icon_item(Actions.icon(id), action.label, items.size())
		if checked_states.has(id):
			popup.set_item_checked(index, bool(checked_states[id].call()))
		var shortcuts: PackedStringArray = Actions.shortcuts(id)
		if not shortcuts.is_empty():
			var event: InputEventKey = Shortcuts.parse(shortcuts[0])
			if event != null:
				var shortcut: Shortcut = Shortcut.new()
				shortcut.events = [event]
				popup.set_item_shortcut(index, shortcut)
				# Shown only: the registry handles the keys.
				popup.set_item_shortcut_disabled(index, true)
		popup.set_item_disabled(index, not action.is_enabled())
		popup.set_item_tooltip(index, action.disabled_reason())
		items.append(id)
	while popup.item_count > 0 and popup.is_item_separator(popup.item_count - 1):
		popup.remove_item(popup.item_count - 1)
	_items[popup] = items


func _add_action_submenu(popup: PopupMenu, title: String, ids: Array) -> void:
	var sub: MenuPopup = MenuPopup.new()
	_fill(sub, ids)
	sub.id_pressed.connect(_on_id.bind(sub))
	sub.menu_key.connect(_on_popup_input)
	popup.add_submenu_node_item(tr(title), sub)


func _add_submenu(popup: PopupMenu, title: String) -> void:
	var sub: MenuPopup = MenuPopup.new()
	var entries: Array[Dictionary] = []
	if dynamic_menus.has(title):
		entries.assign(dynamic_menus[title].call())
	for i: int in entries.size():
		sub.add_item(String(entries[i]["label"]), i)
		if entries[i].has("tooltip"):
			sub.set_item_tooltip(i, String(entries[i]["tooltip"]))
	sub.id_pressed.connect(func(index: int) -> void: (entries[index]["run"] as Callable).call())
	sub.menu_key.connect(_on_popup_input)
	popup.add_submenu_node_item(tr(title), sub)
	popup.set_item_disabled(popup.item_count - 1, entries.is_empty())


func _on_id(id: int, popup: PopupMenu) -> void:
	var items: Array = _items.get(popup, [])
	if id >= 0 and id < items.size():
		Actions.run_action(items[id])
