class_name LibraryOps
extends Node
## The Home flows (PLAN §4 Home): Clone, Add existing folder, Scan folder,
## Create and Initialize folder, and the actions on a library entry. Clones
## run in the background and show as rows on Home (`clones()`); Create and
## Initialize keep their form open with progress and errors.

## The shell should open `path` (a repository, or a folder inside one).
signal open_requested(path: String)
## A clone started, progressed, failed or ended (Home redraws its rows).
signal clones_changed()
## A clone finished; `path` is in the library now.
signal clone_finished(path: String)

const FORM: PackedScene = preload("res://ui/form_dialog/form_dialog.tscn")
## `.gitignore` choice meaning none.
const NO_TEMPLATE: String = "None"

## Where toasts go (set by the shell).
var toasts: Toasts = null
## `func(path: String) -> bool`: whether a tab shows repository `path`.
var is_open: Callable = Callable()
## `func(path: String) -> void`: closes the tab of repository `path`.
var close_repo: Callable = Callable()

var _form: FormDialog = FORM.instantiate() as FormDialog
## Rebuilt for each question (see `_ask`).
var _confirm: ConfirmationDialog = null
var _scan: ScanDialog = ScanDialog.new()
## Clone jobs: job id -> `{job, url, path, name, percent, text, error}`.
var _clones: Dictionary[int, Dictionary] = {}
## The Create or Initialize job the form shows, or -1.
var _form_job: int = -1
## The form's job status and progress (made by `_add_status`).
var _status: Label = null
var _progress: ProgressBar = null
## Location checks: job id -> `func(result: Dictionary) -> void`.
var _checks: Dictionary[int, Callable] = {}
var _clone_destination_edited: bool = false
## The folder a clone goes in while its destination follows the URL.
var _clone_parent: String = ""


func _ready() -> void:
	add_child(_form)
	add_child(_scan)
	_form.field_changed.connect(_on_field_changed)
	_form.canceled.connect(_on_form_canceled)
	Core.repository_job_progress.connect(_on_job_progress)
	Core.repository_job_finished.connect(_on_job_finished)
	Core.repository_job_cancelled.connect(_on_job_cancelled)


func form() -> FormDialog:
	return _form


## The last question asked (for tests), or null.
func confirm_dialog() -> ConfirmationDialog:
	return _confirm


func scan_dialog() -> ScanDialog:
	return _scan


# --- Clone ------------------------------------------------------------------

## Opens the Clone form, with `url` or a git URL from the clipboard.
func clone(url: String = "", destination: String = "") -> void:
	if url.is_empty():
		var clipboard: String = DisplayServer.clipboard_get().strip_edges()
		if looks_like_git_url(clipboard):
			url = clipboard
	_clone_destination_edited = not destination.is_empty()
	_clone_parent = default_clone_folder()
	_form.begin("Clone repository", "Clone", _start_clone)
	_form.hide_on_submit = true
	_form.add_line("url", "Repository URL", url, false, "https://github.com/user/repository.git")
	var folder: String = destination if not destination.is_empty() else _clone_parent.path_join(clone_name(url))
	_form.add_folder("destination", "Destination", folder)
	_form.add_line("branch", "Branch", "", true, "The remote's default branch")
	_form.add_check("submodules", "Clone submodules too")
	_form.validator = _validate_clone
	_form.set_ok_icon(AppTheme.icon(&"GitFetch"))
	_form.open()


## Sets the clone destination as if picked in the folder dialog (tests).
func pick_clone_destination(dir: String) -> void:
	_clone_destination_edited = true
	_form.pick_folder("destination", dir)


## Running and failed clones, oldest first.
func clones() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for job: int in _clones:
		out.append(_clones[job])
	return out


func cancel_clone(job: int) -> void:
	Core.cancel_repository_job(job)


## Forgets a failed clone's row.
func dismiss_clone(job: int) -> void:
	if _clones.erase(job):
		clones_changed.emit()


## Opens the form again with a failed clone's values.
func retry_clone(job: int) -> void:
	var entry: Dictionary = _clones.get(job, {})
	dismiss_clone(job)
	if not entry.is_empty():
		clone(String(entry["url"]), String(entry["path"]))


## The Settings folder for clones, the last one used, or the documents folder.
static func default_clone_folder() -> String:
	var folder: String = Core.clone_folder()
	return folder if not folder.is_empty() else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)


