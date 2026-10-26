class_name RepoTab
extends Control
## One repository tab (PLAN §4): the strip of worktree chips and the view of
## the selected worktree. A worktree's view (and session) is made the first
## time its chip is chosen. What the shell asks of "the current tab" (its
## session, operations, views and menus) is the selected worktree's.

## Title, worktrees or state may have changed.
signal state_changed()
## Something the user should read.
signal notice(title: String, message: String)

const WORKTREE_VIEW: PackedScene = preload("res://app/repo_tab/worktree_view.tscn")
## The tab's attention dot, most important first (PLAN §4 Repo tabs).
enum Attention { NONE, SYNC, CHANGES, CONFLICT }

## The selected worktree's session.
var session: RepoSession:
	get:
		return _active.session if _active != null else null
## The selected worktree's view (History or Changes).
var view: WorktreeView.View:
	get:
		return _active.view if _active != null else WorktreeView.View.HISTORY
## Shows job progress and results; set before `setup`.
var feedback: Feedback = null

var _views: Array[WorktreeView] = []
var _active: WorktreeView = null
## A worktree delete waiting for the shown worktree to load: `{path, force,
## branch}`, or empty.
var _pending_delete: Dictionary = {}

@onready var _strip: WorktreeStrip = %Strip
@onready var _pages: Control = %Pages


func _ready() -> void:
	_strip.worktree_chosen.connect(func(path: String) -> void: show_worktree(path))
	_strip.worktree_menu_requested.connect(_on_chip_menu)


## Shows the worktree of `first` (taking ownership of the session).
func setup(first: RepoSession) -> void:
	_activate(_add_view(first))


## Shows worktree `path`, making its view first if needed. Returns whether it
## is shown (false when its folder cannot be opened).
func show_worktree(path: String) -> bool:
	var existing: WorktreeView = view_for(path)
	if existing != null:
		_activate(existing)
		return true
	var opened: RepoSession = Core.open_session(path)
	if opened == null:
		notice.emit("Cannot open the worktree", Core.start_error())
		return false
	_activate(_add_view(opened))
	return true


## The view of worktree `path` (as git or the user wrote it), or null.
func view_for(path: String) -> WorktreeView:
	for v: WorktreeView in _views:
		if Paths.same(v.worktree_path(), path) or Paths.same(v.repo_path(), path):
			return v
	return null


## Whether `path` is one of this repository's worktrees.
func has_worktree(path: String) -> bool:
	if view_for(path) != null:
		return true
	for wt: Dictionary in worktrees():
		if Paths.same(String(wt["path"]), path):
			return true
	return false


## Closes the view (and session) of worktree `path`, if open; a closed
## selected worktree hands over to the main one.
func close_worktree(path: String) -> void:
	var v: WorktreeView = view_for(path)
	if v == null:
		return
	var was_active: bool = v == _active
	_views.erase(v)
	Core.close_session(v.session)
	v.queue_free()
	if was_active:
		_active = null
		var main: String = main_worktree()
		if not main.is_empty() and not Paths.same(main, path) and show_worktree(main):
			return
		if not _views.is_empty():
			_activate(_views[0])
	_refresh_strip()
	state_changed.emit()


## Closes every session (the tab is going away).
func close_all() -> void:
	for v: WorktreeView in _views:
		Core.close_session(v.session)
	_views.clear()
	_active = null


## Moves the views out (to another tab of the same repository).
func release_views() -> Array[WorktreeView]:
	var out: Array[WorktreeView] = _views.duplicate()
	for v: WorktreeView in out:
		_pages.remove_child(v)
		_disconnect(v)
	_views.clear()
	_active = null
	return out


## Takes over `v` from another tab.
func adopt(v: WorktreeView) -> void:
	_pages.add_child(v)
	_connect(v)
	_views.append(v)
	v.hide()
	_refresh_strip()


func views() -> Array[WorktreeView]:
	return _views


func active_view() -> WorktreeView:
	return _active


## The repository's worktrees (`RepoSession.worktrees()` of the selected one,
## or of another open one while the selected one has not read them yet).
func worktrees() -> Array[Dictionary]:
	if session != null:
		var list: Array[Dictionary] = session.worktrees()
		if not list.is_empty():
			return list
	for v: WorktreeView in _views:
		var list: Array[Dictionary] = v.session.worktrees()
		if not list.is_empty():
			return list
	return []


## The main worktree's path, or "" until known.
func main_worktree() -> String:
	for v: WorktreeView in [_active] + _views:
		if v != null and not v.session.main_worktree().is_empty():
			return v.session.main_worktree()
	return ""


## What identifies the repository: its main worktree, else the selected path.
func key() -> String:
	var main: String = main_worktree()
	return main if not main.is_empty() else repo_path()


## The selected worktree's session key (as opened).
func repo_path() -> String:
	return _active.repo_path() if _active != null else ""


## The tab title: the repository's name.
func title() -> String:
	var main: String = main_worktree()
	if not main.is_empty():
		return main.replace("\\", "/").trim_suffix("/").get_file()
	return session.display_name() if session != null else ""


## The most important state across the worktrees (PLAN §4): a conflict or an
## operation in progress, then changed files, then commits to pull or push.
func attention() -> Attention:
	var level: Attention = Attention.NONE
	for wt: Dictionary in worktrees():
		if int(wt.get("conflicts", 0)) > 0 or not String(wt.get("operation", "")).is_empty():
			return Attention.CONFLICT
		if int(wt["changed"]) > 0:
			level = Attention.CHANGES
		elif level == Attention.NONE and (int(wt.get("ahead", 0)) > 0 or int(wt.get("behind", 0)) > 0):
			level = Attention.SYNC
	return level


