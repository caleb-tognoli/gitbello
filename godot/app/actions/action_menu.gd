class_name ActionMenu
extends PopupMenu
## A menu filled from the action registry: the menu bar, context
## menus and menu buttons all use it, so an action looks and behaves the same
## wherever it is listed.
##
## Each action shows its icon, `menu_label` and shortcut. One that does not
## apply here (`Action.visible`) is left out; one that applies but cannot run
## now is greyed, with why in its tooltip. Checkable actions are check or
## radio items.
##
## `fill()` takes a list of entries:
## - `&""`: a separator (never first, last or doubled);
## - an action id;
## - `ActionMenu.title(text)`: a separator labelled with what the menu acts on;
## - `ActionMenu.sub(title, entries, icon)`: a submenu of entries, left out
##   when nothing in it shows;
## - `ActionMenu.family(title, entries, labels, icon)`: a submenu of related
##   actions with shorter labels, flat when only one of them shows;
## - `ActionMenu.scoped(title, entries, scope, icon)`: a submenu whose actions
##   act on another target (a worktree's Branch ▸);
## - `ActionMenu.dynamic(title, fill, icon)`: a submenu of plain items built on
##   each fill by `fill() -> Array[Dictionary]` of `{label, run: Callable,
##   tooltip?, icon?, disabled?}`; shown greyed when empty;
## - `ActionMenu.item(label, run, icon, disabled, tooltip)`: a plain item that
##   is not an action (a choice: a template, a side, a folder hint).

## An entry was chosen: an action id, or &"" for a plain item.
signal chosen(id: StringName)
## A key reached the open menu without being handled (the menu bar moves
## between menus with it).
signal menu_key(event: InputEvent)

## Runs the chosen action itself. Off, only `chosen` is emitted and the owner
## runs it (to set up what the action acts on first).
var auto_run: bool = true
## The control that started the actions run from this menu (see
## `ActionRegistry.origin()`), or null.
var origin: Control = null
## Action id -> the text shown instead of its `menu_label` (set before
## `fill`): "Publish branch" for a push that publishes.
var label_overrides: Dictionary[StringName, String] = {}
## `func(id: StringName) -> String`: the tooltip of an enabled item (a
## disabled one shows why it is disabled), or an invalid Callable for none.
var tooltip_for: Callable = Callable()
## `func(body: Callable) -> Variant` of a scoped submenu: sets the target its
## actions act on, returns `body.call()` and restores the target. Wraps filling
## the menu and running its choice.
var scope: Callable = Callable()

## Item id -> action id (&"" for plain and dynamic items).
var _ids: Array[StringName] = []
## Item id -> Callable for plain and dynamic items.
var _runs: Array[Callable] = []
var _subs: Array[ActionMenu] = []


func _init() -> void:
	id_pressed.connect(_on_id)


func _unhandled_key_input(event: InputEvent) -> void:
	menu_key.emit(event)


static func title(text: String) -> Dictionary:
	return {"kind": "title", "text": text}


static func sub(text: String, entries: Array, icon: StringName = &"") -> Dictionary:
	return {"kind": "sub", "text": text, "entries": entries, "icon": icon}


## A family of actions (Compare ▸, Copy ▸, Open ▸): a submenu whose items show
## `item_labels` (action id -> text, already translated) instead of their menu
## labels, since the submenu names what they do. When only one item shows, it
## is listed flat with its own menu label.
static func family(text: String, entries: Array, item_labels: Dictionary = {}, icon: StringName = &"") -> Dictionary:
	return {"kind": "sub", "text": text, "entries": entries, "icon": icon, "labels": item_labels, "flat_single": true}


## A submenu of `entries` acting on another target than the menu's: `scope`
## (see `ActionMenu.scope`) sets it while the submenu is filled and while its
## choice runs.
static func scoped(text: String, entries: Array, scope_call: Callable, icon: StringName = &"") -> Dictionary:
	return {"kind": "sub", "text": text, "entries": entries, "icon": icon, "scope": scope_call}


static func dynamic(text: String, fill_entries: Callable, icon: StringName = &"") -> Dictionary:
	return {"kind": "dynamic", "text": text, "fill": fill_entries, "icon": icon}


static func item(text: String, run: Callable, icon: StringName = &"", disabled: bool = false,
		tooltip: String = "") -> Dictionary:
	return {"kind": "item", "text": text, "run": run, "icon": icon, "disabled": disabled, "tooltip": tooltip}