## Whether `text` (one line) looks like something `git clone` takes.
static func looks_like_git_url(text: String) -> bool:
	if text.is_empty() or text.contains("\n") or text.contains(" "):
		return false
	for prefix: String in ["https://", "http://", "ssh://", "git://", "git@"]:
		if text.begins_with(prefix):
			return true
	return text.ends_with(".git")


## The folder name a clone of `url` gets (`repository` of `…/repository.git`).
static func clone_name(url: String) -> String:
	var source: String = url.strip_edges().replace("\\", "/")
	while source.ends_with("/"):
		source = source.left(-1)
	var repo_name: String = source.get_file()
	if repo_name == ".git":
		repo_name = source.get_base_dir().get_file()
	if repo_name.contains(":"):
		repo_name = repo_name.get_slice(":", repo_name.get_slice_count(":") - 1)
	return repo_name.trim_suffix(".git")


func _validate_clone(fields: Dictionary) -> String:
	if String(fields["url"]).strip_edges().is_empty():
		return "Enter a repository URL or path."
	var branch: String = String(fields["branch"]).strip_edges()
	if not branch.is_empty():
		var error: String = Core.ref_name_error(branch)
		if not error.is_empty():
			return error
	return Core.new_repository_path_error(String(fields["destination"]))


func _start_clone(fields: Dictionary) -> void:
	var url: String = String(fields["url"]).strip_edges()
	var path: String = String(fields["destination"]).strip_edges()
	var job: int = Core.clone_repository(url, path,
			{"branch": String(fields["branch"]), "submodules": bool(fields["submodules"])})
	if job < 0:
		_toast_error("Cannot clone", L10n.runtime_error(Core.start_error()))
		return
	_clones[job] = {"job": job, "url": url, "path": path, "name": path.replace("\\", "/").get_file(),
		"percent": -1, "text": "", "error": ""}
	clones_changed.emit()


# --- Create and Initialize folder -------------------------------------------

func create() -> void:
	_form.begin("Create repository", "Create repository", _start_create.bind(false))
	_form.hide_on_submit = false
	_form.add_line("name", "Name")
	_form.add_folder("location", "Location", default_clone_folder())
	_form.add_line("branch", "Initial branch", "main", true)
	_add_starter_fields()
	_form.add_note("With a .gitignore or a README, the first commit is made for you.")
	_add_status()
	_form.validator = _validate_create.bind(false)
	_form.open()


## Initializes a folder that has files (`path`, or one chosen in the form).
func init_folder(path: String = "") -> void:
	_form.begin("Initialize folder", "Initialize", _start_create.bind(true))
	_form.hide_on_submit = false
	_form.add_folder("location", "Folder", path)
	_form.add_line("branch", "Initial branch", "main", true)
	_add_starter_fields()
	_form.add_check("first_commit", "Commit the files that are there", true)
	_add_status()
	_form.validator = _validate_create.bind(true)
	_form.open()


func running() -> bool:
	return _form_job != -1


func job_status() -> String:
	return _status.text if is_instance_valid(_status) else ""


func _add_starter_fields() -> void:
	var templates: PackedStringArray = PackedStringArray([tr(NO_TEMPLATE)])
	templates.append_array(Core.gitignore_templates())
	_form.add_choice("gitignore", ".gitignore", templates)
	_form.add_check("readme", "Add a README")


func _add_status() -> void:
	var box: VBoxContainer = VBoxContainer.new()
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	_progress = ProgressBar.new()
	_progress.show_percentage = false
	box.add_child(_progress)
	_form.add_control("status", "", box)
	_form.set_field_visible("status", false)


func _create_path(fields: Dictionary, existing: bool) -> String:
	var location: String = String(fields["location"]).strip_edges()
	return location if existing else location.path_join(String(fields["name"]).strip_edges())


func _validate_create(fields: Dictionary, existing: bool) -> String:
	if running():
		return ""
	if not existing and String(fields["name"]).strip_edges().is_empty():
		return "Enter a repository name."
	if String(fields["location"]).strip_edges().is_empty():
		return "Choose a folder." if existing else "Choose a location."
	var branch_error: String = Core.ref_name_error(String(fields["branch"]))
	if not branch_error.is_empty():
		return branch_error
	var path: String = _create_path(fields, existing)
	return Core.init_folder_error(path) if existing else Core.new_repository_path_error(path)


