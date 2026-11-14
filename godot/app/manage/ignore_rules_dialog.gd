class_name IgnoreRulesDialog
extends AcceptDialog
## Repository → Ignore rules… (M7.7b, docs/IGNORE_RULES.md §2): a chip per
## file git reads ignore rules from (the root and nested `.gitignore` files,
## `info/exclude` as "My computer" and the global file as "Global setting")
## with how many paths each hides; under it, the chosen file's lines (comments
## dimmed, `!` lines marked, unused rules muted, rules matching tracked files
## with a warning) and, beside them, what the selected line hides: a short
## recap and the paths. Add (one rule, or what a template lacks), Remove
## and Stop tracking… sit above the lines and run through `IgnoreOps`, with
## Undo; a chip opens its file on middle-click and has a menu on right-click.
## While it is open the rules reload with every status change.

const THEME_TYPE: StringName = &"IgnoreRulesDialog"
## The toolbar's buttons: id, label, icon, tooltip. Add's ▾ ("add_more")
## follows Add; Stop tracking… only shows for a rule matching tracked files.
const BUTTONS: Array[Array] = [
	["add", "Add", &"Add", "Add a rule"],
	["add_more", "", &"ChevronDown", "Add the rules of a template"],
	["remove", "Remove", &"Remove", "Remove the selected rule"],
	["untrack", "Stop tracking…", &"GitIgnore", "Stop tracking the files this rule matches; they stay on your disk."],
]
## The chip menu's items: id, label, icon.
const CHIP_MENU: Array[Array] = [
	[0, "Open file", &"ExternalLink"],
	[1, "Show in file manager", &"Folder"],
]

var _ops: IgnoreOps = null
var _session: RepoSession = null
## The source chips, scrolling sideways when they do not fit.
var _chip_row: ScrollRow = ScrollRow.new()
var _chips: HBoxContainer = _chip_row.content()
var _chip_menu: PopupMenu = PopupMenu.new()
var _lines: Tree = Tree.new()
var _recap: HBoxContainer = HBoxContainer.new()
var _hidden: IgnoreHiddenList = IgnoreHiddenList.new()
var _buttons: Dictionary[String, Button] = {}
## Add's ▾ menu.
var _add_menu: PopupMenu = PopupMenu.new()
## The add menu's templates, by item id - 1.
var _templates: PackedStringArray = PackedStringArray()
var _source_rows: Array[Dictionary] = []
var _line_rows: Array[Dictionary] = []
var _source: int = -1
var _line: int = -1
## The source whose chip menu is open.
var _menu_source: int = -1
## Tree rows are being filled by code: their selection is not the user's.
var _filling: bool = false
var _mono: Font = null
var _mono_size: int = 0


func _ready() -> void:
	# Not exclusive: the Ignore dialog and the confirmations open over it.
	exclusive = false
	title = tr("Ignore rules")
	ok_button_text = tr("Close")
	var box: VBoxContainer = VBoxContainer.new()
	add_child(box)
	_chips.theme_type_variation = &"ChipRow"
	box.add_child(_chip_row)
	box.add_child(HSeparator.new())
	var split: HSplitContainer = HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(split)
	var left: VBoxContainer = VBoxContainer.new()
	split.add_child(left)
	var toolbar: HBoxContainer = HBoxContainer.new()
	left.add_child(toolbar)
	# Add and its ▾ sit together, a hair apart.
	var pair: HBoxContainer = HBoxContainer.new()
	pair.add_theme_constant_override(&"separation", 1)
	toolbar.add_child(pair)
	for entry: Array in BUTTONS:
		var action_button: Button = Button.new()
		action_button.set_meta(&"label", entry[1])
		action_button.set_meta(&"tooltip", entry[3])
		action_button.icon = AppTheme.icon(entry[2])
		action_button.pressed.connect(press.bind(String(entry[0])))
		(pair if String(entry[0]).begins_with("add") else toolbar).add_child(action_button)
		_buttons[String(entry[0])] = action_button
	_add_menu.id_pressed.connect(_on_add)
	add_child(_add_menu)
	_lines.hide_root = true
	_lines.columns = 2
	_lines.set_column_expand(0, false)
	_lines.select_mode = Tree.SELECT_ROW
	_lines.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_lines.item_selected.connect(_on_line_selected)
	left.add_child(_lines)
	var right: VBoxContainer = VBoxContainer.new()
	split.add_child(right)
	_recap.custom_minimum_size.y = _buttons["add"].get_combined_minimum_size().y
	right.add_child(_recap)
	_hidden.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_hidden.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_hidden)
	_chip_menu.id_pressed.connect(_on_chip_menu)
	add_child(_chip_menu)
	visibility_changed.connect(func() -> void:
		if not visible and _session != null:
			_session.watch_ignore_rules(false))
	_apply_texts()
	_apply_theme()


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		title = tr("Ignore rules")
		ok_button_text = tr("Close")
		_apply_texts()
		if _session != null:
			_rebuild()
	elif what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()


