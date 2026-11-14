extends Node
## Captures the loading indicators (see `LoadingIndicator`) in each state:
## Changes (the file list and the diff) and History (the commit list and the
## commit's files), each while nothing is shown yet (the spinner and its
## caption) and while shown content loads again (the line along the top), in
## the dark and light themes. The indicators are forced on; the loads
## themselves are real and fast.
##
## Read-only: pass --repo=<repository with uncommitted changes and some
## history, e.g. CLI fixture repo-1> --out=<directory>, with GITBELLO_CONFIG
## set to a scratch config, and launch windowed.

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
		printerr("loading_screenshots: pass --repo=<repository> --out=<directory>")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	get_window().size = Vector2i(1400, 820)
	var main: Main = MAIN.instantiate() as Main
	add_child(main)
	await get_tree().process_frame
	var page: RepoTab = main.open_repo(repo)
	var session: RepoSession = page.session
	if not await _wait(func() -> bool: return session.is_ready() and session.has_status() \
			and session.change_count() > 0):
		return
	var changes: ChangesView = page.changes()
	changes.list().select_only(0)
	if not await _wait(func() -> bool: return String(session.diff_info().get("state", "")) == "ready"):
		return
	page.show_view(WorktreeView.View.HISTORY)
	var history: HistoryView = page.history()
	if not await _wait(func() -> bool: return session.graph_row_count() > 1 \
			and not history.loading_indicator().is_loading()):
		return
	# Let the opening's refreshes settle: the views would hide forced indicators.
	if not await _wait(func() -> bool: return not session.status_refreshing() and not session.graph_reloading()):
		return
	await get_tree().create_timer(1.5).timeout

	var states: Array[Array] = [
		["changes", true, WorktreeView.View.CHANGES],
		["changes", false, WorktreeView.View.CHANGES],
		["history", true, WorktreeView.View.HISTORY],
		["history", false, WorktreeView.View.HISTORY],
	]
	var step: int = 1
	for mode: String in ["dark", "light"]:
		Actions.run_action(StringName("view.theme_" + mode))
		for state: Array in states:
			var view: String = state[0]
			var blocking: bool = state[1]
			page.show_view(state[2])
			var indicators: Array[LoadingIndicator] = []
			var captions: PackedStringArray = PackedStringArray()
			if view == "changes":
				indicators = [changes.loading_indicator(), changes.diff_panel().loading_indicator()]
				captions = [tr("Reading changes…"), tr("Loading diff…")]
			else:
				indicators = [history.loading_indicator(), history.details().loading_indicator()]
				captions = [tr("Loading history…"), tr("Loading commit…")]
			if not blocking:
				captions = [tr("Updating…"), tr("Updating…")]
			for i: int in indicators.size():
				indicators[i].show_loading(blocking, captions[i])
			await _frames(4)
			# Past the show delay.
			await get_tree().create_timer(LoadingIndicator.SHOW_DELAY + 0.1).timeout
			for i: int in indicators.size():
				# A late refresh may have hidden it: show it again.
				if not indicators[i].is_loading():
					indicators[i].show_loading(blocking, captions[i])
					await get_tree().create_timer(LoadingIndicator.SHOW_DELAY + 0.1).timeout
			await _shot(out, "%02d-%s-%s-%s" % [step, view, "empty" if blocking else "reloading", mode])
			step += 1
			for indicator: LoadingIndicator in indicators:
				indicator.hide_loading()
	Actions.run_action(&"view.theme_dark")
	while main.tab_count() > 0:
		main.close_tab(0)
	get_tree().quit(0)


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + WAIT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() >= deadline:
			printerr("loading_screenshots: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


func _frames(count: int) -> void:
	for frame: int in count:
		await get_tree().process_frame


func _shot(out: String, file_name: String) -> void:
	await _frames(6)
	var path: String = out.path_join(file_name + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("SHOT ", path)
