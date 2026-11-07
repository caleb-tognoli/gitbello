class_name IgnoreOps
extends Node
## Ignoring files (M7.7, docs/IGNORE_RULES.md): the quick rules of the
## Changes menu and the Ignore dialog with its live preview, the file the rule
## goes to, and untracking the tracked files it matches. Shared rules go to a
## `.gitignore`, local ones to `info/exclude` (every worktree), global ones
## to the user's excludes file (every repository). The rules viewer's edits
## (remove a rule, stop tracking, rules from a template) and Stop ignoring
## run here too. Jobs report to `feedback`, with Undo.

const FORM: PackedScene = preload("res://ui/form_dialog/form_dialog.tscn")
## The preview waits this long after the last edit (seconds).
const PREVIEW_DELAY: float = 0.15
## Per-repository UI state of the dialog's target: 0 shared, 1 local, 2 global.
const TARGET_STATE: String = "ignore_target"
## Choices of the dialog's "Where".
const SHARED: int = 0
const LOCAL: int = 1
const GLOBAL: int = 2
const TARGET_IDS: PackedStringArray = ["shared", "local", "global"]
## The Where choices' icons and tooltips, by target.
const WHERE: Array[Array] = [
	[&"GitIgnore", "Shared with everyone in .gitignore"],
	[&"User", "Only you, in every worktree of this repository (.git/info/exclude)"],
	[&"Tools", "Every repository on this computer (your global ignore file)"],
]
## Paths listed in the preview note.
const SAMPLE: int = 3

var session: RepoSession = null:
	set = set_session
## Shows the jobs started here (null in tests that build ops alone).
var feedback: Feedback = null

var _form: FormDialog = null
var _timer: Timer = Timer.new()
## The files the dialog is about.
var _paths: PackedStringArray = PackedStringArray()
## Folders with a `.gitignore` above every path, "" (the root) first.
var _files: PackedStringArray = PackedStringArray()
## The rules offered for the chosen file (see `RepoSession.ignore_suggestions`).
var _suggestions: Array[Dictionary] = []
var _preview_job: int = -1
## The preview of the dialog's rule, {} while it loads.
var _preview: Dictionary = {}
## Quick rules started here: job id -> `{paths, kind}`, to open the dialog
## when core refuses them over tracked files.
var _quick: Dictionary[int, Dictionary] = {}
var _preview_note: Label = null
var _untrack_note: Label = null
## Fields are being set by code: their changes are not the user's.
var _setting: bool = false
## Asks before stopping tracking from the rules viewer.
var _confirm: ConfirmationDialog = ConfirmationDialog.new()
var _pending: Callable = Callable()


func _ready() -> void:
	_form = FORM.instantiate() as FormDialog
	add_child(_form)
	_form.field_changed.connect(_on_field)
	_timer.one_shot = true
	_timer.wait_time = PREVIEW_DELAY
	_timer.timeout.connect(_load_preview)
	add_child(_timer)
	_confirm.confirmed.connect(func() -> void:
		if _pending.is_valid():
			_pending.call()
		_pending = Callable())
	_confirm.canceled.connect(func() -> void: _pending = Callable())
	add_child(_confirm)


func set_session(value: RepoSession) -> void:
	if session != null and session.job_finished.is_connected(_on_job_finished):
		session.job_finished.disconnect(_on_job_finished)
		session.ignore_preview_ready.disconnect(_on_preview_ready)
	session = value
	if session != null:
		session.job_finished.connect(_on_job_finished)
		session.ignore_preview_ready.connect(_on_preview_ready)


func form() -> FormDialog:
	return _form


## The rule a quick entry writes for `paths` (`kind` is `file`, `extension`
## or `folder`, the nearest one), or {} when there is none.
func quick_rule(paths: PackedStringArray, kind: String) -> Dictionary:
	if session == null or paths.is_empty():
		return {}
	for suggestion: Dictionary in session.ignore_suggestions(paths, ""):
		if String(suggestion["kind"]) == kind:
			return suggestion
	return {}