func _apply_texts() -> void:
	for each: Button in _buttons.values():
		var label: String = String(each.get_meta(&"label"))
		each.text = tr(label) if not label.is_empty() else ""
		each.tooltip_text = tr(String(each.get_meta(&"tooltip")))


func _apply_theme() -> void:
	_lines.custom_minimum_size.x = get_theme_constant(&"lines_width", THEME_TYPE)
	# Line numbers and lines in the diff font. A column that does not expand
	# needs a width for its numbers.
	_mono = get_theme_font(&"font", &"DiffView")
	_mono_size = get_theme_font_size(&"font_size", &"DiffView")
	var digits: float = _mono.get_string_size("0000", HORIZONTAL_ALIGNMENT_LEFT, -1, _mono_size).x
	_lines.set_column_custom_minimum_width(0, ceili(digits) + get_theme_constant(&"inner_item_margin_left", &"Tree")
			+ get_theme_constant(&"inner_item_margin_right", &"Tree") + get_theme_constant(&"h_separation", &"Tree"))
	_recap.add_theme_constant_override(&"separation", get_theme_constant(&"recap_separation", THEME_TYPE))
	if _session != null:
		_rebuild()


## Shows the ignore rules of `ops`' worktree, kept up to date while open.
func open(ops: IgnoreOps) -> void:
	if _session != null and _session.ignore_rules_ready.is_connected(_on_rules_ready):
		_session.ignore_rules_ready.disconnect(_on_rules_ready)
		_session.watch_ignore_rules(false)
	_ops = ops
	_session = ops.session
	_hidden.session = _session
	_session.ignore_rules_ready.connect(_on_rules_ready)
	_source = -1
	_line = -1
	_session.watch_ignore_rules(true)
	_rebuild()
	# No wider than the window, less a margin on each side.
	var room: Vector2i = Vector2i(get_tree().root.get_visible_rect().size) - Vector2i(48, 48)
	popup_centered(Vector2i(mini(get_theme_constant(&"width", THEME_TYPE), room.x),
			mini(get_theme_constant(&"height", THEME_TYPE), room.y)))


func _on_rules_ready(_job: int) -> void:
	if visible:
		_rebuild()


## `name  hides` per source chip (for tests).
func sources() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for each: IgnoreSourceChip in _chip_nodes():
		out.append(each.text())
	return out


## `number  text  effect` per line of the chosen source (for tests; the
## effect is the line's tooltip).
func lines() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for line: Dictionary in _line_rows:
		out.append("%d  %s  %s" % [int(line["number"]), String(line["text"]), _effect(line)])
	return out


## The recap above the hidden paths, its parts joined by ", " (for tests).
func recap() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for child: Node in _recap.get_children():
		var label: Label = child as Label
		if label != null:
			parts.append(label.text)
	return ", ".join(parts)


