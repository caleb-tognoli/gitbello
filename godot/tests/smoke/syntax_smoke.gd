extends SmokeTest
## M7.13: syntax highlighting. Core lists the token kinds; every kind
## resolves, in both themes, to its own colour, its parent's or plain text,
## and the theme's colours read on the diff's backgrounds: 4.5:1 on
## unchanged lines and 3:1 on added and removed lines, except the shortfalls
## listed in `KNOWN_SHORT`. What the view draws (`AppTheme.syntax_color_tables`
## and plain text through `AppTheme.readable`) reaches 4.5:1 on every
## background, changed words and the selection included, also with chosen
## added and removed colours at the extremes; on unchanged lines it is the
## theme's colours unchanged. With
## `--fixtures`, the `syntax` fixture's diffs carry their language: by
## extension, and by shebang for `bin/tool`; their line states are found, so
## the second line of a block comment is coloured as one.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
## Contrast on unchanged lines and on added/removed lines.
const MIN_CONTEXT_CONTRAST: float = 4.5
const MIN_CHANGED_CONTRAST: float = 3.0
## `<theme>:<kind>` colours below `MIN_CONTEXT_CONTRAST` on unchanged lines,
## accepted for now (a kind that reads must leave the list).
const KNOWN_SHORT: Array[String] = []


func run() -> void:
	_check_kinds()
	for light: bool in [false, true]:
		_check_theme(light)
		_check_tables(light, Color.TRANSPARENT, Color.TRANSPARENT)
		# Chosen colours at the extremes Settings allows (any opaque colour).
		_check_tables(light, Color.WHITE, Color.BLACK)
		_check_tables(light, Color(0.0, 1.0, 0.0), Color(1.0, 0.0, 1.0))
	await _check_fixture()


func _check_kinds() -> void:
	var kinds: Array[Dictionary] = RepoSession.syntax_kinds()
	expect(kinds.size() >= 5, "core lists the token kinds")
	var names: Array[String] = []
	for kind: Dictionary in kinds:
		names.append(String(kind["name"]))
	expect_eq(names.slice(0, 5), ["keyword", "type", "string", "number", "comment"] as Array[String],
			"the first five keep their ids")
	for kind: Dictionary in kinds:
		var parent: String = kind["parent"]
		expect(parent.is_empty() or names.find(parent) < names.find(String(kind["name"])),
				"%s's parent %s comes first" % [kind["name"], parent])


func _check_theme(light: bool) -> void:
	var theme_name: String = "light" if light else "dark"
	var probe: Control = Control.new()
	probe.theme = AppTheme.build(light)
	add_child(probe)
	var kinds: Array[Dictionary] = RepoSession.syntax_kinds()
	var colors: PackedColorArray = AppTheme.syntax_colors(probe, &"DiffView", Color.TRANSPARENT)
	expect_eq(colors.size(), kinds.size(), "%s: a colour per kind" % theme_name)
	var minimap: PackedColorArray = AppTheme.syntax_colors(probe, &"DiffMinimap", Color.TRANSPARENT)
	expect_eq(minimap.size(), kinds.size(), "%s: a minimap colour per kind" % theme_name)
	var background: Color = AppTheme.palette(light).background
	var changed: Array[Color] = []
	for color_name: StringName in [&"added_bg", &"removed_bg"]:
		changed.append(probe.get_theme_color(color_name, &"DiffView"))
	for i: int in mini(colors.size(), kinds.size()):
		var kind_name: String = kinds[i]["name"]
		var color: Color = colors[i]
		if color.a == 0.0:
			# Plain text: neither the kind nor an ancestor has a colour.
			expect(not probe.has_theme_color(AppTheme.syntax_color_name(kind_name), &"DiffView"),
					"%s: %s is plain only without a colour" % [theme_name, kind_name])
			continue
		# Derived kinds share their parent's colour: check the ones with their own.
		if not probe.has_theme_color(AppTheme.syntax_color_name(kind_name), &"DiffView"):
			continue
		var on_context: float = AppTheme.contrast_ratio(color, background)
		var short: bool = KNOWN_SHORT.has("%s:%s" % [theme_name, kind_name])
		if short:
			expect(on_context < MIN_CONTEXT_CONTRAST,
					"%s: %s reads now (%.2f:1): drop it from KNOWN_SHORT" % [theme_name, kind_name, on_context])
		else:
			expect(on_context >= MIN_CONTEXT_CONTRAST, "%s: %s reads on unchanged lines (%.2f:1)"
					% [theme_name, kind_name, on_context])
		for bg: Color in changed:
			var on_changed: float = AppTheme.contrast_ratio(color, bg)
			expect(on_changed >= MIN_CHANGED_CONTRAST, "%s: %s reads on %s (%.2f:1)"
					% [theme_name, kind_name, bg.to_html(false), on_changed])
	probe.queue_free()