## Clears the menu and fills it with `entries`. Returns how many items show.
func fill(entries: Array) -> int:
	_clear_all()
	for entry: Variant in entries:
		if entry is StringName or entry is String:
			var id: StringName = StringName(entry)
			if id == &"":
				_add_separator()
			else:
				_add_action(id)
		elif entry is Dictionary:
			_add_entry(entry as Dictionary)
	_trim_separators()
	return item_count - _separator_count()


## Fills the menu with `entries` and opens it at screen position `at`; does
## nothing when no item shows.
func open(entries: Array, at: Vector2) -> bool:
	if fill(entries) == 0:
		return false
	open_at(at)
	return true


## Opens the filled menu at screen position `at`.
func open_at(at: Vector2) -> void:
	position = Vector2i(at)
	reset_size()
	popup()


## The action ids shown, in order, submenus included (for tests).
func action_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for i: int in item_count:
		if is_item_separator(i):
			continue
		var id: StringName = _ids[get_item_id(i)]
		if id != &"":
			out.append(id)
		var child: PopupMenu = get_item_submenu_node(i)
		if child is ActionMenu:
			out.append_array((child as ActionMenu).action_ids())
	return out


## Labels shown, submenus included; disabled ones end with " (disabled)"
## (for tests).
func labels(mark_disabled: bool = false) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i: int in item_count:
		if is_item_separator(i):
			continue
		out.append(get_item_text(i) + (" (disabled)" if mark_disabled and is_item_disabled(i) else ""))
		var child: PopupMenu = get_item_submenu_node(i)
		if child is ActionMenu:
			out.append_array((child as ActionMenu).labels(mark_disabled))
	return out


## Labels at this level only, without submenus' items (for tests).
func top_labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i: int in item_count:
		if not is_item_separator(i):
			out.append(get_item_text(i))
	return out


## Chooses the enabled entry labelled `label`, here or in a submenu. Returns
## whether one was found (for tests).
func press(label: String) -> bool:
	for i: int in item_count:
		if is_item_separator(i):
			continue
		if get_item_text(i) == label and not is_item_disabled(i) and get_item_submenu_node(i) == null:
			hide()
			_on_id(get_item_id(i))
			return true
		var child: PopupMenu = get_item_submenu_node(i)
		if child is ActionMenu and (child as ActionMenu).press(label):
			hide()
			return true
	return false


## Chooses the enabled action `id`, here or in a submenu (for tests).
func press_id(id: StringName) -> bool:
	for i: int in item_count:
		if is_item_separator(i):
			continue
		if _ids[get_item_id(i)] == id and not is_item_disabled(i):
			hide()
			_on_id(get_item_id(i))
			return true
		var child: PopupMenu = get_item_submenu_node(i)
		if child is ActionMenu and (child as ActionMenu).press_id(id):
			hide()
			return true
	return false


## The submenu titled `text`, or null (for tests).
func submenu(text: String) -> ActionMenu:
	for i: int in item_count:
		if get_item_text(i) == text and get_item_submenu_node(i) is ActionMenu:
			return get_item_submenu_node(i) as ActionMenu
	return null


# --- Internals ------------------------------------------------------------------

func _clear_all() -> void:
	clear(true)
	_ids.clear()
	_runs.clear()
	_subs.clear()


func _next_id(id: StringName, run: Callable = Callable()) -> int:
	_ids.append(id)
	_runs.append(run)
	return _ids.size() - 1


func _add_separator(text: String = "") -> void:
	if item_count > 0 and is_item_separator(item_count - 1):
		if text.is_empty():
			return
		remove_item(item_count - 1)
	if item_count == 0 and text.is_empty():
		return
	add_separator(text, _next_id(&""))


func _trim_separators() -> void:
	while item_count > 0 and is_item_separator(item_count - 1):
		remove_item(item_count - 1)


func _separator_count() -> int:
	var count: int = 0
	for i: int in item_count:
		if is_item_separator(i):
			count += 1
	return count