func hidden_list() -> IgnoreHiddenList:
	return _hidden


func button(id: String) -> Button:
	return _buttons.get(id, null)


## Add's ▾ menu, filled (for tests).
func add_menu() -> PopupMenu:
	_fill_add_menu()
	return _add_menu


func chip(index: int) -> IgnoreSourceChip:
	var chips: Array[IgnoreSourceChip] = _chip_nodes()
	return chips[index] if index >= 0 and index < chips.size() else null


## The row of source chips (for tests).
func chip_row() -> ScrollRow:
	return _chip_row


func chip_menu() -> PopupMenu:
	return _chip_menu


func select_source(index: int) -> void:
	if index >= 0 and index < _source_rows.size():
		_choose_source(index)


## Selects the line whose text is `text` in the chosen source.
func select_line_text(text: String) -> bool:
	var root: TreeItem = _lines.get_root()
	if root == null:
		return false
	for i: int in _line_rows.size():
		if String(_line_rows[i]["text"]) == text:
			root.get_child(i).select(0)
			return true
	return false


func press(id: String) -> void:
	var line: Dictionary = _line_rows[_line] if _line >= 0 and _line < _line_rows.size() else {}
	match id:
		"add":
			if _ops != null:
				_ops.open_pattern("")
		"add_more":
			_fill_add_menu()
			var under: Button = _buttons["add_more"]
			_add_menu.popup(Rect2i(Vector2i(under.get_screen_position() + Vector2(0.0, under.size.y)), Vector2i.ZERO))
		"remove":
			if _is_rule(line):
				_ops.remove_rule(_source, _line, String(line["text"]))
		"untrack":
			if int(line.get("tracked_count", 0)) > 0:
				_ops.confirm_untrack(_source, _line, int(line["tracked_count"]), String(line["text"]))


## Opens source `index`'s file in its default app (like Open).
func open_source(index: int) -> void:
	if index < 0 or index >= _source_rows.size() or not bool(_source_rows[index]["exists"]):
		return
	RepoOps.opener.call(String(_source_rows[index]["path"]))


func _chip_nodes() -> Array[IgnoreSourceChip]:
	var out: Array[IgnoreSourceChip] = []
	for child: Node in _chips.get_children():
		if child is IgnoreSourceChip and not child.is_queued_for_deletion():
			out.append(child as IgnoreSourceChip)
	return out


func _rebuild() -> void:
	if _session == null:
		return
	var chosen: String = String(_source_rows[_source]["name"]) if _source >= 0 and _source < _source_rows.size() else ""
	_source_rows = _session.ignore_sources()
	var selected: int = 0
	for i: int in _source_rows.size():
		if String(_source_rows[i]["name"]) == chosen:
			selected = i
	for child: Node in _chips.get_children():
		_chips.remove_child(child)
		child.queue_free()
	for i: int in _source_rows.size():
		var source_chip: IgnoreSourceChip = IgnoreSourceChip.new()
		source_chip.set_source(_source_rows[i])
		source_chip.chosen.connect(_choose_source.bind(i))
		source_chip.open_requested.connect(open_source.bind(i))
		source_chip.menu_requested.connect(_open_chip_menu.bind(i))
		_chips.add_child(source_chip)
	_source = selected if not _source_rows.is_empty() else -1
	_update_chips()
	_fill_lines()


func _choose_source(index: int) -> void:
	if index == _source:
		return
	_source = index
	_line = -1
	_update_chips()
	_fill_lines()


func _update_chips() -> void:
	var chips: Array[IgnoreSourceChip] = _chip_nodes()
	for i: int in chips.size():
		chips[i].selected = i == _source
	if _source >= 0 and _source < chips.size():
		# Once the row is laid out.
		_chip_row.reveal.call_deferred(chips[_source])