func _start_create(fields: Dictionary, existing: bool) -> void:
	if running():
		return
	var template: String = String(fields["gitignore"])
	var none: bool = template == tr(NO_TEMPLATE)
	var readme: bool = bool(fields["readme"])
	var options: Dictionary = {
		"initial_branch": String(fields["branch"]),
		"gitignore": "" if none else template,
		"readme": readme,
		"first_commit": bool(fields["first_commit"]) if existing else (readme or not none),
		"existing": existing,
	}
	var job: int = Core.create_repository(_create_path(fields, existing), options)
	if job < 0:
		_show_form_error(L10n.runtime_error(Core.start_error()))
		return
	_form_job = job
	_status.theme_type_variation = &"DimLabel"
	_status.text = tr("Initializing…") if existing else tr("Creating repository…")
	_form.set_field_visible("status", true)
	_set_form_busy(true)


func _set_form_busy(busy: bool) -> void:
	_form.get_ok_button().disabled = busy
	_form.get_cancel_button().text = tr("Cancel operation") if busy else tr("Cancel")
	if is_instance_valid(_progress):
		_progress.visible = busy
		# A new job starts indeterminate until git reports a percentage.
		_progress.indeterminate = busy
		_progress.value = 0
	if not busy:
		_form.revalidate()


func _show_form_error(message: String) -> void:
	if not is_instance_valid(_status):
		_toast_error("The git operation failed.", message)
		return
	_status.theme_type_variation = &"ErrorLabel"
	_status.text = tr(message)
	_form.set_field_visible("status", true)


func _on_form_canceled() -> void:
	if running():
		Core.cancel_repository_job(_form_job)
		_form.popup_centered.call_deferred()


func _on_field_changed(key: String) -> void:
	var destination: LineEdit = _form.field("destination") as LineEdit
	if destination == null:
		return
	if key == "destination":
		_clone_destination_edited = true
	elif key == "url" and not _clone_destination_edited:
		destination.text = _clone_parent.path_join(clone_name(String(_form.values()["url"])))
		_form.revalidate()


# --- Add existing folder and Scan -------------------------------------------

func add_existing() -> void:
	_pick_folder("Add existing folder", "", add_folder)


## A folder chosen or dropped: open it when it is in a repository, else
## offer to initialize it or scan inside.
func add_folder(path: String) -> void:
	_check(path, "", func(result: Dictionary) -> void:
		if not String(result.get("root", "")).is_empty():
			open_requested.emit(path)
			return
		_ask("Not a git repository", tr("“%s” is not in a git repository.") % path,
				"Initialize here", init_folder.bind(path), "Scan inside", scan.bind(path)))


## Scans `root` (or a folder chosen now) for repositories to add.
func scan(root: String = "") -> void:
	if root.is_empty():
		_pick_folder("Scan folder for repositories", "", scan)
		return
	_scan.open(root)


# --- Entry actions ----------------------------------------------------------

## Change location: points entry `path` at another folder of the repository.
func relocate(path: String) -> void:
	var start: String = path if DirAccess.dir_exists_absolute(path) else path.get_base_dir()
	_pick_folder("Change location", start, relocate_to.bind(path))


## Change location to `chosen` (after the folder dialog).
func relocate_to(chosen: String, path: String) -> void:
	_check(chosen, path, func(result: Dictionary) -> void:
		var root: String = String(result.get("root", ""))
		if root.is_empty():
			_toast_error("Not a git repository", tr("“%s” is not in a git repository.") % chosen)
			return
		if int(result.get("same_root", -1)) == 0:
			_ask("Different repository",
					tr("“%s” has a different history than “%s”. Use it anyway?") % [root, path],
					"Use anyway", _relocate.bind(path, root))
			return
		_relocate(path, root))


func rename(path: String, current_name: String) -> void:
	_form.begin("Rename", "Rename", func(fields: Dictionary) -> void:
		Core.library_rename(path, String(fields["name"])))
	_form.hide_on_submit = true
	_form.add_note("Only the name gitbello shows changes; the folder stays as it is.")
	_form.add_line("name", "Name", current_name, false, path.replace("\\", "/").get_file())
	_form.open()


## Removes entry `path` from the list (never its files), with Undo; an open
## repository's tab closes, after asking.
func remove(path: String) -> void:
	if is_open.is_valid() and bool(is_open.call(path)):
		_ask("Remove from list",
				tr("“%s” is open. Remove it from the list and close its tab?") % path.replace("\\", "/").get_file(),
				"Remove and close tab", func() -> void:
					if close_repo.is_valid():
						close_repo.call(path)
					_remove(path))
		_confirm.get_ok_button().theme_type_variation = &"DangerButton"
		return
	_remove(path)


