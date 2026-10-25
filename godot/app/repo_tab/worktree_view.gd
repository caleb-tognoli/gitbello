class_name WorktreeView
extends Control
## One worktree of a repository tab (PLAN §4): the Branch and Sync buttons,
## the banner of an operation in progress, and the Changes or History panes
## with a switch at the top of their left column. Owns the worktree's
## RepoSession and the RepoOps that run its operations, builds the context
## menus of branches, ref labels, commits and worktree chips from the action
## registry, and dims its panes while a job changes its files.

## The title, branch or state may have changed.
signal state_changed()
## Something the user should read (from the operations).
signal notice(title: String, message: String)
## A worktree should show (a branch checked out there, a new task).
signal worktree_open_requested(path: String)
## A worktree is about to be removed: its view should close.
signal worktree_close_requested(path: String)

enum View { HISTORY, CHANGES }

## Context menu entries per ref type; &"" is a separator.
const REF_MENUS: Dictionary[String, Array] = {
	"branch": [&"branch.checkout", &"", &"branch.new", &"tag.new", &"",
		&"branch.rename", &"branch.set_upstream", &"branch.delete"],
	"remote": [&"branch.checkout", &"branch.new", &"tag.new"],
	"tag": [&"commit.checkout", &"branch.new", &"", &"tag.push", &"tag.delete"],
	"worktree": [&"worktree.open_in_editor", &"worktree.open_terminal", &"worktree.show_in_file_manager",
		&"worktree.copy_path", &"", &"worktree.lock", &"worktree.unlock", &"", &"worktree.remove"],
}
## A ref label in the graph offers fewer actions than the branch list.
const LABEL_MENUS: Dictionary[String, Array] = {
	"branch": [&"branch.checkout", &"", &"branch.delete"],
	"remote": [&"branch.checkout"],
	"tag": [&"tag.push", &"tag.delete"],
}
const COMMIT_MENU: Array[StringName] = [&"commit.checkout", &"branch.new", &"tag.new", &"",
	&"commit.cherry_pick", &"", &"commit.copy_hash"]
const SYNC_MENU: Array[StringName] = [&"sync.fetch", &"sync.pull_merge", &"sync.pull_rebase", &"sync.push",
	&"", &"sync.force_push"]
## Jobs that change the worktree's files: its panes dim while they run.
const BLOCKING: Dictionary[String, String] = {
	"checkout": "Switching branches",
	"shelve": "Shelving",
	"restore shelf": "Restoring the shelf",
	"pull": "Pulling",
	"cherry-pick": "Cherry-picking",
	"abort": "Aborting",
}
## How long a blocking job runs before the panes dim.
const OVERLAY_DELAY: float = 0.3
## What the Sync button says and shows per `RepoOps.sync_state()`.
const SYNC_ICONS: Dictionary[String, StringName] = {
	"publish": &"GitPush", "push": &"GitPush", "pull": &"GitPull", "sync": &"Reload", "fetch": &"GitFetch",
}

var session: RepoSession = null
var view: View = View.HISTORY
## Shows job progress and results; set before `setup`.
var feedback: Feedback = null

var _ops: RepoOps = RepoOps.new()
var _menu: PopupMenu = PopupMenu.new()
var _menu_actions: Array[StringName] = []
## What the open context menu is about; actions see it through `ref_target`
## and `commit_target` while the menu builds and runs.
var _menu_ref: Dictionary = {}
var _menu_commit: Dictionary = {}
var _menu_active: bool = false
var _sync_menu: PopupMenu = PopupMenu.new()
var _sync_ids: Array[StringName] = []
var _popover: BranchPopover = BranchPopover.new()
var _switch: HBoxContainer = HBoxContainer.new()
var _history_button: Button = Button.new()
var _changes_button: Button = Button.new()
## The blocking job the overlay shows, or -1.
var _overlay_job: int = -1

