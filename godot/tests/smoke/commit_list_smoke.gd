extends SmokeTest
## RepoSession loads this repository's own history (read-only) and the history
## view shows it.

const LOAD_TIMEOUT_MS: int = 30_000

var _loaded: bool = false
var _load_error: String = ""


func run() -> void:
	var repo: String = ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var scene: PackedScene = load("res://app/history/history_view.tscn") as PackedScene
	var view: HistoryView = scene.instantiate() as HistoryView
	view.set_anchors_preset(Control.PRESET_TOP_LEFT)
	add_child(view)
	view.size = Vector2(1000, 600)
	view.repo_loaded.connect(_on_loaded)
	view.open_repo(repo)

	var deadline: int = Time.get_ticks_msec() + LOAD_TIMEOUT_MS
	while not _loaded and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	expect(_loaded, "history loads within %d ms" % LOAD_TIMEOUT_MS)
	expect_eq(_load_error, "", "no load error")

	var session: RepoSession = view.session()
	var rows: int = session.graph_row_count()
	expect(rows >= 1, "at least one commit (got %d)" % rows)
	var first: Array[Dictionary] = session.graph_rows(0, 3)
	expect_eq(first.size(), mini(3, rows), "graph_rows returns the requested slice")
	if not first.is_empty():
		var row: Dictionary = first[0]
		for key: String in ["row", "hash", "subject", "author", "email", "time", "column",
				"color", "width", "segments"]:
			expect(row.has(key), "row has `%s`" % key)
		expect_eq(String(row.get("hash", "")).length(), 40, "full hash")
	expect(session.graph_rows(rows, 10).is_empty(), "slice past the end is empty")

	var list: CommitList = view.commit_list()
	await get_tree().process_frame
	await get_tree().process_frame
	expect(list.rows_drawn > 0, "commit list draws rows")
	expect_eq(list.row_count(), rows, "commit list knows every row")

	var stats: Dictionary = session.load_stats()
	expect(float(stats.get("total_ms", -1.0)) >= 0.0, "load_stats reports timing")

	var failing: RepoSession = RepoSession.new()
	add_child(failing)
	failing.graph_loaded.connect(_on_failing_loaded)
	_load_error = ""
	_loaded = false
	failing.open(OS.get_temp_dir().path_join("gitbello-no-such-repo-%d" % OS.get_process_id()))
	deadline = Time.get_ticks_msec() + LOAD_TIMEOUT_MS
	while not _loaded and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	expect(not _load_error.is_empty(), "a missing repository reports an error")
	failing.queue_free()
	view.queue_free()


func _on_loaded(_row_count: int, error: String) -> void:
	_loaded = true
	_load_error = error


func _on_failing_loaded(_row_count: int, error: String) -> void:
	_loaded = true
	_load_error = error
