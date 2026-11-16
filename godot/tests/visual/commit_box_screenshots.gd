extends Node
## The commit summary's character count, in numbered shots per theme, each
## with a 2x crop of the commit box: a summary under 50 characters (no count),
## one of 59 (muted count), one of 88 (warning count) and the same unfocused.
## Pass --repo=<CLI fixture repo-1> --out=<directory> and set GITBELLO_CONFIG
## to a scratch config before launching windowed (read-only on the repository).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000
const SUMMARIES: Array[Array] = [
	["under-50", "Fix the stash order after a rename"],
	["59-muted", "Keep the stash order when a branch is renamed in a worktree"],
	["88-warning", "Keep the stash order when a branch is renamed in another worktree of the same repository"],
]

var _out: String = ""
var _step: int = 1


func _ready() -> void:
	DisplayServer.window_set_position(Vector2i(-10000, -10000))
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or _out.is_empty():
		printerr("commit_box_screenshots: pass --repo=<fixture> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() >= 1):
		return
	page.show_view(WorktreeView.View.CHANGES)
	var box: CommitBox = page.changes().commit_box()
	for theme: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + theme))
		for entry: Array in SUMMARIES:
			box.set_message(String(entry[1]), "")
			box.focus_summary()
			await _shot("%s-%s" % [entry[0], theme], box)
		get_viewport().gui_release_focus()
		await _shot("88-warning-unfocused-" + theme, box)
	box.set_message("", "")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("commit_box_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


## The window, then a 2x crop of the commit box.
func _shot(file_name: String, box: CommitBox) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	var stem: String = "%02d-%s" % [_step, file_name]
	_step += 1
	image.save_png(_out.path_join(stem + ".png"))
	var scale: Vector2 = get_viewport().get_screen_transform().get_scale()
	var area: Rect2 = box.get_global_rect().grow(6)
	var rect: Rect2i = Rect2i(Rect2(area.position * scale, area.size * scale))
	rect = rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var crop: Image = image.get_region(rect)
	crop.resize(crop.get_width() * 2, crop.get_height() * 2, Image.INTERPOLATE_NEAREST)
	crop.save_png(_out.path_join(stem + "-box.png"))
	print("SHOT ", _out.path_join(stem + ".png"))
