extends Node
## The branch list (Ctrl+B) in the real app, one numbered screenshot per
## step, each popover shot with a 2x crop of its top rows: Recent, Local and
## Remote; the keyboard crossing a header; a filter matching every section;
## no match; merge mode (the upstream first in Remote); a click on a Local
## branch and the list reopened with it first; the light theme; Compare's
## picker with muted prefixes; and a short list (`--small`) without headers.
## Checks out a branch in `--repo`: a throwaway CLI fixture repo-1 prepared by
## `branch_list_prep.sh`, `--small` another untouched fixture repo, with
## `GITBELLO_CONFIG` set to a scratch file.
## `-- --repo=<prepared repo-1> --small=<repo-2> --out=<dir>`

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _main: Main
var _page: RepoTab
var _out: String = ""
var _step: int = 0
@onready var root: Window = get_tree().root


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var repo: String = ""
	var small: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--small="):
			small = arg.trim_prefix("--small=")
	if _out.is_empty() or repo.is_empty() or small.is_empty():
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	# Every frame is drawn, so each shot's frame_post_draw comes.
	OS.low_processor_usage_mode = false
	_main = MAIN.instantiate() as Main
	root.add_child(_main)
	root.content_scale_factor = 1.0
	root.size = Vector2i(1280, 800)
	Input.warp_mouse(Vector2(4, 4))
	Actions.run_action(&"view.theme_dark")
	_page = _main.open_repo(repo)
	await _until(func() -> bool: return _session().is_ready() and not _session().branch_refs().is_empty())
	await _frames(30)
	var view: WorktreeView = _page.active_view()
	var popover: BranchPopover = view.branch_popover()

	view.open_branches()
	await _shot_popover(popover, "list")
	# The last Recent row, then Down: the header is skipped.
	var tree: Tree = popover._tree
	tree.grab_focus()
	for i: int in 3:
		_key(popover, KEY_DOWN)
	await _shot_popover(popover, "last-recent-selected")
	_key(popover, KEY_DOWN)
	await _shot_popover(popover, "down-crosses-header")
	popover.set_filter("re")
	await _shot_popover(popover, "filter-re")
	popover.set_filter("no-such-branch")
	await _shot_popover(popover, "no-match")
	popover.hide()
	await _frames(4)

	view.open_merge_picker()
	await _shot_popover(popover, "merge-mode")
	popover.hide()
	await _frames(4)

	view.open_branches()
	await _frames(6)
	var row: TreeItem = _row(popover, "old-experiment")
	if row != null:
		await _click(popover, row)
	await _until(func() -> bool: return _session().current_branch() == "old-experiment", 20.0)
	await _until(func() -> bool: return _session().branch_refs().any(func(ref: Dictionary) -> bool:
		return String(ref["short_name"]) == "old-experiment" and bool(ref["is_head"])), 20.0)
	await _frames(20)
	await _shot("after-checkout")
	view.open_branches()
	await _shot_popover(popover, "reopened")
	popover.hide()
	await _frames(4)

	Actions.run_action(&"view.theme_light")
	await _frames(10)
	view.open_branches()
	await _shot_popover(popover, "light")
	popover.hide()
	Actions.run_action(&"view.theme_dark")
	await _frames(10)

	view.open_compare("main", "origin/main", false)
	await _until(func() -> bool: return view.compare().has_comparison(), 20.0)
	await _frames(20)
	view.compare().pick_side("left")
	await _shot_popover(view.compare().picker(), "compare-picker")
	view.compare().picker().hide()
	await _frames(4)

	var small_page: RepoTab = _main.open_repo(small)
	await _until(func() -> bool: return small_page.session.is_ready() and not small_page.session.branch_refs().is_empty())
	await _frames(30)
	small_page.active_view().open_branches()
	await _shot_popover(small_page.active_view().branch_popover(), "short-list")
	small_page.active_view().branch_popover().hide()
	get_tree().quit(0)


func _session() -> RepoSession:
	return _page.session


## A key press and release in `window`, to its focused control.
func _key(window: Window, keycode: Key) -> void:
	for pressed: bool in [true, false]:
		var key: InputEventKey = InputEventKey.new()
		key.keycode = keycode
		key.pressed = pressed
		window.push_input(key)


func _row(popover: BranchPopover, label: String) -> TreeItem:
	for item: TreeItem in popover._tree.get_root().get_children():
		if item.get_text(0) == label:
			return item
	return null


## A left click (press and release) in the middle of `item`'s row.
func _click(popover: BranchPopover, item: TreeItem) -> void:
	var tree: Tree = popover._tree
	tree.scroll_to_item(item)
	await _frames(2)
	var at: Vector2 = tree.get_item_area_rect(item).get_center()
	for pressed: bool in [true, false]:
		var event: InputEventMouseButton = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = at
		event.global_position = at
		tree.gui_input.emit(event)
		if pressed:
			# A press selects the row in Tree's own handling.
			item.select(0)
		await _frames(2)


func _shot(step: String) -> void:
	await _frames(12)
	await RenderingServer.frame_post_draw
	_step += 1
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	root.get_texture().get_image().save_png(path)
	printerr("SHOT ", path)


## The popover, then a 2x crop of its top rows. An embedded popup is drawn
## in the main window, so it is cut from there; a native one has its own
## texture.
func _shot_popover(window: Window, step: String) -> void:
	await _frames(12)
	await RenderingServer.frame_post_draw
	_step += 1
	var image: Image = null
	if root.gui_embed_subwindows:
		image = root.get_texture().get_image().get_region(Rect2i(window.position, window.size).intersection(
				Rect2i(Vector2i.ZERO, root.size)))
	else:
		image = window.get_texture().get_image()
	var path: String = _out.path_join("%02d-%s.png" % [_step, step])
	image.save_png(path)
	var crop: Image = image.get_region(Rect2i(0, 0, image.get_width(), mini(image.get_height(), 200)))
	crop.resize(crop.get_width() * 2, crop.get_height() * 2, Image.INTERPOLATE_NEAREST)
	crop.save_png(_out.path_join("%02d-%s-2x.png" % [_step, step]))
	var rows: PackedStringArray = (window as BranchPopover).row_labels() if window is BranchPopover else PackedStringArray()
	printerr("SHOT ", path, " · rows ", rows)


func _until(condition: Callable, seconds: float = 30.0) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while not bool(condition.call()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _frames(count: int) -> void:
	for frame: int in count:
		await get_tree().process_frame