## The colours the view draws with, on every background of a theme built with
## `added` and `removed` (transparent: the theme's own).
func _check_tables(light: bool, added: Color, removed: Color) -> void:
	var label: String = ("light" if light else "dark") + (
			"" if added.a == 0.0 else " with %s/%s" % [added.to_html(false), removed.to_html(false)])
	var probe: Control = Control.new()
	probe.theme = AppTheme.build(light, AppTheme.DEFAULT_ACCENT, added, removed)
	add_child(probe)
	var kinds: Array[Dictionary] = RepoSession.syntax_kinds()
	var colors: PackedColorArray = AppTheme.syntax_colors(probe, &"DiffView", Color.TRANSPARENT)
	var tables: Dictionary[StringName, PackedColorArray] = AppTheme.syntax_color_tables(probe)
	var backgrounds: Dictionary[StringName, Color] = AppTheme.diff_backgrounds(probe)
	expect_eq(tables.keys(), backgrounds.keys(), "%s: a table per background" % label)
	expect(backgrounds.has(&"added_word") and backgrounds.has(&"selection_theirs"),
			"%s: the backgrounds include changed words and the selection" % label)
	var plain: Color = probe.get_theme_color(&"text_color", &"DiffView")
	var moved: Array[String] = []
	for bg_name: StringName in tables:
		var table: PackedColorArray = tables[bg_name]
		var bg: Color = backgrounds[bg_name]
		expect_eq(table.size(), colors.size(), "%s: %s has a colour per kind" % [label, bg_name])
		var changed: int = 0
		for i: int in mini(table.size(), kinds.size()):
			if table[i].a == 0.0:
				expect(colors[i].a == 0.0, "%s: %s keeps plain kinds plain" % [label, bg_name])
				continue
			var ratio: float = AppTheme.contrast_ratio(table[i], bg)
			expect(ratio >= AppTheme.MIN_TEXT_CONTRAST - 0.01, "%s: %s reads on %s (%.2f:1)"
					% [label, kinds[i]["name"], bg_name, ratio])
			if not table[i].is_equal_approx(colors[i]):
				changed += 1
				if bg_name == &"unchanged" and added.a == 0.0:
					expect(false, "%s: %s changed on unchanged lines" % [label, kinds[i]["name"]])
		var text: Color = AppTheme.readable(plain, bg)
		var on_text: float = AppTheme.contrast_ratio(text, bg)
		expect(on_text >= AppTheme.MIN_TEXT_CONTRAST - 0.01, "%s: plain text reads on %s (%.2f:1)"
				% [label, bg_name, on_text])
		moved.append("%s %d" % [bg_name, changed])
	print("  %s: colours moved per background: %s" % [label, ", ".join(moved)])
	probe.queue_free()


func _check_fixture() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("syntax_smoke: no --fixtures, fixture checks skipped")
		return
	Core.set_diff_mode("text", "unified")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(fixtures.path_join("syntax"))
	var session: RepoSession = page.session
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var view: DiffView = changes.diff_panel().view()
	expect(await wait_until(func() -> bool: return session.change_count() > 5), "the samples changed")
	for entry: Array in [["rust/sample.rs", "rust"], ["markdown/sample.md", "markdown"],
			["bin/tool", "python"], ["typescript/sample.ts", "typescript"],
			["godot_resource/sample.tscn", "godot_resource"], ["makefile/sample.mk", "makefile"],
			["html/sample.html", "html"], ["diff/sample.diff", "diff"], ["ruby/sample.rb", "ruby"],
			["batch/sample.bat", "batch"], ["zig/sample.zig", "zig"],
			["razor/sample.razor", "razor"], ["razor/sample.cshtml", "razor"],
			["php/sample-html.php", "php"],
			# Last: the TSV check below reads its diff.
			["tsv/sample.tsv", "tsv"]]:
		var path: String = entry[0]
		expect(await _select(changes, session, path), "%s's diff loads" % path)
		expect_eq(String(session.diff_info().get("language", "")), String(entry[1]), "%s's language" % path)
		var coloured: bool = false
		for row: int in view.row_count():
			if not (view.row_data(row).get("syntax", PackedInt32Array()) as PackedInt32Array).is_empty():
				coloured = true
				break
		expect(coloured, "%s has coloured rows" % path)
		if path == "rust/sample.rs":
			await _check_states(session, view)
	# TSV fields are found by their tabs and coloured where the tabs are shown.
	var tsv_row: Dictionary = {}
	for row: int in view.row_count():
		if String(view.row_data(row).get("text", "")).begins_with("1   Ada"):
			tsv_row = view.row_data(row)
	var spans: PackedInt32Array = tsv_row.get("syntax", PackedInt32Array())
	expect(spans.size() >= 9 and spans[3] == 1 and spans[4] == 4 and spans[6] == 4,
			"the first TSV delimiter covers its tab's columns: %s" % [spans])
	main.queue_free()
	await get_tree().process_frame


## P5a: once the diff's line states are found, a line inside a block comment
## opened on the line above is coloured as a comment.
func _check_states(session: RepoSession, view: DiffView) -> void:
	expect(await wait_until(func() -> bool: return String(session.diff_info().get("states", "")) == "ready"),
			"the line states are found: %s" % session.diff_info().get("states", ""))
	var comment: int = -1
	var kinds: Array[Dictionary] = RepoSession.syntax_kinds()
	for i: int in kinds.size():
		if String(kinds[i]["name"]) == "comment":
			comment = i
	var spans: PackedInt32Array = PackedInt32Array()
	for row: int in view.row_count():
		if String(view.row_data(row).get("text", "")).strip_edges() == "over two lines */":
			spans = view.row_data(row).get("syntax", PackedInt32Array())
	expect(spans.size() == 3 and spans[0] == 0 and spans[2] == comment,
			"the second line of a block comment is a comment: %s" % [spans])


func _select(changes: ChangesView, session: RepoSession, path: String) -> bool:
	var index: int = -1
	for row: int in changes.list().row_count():
		if changes.list().path_at(row) == path:
			index = row
	if index < 0:
		return false
	changes.list().select_only(index)
	return await wait_until(func() -> bool:
		var info: Dictionary = session.diff_info()
		return String(info.get("path", "")) == path and String(info.get("state", "")) == "ready")
