extends SmokeTest
## M7.15 P1: the theme's check icons (one look for check boxes, menus, trees
## and switches) and `OptionsPopover` with its segmented choices, toggle
## chips and check rows: values, defaults and the count, the Clear link,
## shortcuts in tooltips, live changes, the keys, Escape giving the focus
## back, and translation.

var _changes: Array[Array] = []
var _popover: OptionsPopover = null


func run() -> void:
	_check_theme()
	await _check_popover()


func _check_theme() -> void:
	for light: bool in [false, true]:
		var theme: Theme = AppTheme.build(light)
		var defaults: Theme = ThemeDB.get_default_theme()
		for icon_name: StringName in [&"checked", &"unchecked", &"radio_checked", &"radio_unchecked", &"checked_disabled"]:
			var icon: Texture2D = theme.get_icon(icon_name, &"CheckBox")
			expect(icon is DPITexture, "CheckBox %s is drawn by the theme (light %s)" % [icon_name, light])
			expect(icon != defaults.get_icon(icon_name, &"CheckBox"), "CheckBox %s is not Godot's" % icon_name)
			expect(theme.get_icon(icon_name, &"PopupMenu") == icon, "menus share the check boxes' %s" % icon_name)
		expect(theme.get_icon(&"checked", &"Tree") == theme.get_icon(&"checked", &"CheckBox"), "trees share the tick")
		expect(theme.get_icon(&"indeterminate", &"Tree") is DPITexture, "trees have a partial box")
		expect(theme.get_icon(&"checked", &"CheckButton").get_width() > theme.get_icon(&"checked", &"CheckBox").get_width(),
				"switches are wider than boxes")
		expect_eq(theme.get_color(&"checkbox_checked_color", &"CheckBox"), Color.WHITE, "the icons keep their own colours")
		expect(theme.get_icon(&"checked", &"CheckBox") != theme.get_icon(&"checked_disabled", &"CheckBox"), "disabled boxes differ")
	var blue: Theme = AppTheme.build(false, Color("4c9cff"))
	var green: Theme = AppTheme.build(false, Color("5cb85c"))
	expect(blue.get_icon(&"checked", &"CheckBox") != green.get_icon(&"checked", &"CheckBox"), "the tick box follows the accent")
	expect(blue.get_icon(&"unchecked", &"CheckBox") == green.get_icon(&"unchecked", &"CheckBox"), "an empty box is cached across accents")
	# The configured theme, as the app applies it (the popover reads its sizes).
	ThemeManager.apply(self)
	for icon_name: StringName in [&"Sliders", &"GitGraph", &"GitBranches", &"LineEndings", &"CommitIncluded", &"CommitExcluded"]:
		expect(AppTheme.icon(icon_name) is DPITexture, "%s is imported as a DPITexture" % icon_name)


