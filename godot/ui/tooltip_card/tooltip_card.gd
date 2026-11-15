class_name TooltipCard
extends VBoxContainer
## The one tooltip card: a label with its shortcut drawn as key caps
## on the right, then muted lines with a fact (the target, what a push sends,
## why it is disabled); rows add icon + text lines (`line`).
##
## Plain tooltips become cards through `install`: a tooltip text whose lines
## carry a tab (`Label\tCtrl+B`, from `ActionRegistry.tooltip`) or that has
## more than one line is drawn as a card instead of Godot's plain label. The
## first line is the label, a tab's right side the shortcut (canonical text,
## as `Shortcuts` writes it), the other lines facts.

## Separates a line's text from its shortcut in tooltip text.
const SHORTCUT_SEPARATOR: String = "\t"


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme_type_variation = &"TooltipCard"


## The card for tooltip `text` (see the class description).
static func from_text(text: String) -> TooltipCard:
	var card: TooltipCard = TooltipCard.new()
	var lines: PackedStringArray = text.split("\n")
	for i: int in lines.size():
		var parts: PackedStringArray = lines[i].split(SHORTCUT_SEPARATOR, true, 1)
		var shortcut: String = parts[1] if parts.size() > 1 else ""
		if i == 0:
			card.title(parts[0], shortcut)
		elif not parts[0].is_empty() or not shortcut.is_empty():
			card.fact(parts[0], shortcut)
	return card


## Whether `text` is drawn as a card rather than a plain label.
static func wants_card(text: String) -> bool:
	return text.contains(SHORTCUT_SEPARATOR) or text.strip_edges().contains("\n")


## Tooltip text for an action-like label: `label`, then its shortcut, then
## `facts` (each on its own line, empty ones left out).
static func text_for(label: String, shortcut: String = "", facts: PackedStringArray = PackedStringArray()) -> String:
	var out: String = label + (SHORTCUT_SEPARATOR + shortcut if not shortcut.is_empty() else "")
	for fact_text: String in facts:
		if not fact_text.is_empty():
			out += "\n" + fact_text
	return out


## The card's first line: `text` with `shortcut` as key caps on the right.
func title(text: String, shortcut: String = "") -> TooltipCard:
	add_child(_row(text, shortcut, &"TooltipCardTitle"))
	return self


## A muted line under the title.
func fact(text: String, shortcut: String = "") -> TooltipCard:
	add_child(_row(text, shortcut, &"TooltipCardFact"))
	return self


## An icon + text line, as a row's card lists its states.
func line(icon_name: StringName, text: String, variation: StringName = &"TooltipCardTitle") -> TooltipCard:
	var row: HBoxContainer = HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.theme_type_variation = &"TooltipCardRow"
	var icon: TextureRect = TextureRect.new()
	icon.texture = AppTheme.icon(icon_name) if icon_name != &"" else null
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	row.add_child(_label(text, variation))
	add_child(row)
	return self


## The texts of the card's lines, for tests: `Label · Ctrl+B` per line.
func texts() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for row: Node in get_children():
		var parts: PackedStringArray = PackedStringArray()
		for child: Node in row.get_children():
			if child is Label:
				parts.append((child as Label).text)
			elif child is HBoxContainer:
				var keys: PackedStringArray = PackedStringArray()
				for cap: Node in child.get_children():
					keys.append((cap.get_child(0) as Label).text)
				parts.append("+".join(keys))
		out.append(" · ".join(parts))
	return out


func _row(text: String, shortcut: String, variation: StringName) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.theme_type_variation = &"TooltipCardRow"
	var label: Label = _label(text, variation)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	if not shortcut.is_empty():
		var keys: HBoxContainer = HBoxContainer.new()
		keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
		keys.theme_type_variation = &"TooltipCardKeys"
		keys.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		for key: String in Shortcuts.display_keys(shortcut):
			var cap: PanelContainer = PanelContainer.new()
			cap.theme_type_variation = &"TooltipKeyCap"
			cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cap.add_child(_label(key, &"TooltipKeyCapLabel"))
			keys.add_child(cap)
		row.add_child(keys)
	return row


static func _label(text: String, variation: StringName) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.theme_type_variation = variation
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


## Makes every plain tooltip in `tree` whose text `wants_card` a card: the
## label Godot adds to its tooltip popup is emptied, the card drawn inside it
## and the label sized to the card, before the popup measures itself. (The
## popup cannot take another child while it enters the tree.)
static func install(tree: SceneTree) -> void:
	if not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)


static func _on_node_added(node: Node) -> void:
	var label: Label = node as Label
	if label == null or label.theme_type_variation != &"TooltipLabel" or not (label.get_parent() is PopupPanel):
		return
	if not wants_card(label.text) or label.has_node(^"TooltipCard"):
		return
	var card: TooltipCard = from_text(label.text)
	card.name = "TooltipCard"
	label.text = ""
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.add_child(card)
	label.custom_minimum_size = card.get_combined_minimum_size()
