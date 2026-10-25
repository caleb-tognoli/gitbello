class_name RepoOps
extends Node
## Sync, branch, tag, remote, commit and worktree operations of one worktree,
## with the dialogs they need (PLAN §4): names for new branches and tags,
## confirmations for deletes, force pushes and cherry-picks, the dirty-tree
## checkout flow that offers to stash, switch and re-apply, the Sync button's
## choice, and the new-task and cleanup flows for worktrees. Every job it
## starts goes to `feedback`, with the control that started the flow.

## Something the user should read (an editor that did not start, ...).
signal notice(title: String, message: String)
## A worktree should show (a new task, or the user asked).
signal open_requested(path: String)
## A worktree is about to be removed: close its view, if open.
signal close_requested(path: String)

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
## `func(stash: bool) -> int` and retries the checkout.
var _checkouts: Dictionary[int, Dictionary] = {}
## Branch deletes started here: job id -> branch name.
var _deletes: Dictionary[int, String] = {}
## Tags to push once created: job id -> tag name.
var _tag_pushes: Dictionary[int, String] = {}
## New tasks and added worktrees started here: job id -> `{path, tab, editor}`.
var _tasks: Dictionary[int, Dictionary] = {}
## Which flow the form shows (`task`, `cleanup`, ...), for field changes.
var _form_kind: String = ""
## The new-task folder was edited by hand: stop following the branch name.
var _folder_edited: bool = false
var _cleanup_requested: bool = false
var _cleanup_list: Array[Dictionary] = []


func _ready() -> void:
	_form = FORM.instantiate() as FormDialog
	add_child(_form)
	_form.field_changed.connect(_on_form_field)
	_confirm.dialog_autowrap = true
	_confirm.confirmed.connect(_on_confirmed)
	_confirm.get_ok_button().theme_type_variation = &"PrimaryButton"
	add_child(_confirm)


func set_session(value: RepoSession) -> void:
	if session != null and session.job_finished.is_connected(_on_job_finished):
		session.job_finished.disconnect(_on_job_finished)
		session.cleanup_loaded.disconnect(_on_cleanup_loaded)
	session = value
	if session != null:
		session.job_finished.connect(_on_job_finished)
		session.cleanup_loaded.connect(_on_cleanup_loaded)


func form() -> FormDialog:
	return _form


func confirm_dialog() -> ConfirmationDialog:
	return _confirm


## Errors a dialog here follows up (stash and switch, delete anyway), so
## they need no toast.
func handles_error(error: Dictionary) -> bool:
	var kind: String = String(error.get("kind", ""))
	var command: String = String(error.get("command", ""))
	return (kind == "local_changes" and command.begins_with("switch")) \
			or (kind == "not_fully_merged" and command.begins_with("branch"))


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
				feedback.toasts.show_toast("%s has diverged from its upstream" % session.current_branch(),
						"Both sides have new commits, so a fast-forward is not possible. Merge or rebase, then push.",
						"", fixes)


func _pull_then_push(mode: String, origin: Control) -> void:
	var branch: String = session.current_branch()
	var then_push: Callable = func(ok: bool) -> void:
		if ok:
			_track(session.push(false), "Pushing %s" % branch,
					"Synced %s with %s" % [branch, session.default_remote()], Callable(), origin)
	_track(session.pull(mode), "Pulling %s" % branch, "", then_push, origin)


func fetch() -> int:
	return _track(session.fetch(), "Fetching %s" % session.display_name())


## `mode` is `ff-only`, `merge`, `rebase`, or empty for the configured one.
func pull(mode: String = "") -> int:
	var branch: String = session.current_branch()
	return _track(session.pull(mode), "Pulling %s" % branch, "Pulled into %s" % branch)


## Pushes the current branch; one without an upstream is published (the push
## sets it).
func push() -> int:
	var branch: String = session.current_branch()
	var remote: String = session.default_remote()
	return _track(session.push(false), "Pushing %s" % branch, "Pushed %s to %s" % [branch, remote])


func force_push() -> void:
	var branch: String = session.current_branch()
	var origin: Control = Actions.origin()
	_ask("Force push", "Replace %s on %s with your local branch?\nThis is refused if the remote branch has commits you have not fetched." % [
		branch, session.default_remote()], "Force push", func() -> void:
			_track(session.push(true), "Force pushing %s" % branch, "Force pushed %s" % branch, Callable(), origin))


# --- Checkout -------------------------------------------------------------------

func checkout_branch(name: String) -> int:
	return _checkout(name, func(stash: bool) -> int: return session.checkout_branch(name, stash))


