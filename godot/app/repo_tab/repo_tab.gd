class_name RepoTab
extends Control
## Content of one repository tab: sidebar plus the History or Changes view,
## with Fetch, Pull and Push in the view bar. Owns its RepoSession and the
## RepoOps that run its operations, and builds the context menus of the
## sidebar's refs and the history's commits from the action registry.

## Title or badge text may have changed.
signal title_changed()
## Something the user should read (from the tab's operations).
signal notice(title: String, message: String)

enum View { HISTORY, CHANGES }

## Context menu entries per sidebar row type; &"" is a separator.
const REF_MENUS: Dictionary[String, Array] = {
	"branch": [&"branch.checkout", &"sync.pull", &"sync.push", &"", &"branch.new", &"tag.new", &"",
		&"branch.rename", &"branch.set_upstream", &"branch.delete"],
	"remote": [&"branch.checkout", &"branch.new", &"tag.new"],
	"tag": [&"commit.checkout", &"branch.new", &"", &"tag.push", &"tag.delete"],
}
const COMMIT_MENU: Array[StringName] = [&"commit.checkout", &"branch.new", &"tag.new", &"",
	&"commit.cherry_pick", &"", &"commit.copy_hash"]

var session: RepoSession = null
var view: View = View.HISTORY

var _ops: RepoOps = RepoOps.new()
var _menu: PopupMenu = PopupMenu.new()
var _menu_actions: Array[StringName] = []
## What the open context menu is about; actions see it through `ref_target`
## and `commit_target` while the menu builds and runs.
var _menu_ref: Dictionary = {}
var _menu_commit: Dictionary = {}
var _menu_active: bool = false

@onready var _split: HSplitContainer = %Split
@onready var _sidebar: RepoSidebar = %Sidebar
@onready var _history: HistoryView = %History
@onready var _changes: ChangesView = %Changes
@onready var _history_button: Button = %HistoryButton
@onready var _changes_button: Button = %ChangesButton
@onready var _error_panel: Control = %ErrorPanel
@onready var _error_label: Label = %ErrorLabel
@onready var _fetch_button: Button = %FetchButton
@onready var _pull_button: Button = %PullButton
@onready var _push_button: Button = %PushButton


func _ready() -> void:
	var group: ButtonGroup = ButtonGroup.new()
	_history_button.button_group = group
	_changes_button.button_group = group
	_history_button.pressed.connect(show_view.bind(View.HISTORY))
	_changes_button.pressed.connect(show_view.bind(View.CHANGES))
	_sidebar.changes_requested.connect(show_view.bind(View.CHANGES))
	for button: Button in [_history_button, _changes_button]:
		var action: StringName = &"view.history" if button == _history_button else &"view.changes"
		button.tooltip_text = Actions.shortcut_label(action)
	add_child(_ops)
	_ops.notice.connect(func(title_text: String, message: String) -> void: notice.emit(title_text, message))
	add_child(_menu)
	_menu.id_pressed.connect(_on_menu_id)
	_sidebar.ref_activated.connect(_on_ref_activated)
	_sidebar.context_menu_requested.connect(_on_ref_menu)
	_history.commit_menu_requested.connect(_on_commit_menu)
	_fetch_button.pressed.connect(func() -> void: Actions.run_action(&"sync.fetch"))
	_pull_button.pressed.connect(func() -> void: Actions.run_action(&"sync.pull"))
	_push_button.pressed.connect(func() -> void: Actions.run_action(&"sync.push"))


## Takes ownership of `value` (adds it as a child) and shows its repository.
func setup(value: RepoSession) -> void:
	session = value
	if session.get_parent() == null:
		add_child(session)
	_sidebar.session = session
	_history.session = session
	_changes.session = session
	for sig: Signal in [session.opened, session.badge_changed, session.status_changed]:
		sig.connect(func() -> void: title_changed.emit())
	session.status_changed.connect(_update_changes_button)
	session.open_failed.connect(_on_open_failed)
	_ops.session = session
	for sig: Signal in [session.opened, session.refs_changed, session.status_changed, session.badge_changed]:
		sig.connect(_update_sync_buttons)
	session.job_started.connect(func(_job: int, _label: String) -> void: _update_sync_buttons())
	session.job_cancelled.connect(func(_job: int, _label: String) -> void: _update_sync_buttons())
	session.job_finished.connect(func(_job: int, _label: String, _ok: bool, _error: Dictionary) -> void:
		_update_sync_buttons())
	_update_sync_buttons()
	var error: Dictionary = session.open_error()
	if not error.is_empty():
		_on_open_failed(error)


