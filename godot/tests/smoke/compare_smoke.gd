extends SmokeTest
## M7.12: Compare, in M7.12c's History-like layout. Opens branch against
## branch (since the fork), swaps (an ancestor on the right: nothing since
## the fork, the full difference shows the change), reopens a recent
## comparison from the Recent popover, compares with the working copy and
## filters, picks a tag, shows an unknown revision's error, compares two
## commits selected in History (and the details pane's button), checks the
## ref menu's entries, Branch → Compare… (Ctrl+Shift+C) and closes. Then
## the commit list: All changes, main's commit (History's row with its
## details over its files), Restore from a side with Undo, the
## working-copy side following an edit, a fetch moving a ref side and
## offering its commit to cherry-pick (the confirmation is cancelled), the
## Include pill on the left side's commits when both sides moved (from a
## focused commit, it selects All changes), and the tab's ×. On fixture
## `repo-16`: `main` is one commit ahead of `feature/login`, `app.txt` is
## edited and `notes.txt` untracked; the origin has a commit `repo-16` has
## not fetched. It fetches and restores (then undoes) `app.txt`. Skipped
## without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("compare_smoke: no --fixtures, skipped")
		return
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var repo: String = fixtures.path_join("repo-16")
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	expect(await wait_until(func() -> bool: return session.is_ready()), "the repository opens")
	var worktree: WorktreeView = page.active_view()
	var compare: CompareView = worktree.compare()
	expect(not worktree.compare_button().visible, "no Compare tab without a comparison")
	expect(not Actions.is_enabled(&"view.compare"), "View → Compare is disabled without a comparison")

	# Branch against branch: Since fork by default, main's one commit.
	worktree.open_compare("feature/login", "main", false)
	expect(await _compared(session), "feature/login ⇄ main compares")
	expect_eq(page.view, WorktreeView.View.COMPARE, "the Compare view shows")
	expect(worktree.compare_button().visible and worktree.compare_button().button_pressed, "the Compare tab shows, pressed")
	var info: Dictionary = session.compare_info()
	expect_eq(String(info["mode"]), "fork", "two branches compare since their fork")
	expect_eq(int(info["file_count"]), 1, "one file differs")
	expect_eq(int(info["only_right"]), 1, "main has one commit feature/login lacks")
	expect_eq(int(info["only_left"]), 0, "feature/login has nothing main lacks")
	expect_eq(compare.bar_button("left").text, "feature/login", "the left chip names the base")
	expect_eq(compare.bar_button("right").text, "main", "the right chip names the compared side")
	expect(not Actions.is_enabled(&"compare.full_difference"), "nothing to include: feature/login has no commits of its own")
	expect(compare.list_header().counts_text().contains("1"), "the header counts the lines: %s" % compare.list_header().counts_text())
	expect(await wait_until(func() -> bool: return compare.file_list().path_at(compare.file_list().cursor) == "app.txt"),
			"the first file is selected")
	expect(await wait_until(func() -> bool:
		var diff: Dictionary = session.compare_diff_info()
		return String(diff.get("state", "")) == "ready" and String(diff.get("path", "")) == "app.txt"),
			"its diff loads")
	expect(await wait_until(func() -> bool: return compare.diff_panel().view().row_count() > 0), "the diff shows")

	# Swap: main ⇄ feature/login. feature/login is main's ancestor, so
	# nothing changed since the fork; the full difference shows main's
	# change undone.
	expect(Actions.run_action(&"compare.swap"), "Swap runs")
	expect(await _compared(session), "the swapped comparison loads")
	expect_eq(compare.bar_button("left").text, "main", "the sides swapped")
	expect_eq(int(session.compare_info()["file_count"]), 0, "nothing since the fork")
	expect(compare.message_text().begins_with(tr("No differences")), "says there are no differences: %s" % compare.message_text())
	var swapped: CompareCommitList = compare.commit_list()
	expect_eq(swapped.kind_at(1), "left", "main's own commits have a section")
	expect(not swapped.includes_left(), "the Include pill starts off")
	expect(Actions.is_enabled(&"compare.full_difference"), "the full difference is offered")
	swapped.include_toggled.emit()
	expect(await _compared(session), "the full difference loads")
	expect_eq(String(session.compare_info()["mode"]), "exact", "every difference")
	expect_eq(int(session.compare_info()["file_count"]), 1, "it shows the file")
	expect(compare.message_text().is_empty(), "the message hides")
	expect(swapped.includes_left(), "the pill is on")

	# The Recent popover reopens feature/login ⇄ main.
	expect(Actions.run_action(&"compare.recent"), "Recent comparisons runs")
	var recent: CompareRecentPopover = compare.recent_popover()
	expect(await wait_until(func() -> bool: return recent.visible), "the Recent popover opens")
	expect(recent.labels().has("feature/login ⇄ main"), "it lists the earlier comparison: %s" % ", ".join(recent.labels()))
	expect(not recent.labels().has("main ⇄ feature/login"), "but not the open one")
	expect(recent.choose("feature/login ⇄ main"), "a recent comparison can be chosen")
	expect(await wait_until(func() -> bool: return String(compare.shown_request().get("left", "")) == "feature/login"),
			"it opens again")
	expect(await _compared(session), "the earlier comparison loads")
	expect_eq(String(session.compare_info()["mode"]), "fork", "since the fork")

	# Against the working copy: the edit and the untracked file; the filter.
	worktree.open_compare("main", "", true)
	expect(await _compared(session), "main ⇄ working copy compares")
	expect_eq(compare.bar_button("right").text, tr("Working copy"), "the right chip is the working copy")
	expect(compare.bar_button("swap").disabled, "the working copy cannot swap")
	expect_eq(int(session.compare_info()["file_count"]), 2, "app.txt and notes.txt differ")
	var untracked: Dictionary = compare.file_list().row(session.compare_file_index("notes.txt"))
	expect(bool(untracked.get("untracked", false)), "notes.txt is untracked")
	compare.filter_field().set_text("notes")
	expect_eq(compare.file_list().row_count(), 1, "the filter keeps notes.txt")
	expect(compare.list_header().text().begins_with("1 "), "the header says one of two: %s" % compare.list_header().text())
	compare.filter_field().set_text("\"notes.txt\"")
	expect_eq(compare.file_list().row_count(), 1, "a path in quotes keeps that file")
	compare.filter_field().set_text("\"notes\"")
	expect_eq(compare.message_text(), tr("No changed files match the filter."), "and only that path, whole")
	compare.filter_field().set_text("zzz")
	expect_eq(compare.message_text(), tr("No changed files match the filter."), "says nothing matches")
	compare.filter_field().set_text("")
	expect_eq(compare.file_list().row_count(), 2, "both files again")

	# The right side's picker: a tag.
	Actions.run_action(&"compare.pick_right")
	var picker: ComparePicker = compare.picker()
	expect(await wait_until(func() -> bool: return picker.visible), "the right side's picker opens")
	expect(picker.row_labels().has(tr("Working copy")), "the right side offers the working copy")
	picker.set_filter("v1")
	expect(picker.row_labels().has("v1.0"), "the filter lists the tag: %s" % ", ".join(picker.row_labels()))
	expect(picker.row_labels()[-1].contains("v1"), "and the text as a revision")
	picker.choose_selected()
	expect(await wait_until(func() -> bool: return String(compare.shown_request().get("right", "")) == "v1.0"), "v1.0 is on the right")
	expect(await _compared(session), "main ⇄ v1.0 compares")
	expect_eq(String(session.compare_info()["mode"]), "fork", "a tag also compares since the fork")
	Actions.run_action(&"compare.pick_left")
	expect(await wait_until(func() -> bool: return picker.visible), "the left side's picker opens")
	expect(not picker.row_labels().has(tr("Working copy")), "the left side has no working copy")
	expect(not ", ".join(picker.row_labels()).contains("⇄"), "recent comparisons are not in the picker")
	expect(picker.row_labels().has("Improve app"), "commits are listed by subject alone: %s" % ", ".join(picker.row_labels()))
	picker.hide()

	# An unknown revision.
	worktree.open_compare("no-such-branch", "main", false)
	expect(await wait_until(func() -> bool: return String(session.compare_info().get("state", "")) == "error"),
			"an unknown revision fails")
	expect(compare.message_text().contains("no-such-branch"), "the message names it: %s" % compare.message_text())

	# Two commits in History, older on the left.
	worktree.show_view(WorktreeView.View.HISTORY)
	var list: CommitList = page.history().commit_list()
	expect(await wait_until(func() -> bool: return list.row_count() >= 2), "History lists commits")
	expect(not Actions.is_enabled(&"history.compare_selected"), "one commit is not a pair")
	list.select_only(0)
	list._toggle(1)
	expect(page.history().details().pair_button().visible, "the details pane offers Compare commits")
	var pair: PackedStringArray = page.history().selected_pair()
	expect_eq(pair.size(), 2, "two commits are selected")
	expect(Actions.is_enabled(&"history.compare_selected"), "Compare commits is offered")
	expect(Actions.run_action(&"history.compare_selected"), "Compare commits runs")
	expect(await _compared(session), "the commits compare")
	expect_eq(String(session.compare_info()["left"]["oid"]), pair[0], "the older commit is on the left")
	expect_eq(String(session.compare_info()["mode"]), "fork", "commits compare since the fork")
	expect(not compare.bar_button("left").text.contains(pair[0].left(7)), "the chips name commits by subject: %s"
			% compare.bar_button("left").text)
	var commit_recent: Dictionary = Core.compare_recent(compare._repo_key())[0]
	var commit_label: String = CompareRecentPopover.label(commit_recent)
	expect(not commit_label.contains(pair[0].left(7)) and commit_label.contains(" ⇄ "),
			"Recent names commits by subject: %s" % commit_label)

	# A branch's menu offers both comparisons.
	worktree.show_view(WorktreeView.View.HISTORY)
	var login: Dictionary = {}
	for ref: Dictionary in session.branch_refs():
		if String(ref["short_name"]) == "feature/login":
			login = {"type": "branch", "name": String(ref["name"]), "short": "feature/login",
				"commit": String(ref["commit"]), "is_head": false, "upstream": "", "worktree": ""}
	worktree.show_ref_menu(login, Vector2(100, 100))
	var labels: PackedStringArray = worktree.menu_labels()
	expect(labels.has(tr("Compare with current branch")) and labels.has(tr("Compare with…")),
			"the branch menu offers Compare: %s" % ", ".join(labels))
	expect(worktree.press_menu(tr("Compare with current branch")), "Compare with current branch runs")
	expect(await _compared(session), "main ⇄ feature/login compares")
	expect_eq(compare.bar_button("left").text, "main", "the current branch is the base")
	expect_eq(compare.bar_button("right").text, "feature/login", "the branch is compared")

	# Close returns to the view before Compare.
	Actions.run_action(&"compare.close")
	expect_eq(page.view, WorktreeView.View.HISTORY, "closing returns to History")
	expect(not worktree.compare_button().visible, "the Compare tab hides")
	expect(not compare.has_comparison() and String(session.compare_info().get("state", "")) == "none",
			"the comparison is gone")

	# Branch → Compare…: the current branch against the working copy, the
	# right side's picker open.
	press("Ctrl+Shift+C")
	expect(await wait_until(func() -> bool: return picker.visible), "Ctrl+Shift+C opens the right side's picker")
	expect_eq(String(compare.shown_request().get("left", "")), "main", "the current branch on the left")
	expect(bool(compare.shown_request().get("working", false)), "the working copy on the right")
	picker.set_filter("feature/login")
	picker.choose_selected()
	expect(await wait_until(func() -> bool: return String(compare.shown_request().get("right", "")) == "feature/login"),
			"the pick replaces the right side")
	Actions.run_action(&"compare.close")

	# The commits: All changes, then main's commit as a History row; the
	# commit shows its details over its own files.
	worktree.open_compare("feature/login", "main", false)
	expect(await _compared(session), "feature/login ⇄ main compares again")
	var commits: CompareCommitList = compare.commit_list()
	expect(commits.is_visible_in_tree(), "the commits are always shown")
	expect_eq(commits.kind_at(0), "all", "All changes comes first")
	expect_eq(commits.cursor, 0, "and is selected")
	expect(not compare.details_header().visible, "All changes has no details")
	expect_eq(commits.kind_at(1), "right", "then the right side's header")
	var improve: Dictionary = commits.commit_at(2)
	expect_eq(String(improve.get("subject", "")), "Improve app", "then main's commit")
	expect(not String(improve.get("email", "")).is_empty() and improve.has("refs"), "shaped like History's rows: %s" % improve)
	expect_eq(commits.kind_at(3), "", "feature/login has no commits of its own")
	commits.select_only(2)
	expect(await wait_until(func() -> bool:
		return not compare.focused_commit().is_empty() and compare.details_header().visible), "the commit's details load")
	expect_eq(compare.details_header().summary_text(), "Improve app", "the details name the commit")
	expect_eq(compare.file_list().row_count(), 1, "the commit changed one file")
	expect(not Actions.is_enabled(&"compare.cherry_pick"), "main's commit is already in HEAD")
	expect(compare.cherry_pick_reason().contains("Improve app"), "the reason names it: %s" % compare.cherry_pick_reason())
	commits.select_only(1)
	expect_eq(commits.cursor, 0, "moving up skips the section header to All changes")
	commits.select_only(0)
	expect(compare.focused_commit().is_empty(), "All changes again")
	expect(await _compared(session), "the whole comparison shows")
	expect(not compare.details_header().visible, "the details hide")

	# Section headers are one-line rows; a click folds them.
	expect(commits.row_extent(1) < commits.row_extent(2), "the header is shorter than a commit row")
	expect_eq(commits.row_top(2), commits.row_extent(0) + commits.row_extent(1), "rows follow each other")
	commits.select_only(2)
	expect(await wait_until(func() -> bool: return not compare.focused_commit().is_empty()), "the commit is focused")
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(20.0, commits.row_top(1) + commits.row_extent(1) * 0.5 - commits.scroll_offset())
	commits._gui_input(click)
	expect(commits.is_collapsed("right"), "clicking the header folds it")
	expect_eq(commits.kind_at(2), "", "its commits are hidden")
	expect_eq(commits.cursor, 0, "the cursor moves to All changes")
	expect(compare.focused_commit().is_empty(), "which shows the whole comparison")
	expect(await _compared(session), "the whole comparison loads")
	commits._gui_input(click)
	expect(not commits.is_collapsed("right") and commits.kind_at(2) == "commit", "a second click unfolds it")

	# Restore app.txt from main over the local edit, then Undo.
	var app_path: String = repo.path_join("app.txt")
	var edited: String = read_file(app_path)
	expect(await wait_until(func() -> bool: return compare.current_file() == "app.txt"), "app.txt is selected")
	expect(Actions.is_enabled(&"compare.restore_right"), "Restore from main is offered")
	Actions.run_action(&"compare.restore_right")
	expect(await wait_until(func() -> bool: return read_file(app_path) == "v2\n"), "app.txt is main's again")
	expect(await wait_until(func() -> bool: return session.can_undo_discard()), "the restore can be undone")
	session.undo_discard()
	expect(await wait_until(func() -> bool: return read_file(app_path) == edited), "Undo brings the edit back")

	# The working-copy side follows the files.
	worktree.open_compare("main", "", true)
	expect(await _compared(session), "main ⇄ working copy compares")
	expect(not Actions.is_enabled(&"compare.restore_right"), "nothing to restore from the working copy")
	var extra: String = repo.path_join("extra.txt")
	write_file(extra, "x\n")
	expect(await wait_until(func() -> bool: return int(session.compare_info().get("file_count", 0)) == 3),
			"a new file shows up in the comparison")
	DirAccess.remove_absolute(extra)
	expect(await wait_until(func() -> bool: return int(session.compare_info().get("file_count", 0)) == 2),
			"and goes when it is deleted")

	# A fetch moves origin/main: the open comparison follows, and the
	# fetched commit can be cherry-picked.
	worktree.open_compare("main", "origin/main", false)
	expect(await _compared(session), "main ⇄ origin/main compares")
	var before: int = int(session.compare_info()["only_right"])
	Actions.run_action(&"sync.fetch")
	expect(await wait_until(func() -> bool:
		var now: Dictionary = session.compare_info()
		return String(now.get("state", "")) == "ready" and not bool(now.get("reloading", false)) \
				and int(now.get("only_right", 0)) == before + 1), "the fetched commit shows on the right")
	expect(await wait_until(func() -> bool: return commits.kind_at(2) == "commit"), "the commit is listed")
	commits.select_only(2)
	expect(Actions.is_enabled(&"compare.cherry_pick"), "a commit HEAD lacks can be cherry-picked: %s" % compare.cherry_pick_reason())
	Actions.run_action(&"compare.cherry_pick")
	var confirm: ConfirmationDialog = worktree.ops().confirm_dialog()
	expect(await wait_until(func() -> bool: return confirm.visible), "cherry-picking asks first")
	confirm.hide()

	# Both sides moved: main's own commit is left out (and dimmed) until
	# the Include pill is on. From the focused commit, it selects All changes.
	var since_fork: int = int(session.compare_info()["all_file_count"])
	var left_row: int = -1
	for row: int in commits.row_count():
		if commits.kind_at(row) == "left":
			left_row = row + 1
	expect(commits.kind_at(left_row) == "commit" and commits.is_row_dimmed(left_row),
			"main's own commit is dimmed")
	expect(Actions.is_enabled(&"compare.full_difference"), "main's commits can be included")
	commits.include_toggled.emit()
	expect(await _compared(session), "the full difference loads")
	expect(compare.focused_commit().is_empty() and commits.cursor == 0, "the pill selects All changes")
	expect(int(session.compare_info()["file_count"]) > since_fork, "it adds main's own change")
	expect(commits.includes_left() and not commits.is_row_dimmed(left_row),
			"the pill is on and main's commit no longer dimmed")
	commits.include_toggled.emit()
	expect(await _compared(session), "only since the fork again")
	expect_eq(int(session.compare_info()["file_count"]), since_fork, "back to the changes since the fork")

	# The tab's × closes the comparison.
	worktree.compare_close_button().emit_signal(&"pressed")
	expect(not compare.has_comparison() and not worktree.compare_button().visible, "the tab's × closes it")
	main.queue_free()
	await get_tree().process_frame


func _compared(session: RepoSession) -> bool:
	await get_tree().process_frame
	return await wait_until(func() -> bool:
		var info: Dictionary = session.compare_info()
		return String(info.get("state", "")) == "ready" and not bool(info.get("reloading", false)))
