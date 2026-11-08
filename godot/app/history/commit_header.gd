class_name CommitHeader
extends PanelContainer
## A commit's details above its files (PLAN M4b, M7.10; shared with Compare
## in M7.12c): the summary, the people (a card each with avatar, name and
## email for the author, every co-author and a different committer), date,
## hash, a merge's parents, the commit's refs as chips and the full message.
## Fill it with `show_info` from a `commit_info`-shaped dictionary.

## The theme type its sizes and tints come from.
const THEME_TYPE: StringName = &"CommitDetails"
## Characters shown of the commit's and its parents' hashes.
const HASH_LENGTH: int = 10
const PARENT_LENGTH: int = 7

## A merge's parent link was clicked: show commit `oid` (from `source`).
signal parent_requested(source: String, oid: String, origin: LinkButton)
## A ref chip was clicked: show the menu of `label` (`RefChip.ref_target`)
## at `at_position` (screen).
signal label_menu_requested(label: Dictionary, at_position: Vector2)
## The message body appeared or went (the owner can collapse its split).
signal body_shown(shown: bool)

## Formats unix times (the commit list's local-time format).
var date_format: Callable = Callable()
## The action the copy button runs.
var copy_action: StringName = &"commit.copy_hash"
## Shows a merge's parents as links (History, which can go to them).
var links_parents: bool = true

var _parent_links: Array[LinkButton] = []
var _shown_oid: String = ""

@onready var _summary: RichTextLabel = %Summary
@onready var _who: Control = %Who
@onready var _ids: Control = %Ids
@onready var _date: Label = %DateLabel
@onready var _hash: Label = %HashLabel
@onready var _copy_hash: Button = %CopyHash
@onready var _parents: Control = %Parents
@onready var _refs: HFlowContainer = %Refs
@onready var _body_separator: Control = %BodySeparator
@onready var _body: RichTextLabel = %Body
## Above the summary while two commits are selected (PLAN M7.12).
var _pair_button: Button = Button.new()


func _ready() -> void:
	_copy_hash.pressed.connect(func() -> void: Actions.run_action(copy_action, _copy_hash))
	_copy_hash.tooltip_text = tr("Copy the full hash")
	_pair_button.text = "Compare these commits"
	_pair_button.theme_type_variation = &"ToolbarButton"
	_pair_button.focus_mode = Control.FOCUS_NONE
	_pair_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_pair_button.hide()
	_pair_button.pressed.connect(func() -> void: Actions.run_action(&"history.compare_selected", _pair_button))
	_summary.get_parent().add_child(_pair_button)
	_summary.get_parent().move_child(_pair_button, 0)
	(_hash.get_parent() as Container).sort_children.connect(func() -> void: _align_baseline(_hash))
	(_parents as Container).sort_children.connect(func() -> void:
		for link: LinkButton in _parent_links:
			_align_baseline(link))
	_apply_theme()
	show_text("")


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		_copy_hash.tooltip_text = tr("Copy the full hash")


## Shows `text` in place of a commit (or nothing).
func show_text(text: String) -> void:
	_shown_oid = ""
	_clear_parents()
	_summary.text = text
	_who.hide()
	_ids.hide()
	_show_body("")


## Shows a commit: `info` as `RepoSession.commit_info()` gives it.
func show_info(info: Dictionary) -> void:
	_summary.text = String(info["summary"])
	_show_people(info)
	_date.text = date_format.call(int(info["time"])) if date_format.is_valid() else str(info["time"])
	_date.tooltip_text = tr("Author date")
	var oid: String = String(info["oid"])
	_shown_oid = oid
	_hash.text = oid.left(HASH_LENGTH)
	_hash.tooltip_text = oid
	_show_parents(oid, info["parents"] if links_parents else PackedStringArray())
	_show_refs(info.get("refs", []))
	_who.show()
	_ids.show()
	_show_body(String(info["body"]).strip_edges())


## The commit shown, or "".
func commit_oid() -> String:
	return _shown_oid


func summary_text() -> String:
	return _summary.text


func body_text() -> String:
	return _body.text


func has_body() -> bool:
	return _body.visible


## Shows "Compare these commits" while two commits are selected.
func show_pair_action(shown: bool) -> void:
	_pair_button.icon = AppTheme.icon(&"GitCompare")
	_pair_button.visible = shown


func pair_button() -> Button:
	return _pair_button


## The merge's parents row (screenshots).
func parents_group() -> Control:
	return _parents


func parent_links() -> Array[LinkButton]:
	return _parent_links.duplicate()


## The people's cards: `{name, email, role}` with role "", "co-author" or
## "committer", for tests.
func people() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for card: Node in _who.get_children():
		out.append(card.get_meta(&"person"))
	return out


## The ref chips shown, for tests.
func ref_chips() -> Array[RefChip]:
	var out: Array[RefChip] = []
	for chip: Node in _refs.get_children():
		out.append(chip as RefChip)
	return out


## Hashes are monospace beside sans text. Boxes centre each control, and the
## fonts split their height differently between ascent and descent, so the
## hashes would sit off the date's and labels' baseline; move them onto it
## (runs after each sort, as the box resets positions).
func _align_baseline(control: Control) -> void:
	if control.get_parent() == null:
		return
	control.position.y += roundf((_baseline_lift(_date) - _baseline_lift(control)) / 2.0)


