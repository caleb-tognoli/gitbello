class_name FilterField
extends PanelContainer
## A filter or search box, the same everywhere: one field with a search
## icon, the text and its clear button, then any buttons added with
## `add_button` after a divider (shown while any of them is) (an options menu from `set_options`, or
## steps through matches). The whole field is outlined in the accent colour
## while the text has focus; the options button looks pressed while any
## option is on. Enter and Shift+Enter submit, Down leaves the field, Escape
## clears the text (then leaves). Styles are the `FilterField*` theme types.

## The text or the options changed.
signal changed()
## Enter (`backwards` with Shift).
signal submitted(backwards: bool)
## The user left the field with Down or Escape.
signal done()

const THEME_TYPE: StringName = &"FilterField"

@export var placeholder: String = "":
	set(value):
		placeholder = value
		if is_node_ready():
			_text.placeholder_text = value

## `[id, label]` of each option, in menu order; "" is a separator.
var _options: Array[Array] = []
var _options_button: Button = null
var _menu: PopupMenu = PopupMenu.new()

@onready var _search_icon: TextureRect = %SearchIcon
@onready var _text: LineEdit = %Text
@onready var _divider: Control = %Divider
@onready var _buttons: HBoxContainer = %Buttons


func _ready() -> void:
	_text.placeholder_text = placeholder
	_text.text_changed.connect(func(_value: String) -> void: changed.emit())
	_text.gui_input.connect(_on_text_key)
	_text.focus_entered.connect(_update_focus)
	_text.focus_exited.connect(_update_focus)
	# A click on the icon or the padding focuses the text too.
	gui_input.connect(func(event: InputEvent) -> void:
		var mouse: InputEventMouseButton = event as InputEventMouseButton
		if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
			_text.grab_focus())
	_search_icon.texture = AppTheme.icon(&"Search")
	_menu.hide_on_checkable_item_selection = false
	_menu.id_pressed.connect(_on_option)
	add_child(_menu)
	_divider.hide()
	_apply_theme()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()


func text() -> String:
	return _text.text


func set_text(value: String) -> void:
	_text.text = value
	changed.emit()


func focus_text() -> void:
	_text.grab_focus()
	_text.select_all()


func text_box() -> LineEdit:
	return _text


## Adds a flat icon button after the divider; returns it to connect.
func add_button(icon: StringName, tooltip: String) -> Button:
	var button: Button = Button.new()
	button.icon = AppTheme.icon(icon)
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_NONE
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.theme_type_variation = &"FilterFieldButton"
	_buttons.add_child(button)
	button.visibility_changed.connect(_update_divider)
	_update_divider()
	return button


## Adds the options button with a menu of check items: `[id, label]` each,
## "" ids for separators.
func set_options(entries: Array[Array]) -> void:
	_options = entries
	_menu.clear()
	for i: int in entries.size():
		if String(entries[i][0]).is_empty():
			_menu.add_separator()
		else:
			_menu.add_check_item(String(entries[i][1]), i)
	if _options_button == null:
		_options_button = add_button(&"Filter", "Filter options")
		_options_button.toggle_mode = true
		_options_button.pressed.connect(_show_menu)


## Ids of the options on.
func options() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i: int in _options.size():
		var index: int = _menu.get_item_index(i)
		if index >= 0 and _menu.is_item_checked(index):
			out.append(String(_options[i][0]))
	return out


## Turns option `id` on or off.
func set_option(id: String, on: bool) -> void:
	for i: int in _options.size():
		if String(_options[i][0]) == id:
			_menu.set_item_checked(_menu.get_item_index(i), on)
	_options_changed()


## Whether there is text or an option on.
func is_active() -> bool:
	return not _text.text.strip_edges().is_empty() or not options().is_empty()


## The options button, or null without options.
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
	if _options_button != null:
		_options_button.set_pressed_no_signal(not options().is_empty())
	changed.emit()


func _on_text_key(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key != null and key.pressed and key.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		submitted.emit(key.shift_pressed)
		_text.accept_event()
	elif event.is_action_pressed("ui_down", false, true):
		done.emit()
		_text.accept_event()
	elif event.is_action_pressed("ui_cancel", false, true):
		if _text.text.is_empty():
			done.emit()
		else:
			set_text("")
		_text.accept_event()


func _update_divider() -> void:
	_divider.visible = _buttons.get_children().any(func(child: Node) -> bool: return (child as Control).visible)


func _update_focus() -> void:
	theme_type_variation = &"FilterFieldFocus" if _text.has_focus() else THEME_TYPE


func _apply_theme() -> void:
	var icon_size: float = float(get_theme_constant(&"icon_size", THEME_TYPE))
	_search_icon.custom_minimum_size = Vector2(icon_size, icon_size)
	_search_icon.self_modulate = get_theme_color(&"icon_color", THEME_TYPE)
