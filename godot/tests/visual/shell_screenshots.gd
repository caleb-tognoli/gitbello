extends Node
## Saves screenshots of the shell for visual review (not part of the smoke run).
## Usage: godot --path godot res://tests/visual/shell_screenshots.tscn --
##        --repos=<path>;<path>;... --out=<dir> [--branches-only]
## Run with GITBELLO_CONFIG pointing at a scratch config file.
## --branches-only captures grouped and filtered lists without the later git operations.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000


func _ready() -> void:
	var repos: PackedStringArray = PackedStringArray()
	var out: String = ""
	var branches_only: bool = false
	var parent_fixtures: String = ""
	var prepare_parent_merge: bool = false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repos="):
			repos = arg.trim_prefix("--repos=").split(";", false)
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
		elif arg == "--branches-only":
			branches_only = true
		elif arg.begins_with("--parent-details="):
			parent_fixtures = arg.trim_prefix("--parent-details=")
		elif arg == "--prepare-parent-merge":
			prepare_parent_merge = true
	if not parent_fixtures.is_empty():
		get_tree().quit(0 if await _parent_details(parent_fixtures, out, prepare_parent_merge) else 1)
		return
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
	if branches_only:
		var captured: bool = await _branch_shots(main.page_at(0), out)
		while main.tab_count() > 0:
			main.close_tab(0)
		get_tree().quit(0 if captured else 2)
		return

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
	main.palette().open()
	main.palette().set_query("amend")
	await _shot(out, "palette_unavailable_dark")
	Actions.run_action(&"view.theme_light")
	await _shot(out, "palette_unavailable_light")
	Actions.run_action(&"view.theme_dark")
	main.palette().close()
	# The filter over the changed files and its options.
	var filter: FilterField = changes.filter_field()
	await _shot(out, "changes_filter_empty")
	filter.options_button().pressed.emit()
	await _shot_window(filter.menu(), out, "changes_filter_menu_inactive")
	filter.menu().hide()
	filter.focus_text()
	filter.set_text("src")
	filter.set_option("modified", true)
	await _shot(out, "changes_filter")
	Actions.run_action(&"view.theme_light")
	await _shot(out, "changes_filter_light")
	Actions.run_action(&"view.theme_dark")
	filter.options_button().pressed.emit()
	await _shot_window(filter.menu(), out, "changes_filter_menu")
	var clear_index: int = filter.menu().item_count - 1
	filter.menu().id_pressed.emit(filter.menu().get_item_id(clear_index))
	filter.options_button().pressed.emit()
	await _shot_window(filter.menu(), out, "changes_filter_menu_cleared")
	filter.menu().hide()
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
	page.changes().commit_box().set_message("Next task", "This ordinary draft survives amending.")
	var head: String = String(page.session.status().get("oid", ""))
	for row: int in page.history().commit_list().row_count():
		if page.history().commit_list().hash_at(row) == head:
			page.history().commit_list().select_only(row)
			break
	page.history().commit_menu_requested.emit(page.get_screen_position() + Vector2(180.0, 170.0))
	await _shot_window(page.context_menu(), out, "amend_menu")
	page.press_menu("Amend…")
	deadline = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and not page.changes().commit_box().can_commit():
		await get_tree().process_frame
	await _shot(out, "amend_dark")
	Actions.run_action(&"view.theme_light")
	await _shot(out, "amend_light")
	Actions.run_action(&"view.theme_dark")
	Actions.run_action(&"changes.cancel_amend")
	page.show_view(WorktreeView.View.HISTORY)

	# M6.5 P2: the branch list and a branch's menu, the new-branch form, a
	# busy Sync button, a progress toast, the busy overlay, the operation
	# banner and a toast with fixes (fetching changes only the fixture repo).
	var view: WorktreeView = page.active_view()
	view.open_branches()
	await _shot_window(view.branch_popover(), out, "branch_list")
	view.branch_popover().set_filter("no-matching-branch")
	await _shot_window(view.branch_popover(), out, "branch_no_matches_dark")
	Actions.run_action(&"view.theme_light")
	await _shot_window(view.branch_popover(), out, "branch_no_matches_light")
	Actions.run_action(&"view.theme_dark")
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
	await _shot_window(main.settings_window(), out, "settings")
	main.settings_window().show_category("Interface")
	await _shot_window(main.settings_window(), out, "settings_interface")
	main.settings_window().hide()

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
	await _shot(out, "home")
	get_tree().quit(0)