## One line per worktree: `name · branch  state`, for the tab's tooltip.
func summary() -> String:
	var lines: PackedStringArray = PackedStringArray()
	for wt: Dictionary in WorktreeStrip._ordered(worktrees()):
		var state: String = String(wt["badge"])
		lines.append("%s · %s%s" % [String(wt["name"]), String(wt["branch"]), "  " + state if not state.is_empty() else ""])
	return "\n".join(lines) if not lines.is_empty() else repo_path()


## Shows chip `index` (0-based) of the strip.
func select_chip(index: int) -> bool:
	var path: String = _strip.path_at(index)
	return not path.is_empty() and show_worktree(path)


func strip() -> WorktreeStrip:
	return _strip


func has_error() -> bool:
	return _active != null and _active.has_error()


# --- The selected worktree's parts (what the shell's actions act on) -----------

func ops() -> RepoOps:
	return _active.ops()


func history() -> HistoryView:
	return _active.history()


func changes() -> ChangesView:
	return _active.changes()


func show_view(which: WorktreeView.View) -> void:
	_active.show_view(which)


func focus_view() -> void:
	if _active != null:
		_active.focus_view()


func ref_target() -> Dictionary:
	return _active.ref_target() if _active != null else {}


func commit_target() -> Dictionary:
	return _active.commit_target() if _active != null else {}


func show_menu(ids: Array, at_position: Vector2) -> void:
	_active.show_menu(ids, at_position)


func close_menu() -> void:
	_active.close_menu()


func context_menu() -> PopupMenu:
	return _active.context_menu()


func menu_labels() -> PackedStringArray:
	return _active.menu_labels()


func press_menu(label: String) -> bool:
	return _active.press_menu(label)


# --- Internals ------------------------------------------------------------------

func _add_view(opened: RepoSession) -> WorktreeView:
	var v: WorktreeView = WORKTREE_VIEW.instantiate() as WorktreeView
	v.feedback = feedback
	_pages.add_child(v)
	v.setup(opened)
	_connect(v)
	_views.append(v)
	if feedback != null:
		feedback.watch(opened)
	return v


func _connect(v: WorktreeView) -> void:
	v.state_changed.connect(_on_view_state.bind(v))
	v.notice.connect(_forward_notice)
	v.worktree_open_requested.connect(_on_open_requested)
	v.worktree_close_requested.connect(close_worktree)
	v.worktree_delete_requested.connect(_delete_worktree)


func _disconnect(v: WorktreeView) -> void:
	for sig: Signal in [v.state_changed, v.notice, v.worktree_open_requested, v.worktree_close_requested,
			v.worktree_delete_requested]:
		for connection: Dictionary in sig.get_connections():
			var callable: Callable = connection["callable"]
			if callable.get_object() == self:
				sig.disconnect(callable)


func _forward_notice(title_text: String, message: String) -> void:
	notice.emit(title_text, message)


func _on_open_requested(path: String) -> void:
	show_worktree(path)


func _activate(v: WorktreeView) -> void:
	_active = v
	for other: WorktreeView in _views:
		other.visible = other == v
	_refresh_strip()
	v.focus_view()
	state_changed.emit()


func _on_view_state(v: WorktreeView) -> void:
	if v == _active:
		_refresh_strip()
		_run_pending_delete()
	state_changed.emit()


## Deletes worktree `path` (then `branch` unless empty) from another
## worktree: its own view closes first, showing the main worktree if it was
## the one shown.
func _delete_worktree(path: String, force: bool, branch: String) -> void:
	close_worktree(path)
	_pending_delete = {"path": path, "force": force, "branch": branch}
	_run_pending_delete()


## Runs the pending delete once the shown worktree has loaded.
func _run_pending_delete() -> void:
	if _pending_delete.is_empty() or _active == null or not _active.session.is_ready():
		return
	var pending: Dictionary = _pending_delete
	_pending_delete = {}
	_active.ops().delete_worktree(String(pending["path"]), bool(pending["force"]), String(pending["branch"]))


func _refresh_strip() -> void:
	if _active == null or not is_node_ready():
		return
	var list: Array[Dictionary] = worktrees()
	if list.is_empty():
		# Not read yet: show the selected worktree alone.
		list.append({"path": _active.worktree_path(), "name": _active.worktree_path().replace("\\", "/").get_file(),
			"branch": session.current_branch(), "head": "", "detached": false, "bare": false, "locked": false,
			"lock_reason": "", "prunable": false, "is_main": true, "is_current": true, "badge": "", "changed": -1})
	_strip.show_worktrees(list, _active.worktree_path())


func _on_chip_menu(wt: Dictionary, at_position: Vector2) -> void:
	if _active == null:
		return
	_active.show_ref_menu({
		"type": "worktree",
		"name": "worktree:" + String(wt["path"]),
		"short": String(wt["name"]),
		"path": String(wt["path"]),
		"commit": String(wt["head"]),
		"is_head": bool(wt["is_current"]),
		"is_main": bool(wt["is_main"]),
		"locked": bool(wt["locked"]),
		"prunable": bool(wt["prunable"]),
		"branch": String(wt["branch"]),
		"detached": bool(wt["detached"]),
		"changed": maxi(0, int(wt["changed"])),
		"upstream": "",
	}, at_position)
