extends SmokeTest
## The Changes view (M4a, reworked in M6.5 P3): checkboxes, commit and amend
## with the keyboard only, on fixture `repo-6` (app.txt modified, notes.txt
## untracked). Also checks the diff of the highlighted file, the commit
## button's text and reason, hook output on a failed commit, the empty state
## and the linked worktree's badge. Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _main: Main = null


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("changes_smoke: no --fixtures, skipped")
		return
	var repo: String = fixtures.path_join("repo-6")

	_main = MAIN.instantiate() as Main
	add_child(_main)
	await get_tree().process_frame
	var page: RepoTab = _main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.change_count() == 2),
			"repo-6 has one modified and one untracked file")

	var view: ChangesView = page.changes()
	var list: ChangeList = view.list()
	press("Ctrl+Shift+G")
	expect_eq(page.view, WorktreeView.View.CHANGES, "Ctrl+Shift+G shows the changes view")
	expect(list.has_focus(), "the list has focus")
	expect_eq(list.cursor, 0, "cursor on the first file")
	expect_eq(session.picked_count(), 2, "nothing staged: every file is included")
	expect_eq(view.check_all().state, "all", "the check-all box is checked")

	# The highlighted file's diff loads.
	var diff: DiffView = view.diff_view()
	expect(await wait_until(func() -> bool: return _diff_has(diff, "local edit")), "diff of app.txt shows the local edit")

	# Space leaves out the highlighted file; the button follows.
	var box: CommitBox = view.commit_box()
	press("Down")
	expect_eq(list.path_at(list.cursor), "notes.txt", "cursor on notes.txt")
	press("Space")
	expect(await wait_until(func() -> bool: return session.picked_count() == 1), "Space left out notes.txt")
	expect(await wait_until(func() -> bool: return view.check_all().state == "partial"), "check-all shows partial")
	expect_eq(box.button_text(), "Commit 1 file to main", "the button counts the included files")
	press("Ctrl+Shift+U")
	expect(await wait_until(func() -> bool: return session.picked_count() == 0), "Ctrl+Shift+U leaves out everything")
	expect_eq(box.block_reason(), "Nothing included", "the button says why it is disabled")
	press("Ctrl+Shift+S")
	expect(await wait_until(func() -> bool: return session.picked_count() == 2), "Ctrl+Shift+S includes everything")
	expect_eq(box.block_reason(), "Write a summary", "a summary is still needed")

	# Write the message and commit.
	press("Ctrl+Shift+M")
	type_text("Add notes")
	press("Enter")
	type_text("Body line")
	expect_eq(box.summary(), "Add notes", "summary typed")
	expect_eq(box.body(), "Body line", "body typed")
	press("Ctrl+Enter")
	var committed: bool = await wait_until(func() -> bool:
		return not box.is_busy() and box.summary().is_empty() and session.change_count() == 0)
	expect(committed, "Ctrl+Enter commits and clears the message (output: %s)" % box.output_text())
	expect(await wait_until(func() -> bool: return _head_subject(session) == "Add notes"), "graph shows the new commit")
	var commits: int = session.graph_row_count()

	# Nothing left: suggested actions replace the diff.
	var empty: EmptyState = view.empty_state()
	expect(await wait_until(func() -> bool: return empty.visible), "the empty state shows")
	expect_eq(empty.title(), "No local changes", "it says there is nothing to commit")
	expect("New worktree" in empty.button_labels(), "it suggests a new worktree: %s" % [empty.button_labels()])

	# Amend: Ctrl+Shift+A loads HEAD's message; edit the summary and commit.
	press("Ctrl+Shift+A")
	expect(box.is_amend(), "Ctrl+Shift+A turns on amend")
	expect(await wait_until(func() -> bool: return box.summary() == "Add notes"), "amend loads HEAD's summary")
	expect_eq(box.body(), "Body line", "amend loads HEAD's body")
	expect_eq(box.button_text(), "Amend last commit", "amending with nothing new rewords")
	press("Ctrl+Shift+M")
	type_text(" (amended)")
	press("Ctrl+Enter")
	committed = await wait_until(func() -> bool: return not box.is_busy() and not box.is_amend())
	expect(committed, "amend finished (output: %s)" % box.output_text())
	expect(await wait_until(func() -> bool: return _head_subject(session) == "Add notes (amended)"),
			"graph shows the amended commit: %s" % _head_subject(session))
	expect_eq(session.graph_row_count(), commits, "amending does not add a commit")

	# A rejecting pre-commit hook: its output is shown and the message kept.
	var hook_path: String = repo.path_join(".git/hooks/pre-commit")
	var hook: FileAccess = FileAccess.open(hook_path, FileAccess.WRITE)
	hook.store_string("#!/bin/sh\necho 'hook says no' >&2\nexit 1\n")
	hook.close()
	FileAccess.set_unix_permissions(hook_path, FileAccess.UNIX_EXECUTE_OWNER | FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	press("Ctrl+Shift+A")
	await wait_until(func() -> bool: return box.summary() == "Add notes (amended)")
	press("Ctrl+Enter")
	var rejected: bool = await wait_until(func() -> bool: return not box.is_busy() and box.output_text().contains("hook says no"))
	expect(rejected, "hook output is shown: %s" % box.output_text())
	expect_eq(box.summary(), "Add notes (amended)", "message kept after a failed commit")
	DirAccess.remove_absolute(hook_path)
	box.set_amend(false)

	# The linked worktree's badge arrives (clean: 0 changes).
	var badged: bool = await wait_until(func() -> bool:
		for wt: Dictionary in session.worktrees():
			if not bool(wt["is_main"]) and int(wt["changed"]) == 0:
				return true
		return false)
	expect(badged, "linked worktree has a badge: %s" % [session.worktrees()])

	press("Ctrl+Shift+H")
	expect_eq(page.view, WorktreeView.View.HISTORY, "Ctrl+Shift+H shows history")
	while _main.tab_count() > 0:
		_main.close_tab(0)
	_main.queue_free()
	await get_tree().process_frame


func _diff_has(diff: DiffView, needle: String) -> bool:
	for i: int in diff.row_count():
		if diff.line_text(i).contains(needle):
			return true
	return false


func _head_subject(session: RepoSession) -> String:
	var rows: Array[Dictionary] = session.graph_rows(0, 1)
	return String(rows[0]["subject"]) if not rows.is_empty() else ""
