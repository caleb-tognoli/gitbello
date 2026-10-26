class_name AppMenuBar
extends MenuBar
## The menu bar (PLAN §4): every entry is an action of the registry, so its
## label, shortcut and enabled state match the palette and the shortcuts.
## Entries are refreshed each time a menu opens; a disabled one says why in
## its tooltip. On macOS it becomes the system's global menu where Godot
## supports it (`prefer_global_menu`).

## Menus and their actions, in order; &"" is a separator, a String names a
## submenu filled by `dynamic_menus`.
const MENUS: Array[Array] = [
	["File", [&"repo.open", "Open recent", &"", &"tab.close", &"", &"app.settings", &"", &"app.quit"]],
	["Edit", [&"diff.copy", &"diff.select_all", &"", &"changes.undo_discard", &"shelf.undo_discard", &"",
		&"view.find", &"history.next_match", &"history.previous_match", &"", &"app.command_palette"]],
	["Repository", [&"sync.fetch", &"sync.pull", &"sync.push", &"", &"task.new", &"worktree.cleanup", &"",
		&"repo.open_in_editor", &"repo.open_terminal", &"repo.show_in_file_manager", &"",
		&"repo.remotes", &"repo.tags", &"", &"repo.refresh"]],
	["Branch", [&"branch.switch", &"branch.new", &"", &"branch.rename", &"branch.set_upstream", &"",
		&"changes.shelve", &"shelf.restore_left"]],
	["View", [&"view.changes", &"view.history", &"", &"diff.toggle_side_by_side", &"diff.toggle_whole_file", &"", &"view.theme_system",
		&"view.theme_light", &"view.theme_dark", &"", &"view.toggle_git_log"]],
	["Help", [&"app.keyboard_shortcuts", &"app.about"]],
]

## Submenu name -> `func() -> Array[Dictionary]` of `{label, run: Callable}`.
var dynamic_menus: Dictionary[String, Callable] = {}

## Per menu: item index -> action id (or a dynamic entry's Callable).
var _items: Dictionary[PopupMenu, Array] = {}


func _ready() -> void:
	prefer_global_menu = true
	flat = true
	for entry: Array in MENUS:
		var menu: PopupMenu = PopupMenu.new()
		menu.name = String(entry[0])
		add_child(menu)
		_items[menu] = []
		menu.about_to_popup.connect(_fill.bind(menu, entry[1]))
		menu.id_pressed.connect(_on_id.bind(menu))
	# Filled once the shell has registered its actions, then on each opening.
	_refresh_all.call_deferred()


## The menu named `title`, or null (for tests).
func menu(title: String) -> PopupMenu:
	return get_node_or_null(title) as PopupMenu


## Labels of menu `title` as it would open now (for tests): disabled ones end
## with " (disabled)".
func labels(title: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var popup: PopupMenu = menu(title)
	if popup == null:
		return out
	for entry: Array in MENUS:
		if entry[0] == title:
			_fill(popup, entry[1])
	for i: int in popup.item_count:
		if popup.is_item_separator(i):
			continue
		out.append(popup.get_item_text(i) + (" (disabled)" if popup.is_item_disabled(i) else ""))
	return out


## Runs the entry labelled `label` in menu `title` (for tests).
func press(title: String, label: String) -> bool:
	var popup: PopupMenu = menu(title)
	if popup == null:
		return false
	for entry: Array in MENUS:
		if entry[0] == title:
			_fill(popup, entry[1])
	for i: int in popup.item_count:
		if popup.get_item_text(i) == label and not popup.is_item_disabled(i):
			_on_id(popup.get_item_id(i), popup)
			return true
	return false


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
		var action: ActionRegistry.Action = Actions.get_action(id)
		if action == null:
			continue
		var index: int = popup.item_count
		if String(id).begins_with("view.theme_"):
			popup.add_radio_check_item(action.label, items.size())
			popup.set_item_checked(index, Core.theme_choice() == String(id).trim_prefix("view.theme_"))
		else:
			popup.add_icon_item(Actions.icon(id), action.label, items.size())
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


func _add_submenu(popup: PopupMenu, title: String) -> void:
	var sub: PopupMenu = PopupMenu.new()
	var entries: Array[Dictionary] = []
	if dynamic_menus.has(title):
		entries.assign(dynamic_menus[title].call())
	for i: int in entries.size():
		sub.add_item(String(entries[i]["label"]), i)
		if entries[i].has("tooltip"):
			sub.set_item_tooltip(i, String(entries[i]["tooltip"]))
	sub.id_pressed.connect(func(index: int) -> void: (entries[index]["run"] as Callable).call())
	popup.add_submenu_node_item(title, sub)
	popup.set_item_disabled(popup.item_count - 1, entries.is_empty())


func _on_id(id: int, popup: PopupMenu) -> void:
	var items: Array = _items.get(popup, [])
	if id >= 0 and id < items.size():
		Actions.run_action(items[id])