func repo_path() -> String:
	return session.repo_path() if session != null else ""


## `name · branch` for the tab title.
func title() -> String:
	if session == null:
		return ""
	var badge: Dictionary = session.badge()
	var head: String = String(badge.get("head", ""))
	return session.display_name() if head.is_empty() else "%s · %s" % [session.display_name(), head]


## `3 ↑1 ↓2`-style summary, empty when clean and in sync.
func badge_text() -> String:
	return String(session.badge().get("summary", "")) if session != null else ""


func sidebar() -> RepoSidebar:
	return _sidebar


func history() -> HistoryView:
	return _history


func changes() -> ChangesView:
	return _changes


func ops() -> RepoOps:
	return _ops


## The sidebar ref the user is acting on: the context menu's, or the
## selected row while the sidebar has focus. See `RepoSidebar.selected_ref`.
func ref_target() -> Dictionary:
	if _menu_active:
		return _menu_ref
	return _sidebar.selected_ref() if _sidebar.has_focus() else {}


## The commit the user is acting on (`{hash, subject}`): the context menu's,
## or the history's cursor while the history is shown and the sidebar does
## not have focus.
func commit_target() -> Dictionary:
	if _menu_active:
		return _menu_commit
	if view != View.HISTORY or _sidebar.has_focus():
		return {}
	return _history.selected_commit()


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


func _on_ref_menu(ref: Dictionary, at_position: Vector2) -> void:
	_menu_ref = ref
	_menu_commit = {}
	show_menu(REF_MENUS.get(String(ref["type"]), []), at_position)


func _on_commit_menu(at_position: Vector2) -> void:
	_menu_ref = {}
	_menu_commit = _history.selected_commit()
	show_menu(COMMIT_MENU, at_position)


## Enter on a branch checks it out; on a remote branch, checks out (or
## creates) the local branch tracking it.
func _on_ref_activated(ref: Dictionary) -> void:
	match String(ref["type"]):
		"branch":
			if not bool(ref["is_head"]):
				_ops.checkout_branch(String(ref["short"]))
		"remote":
			_ops.checkout_remote(String(ref["name"]))


func _update_sync_buttons() -> void:
	if session == null or not is_node_ready():
		return
	var badge: Dictionary = session.badge()
	var ahead: int = int(badge.get("ahead", 0))
	var behind: int = int(badge.get("behind", 0))
	var fetching: bool = session.is_fetching()
	_fetch_button.text = "Fetching…" if fetching else "Fetch"
	_fetch_button.disabled = fetching or not session.can_fetch()
	_pull_button.text = "Pull ↓%d" % behind if behind > 0 else "Pull"
	_pull_button.disabled = not session.can_pull()
	_push_button.text = "Push ↑%d" % ahead if ahead > 0 else "Push"
	_push_button.disabled = not session.can_push()
	for pair: Array in [[_fetch_button, &"sync.fetch"], [_pull_button, &"sync.pull"], [_push_button, &"sync.push"]]:
		var shortcut: String = Actions.shortcut_label(pair[1])
		var action: ActionRegistry.Action = Actions.get_action(pair[1])
		var label: String = action.label if action != null else ""
		(pair[0] as Button).tooltip_text = label if shortcut.is_empty() else "%s (%s)" % [label, shortcut]


func sync_buttons() -> Array[Button]:
	return [_fetch_button, _pull_button, _push_button]


func toggle_sidebar() -> void:
	_sidebar.visible = not _sidebar.visible


func has_error() -> bool:
	return _error_panel.visible


## Switches the main area and focuses it (the changes view focuses its files).
func show_view(which: View) -> void:
	view = which
	_history.visible = which == View.HISTORY
	_changes.visible = which == View.CHANGES
	_history_button.set_pressed_no_signal(which == View.HISTORY)
	_changes_button.set_pressed_no_signal(which == View.CHANGES)
	focus_view()


func focus_view() -> void:
	if view == View.CHANGES:
		_changes.focus_files()
	else:
		_history.commit_list().grab_focus()


func _update_changes_button() -> void:
	var changed: int = int(session.badge().get("changed", 0))
	_changes_button.text = "Changes" if changed == 0 else "Changes · %d" % changed


func _on_open_failed(error: Dictionary) -> void:
	_split.hide()
	_error_panel.show()
	_error_label.text = "%s\n%s\n\n%s" % [
		session.repo_path(),
		String(error.get("title", "")),
		String(error.get("message", "")),
	]
	title_changed.emit()