## The quick entry's menu label for `paths`, or "" when it does not apply.
func quick_label(paths: PackedStringArray, kind: String) -> String:
	var suggestion: Dictionary = quick_rule(paths, kind)
	if suggestion.is_empty():
		return ""
	var subject: String = String(suggestion["subject"])
	match kind:
		"file":
			return tr("Ignore \"%s\"") % subject if paths.size() == 1 else tr("Ignore these %d files") % paths.size()
		"extension":
			return tr("Ignore all %s files") % subject
		"folder":
			return tr("Ignore folder \"%s\"") % String(suggestion["pattern"]).trim_prefix("/")
	return ""


## Adds the quick rule `kind` for `paths` to the root `.gitignore`. When it
## matches tracked files, core refuses and the dialog opens on it instead.
func ignore_quick(paths: PackedStringArray, kind: String) -> void:
	var suggestion: Dictionary = quick_rule(paths, kind)
	if suggestion.is_empty():
		return
	var quick: Dictionary = {"pattern": suggestion["pattern"], "target": "shared", "dir": ""}
	var job: int = session.add_ignore_rule(quick, "refuse")
	if job < 0:
		return
	_quick[job] = {"paths": paths, "kind": kind}
	_track(job, quick, false)


## Adds `/folder/` to the root `.gitignore` (the Changes hint). When it
## matches tracked files, core refuses and the dialog opens on it instead.
func ignore_folder(folder: String) -> void:
	if session == null or folder.is_empty():
		return
	# The nearest folder rule of a file inside it, escaped as rules need.
	var suggestion: Dictionary = quick_rule(PackedStringArray([folder.path_join("x")]), "folder")
	if suggestion.is_empty():
		return
	var quick: Dictionary = {"pattern": suggestion["pattern"], "target": "shared", "dir": ""}
	var job: int = session.add_ignore_rule(quick, "refuse")
	if job < 0:
		return
	_quick[job] = {"pattern": quick["pattern"]}
	_track(job, quick, false)


## Opens the Ignore dialog for `paths`, on the rule of `kind` ("" for the narrowest).
func open(paths: PackedStringArray, kind: String = "") -> void:
	if session == null or paths.is_empty():
		return
	_paths = paths
	_files = session.ignore_files(paths)
	var where: int = clampi(int(Core.repo_ui_state(session.repo_path()).get(TARGET_STATE, SHARED)), SHARED, GLOBAL)
	_build("Ignore files", where, kind)


## Opens the Ignore dialog on `pattern` (several lines, such as the rules a
## template adds), for the root `.gitignore`.
func open_pattern(pattern: String, title: String = "Add ignore rules") -> void:
	if session == null:
		return
	_paths = PackedStringArray()
	_files = PackedStringArray([""])
	_build(title, SHARED, "")
	_set_pattern(pattern)
	(_form.field("rule") as OptionButton).selected = _suggestions.size()
	_load_preview()


func _build(title: String, where: int, kind: String) -> void:
	_preview = {}
	_setting = true
	_form.begin(title, "Ignore", _submit)
	_form.set_ok_icon(AppTheme.icon(&"GitIgnore"))
	var choice: OptionButton = _form.add_choice("where", "Where", PackedStringArray([tr("This repository"),
			tr("My computer"), tr("Global setting")]), where)
	for i: int in WHERE.size():
		choice.set_item_icon(i, AppTheme.icon(WHERE[i][0]))
		choice.set_item_tooltip(i, tr(String(WHERE[i][1])))
	var files: PackedStringArray = PackedStringArray()
	for dir: String in _files:
		files.append(dir.path_join(".gitignore") if not dir.is_empty() else ".gitignore")
	_form.add_choice("file", "File", files)
	_form.add_choice("rule", "Ignore", PackedStringArray())
	_form.add_text("pattern", "Pattern")
	_preview_note = _form.add_note("")
	_form.add_check("untrack", "Also stop tracking the files that match", where == SHARED)
	_untrack_note = _form.add_note("They stay on your disk. Once you commit and push, git deletes them from the disk of everyone who pulls.")
	_form.validator = _validate
	_fill_rules(kind)
	_setting = false
	_update_fields()
	_form.open()
	_load_preview()


