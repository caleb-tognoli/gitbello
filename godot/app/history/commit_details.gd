class_name CommitDetails
extends VSplitContainer
## The selected commit (PLAN M4b, laid out in M6.5): summary, the people
## (M7.10: a card each with avatar, name and email for the author, every
## co-author and a different committer), date, hashes, the commit's refs as
## chips and the full message on top, then its files beside the diff of the
## selected file. The top part's height (this split) and the files' width
## (`files_split()`) are dragged by the user.

const THEME_TYPE: StringName = &"CommitDetails"
## Characters shown of the commit's and its parents' hashes.
const HASH_LENGTH: int = 10
const PARENT_LENGTH: int = 7
## The diff's context menu: its actions, by item id.
const DIFF_MENU_ACTIONS: Array[StringName] = [&"diff.copy", &"diff.select_all", &"", &"diff.open_file", &"",
	&"diff.toggle_minimap"]
## The file list's context menu: its actions, by item id.
const FILE_MENU_ACTIONS: Array[StringName] = [&"diff.open_file"]

var session: RepoSession = null:
	set = set_session
## Formats unix times (the commit list's local-time format).
var date_format: Callable = Callable()

signal parent_requested(source: String, oid: String, origin: LinkButton)
## A ref chip was clicked: show the menu of `label` (`RefChip.ref_target`)
## at `at_position` (screen).
signal label_menu_requested(label: Dictionary, at_position: Vector2)

var _menu: PopupMenu = PopupMenu.new()
var _file_menu: PopupMenu = PopupMenu.new()
var _parent_links: Array[LinkButton] = []
var _shown_oid: String = ""
var _requested_oid: String = ""


@onready var _files_box: VBoxContainer = %FilesBox
@onready var _split: HSplitContainer = %Split
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
@onready var _files_header: ListHeader = %FilesHeader
@onready var _files: CommitFileList = %Files
@onready var _diff_panel: DiffPanel = %CommitDiffPanel
## Over the file list while the selected commit loads.
var _loading: LoadingIndicator = LoadingIndicator.new()


func _ready() -> void:
	_loading.area = "details"
	_files.add_child(_loading)
	_copy_hash.pressed.connect(func() -> void: Actions.run_action(&"commit.copy_hash", _copy_hash))
	_copy_hash.tooltip_text = tr("Copy the full hash")
	dragger_visibility = SplitContainer.DRAGGER_HIDDEN_COLLAPSED
	_apply_theme()
	_files.current_changed.connect(_on_file_changed)
	_diff_panel.set_source(func(start: int, count: int) -> Array:
		return session.commit_diff_lines(start, count) if session != null else [])
	_diff_panel.set_image_source(func(side: String) -> Dictionary:
		return session.image_side("commit", side) if session != null else {})
	_diff_panel.set_split_source(func(start: int, count: int) -> Array:
		return session.diff_split_rows("commit", start, count) if session != null else [])
	_diff_panel.set_minimap_sources(
		func(split: bool, first: int, rows: int, columns: int, row_px: int, char_px: int,
				palette: PackedColorArray) -> PackedByteArray:
			if session == null:
				return PackedByteArray()
			return session.diff_minimap_tile("commit", split, first, rows, columns, row_px, char_px, palette),
		func(split: bool, buckets: int) -> PackedByteArray:
			return session.diff_overview("commit", split, buckets, true) if session != null else PackedByteArray(),
		func(split: bool, row: float) -> float:
			return session.diff_strip_position("commit", split, row, true) if session != null else 0.0,
		func(split: bool, fraction: float) -> Dictionary:
			return session.diff_strip_target("commit", split, fraction, true) if session != null else {})
	_diff_panel.set_change_source(func(split: bool, from_row: int, forward: bool) -> int:
		return session.diff_change_row("commit", split, from_row, forward) if session != null else -1)
	_diff_panel.load_full_requested.connect(func() -> void:
		session.select_commit_file(String(session.commit_diff_info().get("path", "")), true))
	_diff_panel.expand_requested.connect(func(gap: int, how: String) -> void:
		session.expand_diff("commit", gap, how))
	_diff_panel.whole_file_requested.connect(func(whole: bool) -> void:
		session.show_whole_diff("commit", whole))
	_files.gui_input.connect(_on_files_key)
	_diff_panel.view().gui_input.connect(_on_diff_key)
	_diff_panel.view().context_menu_requested.connect(_show_diff_menu)
	_diff_panel.open_side_requested.connect(func(side: String) -> void:
		if session != null:
			session.open_version("commit", side))
	add_child(_menu)
	_menu.id_pressed.connect(func(id: int) -> void: Actions.run_action(DIFF_MENU_ACTIONS[id]))
	_files.context_menu_requested.connect(_show_file_menu)
	add_child(_file_menu)
	_file_menu.id_pressed.connect(func(id: int) -> void: Actions.run_action(FILE_MENU_ACTIONS[id]))
	(_hash.get_parent() as Container).sort_children.connect(func() -> void: _align_baseline(_hash))
	(_parents as Container).sort_children.connect(func() -> void:
		for link: LinkButton in _parent_links:
			_align_baseline(link))
	show_placeholder()


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


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _loading.get_parent() == null:
		_loading.free()  # Never added: freed without ever being ready.
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		_copy_hash.tooltip_text = tr("Copy the full hash")
		if session != null:
			_on_commit_loaded()
			_on_diff_changed()


