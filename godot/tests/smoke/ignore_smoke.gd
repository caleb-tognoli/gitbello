extends SmokeTest
## Ignoring changed files (M7.7a) on fixture `repo-14` (app.txt modified,
## notes.txt untracked, plus build output and logs written here): the Ignore
## submenu and its quick rules, Undo, a quick rule on a tracked file opening
## the dialog with the untrack choice, and the dialog's folder rules, preview,
## nested `.gitignore` choice and local target. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("ignore_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-14")
	for file: String in ["build/debug/x.o", "build/y.o", "logs/a.log"]:
		DirAccess.make_dir_recursive_absolute(repo.path_join(file).get_base_dir())
		write_file(repo.path_join(file), "output\n")

	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.change_count() == 5),
			"repo-14 lists its two changes and the files written: %d" % session.change_count())
	page.show_view(WorktreeView.View.CHANGES)
	var view: ChangesView = page.changes()
	var list: ChangeList = view.list()
	var ops: IgnoreOps = view.ignore_ops()
	var form: FormDialog = ops.form()
	var gitignore: String = repo.path_join(".gitignore")

	# The submenu's quick rules for a file at the root: no folder to offer.
	list.select_only(session.change_index("notes.txt"))
	list.context_menu_requested.emit(list.cursor, Vector2(8, 8))
	expect("Ignore" in view.menu_labels(), "the files' menu has Ignore")
	var sub: PopupMenu = view.ignore_menu()
	expect(sub != null, "Ignore is a submenu")
	if sub == null:
		return
	expect_eq(_labels(sub), PackedStringArray(["Ignore \"notes.txt\"", "Ignore all *.txt files", "Ignore…"]),
			"quick rules for notes.txt")
	expect(not Actions.is_enabled(&"changes.ignore_folder"), "no folder rule for a root file")
	view.context_menu().hide()
	sub.id_pressed.emit(0)
	expect(await wait_until(func() -> bool: return session.change_index("notes.txt") < 0),
			"the quick rule hides notes.txt")
	expect_eq(read_file(gitignore), "/notes.txt\n", "it is anchored in the root .gitignore")
	expect(session.change_index(".gitignore") >= 0, ".gitignore shows as a change")
	expect(Actions.is_enabled(&"changes.undo_ignore"), "the rule can be undone")
	Actions.run_action(&"changes.undo_ignore")
	expect(await wait_until(func() -> bool: return session.change_index("notes.txt") >= 0),
			"Undo brings notes.txt back")
	expect(not FileAccess.file_exists(gitignore), "Undo removes the .gitignore it created")

	# A tracked file: core refuses the quick rule and the dialog opens on it.
	list.select_only(session.change_index("app.txt"))
	expect(Actions.run_action(&"changes.ignore_file"), "the quick file rule runs on app.txt")
	expect(await wait_until(func() -> bool: return form.visible), "matching a tracked file opens the dialog")
	expect_eq(String(ops.rule()["pattern"]), "/app.txt", "the dialog starts on the refused rule")
	expect(await wait_until(func() -> bool: return int(ops.preview().get("tracked_count", 0)) == 1),
			"the preview finds the tracked file")
	var untrack: CheckBox = form.field("untrack") as CheckBox
	expect(untrack.visible and untrack.button_pressed, "shared rules offer untracking, checked")
	expect_eq(untrack.text, "Also stop tracking the 1 file that matches", "the check counts the files")
	expect(not FileAccess.file_exists(gitignore), "nothing was written")
	form.hide()

	# The dialog: a folder rule two levels up, with its preview.
	list.select_only(session.change_index("build/debug/x.o"))
	expect(Actions.run_action(&"changes.ignore"), "Ignore… opens the dialog")
	expect(form.visible, "the dialog shows")
	expect(not form.field("file").visible, "one .gitignore: no file choice")
	var rules: OptionButton = form.field("rule") as OptionButton
	var folder: int = _item(rules, "The folder build/")
	expect(folder >= 0, "the dialog offers each folder: %s" % _items(rules))
	expect(_item(rules, "The folder build/debug/") >= 0, "the nearest folder too")
	expect(_item(rules, "All *.o files") >= 0, "and the extension")
	rules.select(folder)
	rules.item_selected.emit(folder)
	expect_eq(String(ops.rule()["pattern"]), "/build/", "choosing a rule sets its pattern")
	expect(await wait_until(func() -> bool: return int(ops.preview().get("hidden_count", 0)) == 2),
			"the preview counts both build files: %s" % ops.preview())
	var pattern: TextEdit = form.field("pattern") as TextEdit
	pattern.text = "/build/*.o"
	pattern.text_changed.emit()
	expect_eq(rules.selected, rules.item_count - 1, "an edited pattern is a custom one")
	expect(await wait_until(func() -> bool: return int(ops.preview().get("hidden_count", 0)) == 1),
			"the preview follows the edit: %s" % ops.preview())
	rules.select(folder)
	rules.item_selected.emit(folder)
	var where: OptionButton = form.field("where") as OptionButton
	where.select(IgnoreOps.LOCAL)
	where.item_selected.emit(IgnoreOps.LOCAL)
	expect_eq(String(ops.rule()["target"]), "local", "Only on this computer writes info/exclude")
	expect(await wait_until(func() -> bool: return not ops.preview().is_empty()), "the preview loads")
	expect(form.submit(), "the dialog submits")
	expect(await wait_until(func() -> bool: return session.change_index("build/y.o") < 0),
			"the local rule hides the build output")
	expect(read_file(repo.path_join(".git/info/exclude")).ends_with("/build/\n"), "the rule is in info/exclude")
	expect(not FileAccess.file_exists(gitignore), "and not in .gitignore")
	Actions.run_action(&"changes.undo_ignore")
	expect(await wait_until(func() -> bool: return session.change_index("build/y.o") >= 0), "Undo shows it again")

	# A nested .gitignore is offered as the file, with rules relative to it.
	write_file(repo.path_join("logs/.gitignore"), "*.tmp\n")
	session.refresh()
	expect(await wait_until(func() -> bool: return session.change_index("logs/.gitignore") >= 0),
			"the nested .gitignore shows")
	list.select_only(session.change_index("logs/a.log"))
	expect(Actions.run_action(&"changes.ignore"), "the dialog opens for logs/a.log")
	# Each opening builds the form's fields again.
	where = form.field("where") as OptionButton
	expect_eq(where.selected, IgnoreOps.LOCAL, "the dialog remembers the last target")
	expect(not form.field("file").visible, "local rules have no file choice")
	where.select(IgnoreOps.SHARED)
	where.item_selected.emit(IgnoreOps.SHARED)
	expect(form.field("file").visible, "the file choice shows with a nested .gitignore")
	var file: OptionButton = form.field("file") as OptionButton
	expect_eq(_items(file), PackedStringArray([".gitignore", "logs/.gitignore"]), "root first")
	file.select(1)
	file.item_selected.emit(1)
	expect_eq(String(ops.rule()["pattern"]), "/a.log", "the rule is relative to logs/")
	expect(form.submit(), "the nested rule submits")
	expect(await wait_until(func() -> bool: return session.change_index("logs/a.log") < 0), "logs/a.log is hidden")
	expect_eq(read_file(repo.path_join("logs/.gitignore")), "*.tmp\n/a.log\n", "the rule is in logs/.gitignore")
	# Open tabs are saved; the next test's window would restore this one.
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


static func _labels(menu: PopupMenu) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i: int in menu.item_count:
		if not menu.is_item_separator(i):
			out.append(menu.get_item_text(i))
	return out


static func _items(choice: OptionButton) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i: int in choice.item_count:
		out.append(choice.get_item_text(i))
	return out


static func _item(choice: OptionButton, text: String) -> int:
	return Array(_items(choice)).find(text)
