extends Node
## Image diff benchmark (read-only, M7.8): for each `--file`, the unstaged
## image diff's load (git, both sides' bytes), the time to the first picture
## (both sides decoded on worker threads and shown), the longest frame
## meanwhile (the main thread's longest block) and the same file shown again
## from the cache. Run windowed. Prints `BENCH <key> <value>` lines and quits.
## Usage: godot --path godot res://tests/perf/image_bench.tscn --
##        --repo=<worktree root> --file=<path>[,<path>…]

const TIMEOUT_MS: int = 60_000
const PANEL: PackedScene = preload("res://ui/diff_view/diff_panel.tscn")

var _session: RepoSession = null
var _panel: DiffPanel = null


func _ready() -> void:
	var repo: String = _arg("--repo=")
	var files: PackedStringArray = _arg("--file=").split(",", false)
	if repo.is_empty() or files.is_empty():
		printerr("image_bench: pass -- --repo=<path> --file=<path>[,<path>]")
		get_tree().quit(2)
		return
	_session = Core.open_session(repo)
	add_child(_session)
	_panel = PANEL.instantiate() as DiffPanel
	add_child(_panel)
	_panel.set_image_source(func(side: String) -> Dictionary: return _session.image_side("changes", side))
	if not await _wait(func() -> bool: return _session.is_ready() and _session.change_count() > 0):
		return
	var idle: float = 0.0
	var tick: int = Time.get_ticks_usec()
	for frame: int in 60:
		await get_tree().process_frame
		idle = maxf(idle, (Time.get_ticks_usec() - tick) / 1000.0)
		tick = Time.get_ticks_usec()
	print("BENCH idle_longest_frame_ms %.1f" % idle)
	for file: String in files:
		var key: String = file.get_file().replace(".", "_")
		var times: Array[float] = await _show(file)
		if times.is_empty():
			return
		print("BENCH %s_diff_ms %.1f" % [key, times[0]])
		print("BENCH %s_first_picture_ms %.1f" % [key, times[1]])
		print("BENCH %s_longest_frame_ms %.1f" % [key, times[2]])
		print("BENCH %s_show_info_ms %.1f" % [key, times[3]])
		var info: Dictionary = _session.diff_info()
		var image: Dictionary = info.get("image", {})
		print("BENCH %s_stats %s" % [key, DiffPanel.image_stats(image).replace(" ", "")])
	# Again, from the cache.
	for file: String in files:
		var times: Array[float] = await _show(file)
		if times.is_empty():
			return
		print("BENCH %s_cached_picture_ms %.1f" % [file.get_file().replace(".", "_"), times[1]])
		print("BENCH %s_cached_longest_frame_ms %.1f" % [file.get_file().replace(".", "_"), times[2]])
	get_tree().quit(0)


## Shows `file` and returns [diff ready, first picture, longest frame,
## show_info] in ms, or [] on a timeout.
func _show(file: String) -> Array[float]:
	_panel.clear()
	await get_tree().process_frame
	await get_tree().process_frame
	var started: int = Time.get_ticks_usec()
	_session.select_change(file, false)
	var diff_ms: float = -1.0
	var show_ms: float = 0.0
	var longest: float = 0.0
	var last: int = Time.get_ticks_usec()
	var deadline: int = Time.get_ticks_msec() + TIMEOUT_MS
	var images: ImageDiffView = _panel.image_view()
	while true:
		var info: Dictionary = _session.diff_info()
		if diff_ms < 0.0 and String(info.get("path", "")) == file and String(info.get("state", "")) == "ready":
			diff_ms = (Time.get_ticks_usec() - started) / 1000.0
			var before: int = Time.get_ticks_usec()
			_panel.show_info(info)
			show_ms = (Time.get_ticks_usec() - before) / 1000.0
		if diff_ms >= 0.0 and images.texture(ImageDiffView.OLD) != null and images.texture(ImageDiffView.NEW) != null:
			break
		if Time.get_ticks_msec() > deadline:
			printerr("image_bench: %s did not show: %s" % [file, _session.diff_info()])
			get_tree().quit(1)
			return []
		await get_tree().process_frame
		var now: int = Time.get_ticks_usec()
		longest = maxf(longest, (now - last) / 1000.0)
		last = now
	var picture: float = (Time.get_ticks_usec() - started) / 1000.0
	# The frame that draws it.
	await get_tree().process_frame
	longest = maxf(longest, (Time.get_ticks_usec() - last) / 1000.0)
	return [diff_ms, picture, longest, show_ms]


func _wait(predicate: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + TIMEOUT_MS
	while not bool(predicate.call()):
		if Time.get_ticks_msec() > deadline:
			printerr("image_bench: timed out")
			get_tree().quit(1)
			return false
		await get_tree().process_frame
	return true


func _arg(prefix: String) -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix)
	return ""