func set_session(value: RepoSession) -> void:
	if session != null:
		session.commit_loaded.disconnect(_on_commit_loaded)
		session.commit_diff_changed.disconnect(_on_diff_changed)
	session = value
	show_placeholder()
	_files.session = session
	if session != null:
		session.commit_loaded.connect(_on_commit_loaded)
		session.commit_diff_changed.connect(_on_diff_changed)


func file_list() -> CommitFileList:
	return _files


func diff_panel() -> DiffPanel:
	return _diff_panel


## The files beside the diff (its offset is the files' width).
func files_split() -> HSplitContainer:
	return _split


func summary_text() -> String:
	return _summary.text


func body_text() -> String:
	return _body.text


## The commit's line totals as shown, `+12 −3`, or "" when hidden.
func totals_text() -> String:
	return _files_header.counts_text()


## The line above the files: their count and the commit's totals.
func files_header() -> ListHeader:
	return _files_header


## Asks for commit `oid`; the panel fills in when it arrives.
func show_commit(oid: String) -> void:
	if session == null or oid.is_empty():
		show_placeholder()
		return
	_requested_oid = oid
	if _shown_oid != oid:
		_clear_parents()
		_shown_oid = ""
	session.load_commit(oid)
	if String(session.commit_info().get("oid", "")) == oid:
		_on_commit_loaded()
	elif _shown_oid != oid:
		# The files of the previous commit would mislead: show the load.
		_files.show_files(0)
		_files_header.set_text("")
		_files_header.show_counts(0, 0)
		_loading.show_loading(true, tr("Loading commit…"))


## Shows `text` instead of a commit (while the history loads, or when it
## has none).
func show_placeholder(text: String = "") -> void:
	_loading.hide_loading()
	_requested_oid = ""
	_shown_oid = ""
	_clear_parents()
	_summary.text = text
	_who.hide()
	_ids.hide()
	_show_body("")
	_files_header.set_text("")
	_files_header.show_counts(0, 0)
	_files.show_files(0)
	_diff_panel.clear("Select a file to see its changes.")


## The file list's loading indicator (smoke tests and screenshots).
func loading_indicator() -> LoadingIndicator:
	return _loading


## Focuses the file list (cursor on the first file).
func focus_files() -> void:
	_files.grab_focus()
	if _files.cursor < 0 and _files.row_count() > 0:
		_files.select_only(0)


func _on_commit_loaded() -> void:
	var info: Dictionary = session.commit_info()
	if info.is_empty() or _requested_oid.is_empty() or not String(info["oid"]).begins_with(_requested_oid):
		return
	_loading.hide_loading()
	_summary.text = String(info["summary"])
	_show_people(info)
	_date.text = date_format.call(int(info["time"])) if date_format.is_valid() else str(info["time"])
	_date.tooltip_text = tr("Author date")
	var oid: String = String(info["oid"])
	_requested_oid = oid
	_shown_oid = oid
	_hash.text = oid.left(HASH_LENGTH)
	_hash.tooltip_text = oid
	_show_parents(oid, info["parents"])
	_show_refs(info.get("refs", []))
	_who.show()
	_ids.show()
	_show_body(String(info["body"]).strip_edges())
	var count: int = int(info["file_count"])
	_files_header.set_text(ListHeader.count_text(count, "changed file"))
	_files_header.show_counts(int(info.get("additions", 0)), int(info.get("deletions", 0)))
	_files.show_files(count)
	if count > 0:
		_files.select_only(0)
	else:
		_diff_panel.clear()


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


