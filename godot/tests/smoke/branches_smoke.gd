extends SmokeTest
## M5: branches, tags and cherry-pick from the keyboard, dialogs and context
## menus, including the dirty-tree checkout that stashes, switches and
## re-applies, and deleting an unmerged branch. GDScript only writes
## `lines.txt`; the app runs git. Uses fixture `repo-9`. Skipped without
## `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


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
	expect(await wait_until(func() -> bool: return session.change_count("untracked") == 2), "lines.txt is untracked")
	expect(await _commit(session, "untracked", "lines.txt", "Add lines"), "committed lines.txt on main")

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
	expect(await _commit(session, "unstaged", "lines.txt", "Edit line 1"), "committed on topic-one")

	# Enter on a sidebar branch checks it out.
	var sidebar: RepoSidebar = page.sidebar()
	expect(await wait_until(func() -> bool: return sidebar.select_ref("refs/heads/main")), "main is in the sidebar")
	sidebar.grab_focus()
	press("Enter")
	expect(await wait_until(func() -> bool: return session.current_branch() == "main"), "Enter checked out main")

	# A local edit that topic-one's version would overwrite: the checkout is
	# refused, a dialog offers to stash, switch and re-apply.
	write_file(lines_path, lines.replace("line 10\n", "local 10\n"))
	expect(await wait_until(func() -> bool: return session.change_count("unstaged") == 2), "lines.txt is modified")
	expect(sidebar.select_ref("refs/heads/topic-one"), "topic-one is in the sidebar")
	press("Enter")
	var confirm: ConfirmationDialog = ops.confirm_dialog()
	expect(await wait_until(func() -> bool: return confirm.visible), "the refused checkout offers to stash")
	expect(confirm.dialog_text.contains("Stash"), "the dialog explains: %s" % confirm.dialog_text)
	press("Enter")
	expect(await wait_until(func() -> bool: return session.current_branch() == "topic-one"),
			"stashed and switched: %s" % session.current_branch())
	expect(await wait_until(func() -> bool: return read_file(lines_path) == lines.replace("line 1\n", "topic 1\n").replace("line 10\n", "local 10\n")),
			"the local edit was re-applied on topic-one: %s" % read_file(lines_path).c_escape())
	expect(await wait_until(func() -> bool: return session.stashes().size() == 1), "only the fixture's stash is left")

	# F2 on the current branch renames it.
	session.discard_paths(PackedStringArray(["lines.txt"]))
	expect(await wait_until(func() -> bool: return session.change_count("unstaged") == 1), "lines.txt discarded")
	sidebar.select_ref("refs/heads/topic-one")
	sidebar.grab_focus()
	press("F2")
	expect(await wait_until(func() -> bool: return form.visible), "F2 asks for the new name")
	(form.field("name") as LineEdit).text = "renamed"
	expect(form.submit(), "the rename form submits")
	expect(await wait_until(func() -> bool: return session.current_branch() == "renamed"), "renamed the branch")

	# Back on main: cherry-pick renamed's commit from the history.
	expect(await wait_until(func() -> bool: return sidebar.select_ref("refs/heads/main")), "main is listed")
	sidebar.grab_focus()
	press("Enter")
	expect(await wait_until(func() -> bool: return session.current_branch() == "main"), "back on main")
	press("Ctrl+1")
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
	expect(await wait_until(func() -> bool: return sidebar.select_ref("refs/heads/renamed")), "renamed is listed")
	sidebar.grab_focus()
	sidebar.context_menu_requested.emit(sidebar.selected_ref(), Vector2.ZERO)
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
	expect(await wait_until(func() -> bool: return sidebar.select_ref("refs/tags/v2.0")), "the tag is in the sidebar")
	sidebar.grab_focus()
	sidebar.context_menu_requested.emit(sidebar.selected_ref(), Vector2.ZERO)
	expect("Push tag" in page.menu_labels(), "the tag menu offers push: %s" % [page.menu_labels()])
	expect(page.press_menu("Delete tag…"), "delete tag chosen")
	expect(await wait_until(func() -> bool: return confirm.visible), "tag delete asks first")
	press("Enter")
	expect(await wait_until(func() -> bool: return not _has_tag(session, "v2.0")), "the tag was deleted")

	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


## Stages `path` from `group` and commits it; returns whether that worked.
func _commit(session: RepoSession, group: String, path: String, message: String) -> bool:
	session.stage_paths(group, PackedStringArray([path]))
	if not await wait_until(func() -> bool: return session.can_commit(false)):
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
