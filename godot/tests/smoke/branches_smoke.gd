extends SmokeTest
## M5, reworked in M6.5 P2: branches, tags and cherry-pick from the keyboard,
## the branch list (Ctrl+B), dialogs and context menus (a branch row's, a
## commit's, a ref label's), including the dirty-tree checkout that stashes,
## switches and re-applies, and deleting an unmerged branch. GDScript only writes
## `lines.txt`; the app runs git. Uses fixture `repo-9`. Skipped without
## `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _ops: RepoOps = null

func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("branches_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-9")
	var lines_path: String = repo.path_join("lines.txt")
	var lines: String = ""
	for n: int in range(1, 11):
		lines += "line %d\n" % n
	write_file(lines_path, lines)

	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	var ops: RepoOps = page.ops()
	_ops = ops
	expect(await wait_until(func() -> bool: return _code(session, "lines.txt") == "?"), "lines.txt is untracked")
	expect(await _commit(session, "lines.txt", "Add lines"), "committed lines.txt on main")
	# The commit job finishes before status and the history selection refresh.
	# Wait for the new HEAD so New branch cannot target the previous commit
	# and open an unexpected bring-or-leave dialog on faster runners.
	expect(await wait_until(func() -> bool:
		var selected: Dictionary = page.commit_target()
		return String(selected.get("subject", "")) == "Add lines" \
				and String(selected.get("hash", "")) == String(session.status().get("oid", ""))),
			"the new HEAD is selected before branching")

	# Ctrl+Shift+N: a new branch from HEAD; typed spaces become dashes.
	press("Ctrl+Shift+N")
	var form: FormDialog = ops.form()
	expect(await wait_until(func() -> bool: return form.visible), "Ctrl+Shift+N asks for a name")
	var name_field: LineEdit = form.field("name") as LineEdit
	type_text("topic one")
	# LineEdit reports text changes a frame later.
	expect(await wait_until(func() -> bool: return name_field.text == "topic-one"),
			"spaces become dashes: %s" % name_field.text)
	press("Enter")
	expect(await wait_until(func() -> bool: return session.current_branch() == "topic-one"),
			"created and checked out topic-one: %s" % session.current_branch())

	write_file(lines_path, lines.replace("line 1\n", "topic 1\n"))
	expect(await wait_until(func() -> bool: return _code(session, "lines.txt") == "M"), "lines.txt is edited")
	expect(await _commit(session, "lines.txt", "Edit line 1"), "committed on topic-one")

	# Ctrl+B lists the branches; Enter in the filter checks out the first.
	var popover: BranchPopover = page.active_view().branch_popover()
	expect(await _choose_branch(popover, "main"), "the branch list finds main")
	expect(await wait_until(func() -> bool: return session.current_branch() == "main"), "Enter checked out main")

	# A local edit that topic-one's version would overwrite: the switch asks
	# first; bringing the changes stashes, switches and re-applies them.
	write_file(lines_path, lines.replace("line 10\n", "local 10\n"))
	expect(await wait_until(func() -> bool: return _code(session, "lines.txt") == "M"), "lines.txt is modified")
	expect(await _choose_branch(popover, "topic-one", ""), "the branch list finds topic-one")
	var switch: ConfirmationDialog = ops.switch_dialog()
	expect(await wait_until(func() -> bool: return switch.visible), "a switch with changes asks first")
	expect(switch.get_ok_button().text == "Bring them to topic-one", "it offers to bring them: %s" % switch.get_ok_button().text)
	expect(ops.leave_button().text == "Leave them on main", "or to leave them: %s" % ops.leave_button().text)
	switch.get_ok_button().pressed.emit()
	var confirm: ConfirmationDialog = ops.confirm_dialog()
	expect(await wait_until(func() -> bool: return session.current_branch() == "topic-one"),
			"stashed and switched: %s" % session.current_branch())
	expect(await wait_until(func() -> bool: return read_file(lines_path) == lines.replace("line 1\n", "topic 1\n").replace("line 10\n", "local 10\n")),
			"the local edit was re-applied on topic-one: %s" % read_file(lines_path).c_escape())
	expect(await wait_until(func() -> bool: return session.stashes().size() == 1), "only the fixture's stash is left")

	# F2 on the current branch renames it.
	session.discard_paths(PackedStringArray(["lines.txt"]))
	expect(await wait_until(func() -> bool: return _code(session, "lines.txt").is_empty()), "lines.txt discarded")
	page.focus_view()
	press("F2")
	expect(await wait_until(func() -> bool: return form.visible), "F2 asks for the new name")
	(form.field("name") as LineEdit).text = "renamed"
	expect(form.submit(), "the rename form submits")
	expect(await wait_until(func() -> bool: return session.current_branch() == "renamed"), "renamed the branch")

	# Back on main: cherry-pick renamed's commit from the history.
	expect(await _choose_branch(popover, "main"), "main is listed")
	expect(await wait_until(func() -> bool: return session.current_branch() == "main"), "back on main")
	# Another commit first, so the picked commit gets a new parent: picked
	# within the same second onto the same parent, git would produce the
	# very same commit and `renamed` would count as merged.
	expect(await _commit(session, "notes.txt", "Add notes"), "committed notes.txt on main")
	press("Ctrl+Shift+H")
	var history: HistoryView = page.history()
	var list: CommitList = history.commit_list()
	var row: int = await _row_with_subject(session, "Edit line 1")
	expect(row >= 0, "the commit to pick is in the graph")
	list.grab_focus()
	list.select_only(row)
	expect(Actions.run_action(&"commit.cherry_pick"), "cherry-pick is available for the selected commit")
	expect(await wait_until(func() -> bool: return confirm.visible), "cherry-pick asks first")
	press("Enter")
	expect(await wait_until(func() -> bool: return read_file(lines_path).begins_with("topic 1\n")),
			"the commit was picked onto main")

	# Deleting renamed from its context menu: it is not merged, so a second
	# dialog offers to delete anyway.
	press("Ctrl+B")
	expect(await wait_until(func() -> bool: return popover.visible), "Ctrl+B opens the branch list")
	popover.set_filter("renamed")
	expect_eq(popover.row_names(), PackedStringArray(["renamed"]), "the filter narrows the list")
	popover.menu_requested.emit(popover.first_ref(), Vector2.ZERO)
	popover.hide()
	expect("Delete branch…" in page.menu_labels(), "the branch menu offers delete: %s" % [page.menu_labels()])
	expect(page.press_menu("Delete branch…"), "delete chosen from the menu")
	expect(await wait_until(func() -> bool: return confirm.visible), "delete asks first")
	press("Enter")
	expect(await wait_until(func() -> bool: return confirm.visible and confirm.dialog_text.contains("not merged")),
			"an unmerged branch needs a second confirmation: %s" % confirm.dialog_text)
	press("Enter")
	expect(await wait_until(func() -> bool: return not _has_branch(session, "renamed")), "renamed was deleted")

	# A tag on the selected commit from its context menu, then deleted again.
	list.grab_focus()
	list.select_only(0)
	history.commit_menu_requested.emit(Vector2.ZERO)
	expect("New tag…" in page.menu_labels(), "the commit menu offers a tag: %s" % [page.menu_labels()])
	expect(page.press_menu("New tag…"), "new tag chosen")
	expect(await wait_until(func() -> bool: return form.visible), "the tag form opens")
	(form.field("name") as LineEdit).text = "v2.0"
	(form.field("message") as TextEdit).text = "Second release"
	expect(form.submit(), "the tag form submits")
	expect(await wait_until(func() -> bool: return _has_tag(session, "v2.0")), "tagged v2.0")
	# The tag's label in the graph has its own menu.
	history.label_menu_requested.emit({"name": "refs/tags/v2.0", "short": "v2.0", "kind": "tag", "is_head": false},
			Vector2.ZERO)
	expect("Push tag" in page.menu_labels(), "the tag menu offers push: %s" % [page.menu_labels()])
	expect(page.press_menu("Delete tag…"), "delete tag chosen")
	expect(await wait_until(func() -> bool: return confirm.visible), "tag delete asks first")
	press("Enter")
	expect(await wait_until(func() -> bool: return not _has_tag(session, "v2.0")), "the tag was deleted")

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


