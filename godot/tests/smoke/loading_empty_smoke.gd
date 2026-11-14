extends SmokeTest
## The loading indicator (nothing before the show delay, the spinner on a
## first load, the line on a reload, clicks through) and the compact empty
## state (icon, title, one button with its icon, clicks through elsewhere,
## filled in before it is ready).


func run() -> void:
	var panel: Control = Control.new()
	panel.size = Vector2(400, 300)
	add_child(panel)
	var loading: LoadingIndicator = LoadingIndicator.new()
	panel.add_child(loading)
	await get_tree().process_frame

	loading.show_loading(true, "Loading diff…")
	expect(loading.is_blocking() and not loading.is_shown(), "nothing shows before the delay")
	await get_tree().create_timer(LoadingIndicator.SHOW_DELAY + 0.15).timeout
	expect(loading.is_shown(), "the spinner shows after the delay")
	expect_eq(loading.caption_text(), "Loading diff…", "the caption sits under the spinner")
	expect_eq(loading.mouse_filter, Control.MOUSE_FILTER_IGNORE, "clicks go through a load")

	loading.show_loading(false, "Updating…")
	expect(loading.is_shown() and not loading.is_blocking(), "a reload shows the line at once")
	loading.hide_loading()
	expect(not loading.visible and not loading.is_loading(), "hiding stops it")

	var empty: EmptyState = EmptyState.create_compact()
	var pressed: Array[int] = [0]
	# Filled in before it enters the tree: applied once it is ready.
	empty.show_no_match(func() -> void: pressed[0] += 1)
	panel.add_child(empty)
	await get_tree().process_frame
	expect_eq(empty.title(), "No matches", "the title shows once ready")
	expect_eq(empty.shown_icon(), &"Search", "with its icon")
	expect_eq(empty.button_labels(), PackedStringArray(["Clear filter"]), "and its one button")
	expect(empty.first_button().icon != null, "the button has an icon")
	expect(empty.press("Clear filter") and pressed[0] == 1, "the button runs its action")
	expect_eq(empty.mouse_filter, Control.MOUSE_FILTER_IGNORE, "clicks go through the compact form")
	expect_eq(empty.first_button().mouse_filter, Control.MOUSE_FILTER_STOP, "except on its button")
	empty.show_compact(&"TextFile", "No file selected")
	expect(empty.button_labels().is_empty(), "a state without a button shows none")
	var locale: String = TranslationServer.get_locale()
	TranslationServer.set_locale("it")
	await get_tree().process_frame
	expect_eq(empty.title(), "Nessun file selezionato", "the title follows the language")
	TranslationServer.set_locale(locale)
	await get_tree().process_frame
	panel.queue_free()
