class_name CommitBox
extends VBoxContainer
## Commit message (summary and body), amend toggle and commit button. Hook or
## git output from a failed commit is shown below until the next attempt.

## A commit or amend finished successfully.
signal committed()

const THEME_TYPE: StringName = &"CommitBox"
const COMMIT_LABEL: String = "commit"

var session: RepoSession = null:
	set = set_session

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
	_summary.text_changed.connect(func(_t: String) -> void: update_state())
	_summary.text_submitted.connect(func(_t: String) -> void: _body.grab_focus())
	_body.text_changed.connect(update_state)
	_amend.toggled.connect(_on_amend_toggled)
	_commit_button.pressed.connect(commit)
	update_state()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_apply_theme()


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
	return session != null and _job < 0 and not _summary.text.strip_edges().is_empty() \
			and session.can_commit(_amend.button_pressed)


func focus_summary() -> void:
	_summary.grab_focus()
	_summary.caret_column = _summary.text.length()


func update_state() -> void:
	if not is_node_ready():
		return
	_commit_button.disabled = not can_commit()
	if _job >= 0:
		_commit_button.text = "Committing…"
	else:
		_commit_button.text = "Amend last commit" if _amend.button_pressed else "Commit"


## Commits (or amends) with the current message. Returns whether it started.
func commit() -> bool:
	if not can_commit():
		return false
	_output.hide()
	_job = session.commit(_summary.text, _body.text, _amend.button_pressed)
	update_state()
	return _job >= 0


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