## The dialog's rule: `{pattern, target, dir}`.
func rule() -> Dictionary:
	var values: Dictionary = _form.values()
	var where: int = clampi(_choice("where"), SHARED, GLOBAL)
	var file: int = _choice("file")
	return {
		"pattern": String(values.get("pattern", "")).strip_edges(),
		"target": TARGET_IDS[where],
		"dir": "" if where != SHARED or file < 0 or file >= _files.size() else _files[file],
	}


## The dialog's preview, {} while it loads (for tests).
func preview() -> Dictionary:
	return _preview


func _choice(key: String) -> int:
	var choice: OptionButton = _form.field(key) as OptionButton
	return choice.selected if choice != null else -1


## Fills the rule choices for the chosen file, selecting `kind` (or keeping
## the selected rule: the same pattern, else the same kind and level), and
## sets the pattern to it.
func _fill_rules(kind: String) -> void:
	var choice: OptionButton = _form.field("rule") as OptionButton
	var level: int = 0
	var pattern: String = ""
	if kind.is_empty() and choice.selected >= 0 and choice.selected < _suggestions.size():
		kind = String(_suggestions[choice.selected]["kind"])
		level = int(_suggestions[choice.selected]["level"])
		pattern = String(_suggestions[choice.selected]["pattern"])
	_suggestions.assign(session.ignore_suggestions(_paths, String(rule()["dir"])))
	choice.clear()
	var selected: int = -1
	for i: int in _suggestions.size():
		choice.add_item(_rule_label(_suggestions[i]))
		if String(_suggestions[i]["pattern"]) == pattern:
			selected = i
	for i: int in _suggestions.size():
		var same_kind: bool = String(_suggestions[i]["kind"]) == kind
		if selected < 0 and same_kind and int(_suggestions[i]["level"]) == level:
			selected = i
	for i: int in _suggestions.size():
		if selected < 0 and String(_suggestions[i]["kind"]) == kind:
			selected = i
	selected = maxi(selected, 0)
	choice.add_item(tr("Custom pattern"))
	choice.selected = selected
	_set_pattern(String(_suggestions[selected]["pattern"]) if not _suggestions.is_empty() else "")


func _rule_label(suggestion: Dictionary) -> String:
	var subject: String = String(suggestion["subject"])
	var pattern: String = String(suggestion["pattern"])
	match String(suggestion["kind"]):
		"file":
			return tr("This file (%s)") % subject if _paths.size() == 1 else tr("These %d files") % _paths.size()
		"name":
			return tr("Files named %s, in any folder") % subject
		"extension":
			return tr("All %s files") % subject
		"extension_below":
			return tr("%s files in %s and below") % [subject, pattern.get_slice("/**", 0).trim_prefix("/") + "/"]
		"folder":
			return tr("The folder %s") % pattern.trim_prefix("/")
	return pattern


func _set_pattern(text: String) -> void:
	var was: bool = _setting
	_setting = true
	(_form.field("pattern") as TextEdit).text = text
	_setting = was


func _on_field(key: String) -> void:
	if _setting:
		return
	match key:
		"where", "file":
			if key == "where":
				(_form.field("untrack") as CheckBox).button_pressed = _choice("where") == SHARED
			_fill_rules("")
			_update_fields()
		"rule":
			var index: int = _choice("rule")
			if index < _suggestions.size():
				_set_pattern(String(_suggestions[index]["pattern"]))
		"pattern":
			# An edited pattern is no longer one of the offered rules.
			var index: int = _choice("rule")
			var text: String = String(_form.values()["pattern"]).strip_edges()
			if index < _suggestions.size() and text != String(_suggestions[index]["pattern"]):
				(_form.field("rule") as OptionButton).selected = _suggestions.size()
		"untrack":
			_update_fields()
			return
	# A preview asked for before this edit is stale when it lands.
	_preview_job = -1
	_preview = {}
	_update_fields()
	_timer.start()


