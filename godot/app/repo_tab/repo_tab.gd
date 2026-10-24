class_name RepoTab
extends Control
## Content of one repository tab: sidebar plus history. Owns its RepoSession.

## Title or badge text may have changed.
signal title_changed()

var session: RepoSession = null

@onready var _split: HSplitContainer = %Split
@onready var _sidebar: RepoSidebar = %Sidebar
@onready var _history: HistoryView = %History
@onready var _error_panel: Control = %ErrorPanel
@onready var _error_label: Label = %ErrorLabel


## Takes ownership of `value` (adds it as a child) and shows its repository.
func setup(value: RepoSession) -> void:
	session = value
	if session.get_parent() == null:
		add_child(session)
	_sidebar.session = session
	_history.session = session
	for sig: Signal in [session.opened, session.badge_changed, session.status_changed]:
		sig.connect(func() -> void: title_changed.emit())
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


func toggle_sidebar() -> void:
	_sidebar.visible = not _sidebar.visible


func has_error() -> bool:
	return _error_panel.visible


func _on_open_failed(error: Dictionary) -> void:
	_split.hide()
	_error_panel.show()
	_error_label.text = "%s\n%s\n\n%s" % [
		session.repo_path(),
		String(error.get("title", "")),
		String(error.get("message", "")),
	]
	title_changed.emit()
