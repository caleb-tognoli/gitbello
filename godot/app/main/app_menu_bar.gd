class_name AppMenuBar
extends MenuBar


## The menu bar (UX.md): every entry is an action of the registry, so its
## label, shortcut and enabled state match the palette and the shortcuts.
## Entries are refreshed each time a menu opens; a disabled one says why in
## its tooltip. On macOS it becomes the system's global menu where Godot
## supports it (`prefer_global_menu`).

## Menus and their actions, in order: &"" is a separator, a String
## names a submenu filled by `dynamic_menus`, `[title, ids]` is a submenu of
## actions and `[title, ids, labels]` a family whose items show `labels`
## (translated when shown) instead of their menu labels.
const MENUS: Array[Array] = [
	["File", [&"home.open", &"", &"repo.add_existing", "Open recent", &"repo.clone", &"repo.scan", &"repo.create",
		&"repo.init", &"", &"tab.close", &"", &"app.settings", &"", &"app.quit"]],
	["Edit", [&"edit.undo", &"", &"diff.copy", &"diff.select_all", &"",
		&"view.find", &"history.next_match", &"history.previous_match"]],
	["View", [&"view.changes", &"view.history", &"view.shelves", &"view.compare", &"view.file_history", &"",
		["Diff", [&"diff.toggle_whole_file", &"diff.toggle_minimap", &"", &"diff.cycle_mode"]],
		["History", [&"history.current_branch", &"history.all_branches", &"", &"history.compact_rows",
			&"history.detailed_rows", &"", &"history.toggle_graph"]], &"",
		&"app.command_palette", &"view.toggle_git_log"]],
	["Repository", [&"sync.fetch", &"sync.pull", ["Pull with", [&"sync.pull_merge", &"sync.pull_rebase",
			&"sync.pull_ff_only"], {&"sync.pull_merge": "Merge", &"sync.pull_rebase": "Rebase",
			&"sync.pull_ff_only": "Fast-forward only"}], &"sync.push", &"sync.force_push", &"",
		&"repo.remotes", &"repo.tags", &"repo.ignore_rules", &"", &"changes.shelve", &"shelf.restore_left", &"",
		["Open in", [&"repo.open_terminal", &"repo.show_in_file_manager"], {&"repo.open_terminal": "Terminal",
			&"repo.show_in_file_manager": "File manager"}], &"",
		&"operation.continue", &"operation.skip", &"operation.open_resolver", &"operation.abort", &"",
		&"repo.refresh"]],
	["Branch", [&"branch.switch", &"branch.new", &"", &"branch.merge", &"branch.compare", &"", &"branch.rename",
		&"branch.set_upstream"]],
	["Commit", [&"changes.commit", &"commit.amend", &"commit.undo", &"", &"commit.cherry_pick", &"commit.checkout",
		&"", &"tag.new", &"", ["Copy", [&"commit.copy_hash", &"commit.copy_short_hash", &"commit.copy_subject",
			&"commit.copy_message"], {&"commit.copy_hash": "Hash", &"commit.copy_short_hash": "Short hash",
			&"commit.copy_subject": "Subject", &"commit.copy_message": "Message"}], &"commit.open_web"]],
	["Worktree", [&"task.new", &"worktree.setup", &"",
		["Open in", [&"worktree.open_terminal", &"worktree.show_in_file_manager"], {
			&"worktree.open_terminal": "Terminal", &"worktree.show_in_file_manager": "File manager"}],
		&"worktree.copy_path", &"", &"worktree.lock", &"worktree.unlock", &"", &"worktree.cleanup",
		&"worktree.prune", &"worktree.remove"]],
	["Help", [&"app.keyboard_shortcuts", &"app.whats_new", &"app.report_issue", &"app.open_config_folder", &"",
		&"app.about"]],
]

## Submenu name -> `func() -> Array[Dictionary]` of `{label, run: Callable}`.
var dynamic_menus: Dictionary[String, Callable] = {}
var _focus_before_menu: Control = null
var _keyboard_menu_open: bool = false


func _ready() -> void:
	prefer_global_menu = true
	flat = true
	for entry: Array in MENUS:
		var menu_popup: ActionMenu = ActionMenu.new()
		menu_popup.name = String(entry[0])
		add_child(menu_popup)
		menu_popup.about_to_popup.connect(_fill.bind(menu_popup, entry[1]))
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
		if mnemonic(i) == letter:
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
		var shortcut: String = "Alt+" + mnemonic(i).to_upper()
		set_menu_tooltip(i, "" if is_native_menu() or OS.has_feature("macos") else shortcut)


## The letter that opens menu `index` with Alt: the first letter of its title
## that no menu before it uses (Repository and Ramo both start with R in
## Italian), lower case.
func mnemonic(index: int) -> String:
	var used: PackedStringArray = PackedStringArray()
	for i: int in index + 1:
		var title: String = tr(String(MENUS[i][0])).to_lower()
		var letter: String = ""
		for c: String in title:
			if c != " " and not c in used:
				letter = c
				break
		if i == index:
			return letter
		used.append(letter)
	return ""


## The menu named `title`, or null (for tests).
func menu(title: String) -> ActionMenu:
	return get_node_or_null(title) as ActionMenu


## Labels of menu `title` and its submenus (for tests): disabled ones end
## with " (disabled)".
func labels(title: String) -> PackedStringArray:
	_fill_title(title)
	var popup: ActionMenu = menu(title)
	return popup.labels(true) if popup != null else PackedStringArray()


## Runs the entry labelled `label` in menu `title` or a submenu (for tests).
func press(title: String, label: String) -> bool:
	_fill_title(title)
	var popup: ActionMenu = menu(title)
	return popup != null and popup.press(label)


func _fill_title(title: String) -> void:
	for entry: Array in MENUS:
		if entry[0] == title:
			_fill(menu(title), entry[1])


func _refresh_all() -> void:
	for entry: Array in MENUS:
		var popup: ActionMenu = menu(String(entry[0]))
		if popup != null:
			_fill(popup, entry[1])


func _fill(popup: ActionMenu, ids: Array) -> void:
	popup.fill(_entries(ids))


## The menu's entries for `ActionMenu.fill`: a String names a submenu filled
## by `dynamic_menus`, an Array is a static submenu.
## Icons of the submenus, by title.
const SUB_ICONS: Dictionary[String, StringName] = {
	"Open recent": &"Clock", "Diff": &"Panels2", "History": &"RowsTwoLine",
	"Open in": &"ExternalLink", "Copy": &"ActionCopy",
}


func _entries(ids: Array) -> Array:
	var out: Array = []
	for id: Variant in ids:
		if id is String:
			var title: String = String(id)
			var fill: Callable = func() -> Array:
				return dynamic_menus[title].call() if dynamic_menus.has(title) else []
			out.append(ActionMenu.dynamic(tr(title), fill, SUB_ICONS.get(title, &"")))
		elif id is Array and (id as Array).size() > 2:
			var item_labels: Dictionary = {}
			for action: Variant in id[2]:
				item_labels[action] = tr(String(id[2][action]))
			out.append(ActionMenu.family(tr(String(id[0])), _entries(id[1]), item_labels,
					SUB_ICONS.get(String(id[0]), &"")))
		elif id is Array:
			out.append(ActionMenu.sub(tr(String(id[0])), _entries(id[1]), SUB_ICONS.get(String(id[0]), &"")))
		else:
			out.append(id)
	return out
