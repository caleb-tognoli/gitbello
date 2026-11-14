class_name EmptyState
extends CenterContainer
## What a panel shows when it has nothing to show.
##
## Two forms. The big one: a title, a hint and big suggested actions (PLAN §4:
## "No local changes" and the welcome screen). Actions come from the
## registry, so they show only while they can run; plain buttons can be added
## for other choices (recent repositories). The compact one (`compact`, made
## with `create_compact`): a muted icon over a short title, with at most one
## small button (Clear filter), for lists and the diff ("No file selected",
## "No matches"). The compact form lets clicks through except on its button.

const SCENE_PATH: String = "res://ui/empty_state/empty_state.tscn"

## The compact form: see the class description.
@export var compact: bool = false:
	set(value):
		compact = value
		if is_node_ready():
			_apply_form()

@onready var _logo: TextureRect = %Logo
@onready var _icon: TextureRect = %Icon
@onready var _title: Label = %Title
@onready var _hint: Label = %Hint
@onready var _actions: VBoxContainer = %Actions
@onready var _layout: VBoxContainer = $Layout

## The translation keys shown, to translate again when the language changes.
var _heading_key: String = ""
var _hint_key: String = ""
var _icon_name: StringName = &""
## `show_compact`'s arguments while not ready yet: applied in `_ready`.
var _pending: Array = []


## A new compact empty state, filling its parent and hidden.
static func create_compact() -> EmptyState:
	var state: EmptyState = (load(SCENE_PATH) as PackedScene).instantiate() as EmptyState
	state.compact = true
	state.hide()
	return state


func _ready() -> void:
	_apply_form()
	if not _pending.is_empty():
		show_compact.callv(_pending)
		_pending = []


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_title.text = tr(_heading_key)
		_hint.text = tr(_hint_key)
	elif what == NOTIFICATION_THEME_CHANGED:
		_apply_icon()


## Shows `title`, `hint` and one button per entry of `actions`:
## `{id: StringName, label: String (else the action's), icon: StringName}`,
## plus `ahead`/`behind` for commit counts in pills at the button's right.
## Disabled actions are left out.
func show_state(heading: String, hint: String, actions: Array[Dictionary]) -> void:
	_set_text(heading, hint)
	clear_buttons()
	for entry: Dictionary in actions:
		var id: StringName = entry.get("id", &"")
		var action: ActionRegistry.Action = Actions.get_action(id)
		if action == null or not action.is_enabled():
			continue
		var button: Button = add_button(String(entry.get("label", action.label)), entry.get("icon", &""), Callable())
		button.pressed.connect(func() -> void: Actions.run_action(id, button))
		button.tooltip_text = Actions.tooltip(id)
		if entry.has("ahead") or entry.has("behind"):
			var counts: SyncCounts = SyncCounts.new()
			counts.widen_button = false
			counts.at_right = true
			counts.set_counts(int(entry.get("ahead", 0)), int(entry.get("behind", 0)))
			button.add_child(counts)


## Shows the compact form's `heading` (a translation key) under icon
## `icon_name`, with a button labelled `button_label` calling `pressed` when
## both are given, with icon `button_icon`. Before the empty state is ready it
## waits for `_ready`.
func show_compact(icon_name: StringName, heading: String, button_label: String = "",
		pressed: Callable = Callable(), button_icon: StringName = &"") -> void:
	if not is_node_ready():
		_pending = [icon_name, heading, button_label, pressed, button_icon]
		return
	set_icon(icon_name)
	_set_text(heading, "")
	clear_buttons()
	if not button_label.is_empty() and pressed.is_valid():
		add_button(button_label, button_icon, pressed)


## The compact "No matches" of a filter, with Clear filter calling `clear`.
func show_no_match(clear: Callable) -> void:
	show_compact(&"Search", "No matches", "Clear filter", clear, &"Clear")


## Shows icon `icon_name` (from `AppTheme.icon`) above the title; `&""`
## hides it.
func set_icon(icon_name: StringName) -> void:
	_icon_name = icon_name
	_apply_icon()


## The icon shown, or `&""`.
func shown_icon() -> StringName:
	return _icon_name


## Shows `texture` above the title, such as the logo on the welcome screen;
## null hides it.
func set_logo(texture: Texture2D) -> void:
	_logo.texture = texture
	_logo.visible = texture != null
	var side: float = float(get_theme_constant(&"logo_size", &"EmptyState"))
	_logo.custom_minimum_size = Vector2(side, side)


func has_logo() -> bool:
	return _logo.visible


## Adds a big button (a small one in the compact form) that calls `pressed`
## (when valid). Returns it.
func add_button(label: String, icon_name: StringName, pressed: Callable) -> Button:
	var button: Button = Button.new()
	button.text = tr(label)
	if compact:
		button.theme_type_variation = &"EmptyStateButton"
		button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	else:
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


## The title's translation key.
func title_key() -> String:
	return _heading_key


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


func _set_text(heading: String, hint: String) -> void:
	_heading_key = heading
	_hint_key = hint
	_title.text = tr(heading)
	_hint.text = tr(hint)
	_hint.visible = not hint.is_empty()


func _apply_form() -> void:
	if compact:
		# Clicks reach the list or diff below, except on the button.
		var passive: Array[Control] = [self, _layout, _actions, _title, _hint]
		for control: Control in passive:
			control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layout.theme_type_variation = &"EmptyStateCompactBox" if compact else &"EmptyStateBox"
	_title.theme_type_variation = &"EmptyStateCompactTitle" if compact else &"EmptyStateTitle"
	_apply_icon()


func _apply_icon() -> void:
	if _icon == null:
		return
	_icon.visible = _icon_name != &""
	if not _icon.visible:
		return
	var key: StringName = &"compact_icon_size" if compact else &"icon_size"
	var side: int = get_theme_constant(key, &"EmptyState")
	_icon.texture = AppTheme.large_icon(_icon_name, side)
	_icon.custom_minimum_size = Vector2(side, side)
	_icon.self_modulate = get_theme_color(&"icon_tint", &"EmptyState")