## Opens the branch list with Ctrl+B, filters it by `name` and presses
## Enter; returns whether the list opened and the first row is `name`.
## When the switch asks about local changes, it gets `answer` (`bring`; ""
## leaves the dialog open).
func _choose_branch(popover: BranchPopover, name: String, answer: String = "bring") -> bool:
	press("Ctrl+B")
	if not await wait_until(func() -> bool: return popover.visible):
		return false
	popover.set_filter(name)
	var found: bool = not popover.row_names().is_empty() and popover.row_names()[0] == name
	press("Enter", popover)
	var dialog: ConfirmationDialog = _ops.switch_dialog()
	var asked: bool = _ops.session.change_count() > 0 and await wait_until(func() -> bool: return dialog.visible, 3000)
	if answer == "bring" and asked:
		dialog.get_ok_button().pressed.emit()
	return found


## Commits `path` alone (the only file included); returns whether that worked.
func _commit(session: RepoSession, path: String, message: String) -> bool:
	session.pick_all(false)
	if not session.pick_files(PackedStringArray([path]), true) or not session.can_commit(false):
		return false
	var done: Array[bool] = [false, false]
	var on_finished: Callable = func(_job: int, label: String, ok: bool, _error: Dictionary) -> void:
		if label == "commit":
			done[0] = true
			done[1] = ok
	session.job_finished.connect(on_finished)
	session.commit(message, "", false)
	var finished: bool = await wait_until(func() -> bool: return done[0])
	session.job_finished.disconnect(on_finished)
	return finished and done[1]


func _row_with_subject(session: RepoSession, subject: String) -> int:
	if not await wait_until(func() -> bool: return session.graph_row_count() > 0):
		return -1
	await wait_until(func() -> bool: return _find_row(session, subject) >= 0)
	return _find_row(session, subject)


static func _find_row(session: RepoSession, subject: String) -> int:
	var rows: Array[Dictionary] = session.graph_rows(0, session.graph_row_count())
	for data: Dictionary in rows:
		if String(data["subject"]) == subject:
			return int(data["row"])
	return -1


static func _has_branch(session: RepoSession, name: String) -> bool:
	for ref: Dictionary in session.branch_refs():
		if String(ref["kind"]) == "branch" and String(ref["short_name"]) == name:
			return true
	return false


static func _has_tag(session: RepoSession, name: String) -> bool:
	for tag: Dictionary in session.tags():
		if String(tag["name"]) == name:
			return true
	return false


## The change code of `path` in the Changes list (`M`, `?`, ...), or "".
func _code(session: RepoSession, path: String) -> String:
	var index: int = session.change_index(path)
	if index < 0:
		return ""
	var rows: Array[Dictionary] = session.change_rows(index, 1)
	return String(rows[0].get("code", "")) if not rows.is_empty() else ""
