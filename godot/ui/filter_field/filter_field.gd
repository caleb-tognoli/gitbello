class_name FilterField
extends PanelContainer
## A filter or search box, the same everywhere: one field with a search
## icon, the text and its clear button, then any buttons added with
## `add_button` after a divider (shown while any of them is): the options
## button from `add_options` (an `OptionsPopover` of filters and view
## settings, with a count of the filters on), or steps through matches. A muted count (`set_count`, "3/41") can sit
## between the text and the divider. The whole field is outlined in the accent colour
## while the text has focus. Enter and Shift+Enter submit, Down leaves the
## field, Escape clears the text (then leaves); Alt+Down opens the options
## (the `view.options` action). Styles are the `FilterField*` theme types.

## The text or the options changed.
signal changed()
## Enter (`backwards` with Shift).
signal submitted(backwards: bool)
## The user left the field with Down or Escape.
signal done()
## Option `id` of the popover changed to `value` (filters and view settings).
signal option_changed(id: String, value: Variant)

const THEME_TYPE: StringName = &"FilterField"

@export var placeholder: String = "":
	set(value):
		placeholder = value
		if is_node_ready():
			_text.placeholder_text = value

var _options_button: Button = null
var _popover: OptionsPopover = null
var _badge: CountBadge = CountBadge.new()

@onready var _search_icon: TextureRect = %SearchIcon
@onready var _text: LineEdit = %Text
@onready var _count: Label = %Count
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
	_divider.hide()
	_apply_theme()


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		if _options_button != null:
			_options_button.tooltip_text = tr("Options")


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


## Shows `value` after the text ("3/41", "No matches"), in the error colour
## when `error`; "" hides it.
func set_count(value: String, error: bool = false) -> void:
	_count.text = value
	_count.theme_type_variation = &"FilterFieldCountError" if error else &"FilterFieldCount"
	_count.visible = not value.is_empty()


## What the count says, or "".
func count_text() -> String:
	return _count.text if _count.visible else ""


## Adds a flat icon button after the divider; returns it to connect.
func add_button(icon: StringName, tooltip: String) -> Button:
	var button: Button = Button.new()
	button.icon = AppTheme.icon(icon)
	button.tooltip_text = tr(tooltip)
	button.focus_mode = Control.FOCUS_NONE
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.theme_type_variation = &"FilterFieldButton"
	_buttons.add_child(button)
	button.visibility_changed.connect(_update_divider)
	_update_divider()
	return button


## Adds the options button (the sliders icon) and returns its popover, to
## fill with sections and rows (`OptionsPopover`). The popover's counted
## options are the field's filters: `options()`, the button's badge and
## `changed`; every change is also sent as `option_changed`.
func add_options() -> OptionsPopover:
	if _popover != null:
		return _popover
	_popover = OptionsPopover.new()
	_popover.return_focus = _text
	_popover.changed.connect(_on_option_changed)
	add_child(_popover)
	_options_button = add_button(&"Sliders", "Options")
	_options_button.toggle_mode = true
	_options_button.focus_mode = Control.FOCUS_NONE
	_options_button.add_child(_badge)
	_options_button.pressed.connect(open_options)
	return _popover


## The options popover, or null without options.
func options_popover() -> OptionsPopover:
	return _popover


## Opens the options popover under its button.
func open_options() -> void:
	if _popover == null:
		return
	_update_options_button()
	_popover.open_below(_options_button)


## Ids of the filter options on (counted options set to true).
func options() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if _popover == null:
		return out
	for id: String in _popover.ids():
		if _popover.is_counted(id) and _popover.value(id) is bool and bool(_popover.value(id)):
			out.append(id)
	return out


## Turns option `id` on or off.
func set_option(id: String, on: bool) -> void:
	if _popover == null:
		return
	_popover.set_value(id, on)
	_options_changed()


## Whether there is text or a filter option on.
func is_active() -> bool:
	return not _text.text.strip_edges().is_empty() or (_popover != null and _popover.count() > 0)


## The options button, or null without options.
func options_button() -> Button:
	return _options_button


## The count on the options button, for tests.
func options_badge() -> CountBadge:
	return _badge


## Sets the filter options back to their defaults (not the text or view
## settings).
func clear_options() -> void:
	if _popover != null and _popover.reset_counted():
		_options_changed()


## Clears the text and the filter options.
func clear_filters() -> void:
	_text.text = ""
	if _popover != null:
		_popover.reset_counted()
	_options_changed()


func _on_option_changed(id: String, value: Variant) -> void:
	option_changed.emit(id, value)
	if _popover.is_counted(id):
		_options_changed()
	else:
		_update_options_button()


func _options_changed() -> void:
	_update_options_button()
	changed.emit()


## The badge counts the filters on; the button looks pressed meanwhile.
func _update_options_button() -> void:
	if _options_button == null:
		return
	var count: int = _popover.count()
	_badge.count = count
	_options_button.set_pressed_no_signal(count > 0)


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