## `ref_name` is a remote-tracking ref (`refs/remotes/origin/x`).
func checkout_remote(ref_name: String) -> int:
	var shown: String = ref_name.trim_prefix("refs/remotes/")
	return _checkout(shown, func(stash: bool) -> int: return session.checkout_remote(ref_name, stash))


func checkout_commit(oid: String) -> void:
	_ask("Check out commit", "Check out %s?\nHEAD will be detached: new commits are not on any branch until you create one." % oid.left(7),
			"Check out", _checkout_detached.bind(oid))


func _checkout_detached(oid: String) -> void:
	_checkout(oid.left(7), func(stash: bool) -> int: return session.checkout_commit(oid, stash))


func _checkout(name: String, start: Callable) -> int:
	var job: int = start.call(false)
	if job >= 0:
		_checkouts[job] = {"name": name, "start": start, "origin": Actions.origin()}
	return _track(job, "Switching to %s" % name, "Switched to %s" % name)


# --- Branches -----------------------------------------------------------------

## Asks for a name and creates a branch at `start` (a ref or hash, shown as
## `start_label`).
func new_branch(start: String, start_label: String) -> void:
	_begin_form("branch", "New branch", "Create branch", _create_branch.bind(start))
	_form.add_note("Starting at %s." % start_label)
	_form.add_line("name", "Name", "", true)
	_form.add_check("checkout", "Check out the new branch", true)
	_form.validator = _check_branch_name.bind("")
	_form.open()


func _create_branch(values: Dictionary, start: String) -> void:
	var name: String = String(values["name"])
	if bool(values["checkout"]):
		_checkout(name, _create_and_switch.bind(name, start))
	else:
		_track(session.create_branch(name, start, false), "Creating %s" % name, "Created branch %s" % name)


## Creates `name` at `start` and switches to it; with `stash`, as two steps
## so the switch can carry local changes over.
func _create_and_switch(stash: bool, name: String, start: String) -> int:
	if not stash:
		return session.create_branch(name, start, true)
	session.create_branch(name, start, false)
	return session.checkout_branch(name, true)


func rename_branch(name: String) -> void:
	_begin_form("rename", "Rename branch", "Rename", _rename_branch.bind(name))
	_form.add_note("Renaming %s." % name)
	_form.add_line("name", "New name", name, true)
	_form.validator = _check_branch_name.bind(name)
	_form.open()


func _rename_branch(values: Dictionary, old: String) -> void:
	var new: String = String(values["name"])
	if new != old:
		_track(session.rename_branch(old, new), "Renaming %s" % old, "Renamed %s to %s" % [old, new])


func delete_branch(name: String) -> void:
	_ask("Delete branch", "Delete branch %s?" % name, "Delete", _delete_branch.bind(name))


func _delete_branch(name: String) -> void:
	var job: int = session.delete_branch(name, false)
	if job >= 0:
		_deletes[job] = name
	_track(job, "Deleting %s" % name, "Deleted branch %s" % name)


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
	_form.add_note("The branch %s follows." % branch)
	_form.add_choice("upstream", "Upstream", options, selected)
	_form.open()


func _save_upstream(values: Dictionary, branch: String) -> void:
	var upstream: String = String(values["upstream"])
	var none: bool = upstream == NO_UPSTREAM
	_track(session.set_upstream(branch, "" if none else upstream), "Setting the upstream",
			"%s no longer follows a remote branch" % branch if none else "%s now follows %s" % [branch, upstream])


func _check_branch_name(values: Dictionary, current: String) -> String:
	var name: String = String(values.get("name", ""))
	var error: String = Core.ref_name_error(name)
	if not error.is_empty():
		return error
	if name != current and not _branch_ref("branch", name).is_empty():
		return "A branch named %s already exists." % name
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
	_form.add_note("On %s." % target_label)
	_form.add_line("name", "Name", "", true)
	_form.add_text("message", "Message", "", "Optional; a message makes an annotated tag")
	var remote: String = session.default_remote()
	if not remote.is_empty():
		_form.add_check("push", "Push it to %s" % remote, false)
	_form.validator = _check_tag_name
	_form.open()


func _create_tag(values: Dictionary, target: String) -> void:
	var name: String = String(values["name"])
	var job: int = session.create_tag(name, target, String(values["message"]))
	if job >= 0 and bool(values.get("push", false)):
		_tag_pushes[job] = name
	_track(job, "Creating tag %s" % name, "Created tag %s" % name)