func parent_links() -> Array[LinkButton]:
	return _parent_links.duplicate()


func commit_oid() -> String:
	return _shown_oid


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
	if _shown_oid == source and _requested_oid == source and _parent_links.has(origin):
		parent_requested.emit(source, oid, origin)


func _on_file_changed(path: String) -> void:
	if path.is_empty():
		return
	session.select_commit_file(path, false)
	_on_diff_changed()


func retry_diff() -> void:
	if session == null or not _diff_panel.can_retry():
		return
	var info: Dictionary = session.commit_diff_info()
	if String(info.get("state", "")) != "error":
		return
	session.select_commit_file(String(info.get("path", "")), false)
	_on_diff_changed()


func _on_diff_changed() -> void:
	_diff_panel.show_info(session.commit_diff_info())


## The diff's context menu: Copy (when text is selected), Select all and
## the minimap toggle.
func _show_diff_menu(_row: int, at_position: Vector2) -> void:
	_menu.clear()
	for i: int in DIFF_MENU_ACTIONS.size():
		if DIFF_MENU_ACTIONS[i] == &"":
			_menu.add_separator()
			continue
		_menu.add_icon_item(Actions.icon(DIFF_MENU_ACTIONS[i]), Actions.get_action(DIFF_MENU_ACTIONS[i]).label, i)
		_menu.set_item_disabled(_menu.item_count - 1, not Actions.is_enabled(DIFF_MENU_ACTIONS[i]))
		if DIFF_MENU_ACTIONS[i] == &"diff.toggle_minimap":
			_menu.set_item_as_checkable(_menu.item_count - 1, true)
			_menu.set_item_checked(_menu.item_count - 1, Core.diff_minimap())
	_menu.position = Vector2i(_diff_panel.view().get_screen_position() + at_position)
	_menu.reset_size()
	_menu.popup()


## The diff's context menu, for tests.
func diff_menu() -> PopupMenu:
	return _menu


## The file list's context menu (the right-clicked file is selected): Open.
func _show_file_menu(_row: int, at_position: Vector2) -> void:
	_file_menu.clear()
	for i: int in FILE_MENU_ACTIONS.size():
		_file_menu.add_icon_item(Actions.icon(FILE_MENU_ACTIONS[i]), Actions.get_action(FILE_MENU_ACTIONS[i]).label, i)
		_file_menu.set_item_disabled(_file_menu.item_count - 1, not Actions.is_enabled(FILE_MENU_ACTIONS[i]))
	_file_menu.position = Vector2i(_files.get_screen_position() + at_position)
	_file_menu.reset_size()
	_file_menu.popup()


## The file list's context menu, for tests.
func file_menu() -> PopupMenu:
	return _file_menu


## The file list (for tests).
func files() -> CommitFileList:
	return _files


## Right in the file list moves into the diff.
func _on_files_key(event: InputEvent) -> void:
	var view: DiffView = _diff_panel.view()
	if event.is_action_pressed("ui_right", false, true) and view.row_count() > 0:
		view.grab_focus()
		if view.cursor < 0:
			view.select_only(0)
		_files.accept_event()


func _on_diff_key(event: InputEvent) -> void:
	var view: DiffView = _diff_panel.view()
	if event.is_action_pressed("ui_left", false, true) and view.h_scroll() <= 0.0:
		_files.grab_focus()
		view.accept_event()


## Without a message body the top part shrinks to the summary and its
## details, and can't be dragged.
func _show_body(text: String) -> void:
	_body.text = text
	_body.scroll_to_line(0)
	_body.visible = not text.is_empty()
	_body_separator.visible = _body.visible
	collapsed = not _body.visible


func _apply_theme() -> void:
	_files_box.custom_minimum_size.x = float(get_theme_constant(&"min_files_width", THEME_TYPE))
	_copy_hash.icon = AppTheme.icon(&"ActionCopy")
	var tint: Color = get_theme_color(&"icon_tint", THEME_TYPE)
	var icon_size: float = float(get_theme_constant(&"icon_size", THEME_TYPE))
	for entry: Array in [[%DateIcon, &"Clock"], [%HashIcon, &"GitCommit"]]:
		var rect: TextureRect = entry[0]
		if entry[1] != &"":
			rect.texture = AppTheme.icon(entry[1])
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.custom_minimum_size = Vector2(icon_size, icon_size)
		rect.self_modulate = tint