func _load_preview() -> void:
	if session == null or not _form.visible:
		return
	_preview = {}
	_preview_job = session.load_ignore_preview(rule())
	_update_fields()


func _on_preview_ready(job: int) -> void:
	if job != _preview_job or not _form.visible:
		return
	_preview = session.ignore_preview()
	_update_fields()


## Shows the preview, the file choice (shared rules, with nested files) and
## the untrack check (tracked files match) with its warning.
func _update_fields() -> void:
	_form.set_field_visible("file", _choice("where") == SHARED and _files.size() > 1)
	_form.set_field_visible("rule", not _paths.is_empty())
	var tracked: int = int(_preview.get("tracked_count", 0))
	var untrack: CheckBox = _form.field("untrack") as CheckBox
	if tracked == 1:
		untrack.text = tr("Also stop tracking the 1 file that matches")
	elif tracked > 1:
		untrack.text = tr("Also stop tracking %d files that match") % tracked
	_form.set_field_visible("untrack", tracked > 0)
	_show_note(_untrack_note, tracked > 0 and untrack.button_pressed)
	_preview_note.text = _preview_text()
	_show_note(_preview_note, not _preview_note.text.is_empty())
	_form.revalidate()


## Shows or hides a note with the empty label cell beside it.
func _show_note(note: Label, shown: bool) -> void:
	if note.visible == shown:
		return
	note.visible = shown
	if note.get_index() > 0:
		(note.get_parent().get_child(note.get_index() - 1) as Control).visible = shown
	if _form.visible:
		# The dialog wraps its contents: a zero height becomes the least that fits.
		_form.size = Vector2i(_form.size.x, 0)


func _preview_text() -> String:
	# Nothing while it loads or when no changed file matches.
	if _preview.is_empty():
		return ""
	var lines: PackedStringArray = PackedStringArray()
	var hidden: int = int(_preview["hidden_count"])
	if bool(_preview["exists"]):
		lines.append(tr("This rule is already in the file."))
	elif hidden > 0:
		var sample: PackedStringArray = (_preview["hidden_sample"] as PackedStringArray).slice(0, SAMPLE)
		var more: String = "…" if hidden > sample.size() else ""
		var text: String = tr("Hides 1 changed file: %s") if hidden == 1 else tr("Hides %d changed files: %s")
		lines.append(text % ([sample[0]] if hidden == 1 else [hidden, ", ".join(sample) + more]))
	match String(_preview["warning"]):
		"matches_everything":
			lines.append(tr("This rule ignores everything in its folder."))
		"negation":
			lines.append(tr("A rule starting with ! cannot bring back a file whose folder is ignored."))
	return "\n".join(lines)


func _validate(values: Dictionary) -> String:
	if String(values.get("pattern", "")).strip_edges().is_empty():
		return "Write a pattern."
	if String(_preview.get("warning", "")) == "empty":
		return "Write a pattern."
	var untracking: bool = (_form.field("untrack") as CheckBox).visible and bool(values.get("untrack", false))
	if bool(_preview.get("exists", false)) and not untracking:
		return "This rule is already in the file."
	return ""


func _submit(_values: Dictionary) -> void:
	var untrack: CheckBox = _form.field("untrack") as CheckBox
	var remove: bool = untrack.visible and untrack.button_pressed
	var chosen: Dictionary = rule()
	Core.set_repo_ui_state(session.repo_path(), TARGET_STATE, _choice("where"))
	var job: int = session.add_ignore_rule(chosen, "remove" if remove else "keep")
	_track(job, chosen, remove)