func _check_tag_name(values: Dictionary) -> String:
	var name: String = String(values.get("name", ""))
	var error: String = Core.ref_name_error(name)
	if not error.is_empty():
		return error
	for tag: Dictionary in session.tags():
		if String(tag["name"]) == name:
			return "A tag named %s already exists." % name
	return ""


func delete_tag(name: String) -> void:
	_ask("Delete tag", "Delete tag %s? Copies already pushed to a remote stay there." % name, "Delete",
			func() -> void: _track(session.delete_tag(name), "Deleting tag %s" % name, "Deleted tag %s" % name))


func push_tag(name: String) -> int:
	return _track(session.push_tag(name), "Pushing tag %s" % name,
			"Pushed tag %s to %s" % [name, session.default_remote()])


# --- Remotes ------------------------------------------------------------------

func add_remote() -> void:
	_begin_form("remote", "Add remote", "Add", func(values: Dictionary) -> void:
		var name: String = String(values["name"])
		_track(session.add_remote(name, String(values["url"])), "Adding %s" % name, "Added remote %s" % name))
	_form.add_line("name", "Name", "origin" if session.remotes().is_empty() else "", true)
	_form.add_line("url", "URL", "", false, "https://… or git@…")
	_form.validator = _check_remote.bind("", true)
	_form.open()


func edit_remote_url(name: String) -> void:
	var current: String = ""
	for remote: Dictionary in session.remote_list():
		if String(remote["name"]) == name:
			current = String(remote["fetch_url"])
	_begin_form("remote_url", "Change URL", "Save", func(values: Dictionary) -> void:
		_track(session.set_remote_url(name, String(values["url"])), "Updating %s" % name,
				"Updated the URL of %s" % name))
	_form.add_note("Where %s fetches from and pushes to." % name)
	_form.add_line("url", "URL", current)
	_form.validator = func(values: Dictionary) -> String:
		return "Enter a URL." if String(values["url"]).is_empty() else ""
	_form.open()


func rename_remote(name: String) -> void:
	_begin_form("remote_rename", "Rename remote", "Rename", func(values: Dictionary) -> void:
		var new: String = String(values["name"])
		if new != name:
			_track(session.rename_remote(name, new), "Renaming %s" % name, "Renamed remote %s to %s" % [name, new]))
	_form.add_note("Renaming %s; branches that follow it keep following it." % name)
	_form.add_line("name", "New name", name, true)
	_form.validator = _check_remote.bind(name, false)
	_form.open()


func remove_remote(name: String) -> void:
	_ask("Remove remote", "Remove %s? Its remote-tracking branches go too, and local branches stop following it. Nothing changes on the remote itself." % name,
			"Remove", func() -> void: _track(session.remove_remote(name), "Removing %s" % name, "Removed remote %s" % name))


func _check_remote(values: Dictionary, current: String, needs_url: bool) -> String:
	var name: String = String(values.get("name", ""))
	if name.is_empty() or name.contains(" ") or Core.ref_name_error(name) != "":
		return "Enter a name without spaces, like origin or upstream."
	if name != current and name in session.remotes():
		return "A remote named %s already exists." % name
	if needs_url and String(values.get("url", "")).is_empty():
		return "Enter a URL."
	return ""


# --- Commits and operations -------------------------------------------------

func cherry_pick(oid: String, subject: String) -> void:
	var onto: String = session.current_branch()
	var origin: Control = Actions.origin()
	_ask("Cherry-pick", "Apply %s “%s” on top of %s?" % [oid.left(7), subject, onto if not onto.is_empty() else "HEAD"],
			"Cherry-pick", func() -> void:
				_track(session.cherry_pick(oid), "Cherry-picking %s" % oid.left(7), "Cherry-picked %s" % oid.left(7),
						Callable(), origin))


func abort_operation() -> void:
	var doing: String = String(session.badge().get("operation", ""))
	var what: String = doing if not doing.is_empty() else "the operation in progress"
	_ask("Abort", "Stop %s and go back to where you were before it? Its changes are discarded." % what,
			"Abort", func() -> void: _track(session.abort_operation(), "Aborting", "Aborted %s" % what))


func copy_hash(oid: String) -> void:
	DisplayServer.clipboard_set(oid)
	if feedback != null and feedback.toasts != null:
		feedback.toasts.show_success("Copied %s" % oid.left(7))


## Opens `path` (this worktree when empty) in the configured editor.
func open_in_editor(path: String = "") -> void:
	var error: String = Core.open_in_editor(path if not path.is_empty() else session.toplevel())
	if not error.is_empty():
		notice.emit("Cannot open the editor", error)


