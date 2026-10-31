class_name CommitBox
extends VBoxContainer
## Commit message (summary and body), temporary amend mode and the commit button,
## which says what it commits ("Commit 2 files to main") and, when it cannot,
## why in its tooltip. Hook or git output from a failed commit is shown below
## until the next attempt. While a merge or cherry-pick is committed, the box
## starts with git's message, amend mode is unavailable, the button says what it
## finishes and, while it cannot, why under it ("Resolve login.rs first").
## Under the button, the undo strip offers the last unpushed commit (PLAN §4).

## A commit or amend finished successfully.
signal committed()

const THEME_TYPE: StringName = &"CommitBox"
const COMMIT_LABEL: String = "commit"

var session: RepoSession = null:
	set = set_session
## Shows the commit's progress on the button and its success; may be null.
var feedback: Feedback = null

var _job: int = -1
var _message_job: int = -1
var _amending: bool = false
var _amend_head: String = ""
var _amend_subject: String = ""
var _draft_summary: String = ""
var _draft_body: String = ""
## The operation whose message filled the box (`kind:oid`), so it fills once.
var _filled_for: String = ""
## The message that fill put in the box, `[summary, body]`, so it can go
## when the operation ends (unless the user changed it).
var _filled_message: PackedStringArray = PackedStringArray(["", ""])
var _reason: Label = Label.new()
var _undo_strip: HBoxContainer = HBoxContainer.new()
var _undo_icon: TextureRect = TextureRect.new()
var _undo_label: Label = Label.new()
var _undo_button: Button = Button.new()

@onready var _summary: LineEdit = %Summary
@onready var _body: TextEdit = %Body
@onready var _amend_header: HBoxContainer = %AmendHeader
@onready var _amend_title: Label = %AmendTitle
@onready var _cancel_amend: Button = %CancelAmend
@onready var _commit_button: Button = %CommitButton
@onready var _output: TextEdit = %Output


func _ready() -> void:
	_apply_theme()
	_commit_button.icon = Actions.icon(&"changes.commit")
	_summary.text_changed.connect(func(_t: String) -> void: update_state())
	_summary.text_submitted.connect(func(_t: String) -> void: _body.grab_focus())
	_body.text_changed.connect(update_state)
	_cancel_amend.pressed.connect(func() -> void: Actions.run_action(&"changes.cancel_amend", _cancel_amend))
	_commit_button.pressed.connect(commit)
	_undo_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_undo_icon.modulate.a = 0.6
	_undo_label.theme_type_variation = &"DimLabel"
	_undo_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_undo_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_undo_label.clip_text = true
	_undo_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_undo_button.text = tr("Undo")
	_undo_button.icon = AppTheme.icon(&"Undo")
	_undo_button.pressed.connect(func() -> void: Actions.run_action(&"commit.undo", _undo_button))
	_undo_strip.add_child(_undo_icon)
	_undo_strip.add_child(_undo_label)
	_undo_strip.add_child(_undo_button)
	_commit_button.add_sibling(_undo_strip)
	_reason.theme_type_variation = &"DimLabel"
	_reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reason.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_reason.clip_text = true
	_reason.hide()
	_commit_button.add_sibling(_reason)
	_undo_strip.hide()
	update_state()


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()
	elif what == NOTIFICATION_TRANSLATION_CHANGED:
		_undo_button.text = tr("Undo")
		update_state()


func set_session(value: RepoSession) -> void:
	if session != null:
		session.job_finished.disconnect(_on_job_finished)
		session.job_cancelled.disconnect(_on_job_cancelled)
		session.head_message_loaded.disconnect(_on_head_message_loaded)
		session.status_changed.disconnect(update_state)
		session.operation_changed.disconnect(update_state)
		session.head_changed.disconnect(update_state)
		session.commit_undone.disconnect(suggest_message)
	session = value
	if session != null:
		session.job_finished.connect(_on_job_finished)
		session.job_cancelled.connect(_on_job_cancelled)
		session.head_message_loaded.connect(_on_head_message_loaded)
		session.status_changed.connect(update_state)
		session.operation_changed.connect(update_state)
		session.head_changed.connect(update_state)
		session.commit_undone.connect(suggest_message)
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


## Fills the message with `summary` and `body` unless the user wrote one.
func suggest_message(summary_text: String, body_text: String) -> void:
	if _summary.text.strip_edges().is_empty() and _body.text.strip_edges().is_empty():
		set_message(summary_text, body_text)


## The undo strip (for tests): shown, with what it says.
func undo_strip() -> HBoxContainer:
	return _undo_strip


func undo_text() -> String:
	return _undo_label.text if _undo_strip.visible else ""


