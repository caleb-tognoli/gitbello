class_name Feedback
extends Node
## How running and finished git jobs show (PLAN §4 Feedback). Operations
## report the jobs they start with `track`:
## - started from a control (`Actions.origin()`), the control shows the
##   progress and is disabled until the job ends;
## - started from a shortcut, the palette or a menu, a progress toast shows it
##   and turns into the result;
## - a success ends with a short toast; errors get their own toast from
##   `Core.git_error`.
## It also knows which repositories are busy (for the tab spinner) and when
## each was last fetched.

## A repository's jobs started or ended (for the tab spinner).
signal busy_changed(session: RepoSession)

## Jobs that count as the repository being busy, and how their progress reads.
const VERBS: Dictionary[String, String] = {
	"fetch": "Fetching",
	"pull": "Pulling",
	"push": "Pushing",
	"push tag": "Pushing tag",
	"checkout": "Checking out",
	"shelve": "Shelving",
	"restore shelf": "Restoring the shelf",
	"cherry-pick": "Cherry-picking",
	"abort": "Aborting",
	"commit": "Committing",
	"new task": "Creating the worktree",
	"clean up worktrees": "Cleaning up",
	"add worktree": "Adding the worktree",
	"remove worktree": "Removing the worktree",
}


class Tracked:
	extends RefCounted
	var session: RepoSession
	var job: int
	var doing: String
	var done: String
	var origin: Control = null
	## The progress toast, when there is no origin.
	var toast: PanelContainer = null
	## Called with `ok` when the job ends (follow-ups like push after pull).
	var then: Callable = Callable()
	## Undo for the success toast.
	var undo: Callable = Callable()


var toasts: Toasts = null

## Running jobs per session, by id, with their labels (any job in `VERBS`).
var _running: Dictionary[RepoSession, Dictionary] = {}
var _tracked: Array[Tracked] = []
## Unix time of the last successful fetch, per repository path.
var _fetched: Dictionary[String, int] = {}


## Follows the jobs of `session` until it leaves the tree.
func watch(session: RepoSession) -> void:
	if _running.has(session):
		return
	_running[session] = {}
	session.job_started.connect(_on_started.bind(session))
	session.job_progress.connect(_on_progress.bind(session))
	session.job_finished.connect(_on_finished.bind(session))
	session.job_cancelled.connect(_on_cancelled.bind(session))
	session.tree_exiting.connect(_forget.bind(session))


## Reports job `job` of `session` (no-op when it did not start, -1). `doing`
## shows while it runs ("Pushing main…"), `done` when it succeeded ("Pushed
## main to origin"; empty for no success toast). The progress goes to
## `origin`, else to `Actions.origin()`, else to a toast.
func track(session: RepoSession, job: int, doing: String, done: String = "",
		origin: Control = null, then: Callable = Callable(), undo: Callable = Callable()) -> void:
	if job < 0 or session == null:
		if then.is_valid():
			then.call(false)
		return
	var item: Tracked = Tracked.new()
	item.session = session
	item.job = job
	item.doing = doing
	item.done = done
	item.then = then
	item.undo = undo
	item.origin = origin if origin != null else Actions.origin()
	_tracked.append(item)
	if item.origin != null:
		_set_busy(item.origin, true, doing, -1)
	elif toasts != null:
		item.toast = toasts.show_progress(doing + "…", func() -> void: session.cancel_job(job))


## Whether `session` runs a job in `VERBS`.
func is_busy(session: RepoSession) -> bool:
	return _running.has(session) and not (_running[session] as Dictionary).is_empty()


## Whether any job of `sessions` is running.
func any_busy(sessions: Array[RepoSession]) -> bool:
	for s: RepoSession in sessions:
		if is_busy(s):
			return true
	return false


## Cancels the newest tracked job of `session`. Returns whether there was one.
func cancel_latest(session: RepoSession) -> bool:
	for i: int in range(_tracked.size() - 1, -1, -1):
		if _tracked[i].session == session:
			return session.cancel_job(_tracked[i].job)
	return false


## Seconds since `repo_path` was last fetched in this run, or -1.
func seconds_since_fetch(repo_path: String) -> int:
	if not _fetched.has(repo_path):
		return -1
	return int(Time.get_unix_time_from_system()) - _fetched[repo_path]


func tracked_count() -> int:
	return _tracked.size()


func _on_started(id: int, label: String, session: RepoSession) -> void:
	if VERBS.has(label):
		(_running[session] as Dictionary)[id] = label
		busy_changed.emit(session)


func _on_progress(id: int, _label: String, percent: int, text: String, session: RepoSession) -> void:
	var item: Tracked = _find(session, id)
	if item == null:
		return
	var shown: String = item.doing + "…" + ("  " + text if not text.is_empty() else "")
	if item.origin != null:
		_set_busy(item.origin, true, shown, percent)
	elif item.toast != null:
		toasts.update_progress(item.toast, shown, percent)


func _on_finished(id: int, label: String, ok: bool, _error: Dictionary, session: RepoSession) -> void:
	if ok and (label == "fetch" or label == "auto-fetch"):
		_fetched[session.repo_path()] = int(Time.get_unix_time_from_system())
	_end(session, id, ok)


func _on_cancelled(id: int, _label: String, session: RepoSession) -> void:
	_end(session, id, false)


func _end(session: RepoSession, id: int, ok: bool) -> void:
	if _running.has(session) and (_running[session] as Dictionary).erase(id):
		busy_changed.emit(session)
	var item: Tracked = _find(session, id)
	if item == null:
		return
	_tracked.erase(item)
	if item.origin != null and is_instance_valid(item.origin):
		_set_busy(item.origin, false, "", -1)
	var text: String = item.done if ok else ""
	if item.toast != null:
		toasts.finish_progress(item.toast, text)
	elif not text.is_empty() and toasts != null:
		toasts.show_success(text, item.undo)
	if item.then.is_valid():
		item.then.call(ok)


func _forget(session: RepoSession) -> void:
	_running.erase(session)
	for item: Tracked in _tracked.duplicate():
		if item.session == session:
			_tracked.erase(item)
			if item.toast != null and toasts != null:
				toasts.finish_progress(item.toast)


func _find(session: RepoSession, id: int) -> Tracked:
	for item: Tracked in _tracked:
		if item.session == session and item.job == id:
			return item
	return null


## A control showing a job: one with `set_busy(busy, text, percent)` draws it
## itself; a plain button is disabled while the job runs.
static func _set_busy(control: Control, busy: bool, text: String, percent: int) -> void:
	if not is_instance_valid(control):
		return
	if control.has_method(&"set_busy"):
		control.call(&"set_busy", busy, text, percent)
	elif control is BaseButton:
		(control as BaseButton).disabled = busy
