extends SmokeTest
## History editing (UX.md History editing): Rewrite ▸ in History's commit
## menu with its greyed reasons, Reword through its dialog, the undo strip's
## text and Undo, dropping a pushed commit (it asks first) with local changes
## kept, and a drop that conflicts stopping in the banner. The app runs git.
## Uses fixture `repo-17`: on `main`, "Initial commit" and "Add app" are
## pushed, HEAD "Improve app" is not; `app.txt` is edited and `notes.txt`
## untracked. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const REWRITE: Array[StringName] = [&"commit.reword", &"commit.squash", &"commit.move_up",
	&"commit.move_down", &"commit.drop"]


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("history_edit_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-17")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	var ops: RepoOps = page.ops()
	expect(await wait_until(func() -> bool: return session.is_ready()), "the repository opened")
	expect(await wait_until(func() -> bool:
		var oid: String = String(session.status().get("oid", ""))
		return not oid.is_empty() and not session.rewrite_messages(oid).is_empty()), "HEAD can be edited")
	var head: String = String(session.status().get("oid", ""))
	var first_subject: String = String(session.rewrite_messages(head)["summary"])
	var dirty: Dictionary = _codes(session)

	# The menu has Rewrite ▸ with every action; on HEAD, Move up is greyed.
	var found: bool = false
	for entry: Variant in Menus.commit():
		if entry is Dictionary and Array((entry as Dictionary)["entries"]).has(&"commit.reword"):
			found = true
	expect(found, "the commit menu has Rewrite ▸")
	page.active_view().show_in_history(head, true)
	expect(await wait_until(func() -> bool: return String(page.commit_target().get("hash", "")) == head),
			"HEAD is selected in History")
	expect(Actions.is_enabled(&"commit.reword"), "Reword is available on HEAD")
	expect(Actions.is_enabled(&"commit.drop"), "Drop is available on HEAD")
	expect(not Actions.is_enabled(&"commit.move_up"), "Move up is greyed on HEAD")
	expect_eq(Actions.get_action(&"commit.move_up").reason.call(), "Already the newest commit",
			"Move up says why")
	for id: StringName in REWRITE:
		expect(not Actions.get_action(id).label.is_empty(), "%s is registered" % id)

	# Reword: the dialog has the message; HEAD is not pushed, so it runs at once.
	expect(Actions.run_action(&"commit.reword"), "Reword runs")
	var form: FormDialog = ops.form()
	expect(await wait_until(func() -> bool: return form.visible), "Reword asks for the message")
	expect_eq((form.field("summary") as LineEdit).text, first_subject, "the summary is prefilled")
	(form.field("summary") as LineEdit).text = ""
	form.revalidate()
	expect(form.get_ok_button().disabled, "an empty summary cannot be saved")
	(form.field("summary") as LineEdit).text = "Reworded in gitbello"
	form.revalidate()
	expect(form.submit(), "the message is accepted")
	var confirm: ConfirmationDialog = ops.confirm_dialog()
	expect(not confirm.visible, "an unpushed commit does not ask")
	expect(await wait_until(func() -> bool:
		var now: String = String(session.status().get("oid", ""))
		return now != head and String(session.rewrite_messages(now).get("summary", "")) == "Reworded in gitbello"),
			"HEAD was reworded")
	expect(await wait_until(func() -> bool: return String(session.undoable_commit().get("rewrite", "")) == "reword"),
			"the undo strip offers the reword")
	expect_eq(String(session.undoable_commit()["rewrite_subject"]), "Reworded in gitbello", "with the new subject")
	expect(await wait_until(func() -> bool: return _codes(session) == dirty), "local changes are kept")
	expect(await wait_until(func() -> bool: return Actions.is_enabled(&"commit.undo")) and Actions.run_action(&"commit.undo"), "Undo runs")
	expect(await wait_until(func() -> bool: return String(session.status().get("oid", "")) == head),
			"Undo restored HEAD")

	# Drop the pushed root commit: it asks, says a force push follows, keeps
	# local changes, and Undo brings it back.
	var root: String = await _select_parent(page, session, 2)
	expect(not root.is_empty(), "the root commit is selected")
	expect_eq(int(session.rewrite_check(root, "drop").get("pushed", 0)), 2, "two pushed commits are rewritten")
	expect(await wait_until(func() -> bool: return Actions.is_enabled(&"commit.drop")) and Actions.run_action(&"commit.drop"), "Drop runs")
	expect(await wait_until(func() -> bool: return confirm.visible), "dropping a pushed commit asks first")
	expect(confirm.dialog_text.contains("force push"), "it says a force push follows: %s" % confirm.dialog_text)
	confirm.get_ok_button().pressed.emit()
	expect(await wait_until(func() -> bool:
		return String(session.undoable_commit().get("rewrite", "")) == "drop"), "the undo strip offers the drop")
	expect(not FileAccess.file_exists(repo.path_join("README.md")), "the root commit's file is gone")
	expect(await wait_until(func() -> bool: return _codes(session) == dirty), "local changes are kept after a drop")
	expect(await wait_until(func() -> bool: return Actions.is_enabled(&"commit.undo")) and Actions.run_action(&"commit.undo"), "Undo runs again")
	expect(await wait_until(func() -> bool: return String(session.status().get("oid", "")) == head),
			"Undo brought the dropped commit back")

	# Dropping "Add app" leaves "Improve app" nothing to change: the rebase
	# stops for the banner.
	var add_app: String = await _select_parent(page, session, 1)
	expect(not add_app.is_empty(), "Add app is selected")
	expect(await wait_until(func() -> bool: return Actions.is_enabled(&"commit.drop")) and Actions.run_action(&"commit.drop"), "Drop runs on Add app")
	expect(await wait_until(func() -> bool: return confirm.visible), "it asks first")
	confirm.get_ok_button().pressed.emit()
	expect(await wait_until(func() -> bool: return session.operation() == "rebase"), "the edit stopped on a conflict")
	expect(await wait_until(func() -> bool: return page.active_view().banner_text().begins_with("Editing history of main")),
			"the banner says history is being edited: %s" % page.active_view().banner_text())
	expect(not Actions.is_enabled(&"commit.reword"), "no edit while one is in progress")
	session.abort_operation()
	expect(await wait_until(func() -> bool:
		return session.operation().is_empty() and String(session.status().get("oid", "")) == head),
			"Abort put the branch back")
	expect(await wait_until(func() -> bool: return _codes(session) == dirty), "local changes are back after Abort")
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()


## Selects HEAD's `depth`-th first parent in History once it can be edited;
## returns its hash.
func _select_parent(page: RepoTab, session: RepoSession, depth: int) -> String:
	var editable: bool = await wait_until(func() -> bool:
		return session.operation().is_empty() and not session.rewrite_messages(String(session.status().get("oid", ""))).is_empty())
	if not editable:
		return ""
	var oid: String = String(session.status().get("oid", ""))
	for _i: int in depth:
		oid = String(session.rewrite_messages(oid).get("parent", ""))
	page.active_view().show_in_history(oid, true)
	var selected: bool = await wait_until(func() -> bool: return String(page.commit_target().get("hash", "")) == oid)
	return oid if selected else ""


## Path → status code of the local changes.
func _codes(session: RepoSession) -> Dictionary:
	var out: Dictionary = {}
	for change: Dictionary in session.change_rows(0, session.change_count()):
		out[String(change["path"])] = String(change["code"])
	return out
