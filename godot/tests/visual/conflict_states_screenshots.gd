extends Node
## Conflict states besides text blocks, one numbered screenshot per step:
## the cards of files deleted on one side and of a binary file, the Abort
## confirmation, the banner of a cherry-pick and of a rebase stopped at a
## conflict. Pass --repo=<throwaway repo> --rebase-repo=<throwaway repo>
## --out=<directory>, set GITBELLO_CONFIG to a scratch config and launch
## windowed. In --repo, merging `topic` into `main` conflicts on setup.txt
## (topic deleted it), legacy.cfg (main deleted it) and logo.png (binary), and
## `hotfix` conflicts with main on login.rs. --rebase-repo is on `series`,
## rebasing onto main, stopped at a conflict. It merges there: never point it
## at a real repository.

const MAIN: PackedScene = preload("res://app/main/main.tscn")

var _out: String = ""
var _step: int = 0


func _ready() -> void:
	var repo: String = ""
	var rebase_repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--rebase-repo="):
			rebase_repo = arg.trim_prefix("--rebase-repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or rebase_repo.is_empty() or _out.is_empty():
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
	var ops: RepoOps = page.ops()
	page.show_view(WorktreeView.View.CHANGES)

	# Merge topic: three conflicts without text blocks.
	session.merge("topic", "default", "", false)
	await _wait(func() -> bool: return int(session.operation_info().get("conflicts", 0)) == 3)
	for path: String in ["setup.txt", "legacy.cfg", "logo.png"]:
		session.select_change(path, false)
		await _wait(func() -> bool: return String((session.diff_info().get("conflict", {}) as Dictionary).get("kind", "")) != "")
		await _shot("card-" + path.get_basename())

	# Abort asks first.
	ops.abort_operation()
	await _wait(func() -> bool: return ops.confirm_dialog().visible)
	await _shot("abort-confirmation")
	ops.confirm_dialog().get_ok_button().pressed.emit()
	await _wait(func() -> bool: return session.operation().is_empty())

	# A cherry-pick that conflicts.
	var hotfix: String = ""
	for ref: Dictionary in session.branch_refs():
		if String(ref["short_name"]) == "hotfix":
			hotfix = String(ref["commit"])
	session.cherry_pick(hotfix)
	await _wait(func() -> bool: return session.operation() == "cherry_pick" and int(session.operation_info().get("conflicts", 0)) > 0)
	await _shot("cherry-pick-banner")
	session.abort_operation()
	await _wait(func() -> bool: return session.operation().is_empty())

	# A rebase stopped at a conflict, in another tab.
	var rebase_page: RepoTab = main.open_repo(rebase_repo)
	var rebase_session: RepoSession = rebase_page.session
	await _wait(func() -> bool: return rebase_session.is_ready() and rebase_session.operation() == "rebase")
	rebase_page.show_view(WorktreeView.View.CHANGES)
	await _shot("rebase-banner")
	rebase_page.show_view(WorktreeView.View.HISTORY)
	await _shot("rebase-banner-history")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit()


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