func _open_chip_menu(at_position: Vector2, index: int) -> void:
	_menu_source = index
	_chip_menu.clear()
	var exists: bool = bool(_source_rows[index]["exists"])
	for entry: Array in CHIP_MENU:
		_chip_menu.add_icon_item(AppTheme.icon(entry[2]), tr(String(entry[1])), int(entry[0]))
		_chip_menu.set_item_disabled(_chip_menu.item_count - 1, not exists)
	_chip_menu.popup(Rect2i(Vector2i(at_position), Vector2i.ZERO))


func _on_chip_menu(id: int) -> void:
	if _menu_source < 0 or _menu_source >= _source_rows.size():
		return
	if id == 0:
		open_source(_menu_source)
	elif id == 1:
		OS.shell_show_in_file_manager(String(_source_rows[_menu_source]["path"]))


## "Hides 3 paths" and "1 tracked file matches", for a source's tooltip.
static func hides_text(hidden: int, tracked: int) -> String:
	var text: String = _t("Hides 1 path") if hidden == 1 else _t("Hides %d paths") % hidden
	if tracked > 0:
		text += "\n" + (_t("1 tracked file matches") if tracked == 1 else _t("%d tracked files match") % tracked)
	return text


func _fill_lines() -> void:
	var kept: int = _line
	_line_rows.clear()
	if _source >= 0:
		_line_rows = _session.ignore_lines(_source)
	_filling = true
	_lines.clear()
	var root: TreeItem = _lines.create_item()
	for i: int in _line_rows.size():
		var line: Dictionary = _line_rows[i]
		var item: TreeItem = _lines.create_item(root)
		for column: int in 2:
			item.set_custom_font(column, _mono)
			item.set_custom_font_size(column, _mono_size)
		item.set_text(0, str(int(line["number"])))
		item.set_text_alignment(0, HORIZONTAL_ALIGNMENT_RIGHT)
		item.set_custom_color(0, get_theme_color(&"comment_color", THEME_TYPE))
		item.set_text(1, String(line["text"]))
		var effect: String = _effect(line)
		item.set_tooltip_text(1, String(line["text"]) + ("\n" + effect if not effect.is_empty() else ""))
		match String(line["kind"]):
			"comment", "blank":
				item.set_custom_color(1, get_theme_color(&"comment_color", THEME_TYPE))
			"negation":
				item.set_custom_color(1, get_theme_color(&"negation_color", THEME_TYPE))
		if bool(line["unused"]):
			item.set_custom_color(1, get_theme_color(&"unused_color", THEME_TYPE))
		elif int(line["tracked_count"]) > 0:
			item.set_icon(1, AppTheme.icon(&"StatusWarning"))
			item.set_icon_modulate(1, get_theme_color(&"tracked_color", THEME_TYPE))
	_line = kept if kept >= 0 and kept < _line_rows.size() else -1
	if _line >= 0:
		root.get_child(_line).select(0)
	_filling = false
	_show_hidden()