func _check_popover() -> void:
	Actions.register(&"test.options_clear", "Clear test filters", "Test", _clear_filters)
	Actions.register(&"test.options_compact", "Compact rows", "Test", func() -> void: pass,
			PackedStringArray(["Ctrl+Alt+F11"]))
	var holder: VBoxContainer = VBoxContainer.new()
	add_child(holder)
	var field: LineEdit = LineEdit.new()
	holder.add_child(field)
	var anchor: Button = Button.new()
	anchor.text = "Options"
	holder.add_child(anchor)
	_popover = OptionsPopover.new()
	holder.add_child(_popover)
	_popover.return_focus = field
	_popover.changed.connect(func(id: String, value: Variant) -> void: _changes.append([id, value]))
	_popover.add_section("Filter", &"test.options_clear", &"Filter")
	_popover.add_chips("Show", [
		{"id": "new", "icon": "FileAdded", "label": "New files", "tint": Color("5cb85c")},
		{"id": "modified", "icon": "FileModified", "label": "Modified files"},
		{"id": "ignored", "icon": "GitIgnore", "label": "Show ignored files"},
	])
	_popover.add_section("View")
	var rows: SegmentedControl = _popover.add_segmented("rows", "Rows", [
		{"id": "compact", "icon": "RowsOneLine", "label": "Compact", "tooltip": "Compact rows", "action": "test.options_compact"},
		{"id": "detailed", "icon": "RowsTwoLine", "label": "Detailed"},
	], "detailed", "detailed")
	_popover.add_chips("Graph", [{"id": "graph", "icon": "GitGraph", "label": "Show graph", "value": true,
		"default": true, "counted": false}])
	_popover.add_section("Branches")
	_popover.add_checks([
		{"id": "branch:main", "icon": "GitBranch", "label": "main", "translate": false},
		{"id": "branch:topic", "icon": "GitBranch", "label": "topic/a-very-long-branch-name", "translate": false, "value": true},
	])
	await get_tree().process_frame

	# Values, defaults and the count.
	expect_eq(_popover.ids(), PackedStringArray(["new", "modified", "ignored", "rows", "graph", "branch:main", "branch:topic"]),
			"every option is listed in order")
	expect_eq(_popover.value("rows"), "detailed", "the segmented control starts on its value")
	expect_eq(_popover.value("graph"), true, "a chip starts on its value")
	expect_eq(_popover.value("nope"), null, "an unknown option has no value")
	expect_eq(_popover.count(), 1, "only the check row away from its default counts")
	expect(not _popover.clear_button(0).visible, "Clear hides while the filters are at their defaults")
	expect(_popover.clear_button(1) == null, "a section without a clear action has no Clear")
	expect(_popover.get_child(0).get_child(1) is HSeparator, "a divider line splits the sections")
	expect(_popover.get_child(0).get_child(0) is VBoxContainer and not _popover.get_child(0).get_child(0) is PanelContainer,
			"sections are not cards")
	expect(not _section_title(0).uppercase, "section titles keep their case")
	expect(_popover.control("new") is ToggleChip, "on/off options are chips")
	expect(_popover.control("branch:main") is CheckBox, "check rows are check boxes")
	expect_eq(_popover.control("branch:main").theme_type_variation, &"OptionsCheck", "check rows use their style")
	expect_eq((_popover.control("branch:topic") as CheckBox).text, "topic/a-very-long-branch-name", "names are not translated")
	expect_eq(rows.choice_button("compact").theme_type_variation, &"SegmentedButtonFirst", "the first segment rounds its left")
	expect_eq(rows.choice_button("detailed").theme_type_variation, &"SegmentedButtonLast", "the last segment rounds its right")
	expect(rows.choice_button("detailed").button_pressed and not rows.choice_button("compact").button_pressed,
			"only the chosen segment is pressed")
	var new_chip: ToggleChip = _popover.control("new") as ToggleChip
	expect_eq(new_chip.get_theme_color(&"icon_normal_color"), Color("5cb85c"), "a tint colours the icon while off")
	expect_eq(new_chip.text, "New files", "chips show their label")

	# Shortcuts in the tooltips.
	expect_eq(rows.choice_button("compact").tooltip_text, "Compact rows (%s)" % Actions.shortcut_label(&"test.options_compact"),
			"a segment's tooltip has its action's shortcut")
	expect_eq(rows.choice_button("detailed").tooltip_text, "Detailed", "without a tooltip or action it is the label")

	# Live changes, the count and Clear.
	new_chip.button_pressed = true
	expect_eq(_changes.back(), ["new", true], "toggling a chip reports it")
	expect_eq(_popover.count(), 2, "a filter on counts")
	expect(_popover.clear_button(0).visible, "Clear shows while a filter is on")
	(_popover.control("graph") as ToggleChip).button_pressed = false
	expect_eq(_popover.count(), 2, "an option that does not count is left out")
	rows.choice_button("compact").pressed.emit()
	expect_eq(_changes.back(), ["rows", "compact"], "choosing a segment reports it")
	expect_eq(_popover.value("rows"), "compact", "the segment is chosen")
	expect(not rows.choice_button("detailed").button_pressed, "the other segment lets go")
	var before: int = _changes.size()
	rows.choice_button("compact").pressed.emit()
	expect_eq(_changes.size(), before, "choosing the chosen segment again reports nothing")
	_popover.clear_button(0).pressed.emit()
	expect(not bool(_popover.value("new")), "Clear runs its action")
	expect(not _popover.clear_button(0).visible, "Clear hides once the filters are back")
	expect_eq(_popover.value("rows"), "compact", "Clear leaves view options alone")
	before = _changes.size()
	_popover.set_value("rows", "detailed")
	_popover.set_value("ignored", true)
	expect_eq(_changes.size(), before, "set_value reports nothing")
	expect_eq(_popover.value("rows"), "detailed", "set_value chooses a segment")
	expect(_popover.clear_button(0).visible, "set_value updates Clear")
	_popover.set_value("ignored", false)

	# Opening, the keys and Escape.
	field.grab_focus()
	_popover.open_below(anchor)
	await get_tree().process_frame
	await get_tree().process_frame
	expect(_popover.visible, "the popover opens")
	expect(_popover.position.y >= int((anchor.get_screen_transform() * anchor.size).y) - 1, "it opens under its anchor")
	expect(new_chip.has_focus(), "the first control has the focus")
	var flow: Control = new_chip.get_parent() as Control
	expect_eq(rows.global_position.x, flow.global_position.x, "the sections' controls start in one column")
	expect(flow.size.x <= float(_popover.get_theme_constant(&"max_width", &"OptionsPopover")), "chips wrap within the popover's width")
	press("Space", _popover)
	await get_tree().process_frame
	expect(bool(_popover.value("new")), "Space toggles the focused chip")
	expect(_popover.visible, "a change keeps the popover open")
	rows.choice_button("detailed").grab_focus()
	press("Left", _popover)
	await get_tree().process_frame
	expect_eq(_popover.value("rows"), "compact", "Left chooses the segment before")
	expect(rows.choice_button("compact").has_focus(), "the focus follows the choice")
	press("Left", _popover)
	expect_eq(_popover.value("rows"), "compact", "Left on the first segment stays")
	press("Right", _popover)
	await get_tree().process_frame
	expect_eq(_popover.value("rows"), "detailed", "Right chooses the segment after")
	press("Escape", _popover)
	await get_tree().process_frame
	expect(not _popover.visible, "Escape closes the popover")
	expect(field.has_focus(), "closing gives the focus back to the field")

	# Translation.
	var locale: String = TranslationServer.get_locale()
	TranslationServer.set_locale("it")
	_popover.notification(NOTIFICATION_TRANSLATION_CHANGED)
	var view_title: Label = _section_title(1)
	expect_eq(view_title.text, "Visualizza", "section titles translate")
	expect_eq(_popover.clear_button(0).text, "Azzera", "Clear translates")
	expect_eq((_popover.control("branch:main") as CheckBox).text, "main", "names stay as they are")
	TranslationServer.set_locale(locale)
	_popover.notification(NOTIFICATION_TRANSLATION_CHANGED)

	Actions.unregister(&"test.options_clear")
	Actions.unregister(&"test.options_compact")
	holder.queue_free()
	await get_tree().process_frame


## Section `index`'s title: its box (a divider between each two), the
## header, then the label after the icon when there is one.
func _section_title(index: int) -> Label:
	var header: Node = _popover.get_child(0).get_child(index * 2).get_child(0)
	return header.get_child(1 if header.get_child(0) is TextureRect else 0) as Label


func _clear_filters() -> void:
	for id: String in ["new", "modified", "ignored"]:
		_popover.set_value(id, false)
