extends SmokeTest
## English/Italian catalog integrity, locale selection, live UI updates and
## settings persistence. Source strings are keys; user content is never looked up.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const CATALOG: String = "res://localization/gitbello.csv"


func run() -> void:
	_check_catalog()
	var before: Dictionary = Core.settings()
	var before_locale: String = TranslationServer.get_locale()
	L10n.set_choice("en")
	expect_eq(L10n.resolved("system", "it_IT"), "it", "System resolves an Italian OS locale")
	expect_eq(L10n.resolved("system", "IT"), "it", "System locale matching ignores case")
	expect_eq(L10n.resolved("system", "en_US"), "en", "System resolves English")
	expect_eq(L10n.resolved("system", "fr_FR"), "en", "Unsupported OS locales fall back to English")
	expect_eq(L10n.resolved("en", "it_IT"), "en", "An explicit choice overrides the OS")
	expect_eq(L10n.resolved("invalid", "it_IT"), "en", "Invalid choices fall back to English")

	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var settings: SettingsWindow = main.settings_window()
	expect_eq(Actions.get_action(&"app.settings").label, "Settings…", "actions use English source text")
	L10n.set_choice("it")
	await get_tree().process_frame
	expect_eq(TranslationServer.get_locale(), "it", "Italian applies immediately")
	expect_eq(String(Core.settings()["language"]), "it", "the language choice persists")
	expect_eq(Actions.get_action(&"app.settings").label, "Impostazioni…", "actions translate on access")
	expect_eq(Actions.get_action(&"worktree.select_1").label, "Mostra worktree 1", "formatted actions update live")
	expect_eq(Actions.get_action(&"view.theme_system").label, "Tema: Sistema", "formatted theme actions update live")
	expect_eq(settings.title, "Impostazioni", "open Settings controls update live")
	expect_eq(settings.categories.get_item_text(2), "Interfaccia", "Settings categories translate")
	var language: OptionButton = settings.get_control(&"language") as OptionButton
	expect_eq(language.get_item_text(0), "Sistema", "Settings options translate")
	expect_eq(language.get_item_text(2), "Italiano", "the Italian language option translates")
	var minutes: SpinBox = settings.get_control(&"auto_fetch_minutes") as SpinBox
	expect_eq(minutes.suffix, " min", "Settings numeric suffixes use the catalog")
	settings.open()
	settings.search.set_text("lingua")
	expect(settings.get_control(&"language").is_visible_in_tree(), "Settings search accepts translated text")
	settings.search.set_text("")
	expect_eq(L10n.launch_error("unmatched quote in `code {path}`"), "Virgoletta non chiusa in `code {path}`.",
			"launch errors translate without changing the command")
	expect_eq(L10n.launch_error("`missing-tool` was not found; check the command in the settings"),
			"`missing-tool` non trovato. Controlla il comando nelle Impostazioni.", "missing program names stay unchanged")
	expect_eq(L10n.launch_error("raw execution error"), "raw execution error", "unknown execution errors stay unchanged")
	expect_eq(L10n.runtime_error("git --version: git executable not found"),
			"git --version: eseguibile Git non trovato", "startup errors preserve the Git command")
	expect_eq(L10n.config_error("cannot read C:\\tmp\\settings.toml: access denied"),
			"Impossibile leggere C:\\tmp\\settings.toml: access denied", "config errors preserve paths and OS details")
	expect_eq(L10n.config_error("`language` must be \"system\", \"en\" or \"it\""),
			"`language` deve essere \"system\", \"en\" o \"it\"", "config validation translates its fixed text")

	var hidden: Array[int] = [1]
	var diff: DiffView = DiffView.new()
	diff.source = func(_start: int, _count: int) -> Array:
		return [{"kind": DiffView.KIND_HUNK, "text": "@@", "expand": "both", "gap": 1, "hidden": hidden[0]}]
	main.add_child(diff)
	diff.show_lines(1, 1, false)
	expect_eq(diff.expander_label(0), "1 riga nascosta", "Italian singular line text is grammatical")
	hidden[0] = 2
	diff.invalidate()
	expect_eq(diff.expander_label(0), "2 righe nascoste", "Italian plural line text is grammatical")
	diff.queue_free()

	var invalid: String = Core.set_settings({"language": "fr"})
	expect(not invalid.is_empty(), "Core rejects an invalid language")
	expect_eq(String(Core.settings()["language"]), "it", "an invalid language does not replace the saved choice")
	expect(not L10n.set_choice("fr").is_empty(), "the locale manager rejects an invalid language")
	settings.reset_to_defaults()
	expect_eq(String(Core.settings()["language"]), "system", "Reset All restores the System language")
	expect_eq(TranslationServer.get_locale(), L10n.resolved("system"), "Reset All applies the System language")
	L10n.set_choice("en")
	await get_tree().process_frame
	expect_eq(Actions.get_action(&"app.settings").label, "Settings…", "switching back to English updates actions")
	expect_eq(settings.title, "Settings", "switching back to English updates open controls")

	Core.set_settings(before)
	L10n.apply(String(before.get("language", "system")))
	if before_locale != TranslationServer.get_locale():
		TranslationServer.set_locale(before_locale)
	main.queue_free()
	await get_tree().process_frame


func _check_catalog() -> void:
	var file: FileAccess = FileAccess.open(CATALOG, FileAccess.READ)
	expect(file != null, "the translation catalog opens")
	if file == null:
		return
	var keys: Dictionary = {}
	var placeholder_pattern: RegEx = RegEx.new()
	placeholder_pattern.compile("%(?:\\d+\\$)?[sdif%]")
	while not file.eof_reached():
		var row: PackedStringArray = file.get_csv_line()
		if row.is_empty() or (row.size() == 1 and row[0].is_empty()):
			continue
		expect_eq(row.size(), 3, "catalog row %d has key, English and Italian" % file.get_position())
		if row.size() != 3:
			continue
		expect(not row[0].is_empty(), "catalog keys are not empty")
		expect(not keys.has(row[0]), "catalog key is unique: %s" % row[0])
		expect(not row[1].is_empty() and not row[2].is_empty(), "both translations exist: %s" % row[0])
		keys[row[0]] = true
		for column: int in [1, 2]:
			var placeholders: Array[String] = []
			for found: RegExMatch in placeholder_pattern.search_all(row[column]):
				placeholders.append(found.get_string())
			placeholders.sort()
			var source_placeholders: Array[String] = []
			for found: RegExMatch in placeholder_pattern.search_all(row[0]):
				source_placeholders.append(found.get_string())
			source_placeholders.sort()
			expect_eq(placeholders, source_placeholders, "placeholders match in %s (column %d)" % [row[0], column])
	file.close()

	var call_pattern: RegEx = RegEx.new()
	call_pattern.compile("(?:\\btr|TranslationServer\\.translate)\\(\\s*&?\"([^\"]*)\"")
	for path: String in _scripts("res://app") + _scripts("res://ui"):
		var source: String = read_file(path)
		for found: RegExMatch in call_pattern.search_all(source):
			var key: String = found.get_string(1)
			expect(keys.has(key), "literal translation exists in %s: %s" % [path, key])


func _scripts(path: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for file: String in DirAccess.get_files_at(path):
		if file.ends_with(".gd"):
			out.append(path.path_join(file))
	for directory: String in DirAccess.get_directories_at(path):
		out.append_array(_scripts(path.path_join(directory)))
	return out