@onready var _layout: Control = %Layout
@onready var _history: HistoryView = %History
@onready var _changes: ChangesView = %Changes
@onready var _branch_button: BigButton = %BranchButton
@onready var _sync_button: BigButton = %SyncButton
@onready var _banner: Control = %Banner
@onready var _banner_icon: TextureRect = %BannerIcon
@onready var _banner_label: Label = %BannerLabel
@onready var _abort_button: Button = %AbortButton
@onready var _overlay: Control = %Overlay
@onready var _overlay_label: Label = %OverlayLabel
@onready var _overlay_progress: ProgressBar = %OverlayProgress
@onready var _overlay_cancel: Button = %OverlayCancel
@onready var _error_panel: Control = %ErrorPanel
@onready var _error_label: Label = %ErrorLabel


func _ready() -> void:
	_switch.theme_type_variation = &"ViewSwitch"
	var group: ButtonGroup = ButtonGroup.new()
	for entry: Array in [[_changes_button, "Changes", &"FileList", View.CHANGES, &"view.changes"],
			[_history_button, "History", &"History", View.HISTORY, &"view.history"]]:
		var button: Button = entry[0]
		button.text = entry[1]
		button.icon = AppTheme.icon(entry[2])
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.button_group = group
		button.theme_type_variation = &"SegmentButton"
		button.pressed.connect(show_view.bind(entry[3]))
		button.tooltip_text = Actions.tooltip(entry[4])
		_switch.add_child(button)
	add_child(_ops)
	_ops.notice.connect(func(title_text: String, message: String) -> void: notice.emit(title_text, message))
	_ops.open_requested.connect(func(path: String) -> void: worktree_open_requested.emit(path))
	_ops.close_requested.connect(func(path: String) -> void: worktree_close_requested.emit(path))
	add_child(_menu)
	_menu.id_pressed.connect(_on_menu_id)
	add_child(_sync_menu)
	_sync_menu.id_pressed.connect(func(id: int) -> void: Actions.run_action(_sync_ids[id], _sync_button))
	add_child(_popover)
	_popover.branch_chosen.connect(_on_branch_chosen)
	_popover.menu_requested.connect(func(ref: Dictionary, at: Vector2) -> void:
		_popover.hide()
		show_ref_menu(ref, at))
	_popover.new_branch_requested.connect(func() -> void: Actions.run_action(&"branch.new", _branch_button))
	_history.commit_menu_requested.connect(_on_commit_menu)
	_history.label_menu_requested.connect(_on_label_menu)
	_branch_button.icon = AppTheme.icon(&"GitBranch")
	_branch_button.pressed.connect(open_branches)
	_branch_button.menu_requested.connect(open_branches)
	_sync_button.pressed.connect(func() -> void: Actions.run_action(&"sync.sync", _sync_button))
	_sync_button.menu_requested.connect(_open_sync_menu)
	_banner_icon.texture = AppTheme.icon(&"GitConflict")
	_abort_button.pressed.connect(func() -> void: Actions.run_action(&"operation.abort", _abort_button))
	_overlay_cancel.pressed.connect(func() -> void:
		if _overlay_job >= 0:
			session.cancel_job(_overlay_job))
	var panes: Array[SplitContainer] = [_history, _changes, _history.details(), _history.details().files_split()]
	for pane: SplitContainer in panes:
		pane.drag_ended.connect(_on_split_dragged.bind(pane))
	show_view(View.HISTORY)


## Takes ownership of `value` (adds it as a child) and shows its worktree.
func setup(value: RepoSession) -> void:
	session = value
	if session.get_parent() == null:
		add_child(session)
	_history.session = session
	_changes.session = session
	_changes.feedback = feedback
	_changes.ops = _ops
	_ops.session = session
	_ops.feedback = feedback
	_popover.session = session
	for sig: Signal in [session.opened, session.badge_changed, session.status_changed, session.refs_changed,
			session.worktrees_changed, session.operation_changed]:
		sig.connect(_on_state)
	session.open_failed.connect(_on_open_failed)
	session.missing.connect(_on_missing)
	session.job_started.connect(_on_job_started)
	session.job_progress.connect(_on_job_progress)
	session.job_finished.connect(func(job: int, _label: String, _ok: bool, _error: Dictionary) -> void:
		_on_job_ended(job))
	session.job_cancelled.connect(func(job: int, _label: String) -> void: _on_job_ended(job))
	session.opened.connect(_restore_widths)
	_restore_widths()
	_on_state()
	var error: Dictionary = session.open_error()
	if not error.is_empty():
		_on_open_failed(error)


