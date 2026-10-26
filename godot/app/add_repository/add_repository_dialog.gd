class_name AddRepositoryDialog
extends FormDialog
## Create, open or clone a repository from the tab strip's plus button.

signal repository_selected(path: String)

const CREATE: int = 0
const OPEN: int = 1
const CLONE: int = 2

var _mode: int = CREATE
var _job: int = -1
var _clone_destination_edited: bool = false
var _status: Label
var _progress: ProgressBar


func _ready() -> void:
	super._ready()
	hide_on_submit = false
	_status = Label.new()
	_status.theme_type_variation = &"ErrorLabel"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.hide()
	($Box as VBoxContainer).add_child(_status)
	_progress = ProgressBar.new()
	_progress.show_percentage = false
	_progress.hide()
	($Box as VBoxContainer).add_child(_progress)
	field_changed.connect(_on_field_changed)
	canceled.connect(_on_canceled)
	Core.repository_job_progress.connect(_on_job_progress)
	Core.repository_job_finished.connect(_on_job_finished)
	Core.repository_job_cancelled.connect(_on_job_cancelled)


func open() -> void:
	if _job != -1:
		popup_centered()
		return
	_mode = CREATE
	_clone_destination_edited = false
	begin("Add repository", "Create repository", Callable())
	add_choice("action", "Action", PackedStringArray(["Create new", "Open existing", "Clone"]))
	add_line("name", "Repository name")
	var location: String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	add_folder("location", "Location", location)
	add_line("branch", "Initial branch", "main", true)
	add_folder("existing", "Repository folder")
	add_line("url", "Repository URL", "", false, "https://github.com/user/repository.git")
	add_folder("destination", "Destination", location)
	validator = _validate_form
	_status.hide()
	_progress.hide()
	_show_mode(CREATE)
	super.open()


func show_mode(mode: int) -> void:
	_mode = clampi(mode, CREATE, CLONE)
	(field("action") as OptionButton).selected = _mode
	_show_mode(_mode)
	_validate()


func running() -> bool:
	return _job != -1


func pick_folder(key: String, dir: String) -> void:
	if key == "destination":
		_clone_destination_edited = true
	super.pick_folder(key, dir)


func job_status() -> String:
	return _status.text


func _show_mode(mode: int) -> void:
	_mode = mode
	for key: String in ["name", "location", "branch"]:
		set_field_visible(key, mode == CREATE)
	set_field_visible("existing", mode == OPEN)
	for key: String in ["url", "destination"]:
		set_field_visible(key, mode == CLONE)
	ok_button_text = ["Create repository", "Open repository", "Clone repository"][mode] as String


func _validate_form(values: Dictionary) -> String:
	if running():
		return ""
	match _mode:
		CREATE:
			if String(values["name"]).is_empty():
				return "Enter a repository name."
			if String(values["location"]).is_empty():
				return "Choose a location."
			var branch_error: String = Core.ref_name_error(String(values["branch"]))
			if not branch_error.is_empty():
				return branch_error
			return Core.new_repository_path_error(_create_path(values))
		OPEN:
			var path: String = String(values["existing"])
			if path.is_empty():
				return "Choose a repository folder."
			if not DirAccess.dir_exists_absolute(path):
				return "Choose an existing folder."
		CLONE:
			if String(values["url"]).is_empty():
				return "Enter a repository URL or path."
			return Core.new_repository_path_error(String(values["destination"]))
	return ""


func _submit() -> void:
	if running() or not _validate():
		return
	var current: Dictionary = values()
	match _mode:
		OPEN:
			hide()
			repository_selected.emit(String(current["existing"]))
		CREATE:
			_start_job(Core.create_repository(_create_path(current), String(current["branch"])))
		CLONE:
			_start_job(Core.clone_repository(String(current["url"]), String(current["destination"])))


func _start_job(job: int) -> void:
	if job < 0:
		_show_error(Core.start_error())
		return
	_job = job
	_status.theme_type_variation = &"DimLabel"
	_status.text = "Cloning repository…" if _mode == CLONE else "Creating repository…"
	_status.show()
	_progress.value = 0
	_progress.visible = _mode == CLONE
	_set_busy(true)


func _on_field_changed(key: String) -> void:
	if key == "action":
		show_mode((field("action") as OptionButton).selected)
	elif key == "destination":
		_clone_destination_edited = true
	elif key == "url" and not _clone_destination_edited:
		var name: String = _clone_name(String(values()["url"]))
		if not name.is_empty():
			var destination: LineEdit = field("destination") as LineEdit
			destination.text = destination.text.get_base_dir().path_join(name)
			_validate()


func _create_path(current: Dictionary) -> String:
	return String(current["location"]).path_join(String(current["name"]))


static func _clone_name(url: String) -> String:
	var source: String = url.strip_edges().replace("\\", "/")
	while source.ends_with("/"):
		source = source.left(-1)
	var name: String = source.get_file()
	if name == ".git":
		name = source.get_base_dir().get_file()
	return name.trim_suffix(".git")


func _set_busy(busy: bool) -> void:
	for key: String in _fields:
		var control: Control = _fields[key]
		if control is LineEdit:
			(control as LineEdit).editable = not busy
			var browse: Button = control.get_parent().get_child(1) as Button if control.get_parent() is HBoxContainer else null
			if browse != null:
				browse.disabled = busy
		elif control is OptionButton:
			(control as OptionButton).disabled = busy
	get_ok_button().disabled = busy
	get_cancel_button().text = "Cancel operation" if busy else "Cancel"
	if not busy:
		_progress.hide()
		_validate()


func _on_job_progress(job: int, _path: String, _label: String, percent: int, text: String) -> void:
	if job != _job:
		return
	_progress.value = maxf(0.0, float(percent))
	_status.text = text


func _on_job_finished(job: int, path: String, _label: String, ok: bool, error: Dictionary) -> void:
	if job != _job:
		return
	_job = -1
	_set_busy(false)
	if ok:
		hide()
		repository_selected.emit(path)
	else:
		_show_error(String(error.get("message", "The git operation failed.")))


func _on_job_cancelled(job: int, _path: String, _label: String) -> void:
	if job != _job:
		return
	_job = -1
	_set_busy(false)
	_status.hide()


func _on_canceled() -> void:
	if running():
		Core.cancel_repository_job(_job)
		popup_centered.call_deferred()


func _show_error(message: String) -> void:
	_status.theme_type_variation = &"ErrorLabel"
	_status.text = message
	_status.show()