func _add_action(id: StringName) -> void:
	var action: ActionRegistry.Action = Actions.get_action(id)
	if action == null or not action.is_visible():
		return
	var item_id: int = _next_id(id)
	var icon: Texture2D = Actions.icon(id)
	var text: String = label_overrides.get(id, action.menu_label)
	if action.is_checkable() and action.radio:
		add_radio_check_item(text, item_id)
	elif action.is_checkable():
		add_check_item(text, item_id)
	else:
		add_item(text, item_id)
	var index: int = item_count - 1
	if icon != null:
		set_item_icon(index, icon)
	if action.is_checkable():
		set_item_checked(index, action.is_checked())
	var shortcuts: PackedStringArray = Actions.shown_shortcuts(id)
	if not shortcuts.is_empty():
		var event: InputEventKey = Shortcuts.parse(shortcuts[0])
		if event != null:
			var shortcut: Shortcut = Shortcut.new()
			shortcut.events = [event]
			set_item_shortcut(index, shortcut)
			# Shown only: the registry handles the keys.
			set_item_shortcut_disabled(index, true)
	set_item_disabled(index, not action.is_enabled())
	var tip: String = action.disabled_reason()
	if action.is_enabled() and tooltip_for.is_valid():
		tip = String(tooltip_for.call(id))
	set_item_tooltip(index, tip)


func _add_entry(entry: Dictionary) -> void:
	match String(entry.get("kind", "")):
		"title":
			_add_separator(String(entry["text"]))
		"item":
			var item_id: int = _next_id(&"", entry["run"] as Callable)
			add_item(String(entry["text"]), item_id)
			_set_icon(item_count - 1, StringName(entry.get("icon", &"")))
			set_item_disabled(item_count - 1, bool(entry.get("disabled", false)))
			set_item_tooltip(item_count - 1, String(entry.get("tooltip", "")))
		"sub":
			var child: ActionMenu = _new_sub()
			var item_labels: Dictionary = entry.get("labels", {})
			if not item_labels.is_empty():
				child.label_overrides = label_overrides.duplicate()
				for id: Variant in item_labels:
					child.label_overrides[StringName(id)] = String(item_labels[id])
			var entries: Array = entry["entries"] as Array
			var shown: int = 0
			if entry.has("scope"):
				child.scope = entry["scope"] as Callable
				shown = int(child.scope.call(func() -> int: return child.fill(entries)))
			else:
				shown = child.fill(entries)
			var single: Array[StringName] = []
			if shown == 1:
				single = child.action_ids()
			if shown == 0 or (bool(entry.get("flat_single", false)) and single.size() == 1):
				_subs.erase(child)
				child.queue_free()
				if shown == 1:
					_add_action(single[0])
				return
			_add_sub(child, String(entry["text"]), StringName(entry.get("icon", &"")))
		"dynamic":
			var child: ActionMenu = _new_sub()
			var items: Array = (entry["fill"] as Callable).call()
			for each: Variant in items:
				var row: Dictionary = each as Dictionary
				if row.is_empty():
					child._add_separator()
					continue
				var item_id: int = child._next_id(&"", row["run"] as Callable)
				child.add_item(String(row["label"]), item_id)
				child._set_icon(child.item_count - 1, StringName(row.get("icon", &"")))
				child.set_item_tooltip(child.item_count - 1, String(row.get("tooltip", "")))
				child.set_item_disabled(child.item_count - 1, bool(row.get("disabled", false)))
			child._trim_separators()
			_add_sub(child, String(entry["text"]), StringName(entry.get("icon", &"")))
			set_item_disabled(item_count - 1, child.item_count == 0)


func _new_sub() -> ActionMenu:
	var child: ActionMenu = ActionMenu.new()
	child.auto_run = auto_run
	child.origin = origin
	child.label_overrides = label_overrides
	child.tooltip_for = tooltip_for
	child.scope = scope
	child.chosen.connect(func(id: StringName) -> void: chosen.emit(id))
	child.menu_key.connect(func(event: InputEvent) -> void: menu_key.emit(event))
	_subs.append(child)
	return child


func _add_sub(child: ActionMenu, text: String, icon: StringName) -> void:
	add_submenu_node_item(text, child, _next_id(&""))
	_set_icon(item_count - 1, icon)


func _set_icon(index: int, icon_name: StringName) -> void:
	if icon_name != &"":
		set_item_icon(index, AppTheme.icon(icon_name))


func _on_id(item_id: int) -> void:
	if item_id < 0 or item_id >= _ids.size():
		return
	if scope.is_valid():
		scope.call(func() -> bool:
			_choose(item_id)
			return true)
	else:
		_choose(item_id)


func _choose(item_id: int) -> void:
	var id: StringName = _ids[item_id]
	if id == &"":
		var run: Callable = _runs[item_id]
		if run.is_valid():
			run.call()
		chosen.emit(&"")
		return
	chosen.emit(id)
	if auto_run:
		Actions.run_action(id, origin)
