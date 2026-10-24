class_name RepoOps
extends Node
## Sync, branch, tag and commit operations of one repository tab, with the
## dialogs they need (PLAN §4): names for new branches and tags,
## confirmations for deletes, force pushes and cherry-picks, and the
## dirty-tree checkout flow that offers to stash, switch and re-apply.

## Something the user should read (an editor that did not start, ...).
signal notice(title: String, message: String)

const FORM: PackedScene = preload("res://ui/form_dialog/form_dialog.tscn")
## Choice in the upstream dialog that removes the upstream.
const NO_UPSTREAM: String = "(none)"

var session: RepoSession = null:
	set = set_session

var _form: FormDialog = null
var _confirm: ConfirmationDialog = ConfirmationDialog.new()
var _on_confirm: Callable = Callable()
## Checkouts started here: job id -> `{name, start}`; `start` is
## `func(stash: bool) -> int` and retries the checkout.
var _checkouts: Dictionary[int, Dictionary] = {}
## Branch deletes started here: job id -> branch name.
var _deletes: Dictionary[int, String] = {}
## Tags to push once created: job id -> tag name.
var _tag_pushes: Dictionary[int, String] = {}


func _ready() -> void:
	_form = FORM.instantiate() as FormDialog
	add_child(_form)
	_confirm.dialog_autowrap = true
	_confirm.confirmed.connect(_on_confirmed)
	add_child(_confirm)


func set_session(value: RepoSession) -> void:
	if session != null and session.job_finished.is_connected(_on_job_finished):
		session.job_finished.disconnect(_on_job_finished)
	session = value
	if session != null:
		session.job_finished.connect(_on_job_finished)


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

func fetch() -> int:
	return session.fetch()


## `mode` is `ff-only`, `merge`, `rebase`, or empty for the configured one.
func pull(mode: String = "") -> int:
	return session.pull(mode)


func push() -> int:
	return session.push(false)


func force_push() -> void:
	var branch: String = session.current_branch()
	_ask("Force push", "Replace %s on %s with your local branch?\nThis is refused if the remote branch has commits you have not fetched." % [
		branch, session.default_remote()], "Force push", func() -> void: session.push(true))


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
		_checkouts[job] = {"name": name, "start": start}
	return job


# --- Branches -----------------------------------------------------------------

## Asks for a name and creates a branch at `start` (a ref or hash, shown as
## `start_label`).
func new_branch(start: String, start_label: String) -> void:
	_form.begin("New branch", "Create branch", _create_branch.bind(start))
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
		session.create_branch(name, start, false)


## Creates `name` at `start` and switches to it; with `stash`, as two steps
## so the switch can carry local changes over.
func _create_and_switch(stash: bool, name: String, start: String) -> int:
	if not stash:
		return session.create_branch(name, start, true)
	session.create_branch(name, start, false)
	return session.checkout_branch(name, true)


func rename_branch(name: String) -> void:
	_form.begin("Rename branch", "Rename", _rename_branch.bind(name))
	_form.add_line("name", "New name for %s" % name, name, true)
	_form.validator = _check_branch_name.bind(name)
	_form.open()


func _rename_branch(values: Dictionary, old: String) -> void:
	if String(values["name"]) != old:
		session.rename_branch(old, String(values["name"]))


func delete_branch(name: String) -> void:
	_ask("Delete branch", "Delete branch %s?" % name, "Delete", _delete_branch.bind(name))


func _delete_branch(name: String) -> void:
	var job: int = session.delete_branch(name, false)
	if job >= 0:
		_deletes[job] = name


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
	_form.begin("Set upstream", "Save", _save_upstream.bind(branch))
	_form.add_choice("upstream", "Upstream of %s" % branch, options, selected)
	_form.open()


func _save_upstream(values: Dictionary, branch: String) -> void:
	var upstream: String = String(values["upstream"])
	session.set_upstream(branch, "" if upstream == NO_UPSTREAM else upstream)


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
	_form.begin("New tag", "Create tag", _create_tag.bind(target))
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
			func() -> void: session.delete_tag(name))


func push_tag(name: String) -> int:
	return session.push_tag(name)


# --- Commits and operations -------------------------------------------------

func cherry_pick(oid: String, subject: String) -> void:
	var onto: String = session.current_branch()
	_ask("Cherry-pick", "Apply %s “%s” on top of %s?" % [oid.left(7), subject, onto if not onto.is_empty() else "HEAD"],
			"Cherry-pick", func() -> void: session.cherry_pick(oid))


func abort_operation() -> void:
	var doing: String = String(session.badge().get("operation", ""))
	_ask("Abort", "Stop %s and go back to where you were before it? Its changes are discarded." % (
			doing if not doing.is_empty() else "the operation in progress"),
			"Abort", func() -> void: session.abort_operation())


func copy_hash(oid: String) -> void:
	DisplayServer.clipboard_set(oid)


func open_in_editor() -> void:
	var error: String = Core.open_in_editor(session.toplevel())
	if not error.is_empty():
		notice.emit("Cannot open the editor", error)


func open_terminal() -> void:
	var error: String = Core.open_terminal(session.toplevel())
	if not error.is_empty():
		notice.emit("Cannot open a terminal", error)


# --- Follow-ups ---------------------------------------------------------------

func _on_job_finished(job: int, _label: String, ok: bool, error: Dictionary) -> void:
	var kind: String = String(error.get("kind", ""))
	if _checkouts.has(job):
		var entry: Dictionary = _checkouts[job]
		_checkouts.erase(job)
		var start: Callable = entry["start"]
		if not ok and kind == "local_changes":
			var name: String = String(entry["name"])
			_ask("Switch with local changes",
					"Your local changes would be overwritten by checking out %s.\n\nStash them, switch, and re-apply them on %s?" % [name, name],
					"Stash and switch", func() -> void: start.call(true))
	elif _deletes.has(job):
		var name: String = _deletes[job]
		_deletes.erase(job)
		if not ok and kind == "not_fully_merged":
			_ask("Delete branch", "%s has commits that are not merged anywhere else. Delete it anyway?" % name,
					"Delete anyway", func() -> void: session.delete_branch(name, true))
	elif _tag_pushes.has(job):
		var tag: String = _tag_pushes[job]
		_tag_pushes.erase(job)
		if ok:
			session.push_tag(tag)


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
