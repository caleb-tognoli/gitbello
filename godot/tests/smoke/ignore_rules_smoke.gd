extends SmokeTest
## The ignore rules viewer and the rest of M7.7b, on a repository built here
## in the fixtures folder: Repository → Ignore rules… with every source and
## what each line decides, Stop tracking… and Remove rule with Undo, the Add
## rules menu, "Show ignored files" with Stop ignoring, the global target of
## the Ignore dialog and the folder hint. The global excludes file is a
## scratch file set in the smoke's scratch global config (`GIT_CONFIG_GLOBAL`);
## that part is skipped without one. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("ignore_rules_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("ignore-rules")
	var global_file: String = fixtures.path_join("global ignore")
	var scratch_global: bool = not OS.get_environment("GIT_CONFIG_GLOBAL").is_empty()
	_build_repo(repo)
	if scratch_global:
		write_file(global_file, "*.bak\n")
		_git(repo, ["config", "--global", "core.excludesFile", global_file])
		write_file(repo.path_join("z.bak"), "b\n")

	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.change_index("new.txt") >= 0), "the repository loads")
	page.show_view(WorktreeView.View.CHANGES)
	var view: ChangesView = page.changes()
	var ops: IgnoreOps = view.ignore_ops()

	# The folder hint: node_modules/ is build output or downloads.
	expect(await wait_until(func() -> bool: return view.hint_bar().visible), "the hint bar shows")
	expect("node_modules/" in view.hint_text(), "it names the folder: %s" % view.hint_text())
	var menu: PopupMenu = view.hint_menu()
	expect_eq(menu.item_count, 2, "its close menu: this folder, or never")
	menu.id_pressed.emit(0)
	expect(not view.hint_bar().visible, "Don't suggest node_modules/ again hides it")
	view.reload()
	expect(not view.hint_bar().visible, "and it stays hidden")
	Core.set_repo_ui_state(session.repo_path(), ChangesView.HINT_STATE + str("node_modules".hash()), 0)
	view.reload()
	expect(view.hint_bar().visible, "it comes back once the folder is no longer kept")
	menu.id_pressed.emit(1)
	expect(not bool(Core.settings()["ignore_hint"]), "Never suggest turns the setting off")
	expect(not view.hint_bar().visible, "and hides the hint")
	Core.set_settings({"ignore_hint": true})
	view.reload()
	expect(view.hint_bar().visible, "the setting brings it back")
	Actions.run_action(&"changes.ignore_hint")
	expect(await wait_until(func() -> bool: return read_file(repo.path_join(".gitignore")).ends_with("/node_modules/\n")),
			"Ignore writes the folder rule: %s" % read_file(repo.path_join(".gitignore")))
	expect(await wait_until(func() -> bool: return not view.hint_bar().visible), "and the hint goes")
	Actions.run_action(&"changes.undo_ignore")
	expect(await wait_until(func() -> bool: return not read_file(repo.path_join(".gitignore")).contains("node_modules")),
			"Undo takes the folder rule back")

	# The viewer: every source and what each line decides.
	expect(Actions.is_enabled(&"repo.ignore_rules"), "Repository → Ignore rules… is enabled")
	Actions.run_action(&"repo.ignore_rules")
	var dialog: IgnoreRulesDialog = main.ignore_rules_dialog()
	expect(dialog.visible, "the viewer opens")
	expect(await wait_until(func() -> bool: return dialog.sources().size() >= 3), "the sources load")
	var sources: PackedStringArray = dialog.sources()
	expect_eq(sources[0], ".gitignore  2", "the root file hides a.log and build/")
	expect_eq(sources[1], "src/.gitignore  1", "the nested one hides src/t.tmp")
	expect(sources[2].begins_with("My computer"), "info/exclude: %s" % sources[2])
	if scratch_global:
		expect_eq(sources[3], "Global setting  1", "the global file hides z.bak")
	var lines: PackedStringArray = dialog.lines()
	expect_eq(lines[0], "1  *.log  Hides 1 file; 1 tracked file matches", "a rule with a tracked match")
	expect_eq(lines[1], "2  # build output  ", "a comment does nothing")
	expect_eq(lines[2], "3  /build/  Hides 1 folder", "a folder rule")
	expect_eq(lines[3], "4  !keep.log  Brings back 1 file", "a negation")
	expect_eq(lines[4], "5  unused/  Matches nothing", "an unused rule")
	expect(dialog.select_line_text("*.log"), "the *.log line can be selected")
	expect_eq(dialog.hidden_list().texts(), PackedStringArray(["(tracked) tracked.log", "a.log"]),
			"what *.log matches, the tracked file first")
	expect_eq(dialog.recap(), "1 file, 1 tracked", "the recap")
	expect(dialog.button("untrack").visible, "Stop tracking… shows for it")
	expect(not dialog.button("remove").disabled, "and Remove is enabled")

	# Stop tracking…, confirmed, then Undo.
	dialog.press("untrack")
	var confirm: ConfirmationDialog = ops.untrack_confirmation()
	expect(confirm.visible, "Stop tracking asks first")
	expect("1 file" in confirm.dialog_text, "the question counts the files: %s" % confirm.dialog_text)
	confirm.get_ok_button().pressed.emit()
	expect(await wait_until(func() -> bool: return _git(repo, ["ls-files", "tracked.log"]).is_empty()),
			"tracked.log is no longer tracked")
	expect(FileAccess.file_exists(repo.path_join("tracked.log")), "it stays on disk")
	expect(await wait_until(func() -> bool: return dialog.lines()[0].ends_with("Hides 2 files")),
			"the viewer reloads: %s" % dialog.lines()[0])
	Actions.run_action(&"changes.undo_ignore")
	expect(await wait_until(func() -> bool: return not _git(repo, ["ls-files", "tracked.log"]).is_empty()),
			"Undo tracks it again")

	# Remove rule, then Undo.
	expect(await wait_until(func() -> bool: return dialog.select_line_text("unused/")), "the unused line is listed")
	dialog.chip(0).menu_requested.emit(Vector2(8, 8))
	var chip_menu: PopupMenu = dialog.chip_menu()
	expect(chip_menu.visible and chip_menu.get_item_text(0) == "Open file", "a chip's menu opens its file")
	chip_menu.hide()
	dialog.press("remove")
	expect(await wait_until(func() -> bool: return not read_file(repo.path_join(".gitignore")).contains("unused/")),
			"Remove rule takes the line out")
	expect(await wait_until(func() -> bool: return dialog.lines().size() == 4), "the viewer shows 4 lines")
	Actions.run_action(&"changes.undo_ignore")
	expect(await wait_until(func() -> bool: return read_file(repo.path_join(".gitignore")).contains("unused/")),
			"Undo puts it back")

	# Add: one rule, or (▾) what a template lacks.
	expect(await wait_until(func() -> bool: return dialog.select_line_text("# build output")), "a comment selected")
	expect(not dialog.button("untrack").visible, "Stop tracking… hides without tracked matches")
	var form: FormDialog = ops.form()
	dialog.press("add")
	expect(form.visible, "Add opens the form")
	expect(not form.field("rule").visible, "with no rule choice")
	form.hide()
	var add: PopupMenu = dialog.add_menu()
	expect_eq(add.get_item_text(0), "Templates", "the ▾ menu lists the templates")
	var godot: int = _item(add, "Godot")
	expect(godot >= 0 and not add.is_item_disabled(godot), "the Godot template has rules to add")
	add.id_pressed.emit(add.get_item_id(godot))
	expect(form.visible, "the Ignore dialog opens on the template's rules")
	expect(String(ops.rule()["pattern"]).contains(".godot/"), "with the missing lines: %s" % ops.rule()["pattern"])
	form.hide()
	dialog.hide()
	expect(await wait_until(func() -> bool: return not session.has_ignore_rules()), "closing lets the rules go")

	# Show ignored files, with the rule behind each and Stop ignoring.
	view.filter_field().set_option("ignored", true)
	var list: ChangeList = view.list()
	expect(await wait_until(func() -> bool: return session.change_index("a.log") >= 0), "a.log is listed")
	var row: Dictionary = list.row(session.change_index("a.log"))
	expect(bool(row.get("ignored", false)), "as ignored")
	expect_eq(String(row.get("ignored_source", "")), ".gitignore", "by .gitignore")
	expect_eq(int(row.get("ignored_line", 0)), 1, "line 1")
	expect(bool(list.row(session.change_index("build")).get("ignored_dir", false)), "build/ is one folder row")
	expect(session.change_index("new.txt") < session.change_index("a.log"), "ignored files come last")
	list.select_only(session.change_index("a.log"))
	list.context_menu_requested.emit(list.cursor, Vector2(8, 8))
	expect("Stop ignoring" in view.menu_labels(), "the menu offers Stop ignoring: %s" % view.menu_labels())
	expect(not ("Discard selected changes…" in view.menu_labels()), "and no discard")
	view.context_menu().hide()
	expect(not Actions.is_enabled(&"changes.ignore"), "an ignored file cannot be ignored again")
	Actions.run_action(&"changes.stop_ignoring")
	expect(await wait_until(func() -> bool: return read_file(repo.path_join(".gitignore")).ends_with("!/a.log\n")),
			"*.log covers more than a.log: a negation is added")
	expect(await wait_until(func() -> bool:
		var at: int = session.change_index("a.log")
		return at >= 0 and not bool(list.row(at).get("ignored", false))), "a.log is a change again")
	Actions.run_action(&"changes.undo_ignore")
	expect(await wait_until(func() -> bool: return not read_file(repo.path_join(".gitignore")).contains("!/a.log")),
			"Undo takes the negation back")
	view.filter_field().set_option("ignored", false)
	expect(await wait_until(func() -> bool: return session.change_index("a.log") < 0), "the ignored rows go")

	# The Ignore dialog's third target: all my repositories.
	if scratch_global:
		list.select_only(session.change_index("new.txt"))
		Actions.run_action(&"changes.ignore")
		var where: OptionButton = form.field("where") as OptionButton
		expect_eq(where.item_count, 3, "three targets")
		where.select(IgnoreOps.GLOBAL)
		where.item_selected.emit(IgnoreOps.GLOBAL)
		expect_eq(String(ops.rule()["target"]), "global", "the global target")
		expect(not form.field("file").visible, "no file choice")
		expect(await wait_until(func() -> bool: return not ops.preview().is_empty()), "the preview loads")
		expect(form.submit(), "it submits")
		expect(await wait_until(func() -> bool: return read_file(global_file) == "*.bak\n/new.txt\n"),
				"the rule is in the global file: %s" % read_file(global_file))
		expect(await wait_until(func() -> bool: return session.change_index("new.txt") < 0), "new.txt is hidden")
		Actions.run_action(&"changes.undo_ignore")
		expect(await wait_until(func() -> bool: return read_file(global_file) == "*.bak\n"), "Undo takes it back")
		Core.set_repo_ui_state(session.repo_path(), IgnoreOps.TARGET_STATE, IgnoreOps.SHARED)
		_git(repo, ["config", "--global", "--unset", "core.excludesFile"])
	# Open tabs are saved; the next test's window would restore this one.
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