func repo_path() -> String:
	return session.repo_path() if session != null else ""


## The worktree's folder (the session's toplevel once known).
func worktree_path() -> String:
	if session == null:
		return ""
	var top: String = session.toplevel()
	return top if not top.is_empty() else session.repo_path()


func history() -> HistoryView:
	return _history


func changes() -> ChangesView:
	return _changes


func ops() -> RepoOps:
	return _ops


func branch_button() -> BigButton:
	return _branch_button


func sync_button() -> BigButton:
	return _sync_button


func branch_popover() -> BranchPopover:
	return _popover


func banner() -> Control:
	return _banner


func overlay() -> Control:
	return _overlay


func has_error() -> bool:
	return _error_panel.visible


## Opens the branch list under the Branch button.
func open_branches() -> void:
	if session != null and session.is_ready():
		_popover.open_below(_branch_button)


# --- Context menus --------------------------------------------------------------

## The ref the user is acting on: the open context menu's, or empty.
func ref_target() -> Dictionary:
	return _menu_ref if _menu_active else {}


## The commit the user is acting on (`{hash, subject}`): the context menu's,
## or the history's cursor while the history shows.
func commit_target() -> Dictionary:
	if _menu_active:
		return _menu_commit
	return _history.selected_commit() if view == View.HISTORY else {}


## Shows the menu of `ref` (a branch, remote branch, tag or worktree) at a
## screen position.
func show_ref_menu(ref: Dictionary, at_position: Vector2, menus: Dictionary = REF_MENUS) -> void:
	_menu_ref = ref
	_menu_commit = {}
	show_menu(menus.get(String(ref["type"]), []), at_position)


## Shows a context menu of the enabled actions among `ids` at a screen position.
func show_menu(ids: Array, at_position: Vector2) -> void:
	_menu.clear()
	_menu_actions.clear()
	_menu_active = true
	for id: StringName in ids:
		if id == &"":
			if _menu.item_count > 0 and not _menu.is_item_separator(_menu.item_count - 1):
				_menu.add_separator()
		elif Actions.is_enabled(id):
			_menu.add_item(Actions.get_action(id).label, _menu_actions.size())
			_menu_actions.append(id)
	_menu_active = false
	while _menu.item_count > 0 and _menu.is_item_separator(_menu.item_count - 1):
		_menu.remove_item(_menu.item_count - 1)
	if _menu_actions.is_empty():
		return
	_menu.position = Vector2i(at_position)
	_menu.reset_size()
	_menu.popup()


func close_menu() -> void:
	_menu.hide()


func context_menu() -> PopupMenu:
	return _menu


## Labels in the open (or last) context menu, for tests.
func menu_labels() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i: int in _menu.item_count:
		if not _menu.is_item_separator(i):
			out.append(_menu.get_item_text(i))
	return out


## Runs the context menu entry labelled `label` (for tests).
func press_menu(label: String) -> bool:
	for i: int in _menu.item_count:
		if _menu.get_item_text(i) == label:
			_menu.hide()
			_on_menu_id(_menu.get_item_id(i))
			return true
	return false


func _on_menu_id(id: int) -> void:
	_menu_active = true
	Actions.run_action(_menu_actions[id])
	_menu_active = false


func _on_commit_menu(at_position: Vector2) -> void:
	_menu_ref = {}
	_menu_commit = _history.selected_commit()
	show_menu(COMMIT_MENU, at_position)


func _on_label_menu(label: Dictionary, at_position: Vector2) -> void:
	var kind: String = String(label["kind"])
	var ref: Dictionary = {}
	for candidate: Dictionary in session.branch_refs():
		if String(candidate["name"]) == String(label["name"]):
			ref = {"type": "branch" if kind == "branch" else "remote", "name": String(candidate["name"]),
				"short": String(candidate["short_name"]), "commit": String(candidate["commit"]),
				"is_head": bool(candidate["is_head"]), "upstream": String(candidate["upstream"]),
				"worktree": String(candidate["worktree"])}
	if kind == "tag":
		for tag: Dictionary in session.tags():
			if String(tag["name"]) == String(label["short"]):
				ref = {"type": "tag", "name": String(label["name"]), "short": String(tag["name"]),
					"commit": String(tag["commit"]), "is_head": false, "upstream": ""}
	if ref.is_empty():
		_on_commit_menu(at_position)
		return
	show_ref_menu(ref, at_position, LABEL_MENUS)


