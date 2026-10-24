extends Node
## Windowed scroll benchmark for the commit list, run by `cargo xtask bench-graph --ui`.
## Loads the repository given as `-- --repo=<path>`, scrolls row by row and then
## page by page, and prints `BENCH <key> <value>` lines before quitting.

const ROW_FRAMES: int = 300
const PAGE_FRAMES: int = 300
const WARMUP_FRAMES: int = 30
const LOAD_TIMEOUT_MS: int = 60_000

var _loaded: bool = false


func _ready() -> void:
	var repo: String = Main.repo_from_args(OS.get_cmdline_user_args())
	if repo.is_empty():
		printerr("scroll_bench: pass -- --repo=<path>")
		get_tree().quit(2)
		return
	var view: HistoryView = (load("res://app/history/history_view.tscn") as PackedScene).instantiate() as HistoryView
	add_child(view)
	var session: RepoSession = Core.open_session(repo)
	add_child(session)
	view.repo_loaded.connect(func(_rows: int, _error: String) -> void: _loaded = true)
	view.session = session
	var deadline: int = Time.get_ticks_msec() + LOAD_TIMEOUT_MS
	while not _loaded and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var list: CommitList = view.commit_list()
	for i: int in WARMUP_FRAMES:
		await get_tree().process_frame
	var screenshot: String = _arg_value("--screenshot=")
	if not screenshot.is_empty():
		get_viewport().get_texture().get_image().save_png(screenshot)
		print("BENCH screenshot %s" % screenshot)

	var frame_ms: PackedFloat64Array = PackedFloat64Array()
	var draw_us: PackedFloat64Array = PackedFloat64Array()
	var fetch_us: PackedFloat64Array = PackedFloat64Array()
	var page: float = list.size.y
	var last: int = Time.get_ticks_usec()
	for i: int in ROW_FRAMES + PAGE_FRAMES:
		var step: float = list.row_height() if i < ROW_FRAMES else page
		list.set_scroll_offset(list.scroll_offset() + step)
		await get_tree().process_frame
		var now: int = Time.get_ticks_usec()
		frame_ms.append((now - last) / 1000.0)
		draw_us.append(float(list.last_draw_usec))
		if list.last_fetch_usec > 0:
			fetch_us.append(float(list.last_fetch_usec))
			list.last_fetch_usec = 0
		last = now

	var refresh: float = DisplayServer.screen_get_refresh_rate()
	if refresh <= 0.0:
		refresh = 60.0
	var budget_ms: float = 1000.0 / refresh
	var dropped: int = 0
	for ms: float in frame_ms:
		if ms > budget_ms * 1.5:
			dropped += 1
	print("BENCH rows %d" % list.row_count())
	print("BENCH refresh_hz %.0f" % refresh)
	print("BENCH frames %d" % frame_ms.size())
	print("BENCH dropped_frames %d" % dropped)
	for phase: Array in [["row", 0, ROW_FRAMES], ["page", ROW_FRAMES, ROW_FRAMES + PAGE_FRAMES]]:
		var frames: PackedFloat64Array = frame_ms.slice(phase[1], phase[2])
		var draws: PackedFloat64Array = draw_us.slice(phase[1], phase[2])
		for stat: Array in [["p50", 0.5], ["p99", 0.99], ["max", 1.0]]:
			print("BENCH %s_frame_ms_%s %.2f" % [phase[0], stat[0], _percentile(frames, stat[1])])
			print("BENCH %s_draw_us_%s %.0f" % [phase[0], stat[0], _percentile(draws, stat[1])])
	print("BENCH fetches %d" % fetch_us.size())
	print("BENCH fetch_us_p50 %.0f" % _percentile(fetch_us, 0.5))
	print("BENCH fetch_us_max %.0f" % _percentile(fetch_us, 1.0))
	print("BENCH static_memory_mb %.1f" % (OS.get_static_memory_usage() / 1048576.0))
	get_tree().quit(0)


static func _arg_value(prefix: String) -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix)
	return ""


static func _percentile(values: PackedFloat64Array, fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: PackedFloat64Array = values.duplicate()
	sorted.sort()
	return sorted[clampi(int(ceil(fraction * sorted.size())) - 1, 0, sorted.size() - 1)]
