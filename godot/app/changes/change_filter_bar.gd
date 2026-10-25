class_name ChangeFilterBar
extends PanelContainer
## The filter over the changed files, like GitHub Desktop's: one field with
## a search icon, the text (paths containing it, any case) and a button for
## a menu of options narrowing the list to included or left-out files and to
## new, modified or deleted ones (see `RepoSession.set_change_filter`). The
## whole field is outlined in the accent colour while the text has focus;
## the options button looks pressed while any option is on. Down moves into
## the list, Escape clears the text (then leaves the box).

## The text or the options changed.
signal changed()
## The user left the box with Down or Escape.
signal done()

const THEME_TYPE: StringName = &"FilterField"
## `[id, label]` of each option, in menu order; "" is a separator.
const OPTIONS: Array[Array] = [
	["included", "Included in commit"],
	["excluded", "Excluded from commit"],
	["", ""],
	["new", "New files"],
	["modified", "Modified files"],
	["deleted", "Deleted files"],
]

@onready var _field: PanelContainer = %Field
@onready var _search_icon: TextureRect = %SearchIcon
@onready var _text: LineEdit = %FilterText
@onready var _options_button: Button = %OptionsButton

var _menu: PopupMenu = PopupMenu.new()


func _ready() -> void:
	_text.text_changed.connect(func(_value: String) -> void: changed.emit())
	_text.gui_input.connect(_on_text_key)
	_text.focus_entered.connect(_update_focus)
	_text.focus_exited.connect(_update_focus)
	# A click on the icon or the padding focuses the text too.
	_field.gui_input.connect(func(event: InputEvent) -> void:
		var mouse: InputEventMouseButton = event as InputEventMouseButton
		if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
			_text.grab_focus())
	_search_icon.texture = AppTheme.icon(&"Search")
	_options_button.icon = AppTheme.icon(&"Filter")
	_options_button.tooltip_text = "Filter options"
	_options_button.pressed.connect(_show_menu)
	_menu.hide_on_checkable_item_selection = false
	for i: int in OPTIONS.size():
		if String(OPTIONS[i][0]).is_empty():
			_menu.add_separator()
		else:
			_menu.add_check_item(String(OPTIONS[i][1]), i)
	_menu.id_pressed.connect(_on_option)
	add_child(_menu)
	_apply_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()


func text() -> String:
	return _text.text


func set_text(value: String) -> void:
	_text.text = value
	changed.emit()


## Ids of the options on (`included`, `new`, ...).
func options() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i: int in OPTIONS.size():
		var index: int = _menu.get_item_index(i)
		if index >= 0 and _menu.is_item_checked(index):
			out.append(String(OPTIONS[i][0]))
	return out


## Turns option `id` on or off.
func set_option(id: String, on: bool) -> void:
	for i: int in OPTIONS.size():
		if String(OPTIONS[i][0]) == id:
			_menu.set_item_checked(_menu.get_item_index(i), on)
	_options_changed()


## Whether anything is filtered out.
func is_active() -> bool:
	return not _text.text.strip_edges().is_empty() or not options().is_empty()


## Whether including or leaving out a file can change what is shown.
func uses_picks() -> bool:
	var ids: PackedStringArray = options()
	return ("included" in ids) != ("excluded" in ids)


func focus_text() -> void:
	_text.grab_focus()
	_text.select_all()


func text_box() -> LineEdit:
	return _text


func options_button() -> Button:
	return _options_button


## The options menu, for tests.
func menu() -> PopupMenu:
	return _menu


func _show_menu() -> void:
	_options_button.set_pressed_no_signal(not options().is_empty())
	_menu.position = Vector2i(_options_button.get_screen_position() + Vector2(0.0, _options_button.size.y))
	_menu.reset_size()
	_menu.popup()


func _on_option(id: int) -> void:
	var index: int = _menu.get_item_index(id)
	_menu.set_item_checked(index, not _menu.is_item_checked(index))
	_options_changed()


func _options_changed() -> void:
	_options_button.set_pressed_no_signal(not options().is_empty())
	changed.emit()


func _on_text_key(event: InputEvent) -> void:
	if event.is_action_pressed("ui_down", false, true):
		done.emit()
		_text.accept_event()
	elif event.is_action_pressed("ui_cancel", false, true):
		if _text.text.is_empty():
			done.emit()
		else:
			set_text("")
		_text.accept_event()


func _update_focus() -> void:
	_field.theme_type_variation = &"FilterFieldFocus" if _text.has_focus() else THEME_TYPE


func _apply_theme() -> void:
	var icon_size: float = float(get_theme_constant(&"icon_size", THEME_TYPE))
	_search_icon.custom_minimum_size = Vector2(icon_size, icon_size)
	_search_icon.self_modulate = get_theme_color(&"icon_color", THEME_TYPE)
