extends SmokeTest
## M7: a conflicting merge from the branch list to the merge commit with the
## keyboard only (Ctrl+Shift+B, the preview dialog, the banner, the resolver,
## Ctrl+Enter), the undo strip removing the merge again, and the resolver
## side by side with Abort. GDScript only writes files; the app runs git.
## Uses fixture `repo-13`. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("merge_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-13")
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	var ops: RepoOps = page.ops()
	var view: WorktreeView = page.active_view()
	var dirty: Callable = func() -> bool: return _code(session, "app.txt") == "M" and _code(session, "notes.txt") == "?"
	expect(await wait_until(func() -> bool: return session.is_ready() and dirty.call()), "the fixture's local changes show")
	session.discard_paths(PackedStringArray(["app.txt", "notes.txt"]))
	expect(await wait_until(func() -> bool: return session.change_count() == 0), "started clean")

	# main and topic change the same line of conflict.txt; topic adds a file.
	var conflict_path: String = repo.path_join("conflict.txt")
	write_file(conflict_path, "one\nbase\nthree\n")
	expect(await _commit(session, "conflict.txt", "Add conflict.txt"), "committed the base")
	session.create_branch("topic", "main", false)
	expect(await wait_until(func() -> bool: return _has_branch(session, "topic")), "created topic")
	write_file(conflict_path, "one\nours\nthree\n")
	expect(await _commit(session, "conflict.txt", "Ours"), "changed the line on main")
	expect(await wait_until(func() -> bool: return session.change_count() == 0), "clean after the commit")
	ops.checkout_branch("topic")
	expect(await wait_until(func() -> bool: return session.current_branch() == "topic"), "on topic")
	expect(await wait_until(func() -> bool: return read_file(conflict_path) == "one\nbase\nthree\n"), "topic has the base")
	write_file(conflict_path, "one\ntheirs\nthree\n")
	expect(await _commit(session, "conflict.txt", "Theirs"), "changed the line on topic")
	write_file(repo.path_join("topic.txt"), "topic\n")
	expect(await _commit(session, "topic.txt", "Add topic.txt"), "added a file on topic")
	expect(await wait_until(func() -> bool: return session.change_count() == 0), "clean on topic")
	ops.checkout_branch("main")
	expect(await wait_until(func() -> bool: return session.current_branch() == "main"), "back on main")
	# A local change the merge does not touch stays out of the merge commit.
	write_file(repo.path_join("notes.txt"), "my notes\n")
	expect(await wait_until(func() -> bool: return _code(session, "notes.txt") == "?"), "notes.txt is untracked")

	# Ctrl+Shift+B: pick the branch to merge, then the preview's main button.
	page.focus_view()
	press("Ctrl+Shift+B")
	var popover: BranchPopover = view.branch_popover()
	expect(await wait_until(func() -> bool: return popover.visible), "Ctrl+Shift+B opens the branch list")
	expect(not "main" in popover.row_names(), "the current branch is not offered")
	expect_eq(popover.header_text(), "Merge into main", "the list says what it merges into")
	popover.set_filter("topic")
	press("Enter", popover)
	var form: FormDialog = ops.form()
	expect(await wait_until(func() -> bool: return form.visible), "the merge dialog opens")
	expect(form.title == "Merge", "its title: %s" % form.title)
	expect(await wait_until(func() -> bool: return form.ok_button_text == "Merge and resolve…"),
			"the preview finds the conflict: %s / %s" % [form.ok_button_text, ops.merge_status_text()])
	expect(ops.merge_status_text() == "Conflicts in 1 file", "it says so: %s" % ops.merge_status_text())
	expect_eq(ops.merge_conflict_paths(), PackedStringArray(["conflict.txt"]), "it lists the conflicted file")
	expect_eq(form.menu_labels(), PackedStringArray(["Squash and resolve…"]), "the ▾ offers a squash")
	press("Enter", form)
	expect(await wait_until(func() -> bool: return session.operation() == "merge"), "the merge is in progress")
	expect(await wait_until(func() -> bool: return view.banner_text() == "Merging topic into main · 1 file to resolve"),
			"the banner says what is merged: %s" % view.banner_text())
	expect(view.continue_button().disabled, "Continue waits for the conflict")
	expect(view.continue_button().text == "Commit merge", "Continue commits the merge: %s" % view.continue_button().text)
	expect(await wait_until(func() -> bool: return not view.continue_button().visible),
			"in Changes, the commit box commits the merge, not the banner")

	# The resolver opens on the conflict (Open resolver hides); Alt+T takes their line.
	var changes: ChangesView = page.changes()
	expect(await wait_until(func() -> bool: return changes.has_conflict_blocks()), "the resolver shows the conflict")
	expect(not view.resolver_button().visible, "Open resolver hides while the conflict is open")
	expect(changes.diff_view().has_focus(), "the resolver has the keyboard")
	var header: int = changes.diff_view().find_block_header(-1, true)
	expect(header >= 0 and String(changes.diff_view().line(header).get("text", "")) == "Conflict 1 of 1",
			"a header names the block")
	press("Alt+T")
	expect(await wait_until(func() -> bool: return read_file(conflict_path) == "one\ntheirs\nthree\n"),
			"their line was taken: %s" % read_file(conflict_path).c_escape())
	expect(await wait_until(func() -> bool: return int(session.operation_info().get("conflicts", -1)) == 0),
			"the file was staged as resolved")
	expect(await wait_until(func() -> bool: return view.banner_text().ends_with("ready to commit")),
			"the banner says so: %s" % view.banner_text())
	view.show_view(WorktreeView.View.HISTORY)
	expect(view.continue_button().visible and not view.continue_button().disabled,
			"History, without the commit box, offers the commit in the banner")
	view.show_view(WorktreeView.View.CHANGES)
	expect(not view.continue_button().visible, "back in Changes, only the commit box offers it")
	var box: CommitBox = changes.commit_box()
	expect(await wait_until(func() -> bool: return box.button_text() == "Commit merge into main"),
			"the commit box finishes the merge: %s" % box.button_text())
	expect(box.summary() == "Merge branch 'topic'", "git's message is filled in: %s" % box.summary())
	var notes: Dictionary = session.change_rows(session.change_index("notes.txt"), 1)[0]
	expect(String(notes["pick"]) == "none" and bool(notes["locked"]), "notes.txt stays out, locked")
	press("Ctrl+Enter")
	expect(await wait_until(func() -> bool: return session.operation().is_empty()), "the merge was committed")
	expect(await wait_until(func() -> bool: return _code(session, "notes.txt") == "?"), "notes.txt is still local")

	# The undo strip offers the merge commit; Remove merge undoes it.
	expect(await wait_until(func() -> bool: return box.undo_text().begins_with("Merge branch 'topic'")),
			"the undo strip offers the merge: %s" % box.undo_text())
	expect(Actions.run_action(&"commit.undo"), "Undo last commit runs")
	var undo: ConfirmationDialog = ops.undo_merge_dialog()
	expect(await wait_until(func() -> bool: return undo.visible), "undoing a merge asks how")
	ops.remove_merge_button().pressed.emit()
	expect(await wait_until(func() -> bool: return read_file(conflict_path) == "one\nours\nthree\n"),
			"the merge is gone: %s" % read_file(conflict_path).c_escape())
	expect(not FileAccess.file_exists(repo.path_join("topic.txt")), "its files went with it")
	expect(_code(session, "notes.txt") == "?", "the local change is kept")

	# Again, side by side: a block button takes ours; then Abort.
	ops.merge_into_current("refs/heads/topic", "topic")
	expect(await wait_until(func() -> bool: return form.visible and form.ok_button_text == "Merge and resolve…"),
			"the dialog previews the conflict again")
	form.submit()
	expect(await wait_until(func() -> bool: return changes.has_conflict_blocks()), "the resolver shows again")
	Actions.run_action(&"diff.toggle_side_by_side")
	var diff: DiffView = changes.diff_view()
	expect(await wait_until(func() -> bool: return diff.side_by_side and diff.find_block_header(-1, true) >= 0),
			"side by side has the block header")
	var row: int = diff.find_block_header(-1, true)
	var pair: Dictionary = diff.row_data(row + 1)
	expect(String((pair["left"] as Dictionary).get("text", "")) == "ours"
			and String((pair["right"] as Dictionary).get("text", "")) == "theirs",
			"ours on the left, theirs on the right: %s" % pair)
	diff.press_block(row, "ours")
	expect(await wait_until(func() -> bool: return int(session.operation_info().get("resolved", 0)) == 1),
			"the block button resolved the file")
	Actions.run_action(&"diff.toggle_side_by_side")
	expect(Actions.run_action(&"operation.abort"), "Abort runs")
	var confirm: ConfirmationDialog = ops.confirm_dialog()
	expect(await wait_until(func() -> bool: return confirm.visible), "Abort asks first")
	expect(confirm.dialog_text.contains("with the 1 file you resolved"), "it warns about the resolved file: %s" % confirm.dialog_text)
	confirm.get_ok_button().pressed.emit()
	expect(await wait_until(func() -> bool: return session.operation().is_empty()), "the merge was aborted")
	expect(read_file(conflict_path) == "one\nours\nthree\n", "main is as it was")
	expect(await wait_until(func() -> bool: return box.summary().is_empty()),
			"the merge's message goes with it: %s" % box.summary())
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()


func _commit(session: RepoSession, path: String, message: String) -> bool:
	if not await wait_until(func() -> bool: return session.change_index(path) >= 0):
		return false
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


static func _has_branch(session: RepoSession, branch: String) -> bool:
	for ref: Dictionary in session.branch_refs():
		if String(ref["kind"]) == "branch" and String(ref["short_name"]) == branch:
			return true
	return false


## The change code of `path` in the Changes list (`M`, `?`, ...), or "".
func _code(session: RepoSession, path: String) -> String:
	var index: int = session.change_index(path)
	if index < 0:
		return ""
	var rows: Array[Dictionary] = session.change_rows(index, 1)
	return String(rows[0].get("code", "")) if not rows.is_empty() else ""
