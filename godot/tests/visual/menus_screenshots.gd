extends Node
## Menus on `ActionMenu`, in numbered shots with the menus drawn in:
## each menu bar menu, History's commit menu on HEAD and on an older commit,
## a branch's (with Compare ▸ beside it), the current branch's and a tag's
## menus, a graph label's menu (titled), a worktree chip's (with Open in ▸, then Branch ▸), the
## Changes list's menu on one file and on two (titled), the Sync menu,
## Home's row and Add menus, then the commit menu in the light theme. Every
## menu's items are printed, submenus indented, greyed ones with why.
## Nothing runs. Pass --repo=<CLI fixture repo-1> --out=<directory> and set
## GITBELLO_CONFIG to a scratch config before launching windowed (read-only
## on the repository).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 60_000

var _out: String = ""
var _step: int = 1
var _main: Main = null
## Where the next menu was asked to open, in window coordinates: popups of an
## off-screen window are moved onto the screen, so they are drawn in here.
var _anchor: Vector2 = Vector2.ZERO
## A submenu drawn to the right of the next shot's menu (its title), or "".
var _beside: String = ""


func _ready() -> void:
	DisplayServer.window_set_position(Vector2i(-10000, -10000))
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or _out.is_empty():
		printerr("menus_screenshots: pass --repo=<repo> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_main = MAIN.instantiate() as Main
	add_child(_main)
	await get_tree().process_frame
	Actions.run_action(&"view.theme_dark")

	var page: RepoTab = _main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() > 0):
		return
	page.show_view(WorktreeView.View.HISTORY)
	var commits: CommitList = page.history().commit_list()
	if not await _wait(func() -> bool: return commits.row_count() >= 3):
		return

	# The menu bar, menu by menu.
	var bar: AppMenuBar = _main.menu_bar()
	for i: int in bar.get_menu_count():
		var title: String = String(AppMenuBar.MENUS[i][0])
		var popup: ActionMenu = bar.menu(title)
		bar.labels(title)
		_anchor = Vector2(8 + 60 * i, bar.size.y)
		popup.popup(Rect2i(Vector2i(bar.get_screen_position()) + Vector2i(_anchor), Vector2i.ZERO))
		await _shot("menu-bar-" + title.to_lower(), popup)
		popup.hide()

	var view: WorktreeView = page.active_view()
	var at: Vector2 = commits.get_screen_position() + Vector2(260, commits.row_height() * 0.5)
	_anchor = commits.get_global_rect().position + Vector2(260, commits.row_height() * 0.5)
	# History: the commit menu on HEAD (Amend shows), then on an older commit.
	commits.select_only(_head_row(commits, session))
	view._on_commit_menu(at)
	await _shot("commit-menu-head", view.context_menu())
	view.close_menu()
	commits.select_only(commits.row_count() - 1)
	view._on_commit_menu(at)
	await _shot("commit-menu-older", view.context_menu())
	view.close_menu()

	# Refs: another branch, the current branch (Delete greyed) and a tag.
	var current: Dictionary = {}
	var other: Dictionary = {}
	for ref: Dictionary in session.branch_refs():
		if String(ref["name"]).begins_with("refs/heads/"):
			var entry: Dictionary = {"type": "branch", "name": String(ref["name"]), "short": String(ref["short_name"]),
				"commit": String(ref["commit"]), "is_head": bool(ref["is_head"]), "upstream": String(ref["upstream"]),
				"worktree": String(ref["worktree"])}
			if bool(ref["is_head"]):
				current = entry
			elif other.is_empty():
				other = entry
	for pair: Array in [["branch-menu", other], ["current-branch-menu", current]]:
		if (pair[1] as Dictionary).is_empty():
			print("menus_screenshots: no %s" % pair[0])
			continue
		_beside = tr("Compare") if pair[0] == "branch-menu" else ""
		view.show_ref_menu(pair[1], at)
		await _shot(String(pair[0]), view.context_menu())
		view.close_menu()
	var tags: Array = session.tags()
	if not tags.is_empty():
		var tag: Dictionary = tags[0]
		view.show_ref_menu({"type": "tag", "name": "refs/tags/" + String(tag["name"]), "short": String(tag["name"]),
			"commit": String(tag["commit"]), "is_head": false, "upstream": ""}, at)
		await _shot("tag-menu", view.context_menu())
		view.close_menu()
	# A graph label: the same menu, titled with the branch.
	if not other.is_empty():
		view._on_label_menu({"kind": "branch", "name": String(other["name"]), "short": String(other["short"])}, at,
			null)
		await _shot("graph-label-menu", view.context_menu())
		view.close_menu()
	# A worktree chip, with Open in ▸ beside it.
	var worktrees: Array[Dictionary] = page.worktrees()
	if not worktrees.is_empty():
		_beside = tr("Open in")
		page._on_chip_menu(worktrees[0], at)
		await _shot("worktree-menu", view.context_menu())
		view.close_menu()
		# Its Branch ▸: the menu of the branch checked out there.
		_beside = tr("Branch")
		page._on_chip_menu(worktrees[worktrees.size() - 1], at)
		await _shot("worktree-branch-menu", view.context_menu())
		view.close_menu()

	# Changes: the list's menu on the first file.
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	changes.list().select_only(0)
	await get_tree().process_frame
	var list: VirtualList = changes.list()
	_anchor = list.get_global_rect().position + Vector2(120, list.row_height() * 0.5)
	list.context_menu_requested.emit(0, Vector2(120, list.row_height() * 0.5))
	await _shot("changes-list-menu", changes.context_menu())
	changes.context_menu().hide()
	if list.row_count() > 1:
		list._select_range(0, 1, false)
		list.context_menu_requested.emit(0, Vector2(120, list.row_height() * 0.5))
		await _shot("changes-two-files-menu", changes.context_menu())
		changes.context_menu().hide()

	# The Sync ▾ menu.
	var sync_rect: Rect2 = view._sync_button.get_global_rect()
	_anchor = sync_rect.position + Vector2(0.0, sync_rect.size.y)
	view._open_sync_menu()
	await _shot("sync-menu", view._sync_menu)
	view._sync_menu.hide()

	# Home's Add and row menus.
	_main.open_home()
	await get_tree().process_frame
	var home: Home = _main.home()
	if await _wait(func() -> bool: return not home.listed().is_empty()):
		_anchor = home.add_button().get_global_rect().position + Vector2(0.0, home.add_button().size.y)
		home.open_add_menu()
		await _shot("home-add-menu", home.add_menu())
		home.add_menu().hide()
		var row: Control = home.row_for(home.listed()[0])
		var click: InputEventMouseButton = InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_RIGHT
		click.pressed = true
		click.position = Vector2(200, 12)
		_anchor = row.get_global_rect().position + click.position
		row.gui_input.emit(click)
		await _shot("home-row-menu", home.row_menu())
		home.row_menu().hide()

	# Light theme: the older commit's menu.
	Actions.run_action(&"view.theme_light")
	_main.open_repo(repo)
	page.show_view(WorktreeView.View.HISTORY)
	await get_tree().process_frame
	commits.select_only(commits.row_count() - 1)
	_anchor = commits.get_global_rect().position + Vector2(260, commits.row_height() * 0.5)
	view._on_commit_menu(at)
	await _shot("commit-menu-light", view.context_menu())
	view.close_menu()

	while _main.tab_count() > 0:
		_main.close_tab(0)
	get_tree().quit(0)


