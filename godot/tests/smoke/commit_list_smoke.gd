extends SmokeTest
## A session on this repository's own history (read-only) feeds the history view.

const LOAD_TIMEOUT_MS: int = 30_000

var _loaded: bool = false
var _load_error: String = ""


func run() -> void:
	var repo: String = ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var session: RepoSession = Core.open_session(repo)
	expect(session != null, "Core opens a session")
	if session == null:
		return
	var view: HistoryView = (load("res://app/history/history_view.tscn") as PackedScene).instantiate() as HistoryView
	view.set_anchors_preset(Control.PRESET_TOP_LEFT)
	add_child(view)
	add_child(session)
	view.size = Vector2(1000, 600)
	view.repo_loaded.connect(_on_loaded)
	view.session = session

	var deadline: int = Time.get_ticks_msec() + LOAD_TIMEOUT_MS
	while not _loaded and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	expect(_loaded, "history loads within %d ms" % LOAD_TIMEOUT_MS)
	expect_eq(_load_error, "", "no load error")

	var rows: int = session.graph_row_count()
	expect(rows >= 1, "at least one commit (got %d)" % rows)
	var first: Array[Dictionary] = session.graph_rows(0, 3)
	expect_eq(first.size(), mini(3, rows), "graph_rows returns the requested slice")
	if not first.is_empty():
		var row: Dictionary = first[0]
		for key: String in ["row", "hash", "subject", "author", "email", "time", "column",
				"color", "width", "segments", "refs"]:
			expect(row.has(key), "row has `%s`" % key)
		expect_eq(String(row.get("hash", "")).length(), 40, "full hash")
	expect(session.graph_rows(rows, 10).is_empty(), "slice past the end is empty")

	var list: CommitList = view.commit_list()
	await get_tree().process_frame
	await get_tree().process_frame
	expect(list.rows_drawn > 0, "commit list draws rows")
	expect_eq(list.row_count(), rows, "commit list knows every row")
	expect(float(session.load_stats().get("total_ms", -1.0)) >= 0.0, "load_stats reports timing")

	Core.close_session(session)
	view.queue_free()
	session.queue_free()


func _on_loaded(_row_count: int, error: String) -> void:
	_loaded = true
	_load_error = error
