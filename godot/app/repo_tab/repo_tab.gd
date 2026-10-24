class_name RepoTab
extends Control
## Content of one repository tab: sidebar plus the History or Changes view.
## Owns its RepoSession.

## Title or badge text may have changed.
signal title_changed()

enum View { HISTORY, CHANGES }

var session: RepoSession = null
var view: View = View.HISTORY

@onready var _split: HSplitContainer = %Split
@onready var _sidebar: RepoSidebar = %Sidebar
@onready var _history: HistoryView = %History
@onready var _changes: ChangesView = %Changes
@onready var _history_button: Button = %HistoryButton
@onready var _changes_button: Button = %ChangesButton
@onready var _error_panel: Control = %ErrorPanel
@onready var _error_label: Label = %ErrorLabel


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
