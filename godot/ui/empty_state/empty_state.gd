class_name EmptyState
extends CenterContainer
## A title, a hint and big suggested actions (PLAN §4: "No local changes"
## and the welcome screen). Actions come from the registry, so they show only
## while they can run; plain buttons can be added for other choices (recent
## repositories).

@onready var _title: Label = %Title
@onready var _hint: Label = %Hint
@onready var _actions: VBoxContainer = %Actions


## Shows `title`, `hint` and one button per entry of `actions`:
## `{id: StringName, label: String (else the action's), icon: StringName}`.
## Disabled actions are left out.
func show_state(title: String, hint: String, actions: Array[Dictionary]) -> void:
	_title.text = tr(title)
	_hint.text = tr(hint)
	_hint.visible = not hint.is_empty()
	clear_buttons()
	for entry: Dictionary in actions:
		var id: StringName = entry.get("id", &"")
		var action: ActionRegistry.Action = Actions.get_action(id)
		if action == null or not action.is_enabled():
			continue
		var button: Button = add_button(String(entry.get("label", action.label)), entry.get("icon", &""), Callable())
		button.pressed.connect(func() -> void: Actions.run_action(id, button))
		button.tooltip_text = Actions.tooltip(id)


## Adds a big button that calls `pressed` (when valid). Returns it.
func add_button(label: String, icon_name: StringName, pressed: Callable) -> Button:
	var button: Button = Button.new()
	button.text = tr(label)
	button.theme_type_variation = &"SuggestionButton"
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.custom_minimum_size.x = float(get_theme_constant(&"button_width", &"EmptyState"))
	if icon_name != &"":
		button.icon = AppTheme.icon(icon_name)
	if pressed.is_valid():
		button.pressed.connect(pressed)
	_actions.add_child(button)
	return button


func clear_buttons() -> void:
	for child: Node in _actions.get_children():
		_actions.remove_child(child)
		child.queue_free()


func title() -> String:
	return _title.text


## The buttons' labels, for tests.
func button_labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for child: Node in _actions.get_children():
		out.append((child as Button).text)
	return out


## Presses the button labelled `label`, for tests. Returns whether it exists.
func press(label: String) -> bool:
	for child: Node in _actions.get_children():
		var button: Button = child as Button
		if button.text == label:
			button.pressed.emit()
			return true
	return false


func first_button() -> Button:
	return _actions.get_child(0) as Button if _actions.get_child_count() > 0 else null