func _branch_shots(page: RepoTab, out: String) -> bool:
	var view: WorktreeView = page.active_view()
	var popover: BranchPopover = view.branch_popover()
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while page.session.branch_refs().is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var other: String = ""
	for ref: Dictionary in page.session.branch_refs():
		if String(ref["kind"]) == "branch" and not bool(ref["is_head"]):
			other = String(ref["short_name"])
			break
	if other.is_empty() or page.session.current_branch().is_empty():
		printerr("shell_screenshots: branch captures need current and non-current branches")
		return false
	for mode: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + mode))
		view.open_branches()
		print("BRANCH ROWS ", mode, " grouped: ", popover.row_names())
		await _shot_window(popover, out, "branch_grouped_" + mode)
		popover.set_filter(page.session.current_branch())
		print("BRANCH ROWS ", mode, " current: ", popover.row_names())
		await _shot_window(popover, out, "branch_filtered_current_" + mode)
		popover.set_filter(other)
		print("BRANCH ROWS ", mode, " other: ", popover.row_names())
		await _shot_window(popover, out, "branch_filtered_other_" + mode)
		popover.hide()
	return true


func _settle() -> void:
	for i: int in 30:
		await get_tree().process_frame


## Popups may be windows of their own; this saves one's content.
func _shot_window(window: Window, dir: String, file_name: String) -> void:
	await _settle()
	var path: String = dir.path_join(file_name + ".png")
	window.get_texture().get_image().save_png(path)
	print("SHOT ", path)


func _shot(dir: String, file_name: String) -> void:
	await _settle()
	var path: String = dir.path_join(file_name + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path)


## --parent-details=<fixture dir> --out=<dir>; --prepare-parent-merge pulls
## the fixture's local remote into repo-1 to make a real two-parent commit.
func _parent_details(fixtures: String, out: String, prepare_merge: bool) -> bool:
	var config: String = OS.get_environment("GITBELLO_CONFIG").replace("\\", "/").simplify_path()
	var root: String = fixtures.replace("\\", "/").simplify_path()
	if out.is_empty() or config.get_base_dir() != root \
			or not FileAccess.file_exists(root.path_join("global.gitconfig")):
		printerr("parent_details: use CLI fixtures and GITBELLO_CONFIG=<fixtures>/config.toml")
		return false
	if DirAccess.make_dir_recursive_absolute(out) != OK:
		printerr("parent_details: cannot create output directory")
		return false
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(root.path_join("repo-1"))
	page.show_view(WorktreeView.View.HISTORY)
	var session: RepoSession = page.session
	if not await _parent_wait(func() -> bool: return session.graph_row_count() >= 3 \
			and not session.status().is_empty(), "fixture history"):
		return false
	var ordinary: int = -1
	var initial: int = -1
	var filtered_parent: int = -1
	for row: Dictionary in session.graph_rows(0, session.graph_row_count()):
		if String(row["subject"]) == "Improve app":
			ordinary = int(row["row"])
		elif String(row["subject"]) == "Initial commit":
			initial = int(row["row"])
		elif String(row["subject"]) == "Add app":
			filtered_parent = int(row["row"])
	if ordinary < 0 or initial < 0 or filtered_parent < 0:
		printerr("parent_details: expected fixture subjects are missing")
		return false
	if not await _parent_capture(page, ordinary, 1, out, "parent_ordinary"):
		return false
	if not await _parent_capture(page, initial, 0, out, "parent_root"):
		return false
	page.history().search_field().set_text("Improve")
	if not await _parent_wait(func() -> bool: return bool(session.search_info().get("done", false)), "search"):
		return false
	if not await _parent_capture(page, filtered_parent, 1, out, "parent_filtered_parent"):
		return false
	page.history().search_field().set_text("")
	if not await _parent_wait(func() -> bool: return session.search_info().is_empty(), "clear search"):
		return false
	if prepare_merge:
		var previous: String = String(session.status().get("oid", ""))
		if session.pull("merge") < 0:
			printerr("parent_details: merge pull could not start")
			return false
		if not await _parent_wait(func() -> bool: return String(session.status().get("oid", "")) != previous \
				and session.graph_row_count() >= 5, "fixture merge pull"):
			return false
	if not await _parent_capture(page, 0, 2, out, "parent_merge"):
		return false
	if not page.history().details().parent_links().is_empty():
		if not await _parent_navigation_proof(main, page, out):
			return false
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame
	print("PARENT DETAILS CAPTURES PASS")
	return true


func _parent_wait(condition: Callable, description: String) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	printerr("parent_details: timed out waiting for ", description)
	return false


