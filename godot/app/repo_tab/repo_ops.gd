class_name RepoOps
extends Node
## Sync, branch, tag, remote, commit and worktree operations of one worktree,
## with the dialogs they need (PLAN §4): names for new branches and tags,
## confirmations for deletes, force pushes and cherry-picks, the switch with
## local changes (bring them along, or leave them on the branch as a shelf),
## shelving, the Sync button's choice, the merge with its preview, finishing
## or aborting an operation, resolving conflicts, undoing a commit, and the
## new-task and cleanup flows for worktrees. Every job it starts goes to
## `feedback`, with the control that started the flow.

## Something the user should read (an editor that did not start, ...).
signal notice(title: String, message: String)
## A worktree should show (a new task, or the user asked).
signal open_requested(path: String)
## A worktree is about to be removed: close its view, if open.
signal close_requested(path: String)
## The user confirmed deleting worktree `path` (`force` for changes or a
## lock), then `branch` unless empty: run it from another worktree (see
## `delete_worktree`).
signal delete_requested(path: String, force: bool, branch: String)
## The Changes view should show; with `conflicts`, at the first conflicted file.
signal changes_requested(conflicts: bool)
## A commit message to offer in the commit box (after a squash merge).
signal message_suggested(summary: String, body: String)

const FORM: PackedScene = preload("res://ui/form_dialog/form_dialog.tscn")
## Choice in the upstream dialog that removes the upstream.
const NO_UPSTREAM: String = "(none)"

var session: RepoSession = null:
	set = set_session
## Shows the progress and results of the jobs started here (null in tests
## that build ops alone).
var feedback: Feedback = null

var _form: FormDialog = null
var _confirm: ConfirmationDialog = ConfirmationDialog.new()
var _on_confirm: Callable = Callable()
## Checkouts started here: job id -> `{name, start, origin}`; `start` is
## `func(changes: String) -> int` (`keep`, `bring` or `leave`).
var _checkouts: Dictionary[int, Dictionary] = {}
## Branch deletes started here: job id -> branch name.
var _deletes: Dictionary[int, String] = {}
## Tags to push once created: job id -> tag name.
var _tag_pushes: Dictionary[int, String] = {}
## Branches to delete once their worktree is deleted: job id -> branch.
var _worktree_branches: Dictionary[int, String] = {}
## New tasks and added worktrees started here, shown once created: job id -> path.
var _tasks: Dictionary[int, String] = {}
## Which flow the form shows (`task`, `cleanup`, ...), for field changes.
var _form_kind: String = ""
## The new-task folder was edited by hand: stop following the branch name.
var _folder_edited: bool = false
## A folder picked for new tasks to go in (its name still follows the
## branch), or "" for the template's.
var _folder_parent: String = ""
## The remote branch the typed new-task name matches (`origin/<name>`), or "".
var _remote_match: String = ""
var _cleanup_requested: bool = false
var _cleanup_list: Array[Dictionary] = []
## Switching with local changes: bring them (OK) or leave them (a button).
var _switch: ConfirmationDialog = ConfirmationDialog.new()
var _leave_button: Button = null
## The checkout the switch dialog is about: `{name, start, origin}`.
var _pending_switch: Dictionary = {}
## The merge the dialog is about: `{target, shown, origin}`.
var _merge: Dictionary = {}
## Why the merge dialog cannot merge yet ("" when it can).
var _merge_reason: String = ""
var _merge_status: Label = null
var _merge_status_icon: TextureRect = null
## Turns the status icon while the preview loads.
var _merge_spin: Tween = null
var _merge_conflicts: VBoxContainer = null
var _merge_callout: Label = null
var _merge_commits: VBoxContainer = null
var _merge_commits_toggle: Button = null
## Merges started here: job id -> `{target, shown, mode, commits}`.
var _merges: Dictionary[int, Dictionary] = {}
## Undoing a merge commit: keep its changes (OK) or remove the merge.
var _undo_merge: ConfirmationDialog = ConfirmationDialog.new()
var _undo_question: Label = Label.new()
var _keep_merge_button: Button = null
var _remove_merge_button: Button = null
var _pending_undo: Dictionary = {}


func _ready() -> void:
	_form = FORM.instantiate() as FormDialog
	add_child(_form)
	_form.field_changed.connect(_on_form_field)
	_confirm.dialog_autowrap = true
	_confirm.confirmed.connect(_on_confirmed)
	_confirm.get_ok_button().theme_type_variation = &"PrimaryButton"
	add_child(_confirm)
	_switch.title = tr("Switch with local changes")
	_switch.dialog_autowrap = true
	_switch.get_ok_button().theme_type_variation = &"PrimaryButton"
	_leave_button = _switch.add_button(tr("Leave them"), false, "leave")
	_switch.confirmed.connect(func() -> void: _answer_switch("bring"))
	_switch.custom_action.connect(func(action: StringName) -> void:
		if action == &"leave":
			_switch.hide()
			_answer_switch("leave"))
	add_child(_switch)
	# Two choices as rows (icon, title, hint), and Cancel.
	_undo_merge.title = "Undo merge"
	_undo_merge.get_ok_button().hide()
	var choices: VBoxContainer = VBoxContainer.new()
	_undo_question.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	choices.add_child(_undo_question)
	_keep_merge_button = _choice_row(&"FileModified", "Keep the changes")
	_keep_merge_button.pressed.connect(func() -> void: _choose_undo("keep_changes"))
	choices.add_child(_keep_merge_button)
	_remove_merge_button = _choice_row(&"History", "Remove the merge")
	_remove_merge_button.pressed.connect(func() -> void: _choose_undo("remove_merge"))
	choices.add_child(_remove_merge_button)
	_undo_merge.add_child(choices)
	add_child(_undo_merge)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_switch.title = tr("Switch with local changes")


func set_session(value: RepoSession) -> void:
	if session != null and session.job_finished.is_connected(_on_job_finished):
		session.job_finished.disconnect(_on_job_finished)
		session.cleanup_loaded.disconnect(_on_cleanup_loaded)
		session.merge_preview_ready.disconnect(_on_merge_preview)
	session = value
	if session != null:
		session.job_finished.connect(_on_job_finished)
		session.cleanup_loaded.connect(_on_cleanup_loaded)
		session.merge_preview_ready.connect(_on_merge_preview)


func form() -> FormDialog:
	return _form


func confirm_dialog() -> ConfirmationDialog:
	return _confirm


## The bring-or-leave dialog of a switch with local changes.
func switch_dialog() -> ConfirmationDialog:
	return _switch


## The keep-or-remove dialog of undoing a merge commit.
func undo_merge_dialog() -> ConfirmationDialog:
	return _undo_merge


func keep_merge_button() -> Button:
	return _keep_merge_button


func remove_merge_button() -> Button:
	return _remove_merge_button


## A dialog choice: a full-width button with an icon, a title and a one-line
## hint under it (see `_set_choice_hint`).
func _choice_row(icon: StringName, title: String) -> Button:
	var button: Button = Button.new()
	button.theme_type_variation = &"ChoiceRow"
	var box: MarginContainer = MarginContainer.new()
	box.theme_type_variation = &"ChoiceRowBox"
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row: HBoxContainer = HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var picture: TextureRect = _form_icon(icon)
	picture.name = "Icon"
	row.add_child(picture)
	var lines: VBoxContainer = VBoxContainer.new()
	lines.theme_type_variation = &"ChoiceRowLines"
	lines.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title_label: Label = Label.new()
	title_label.text = title
	lines.add_child(title_label)
	var hint_label: Label = Label.new()
	hint_label.name = "Hint"
	hint_label.theme_type_variation = &"DimLabel"
	hint_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lines.add_child(hint_label)
	row.add_child(lines)
	box.add_child(row)
	button.add_child(box)
	box.minimum_size_changed.connect(func() -> void:
		button.custom_minimum_size.y = box.get_combined_minimum_size().y)
	return button


