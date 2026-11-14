extends Node
## Merge workflow, end to end (M7), one numbered screenshot per step: the
## branch list in merge mode, the preview dialog (conflicts, clean,
## fast-forward, local changes in the way), the banner and the resolver
## (unified, base, side by side, keyboard and buttons), the commit that
## finishes the merge, the undo strip and Remove merge, then Rebase (a check
## that stops on a conflict, a clean one with pushed commits and a merge, the
## undo strip and Undo). Keys go through the viewport like a user's. Pass
## --repo=<repo built by tests/visual/merge_prep.sh> --out=<directory>, set
## GITBELLO_CONFIG to a scratch config and launch windowed; --long also shoots
## the scrolling commit list of `long`. It merges and rebases there: never
## point it at a real repository.

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _out: String = ""
var _step: int = 0
## `--long`: the repo also has `long`, many commits ahead of main.
var _long: bool = false


func _ready() -> void:
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg == "--long":
			_long = true
	if repo.is_empty() or _out.is_empty():
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_viewport().gui_embed_subwindows = true
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.graph_row_count() > 0):
		get_tree().quit(3)
		return
	var view: WorktreeView = page.active_view()
	var ops: RepoOps = page.ops()
	var dialog: MergeDialog = ops.merge_dialog()
	var shown: Callable = func() -> bool: return dialog.visible and dialog.summary_texts() != PackedStringArray(["Checking…"])
	var changes: ChangesView = page.changes()
	var diff: DiffView = changes.diff_view()
	var box: CommitBox = changes.commit_box()

	page.show_view(WorktreeView.View.HISTORY)
	await _shot("history-before")

	# Ctrl+Shift+B: the branch list picks the branch to merge.
	page.focus_view()
	await _press("Ctrl+Shift+B")
	var popover: BranchPopover = view.branch_popover()
	await _wait(func() -> bool: return popover.visible)
	await _shot("merge-picker")
	popover.set_filter("topic")
	await _shot("merge-picker-filtered")
	await _press("Enter", popover)
	await _wait(shown)
	await _shot("dialog-conflicts")
	# A long branch name: the badges wrap under the branches.
	var long_name: String = "defaults/rework-the-service-defaults-so-new-people-can-run-it"
	var picked: String = dialog.source_text()
	dialog.hide()
	ops.merge_into_current(long_name, long_name)
	await _wait(shown)
	await _shot("dialog-long-name")
	dialog.hide()
	ops.merge_into_current(picked, picked)
	await _wait(shown)
	dialog.commits_section().header().pressed.emit()
	await _shot("dialog-conflicts-commits-open")
	dialog.set_strategy("squash")
	await _shot("dialog-conflicts-squash")
	dialog.set_strategy("merge")
	# The source chip picks another branch.
	dialog.source_button().pressed.emit()
	await _wait(func() -> bool: return dialog.branch_popover().visible)
	await _shot("dialog-source-picker")
	dialog.branch_popover().hide()

	# Enter: merge; the banner and the resolver take over.
	dialog.get_ok_button().grab_focus()
	await _press("Enter", dialog)
	await _wait(func() -> bool: return changes.has_conflict_blocks() and diff.has_focus())
	await _shot("resolver-unified")
	session.show_conflict_base(true)
	await _wait(func() -> bool: return changes.diff_panel().base_button().button_pressed)
	await _shot("resolver-show-base")
	Actions.run_action(&"diff.cycle_mode")
	await _shot("resolver-side-by-side")
	Actions.run_action(&"diff.cycle_mode")
	session.show_conflict_base(false)
	diff.grab_focus()
	diff.select_only(diff.find_block_header(-1, true))

	# Alt+T takes theirs for the first conflict; F8 goes to the next one.
	await _press("Alt+T")
	await _wait(func() -> bool: return _blocks(session) == 1)
	await _shot("first-conflict-theirs")
	await _press("Ctrl+Z")
	await _wait(func() -> bool: return _blocks(session) == 2)
	await _shot("undo-choice")
	await _press("Alt+T")
	await _wait(func() -> bool: return _blocks(session) == 1)
	# The block left: the header after the first one, when the first is taken.
	var header: int = diff.find_block_header(-1, true)
	var next: int = diff.find_block_header(header, true)
	if next > header:
		header = next
	diff.select_only(header)
	diff.press_block(header, "both")
	await _shot("both-menu")
	for child: Node in changes.get_children():
		if child is PopupMenu and (child as PopupMenu).visible:
			(child as PopupMenu).hide()
			(child as PopupMenu).id_pressed.emit(1)
	await _wait(func() -> bool: return int(session.operation_info().get("conflicts", 1)) == 0 \
			and int(session.operation_info().get("resolved", 0)) > 0)
	await _wait(func() -> bool: return box.can_commit())
	await _shot("all-resolved")

	# Ctrl+Enter commits the merge; the undo strip offers it back.
	await _press("Ctrl+Enter")
	await _wait(func() -> bool:
		return session.operation().is_empty() and String(session.undoable_commit().get("subject", "")).begins_with("Merge"))
	await _shot("merge-committed")
	page.show_view(WorktreeView.View.HISTORY)
	await _shot("history-after-merge")
	page.show_view(WorktreeView.View.CHANGES)
	Actions.run_action(&"commit.undo")
	await _wait(func() -> bool: return ops.undo_merge_dialog().visible)
	await _shot("undo-merge-dialog")
	ops.remove_merge_button().pressed.emit()
	await _wait(func() -> bool: return not String(session.undoable_commit().get("subject", "")).begins_with("Merge"))
	await _shot("merge-removed")

	# The other dialogs: a clean merge, a fast-forward, local changes in the way.
	ops.merge_into_current("clean", "clean")
	await _wait(shown)
	await _shot("dialog-clean")
	dialog.set_strategy("squash")
	await _shot("dialog-clean-squash")
	dialog.hide()
	ops.merge_into_current("ahead", "ahead")
	await _wait(shown)
	await _shot("dialog-fast-forward")
	dialog.set_strategy("merge")
	await _shot("dialog-fast-forward-as-merge")
	dialog.hide()
	# A long branch: the commit list scrolls in a dialog that fits the window,
	# scrolled to its end, then in a shorter window.
	if _long:
		ops.merge_into_current("long", "long")
		await _wait(shown)
		await _shot("dialog-long-list")
		var list: ScrollContainer = dialog.commits_section().scroll()
		list.scroll_vertical = int(list.get_v_scroll_bar().max_value)
		await _shot("dialog-long-list-end")
		dialog.hide()
		var full: Vector2i = get_window().size
		get_window().size = Vector2i(full.x, floori(full.y * 2.0 / 3.0))
		await get_tree().process_frame
		ops.merge_into_current("long", "long")
		await _wait(shown)
		await _shot("dialog-long-list-short-window")
		dialog.hide()
		get_window().size = full
		await get_tree().process_frame
	# `clean` changes README.md's first line; a local edit to its last line.
	var readme: String = FileAccess.get_file_as_string(repo.path_join("README.md"))
	FileAccess.open(repo.path_join("README.md"), FileAccess.WRITE).store_string(readme + "Local note.\n")
	await _wait(func() -> bool: return session.change_count() > 0)
	ops.merge_into_current("clean", "clean")
	await _wait(shown)
	await _shot("dialog-local-changes")
	dialog.get_ok_button().pressed.emit()
	await _wait(func() -> bool: return session.operation().is_empty() and session.shelves().is_empty() \
			and String(session.undoable_commit().get("subject", "")).begins_with("Merge"))
	await _shot("shelved-and-merged")
	ops.merge_into_current("clean", "clean")
	await _wait(shown)
	await _shot("dialog-up-to-date")
	dialog.hide()
	# The dialog while it checks (caught before the preview lands), and a
	# target that cannot be merged.
	ops.merge_into_current("topic", "topic")
	await _shot("dialog-checking", 2)
	dialog.hide()
	ops.merge_into_current("no-such-branch", "no-such-branch")
	await _wait(shown)
	await _shot("dialog-cannot-merge")
	dialog.hide()
	# The light theme.
	Actions.run_action(&"view.theme_light")
	ops.merge_into_current("topic", "topic")
	await _wait(shown)
	await _shot("dialog-conflicts-light")
	dialog.hide()
	Actions.run_action(&"view.theme_dark")
	# The plain branch list fits its rows the same way.
	view.open_branches()
	await _wait(func() -> bool: return popover.visible)
	await _shot("branch-list")
	popover.hide()
	# A long subject in the undo strip shortens; its age stays.
	box.set_message("Note the local setup steps in the README so new people can run the service without asking", "")
	box.commit()
	await _wait(func() -> bool: return box.undo_text().begins_with("Note the local"))
	await _shot("undo-strip-long")

	# Rebase: `rework` stops on main's change to app.txt.
	if not await _switch(ops, session, "rework"):
		get_tree().quit(4)
		return
	ops.merge_into_current("refs/heads/main", "main")
	await _wait(func() -> bool: return dialog.visible and dialog.strategy_enabled("rebase"))
	dialog.set_strategy("rebase")
	await _wait(func() -> bool: return dialog.summary_texts().has("Conflicts"))
	await _shot("rebase-conflicts")
	dialog.incoming_section().set_folded(false)
	await _shot("rebase-conflicts-incoming-open")
	dialog.hide()
	# `feature` replays cleanly: one commit is pushed and a merge is flattened.
	if not await _switch(ops, session, "feature"):
		get_tree().quit(4)
		return
	page.show_view(WorktreeView.View.HISTORY)
	var feature_graph: Callable = func() -> bool: return session.graph_row_count() > 0 \
			and String(session.graph_rows(0, 1)[0].get("subject", "")).begins_with("Merge branch 'feature-part'")
	await _wait(feature_graph)
	await _shot("history-before-rebase", 60)
	ops.merge_into_current("refs/heads/main", "main")
	await _wait(func() -> bool: return dialog.visible and dialog.strategy_enabled("rebase"))
	await _shot("rebase-feature-merge-default")
	dialog.set_strategy("rebase")
	await _shot("rebase-checking", 2)
	await _wait(func() -> bool: return dialog.summary_texts().has("No conflicts"))
	await _shot("rebase-clean")
	dialog.hide()
	Actions.run_action(&"view.theme_light")
	ops.merge_into_current("refs/heads/main", "main")
	await _wait(func() -> bool: return dialog.visible and dialog.strategy_enabled("rebase"))
	dialog.set_strategy("rebase")
	await _wait(func() -> bool: return dialog.summary_texts().has("No conflicts"))
	await _shot("rebase-clean-light")
	dialog.hide()
	Actions.run_action(&"view.theme_dark")
	ops.merge_into_current("refs/heads/main", "main")
	await _wait(func() -> bool: return dialog.visible and dialog.strategy_enabled("rebase"))
	dialog.set_strategy("rebase")
	await _wait(func() -> bool: return dialog.summary_texts().has("No conflicts"))
	dialog.get_ok_button().pressed.emit()
	await _wait(func() -> bool: return box.undo_text() == "Rebased feature onto main")
	await _shot("history-after-rebase")
	page.show_view(WorktreeView.View.CHANGES)
	await _shot("rebase-undo-strip")
	# The branch is now ahead of main: Rebase is off, with its reason.
	ops.merge_into_current("refs/heads/main", "main")
	await _wait(shown)
	print("REBASE REASON ", dialog.strategy_reason("rebase"))
	await _shot("rebase-up-to-date")
	dialog.hide()
	Actions.run_action(&"commit.undo")
	await _wait(func() -> bool: return box.undo_text() != "Rebased feature onto main" and session.operation().is_empty())
	page.show_view(WorktreeView.View.HISTORY)
	await _wait(feature_graph)
	await _shot("rebase-undone", 90)
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit()