## A branch from the list: switch to it, or show the worktree that has it.
func _on_branch_chosen(ref: Dictionary) -> void:
	var worktree: String = String(ref.get("worktree", ""))
	if not worktree.is_empty():
		worktree_open_requested.emit(worktree)
	elif String(ref["type"]) == "remote":
		_ops.checkout_remote(String(ref["name"]))
	elif not bool(ref["is_head"]):
		_ops.checkout_branch(String(ref["short"]))


func _open_sync_menu() -> void:
	_sync_menu.clear()
	_sync_ids.clear()
	for id: StringName in SYNC_MENU:
		if id == &"":
			_sync_menu.add_separator()
			continue
		var action: ActionRegistry.Action = Actions.get_action(id)
		if action == null:
			continue
		_sync_menu.add_item(action.label, _sync_ids.size())
		_sync_menu.set_item_disabled(_sync_menu.item_count - 1, not action.is_enabled())
		_sync_ids.append(id)
	var rect: Rect2 = _sync_button.get_global_rect()
	_sync_menu.position = Vector2i(get_window().position) + Vector2i((rect.position + Vector2(0.0, rect.size.y)) \
			* get_window().content_scale_factor)
	_sync_menu.reset_size()
	_sync_menu.popup()


# --- Views ----------------------------------------------------------------------

## Switches the panes and focuses them (the changes view focuses its files).
func show_view(which: View) -> void:
	view = which
	_history.visible = which == View.HISTORY
	_changes.visible = which == View.CHANGES
	_history_button.set_pressed_no_signal(which == View.HISTORY)
	_changes_button.set_pressed_no_signal(which == View.CHANGES)
	var slot: Container = _history.switch_slot() if which == View.HISTORY else _changes.switch_slot()
	if _switch.get_parent() != slot:
		if _switch.get_parent() != null:
			_switch.get_parent().remove_child(_switch)
		slot.add_child(_switch)
	focus_view()


func focus_view() -> void:
	if not is_visible_in_tree():
		return
	if view == View.CHANGES:
		_changes.focus_files()
	else:
		_history.commit_list().grab_focus()


## The left-pane width of each view, and the commit details' height and
## files width, are saved per repository.
func _on_split_dragged(pane: SplitContainer) -> void:
	Core.set_repo_ui_state(_repo_key(), _split_key(pane), pane.split_offset)


func _split_key(pane: SplitContainer) -> String:
	if pane == _history:
		return "history_width"
	if pane == _changes:
		return "changes_width"
	if pane == _history.details():
		return "details_height"
	return "details_files_width"


## Saved sizes, else the theme's defaults (a split's offset is the size of
## its first part).
func _restore_widths() -> void:
	var saved: Dictionary = Core.repo_ui_state(_repo_key())
	var default: int = get_theme_constant(&"default_left_width", &"Panes")
	_history.split_offset = int(saved.get("history_width", default))
	_changes.split_offset = int(saved.get("changes_width", default))
	var details: CommitDetails = _history.details()
	details.split_offset = int(saved.get("details_height",
			details.get_theme_constant(&"details_height", CommitDetails.THEME_TYPE)))
	details.files_split().split_offset = int(saved.get("details_files_width",
			details.get_theme_constant(&"files_width", CommitDetails.THEME_TYPE)))


## Per-repository state is saved under the main worktree's path.
func _repo_key() -> String:
	var main: String = session.main_worktree() if session != null else ""
	return main if not main.is_empty() else worktree_path()


# --- State ----------------------------------------------------------------------

func _on_state() -> void:
	if session == null or not is_node_ready():
		return
	_update_header()
	_update_banner()
	var changed: int = int(session.badge().get("changed", 0))
	_changes_button.text = "Changes" if changed == 0 else "Changes · %d" % changed
	state_changed.emit()