func _parent_capture(page: RepoTab, row: int, count: int, out: String, shot_name: String) -> bool:
	var history: HistoryView = page.history()
	var oid: String = history.commit_list().hash_at(row)
	if oid.is_empty():
		printerr("parent_details: missing row ", row)
		return false
	history.commit_list().select_only(row)
	history.commit_list().scroll_to_row(row)
	history.commit_list().grab_focus()
	history.details().show_commit(oid)
	if not await _parent_wait(func() -> bool: return String(page.session.commit_info().get("oid", "")) == oid \
			and history.details().diff_panel().view().row_count() > 0, "commit and diff " + shot_name):
		return false
	var info: Dictionary = page.session.commit_info()
	var parents: PackedStringArray = info["parents"]
	if parents.size() != count:
		printerr("parent_details: ", shot_name, " expected ", count, " parents, got ", parents.size())
		return false
	var parent_group: Control = history.details().get_node("%Parents") as Control
	if parent_group.visible != (count > 0):
		printerr("parent_details: wrong parent visibility for ", shot_name)
		return false
	print("PARENT BASELINE ", shot_name, " oid=", oid, " parents=", parents)
	for theme: String in ["dark", "light"]:
		if not Actions.run_action(StringName("view.theme_" + theme)):
			printerr("parent_details: theme action unavailable")
			return false
		await _settle()
		var rects: Array[Rect2] = []
		for link: LinkButton in history.details().parent_links():
			rects.append(link.get_global_rect())
		print("PARENT GEOMETRY ", shot_name, " group=", parent_group.get_global_rect(), " links=", rects)
		var path: String = out.path_join(shot_name + "_" + theme + ".png")
		if get_viewport().get_texture().get_image().save_png(path) != OK:
			printerr("parent_details: could not save ", path)
			return false
		print("SHOT ", path)
	return true


func _parent_navigation_proof(main: Main, page: RepoTab, out: String) -> bool:
	var history: HistoryView = page.history()
	var session: RepoSession = page.session
	var source: String = history.details().commit_oid()
	var subject: String = String(session.commit_info()["summary"])
	var parents: PackedStringArray = session.commit_info()["parents"]
	var rows: Dictionary = session.graph_parent_rows(0)
	for index: int in parents.size():
		history._select(0)
		history.details().show_commit(source)
		if not await _parent_wait(func() -> bool: return history.details().commit_oid() == source \
				and history.details().parent_links().size() == 2, "merge navigation source"):
			return false
		var links: Array[LinkButton] = history.details().parent_links()
		if index == 0:
			var motion: InputEventMouseMotion = InputEventMouseMotion.new()
			motion.position = links[index].get_global_rect().get_center()
			get_viewport().push_input(motion)
			var click: InputEventMouseButton = InputEventMouseButton.new()
			click.position = motion.position
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = true
			get_viewport().push_input(click)
			click = click.duplicate() as InputEventMouseButton
			click.pressed = false
			get_viewport().push_input(click)
		else:
			links[0].grab_focus()
			_parent_key("Tab")
			await get_tree().process_frame
			if not links[index].has_focus():
				printerr("parent_details: Tab did not reach the second parent")
				return false
			await _shot(out, "parent_merge_keyboard_focus")
			print("PARENT KEY CONTEXT focus=", links[index].has_focus(), " shown=", history.details().commit_oid(),
					" cached=", session.commit_info().get("oid", ""), " selected=", history.selected_commit())
			_parent_key("Space")
			print("PARENT KEY RESULT selected=", history.selected_commit(), " pending=", history._pending_parent_oid)
		if not await _parent_wait(func() -> bool: return history.details().commit_oid() == parents[index] \
				and history.commit_list().hash_at(history.commit_list().cursor) == parents[index], "real parent activation"):
			return false
		if String(page.commit_target().get("hash", "")) != parents[index] \
				or Actions.is_enabled(&"history.go_to_parent"):
			printerr("parent_details: action targeting did not follow navigation")
			return false
		print("PARENT NAVIGATION ", "mouse" if index == 0 else "Tab+Space", " source=", source,
				" destination=", parents[index], " row=", history.commit_list().cursor)
		if not await _parent_capture(page, int(rows[parents[index]]), 1, out, "parent_destination_%d" % (index + 1)):
			return false
	history.search_field().set_text(subject)
	if not await _parent_wait(func() -> bool: return bool(session.search_info().get("done", false)) \
			and history.details().commit_oid() == source, "search selects merge"):
		return false
	history.details().parent_links()[0].grab_focus()
	_parent_key("Enter")
	if not await _parent_wait(func() -> bool: return history.details().commit_oid() == parents[0], "Enter with search"):
		return false
	if history.search_field().text() != subject or session.search_match_index(history.commit_list().cursor) != -1:
		printerr("parent_details: search was not preserved")
		return false
	print("PARENT NAVIGATION Enter destination=", parents[0], " preserved_query=", subject)
	if not await _parent_capture(page, int(rows[parents[0]]), 1, out, "parent_destination_search"):
		return false
	_parent_key("F3")
	if not await _parent_wait(func() -> bool: return history.details().commit_oid() == source, "F3 after parent navigation"):
		return false
	if not await _parent_capture(page, 0, 2, out, "parent_search_next_match"):
		return false
	if main.current_page() != page:
		printerr("parent_details: navigation changed the active repository")
		return false
	print("PARENT NAVIGATION INPUT PASS")
	return true


func _parent_key(shortcut: String) -> void:
	var event: InputEventKey = Shortcuts.parse(shortcut)
	event.physical_keycode = event.keycode
	if event.keycode == KEY_SPACE:
		event.unicode = 32
	get_viewport().push_input(event)
	var release: InputEventKey = event.duplicate() as InputEventKey
	release.pressed = false
	get_viewport().push_input(release)