func is_amend() -> bool:
	return _amending


func can_amend() -> bool:
	return session != null and session.is_ready() and not _amending and _job < 0 and _message_job < 0 \
			and not String(session.status().get("oid", "")).is_empty() and session.operation().is_empty()


func begin_amend(target: Dictionary) -> void:
	if not can_amend() or String(target.get("hash", "")) != String(session.status().get("oid", "")):
		return
	_draft_summary = _summary.text
	_draft_body = _body.text
	_amend_head = String(target["hash"])
	_amend_subject = String(target.get("subject", ""))
	_amending = true
	_output.hide()
	_message_job = session.load_head_message()
	if _message_job < 0:
		cancel_amend()
		_show_error({"title": "Could not load the commit message"})
	update_state()


func cancel_amend() -> void:
	if not _amending or is_busy():
		return
	_amending = false
	_amend_head = ""
	_amend_subject = ""
	set_message(_draft_summary, _draft_body)
	_draft_summary = ""
	_draft_body = ""
	_output.hide()


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
	if _amending:
		if _amend_head != String(session.status().get("oid", "")):
			return tr("The last commit changed. Start amend again.")
		if _message_job >= 0:
			return tr("Loading the commit message")
		if not session.operation().is_empty():
			return tr("Finish the operation in progress first")
	var reason: String = session.commit_block_reason(_amending)
	if reason == "Resolve conflicts first":
		return _resolve_reason()
	if not reason.is_empty():
		return tr(reason)
	if _summary.text.strip_edges().is_empty():
		return tr("Write a summary")
	return ""


## What the button commits: "Commit 2 files to main", "Amend commit",
## "Commit merge into main"...
func button_text() -> String:
	var mode: String = session.commit_mode() if session != null else "normal"
	if mode == "merge":
		var into: String = session.current_branch()
		return tr("Commit merge into %s") % into if not into.is_empty() else tr("Commit merge")
	if mode == "cherry_pick":
		return tr("Commit cherry-pick") if session.operation() == "cherry_pick" else tr("Commit revert")
	if _amending:
		return tr("Amend commit")
	var count: int = session.picked_count() if session != null else 0
	var files: String = tr("1 file") if count == 1 else tr("%d files") % count
	var branch: String = session.current_branch() if session != null else ""
	if branch.is_empty():
		return tr("Commit") if count == 0 else tr("Commit %s") % files
	return tr("Commit to %s") % branch if count == 0 else tr("Commit %s to %s") % [files, branch]


## The reason shown under the button, or "".
func reason_text() -> String:
	return _reason.text if _reason.visible else ""


## "Resolve login.rs first", or "Resolve 2 conflicted files first".
func _resolve_reason() -> String:
	var left: int = int(session.operation_info().get("conflicts", 0))
	if left != 1:
		return tr("Resolve %d conflicted files first") % left if left > 1 else tr("Resolve conflicts first")
	# Conflicted files are listed first, among the resolved ones.
	for row: Dictionary in session.change_rows(0, int(session.operation_info().get("resolved", 0)) + 1):
		if bool(row.get("conflicted", false)):
			return tr("Resolve %s first") % String(row["path"]).get_file()
	return tr("Resolve conflicts first")


func focus_summary() -> void:
	_summary.grab_focus()
	_summary.caret_column = _summary.text.length()


func update_state() -> void:
	if not is_node_ready():
		return
	var mode: String = session.commit_mode() if session != null else "normal"
	if _amending and not is_busy() and (session == null or mode != "normal" \
			or _amend_head != String(session.status().get("oid", ""))):
		cancel_amend()
		return
	_amend_header.visible = _amending
	_amend_title.text = tr("Amending “%s”") % _amend_subject
	_amend_title.tooltip_text = _amend_title.text
	_cancel_amend.text = tr("Cancel")
	_cancel_amend.disabled = is_busy()
	var editable: bool = not is_busy() and not (_amending and _message_job >= 0)
	_summary.editable = editable
	_body.editable = editable
	_fill_operation_message(mode)
	_update_undo_strip()
	_commit_button.disabled = not can_commit()
	_commit_button.icon = AppTheme.icon(&"GitMerge") if mode == "merge" else Actions.icon(&"changes.commit")
	if _job >= 0:
		_commit_button.text = tr("Amending…") if _amending else tr("Committing…")
	else:
		_commit_button.text = button_text()
	var shortcut: String = Actions.shortcut_label(&"changes.commit")
	var why: String = block_reason() if _job < 0 else ""
	var detail: String = button_text()
	if _amending and session != null:
		detail += tr(" with %d included file(s)") % session.picked_count()
	_commit_button.tooltip_text = why if not why.is_empty() \
			else (detail + (" (%s)" % shortcut if not shortcut.is_empty() else ""))
	_reason.text = why
	_reason.visible = not why.is_empty() and mode in ["merge", "cherry_pick"]


