extends SmokeTest
## TooltipCard (M7.17): the card a tooltip text describes (label, key caps,
## facts), plain texts left to Godot's label, `ActionRegistry.tooltip`'s
## text, and the hook on a popup built like Godot's tooltip (a real hover is
## in `tests/visual/tooltip_screenshots.tscn`: headless Godot shows no tooltips).


func run() -> void:
	var card: TooltipCard = TooltipCard.from_text("Fetch\tCtrl+Shift+F\nNothing to fetch")
	expect_eq(card.texts(), PackedStringArray(["Fetch · %s" % "+".join(Shortcuts.display_keys("Ctrl+Shift+F")),
			"Nothing to fetch"]), "a card has the label with its keys, then the fact")
	card.free()
	expect(not TooltipCard.wants_card("Dismiss"), "a one-line text stays a plain tooltip")
	expect(TooltipCard.wants_card("Dismiss\tEscape") and TooltipCard.wants_card("Commit\nWrite a summary"),
			"a shortcut or a second line makes a card")
	expect_eq(TooltipCard.text_for("Push", "Ctrl+P", PackedStringArray(["", "2 commits"])), "Push\tCtrl+P\n2 commits",
			"empty facts are left out")

	Actions.register(&"test.tooltip", "Test tooltip action", "Test", func() -> void: pass,
			PackedStringArray(["Ctrl+Alt+F9"]), func() -> bool: return false, func() -> String: return "Not now")
	Actions.get_action(&"test.tooltip").menu_label = "Test"
	expect_eq(Actions.tooltip(&"test.tooltip"), "Test\tCtrl+Alt+F9\nNot now",
			"an action's tooltip: its short label, shortcut and why it is disabled")
	Actions.unregister(&"test.tooltip")

	# The hook on a popup built like Godot's tooltip.
	TooltipCard.install(get_tree())
	var panel: PopupPanel = PopupPanel.new()
	var label: Label = Label.new()
	label.theme_type_variation = &"TooltipLabel"
	label.text = "Switch…\tCtrl+B"
	panel.add_child(label)
	add_child(panel)
	var built: TooltipCard = label.get_node_or_null(^"TooltipCard") as TooltipCard
	expect(built != null and label.text.is_empty(), "the hook draws the card in place of the label's text")
	expect(built != null and label.custom_minimum_size.x >= built.get_combined_minimum_size().x - 0.5
			and label.custom_minimum_size.x > 0.0, "and sizes the label to the card")
	panel.queue_free()
