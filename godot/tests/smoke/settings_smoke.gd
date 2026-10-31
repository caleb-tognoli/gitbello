extends SmokeTest
## The categorized Settings window: navigation, search, immediate edits,
## validation, reverting and resetting, and live interface colours.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var before: Dictionary = Core.settings()
	var before_theme: String = Core.theme_choice()
	Core.set_settings({"auto_fetch_minutes": 10, "branch_prefix": "", "accent": "", "language": "en"})
	L10n.apply("en")
	Core.set_theme_choice("system")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	expect(Actions.run_action(&"app.settings"), "Settings opens")
	var settings: SettingsWindow = main.settings_window()
	expect(await wait_until(func() -> bool: return settings.visible), "the settings window shows")

	expect(settings.get_control(&"pull_mode").is_visible_in_tree(), "General is selected first")
	expect(not settings.get_control(&"accent").is_visible_in_tree(), "other categories are hidden")
	settings.show_category("Interface")
	expect(settings.get_control(&"accent").is_visible_in_tree(), "Interface controls show")
	settings.search.set_text("branch prefix")
	expect(settings.get_control(&"branch_prefix").is_visible_in_tree(), "search finds another category")
	expect(not settings.get_control(&"accent").is_visible_in_tree(), "search hides non-matches")
	settings.show_category("General")

	var minutes: SpinBox = settings.get_control(&"auto_fetch_minutes") as SpinBox
	expect(not settings.get_revert_button(&"auto_fetch_minutes").visible, "the default has no revert button")
	minutes.value = 15
	expect_eq(int(Core.settings()["auto_fetch_minutes"]), 15, "the interval saves immediately")
	expect(settings.get_revert_button(&"auto_fetch_minutes").visible, "a changed value can be reverted")
	settings.get_revert_button(&"auto_fetch_minutes").pressed.emit()
	expect_eq(int(Core.settings()["auto_fetch_minutes"]), 10, "revert restores the interval")
	expect_eq(minutes.value, 10.0, "the control follows the reverted value")

	settings.show_category("Worktrees")
	var prefix: LineEdit = settings.get_control(&"branch_prefix") as LineEdit
	prefix.text = "bad prefix"
	prefix.text_submitted.emit(prefix.text)
	expect_eq(String(Core.settings()["branch_prefix"]), "", "an invalid prefix is not saved")
	expect(settings._error.visible, "validation is shown inline")
	prefix.text = "caleb/"
	prefix.text_submitted.emit(prefix.text)
	expect_eq(String(Core.settings()["branch_prefix"]), "caleb/", "a valid prefix saves")

	settings.show_category("Interface")
	var language: OptionButton = settings.get_control(&"language") as OptionButton
	language.select(2)
	language.item_selected.emit(2)
	expect_eq(String(Core.settings()["language"]), "it", "the language choice saves")
	expect_eq(TranslationServer.get_locale(), "it", "the language applies immediately")
	settings.get_revert_button(&"language").pressed.emit()
	expect_eq(String(Core.settings()["language"]), "system", "revert restores the System language")
	var theme: OptionButton = settings.get_control(&"theme") as OptionButton
	theme.select(2)
	theme.item_selected.emit(2)
	expect_eq(Core.theme_choice(), "light", "the theme choice saves")
	expect(ThemeManager.light, "the theme applies immediately")
	var accent: ColorPickerButton = settings.get_control(&"accent") as ColorPickerButton
	accent.color = Color("e0569a")
	accent.color_changed.emit(accent.color)
	expect_eq(String(Core.settings()["accent"]), "#e0569a", "the accent saves")
	expect(ThemeManager.accent.is_equal_approx(Color("e0569a")), "the accent applies immediately")
	settings.get_revert_button(&"accent").pressed.emit()
	expect_eq(String(Core.settings()["accent"]), "", "the default accent is restored")

	minutes.value = 20
	settings.custom_action.emit(&"reset")
	expect(settings._reset.visible, "Reset All asks for confirmation")
	settings._reset.confirmed.emit()
	expect_eq(int(Core.settings()["auto_fetch_minutes"]), 10, "Reset All restores settings")
	expect_eq(Core.theme_choice(), "system", "Reset All restores the theme")
	expect_eq(String(Core.settings()["language"]), "system", "Reset All restores the language")
	settings._reset.hide()
	settings.hide()

	Core.set_settings(before)
	Core.set_theme_choice(before_theme)
	L10n.apply(String(before.get("language", "system")))
	main.queue_free()
	await get_tree().process_frame