## Switches to `branch`, answering the switch dialog if it asks.
func _switch(ops: RepoOps, session: RepoSession, branch: String) -> bool:
	ops.checkout_branch(branch)
	await _wait(func() -> bool: return ops.switch_dialog().visible or session.current_branch() == branch, 5000)
	if ops.switch_dialog().visible:
		ops.switch_dialog().get_ok_button().pressed.emit()
	return await _wait(func() -> bool: return session.current_branch() == branch)


## Conflict blocks left in the file the resolver shows.
static func _blocks(session: RepoSession) -> int:
	var info: Dictionary = session.diff_info()
	return int((info.get("conflict", {}) as Dictionary).get("blocks", 0)) if String(info.get("kind", "")) == "conflict" else 0


## A key press and release such as `Ctrl+Enter`, through the viewport (or
## `into`, such as a popup).
func _press(shortcut: String, into: Viewport = null) -> void:
	var event: InputEventKey = Shortcuts.parse(shortcut)
	event.physical_keycode = event.keycode
	var target: Viewport = into if into != null else get_viewport()
	target.push_input(event)
	var release: InputEventKey = event.duplicate() as InputEventKey
	release.pressed = false
	target.push_input(release)
	await get_tree().process_frame


func _wait(condition: Callable, timeout_ms: int = 30_000) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await get_tree().process_frame
	print("TIMEOUT at step ", _step + 1)
	return bool(condition.call())


## Saves `NN-<name>.png` after the frame settles.
func _shot(name_text: String, frames: int = 10) -> void:
	for frame: int in frames:
		await get_tree().process_frame
	RenderingServer.force_draw()
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, name_text])
	var error: Error = get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path, " ", error)