## What a line does, for its tooltip: "Hides 3 files, 1 folder; 2 tracked
## files match", "Brings back 1 file", "Matches nothing".
static func _effect(line: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var counted: PackedStringArray = _counts(line)
	if not counted.is_empty():
		parts.append(_t("Hides %s") % ", ".join(counted))
	var tracked: int = int(line["tracked_count"])
	if tracked > 0:
		parts.append(_t("1 tracked file matches") if tracked == 1 else _t("%d tracked files match") % tracked)
	var back: int = int(line["reincluded"])
	if back > 0:
		parts.append(_t("Brings back 1 file") if back == 1 else _t("Brings back %d files") % back)
	if bool(line["unused"]):
		parts.append(_t("Matches nothing"))
	return "; ".join(parts)


## "2 files", "1 folder": what a line hides.
static func _counts(line: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var files: int = int(line["hidden_files"])
	var folders: int = int(line["hidden_folders"])
	if files > 0:
		out.append(_t("1 file") if files == 1 else _t("%d files") % files)
	if folders > 0:
		out.append(_t("1 folder") if folders == 1 else _t("%d folders") % folders)
	return out


## `key` translated, as a String (`translate` returns a StringName).
static func _t(key: String) -> String:
	return String(TranslationServer.translate(key))


static func _is_rule(line: Dictionary) -> bool:
	return String(line.get("kind", "")) in ["rule", "negation"]


func _on_line_selected() -> void:
	if _filling:
		return
	var item: TreeItem = _lines.get_selected()
	_line = item.get_index() if item != null else -1
	_show_hidden()


func _show_hidden() -> void:
	var line: Dictionary = _line_rows[_line] if _line >= 0 and _line < _line_rows.size() else {}
	_hidden.show_line(_source, _line if _is_rule(line) else -1)
	_fill_recap(line if _is_rule(line) else {})
	_buttons["remove"].disabled = not _is_rule(line)
	_buttons["untrack"].visible = int(line.get("tracked_count", 0)) > 0


## The selected rule's recap, icon and count per part: files and folders it
## hides, tracked files it matches, files it brings back, or that it matches
## nothing. Empty without a rule.
func _fill_recap(line: Dictionary) -> void:
	for child: Node in _recap.get_children():
		_recap.remove_child(child)
		child.queue_free()
	if line.is_empty():
		return
	var parts: Array[Array] = []
	var files: int = int(line["hidden_files"])
	var folders: int = int(line["hidden_folders"])
	if files > 0:
		parts.append([&"TextFile", tr("1 file") if files == 1 else tr("%d files") % files, &""])
	if folders > 0:
		parts.append([&"Folder", tr("1 folder") if folders == 1 else tr("%d folders") % folders, &""])
	var tracked: int = int(line["tracked_count"])
	if tracked > 0:
		parts.append([&"StatusWarning", tr("1 tracked") if tracked == 1 else tr("%d tracked") % tracked, &"tracked_color"])
	var back: int = int(line["reincluded"])
	if back > 0:
		parts.append([&"Undo", tr("Brings back 1 file") if back == 1 else tr("Brings back %d files") % back, &"negation_color"])
	if bool(line["unused"]):
		parts.append([&"", tr("Matches nothing"), &"unused_color"])
	var side: float = float(get_theme_constant(&"marker_size", &"WorktreeChip"))
	for part: Array in parts:
		var color: Color = get_theme_color(StringName(part[2]), THEME_TYPE) if part[2] != &"" else Color.WHITE
		if part[0] != &"":
			var icon: TextureRect = TextureRect.new()
			icon.texture = AppTheme.icon(part[0])
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.custom_minimum_size = Vector2(side, side)
			icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			icon.modulate = color
			_recap.add_child(icon)
		var label: Label = Label.new()
		label.text = String(part[1])
		if part[2] != &"":
			label.add_theme_color_override(&"font_color", color)
		_recap.add_child(label)


## Add's ▾ menu: the templates, one whose rules are all in the root
## `.gitignore` disabled.
func _fill_add_menu() -> void:
	_add_menu.clear()
	_templates = Core.gitignore_templates()
	_add_menu.add_separator(tr("Templates"))
	for i: int in _templates.size():
		var template: String = _templates[i]
		_add_menu.add_icon_item(AppTheme.icon(&"FileList"), template, i + 1)
		if _session == null or _session.ignore_template_lines(template).is_empty():
			_add_menu.set_item_disabled(_add_menu.item_count - 1, true)
			_add_menu.set_item_tooltip(_add_menu.item_count - 1, tr("The root .gitignore has every rule of this template."))


func _on_add(id: int) -> void:
	if _ops == null:
		return
	var template: String = _templates[id - 1] if id - 1 < _templates.size() else ""
	var missing: String = _session.ignore_template_lines(template)
	if not missing.is_empty():
		_ops.open_pattern(missing, "Add template rules")
