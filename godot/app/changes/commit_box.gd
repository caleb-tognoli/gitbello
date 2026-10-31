class_name CommitBox
extends VBoxContainer
## Commit message (summary and body), amend toggle and the commit button,
## which says what it commits ("Commit 2 files to main") and, when it cannot,
## why in its tooltip. Hook or git output from a failed commit is shown below
## until the next attempt.

## A commit or amend finished successfully.
signal committed()

const THEME_TYPE: StringName = &"CommitBox"
const COMMIT_LABEL: String = "commit"

var session: RepoSession = null:
	set = set_session
## Shows the commit's progress on the button and its success; may be null.
var feedback: Feedback = null

var _job: int = -1
## Message loaded from HEAD for amending, to tell it apart from user edits.
var _loaded_summary: String = ""
var _loaded_body: String = ""
var _waiting_for_message: bool = false
## What the user had typed before an amend filled in HEAD's message.
var _draft_summary: String = ""
var _draft_body: String = ""

@onready var _summary: LineEdit = %Summary
@onready var _body: TextEdit = %Body
@onready var _amend: CheckBox = %Amend
@onready var _commit_button: Button = %CommitButton
@onready var _output: TextEdit = %Output


func _ready() -> void:
	_apply_theme()
	_commit_button.icon = Actions.icon(&"changes.commit")
	_amend.tooltip_text = tr("Amend the last commit")
	_summary.text_changed.connect(func(_t: String) -> void: update_state())
	_summary.text_submitted.connect(func(_t: String) -> void: _body.grab_focus())
	_body.text_changed.connect(update_state)
	_amend.toggled.connect(_on_amend_toggled)
	_commit_button.pressed.connect(commit)
	update_state()


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		_amend.tooltip_text = tr("Amend the last commit")
		update_state()


func set_session(value: RepoSession) -> void:
	if session != null:
		session.job_finished.disconnect(_on_job_finished)
		session.head_message_loaded.disconnect(_on_head_message_loaded)
		session.status_changed.disconnect(update_state)
	session = value
	if session != null:
		session.job_finished.connect(_on_job_finished)
		session.head_message_loaded.connect(_on_head_message_loaded)
		session.status_changed.connect(update_state)
	if is_node_ready():
		update_state()


func summary() -> String:
	return _summary.text


func body() -> String:
	return _body.text


func set_message(summary_text: String, body_text: String) -> void:
	_summary.text = summary_text
	_body.text = body_text
	update_state()


func is_amend() -> bool:
	return _amend.button_pressed


func set_amend(value: bool) -> void:
	_amend.button_pressed = value


func is_busy() -> bool:
	return _job >= 0


func output_text() -> String:
	return _output.text if _output.visible else ""


func can_commit() -> bool:
	return session != null and _job < 0 and block_reason().is_empty()


## Why the commit button is disabled, or "".
func block_reason() -> String:
	if session == null:
		return tr("No repository")
	var reason: String = session.commit_block_reason(_amend.button_pressed)
	if not reason.is_empty():
		return tr(reason)
	if _summary.text.strip_edges().is_empty():
		return tr("Write a summary")
	return ""


## What the button commits: "Commit 2 files to main", "Amend last commit"...
func button_text() -> String:
	var count: int = session.picked_count() if session != null else 0
	var files: String = tr("1 file") if count == 1 else tr("%d files") % count
	if _amend.button_pressed:
		return tr("Amend last commit") if count == 0 else tr("Amend last commit with %s") % files
	var branch: String = session.current_branch() if session != null else ""
	if branch.is_empty():
		return tr("Commit") if count == 0 else tr("Commit %s") % files
	return tr("Commit to %s") % branch if count == 0 else tr("Commit %s to %s") % [files, branch]


func focus_summary() -> void:
	_summary.grab_focus()
	_summary.caret_column = _summary.text.length()


func update_state() -> void:
	if not is_node_ready():
		return
	_commit_button.disabled = not can_commit()
	if _job >= 0:
		_commit_button.text = tr("Committing…")
	else:
		_commit_button.text = button_text()
	var shortcut: String = Actions.shortcut_label(&"changes.commit")
	var why: String = block_reason() if _job < 0 else ""
	_commit_button.tooltip_text = why if not why.is_empty() \
			else (button_text() + (" (%s)" % shortcut if not shortcut.is_empty() else ""))


## Commits (or amends) with the current message. Returns whether it started.
func commit() -> bool:
	if not can_commit():
		return false
	_output.hide()
	var done: String = _done_text()
	_job = session.commit(_summary.text, _body.text, _amend.button_pressed)
	if feedback != null:
		feedback.track(session, _job, "Committing", done, _commit_button)
	update_state()
	return _job >= 0


## The success toast of the commit about to start.
func _done_text() -> String:
	var count: int = session.picked_count()
	var files: String = tr("1 file") if count == 1 else tr("%d files") % count
	var branch: String = session.current_branch()
	if _amend.button_pressed:
		return tr("Amended the last commit") if count == 0 else tr("Amended the last commit with %s") % files
	return tr("Committed %s to %s") % [files, branch] if not branch.is_empty() else tr("Committed %s") % files


func _on_amend_toggled(on: bool) -> void:
	if on:
		_draft_summary = _summary.text
		_draft_body = _body.text
		if _summary.text.strip_edges().is_empty() and _body.text.strip_edges().is_empty() and session != null:
			_waiting_for_message = session.load_head_message() >= 0
	else:
		_waiting_for_message = false
		# Put back the user's draft unless they edited the loaded message.
		if _summary.text == _loaded_summary and _body.text == _loaded_body:
			set_message(_draft_summary, _draft_body)
		_loaded_summary = ""
		_loaded_body = ""
	update_state()


func _on_head_message_loaded(summary_text: String, body_text: String) -> void:
	if not _waiting_for_message or not _amend.button_pressed:
		return
	_waiting_for_message = false
	_loaded_summary = summary_text
	_loaded_body = body_text
	set_message(summary_text, body_text)


func _on_job_finished(job: int, label: String, ok: bool, error: Dictionary) -> void:
	if job != _job or label != COMMIT_LABEL:
		return
	_job = -1
	if ok:
		_loaded_summary = ""
		_loaded_body = ""
		_draft_summary = ""
		_draft_body = ""
		_waiting_for_message = false
		_amend.set_pressed_no_signal(false)
		set_message("", "")
		committed.emit()
	else:
		var stderr: String = String(error.get("stderr", "")).strip_edges()
		_output.text = stderr if not stderr.is_empty() else String(error.get("title", "Commit failed"))
		_output.show()
	update_state()


func _apply_theme() -> void:
	_body.custom_minimum_size.y = float(get_theme_constant(&"body_height", THEME_TYPE))
	_output.custom_minimum_size.y = float(get_theme_constant(&"output_height", THEME_TYPE))