func _update_header() -> void:
	var branch: String = session.current_branch()
	var head: String = String(session.status().get("oid", ""))
	if branch.is_empty():
		branch = "Detached at %s" % head.left(7) if not head.is_empty() else "No branch yet"
	_branch_button.show_state(branch, AppTheme.icon(&"GitBranch"), session.is_ready())
	_branch_button.tooltip_text = Actions.tooltip(&"branch.switch")
	var state: String = _ops.sync_state()
	var badge: Dictionary = session.badge()
	var ahead: int = int(badge.get("ahead", 0))
	var behind: int = int(badge.get("behind", 0))
	var caption: String = {
		"publish": "Publish branch",
		"push": "Push ↑%d" % ahead,
		"pull": "Pull ↓%d" % behind,
		"sync": "Sync ↓%d ↑%d" % [behind, ahead],
		"fetch": "Fetch",
	}[state]
	_sync_button.show_state(caption, AppTheme.icon(SYNC_ICONS[state]), session.is_ready() and session.can_fetch())
	var tooltip: String = {
		"publish": "Push %s and set its upstream" % session.current_branch(),
		"push": "Push your commits to %s" % session.default_remote(),
		"pull": "Pull the new commits from %s" % session.default_remote(),
		"sync": "Pull the new commits, then push yours",
		"fetch": "Fetch from %s" % session.default_remote(),
	}[state]
	if feedback != null:
		var seconds: int = feedback.seconds_since_fetch(session.repo_path())
		if seconds >= 0:
			tooltip += "\nFetched %s" % _ago(seconds)
	if not session.can_fetch() and session.is_ready():
		tooltip = "This repository has no remote. Add one with Repository → Remotes…"
	_sync_button.tooltip_text = tooltip


func _update_banner() -> void:
	var operation: String = session.operation()
	_banner.visible = not operation.is_empty()
	if operation.is_empty():
		return
	var doing: String = {
		"merge": "Merging", "rebase": "Rebasing", "cherry-pick": "Cherry-picking",
		"revert": "Reverting", "bisect": "Bisecting",
	}.get(operation, operation.capitalize())
	var conflicts: int = int(session.badge().get("conflicts", 0))
	var where: String = session.current_branch()
	_banner_label.text = "%s%s%s" % [doing, " into " + where if not where.is_empty() and operation == "merge" else "",
			" · %d conflict%s" % [conflicts, "" if conflicts == 1 else "s"] if conflicts > 0 else ""]


static func _ago(seconds: int) -> String:
	if seconds < 60:
		return "just now"
	if seconds < 3600:
		return "%d min ago" % (seconds / 60)
	return "%d h ago" % (seconds / 3600)


# --- Blocking jobs --------------------------------------------------------------

func _on_job_started(job: int, label: String) -> void:
	if not BLOCKING.has(label):
		return
	_overlay_job = job
	_overlay_label.text = BLOCKING[label] + "…"
	_overlay_progress.indeterminate = true
	get_tree().create_timer(OVERLAY_DELAY).timeout.connect(func() -> void:
		if _overlay_job == job:
			_overlay.show())


func _on_job_progress(job: int, label: String, percent: int, text: String) -> void:
	if job != _overlay_job:
		return
	_overlay_label.text = BLOCKING.get(label, label.capitalize()) + "…" + ("  " + text if not text.is_empty() else "")
	_overlay_progress.indeterminate = percent < 0
	_overlay_progress.value = maxf(0.0, float(percent))


func _on_job_ended(job: int) -> void:
	if job == _overlay_job:
		_overlay_job = -1
		_overlay.hide()


# --- Errors ---------------------------------------------------------------------

func _on_missing() -> void:
	_layout.hide()
	_error_panel.show()
	_error_label.text = "%s\n\nThis worktree's folder no longer exists." % worktree_path()
	state_changed.emit()


func _on_open_failed(error: Dictionary) -> void:
	_layout.hide()
	_error_panel.show()
	_error_label.text = "%s\n%s\n\n%s" % [
		session.repo_path(),
		String(error.get("title", "")),
		String(error.get("message", "")),
	]
	state_changed.emit()
