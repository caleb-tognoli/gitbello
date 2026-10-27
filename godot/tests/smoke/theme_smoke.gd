extends SmokeTest
## AppTheme: readable text in both themes with any accent, icons recoloured
## for the light theme, and the accent setting saved and applied.

## Odd accents on top of the presets: very light, very dark, saturated.
const EXTRA_ACCENTS: Array[Color] = [Color.WHITE, Color.BLACK, Color("ffee00"), Color("00ff00")]


func run() -> void:
	var accents: Array[Color] = AppTheme.ACCENT_PRESETS + EXTRA_ACCENTS
	for light: bool in [false, true]:
		var name: String = "light" if light else "dark"
		for accent: Color in accents:
			var p: AppTheme.Palette = AppTheme.palette(light, accent)
			for background: Color in [p.selected, p.selected_focus, p.selected.blend(p.hovered),
					p.selected_focus.blend(p.hovered)]:
				_expect_readable(p.selected_text, background,
						"%s, accent %s: selected-row text" % [name, accent.to_html(false)])
		var p: AppTheme.Palette = AppTheme.palette(light)
		for background: Color in [p.background, p.surface, p.raised, p.hover]:
			_expect_readable(p.text, background, "%s: text" % name)
		for background: Color in [p.background, p.surface, p.raised]:
			_expect_readable(p.text_muted, background, "%s: muted text" % name)
		var theme: Theme = AppTheme.build(light)
		var discard: Button = Button.new()
		discard.theme = theme
		discard.theme_type_variation = &"ShelfDiscardButton"
		var padding: Vector2 = discard.get_theme_stylebox(&"normal").get_minimum_size()
		for state: StringName in [&"hover", &"pressed", &"hover_pressed"]:
			expect_eq(discard.get_theme_stylebox(state).get_minimum_size(), padding,
					"%s: Discard padding stays stable in %s" % [name, state])
		discard.free()
		var label_text: Color = theme.get_color(&"label_color", &"CommitList")
		for label: StringName in [&"label_head", &"label_branch", &"label_remote", &"label_tag"]:
			var box: StyleBoxFlat = theme.get_stylebox(label, &"CommitList") as StyleBoxFlat
			_expect_readable(label_text, box.bg_color, "%s: ref label %s" % [name, label])
		var close: DPITexture = AppTheme.CLOSE as DPITexture
		expect(close != null, "icons are DPITextures")
		if close != null:
			expect_eq(close.color_map.is_empty(), not light, "%s: icons recoloured" % name)
		for icon: StringName in [&"GitBranch", &"GitPush", &"GitPull", &"GitFetch", &"GitWorktree",
				&"GitShelf", &"GitTag", &"Terminal"]:
			expect(AppTheme.icon(icon) is DPITexture, "icon %s loads" % icon)
	AppTheme.build(false)

	# The accent setting: saved through core, normalised, and empty for the default.
	var before: String = String(Core.settings()["accent"])
	expect_eq(Core.set_settings({"accent": "#E0569A"}), "", "accent saved")
	expect_eq(String(Core.settings()["accent"]), "#e0569a", "accent normalised")
	expect(ThemeManager.configured_accent().is_equal_approx(Color("e0569a")), "accent read back")
	expect(not Core.set_settings({"accent": "pink"}).is_empty(), "a bad accent is refused")
	expect_eq(Core.set_settings({"accent": before}), "", "accent restored")
	await get_tree().process_frame


func _expect_readable(text: Color, background: Color, what: String) -> void:
	var ratio: float = AppTheme.contrast_ratio(text, background)
	expect(ratio >= AppTheme.MIN_CONTRAST, "%s contrast %.2f < %.1f" % [what, ratio, AppTheme.MIN_CONTRAST])