## Opens a terminal in `path` (this worktree when empty).
func open_terminal(path: String = "") -> void:
	var error: String = Core.open_terminal(path if not path.is_empty() else session.toplevel())
	if not error.is_empty():
		notice.emit("Cannot open a terminal", error)


## Shows `path` (this worktree when empty) in the system's file manager.
func show_in_file_manager(path: String = "") -> void:
	var error: Error = OS.shell_show_in_file_manager(path if not path.is_empty() else session.toplevel())
	if error != OK:
		notice.emit("Cannot open the file manager", error_string(error))


# --- Worktrees ------------------------------------------------------------------

## The new-task flow (PLAN §4): a branch from a base (the default one
## first) in a new worktree whose folder follows the branch name, shown
## (and optionally opened in the editor) once created.
func new_task() -> void:
	var bases: PackedStringArray = PackedStringArray()
	var base: String = session.default_base()
	if not base.is_empty():
		bases.append(base)
	for ref: Dictionary in session.branch_refs():
		var name: String = String(ref["short_name"])
		if not name in bases:
			bases.append(name)
	if bases.is_empty():
		bases.append("HEAD")
	_folder_edited = false
	_begin_form("task", "New task", "Create", _create_task)
	_form.add_line("name", "Branch", "", true)
	_form.add_choice("base", "Start from", bases, 0)
	_form.add_line("folder", "Folder", "", false, "Follows the branch name")
	_form.add_check("open_tab", "Switch to it", true)
	_form.add_check("open_editor", "Open it in the editor", false)
	_form.add_note("A remote branch is fetched first.")
	_form.validator = _check_task
	_form.open()


func _check_task(values: Dictionary) -> String:
	var error: String = _check_branch_name(values, "")
	if not error.is_empty():
		return error
	var folder: String = String(values.get("folder", ""))
	return Core.new_worktree_path_error(folder)


func _create_task(values: Dictionary) -> void:
	var base: String = String(values["base"])
	var remote: String = ""
	for name: String in session.remotes():
		if base.begins_with(name + "/") and name.length() > remote.length():
			remote = name
	var folder: String = String(values["folder"])
	var name: String = String(values["name"])
	var job: int = session.new_task(name, base, folder, remote)
	if job >= 0:
		_tasks[job] = {"path": folder, "tab": bool(values["open_tab"]), "editor": bool(values["open_editor"])}
	_track(job, "Creating the task %s" % name, "Created the task %s" % name)


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
		var path: String = String(values["folder"])
		var job: int = session.add_worktree(path, branch, "")
		if job >= 0:
			_tasks[job] = {"path": path, "tab": true, "editor": false}
		_track(job, "Adding a worktree for %s" % branch, "Added a worktree for %s" % branch))
	_form.add_choice("branch", "Branch", branches, 0)
	_form.add_line("folder", "Folder", session.worktree_path_for(branches[0]))
	_form.validator = func(values: Dictionary) -> String:
		return Core.new_worktree_path_error(String(values.get("folder", "")))
	_form.open()


func _on_form_field(key: String) -> void:
	if _form_kind == "existing" and key == "branch":
		(_form.field("folder") as LineEdit).text = session.worktree_path_for(String(_form.values()["branch"]))
		return
	if _form_kind != "task":
		return
	if key == "folder":
		_folder_edited = true
	elif key == "name" and not _folder_edited:
		var name: String = String(_form.values()["name"])
		(_form.field("folder") as LineEdit).text = session.worktree_path_for(name) if not name.is_empty() else ""


func open_worktree(path: String) -> void:
	open_requested.emit(path)


func lock_worktree(path: String) -> void:
	_begin_form("lock", "Lock worktree", "Lock", func(values: Dictionary) -> void:
		_track(session.lock_worktree(path, String(values["reason"])), "Locking", "Locked %s" % path.get_file()))
	_form.add_note("A locked worktree is kept by prune and cleanup, for example while its folder is on a removable disk.")
	_form.add_line("reason", "Reason", "", false, "Optional")
	_form.open()


func unlock_worktree(path: String) -> void:
	_track(session.unlock_worktree(path), "Unlocking", "Unlocked %s" % path.get_file())