## How far above its centre a centred control's baseline is, times two.
func _baseline_lift(control: Control) -> float:
	var font: Font = control.get_theme_font(&"font")
	var font_size: int = control.get_theme_font_size(&"font_size")
	return font.get_ascent(font_size) - font.get_descent(font_size)


## A card per person: the author, each co-author, and the committer when
## they are someone else.
func _show_people(info: Dictionary) -> void:
	for card: Node in _who.get_children():
		_who.remove_child(card)
		card.queue_free()
	var author: String = String(info["author"])
	var email: String = String(info["email"])
	_who.add_child(_person_card(author, email, ""))
	for person: Dictionary in info.get("coauthors", []):
		_who.add_child(_person_card(String(person["name"]), String(person["email"]), "co-author"))
	var committer: String = String(info.get("committer", ""))
	var committer_email: String = String(info.get("committer_email", ""))
	if committer != author or committer_email.to_lower() != email.to_lower():
		var card: Control = _person_card(committer, committer_email, "committer")
		var when: int = int(info.get("commit_time", 0))
		if when > 0 and date_format.is_valid():
			card.tooltip_text += "\n" + String(date_format.call(when))
		_who.add_child(card)


func _person_card(person: String, email: String, role: String) -> Control:
	var card: HBoxContainer = HBoxContainer.new()
	card.theme_type_variation = &"DetailsPerson"
	card.mouse_filter = Control.MOUSE_FILTER_PASS
	card.set_meta(&"person", {"name": person, "email": email, "role": role})
	card.tooltip_text = CommitList.identity_text(person, email)
	var avatar: AvatarView = AvatarView.new(person, email, float(get_theme_constant(&"avatar_size", THEME_TYPE)))
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	card.add_child(avatar)
	var lines: VBoxContainer = VBoxContainer.new()
	lines.theme_type_variation = &"DetailsPersonLines"
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	card.add_child(lines)
	var top: HBoxContainer = HBoxContainer.new()
	top.theme_type_variation = &"DetailsGroup"
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(top)
	top.add_child(_card_label(person if not person.is_empty() else email, &"DetailsName"))
	if not role.is_empty():
		top.add_child(_card_label(tr("Co-author") if role == "co-author" else tr("Committer"), &"DetailsRole"))
	if not person.is_empty() and not email.is_empty():
		lines.add_child(_card_label(email, &"DetailsMeta"))
	return card


func _card_label(text: String, variation: StringName) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.theme_type_variation = variation
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


## A chip per ref of the commit, after its hashes; a click opens its menu.
func _show_refs(refs: Array) -> void:
	for chip: Node in _refs.get_children():
		_refs.remove_child(chip)
		chip.queue_free()
	for ref_label: Dictionary in refs:
		var chip: RefChip = RefChip.new()
		chip.label = ref_label
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		chip.gui_input.connect(func(event: InputEvent) -> void:
			var mouse: InputEventMouseButton = event as InputEventMouseButton
			if mouse != null and mouse.pressed and mouse.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
				chip.accept_event()
				label_menu_requested.emit(RefChip.ref_target(ref_label),
						chip.get_screen_transform() * Vector2(0.0, chip.size.y)))
		_refs.add_child(chip)
	_refs.visible = not refs.is_empty()


func _clear_parents() -> void:
	for child: Node in _parents.get_children():
		_parents.remove_child(child)
		child.queue_free()
	_parent_links.clear()
	_parents.hide()


## Only merges show their parents: "Merges 5346dbe → 748e3dc", the parents
## it brings in, an arrow, and the one they were merged into (the first).
## Each hash is a link to that commit; `parent_links()` keeps Git's order.
func _show_parents(oid: String, parents: PackedStringArray) -> void:
	_clear_parents()
	if parents.size() < 2:
		return
	for index: int in parents.size():
		var parent: String = parents[index]
		var link: LinkButton = LinkButton.new()
		link.text = parent.left(PARENT_LENGTH)
		link.tooltip_text = tr("Go to parent %d") % (index + 1) + "\n" + parent
		link.theme_type_variation = &"DetailsParentLink"
		link.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
		link.focus_mode = Control.FOCUS_ALL
		link.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		link.pressed.connect(_request_parent.bind(oid, parent, link))
		_parent_links.append(link)
	_parents.add_child(_card_label(tr("Merges"), &"DetailsMeta"))
	for index: int in range(1, _parent_links.size()):
		_parents.add_child(_parent_links[index])
	_parents.add_child(_card_label("→", &"DetailsMeta"))
	_parents.add_child(_parent_links[0])
	_parents.show()


func _request_parent(source: String, oid: String, origin: LinkButton) -> void:
	if _shown_oid == source and _parent_links.has(origin):
		parent_requested.emit(source, oid, origin)


func _show_body(text: String) -> void:
	_body.text = text
	_body.scroll_to_line(0)
	_body.visible = not text.is_empty()
	_body_separator.visible = _body.visible
	body_shown.emit(_body.visible)


func _apply_theme() -> void:
	_copy_hash.icon = AppTheme.icon(&"ActionCopy")
	var tint: Color = get_theme_color(&"icon_tint", THEME_TYPE)
	var icon_size: float = float(get_theme_constant(&"icon_size", THEME_TYPE))
	for entry: Array in [[%DateIcon, &"Clock"], [%HashIcon, &"GitCommit"]]:
		var rect: TextureRect = entry[0]
		rect.texture = AppTheme.icon(entry[1])
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.custom_minimum_size = Vector2(icon_size, icon_size)
		rect.self_modulate = tint
