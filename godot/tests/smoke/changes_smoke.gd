extends SmokeTest
## M4a acceptance: a full stage-commit-amend cycle using only the keyboard,
## on fixture `repo-6` (app.txt modified, notes.txt untracked). Also checks
## the diff of the selected file, hook output on a failed commit and the
## linked worktree's badge. Skipped without `--fixtures`.

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
	var ready: bool = await wait_until(func() -> bool:
		return session.change_count("unstaged") == 1 and session.change_count("untracked") == 1)
	expect(ready, "repo-6 has one modified and one untracked file")

	var view: ChangesView = page.changes()
	press("Ctrl+2")
	expect_eq(page.view, RepoTab.View.CHANGES, "Ctrl+2 shows the changes view")
	expect(view.unstaged_list().has_focus(), "the unstaged list has focus")
	expect_eq(view.unstaged_list().cursor, 0, "cursor on the first file")

	# The selected file's diff loads.
	var diff: DiffView = view.diff_view()
	var shown: bool = await wait_until(func() -> bool: return _diff_has(diff, "local edit"))
	expect(shown, "diff of app.txt shows the local edit")

	# Enter stages app.txt; the untracked list takes over; Space stages notes.txt.
	press("Enter")
	var staged: bool = await wait_until(func() -> bool:
		return session.change_count("staged") == 1 and view.untracked_list().has_focus())
	expect(staged, "Enter stages app.txt and focus moves to the untracked list")
	press("Space")
	staged = await wait_until(func() -> bool: return session.change_count("staged") == 2)
	expect(staged, "Space stages notes.txt")
	expect(await wait_until(func() -> bool: return view.staged_list().has_focus()), "focus moves to the staged list")

	# Enter on a staged file unstages it; stage it again from the untracked list.
	press("Enter")
	expect(await wait_until(func() -> bool: return session.change_count("staged") == 1), "Enter unstages a staged file")
	press("Ctrl+Shift+S")
	expect(await wait_until(func() -> bool: return session.change_count("staged") == 2), "Ctrl+Shift+S stages everything")

	# Write the message and commit.
	press("Ctrl+Shift+M")
	var box: CommitBox = view.commit_box()
	type_text("Add notes")
	press("Enter")
	type_text("Body line")
	expect_eq(box.summary(), "Add notes", "summary typed")
	expect_eq(box.body(), "Body line", "body typed")
	press("Ctrl+Enter")
	var committed: bool = await wait_until(func() -> bool:
		return not box.is_busy() and box.summary().is_empty() and session.change_count("staged") == 0)
	expect(committed, "Ctrl+Enter commits and clears the message (output: %s)" % box.output_text())
	expect(await wait_until(func() -> bool: return _head_subject(session) == "Add notes"), "graph shows the new commit")
	var commits: int = session.graph_row_count()

	# Amend: Ctrl+Shift+A loads HEAD's message; edit the summary and commit.
	press("Ctrl+Shift+A")
	expect(box.is_amend(), "Ctrl+Shift+A turns on amend")
	expect(await wait_until(func() -> bool: return box.summary() == "Add notes"), "amend loads HEAD's summary")
	expect_eq(box.body(), "Body line", "amend loads HEAD's body")
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

	press("Ctrl+1")
	expect_eq(page.view, RepoTab.View.HISTORY, "Ctrl+1 shows history")
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
