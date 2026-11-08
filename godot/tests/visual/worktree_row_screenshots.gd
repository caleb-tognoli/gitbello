extends Node
## Saves numbered screenshots of the worktree strip for visual review (not
## part of the smoke run): the strip in both themes, hovered chips with their
## tooltip cards, the hovered worktree icon and the worktree list: open,
## filtered, matching nothing, a hovered footer action and in the light theme
## (Prune shows in its footer when one of the worktrees' folders is missing).
## Usage: godot --path godot res://tests/visual/worktree_row_screenshots.tscn --
##        --repo=<worktree of a throwaway repo with several worktrees> --out=<dir>
## Run with GITBELLO_CONFIG pointing at a scratch config file. Read-only.

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000


func _ready() -> void:
	var repo: String = ""
	var out: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	if repo.is_empty() or out.is_empty():
		printerr("worktree_row_screenshots: pass -- --repo=<path> --out=<dir>")
		get_tree().quit(2)
		return
	get_tree().root.gui_embed_subwindows = true
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	get_window().size = Vector2i(1280, 720)
	var page: RepoTab = main.open_repo(repo)
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		var known: bool = page.worktrees().size() > 1
		for wt: Dictionary in page.worktrees():
			if not bool(wt["prunable"]) and int(wt["changed"]) < 0:
				known = false
		if known:
			break
		await get_tree().process_frame
	var strip: WorktreeStrip = page.strip()
	Actions.run_action(&"view.theme_dark")
	await _shot(out, "01-strip-dark")
	var step: int = 2
	for chip: WorktreeChip in strip.chips():
		if chip.selected or chip.texts()["marker"] != "" or chip == strip.chips()[strip.chips().size() - 1]:
			await _hover(chip)
			await _shot(out, "%02d-hover-%s" % [step, String(chip.texts()["name"]).left(20)])
			step += 1
	await _hover(strip.list_button())
	await _shot(out, "%02d-hover-worktree-icon" % step)
	step += 1
	_move_mouse(Vector2(640, 600))
	var list: WorktreeListPopover = strip.all_list()
	_open_list(strip)
	await _shot(out, "%02d-worktree-list" % step)
	step += 1
	# Part of the last branch's name (folder names share the repository's).
	var query: String = String(list.rows()[list.rows().size() - 1]["branch"]).get_file().left(4)
	list.set_filter(query)
	await _shot(out, "%02d-worktree-list-filtered-%s" % [step, query])
	step += 1
	list.set_filter("no such worktree")
	await _shot(out, "%02d-worktree-list-no-match" % step)
	step += 1
	list.set_filter("")
	await _settle()
	# The list is an embedded window: its controls are placed in its own viewport.
	_move_mouse(Vector2(list.position) + list.footer_button(&"worktree.cleanup").get_global_rect().get_center())
	var until: int = Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
	await _shot(out, "%02d-worktree-list-hover-cleanup" % step)
	step += 1
	list.hide()
	Actions.run_action(&"view.theme_light")
	await _shot(out, "%02d-strip-light" % step)
	step += 1
	_open_list(strip)
	await _shot(out, "%02d-worktree-list-light" % step)
	list.hide()
	Actions.run_action(&"view.theme_dark")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


## Opens the worktree list under the icon (embedded here, so in viewport
## coordinates).
func _open_list(strip: WorktreeStrip) -> void:
	strip.list_button().pressed.emit()
	var under: Rect2 = strip.list_button().get_global_rect()
	strip.all_list().position = Vector2i(under.position + Vector2(0.0, under.size.y))


func _hover(control: Control) -> void:
	_move_mouse(Vector2(640, 600))
	await _settle()
	_move_mouse(control.get_global_rect().get_center())
	var until: int = Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _move_mouse(at: Vector2) -> void:
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_viewport().push_input(motion)


func _settle() -> void:
	for i: int in 30:
		await get_tree().process_frame


func _shot(dir: String, file_name: String) -> void:
	await _settle()
	var path: String = dir.path_join(file_name + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path)