func _head_row(commits: CommitList, session: RepoSession) -> int:
	var head: String = String(session.status().get("oid", ""))
	for row: int in commits.row_count():
		if commits.hash_at(row) == head:
			return row
	return 0


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("menus_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## The window, with `popup` (a separate window) drawn in where it shows, and
## the menu's items printed.
func _shot(file_name: String, popup: ActionMenu) -> void:
	for frame: int in 20:
		await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	if popup != null and popup.visible:
		var menu: Image = popup.get_texture().get_image()
		menu.convert(image.get_format())
		var where: Vector2i = Vector2i(_anchor)
		where.x = clampi(where.x, 0, maxi(0, image.get_width() - menu.get_width()))
		where.y = clampi(where.y, 0, maxi(0, image.get_height() - menu.get_height()))
		image.blit_rect(menu, Rect2i(Vector2i.ZERO, menu.get_size()), where)
		_print_items(file_name, popup, "")
		var child: ActionMenu = popup.submenu(_beside) if not _beside.is_empty() else null
		if child != null:
			child.popup(Rect2i(Vector2i(-10000, -10000), Vector2i.ZERO))
			for frame: int in 5:
				await get_tree().process_frame
			var sub_image: Image = child.get_texture().get_image()
			child.hide()
			sub_image.convert(image.get_format())
			var at_side: Vector2i = where + Vector2i(menu.get_width() - 4, 0)
			at_side.x = clampi(at_side.x, 0, maxi(0, image.get_width() - sub_image.get_width()))
			image.blit_rect(sub_image, Rect2i(Vector2i.ZERO, sub_image.get_size()), at_side)
		_beside = ""
	elif popup != null:
		printerr("menus_screenshots: %s: the menu did not open" % file_name)
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	_step += 1
	image.save_png(path)
	print("SHOT ", path)


func _print_items(file_name: String, popup: PopupMenu, indent: String) -> void:
	for i: int in popup.item_count:
		if popup.is_item_separator(i):
			print("%s %s──── %s" % [file_name, indent, popup.get_item_text(i)])
			continue
		var line: String = popup.get_item_text(i)
		if popup.is_item_disabled(i):
			line += "  (disabled: %s)" % popup.get_item_tooltip(i)
		print("%s %s%s" % [file_name, indent, line])
		var child: PopupMenu = popup.get_item_submenu_node(i)
		if child != null:
			_print_items(file_name, child, indent + "  ")