func _build_repo(repo: String) -> void:
	DirAccess.make_dir_recursive_absolute(repo)
	_git(repo, ["init", "-q", "-b", "main"])
	write_file(repo.path_join(".gitignore"), "*.log\n# build output\n/build/\n!keep.log\nunused/\n")
	DirAccess.make_dir_recursive_absolute(repo.path_join("src"))
	write_file(repo.path_join("src/.gitignore"), "*.tmp\n")
	write_file(repo.path_join("src/main.rs"), "fn main() {}\n")
	write_file(repo.path_join("tracked.log"), "t\n")
	_git(repo, ["add", ".gitignore", "src"])
	_git(repo, ["add", "-f", "tracked.log"])
	_git(repo, ["-c", "user.name=Smoke", "-c", "user.email=smoke@example.com", "commit", "-q", "-m", "base"])
	for file: String in ["a.log", "keep.log", "build/o.o", "src/t.tmp", "new.txt", "node_modules/x/i.js"]:
		DirAccess.make_dir_recursive_absolute(repo.path_join(file).get_base_dir())
		write_file(repo.path_join(file), "x\n")


## Runs git in `repo` and returns its output, trimmed.
static func _git(repo: String, args: PackedStringArray) -> String:
	var output: Array = []
	OS.execute("git", PackedStringArray(["-C", repo]) + args, output, true)
	return String(output[0]).strip_edges() if not output.is_empty() else ""


static func _item(menu: PopupMenu, text: String) -> int:
	for i: int in menu.item_count:
		if menu.get_item_text(i) == text:
			return i
	return -1
