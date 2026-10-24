class_name JobsBar
extends HBoxContainer
## The long git operation running in any open tab (fetch, pull, push,
## checkout, cherry-pick), shown in the status bar with its progress and a
## Cancel button. With several running, the newest is shown.

## What the bar says per job label.
const VERBS: Dictionary[String, String] = {
	"fetch": "Fetching",
	"auto-fetch": "Fetching (automatic)",
	"pull": "Pulling",
	"push": "Pushing",
	"push tag": "Pushing tag",
	"checkout": "Checking out",
	"cherry-pick": "Cherry-picking",
}
const THEME_TYPE: StringName = &"JobsBar"


class Job:
	extends RefCounted
	var session: RepoSession
	var id: int
	var label: String
	var percent: int = -1
	var text: String = ""


var _jobs: Array[Job] = []

@onready var _label: Label = %JobLabel
@onready var _progress: ProgressBar = %JobProgress
@onready var _cancel: Button = %JobCancel


func _ready() -> void:
	_cancel.pressed.connect(cancel_current)
	_apply_theme()
	_update()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()


## Follows the jobs of `session` until it leaves the tree.
func watch(session: RepoSession) -> void:
	session.job_started.connect(_on_started.bind(session))
	session.job_progress.connect(_on_progress.bind(session))
	session.job_finished.connect(_on_finished.bind(session))
	session.job_cancelled.connect(_on_cancelled.bind(session))
	session.tree_exiting.connect(_forget.bind(session))


func job_count() -> int:
	return _jobs.size()


## What the bar shows now ("" when idle).
func current_text() -> String:
	return _label.text if visible else ""


func cancel_current() -> bool:
	if _jobs.is_empty():
		return false
	var job: Job = _jobs.back()
	return job.session.cancel_job(job.id)


func _on_started(id: int, label: String, session: RepoSession) -> void:
	if not VERBS.has(label):
		return
	var job: Job = Job.new()
	job.session = session
	job.id = id
	job.label = label
	_jobs.append(job)
	_update()


func _on_progress(id: int, _label_text: String, percent: int, text: String, session: RepoSession) -> void:
	var job: Job = _find(session, id)
	if job != null:
		job.percent = percent
		job.text = text
		_update()


func _on_finished(id: int, _label_text: String, _ok: bool, _error: Dictionary, session: RepoSession) -> void:
	_remove(session, id)


func _on_cancelled(id: int, _label_text: String, session: RepoSession) -> void:
	_remove(session, id)


func _forget(session: RepoSession) -> void:
	_jobs.assign(_jobs.filter(func(job: Job) -> bool: return job.session != session))
	_update()


func _find(session: RepoSession, id: int) -> Job:
	for job: Job in _jobs:
		if job.session == session and job.id == id:
			return job
	return null


func _remove(session: RepoSession, id: int) -> void:
	var job: Job = _find(session, id)
	if job != null:
		_jobs.erase(job)
		_update()


func _update() -> void:
	visible = not _jobs.is_empty()
	if _jobs.is_empty():
		return
	var job: Job = _jobs.back()
	var text: String = "%s · %s…" % [job.session.display_name(), VERBS[job.label]]
	if not job.text.is_empty():
		text += "  " + job.text
	if _jobs.size() > 1:
		text += "  (+%d more)" % (_jobs.size() - 1)
	_label.text = text
	_progress.indeterminate = job.percent < 0
	_progress.value = maxf(0.0, float(job.percent))


func _apply_theme() -> void:
	# Overriding a constant on this node notifies a theme change again.
	var separation: int = get_theme_constant(&"separation", THEME_TYPE)
	if get_theme_constant(&"separation") != separation:
		add_theme_constant_override(&"separation", separation)
	_progress.custom_minimum_size.x = float(get_theme_constant(&"progress_width", THEME_TYPE))
	_label.custom_minimum_size.x = float(get_theme_constant(&"label_width", THEME_TYPE))