## Commits (or amends) with the current message. Returns whether it started.
## The progress shows on `origin`, else on the button.
func commit(origin: Control = null) -> bool:
	if not can_commit():
		return false
	_output.hide()
	var done: String = _done_text()
	_job = session.commit(_summary.text, _body.text, _amending)
	if feedback != null:
		feedback.track(session, _job, "Amending" if _amending else "Committing", done,
				origin if origin != null else _commit_button, func(_ok: bool) -> void: update_state())
	update_state()
	return _job >= 0


## git's message for the merge or cherry-pick being committed, once per
## operation, unless the user already wrote one.
func _fill_operation_message(mode: String) -> void:
	if not mode in ["merge", "cherry_pick"]:
		if not _filled_for.is_empty():
			_filled_for = ""
			_clear_filled_message()
		return
	var info: Dictionary = session.operation_info()
	var key: String = "%s:%s" % [info.get("kind", ""), info.get("other_oid", "")]
	if key == _filled_for:
		return
	_filled_for = key
	_clear_filled_message()
	var message: String = String(info.get("message", "")).strip_edges()
	var cut: int = message.find("\n")
	var summary_text: String = message if cut < 0 else message.left(cut)
	var body_text: String = "" if cut < 0 else message.substr(cut + 1).strip_edges()
	suggest_message(summary_text.strip_edges(), body_text)
	_filled_message = PackedStringArray([_summary.text, _body.text])


## Empties the box when it still holds the message an operation filled in
## (after an abort, or before the next operation's).
func _clear_filled_message() -> void:
	var filled: PackedStringArray = _filled_message
	_filled_message = PackedStringArray(["", ""])
	if filled != _filled_message and _summary.text == filled[0] and _body.text == filled[1]:
		set_message("", "")


## The last unpushed commit: a commit or merge icon, its subject and Undo.
func _update_undo_strip() -> void:
	var commit_info: Dictionary = session.undoable_commit() if session != null else {}
	_undo_strip.visible = not commit_info.is_empty() and _job < 0
	if commit_info.is_empty():
		return
	var merge: bool = bool(commit_info.get("merge", false))
	_undo_icon.texture = AppTheme.icon(&"GitMerge" if merge else &"GitCommit")
	_undo_label.text = String(commit_info["subject"])
	_undo_label.tooltip_text = String(commit_info["subject"])
	_undo_button.tooltip_text = Actions.tooltip(&"commit.undo")


## The success toast of the commit about to start: none for a merge or
## cherry-pick, which the undo strip shows.
func _done_text() -> String:
	var mode: String = session.commit_mode()
	if mode in ["merge", "cherry_pick"]:
		return ""
	var count: int = session.picked_count()
	var files: String = tr("1 file") if count == 1 else tr("%d files") % count
	var branch: String = session.current_branch()
	if _amending:
		return tr("Amended “%s”") % _amend_subject
	return tr("Committed %s to %s") % [files, branch] if not branch.is_empty() else tr("Committed %s") % files


func _on_head_message_loaded(summary_text: String, body_text: String) -> void:
	if _message_job < 0:
		return
	_message_job = -1
	if not _amending:
		update_state()
		return
	if _amend_head != String(session.status().get("oid", "")):
		cancel_amend()
		return
	_amend_subject = summary_text
	set_message(summary_text, body_text)


func _on_job_finished(job: int, label: String, ok: bool, error: Dictionary) -> void:
	if job == _message_job:
		_message_job = -1
		if _amending and not ok:
			cancel_amend()
			_show_error(error)
		update_state()
		return
	if job != _job or label != COMMIT_LABEL:
		return
	_job = -1
	if ok:
		if _amending:
			cancel_amend()
		else:
			set_message("", "")
		committed.emit()
	else:
		_show_error(error)
	update_state()


func _on_job_cancelled(job: int, label: String) -> void:
	_on_job_finished(job, label, false, {"title": "Operation cancelled"})


func _show_error(error: Dictionary) -> void:
	var stderr: String = String(error.get("stderr", "")).strip_edges()
	_output.text = stderr if not stderr.is_empty() else tr(String(error.get("title", "Commit failed")))
	_output.show()


func _apply_theme() -> void:
	_body.custom_minimum_size.y = float(get_theme_constant(&"body_height", THEME_TYPE))
	_output.custom_minimum_size.y = float(get_theme_constant(&"output_height", THEME_TYPE))