func _set_choice_hint(button: Button, hint: String) -> void:
	(button.find_child("Hint", true, false) as Label).text = hint
	button.tooltip_text = hint


func _choose_undo(mode: String) -> void:
	_undo_merge.hide()
	_answer_undo(mode)


func leave_button() -> Button:
	return _leave_button


## Errors a dialog here follows up (stash and switch, delete anyway, a merge
## preview that failed), or the banner does (a merge, cherry-pick or revert
## stopped at conflicts), so they need no toast.
func handles_error(error: Dictionary) -> bool:
	var kind: String = String(error.get("kind", ""))
	var command: String = String(error.get("command", ""))
	var stopped: bool = kind == "conflict" and not command.contains("--abort") \
			and (command.contains("merge ") or command.begins_with("cherry-pick") or command.begins_with("revert"))
	# The merge dialog says why its preview failed.
	var previewing: bool = _form_kind == "merge" and _form.visible and (command == "merge"
			or command.begins_with("merge-tree") or command.begins_with("merge-base") or command.begins_with("rev-parse"))
	return (kind == "local_changes" and command.begins_with("switch")) \
			or (kind == "not_fully_merged" and command.begins_with("branch")) or stopped or previewing


# --- Sync ---------------------------------------------------------------------

## What the Sync button does now (PLAN §4): `publish`, `pull`, `push`, `sync`
## (pull then push), or `fetch`.
func sync_state() -> String:
	if session == null or not session.is_ready() or session.current_branch().is_empty():
		return "fetch"
	var head: Dictionary = _branch_ref("branch", session.current_branch())
	if String(head.get("upstream", "")).is_empty():
		return "publish" if not session.default_remote().is_empty() else "fetch"
	var ahead: int = int(head.get("ahead", 0))
	var behind: int = int(head.get("behind", 0))
	if ahead > 0 and behind > 0:
		return "sync"
	if behind > 0:
		return "pull"
	if ahead > 0:
		return "push"
	return "fetch"


## The Sync button: publish, pull, push, pull then push, or fetch. With the
## pull mode `ff-only`, diverged branches cannot fast-forward, so it offers
## merge or rebase (then the push) instead of failing.
func sync() -> void:
	match sync_state():
		"publish", "push":
			push()
		"pull":
			pull()
		"fetch":
			fetch()
		"sync":
			var origin: Control = Actions.origin()
			var mode: String = Core.pull_mode()
			if mode != "ff-only":
				_pull_then_push(mode, origin)
				return
			var fixes: Array[Dictionary] = [
				{"label": "Pull (merge)", "run": func() -> void: _pull_then_push("merge", origin)},
				{"label": "Pull (rebase)", "run": func() -> void: _pull_then_push("rebase", origin)},
			]
			if feedback != null and feedback.toasts != null:
				feedback.toasts.show_toast(tr("%s has diverged from its upstream") % session.current_branch(),
						tr("Both sides have new commits, so a fast-forward is not possible. Merge or rebase, then push."),
						"", fixes)


func _pull_then_push(mode: String, origin: Control) -> void:
	var branch: String = session.current_branch()
	var then_push: Callable = func(ok: bool) -> void:
		if ok:
			_track(session.push(false), tr("Pushing %s") % branch,
					tr("Synced %s with %s") % [branch, session.default_remote()], Callable(), origin)
	_track(session.pull(mode), tr("Pulling %s") % branch, "", then_push, origin)


func fetch() -> int:
	return _track(session.fetch(), tr("Fetching %s") % session.display_name())


## `mode` is `ff-only`, `merge`, `rebase`, or empty for the configured one.
func pull(mode: String = "") -> int:
	var branch: String = session.current_branch()
	return _track(session.pull(mode), tr("Pulling %s") % branch, tr("Pulled into %s") % branch)


## Pushes the current branch; one without an upstream is published (the push
## sets it).
func push() -> int:
	var branch: String = session.current_branch()
	var remote: String = session.default_remote()
	return _track(session.push(false), tr("Pushing %s") % branch, tr("Pushed %s to %s") % [branch, remote])


func force_push() -> void:
	var branch: String = session.current_branch()
	var origin: Control = Actions.origin()
	_ask("Force push", tr("Replace %s on %s with your local branch?\nThis is refused if the remote branch has commits you have not fetched.") % [
		branch, session.default_remote()], "Force push", func() -> void:
			_track(session.push(true), tr("Force pushing %s") % branch, tr("Force pushed %s") % branch, Callable(), origin))


# --- Checkout -------------------------------------------------------------------

## Checks out `name`; with local changes, asks first whether to bring them
## or leave them (then returns -1: the job starts on the answer).
func checkout_branch(branch: String) -> int:
	return _checkout(branch, func(changes: String) -> int: return session.checkout_branch(branch, changes))


## `ref_name` is a remote-tracking ref (`refs/remotes/origin/x`).
func checkout_remote(ref_name: String) -> int:
	var shown: String = ref_name.trim_prefix("refs/remotes/")
	return _checkout(shown, func(changes: String) -> int: return session.checkout_remote(ref_name, changes))


func checkout_commit(oid: String) -> void:
	_ask("Check out commit", tr("Check out %s?\nHEAD will be detached: new commits are not on any branch until you create one.") % oid.left(7),
			"Check out", _checkout_detached.bind(oid))


func _checkout_detached(oid: String) -> void:
	_checkout(oid.left(7), func(changes: String) -> int: return session.checkout_commit(oid, changes))


func _checkout(shown: String, start: Callable) -> int:
	var origin: Control = Actions.origin()
	if session.change_count() > 0:
		_ask_switch(shown, start, origin)
		return -1
	return _start_checkout(shown, start, "keep", origin)


## Asks whether to bring the local changes to `name` or leave them here.
func _ask_switch(shown: String, start: Callable, origin: Control) -> void:
	_pending_switch = {"name": shown, "start": start, "origin": origin}
	var here: String = _here()
	_switch.dialog_text = tr("You have local changes. Bring them to %s, or leave them on %s? Left changes are shelved and offered back when you return.") % [shown, here]
	_switch.ok_button_text = tr("Bring them to %s") % shown
	_leave_button.text = tr("Leave them on %s") % here
	_switch.popup_centered()
	_switch.get_ok_button().grab_focus()


func _answer_switch(changes: String) -> void:
	if _pending_switch.is_empty():
		return
	var entry: Dictionary = _pending_switch
	_pending_switch = {}
	_start_checkout(String(entry["name"]), entry["start"], changes, entry.get("origin") as Control)


func _start_checkout(shown: String, start: Callable, changes: String, origin: Control) -> int:
	var job: int = start.call(changes)
	if job >= 0:
		_checkouts[job] = {"name": shown, "start": start, "origin": origin}
	var done: String = tr("Switched to %s") % shown
	if changes == "bring":
		done = tr("Switched to %s with your changes") % shown
	elif changes == "leave":
		done = tr("Switched to %s; your changes stay on %s") % [shown, _here()]
	return _track(job, tr("Switching to %s") % shown, done, Callable(), origin)


## The current branch's name, or "this commit" when detached.
func _here() -> String:
	var branch: String = session.current_branch()
	return branch if not branch.is_empty() else tr("this commit")


# --- Shelves (PLAN §4 Shelves) ----------------------------------------------------

