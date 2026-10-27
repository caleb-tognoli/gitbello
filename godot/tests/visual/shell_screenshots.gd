extends Node
## Saves screenshots of the shell for visual review (not part of the smoke run).
## Usage: godot --path godot res://tests/visual/shell_screenshots.tscn --
##        --repos=<path>;<path>;... --out=<dir>
## Run with GITBELLO_CONFIG pointing at a scratch config file.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000


func _ready() -> void:
	var repos: PackedStringArray = PackedStringArray()
	var out: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repos="):
			repos = arg.trim_prefix("--repos=").split(";", false)
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	if repos.is_empty() or out.is_empty():
		printerr("shell_screenshots: pass -- --repos=a;b --out=<dir>")
		get_tree().quit(2)
		return
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	for repo: String in repos:
		main.open_repo(repo)
	main.tab_bar().current_tab = 0
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		var list: CommitList = main.page_at(0).history().commit_list()
		if list.row_count() > 0 and not main.page_at(0).session.badge().get("head", "").is_empty():
			break
		await get_tree().process_frame
	main.page_at(0).history().commit_list().select_only(0)
	await _settle()

	Actions.run_action(&"view.theme_dark")
	await _shot(out, "dark")
	Actions.run_action(&"view.theme_light")
	await _shot(out, "light")
	# Two more accent colours (P1 review), then back to the default.
	Core.set_settings({"accent": "#2bb3a8"})
	ThemeManager.apply(main)
	await _shot(out, "accent_teal_light")
	Actions.run_action(&"view.theme_dark")
	Core.set_settings({"accent": "#e0569a"})
	ThemeManager.apply(main)
	await _shot(out, "accent_pink_dark")
	Core.set_settings({"accent": ""})
	ThemeManager.apply(main)
	main.palette().open()
	main.palette().set_query("tab")
	await _shot(out, "palette")
	main.palette().close()
	Actions.run_action(&"view.toggle_git_log")
	await _shot(out, "git_log")
	Actions.run_action(&"view.toggle_git_log")

	var page: RepoTab = main.page_at(0)
	page.show_view(WorktreeView.View.CHANGES)
	deadline = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and page.changes().diff_view().row_count() == 0:
		await get_tree().process_frame
	await _shot(out, "changes_dark")
	Actions.run_action(&"view.theme_light")
	await _shot(out, "changes_light")
	Actions.run_action(&"view.theme_dark")
	# M6.5 P3: a file left out, then a line left out of the highlighted file.
	var changes: ChangesView = page.changes()
	changes.list().grab_focus()
	changes.list().select_only(changes.list().row_count() - 1)
	changes.list().toggle_selection()
	changes.list().select_only(0)
	deadline = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and not changes.diff_view().pickable:
		await get_tree().process_frame
	for row: int in changes.diff_view().row_count():
		if int(changes.diff_view().line(row).get("kind", 0)) == DiffView.KIND_ADDED:
			changes.diff_view().select_only(row)
			changes.toggle_diff_lines()
			break
	await _shot(out, "changes_picks")
	# Text selected in the diff, and a long file's gaps (when the first repo
	# has a changed `long.txt`): one opened upwards.
	var diff: DiffView = changes.diff_view()
	diff.grab_focus()
	diff._sel_from = Vector2i(1, 2)
	diff._sel_to = Vector2i(mini(3, diff.row_count() - 1), 4)
	diff.queue_redraw()
	await _shot(out, "diff_selection")
	for row: int in changes.list().row_count():
		if changes.list().path_at(row) == "long.txt":
			changes.list().select_only(row)
			deadline = Time.get_ticks_msec() + WAIT_MS
			while Time.get_ticks_msec() < deadline and diff.row_expanders(0).is_empty():
				await get_tree().process_frame
			await _shot(out, "diff_expanders")
			diff.grab_focus()
			diff._select_span(Vector2i(3, 4), Vector2i(5, 12))
			await _shot(out, "diff_selection_colors")
			for header: int in diff.row_count():
				if diff.row_expanders(header) == "both":
					var rows: int = diff.row_count()
					diff.press_expander(header, "up")
					while Time.get_ticks_msec() < deadline and diff.row_count() == rows:
						await get_tree().process_frame
					break
			await _shot(out, "diff_expanded")
	Actions.run_action(&"changes.focus_message")
	page.changes().commit_box().set_message("Add a summary", "And a longer description.")
	await _shot(out, "changes_message")
	# The filter over the changed files and its options.
	var filter: FilterField = changes.filter_field()
	await _shot(out, "changes_filter_empty")
	filter.focus_text()
	filter.set_text("src")
	filter.set_option("modified", true)
	await _shot(out, "changes_filter")
	Actions.run_action(&"view.theme_light")
	await _shot(out, "changes_filter_light")
	Actions.run_action(&"view.theme_dark")
	filter.options_button().pressed.emit()
	await _shot_window(filter.menu(), out, "changes_filter_menu")
	filter.menu().hide()
	filter.set_option("modified", false)
	filter.set_text("")
	# The history search: matches highlighted, other rows dimmed.
	page.show_view(WorktreeView.View.HISTORY)
	var search: FilterField = page.history().search_field()
	search.focus_text()
	search.set_text("app")
	deadline = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and not page.history().status_text().contains(" of "):
		await get_tree().process_frame
	await _shot(out, "history_search")
	Actions.run_action(&"view.theme_light")
	await _shot(out, "history_search_light")
	Actions.run_action(&"view.theme_dark")
	search.set_text("")
	page.history().commit_list().grab_focus()
	await _settle()
	page.show_view(WorktreeView.View.HISTORY)

	# M6.5 P2: the branch list and a branch's menu, the new-branch form, a
	# busy Sync button, a progress toast, the busy overlay, the operation
	# banner and a toast with fixes (fetching changes only the fixture repo).
	var view: WorktreeView = page.active_view()
	view.open_branches()
	await _shot_window(view.branch_popover(), out, "branch_list")
	view.branch_popover().set_filter("feature")
	var ref: Dictionary = view.branch_popover().first_ref()
	view.branch_popover().hide()
	view.show_ref_menu(ref, view.get_screen_position() + Vector2(160.0, 120.0))
	await _shot_window(page.context_menu(), out, "branch_menu")
	page.close_menu()
	Actions.run_action(&"branch.new")
	await _shot_window(page.ops().form(), out, "new_branch")
	page.ops().form().hide()
	view.sync_button().set_busy(true, "Pushing main…  45%", 45)
	var progress: PanelContainer = main.toasts().show_progress("Fetching repo-2…")
	await _shot(out, "busy")
	view.sync_button().set_busy(false, "", -1)
	main.toasts().finish_progress(progress)
	view.banner().show()
	view.overlay().show()
	await _shot(out, "overlay_banner")
	view.overlay().hide()
	view.banner().hide()
	Actions.run_action(&"sync.fetch")
	deadline = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and int(page.session.badge().get("behind", 0)) == 0:
		await get_tree().process_frame
	await _settle()
	Actions.run_action(&"sync.sync", view.sync_button())
	deadline = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and main.toasts().fix_labels().is_empty():
		await get_tree().process_frame
	await _shot(out, "sync_toast")

	# Repository → Remotes… and Tags…, and a menu of the menu bar.
	Actions.run_action(&"repo.remotes")
	await _shot_window(main.remotes_dialog(), out, "remotes")
	main.remotes_dialog().hide()
	Actions.run_action(&"repo.tags")
	await _shot_window(main.tags_dialog(), out, "tags")
	main.tags_dialog().hide()

	# M6: a worktree chip's menu, the new-task form, cleanup and settings.
	page.strip().worktree_menu_requested.emit(page.session.worktrees()[1],
			page.strip().get_screen_position() + Vector2(160.0, 30.0))
	await _shot_window(page.context_menu(), out, "worktree_menu")
	page.close_menu()
	var linked: Dictionary = page.session.worktrees()[1]
	page.ops().remove_worktree({"path": String(linked["path"]), "short": String(linked["name"]),
			"branch": String(linked["branch"]), "detached": false, "changed": 2, "locked": false})
	await _shot_window(page.ops().form(), out, "delete_worktree")
	page.ops().form().hide()
	page.ops().delete_branch("feature/login")
	await _shot_window(page.ops().confirm_dialog(), out, "delete_branch")
	page.ops().confirm_dialog().hide()
	page.select_chip(1)
	await _settle()
	await _shot(out, "second_worktree")
	page.select_chip(0)
	page.ops().new_task()
	var form: FormDialog = page.ops().form()
	var name_line: LineEdit = form.field("name") as LineEdit
	name_line.text = name_line.text + "fix-login"
	name_line.text_changed.emit(name_line.text)
	await _shot_window(form, out, "new_task")
	form.hide()
	page.ops().cleanup_worktrees()
	deadline = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and not form.visible:
		await get_tree().process_frame
	await _shot_window(form, out, "cleanup")
	form.hide()
	Actions.run_action(&"app.settings")
	await _shot_window(main.settings_form(), out, "settings")
	main.settings_form().hide()

	# M6.5 P4: the switch with changes, then changes left on main and the
	# Shelved section (only the fixture repo changes).
	page.show_view(WorktreeView.View.CHANGES)
	page.session.create_branch("topic", "HEAD", false)
	await _settle()
	page.ops().checkout_branch("topic")
	await _shot_window(page.ops().switch_dialog(), out, "switch_dialog")
	page.ops().leave_button().pressed.emit()
	deadline = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and page.session.current_branch() != "topic":
		await get_tree().process_frame
	page.ops().checkout_branch("main")
	deadline = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and not page.changes().offer_bar().visible:
		await get_tree().process_frame
	var shelf_list: ShelfList = page.changes().shelf_list()
	page.show_view(WorktreeView.View.SHELVES)
	if not page.session.shelves().is_empty():
		shelf_list.select_shelf(String(page.session.shelves()[0]["oid"]))
	await _settle()
	await _shot(out, "shelves")

	# M6.5 P3: no local changes (discarding touches only the fixture repo).
	page.session.discard_paths(page.session.change_paths(0, page.session.change_count()))
	deadline = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and page.session.change_count() > 0:
		await get_tree().process_frame
	page.show_view(WorktreeView.View.CHANGES)
	await _shot(out, "changes_empty")

	while main.tab_count() > 0:
		main.close_tab(0)
	await _shot(out, "welcome")
	get_tree().quit(0)


func _settle() -> void:
	for i: int in 30:
		await get_tree().process_frame


## Popups may be windows of their own; this saves one's content.
func _shot_window(window: Window, dir: String, name: String) -> void:
	await _settle()
	var path: String = dir.path_join(name + ".png")
	window.get_texture().get_image().save_png(path)
	print("SHOT ", path)


func _shot(dir: String, name: String) -> void:
	await _settle()
	var path: String = dir.path_join(name + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path)
