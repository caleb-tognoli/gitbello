extends SmokeTest
## M7.8 P3: Open hands a file to its default app. Changes opens the working
## copy (a deleted file, its last version), History the commit's version,
## an image side its own version, all from the file lists', the diff's and
## the image viewer's context menus. Open in editor is gone. The default app
## is replaced by a recorder. Uses the `images` fixtures (read-only here).
## Skipped without `--fixtures`.

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _opened: PackedStringArray = PackedStringArray()


func run() -> void:
	var fixtures: String = fixtures_dir()
	if fixtures.is_empty():
		print("open_file_smoke: no --fixtures, skipped")
		return
	var opener: Callable = RepoOps.opener
	RepoOps.opener = func(path: String) -> Error:
		_opened.append(path)
		return OK
	expect(Actions.get_action(&"repo.open_in_editor") == null, "Open in editor is gone")

	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	expect(Actions.get_action(&"repo.open_in_editor") == null and Actions.get_action(&"worktree.open_in_editor") == null,
			"no Open in editor action")
	var repo: String = fixtures.path_join("images")
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	expect(await wait_until(func() -> bool: return session.change_count() == 6), "six changed images")

	# The working copy, from the list's menu.
	expect(await _select(changes, session, "logo.png"), "logo.png's diff loads")
	changes.list().context_menu_requested.emit(changes.list().cursor, Vector2(10, 10))
	expect("Open" in changes.menu_labels(), "the list's menu has Open: %s" % changes.menu_labels())
	expect(await _open(&"diff.open_file"), "Open opens a file")
	expect(_same(_last(), repo.path_join("logo.png")), "Changes opens the working copy: %s" % _last())
	_close_popups(changes)

	# The diff's menu has Open too.
	changes.diff_panel().view().context_menu_requested.emit(0, Vector2(10, 10))
	expect("Open" in changes.menu_labels(), "the diff's menu has Open: %s" % changes.menu_labels())
	_close_popups(changes)

	# An image side opens its own version: the old logo from HEAD.
	var images: ImageDiffView = changes.diff_panel().image_view()
	expect(await wait_until(func() -> bool:
		return images.texture(ImageDiffView.OLD) != null and images.texture(ImageDiffView.NEW) != null), "both logos decode")
	var right: InputEventMouseButton = InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	right.position = images.side_rect(ImageDiffView.OLD).get_center()
	images._gui_input(right)
	var image_menu: PopupMenu = changes.diff_panel().image_menu()
	expect(image_menu.visible and image_menu.item_count == 1 and image_menu.get_item_text(0) == "Open",
			"a right-click on an image side offers Open")
	var before: int = _opened.size()
	image_menu.id_pressed.emit(0)
	expect(await wait_until(func() -> bool: return _opened.size() > before), "the old side opens")
	expect(_last().get_file() == "logo.png" and not _same(_last(), repo.path_join("logo.png"))
			and _last().replace("\\", "/").contains("/cache/versions/"), "as a version in the cache: %s" % _last())
	expect_eq(FileAccess.get_file_as_bytes(_last()).size(), int((session.diff_info()["image"]["old"] as Dictionary)["size"]),
			"with the old side's bytes")
	image_menu.hide()

	# A deleted file opens its last version.
	expect(await _select(changes, session, "old.png"), "old.png's diff loads")
	expect(await _open(&"diff.open_file"), "Open opens the deleted file")
	expect(_last().get_file() == "old.png" and FileAccess.file_exists(_last()) and not _same(_last(), repo.path_join("old.png")),
			"from HEAD: %s" % _last())

	# History: the commit's version, from the file list's menu.
	page.show_view(WorktreeView.View.HISTORY)
	var details: CommitDetails = page.history().details()
	var commits: CommitList = page.history().commit_list()
	expect(await wait_until(func() -> bool: return commits.row_count() >= 2), "the commits load")
	commits.select_only(0)
	expect(await wait_until(func() -> bool: return details.files().row_count() > 0), "the commit's files load")
	details.files().select_only(0)
	expect(await wait_until(func() -> bool:
		return String(session.commit_diff_info().get("path", "")) == details.files().path_at(0)), "its diff loads")
	details.files().context_menu_requested.emit(0, Vector2(10, 10))
	expect(details.file_menu().visible and details.file_menu().get_item_text(0) == "Open"
			and not details.file_menu().is_item_disabled(0), "the commit's file list offers Open")
	details.file_menu().hide()
	expect(await _open(&"diff.open_file"), "Open opens the commit's file")
	expect(_last().get_file() == details.files().path_at(0).get_file() and _last().replace("\\", "/").contains("/cache/versions/"),
			"as the commit's version: %s" % _last())
	_open_diff_menu(details)
	expect(_menu_has(details.diff_menu(), "Open"), "the commit diff's menu has Open")
	details.diff_menu().hide()

	RepoOps.opener = opener
	while main.tab_count() > 0:
		main.close_tab(0)
	main.queue_free()
	await get_tree().process_frame


## Runs `id` and waits for a file to open.
func _open(id: StringName) -> bool:
	var before: int = _opened.size()
	if not Actions.run_action(id):
		return false
	return await wait_until(func() -> bool: return _opened.size() > before)


func _last() -> String:
	return _opened[_opened.size() - 1] if not _opened.is_empty() else ""


func _same(a: String, b: String) -> bool:
	return a.replace("\\", "/").to_lower() == b.replace("\\", "/").to_lower()


func _close_popups(changes: ChangesView) -> void:
	for child: Node in changes.get_children():
		if child is PopupMenu:
			(child as PopupMenu).hide()


func _open_diff_menu(details: CommitDetails) -> void:
	details.diff_panel().view().context_menu_requested.emit(0, Vector2(10, 10))


func _menu_has(menu: PopupMenu, label: String) -> bool:
	for i: int in menu.item_count:
		if menu.get_item_text(i) == label:
			return true
	return false


## Highlights `path` in Changes and waits for its diff.
func _select(changes: ChangesView, session: RepoSession, path: String) -> bool:
	var index: int = -1
	for row: int in changes.list().row_count():
		if changes.list().path_at(row) == path:
			index = row
	if index < 0:
		return false
	changes.list().select_only(index)
	return await wait_until(func() -> bool:
		var info: Dictionary = session.diff_info()
		return String(info.get("path", "")) == path and String(info.get("state", "")) == "ready")