## Asks for a name, then shelves `paths` on the current branch.
func shelve(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	var what: String = paths[0].get_file() if paths.size() == 1 else tr("%d files") % paths.size()
	_begin_form("shelve", "Shelve changes", "Shelve", _shelve.bind(paths))
	_form.add_note(tr("%s will be put aside on %s and removed from the working copy.") % [what, _here()])
	_form.add_line("name", "Name", tr("Changes to %s") % what)
	_form.validator = func(values: Dictionary) -> String:
		return tr("Name the shelf.") if String(values["name"]).strip_edges().is_empty() else ""
	_form.open()


func _shelve(values: Dictionary, paths: PackedStringArray) -> void:
	var shelf_name: String = String(values["name"]).strip_edges()
	_track(session.shelve(paths, shelf_name), "Shelving", tr("Shelved “%s” on %s") % [shelf_name, _here()])


## `shelf` as in `RepoSession.shelves()`.
func restore_shelf(shelf: Dictionary) -> int:
	var shelf_name: String = String(shelf["name"])
	return _track(session.restore_shelf(String(shelf["oid"])), tr("Restoring “%s”") % shelf_name, tr("Restored “%s”") % shelf_name)


func rename_shelf(shelf: Dictionary, shelf_name: String) -> void:
	if not shelf_name.is_empty() and shelf_name != String(shelf["name"]):
		_track(session.rename_shelf(String(shelf["oid"]), shelf_name), "Renaming the shelf", tr("Renamed the shelf to “%s”") % shelf_name)


func restore_shelf_file(shelf: Dictionary, path: String) -> void:
	_track(session.restore_shelf_file(String(shelf["oid"]), path),
			tr("Restoring %s") % path.get_file(), tr("Restored %s") % path.get_file())


func discard_shelf_file(shelf: Dictionary, path: String) -> void:
	_ask("Discard shelved file", tr("Discard %s from “%s”? You can undo this discard.") % [path, shelf["name"]], "Discard",
			func() -> void:
				_track(session.discard_shelf_file(String(shelf["oid"]), path), "Discarding shelved file",
						tr("Discarded %s from the shelf") % path.get_file(), Callable(), null, undo_shelf_discard), true)


func discard_shelf(shelf: Dictionary) -> void:
	var shelf_name: String = String(shelf["name"])
	_ask("Discard shelf", tr("Discard the shelf “%s”? Its changes are lost unless you undo right away.") % shelf_name, "Discard",
			func() -> void:
				_track(session.discard_shelf(String(shelf["oid"])), "Discarding the shelf",
						tr("Discarded the shelf “%s”") % shelf_name, Callable(), null, undo_shelf_discard), true)


func undo_shelf_discard() -> void:
	if session.can_undo_shelf_discard():
		_track(session.undo_shelf_discard(), "Restoring the shelf", "The shelf is back")


# --- Branches -----------------------------------------------------------------

## Asks for a name and creates a branch at `start` (a ref or hash, shown as
## `start_label`).
func new_branch(start: String, start_label: String) -> void:
	_begin_form("branch", "New branch", "Create branch", _create_branch.bind(start))
	_form.add_note(tr("Starting at %s.") % start_label)
	_form.add_line("name", "Name", "", true)
	_form.add_check("checkout", "Check out the new branch", true)
	_form.validator = _check_branch_name.bind("")
	_form.open()


func _create_branch(values: Dictionary, start: String) -> void:
	var branch: String = String(values["name"])
	var here: bool = start == "HEAD" or start == "refs/heads/" + session.current_branch()
	if bool(values["checkout"]) and here:
		# From the current commit, local changes simply come along.
		_start_checkout(branch, _create_and_switch.bind(branch, start), "keep", Actions.origin())
	elif bool(values["checkout"]):
		_checkout(branch, _create_and_switch.bind(branch, start))
	else:
		_track(session.create_branch(branch, start, false), tr("Creating %s") % branch, tr("Created branch %s") % branch)


## Creates `name` at `start` and switches to it; bringing or leaving local
## changes takes two steps (create, then a checkout that handles them).
func _create_and_switch(changes: String, branch: String, start: String) -> int:
	if changes == "keep":
		return session.create_branch(branch, start, true)
	session.create_branch(branch, start, false)
	return session.checkout_branch(branch, changes)


func rename_branch(branch: String) -> void:
	_begin_form("rename", "Rename branch", "Rename", _rename_branch.bind(branch))
	_form.add_note(tr("Renaming %s.") % branch)
	_form.add_line("name", "New name", branch, true)
	_form.validator = _check_branch_name.bind(branch)
	_form.open()


func _rename_branch(values: Dictionary, old: String) -> void:
	var new: String = String(values["name"])
	if new != old:
		_track(session.rename_branch(old, new), tr("Renaming %s") % old, tr("Renamed %s to %s") % [old, new])


func delete_branch(branch: String) -> void:
	_ask("Delete branch", tr("Delete branch %s?") % branch, "Delete", _delete_branch.bind(branch), true)


func _delete_branch(branch: String) -> void:
	var job: int = session.delete_branch(branch, false)
	if job >= 0:
		_deletes[job] = branch
	_track(job, tr("Deleting %s") % branch, tr("Deleted branch %s") % branch)


## Lets the user pick the remote branch `branch` tracks (or none).
func set_upstream(branch: String) -> void:
	var current: String = String(_branch_ref("branch", branch).get("upstream", ""))
	var options: PackedStringArray = PackedStringArray([NO_UPSTREAM])
	var selected: int = 0
	for ref: Dictionary in session.branch_refs():
		if String(ref["kind"]) == "remote":
			options.append(String(ref["short_name"]))
			if String(ref["short_name"]) == current:
				selected = options.size() - 1
	_begin_form("upstream", "Set upstream", "Save", _save_upstream.bind(branch))
	_form.add_note(tr("The branch %s follows.") % branch)
	_form.add_choice("upstream", "Upstream", options, selected)
	_form.open()


func _save_upstream(values: Dictionary, branch: String) -> void:
	var upstream: String = String(values["upstream"])
	var none: bool = upstream == NO_UPSTREAM
	_track(session.set_upstream(branch, "" if none else upstream), "Setting the upstream",
			tr("%s no longer follows a remote branch") % branch if none else tr("%s now follows %s") % [branch, upstream])


func _check_branch_name(values: Dictionary, current: String) -> String:
	var branch: String = String(values.get("name", ""))
	var error: String = Core.ref_name_error(branch)
	if not error.is_empty():
		return tr(error)
	if branch != current and not _branch_ref("branch", branch).is_empty():
		return tr("A branch named %s already exists.") % branch
	return ""


func _branch_ref(kind: String, short_name: String) -> Dictionary:
	for ref: Dictionary in session.branch_refs():
		if String(ref["kind"]) == kind and String(ref["short_name"]) == short_name:
			return ref
	return {}


# --- Tags ---------------------------------------------------------------------

## Asks for a name (and an optional message, which makes it annotated) and
## tags `target` (shown as `target_label`).
func new_tag(target: String, target_label: String) -> void:
	_begin_form("tag", "New tag", "Create tag", _create_tag.bind(target))
	_form.add_note(tr("On %s.") % target_label)
	_form.add_line("name", "Name", "", true)
	_form.add_text("message", "Message", "", "Optional; a message makes an annotated tag")
	var remote: String = session.default_remote()
	if not remote.is_empty():
		_form.add_check("push", tr("Push it to %s") % remote, false)
	_form.validator = _check_tag_name
	_form.open()


func _create_tag(values: Dictionary, target: String) -> void:
	var tag_name: String = String(values["name"])
	var job: int = session.create_tag(tag_name, target, String(values["message"]))
	if job >= 0 and bool(values.get("push", false)):
		_tag_pushes[job] = tag_name
	_track(job, tr("Creating tag %s") % tag_name, tr("Created tag %s") % tag_name)


func _check_tag_name(values: Dictionary) -> String:
	var tag_name: String = String(values.get("name", ""))
	var error: String = Core.ref_name_error(tag_name)
	if not error.is_empty():
		return tr(error)
	for tag: Dictionary in session.tags():
		if String(tag["name"]) == tag_name:
			return tr("A tag named %s already exists.") % tag_name
	return ""


func delete_tag(tag_name: String) -> void:
	_ask("Delete tag", tr("Delete tag %s? Copies already pushed to a remote stay there.") % tag_name, "Delete",
			func() -> void: _track(session.delete_tag(tag_name), tr("Deleting tag %s") % tag_name, tr("Deleted tag %s") % tag_name), true)


func push_tag(tag_name: String) -> int:
	return _track(session.push_tag(tag_name), tr("Pushing tag %s") % tag_name,
			tr("Pushed tag %s to %s") % [tag_name, session.default_remote()])


# --- Remotes ------------------------------------------------------------------

func add_remote() -> void:
	_begin_form("remote", "Add remote", "Add", func(values: Dictionary) -> void:
		var remote_name: String = String(values["name"])
		_track(session.add_remote(remote_name, String(values["url"])), tr("Adding %s") % remote_name, tr("Added remote %s") % remote_name))
	_form.add_line("name", "Name", "origin" if session.remotes().is_empty() else "", true)
	_form.add_line("url", "URL", "", false, "https://… or git@…")
	_form.validator = _check_remote.bind("", true)
	_form.open()


func edit_remote_url(remote_name: String) -> void:
	var current: String = ""
	for remote: Dictionary in session.remote_list():
		if String(remote["name"]) == remote_name:
			current = String(remote["fetch_url"])
	_begin_form("remote_url", "Change URL", "Save", func(values: Dictionary) -> void:
		_track(session.set_remote_url(remote_name, String(values["url"])), tr("Updating %s") % remote_name,
				tr("Updated the URL of %s") % remote_name))
	_form.add_note(tr("Where %s fetches from and pushes to.") % remote_name)
	_form.add_line("url", "URL", current)
	_form.validator = func(values: Dictionary) -> String:
		return tr("Enter a URL.") if String(values["url"]).is_empty() else ""
	_form.open()


func rename_remote(remote_name: String) -> void:
	_begin_form("remote_rename", "Rename remote", "Rename", func(values: Dictionary) -> void:
		var new: String = String(values["name"])
		if new != remote_name:
			_track(session.rename_remote(remote_name, new), tr("Renaming %s") % remote_name, tr("Renamed remote %s to %s") % [remote_name, new]))
	_form.add_note(tr("Renaming %s; branches that follow it keep following it.") % remote_name)
	_form.add_line("name", "New name", remote_name, true)
	_form.validator = _check_remote.bind(remote_name, false)
	_form.open()


func remove_remote(remote_name: String) -> void:
	_ask("Remove remote", tr("Remove %s? Its remote-tracking branches go too, and local branches stop following it. Nothing changes on the remote itself.") % remote_name,
			"Remove", func() -> void: _track(session.remove_remote(remote_name), tr("Removing %s") % remote_name, tr("Removed remote %s") % remote_name),
			true)


func _check_remote(values: Dictionary, current: String, needs_url: bool) -> String:
	var remote_name: String = String(values.get("name", ""))
	if remote_name.is_empty() or remote_name.contains(" ") or Core.ref_name_error(remote_name) != "":
		return tr("Enter a name without spaces, like origin or upstream.")
	if remote_name != current and remote_name in session.remotes():
		return tr("A remote named %s already exists.") % remote_name
	if needs_url and String(values.get("url", "")).is_empty():
		return tr("Enter a URL.")
	return ""


# --- Merges (PLAN §4 Merge with preview) --------------------------------------

## Opens the merge dialog for `target` (a branch, remote branch or tag by
## full name, or a commit), shown as `shown`; it fills in once the preview
## arrives. One column: `shown → here`, a status line (a spinner while
## checking), the conflicted files, a callout for local changes the merge
## would overwrite, the commits to merge (folded) and the message.
func merge_into_current(target: String, shown: String = "") -> void:
	if shown.is_empty():
		shown = target.left(7) if target.is_valid_hex_number() else target
	_merge = {"target": target, "shown": shown, "origin": Actions.origin()}
	_begin_form("merge", "Merge", "Merge", _start_merge.bind("default"))
	var direction: HBoxContainer = HBoxContainer.new()
	direction.add_child(_ref_chip(_ref_icon(target), shown))
	var arrow: Label = Label.new()
	arrow.text = "→"
	arrow.theme_type_variation = &"DimLabel"
	direction.add_child(arrow)
	direction.add_child(_ref_chip(&"GitBranch", _here()))
	_form.add_control("direction", "", direction)
	var status: HBoxContainer = HBoxContainer.new()
	_merge_status_icon = _form_icon(&"Reload")
	status.add_child(_merge_status_icon)
	_merge_status = Label.new()
	_merge_status.text = "Checking…"
	status.add_child(_merge_status)
	_form.add_control("status", "", status)
	_merge_conflicts = VBoxContainer.new()
	_merge_conflicts.add_theme_constant_override(&"separation", 2)
	_form.add_control("conflicts", "", _merge_conflicts)
	var callout: PanelContainer = PanelContainer.new()
	callout.theme_type_variation = &"Callout"
	var callout_row: HBoxContainer = HBoxContainer.new()
	var warning: TextureRect = _form_icon(&"StatusWarning")
	warning.modulate = _form.get_theme_color(&"warning_color", FormDialog.THEME_TYPE)
	callout_row.add_child(warning)
	_merge_callout = Label.new()
	_merge_callout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_merge_callout.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_merge_callout.mouse_filter = Control.MOUSE_FILTER_PASS
	callout_row.add_child(_merge_callout)
	callout.add_child(callout_row)
	_form.add_control("local_changes", "", callout)
	var commits: VBoxContainer = VBoxContainer.new()
	_merge_commits_toggle = Button.new()
	_merge_commits_toggle.theme_type_variation = &"DisclosureButton"
	_merge_commits_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_merge_commits_toggle.focus_mode = Control.FOCUS_NONE
	_merge_commits_toggle.icon = AppTheme.icon(&"GuiTreeArrowRight")
	_merge_commits = VBoxContainer.new()
	_merge_commits.add_theme_constant_override(&"separation", 2)
	_merge_commits.hide()
	_merge_commits_toggle.pressed.connect(func() -> void:
		_merge_commits.visible = not _merge_commits.visible
		_merge_commits_toggle.icon = AppTheme.icon(&"GuiTreeArrowDown" if _merge_commits.visible else &"GuiTreeArrowRight"))
	commits.add_child(_merge_commits_toggle)
	commits.add_child(_merge_commits)
	_form.add_control("commits", "", commits)
	# One line until the message has more: the box grows with its text.
	var message: TextEdit = _form.add_text("message", "", "", "Merge commit message")
	message.custom_minimum_size.y = 0.0
	message.scroll_fit_content_height = true
	for key: String in ["conflicts", "local_changes", "commits", "message"]:
		_form.set_field_visible(key, false)
	_merge_reason = tr("Checking for conflicts…")
	_form.validator = func(_values: Dictionary) -> String: return _merge_reason
	_form.set_ok_icon(AppTheme.icon(&"GitMerge"))
	_form.open()
	_spin(_merge_status_icon)
	_merge["preview_job"] = session.load_merge_preview(target)
	if int(_merge["preview_job"]) < 0:
		_merge_failed("")


## The preview failed: the status says why and nothing can be merged.
func _merge_failed(why: String) -> void:
	_set_merge_status(&"StatusWarning", why if not why.is_empty() else tr("This cannot be merged"), &"error_color")
	_merge_reason = tr("Cannot merge")
	_form.revalidate()


## The merge dialog's status line (for tests).
func merge_status_text() -> String:
	return _merge_status.text if _merge_status != null and is_instance_valid(_merge_status) else ""


## The conflicted files the merge dialog lists (for tests).
func merge_conflict_paths() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if _merge_conflicts != null and is_instance_valid(_merge_conflicts) and _merge_conflicts.visible:
		for row: Node in _merge_conflicts.get_children():
			out.append(String(row.get_meta(&"path", "")))
	return out


func _on_merge_preview(target: String) -> void:
	if _form_kind != "merge" or not _form.visible or target != String(_merge.get("target", "")):
		return
	var p: Dictionary = session.merge_preview()
	var into: String = _here()
	var shown: String = String(_merge["shown"])
	var count: int = int(p["commit_count"])
	var files: int = int(p["file_count"])
	var conflicts: Array = p["conflicts"]
	var overlap: PackedStringArray = p["overlap"]
	var message_shown: bool = true
	var ok_text: String = ""
	var menu: Array[Dictionary] = []
	_merge_reason = ""
	if bool(p["up_to_date"]):
		_set_merge_status(&"StatusSuccess", tr("%s already has everything in %s") % [into, shown], &"success_color")
		_merge_reason = tr("Already up to date")
		ok_text = tr("Already up to date")
		message_shown = false
		_form.cancel_button_text = "Close"
	elif bool(p["can_ff"]):
		_set_merge_status(&"StatusSuccess", tr("Fast-forward: %s moves to %s") % [into, shown], &"success_color")
		ok_text = tr("Fast-forward %s") % into
		message_shown = false
		menu = [{"label": "Always create merge commit", "icon": &"GitMerge", "run": _start_merge.bind("no_ff")},
			{"label": "Squash into one commit…", "icon": &"GitCommit", "run": _start_merge.bind("squash")}]
	elif conflicts.is_empty():
		_set_merge_status(&"StatusSuccess", tr("No conflicts"), &"success_color")
		ok_text = "Create merge commit"
		menu = [{"label": "Squash into one commit…", "icon": &"GitCommit", "run": _start_merge.bind("squash")},
			{"label": "Fast-forward only", "icon": &"GitBranch", "run": _start_merge.bind("ff_only"), "disabled": true,
				"tooltip": tr("%s has commits %s doesn't") % [into, shown]}]
	else:
		_set_merge_status(&"GitConflict", tr("Conflicts in %s") % _files(conflicts.size()), &"error_color")
		ok_text = "Merge and resolve…"
		menu = [{"label": "Squash and resolve…", "icon": &"GitCommit", "run": _start_merge.bind("squash")}]
	_fill_merge_conflicts(conflicts)
	var overwritten: bool = not overlap.is_empty() and not bool(p["up_to_date"])
	if overwritten:
		var listed: String = overlap[0] if overlap.size() == 1 else tr("%s and %d more") % [overlap[0], overlap.size() - 1]
		_merge_callout.text = tr("Local changes to %s are shelved first") % listed
		_merge_callout.tooltip_text = tr("The merge would overwrite them. They come back after a clean merge; if it conflicts, they stay on the shelf until it is finished.") \
				+ "\n" + "\n".join(overlap)
		ok_text = "Shelve changes and merge"
	_form.set_field_visible("local_changes", overwritten)
	_fill_merge_commits(p["commits"], count)
	_merge_commits_toggle.text = tr("%s · %s changed") % [_commits(count), _files(files)]
	_form.set_field_visible("commits", count > 0)
	(_form.field("message") as TextEdit).text = String(p["message"])
	_form.set_field_visible("message", message_shown)
	_form.ok_button_text = ok_text
	_form.set_ok_icon(null if bool(p["up_to_date"]) else AppTheme.icon(&"GitMerge"))
	_form.set_menu(menu)
	_form.revalidate()
	_form.get_ok_button().grab_focus()


## The status line's icon (stops the spinner) and text, the icon in
## FormDialog colour `color`.
func _set_merge_status(icon: StringName, text: String, color: StringName) -> void:
	if _merge_spin != null:
		_merge_spin.kill()
		_merge_spin = null
	_merge_status_icon.rotation = 0.0
	_merge_status_icon.texture = AppTheme.tintable_icon(icon)
	_merge_status_icon.modulate = _form.get_theme_color(color, FormDialog.THEME_TYPE)
	_merge_status.text = text


## Up to five conflicted files, then "and N more".
func _fill_merge_conflicts(conflicts: Array) -> void:
	for child: Node in _merge_conflicts.get_children():
		_merge_conflicts.remove_child(child)
		child.queue_free()
	var color: Color = _form.get_theme_color(FileRowPainter.CODE_COLORS["U"], FileRowPainter.THEME_TYPE)
	for i: int in mini(5, conflicts.size()):
		var path: String = String((conflicts[i] as Dictionary)["path"])
		var row: HBoxContainer = HBoxContainer.new()
		row.set_meta(&"path", path)
		var icon: TextureRect = _form_icon(&"FileConflict")
		icon.modulate = color
		row.add_child(icon)
		var label: Label = Label.new()
		label.text = path
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(label)
		_merge_conflicts.add_child(row)
	if conflicts.size() > 5:
		var more: Label = Label.new()
		more.text = tr("and %d more") % (conflicts.size() - 5)
		more.theme_type_variation = &"DimLabel"
		_merge_conflicts.add_child(more)
	_form.set_field_visible("conflicts", not conflicts.is_empty())


## A row per commit: icon, short hash, subject, then author and age, dim.
func _fill_merge_commits(commits: Array, count: int) -> void:
	for child: Node in _merge_commits.get_children():
		_merge_commits.remove_child(child)
		child.queue_free()
	var now: int = int(Time.get_unix_time_from_system())
	for commit: Dictionary in commits:
		var row: HBoxContainer = HBoxContainer.new()
		var icon: TextureRect = _form_icon(&"GitCommit")
		icon.modulate.a = 0.6
		row.add_child(icon)
		var short_oid: Label = Label.new()
		short_oid.text = String(commit["oid"]).left(7)
		short_oid.theme_type_variation = &"DetailsHash"
		row.add_child(short_oid)
		var subject: Label = Label.new()
		subject.text = String(commit["subject"])
		subject.tooltip_text = subject.text
		subject.mouse_filter = Control.MOUSE_FILTER_PASS
		subject.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		subject.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(subject)
		var who: Label = Label.new()
		who.text = "%s · %s" % [String(commit["author"]), ago(now - int(commit["time"]))]
		who.theme_type_variation = &"DimLabel"
		row.add_child(who)
		_merge_commits.add_child(row)
	if count > commits.size():
		var more: Label = Label.new()
		more.text = tr("and %d more") % (count - commits.size())
		more.theme_type_variation = &"DimLabel"
		_merge_commits.add_child(more)


## A rounded chip with `icon` and `text`.
func _ref_chip(icon: StringName, text: String) -> PanelContainer:
	var chip: PanelContainer = PanelContainer.new()
	chip.theme_type_variation = &"RefChip"
	var row: HBoxContainer = HBoxContainer.new()
	row.add_child(_form_icon(icon))
	var label: Label = Label.new()
	label.text = text
	row.add_child(label)
	chip.add_child(row)
	return chip


## The icon of a merge target: a tag, a remote branch, a commit or a branch.
static func _ref_icon(target: String) -> StringName:
	if target.begins_with("refs/tags/"):
		return &"GitTag"
	if target.begins_with("refs/remotes/"):
		return &"GitRemote"
	if target.is_valid_hex_number() and target.length() >= 7:
		return &"GitCommit"
	return &"GitBranch"


## An icon sized for a form line.
func _form_icon(icon: StringName) -> TextureRect:
	var rect: TextureRect = TextureRect.new()
	var side: float = float(_form.get_theme_constant(&"icon_size", FormDialog.THEME_TYPE))
	rect.texture = AppTheme.icon(icon)
	rect.custom_minimum_size = Vector2(side, side)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rect.pivot_offset = Vector2(side, side) / 2.0
	return rect


## Turns `icon` until `_set_merge_status` stops it.
func _spin(icon: TextureRect) -> void:
	if _merge_spin != null:
		_merge_spin.kill()
	_merge_spin = icon.create_tween().set_loops()
	_merge_spin.tween_property(icon, "rotation", TAU, 1.0).from(0.0)


## "just now", "5 min ago", "3 h ago", "2 d ago".
static func ago(seconds: int) -> String:
	if seconds < 60:
		return TranslationServer.translate("just now")
	if seconds < 3600:
		return TranslationServer.translate("%d min ago") % floori(seconds / 60.0)
	if seconds < 86400:
		return TranslationServer.translate("%d h ago") % floori(seconds / 3600.0)
	return TranslationServer.translate("%d d ago") % floori(seconds / 86400.0)


## Starts the merge the dialog shows, as `mode` (`default`, `no_ff`,
## `squash`, `ff_only`); local changes the merge touches are shelved first.
func _start_merge(values: Dictionary, mode: String) -> void:
	var p: Dictionary = session.merge_preview()
	var target: String = String(_merge["target"])
	var shown: String = String(_merge["shown"])
	var shelve_first: bool = not (p.get("overlap", PackedStringArray()) as PackedStringArray).is_empty()
	var message: String = String(values.get("message", "")) if mode in ["default", "no_ff"] else ""
	var into: String = _here()
	var job: int = session.merge(target, mode, message, shelve_first)
	var subjects: PackedStringArray = PackedStringArray()
	for commit: Dictionary in p.get("commits", []):
		subjects.append(String(commit["subject"]))
	if job >= 0:
		_merges[job] = {"target": target, "shown": shown, "mode": mode, "commits": subjects}
	var done: String = tr("Merged %s into %s") % [shown, into]
	if mode == "squash":
		done = tr("Squashed %s: review the changes and commit them") % shown
	elif mode != "no_ff" and bool(p.get("can_ff", false)):
		done = tr("Fast-forwarded %s to %s") % [into, shown]
	_track(job, tr("Merging %s") % shown, done, Callable(), _merge.get("origin") as Control)


## "1 file", "3 files".
func _files(n: int) -> String:
	return tr("1 file") if n == 1 else tr("%d files") % n


## "1 commit", "3 commits".
func _commits(n: int) -> String:
	return tr("1 commit") if n == 1 else tr("%d commits") % n


# --- Operations in progress (PLAN §4 Operation banner) ------------------------

## Finishes the operation once no conflict is left: commits a merge or
## cherry-pick with `summary` and `body` (git's message when empty), or
## continues a rebase.
func continue_operation(summary: String = "", body: String = "") -> int:
	var info: Dictionary = session.operation_info()
	var kind: String = String(info.get("kind", ""))
	# A merge or cherry-pick commit shows in the commit box's undo strip.
	var done: String = {"merge": "", "cherry_pick": "", "revert": "", "rebase": "Rebase continued"}.get(kind, "Continued")
	return _track(session.continue_operation(summary, body), "Continuing", done)


func skip_operation() -> int:
	return _track(session.skip_operation(), "Skipping the commit", "Skipped the commit")


# --- Conflicts (PLAN §4 Conflict resolver) ------------------------------------

## Resolves block `block` of conflicted `path` (`ours`, `theirs`,
## `ours_theirs`, `theirs_ours`).
func resolve_block(path: String, block: int, choice: String) -> int:
	return _track(session.resolve_block(path, block, choice), tr("Resolving %s") % path.get_file())


## Resolves conflicted `path` whole (`ours`, `theirs`, `keep`, `delete`).
func resolve_file(path: String, choice: String) -> int:
	var done: String = tr({"ours": "Took our %s", "theirs": "Took their %s", "keep": "Kept %s",
		"delete": "Deleted %s"}.get(choice, "Resolved %s")) % path.get_file()
	return _track(session.resolve_file(path, choice), tr("Resolving %s") % path.get_file(), done)


func undo_block_choice() -> int:
	return _track(session.undo_block_choice(), "Undoing the choice")


func reopen_conflicts(path: String) -> void:
	_ask("Reopen conflicts", tr("Bring back the conflicts of %s? How you resolved it is lost.") % path.get_file(),
			"Reopen", func() -> void:
				_track(session.reopen_conflicts(path), tr("Reopening %s") % path.get_file(), tr("%s has its conflicts again") % path.get_file()))


## Recreates the conflicts of `path` with the base between the markers.
func recreate_with_base(path: String) -> void:
	_ask("Show the base", tr("Recreate the conflicts of %s with the base between them? Changes made to the file since the merge are lost.") % path.get_file(),
			"Recreate", func() -> void:
				_track(session.recreate_conflicts_with_base(path), tr("Recreating %s") % path.get_file()))


# --- Undo commit (PLAN §4 Undo commit strip) ----------------------------------

## Undoes the commit the strip offers: its changes become local changes.
## A merge commit asks first: keep the merged changes, or remove the merge.
func undo_commit() -> void:
	var commit: Dictionary = session.undoable_commit()
	if commit.is_empty():
		return
	if bool(commit["merge"]):
		_pending_undo = commit
		_undo_question.text = tr("Undo “%s”?") % String(commit["subject"])
		_undo_question.tooltip_text = String(commit["subject"])
		_set_choice_hint(_keep_merge_button, "Everything it merged becomes local changes")
		(_keep_merge_button.find_child("Icon", true, false) as TextureRect).modulate = \
				_form.get_theme_color(FileRowPainter.CODE_COLORS["M"], FileRowPainter.THEME_TYPE)
		_set_choice_hint(_remove_merge_button, tr("%s goes back to before it; the merged commits stay on their branch") % _here())
		_undo_merge.reset_size()
		_undo_merge.popup_centered(Vector2i(_form.get_theme_constant(&"width", FormDialog.THEME_TYPE), 0))
		_keep_merge_button.grab_focus()
		return
	_run_undo(commit, "keep_changes", Actions.origin())


func _answer_undo(mode: String) -> void:
	if _pending_undo.is_empty():
		return
	var commit: Dictionary = _pending_undo
	_pending_undo = {}
	_run_undo(commit, mode, null)


func _run_undo(commit: Dictionary, mode: String, origin: Control) -> void:
	var subject: String = String(commit["subject"])
	var done: String = tr("Removed the merge “%s”") % subject if mode == "remove_merge" else tr("Undid “%s”") % subject
	_track(session.undo_commit(String(commit["oid"]), mode), "Undoing the commit", done, Callable(), origin)


# --- Commits and operations -------------------------------------------------

func cherry_pick(oid: String, subject: String) -> void:
	var onto: String = session.current_branch()
	var origin: Control = Actions.origin()
	_ask("Cherry-pick", tr("Apply %s “%s” on top of %s?") % [oid.left(7), subject, onto if not onto.is_empty() else "HEAD"],
			"Cherry-pick", func() -> void:
				_track(session.cherry_pick(oid), tr("Cherry-picking %s") % oid.left(7), tr("Cherry-picked %s") % oid.left(7),
						Callable(), origin))


func abort_operation() -> void:
	var doing: String = String(session.badge().get("operation", ""))
	var what: String = tr(doing) if not doing.is_empty() else tr("the operation in progress")
	var info: Dictionary = session.operation_info()
	# "merging topic", "rebasing series", "cherry-picking 8bc5af2"
	var stopping: String = what
	match session.operation():
		"merge":
			stopping = tr("merging %s") % String(info.get("other_name", ""))
		"rebase":
			stopping = tr("rebasing %s") % String(info.get("head_name", ""))
		"cherry_pick":
			stopping = tr("cherry-picking %s") % String(info.get("other_oid", "")).left(7)
		"revert":
			stopping = tr("reverting %s") % String(info.get("other_oid", "")).left(7)
	var resolved: int = int(info.get("resolved", 0))
	var question: String = tr("Stop %s and discard its changes?") % stopping if resolved == 0 \
			else tr("Stop %s and discard its changes, with the %s you resolved?") % [stopping, _files(resolved)]
	_ask("Abort", question, "Abort", func() -> void:
			_track(session.abort_operation(), "Aborting", tr("Aborted %s") % what), true)


func copy_hash(oid: String) -> void:
	DisplayServer.clipboard_set(oid)
	if feedback != null and feedback.toasts != null:
		feedback.toasts.show_success(tr("Copied %s") % oid.left(7))


## Opens `path` (this worktree when empty) in the configured editor.
func open_in_editor(path: String = "") -> void:
	var error: String = Core.open_in_editor(path if not path.is_empty() else session.toplevel())
	if not error.is_empty():
		notice.emit("Cannot open the editor", L10n.launch_error(error))


## Opens a terminal in `path` (this worktree when empty).
func open_terminal(path: String = "") -> void:
	var error: String = Core.open_terminal(path if not path.is_empty() else session.toplevel())
	if not error.is_empty():
		notice.emit("Cannot open a terminal", L10n.launch_error(error))


## Shows `path` (this worktree when empty) in the system's file manager.
func show_in_file_manager(path: String = "") -> void:
	var error: Error = OS.shell_show_in_file_manager(path if not path.is_empty() else session.toplevel())
	if error != OK:
		notice.emit("Cannot open the file manager", error_string(error))


# --- Worktrees ------------------------------------------------------------------

## The new-task flow (PLAN §4): a branch from a base (the default one
## first, a remote one fetched first) in a new worktree whose folder follows
## the branch name, shown once created.
func new_task() -> void:
	var bases: PackedStringArray = PackedStringArray()
	var base: String = session.default_base()
	if not base.is_empty():
		bases.append(base)
	for ref: Dictionary in session.branch_refs():
		var short: String = String(ref["short_name"])
		if not short in bases:
			bases.append(short)
	if bases.is_empty():
		bases.append("HEAD")
	_folder_edited = false
	_folder_parent = ""
	_remote_match = ""
	_begin_form("task", "New worktree", "Create", _create_task)
	var prefix: String = String(Core.settings()["branch_prefix"])
	var name_line: LineEdit = _form.add_line("name", "Branch", prefix, true)
	_form.add_choice("base", "Start from", bases, 0)
	_form.add_check("track", "", true)
	_form.add_folder("folder", "Folder", "", "-", _pick_task_folder)
	_form.validator = _check_task
	_show_remote_match()
	_form.open()
	# Typing goes after the prefix instead of replacing it.
	name_line.deselect()
	name_line.caret_column = name_line.text.length()


## Where the folder field's relative paths start: the main worktree's root.
func _folder_base() -> String:
	for wt: Dictionary in session.worktrees():
		if bool(wt["is_main"]):
			return String(wt["path"])
	return session.main_worktree() if not session.main_worktree().is_empty() else session.toplevel()


## `path` as the folder field shows it: relative when inside `_folder_base()`.
func _shown_folder(path: String) -> String:
	var inside: String = Paths.relative(path, _folder_base())
	return inside if not inside.is_empty() else path


## The folder field's `text` as a full path.
func _folder_path(text: String) -> String:
	return text if text.is_empty() or text.is_absolute_path() else _folder_base().path_join(text)


## The typed branch name, or "" while it is just the branch prefix.
func _typed_name(values: Dictionary) -> String:
	var typed: String = String(values["name"])
	return "" if typed == String(Core.settings()["branch_prefix"]) else typed


## The remote branch named `name` (`origin/<name>` first), when no local
## branch has that name; else "".
func _remote_branch_named(branch: String) -> String:
	if branch.is_empty() or not _branch_ref("branch", branch).is_empty():
		return ""
	var found: String = ""
	for remote: String in session.remotes():
		var short_name: String = remote + "/" + branch
		if not _branch_ref("remote", short_name).is_empty() and (found.is_empty() or remote == "origin"):
			found = short_name
	return found


## Offers to check out the remote branch the typed name matches; while that
## is on, the base does not apply.
func _show_remote_match() -> void:
	var check: CheckBox = _form.field("track") as CheckBox
	check.text = tr("Check out %s and track it") % _remote_match
	check.tooltip_text = check.text
	# A long branch name is cut short instead of widening the dialog.
	check.clip_text = true
	check.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_form.set_field_visible("track", not _remote_match.is_empty())
	(_form.field("base") as OptionButton).disabled = not _remote_match.is_empty() and check.button_pressed


## A picked empty folder is the worktree's folder; any other is where it
## goes, in a folder named after the branch.
func _pick_task_folder(dir: String) -> String:
	if Core.new_worktree_path_error(dir).is_empty():
		_folder_edited = true
		return _shown_folder(dir)
	_folder_edited = false
	_folder_parent = dir
	return _shown_folder(_task_folder(_typed_name(_form.values())))


## The new-task folder for branch `name` (just the picked folder, or "",
## without a name).
func _task_folder(branch: String) -> String:
	if branch.is_empty():
		return _folder_parent.path_join("") if not _folder_parent.is_empty() else ""
	var path: String = session.worktree_path_for(branch)
	return _folder_parent.path_join(path.get_file()) if not _folder_parent.is_empty() else path


func _check_task(values: Dictionary) -> String:
	var error: String = _check_branch_name(values, "")
	if not error.is_empty():
		return error
	return tr(Core.new_worktree_path_error(_folder_path(String(values.get("folder", "")))))


func _create_task(values: Dictionary) -> void:
	var track: bool = not _remote_match.is_empty() and bool(values["track"])
	var base: String = _remote_match if track else String(values["base"])
	var remote: String = ""
	for remote_name: String in session.remotes():
		if base.begins_with(remote_name + "/") and remote_name.length() > remote.length():
			remote = remote_name
	var folder: String = _folder_path(String(values["folder"]))
	var branch: String = String(values["name"])
	var job: int = session.new_task(branch, base, folder, remote, track)
	if job >= 0:
		_tasks[job] = folder
	if track:
		_track(job, tr("Checking out %s") % base, tr("Checked out %s in a new worktree") % base)
	else:
		_track(job, tr("Creating the worktree %s") % name, tr("Created the worktree %s") % name)


## A worktree for an existing local branch that no worktree has checked out.
func add_existing_worktree() -> void:
	var branches: PackedStringArray = PackedStringArray()
	for ref: Dictionary in session.branch_refs():
		if String(ref["kind"]) == "branch" and String(ref["worktree"]).is_empty():
			branches.append(String(ref["short_name"]))
	if branches.is_empty():
		notice.emit("No branch to add", "Every local branch is already checked out in a worktree.")
		return
	_begin_form("existing", "Add worktree", "Add", func(values: Dictionary) -> void:
		var branch: String = String(values["branch"])
		var path: String = _folder_path(String(values["folder"]))
		var job: int = session.add_worktree(path, branch, "")
		if job >= 0:
			_tasks[job] = path
		_track(job, tr("Adding a worktree for %s") % branch, tr("Added a worktree for %s") % branch))
	_form.add_choice("branch", "Branch", branches, 0)
	_form.add_folder("folder", "Folder", _shown_folder(session.worktree_path_for(branches[0])), "", _shown_folder)
	_form.validator = func(values: Dictionary) -> String:
		return tr(Core.new_worktree_path_error(_folder_path(String(values.get("folder", "")))))
	_form.open()


func _on_form_field(key: String) -> void:
	if _form_kind == "existing" and key == "branch":
		(_form.field("folder") as LineEdit).text = _shown_folder(session.worktree_path_for(String(_form.values()["branch"])))
		return
	if _form_kind != "task":
		return
	if key == "folder":
		_folder_edited = true
	elif key == "name":
		var typed: String = _typed_name(_form.values())
		_remote_match = _remote_branch_named(typed)
		_show_remote_match()
		if not _folder_edited:
			(_form.field("folder") as LineEdit).text = _shown_folder(_task_folder(typed))
	elif key == "track":
		_show_remote_match()


func open_worktree(path: String) -> void:
	open_requested.emit(path)


func lock_worktree(path: String) -> void:
	_begin_form("lock", "Lock worktree", "Lock", func(values: Dictionary) -> void:
		_track(session.lock_worktree(path, String(values["reason"])), "Locking", tr("Locked %s") % path.get_file()))
	_form.add_note("A locked worktree is kept by prune and cleanup, for example while its folder is on a removable disk.")
	_form.add_line("reason", "Reason", "", false, "Optional")
	_form.open()


func unlock_worktree(path: String) -> void:
	_track(session.unlock_worktree(path), "Unlocking", tr("Unlocked %s") % path.get_file())


## Asks before deleting `worktree` (a chip's ref: `path`, `short`, `branch`,
## `detached`, `changed`, `locked`), offering to delete its branch too.
func remove_worktree(worktree: Dictionary) -> void:
	var path: String = String(worktree["path"])
	var changed: int = int(worktree.get("changed", 0))
	var locked: bool = bool(worktree.get("locked", false))
	var branch: String = "" if bool(worktree.get("detached", false)) else String(worktree.get("branch", ""))
	_begin_form("delete_worktree", "Delete worktree", "Delete", func(values: Dictionary) -> void:
		delete_requested.emit(path, changed > 0 or locked, branch if bool(values.get("delete_branch", false)) else ""))
	var text: String = tr("Delete %s and its folder?") % String(worktree.get("short", path.get_file()))
	if changed > 0:
		text += tr(" Its %d changed file will be lost.") % changed if changed == 1 else tr(" Its %d changed files will be lost.") % changed
	if locked:
		text += tr(" It is locked.")
	_form.add_note(text)
	if not branch.is_empty():
		_form.add_check("delete_branch", tr("Also delete the branch %s") % branch, true)
	_form.make_destructive()
	_form.open()


## Deletes worktree `path` from this worktree, then `branch` unless empty
## (asking again if it has commits merged nowhere else).
func delete_worktree(path: String, force: bool, branch: String) -> void:
	var job: int = _track(session.remove_worktree(path, force), tr("Deleting %s") % path.get_file(),
			tr("Deleted the worktree %s") % path.get_file())
	if job >= 0 and not branch.is_empty():
		_worktree_branches[job] = branch


func prune_worktrees() -> int:
	return _track(session.prune_worktrees(), "Pruning worktrees", "Pruned missing worktrees")


## The cleanup flow (PLAN §4): lists worktrees whose branch is merged or
## whose upstream is gone, with warnings, and removes the chosen ones.
func cleanup_worktrees() -> void:
	if session.load_cleanup() < 0:
		notice.emit("Nothing to compare with", "There is no main or master branch to check worktrees against.")
		return
	_cleanup_requested = true


func _on_cleanup_loaded() -> void:
	if not _cleanup_requested:
		return
	_cleanup_requested = false
	_cleanup_list = session.cleanup_candidates()
	var base: String = session.default_base()
	if _cleanup_list.is_empty():
		notice.emit("Nothing to clean up", tr("No worktree's branch is merged into %s or has lost its upstream.") % base)
		return
	_begin_form("cleanup", "Clean up worktrees", "Delete", _run_cleanup)
	_form.add_note(tr("Merged into %s, or their upstream is gone:") % base)
	for i: int in _cleanup_list.size():
		var item: Dictionary = _cleanup_list[i]
		var warnings: PackedStringArray = PackedStringArray()
		if int(item["changed"]) > 0:
			warnings.append(tr("1 changed file will be lost") if int(item["changed"]) == 1
					else tr("%d changed files will be lost") % int(item["changed"]))
		if int(item["ahead"]) > 0:
			warnings.append(tr("1 commit not pushed") if int(item["ahead"]) == 1
					else tr("%d commits not pushed") % int(item["ahead"]))
		if bool(item["locked"]):
			warnings.append(tr("locked"))
		var label: String = "%s  (%s)" % [String(item["branch"]),
				tr("merged") if String(item["reason"]) == "merged" else tr("upstream gone, probably merged")]
		if not warnings.is_empty():
			label += " · " + ", ".join(warnings)
		_form.add_check("wt%d" % i, label, warnings.is_empty())
	_form.add_check("delete_branches", "Also delete their branches", true)
	_form.validator = _check_cleanup
	_form.make_destructive()
	_form.open()


func _check_cleanup(values: Dictionary) -> String:
	for i: int in _cleanup_list.size():
		if bool(values.get("wt%d" % i, false)):
			return ""
	return tr("Select a worktree.")


func _run_cleanup(values: Dictionary) -> void:
	var items: Array[Dictionary] = []
	for i: int in _cleanup_list.size():
		if not bool(values["wt%d" % i]):
			continue
		var item: Dictionary = _cleanup_list[i]
		close_requested.emit(String(item["path"]))
		items.append({
			"path": String(item["path"]),
			"branch": String(item["branch"]),
			"force": int(item["changed"]) > 0 or bool(item["locked"]),
		})
	_track(session.cleanup(items, bool(values["delete_branches"])), "Cleaning up",
			tr("Deleted %d worktree") % items.size() if items.size() == 1 else tr("Deleted %d worktrees") % items.size())


# --- Follow-ups ---------------------------------------------------------------

func _on_job_finished(job: int, _label: String, ok: bool, error: Dictionary) -> void:
	var kind: String = String(error.get("kind", ""))
	if not ok and job >= 0 and job == int(_merge.get("preview_job", -1)) and _form_kind == "merge" and _form.visible:
		_merge_failed(String(error.get("message", "")))
	if _checkouts.has(job):
		var entry: Dictionary = _checkouts[job]
		_checkouts.erase(job)
		# Changes that appeared after the switch started: ask now.
		if not ok and kind == "local_changes":
			_ask_switch(String(entry["name"]), entry["start"], entry.get("origin") as Control)
	elif _deletes.has(job):
		var deleted: String = _deletes[job]
		_deletes.erase(job)
		if not ok and kind == "not_fully_merged":
			_ask("Delete branch", tr("%s has commits that are not merged anywhere else. Delete it anyway?") % deleted,
					"Delete anyway", func() -> void:
						_track(session.delete_branch(deleted, true), tr("Deleting %s") % deleted, tr("Deleted branch %s") % deleted), true)
	elif _worktree_branches.has(job):
		var branch: String = _worktree_branches[job]
		_worktree_branches.erase(job)
		if ok:
			_delete_branch(branch)
	elif _tag_pushes.has(job):
		var tag: String = _tag_pushes[job]
		_tag_pushes.erase(job)
		if ok:
			push_tag(tag)
	elif _tasks.has(job):
		var path: String = _tasks[job]
		_tasks.erase(job)
		if ok:
			open_requested.emit(path)
	elif _merges.has(job):
		var merge: Dictionary = _merges[job]
		_merges.erase(job)
		if ok and String(merge["mode"]) == "squash":
			var subjects: PackedStringArray = merge["commits"]
			var summary: String = subjects[0] if subjects.size() == 1 else "Squash %s into %s" % [merge["shown"], _here()]
			var body: String = "" if subjects.size() == 1 else "\n".join(Array(subjects).map(func(s: String) -> String: return "* " + s))
			message_suggested.emit(summary, body)
			changes_requested.emit(false)
		elif not ok and kind == "conflict":
			# The banner says what is left to resolve.
			changes_requested.emit(true)


## Reports `job` to `feedback` (see `Feedback.track`) and returns it.
func _track(job: int, doing: String, done: String = "", then: Callable = Callable(),
		origin: Control = null, undo: Callable = Callable()) -> int:
	if feedback != null:
		feedback.track(session, job, doing, done, origin, then, undo)
	elif then.is_valid():
		then.call(job >= 0)
	return job


func _begin_form(kind: String, title_text: String, ok_text: String, on_submit: Callable) -> void:
	_form_kind = kind
	_form.begin(title_text, ok_text, on_submit)


## Asks `text` with OK `ok_text`, then calls `run`; `danger` makes OK red
## (deletes and discards).
func _ask(title_text: String, text: String, ok_text: String, run: Callable, danger: bool = false) -> void:
	_confirm.title = title_text
	_confirm.dialog_text = text
	_confirm.ok_button_text = ok_text
	_confirm.get_ok_button().theme_type_variation = &"DangerButton" if danger else &"PrimaryButton"
	_on_confirm = run
	_confirm.popup_centered(Vector2i(_form.get_theme_constant(&"width", FormDialog.THEME_TYPE), 0))
	_confirm.get_ok_button().grab_focus()


func _on_confirmed() -> void:
	var run: Callable = _on_confirm
	_on_confirm = Callable()
	if run.is_valid():
		run.call()
