extends SmokeTest
## Required project settings (PLAN §3.7), the shell layout and app branding.


func run() -> void:
	expect_eq(ProjectSettings.get_setting("application/run/low_processor_mode"), true,
			"low processor mode")
	expect_eq(ProjectSettings.get_setting("display/window/dpi/allow_hidpi"), true, "HiDPI")
	expect_eq(ProjectSettings.get_setting("debug/gdscript/warnings/untyped_declaration"), 2,
			"untyped-declaration warning is an error")

	var main_path: String = ProjectSettings.get_setting("application/run/main_scene")
	var packed: PackedScene = load(main_path) as PackedScene
	expect(packed != null, "main scene loads")
	if packed == null:
		return

	var main: Node = packed.instantiate()
	add_child(main)
	await get_tree().process_frame
	expect_eq(get_window().title, "%s - gitbello %s" % [tr("Home"), Core.core_version()],
			"empty Home window title includes the app version")
	expect(main.get_node_or_null("Layout/StatusBar") == null, "main scene has no status bar")
	var body: Control = main.get_node("Layout/Body") as Control
	var shell_rect: Rect2 = (main as Control).get_global_rect()
	expect(is_equal_approx(body.get_global_rect().end.y, shell_rect.end.y),
			"main content fills the space to the bottom of the shell")

	# Branding: the icons exist, Home's welcome and About show the logo.
	for setting: String in ["application/config/icon", "application/config/windows_native_icon",
			"application/boot_splash/image"]:
		var path: String = ProjectSettings.get_setting(setting)
		expect(FileAccess.file_exists(path), "%s exists (%s)" % [setting, path])
	expect(AppTheme.logo() != null, "the logo loads")
	var shell: Main = main as Main
	expect(shell.home().empty_state().has_logo(), "the welcome screen shows the logo")
	Actions.run_action(&"app.about")
	var about: AboutDialog = shell.about_dialog()
	expect(about.visible and about.has_logo(), "About shows the logo")
	expect(about.text().contains(Core.core_version()), "About shows the version")
	expect(about.text().contains(tr(AboutDialog.TAGLINE)), "About shows the tagline")
	expect_eq(ProjectSettings.get_setting("application/config/description"), AboutDialog.TAGLINE,
			"the project description is the tagline")
	var italian: Translation = TranslationServer.get_translation_object("it")
	expect(italian != null and String(italian.get_message(AboutDialog.TAGLINE)).begins_with("Una GUI Git"),
			"the tagline has an Italian translation")
	about.hide()
	main.queue_free()