func _track(job: int, chosen: Dictionary, untracking: bool) -> void:
	if feedback == null:
		return
	var lines: PackedStringArray = String(chosen["pattern"]).split("\n", false)
	var shown: String = lines[0] + (" …" if lines.size() > 1 else "") if not lines.is_empty() else ""
	var done: String = tr("Added %s to the local ignore list") % shown
	if String(chosen["target"]) == "shared":
		var dir: String = String(chosen["dir"])
		done = tr("Added %s to %s") % [shown, dir.path_join(".gitignore") if not dir.is_empty() else ".gitignore"]
	elif String(chosen["target"]) == "global":
		done = tr("Added %s to your global ignore file") % shown
	if untracking:
		done = tr("%s and stopped tracking the files that match") % done
	feedback.track(session, job, "Ignoring", done, null, Callable(), undo)


func can_undo() -> bool:
	return session != null and session.can_undo_ignore()


## Removes line `line` (an index) of source `source` of the rules viewer;
## `text` is the line, for the toast.
func remove_rule(source: int, line: int, text: String) -> void:
	var job: int = session.remove_ignore_rule(source, line) if session != null else -1
	if job >= 0 and feedback != null:
		feedback.track(session, job, "Removing the rule", tr("Removed %s") % text, null, Callable(), undo)


## Asks, then stops tracking the `count` tracked files a viewer line matches.
func confirm_untrack(source: int, line: int, count: int, text: String) -> void:
	if session == null or count <= 0:
		return
	_confirm.title = tr("Stop tracking")
	_confirm.dialog_text = (tr("Stop tracking the 1 file that %s matches?") % text if count == 1
			else tr("Stop tracking the %d files that %s matches?") % [count, text])
	_confirm.ok_button_text = tr("Stop tracking")
	_pending = func() -> void:
		var job: int = session.untrack_ignored(source, line)
		if job >= 0 and feedback != null:
			feedback.track(session, job, "Stopping tracking", tr("Stopped tracking the files %s matches") % text,
					null, Callable(), undo)
	_confirm.popup_centered()


## The confirmation of `confirm_untrack` (for tests).
func untrack_confirmation() -> ConfirmationDialog:
	return _confirm


## Makes git stop ignoring `path` (a row of "Show ignored files"): removes
## the line that names it, or adds a `!` line after it.
func stop_ignoring(path: String) -> void:
	if session == null:
		return
	var plan: Dictionary = session.stop_ignoring_plan(path)
	if plan.is_empty():
		return
	var job: int = session.stop_ignoring(path)
	if job < 0 or feedback == null:
		return
	var where: String = String(plan["source"])
	var done: String = tr("Removed %s from %s") % [String(plan["pattern"]), where]
	if String(plan["action"]) == "negate":
		var file: String = "info/exclude" if String(plan["target"]) == "local" else where
		done = tr("Added %s to %s") % [String(plan["negation"]), file]
	feedback.track(session, job, "Stopping ignoring", done, null, Callable(), undo)


## Takes back the most recent rule and what it untracked.
func undo() -> void:
	if not can_undo():
		return
	var job: int = session.undo_ignore()
	if feedback != null:
		feedback.track(session, job, "Undoing the ignore rule")


func _on_job_finished(job: int, _label: String, ok: bool, error: Dictionary) -> void:
	if job == _preview_job and not ok and _form.visible:
		# Let the user go on without the preview.
		_preview = {"hidden_count": 0, "hidden_sample": PackedStringArray(), "tracked_count": 0,
				"exists": false, "warning": ""}
		_update_fields()
	if not _quick.has(job):
		return
	var quick: Dictionary = _quick[job]
	_quick.erase(job)
	if not ok and String(error.get("kind", "")) == "tracked_matches":
		if quick.has("pattern"):
			open_pattern(String(quick["pattern"]), "Ignore files")
		else:
			open(quick["paths"] as PackedStringArray, String(quick["kind"]))