func set_pinned(path: String, pinned: bool) -> void:
	Core.library_pin(path, pinned)


func show_in_file_manager(path: String) -> void:
	OS.shell_show_in_file_manager(path)


func open_in_editor(path: String) -> void:
	var error: String = Core.open_in_editor(path)
	if not error.is_empty():
		_toast_error("Cannot open the editor", L10n.launch_error(error))


func open_terminal(path: String) -> void:
	var error: String = Core.open_terminal(path)
	if not error.is_empty():
		_toast_error("Cannot open a terminal", L10n.launch_error(error))


func copy_path(path: String) -> void:
	DisplayServer.clipboard_set(path)


func _remove(path: String) -> void:
	if not Core.library_remove(path):
		return
	if toasts != null:
		toasts.show_success(tr("Removed %s from the list") % path.replace("\\", "/").get_file(),
				func() -> void: Core.library_undo_remove())


func _relocate(old: String, new: String) -> void:
	# The card shows the new folder.
	Core.library_relocate(old, new)


# --- Helpers ----------------------------------------------------------------

func _pick_folder(title_text: String, start: String, picked: Callable) -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.use_native_dialog = true
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.title = tr(title_text)
	if not start.is_empty():
		dialog.current_dir = start
	dialog.dir_selected.connect(func(path: String) -> void: picked.call(path))
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


## Resolves folder `path` in the background (see `Core.check_location`),
## then calls `done` with the result.
func _check(path: String, expected_for: String, done: Callable) -> void:
	var job: int = Core.check_location(path, expected_for)
	if job < 0:
		_toast_error("Cannot open repository", L10n.runtime_error(Core.start_error()))
		return
	_checks[job] = done


## A question whose OK (`ok_text`) runs `run`, with an optional second
## choice `extra_text` that runs `extra`.
func _ask(title_text: String, text: String, ok_text: String, run: Callable,
		extra_text: String = "", extra: Callable = Callable()) -> void:
	if _confirm != null:
		_confirm.queue_free()
	_confirm = ConfirmationDialog.new()
	_confirm.title = tr(title_text)
	_confirm.dialog_text = text
	_confirm.dialog_autowrap = true
	_confirm.ok_button_text = tr(ok_text)
	_confirm.cancel_button_text = tr("Cancel")
	_confirm.get_ok_button().theme_type_variation = &"PrimaryButton"
	_confirm.confirmed.connect(func() -> void: run.call())
	if not extra_text.is_empty():
		_confirm.add_button(tr(extra_text), false, &"extra")
		_confirm.custom_action.connect(func(_action: StringName) -> void:
			_confirm.hide()
			extra.call())
	add_child(_confirm)
	FormDialog.align_right(_confirm, _confirm.get_ok_button())
	_confirm.min_size.x = _confirm.get_theme_constant(&"width", &"FormDialog")
	_confirm.popup_centered()


func _toast_error(title_text: String, message: String) -> void:
	if toasts != null:
		toasts.show_toast(title_text, message)


func _on_job_progress(job: int, _path: String, _label: String, percent: int, text: String) -> void:
	if _clones.has(job):
		_clones[job]["percent"] = percent
		_clones[job]["text"] = text
		clones_changed.emit()
	elif job == _form_job and is_instance_valid(_progress):
		_progress.indeterminate = percent < 0
		_progress.value = maxf(0.0, float(percent))


func _on_job_finished(job: int, path: String, _label: String, ok: bool, error: Dictionary) -> void:
	if _checks.has(job):
		var done: Callable = _checks[job]
		_checks.erase(job)
		if ok:
			done.call(Core.location_result(job))
		else:
			_toast_error("Cannot open repository", String(error.get("message", "")))
		return
	if _clones.has(job):
		if ok:
			_clones.erase(job)
			clones_changed.emit()
			clone_finished.emit(path)
		else:
			_clones[job]["error"] = String(error.get("message", "The git operation failed."))
			clones_changed.emit()
		return
	if job != _form_job:
		return
	_form_job = -1
	_set_form_busy(false)
	if ok:
		_form.hide()
		open_requested.emit(path)
	else:
		_show_form_error(String(error.get("message", "The git operation failed.")))


func _on_job_cancelled(job: int, _path: String, _label: String) -> void:
	_checks.erase(job)
	if _clones.erase(job):
		clones_changed.emit()
	elif job == _form_job:
		_form_job = -1
		_set_form_busy(false)
		_form.set_field_visible("status", false)
