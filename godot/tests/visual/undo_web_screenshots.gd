extends "res://tests/visual/menus_screenshots.gd"
## Edit → Undo, Copy ▸ and Open on <host> (M7.17 P2b), in numbered shots with
## the menus drawn in: Edit with nothing to undo, after a discard (and the
## Changes list's menu showing Ctrl+Z on it), after an ignore rule, after
## Ctrl+Z took the rule back; History's commit menu with Copy ▸ beside it and
## Open on GitHub, a pushed branch's, a local branch's and a tag's menus, a
## commit file's menu, the menu bar's Commit menu, Edit in Italian and the
## commit menu in the light theme. Every menu's items are printed.
## It discards a file, adds an ignore rule and points `origin` at github.com
## for the run (put back at the end): pass --repo=<CLI fixture repo-1>
## --out=<directory>, with GITBELLO_CONFIG set to a scratch config, windowed.


func _ready() -> void:
	DisplayServer.window_set_position(Vector2i(-10000, -10000))
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or _out.is_empty():
		printerr("undo_web_screenshots: pass --repo=<repo> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var origin: String = _git(repo, ["remote", "get-url", "origin"])
	_git(repo, ["remote", "set-url", "origin", "https://github.com/owner/repo.git"])
	_git(repo, ["branch", "-f", "local-only", "HEAD"])
	_main = MAIN.instantiate() as Main
	add_child(_main)
	await get_tree().process_frame
	Actions.run_action(&"view.theme_dark")

	var page: RepoTab = _main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() > 0):
		return
	var bar: AppMenuBar = _main.menu_bar()
	await _bar_shot(bar, "Edit", "edit-nothing-to-undo")

	# A discard: Edit → Undo names it, the list's own Undo shows Ctrl+Z.
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var list: VirtualList = changes.list()
	var tracked: String = ""
	for row: int in list.row_count():
		var entry: Dictionary = list.row(row)
		if String(entry.get("code", "")) != "?" and not bool(entry.get("conflicted", false)):
			tracked = String(entry["path"])
			break
	write_untracked(repo.path_join("notes.log"))
	session.discard_paths(PackedStringArray([tracked]))
	if not await _wait(func() -> bool: return String(session.newest_undo()) == "discard"):
		return
	await _bar_shot(bar, "Edit", "edit-undo-discard")
	if not await _wait(func() -> bool: return session.change_index("notes.log") >= 0):
		return
	list.select_only(session.change_index("notes.log"))
	await get_tree().process_frame
	_anchor = list.get_global_rect().position + Vector2(120, list.row_height() * 0.5)
	list.context_menu_requested.emit(list.cursor, Vector2(120, list.row_height() * 0.5))
	await _shot("changes-menu-undo-discard", changes.context_menu())
	changes.context_menu().hide()

	# An ignore rule on top: Undo takes it back first.
	Actions.run_action(&"changes.ignore_file")
	if not await _wait(func() -> bool: return String(session.newest_undo()) == "ignore_rule"):
		return
	await _bar_shot(bar, "Edit", "edit-undo-ignore-rule")
	Actions.run_action(&"edit.undo")
	if not await _wait(func() -> bool: return String(session.newest_undo()) == "discard"):
		return
	await _bar_shot(bar, "Edit", "edit-after-undo")

	# History: the commit menu with Copy ▸ and Open on GitHub.
	page.show_view(WorktreeView.View.HISTORY)
	var commits: CommitList = page.history().commit_list()
	if not await _wait(func() -> bool: return commits.row_count() >= 3):
		return
	var view: WorktreeView = page.active_view()
	var at: Vector2 = commits.get_screen_position() + Vector2(260, commits.row_height() * 0.5)
	_anchor = commits.get_global_rect().position + Vector2(260, commits.row_height() * 0.5)
	commits.select_only(1)
	var oid: String = commits.hash_at(1)
	if not await _wait(func() -> bool: return String(session.commit_info().get("oid", "")) == oid):
		return
	_beside = tr("Copy")
	view._on_commit_menu(at)
	await _shot("commit-menu-copy", view.context_menu())
	view.close_menu()

	# Refs: the pushed current branch, a branch never pushed, a tag.
	for ref: Dictionary in session.branch_refs():
		var ref_name: String = String(ref["name"])
		if not ref_name.begins_with("refs/heads/") or not (bool(ref["is_head"]) or ref_name == "refs/heads/local-only"):
			continue
		view.show_ref_menu({"type": "branch", "name": ref_name, "short": String(ref["short_name"]),
			"commit": String(ref["commit"]), "is_head": bool(ref["is_head"]), "upstream": String(ref["upstream"]),
			"worktree": String(ref["worktree"])}, at)
		await _shot("branch-menu-" + ("pushed" if bool(ref["is_head"]) else "local"), view.context_menu())
		view.close_menu()
	var tags: Array = session.tags()
	if not tags.is_empty():
		var tag: Dictionary = tags[0]
		view.show_ref_menu({"type": "tag", "name": "refs/tags/" + String(tag["name"]), "short": String(tag["name"]),
			"commit": String(tag["commit"]), "is_head": false, "upstream": ""}, at)
		await _shot("tag-menu", view.context_menu())
		view.close_menu()

	# A file of the commit: Copy path and Open on GitHub.
	var details: CommitDetails = page.history().details()
	var files: CommitFileList = details.file_list()
	if await _wait(func() -> bool: return files.row_count() > 0):
		files.select_only(0)
		if await _wait(func() -> bool: return not details.diff_panel().shown_path().is_empty()):
			_anchor = files.get_global_rect().position + Vector2(80, files.row_height() * 0.5)
			files.context_menu_requested.emit(0, Vector2(80, files.row_height() * 0.5))
			await _shot("commit-file-menu", details.file_menu())
			details.file_menu().hide()

	# The menu bar's Commit menu, with Copy ▸ beside it.
	_beside = tr("Copy")
	await _bar_shot(bar, "Commit", "menu-bar-commit")

	# Italian: Edit → Undo follows the language.
	TranslationServer.set_locale("it")
	await get_tree().process_frame
	await _bar_shot(bar, "Edit", "edit-undo-italian")
	TranslationServer.set_locale("en")

	# Light theme: the commit menu.
	Actions.run_action(&"view.theme_light")
	await get_tree().process_frame
	_anchor = commits.get_global_rect().position + Vector2(260, commits.row_height() * 0.5)
	_beside = tr("Copy")
	view._on_commit_menu(at)
	await _shot("commit-menu-light", view.context_menu())
	view.close_menu()

	Actions.run_action(&"edit.undo")
	await _wait(func() -> bool: return session.change_index(tracked) >= 0)
	while _main.tab_count() > 0:
		_main.close_tab(0)
	_git(repo, ["remote", "set-url", "origin", origin])
	_git(repo, ["branch", "-D", "local-only"])
	DirAccess.remove_absolute(repo.path_join("notes.log"))
	get_tree().quit(0)


## Opens menu bar menu `title` and shoots it.
func _bar_shot(bar: AppMenuBar, title: String, file_name: String) -> void:
	var index: int = -1
	for i: int in AppMenuBar.MENUS.size():
		if String(AppMenuBar.MENUS[i][0]) == title:
			index = i
	var popup: ActionMenu = bar.menu(title)
	bar.labels(title)
	_anchor = Vector2(8 + 60 * index, bar.size.y)
	popup.popup(Rect2i(Vector2i(bar.get_screen_position()) + Vector2i(_anchor), Vector2i.ZERO))
	await _shot(file_name, popup)
	popup.hide()


static func write_untracked(path: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("log\n")
	file.close()


static func _git(repo: String, args: PackedStringArray) -> String:
	var output: Array = []
	OS.execute("git", PackedStringArray(["-C", repo]) + args, output, true)
	return String(output[0]).strip_edges() if not output.is_empty() else ""
