extends Node
## The cards of diffs without changed lines and of conflicts without blocks,
## in numbered shots: History's rename without edits (Show file, the whole
## file, back to the card), its mode change, then Changes' modify/delete
## conflict (Show changes, the bar over the changed side, Hide changes) and
## an "only one side has it" conflict, and the bar in the light theme. Pass
## --repo=<repo built by tests/visual/cards_prep.sh> --out=<directory> and
## set GITBELLO_CONFIG to a scratch config (read-only on the repository).

const MAIN: PackedScene = preload("res://app/main/main.tscn")
const WAIT_MS: int = 30_000

var _out: String = ""
var _step: int = 1


func _ready() -> void:
	var repo: String = ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--repo="):
			repo = arg.trim_prefix("--repo=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	if repo.is_empty() or _out.is_empty():
		printerr("card_screenshots: pass --repo=<repo> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_window().size = Vector2i(1400, 820)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	Actions.run_action(&"view.theme_dark")
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.change_count() >= 2):
		return
	if not await _history(page, session):
		return
	if not await _conflicts(page, session):
		return
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


## The rename without edits: its card, Show file, the toggle off; then the
## mode change's card.
func _history(page: RepoTab, session: RepoSession) -> bool:
	page.show_view(WorktreeView.View.HISTORY)
	var commits: CommitList = page.history().commit_list()
	if not await _wait(func() -> bool: return commits.row_count() >= 4):
		return false
	var panel: DiffPanel = page.history().details().diff_panel()
	var files: CommitFileList = page.history().details().file_list()
	var diff_ready: Callable = func(path: String) -> bool:
		var info: Dictionary = session.commit_diff_info()
		return String(info.get("path", "")) == path and String(info.get("state", "")) == "ready"
	for entry: Array in [["Rename the guide", "docs/manual.md"], ["Make run.sh executable", "run.sh"]]:
		var row: int = _commit_row(commits, String(entry[0]))
		if row < 0:
			return _fail("no commit %s" % entry[0])
		commits.select_only(row)
		if not await _wait(func() -> bool: return files.row_count() >= 1 and diff_ready.call(String(entry[1]))):
			return false
		var stem: String = String(entry[1]).get_file().get_basename()
		if not await _wait(func() -> bool: return panel.card_buttons().has("Show file")):
			return false
		print("CARD %s: %s" % [entry[1], panel.card_buttons()])
		await _shot("history-%s-card" % stem)
		panel.card_action.emit("show_file")
		if not await _wait(func() -> bool:
				var info: Dictionary = session.commit_diff_info()
				return bool(info.get("whole", false)) and int(info.get("line_count", 0)) > 0 and panel.card_buttons().is_empty()):
			return false
		await _shot("history-%s-file" % stem)
		if stem == "manual":
			panel.whole_file_button().button_pressed = false
			if not await _wait(func() -> bool: return panel.card_buttons().has("Show file")):
				return false
			await _shot("history-%s-back-to-card" % stem)
	return true


## The modify/delete card, Show changes, Hide changes; the only-ours card
## and its file; the bar in the light theme.
func _conflicts(page: RepoTab, session: RepoSession) -> bool:
	page.show_view(WorktreeView.View.CHANGES)
	var changes: ChangesView = page.changes()
	var panel: DiffPanel = changes.diff_panel()
	for path: String in ["gone.txt", "ours.txt"]:
		var index: int = _row_of(changes.list(), path)
		if index < 0:
			return _fail("%s is not in Changes" % path)
		changes.list().select_only(index)
		if not await _wait(func() -> bool: return panel.card_buttons().has("Show changes")):
			return false
		var stem: String = path.get_basename()
		print("CARD %s: %s" % [path, panel.card_buttons()])
		await _shot("changes-%s-card" % stem)
		panel.card_action.emit("show_changes")
		if not await _wait(func() -> bool:
				return not panel.side_bar_text().is_empty() and String(session.diff_info().get("state", "")) == "ready"):
			return false
		print("BAR %s: %s" % [path, panel.side_bar_text()])
		await _shot("changes-%s-changes" % stem)
		if stem == "gone":
			Actions.run_action(&"view.theme_light")
			await _shot("changes-%s-changes-light" % stem)
			Actions.run_action(&"view.theme_dark")
			panel.conflict_changes_requested.emit(false)
			if not await _wait(func() -> bool: return panel.card_buttons().has("Show changes")):
				return false
			await _shot("changes-%s-hidden" % stem)
	return true


func _commit_row(list: CommitList, subject: String) -> int:
	for row: int in list.row_count():
		if String(list.call(&"row_data", row).get("subject", "")) == subject:
			return row
	return -1


func _row_of(list: VirtualList, path: String) -> int:
	for row: int in list.row_count():
		if String(list.call(&"path_at", row)) == path:
			return row
	return -1


func _fail(message: String) -> bool:
	printerr("card_screenshots: " + message)
	get_tree().quit(1)
	return false


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			return _fail("timed out")
		await get_tree().process_frame
	return true


func _shot(file_name: String) -> void:
	for frame: int in 30:
		await get_tree().process_frame
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = _out.path_join("%02d-%s.png" % [_step, file_name])
	_step += 1
	image.save_png(path)
	print("SHOT ", path)
