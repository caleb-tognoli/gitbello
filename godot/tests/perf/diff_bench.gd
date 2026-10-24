extends Node
## Diff view benchmark (read-only): loads the unstaged diff of one file and
## times the slice fetches the view makes (unified and side by side, with
## syntax and word highlights), then scrolls a windowed DiffPanel page by
## page. Prints `BENCH <key> <value>` lines and quits.
## Usage: godot --path godot res://tests/perf/diff_bench.tscn --
##        --repo=<worktree root> --file=<path in the repo>

const WINDOW: int = 300
const SAMPLES: int = 20
const PAGE_FRAMES: int = 200
const LOAD_TIMEOUT_MS: int = 60_000
const PANEL: PackedScene = preload("res://ui/diff_view/diff_panel.tscn")


func _ready() -> void:
	var repo: String = _arg("--repo=")
	var file: String = _arg("--file=")
	if repo.is_empty() or file.is_empty():
		printerr("diff_bench: pass -- --repo=<path> --file=<path>")
		get_tree().quit(2)
		return
	var session: RepoSession = Core.open_session(repo)
	add_child(session)
	var deadline: int = Time.get_ticks_msec() + LOAD_TIMEOUT_MS
	while not session.is_ready() or session.change_count("unstaged") == 0:
		if Time.get_ticks_msec() > deadline:
			printerr("diff_bench: repository did not load: ready=%s unstaged=%d error=%s" % [session.is_ready(), session.change_count("unstaged"), session.open_error()])
			get_tree().quit(1)
			return
		await get_tree().process_frame
	var started: int = Time.get_ticks_usec()
	session.select_diff("unstaged", file, true)
	while String(session.diff_info().get("state", "")) != "ready":
		if Time.get_ticks_msec() > deadline:
			printerr("diff_bench: diff did not load: %s" % [session.diff_info()])
			get_tree().quit(1)
			return
		await get_tree().process_frame
	var info: Dictionary = session.diff_info()
	print("BENCH lines %d" % int(info["line_count"]))
	print("BENCH load_ms %.1f" % ((Time.get_ticks_usec() - started) / 1000.0))

	for split: bool in [false, true]:
		var times: PackedFloat64Array = PackedFloat64Array()
		for i: int in SAMPLES:
			var start: int = (i * 997) % maxi(1, int(info["line_count"]) - WINDOW)
			var t: int = Time.get_ticks_usec()
			if split:
				session.diff_split_rows("changes", start, WINDOW)
			else:
				session.diff_lines(start, WINDOW)
			times.append(float(Time.get_ticks_usec() - t))
		times.sort()
		var name: String = "split" if split else "unified"
		print("BENCH %s_fetch_%d_us_p50 %.0f" % [name, WINDOW, times[times.size() / 2]])
		print("BENCH %s_fetch_%d_us_max %.0f" % [name, WINDOW, times[times.size() - 1]])

	var panel: DiffPanel = PANEL.instantiate() as DiffPanel
	add_child(panel)
	panel.size = get_viewport().get_visible_rect().size
	panel.set_source(func(start: int, count: int) -> Array: return session.diff_lines(start, count))
	panel.set_split_source(func(start: int, count: int) -> Array:
		return session.diff_split_rows("changes", start, count))
	panel.show_info(info)
	await get_tree().process_frame
	var view: DiffView = panel.view()
	var frames: PackedFloat64Array = PackedFloat64Array()
	for i: int in PAGE_FRAMES:
		view.set_scroll_offset(view.scroll_offset() + view.size.y)
		var t: int = Time.get_ticks_usec()
		await get_tree().process_frame
		frames.append(float(Time.get_ticks_usec() - t) / 1000.0)
	frames.sort()
	print("BENCH page_frame_ms_p50 %.2f" % frames[frames.size() / 2])
	print("BENCH page_frame_ms_p99 %.2f" % frames[int(frames.size() * 0.99)])
	print("BENCH page_frame_ms_max %.2f" % frames[frames.size() - 1])
	get_tree().quit(0)


func _arg(prefix: String) -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix)
	return ""