## Asks, then removes the worktree described by `worktree` (`path`,
## `changed`, `locked`), closing its view first. Its branch stays.
func remove_worktree(worktree: Dictionary) -> void:
	var path: String = String(worktree["path"])
	var changed: int = int(worktree.get("changed", 0))
	var locked: bool = bool(worktree.get("locked", false))
	var text: String = "Remove the worktree at %s? Its branch stays." % path
	if changed > 0:
		text += "\n\nIts %d changed files are lost." % changed
	if locked:
		text += "\n\nIt is locked."
	_ask("Remove worktree", text, "Remove", func() -> void:
		close_requested.emit(path)
		_track(session.remove_worktree(path, changed > 0 or locked), "Removing %s" % path.get_file(),
				"Removed the worktree %s" % path.get_file()))


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
		notice.emit("Nothing to clean up", "No worktree's branch is merged into %s or has lost its upstream." % base)
		return
	_begin_form("cleanup", "Clean up worktrees", "Remove", _run_cleanup)
	_form.add_note("Merged into %s, or their upstream is gone:" % base)
	for i: int in _cleanup_list.size():
		var item: Dictionary = _cleanup_list[i]
		var warnings: PackedStringArray = PackedStringArray()
		if int(item["changed"]) > 0:
			warnings.append("%d changed files will be lost" % int(item["changed"]))
		if int(item["ahead"]) > 0:
			warnings.append("%d commits not pushed" % int(item["ahead"]))
		if bool(item["locked"]):
			warnings.append("locked")
		var label: String = "%s  (%s)" % [String(item["branch"]),
				"merged" if String(item["reason"]) == "merged" else "upstream gone, probably merged"]
		if not warnings.is_empty():
			label += " · " + ", ".join(warnings)
		_form.add_check("wt%d" % i, label, warnings.is_empty())
	_form.add_check("delete_branches", "Also delete their branches", true)
	_form.validator = _check_cleanup
	_form.open()


func _check_cleanup(values: Dictionary) -> String:
	for i: int in _cleanup_list.size():
		if bool(values.get("wt%d" % i, false)):
			return ""
	return "Select a worktree."


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
			"Removed %d worktree%s" % [items.size(), "" if items.size() == 1 else "s"])


# --- Follow-ups ---------------------------------------------------------------

func _on_job_finished(job: int, _label: String, ok: bool, error: Dictionary) -> void:
	var kind: String = String(error.get("kind", ""))
	if _checkouts.has(job):
		var entry: Dictionary = _checkouts[job]
		_checkouts.erase(job)
		var start: Callable = entry["start"]
		if not ok and kind == "local_changes":
			var name: String = String(entry["name"])
			var origin: Control = entry.get("origin") as Control
			_ask("Switch with local changes",
					"Your local changes would be overwritten by checking out %s.\n\nStash them, switch, and re-apply them on %s?" % [name, name],
					"Stash and switch", func() -> void:
						_track(start.call(true), "Switching to %s" % name, "Switched to %s with your changes" % name,
								Callable(), origin))
	elif _deletes.has(job):
		var name: String = _deletes[job]
		_deletes.erase(job)
		if not ok and kind == "not_fully_merged":
			_ask("Delete branch", "%s has commits that are not merged anywhere else. Delete it anyway?" % name,
					"Delete anyway", func() -> void:
						_track(session.delete_branch(name, true), "Deleting %s" % name, "Deleted branch %s" % name))
	elif _tag_pushes.has(job):
		var tag: String = _tag_pushes[job]
		_tag_pushes.erase(job)
		if ok:
			push_tag(tag)
	elif _tasks.has(job):
		var task: Dictionary = _tasks[job]
		_tasks.erase(job)
		if ok and bool(task["tab"]):
			open_requested.emit(String(task["path"]))
		if ok and bool(task["editor"]):
			open_in_editor(String(task["path"]))


## Reports `job` to `feedback` (see `Feedback.track`) and returns it.
func _track(job: int, doing: String, done: String = "", then: Callable = Callable(),
		origin: Control = null) -> int:
	if feedback != null:
		feedback.track(session, job, doing, done, origin, then)
	elif then.is_valid():
		then.call(job >= 0)
	return job


func _begin_form(kind: String, title_text: String, ok_text: String, on_submit: Callable) -> void:
	_form_kind = kind
	_form.begin(title_text, ok_text, on_submit)


func _ask(title_text: String, text: String, ok_text: String, run: Callable) -> void:
	_confirm.title = title_text
	_confirm.dialog_text = text
	_confirm.ok_button_text = ok_text
	_on_confirm = run
	_confirm.popup_centered(Vector2i(_form.get_theme_constant(&"width", FormDialog.THEME_TYPE), 0))
	_confirm.get_ok_button().grab_focus()


func _on_confirmed() -> void:
	var run: Callable = _on_confirm
	_on_confirm = Callable()
	if run.is_valid():
		run.call()
