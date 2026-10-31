class_name ScanDialog
extends ConfirmationDialog
## Scan folder… (PLAN §4 Home): finds the repositories under a folder in the
## background and lists them with check boxes; Add selected puts the checked
## ones in the library. Repositories already there are listed greyed out.
## Changing the depth scans again.

## The repositories added, by path.
signal added(paths: PackedStringArray)

const DEFAULT_DEPTH: int = 3
const MAX_DEPTH: int = 8

var _root: String = ""
var _job: int = -1
var _rows: Array[Dictionary] = []
var _root_label: Label = Label.new()
var _depth: SpinBox = SpinBox.new()
var _status: Label = Label.new()
var _scroll: ScrollContainer = ScrollContainer.new()
## One check box per repository found; its path is the `path` meta.
var _list: VBoxContainer = VBoxContainer.new()


func _ready() -> void:
	var box: VBoxContainer = VBoxContainer.new()
	var top: HBoxContainer = HBoxContainer.new()
	_root_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	top.add_child(_root_label)
	var depth_label: Label = Label.new()
	depth_label.name = "DepthLabel"
	top.add_child(depth_label)
	_depth.min_value = 1
	_depth.max_value = MAX_DEPTH
	_depth.value = DEFAULT_DEPTH
	_depth.value_changed.connect(func(_value: float) -> void: _start())
	top.add_child(_depth)
	box.add_child(top)
	_status.theme_type_variation = &"DimLabel"
	box.add_child(_status)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.custom_minimum_size = Vector2(0, 280)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)
	box.add_child(_scroll)
	add_child(box)
	FormDialog.align_right(self, get_ok_button())
	confirmed.connect(_add_checked)
	canceled.connect(func() -> void:
		if _job != -1:
			Core.cancel_repository_job(_job))
	Core.repository_job_progress.connect(_on_progress)
	Core.repository_job_finished.connect(_on_finished)
	Core.repository_job_cancelled.connect(func(job: int, _path: String, _label: String) -> void:
		if job == _job:
			_job = -1)
	_translate()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_translate()


## Scans `root` and shows the dialog.
func open(root: String) -> void:
	_root = root
	_root_label.text = root
	_root_label.tooltip_text = root
	min_size = Vector2i(get_theme_constant(&"width", &"ScanDialog"), 0)
	popup_centered()
	_start()


func running() -> bool:
	return _job != -1


## Rows found: `{path, worktrees, bare, known}` (see `Core.scan_results`).
func rows() -> Array[Dictionary]:
	return _rows


## Paths whose box is checked.
func checked() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for box: CheckBox in _boxes():
		if box.button_pressed and not box.disabled:
			out.append(String(box.get_meta(&"path")))
	return out


## Checks or unchecks `path`'s box (tests).
func set_checked(path: String, on: bool) -> void:
	for box: CheckBox in _boxes():
		if Paths.same(String(box.get_meta(&"path")), path) and not box.disabled:
			box.button_pressed = on
	_update_ok()


func set_depth(depth: int) -> void:
	_depth.value = depth


func _start() -> void:
	if _root.is_empty():
		return
	if _job != -1:
		Core.cancel_repository_job(_job)
	_rows.clear()
	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_job = Core.scan_repositories(_root, int(_depth.value))
	_status.text = tr("Scanning…")
	_update_ok()


func _on_progress(job: int, _path: String, _label: String, _percent: int, text: String) -> void:
	if job == _job:
		_status.text = tr("Scanning… %s") % text


func _on_finished(job: int, _path: String, _label: String, ok: bool, error: Dictionary) -> void:
	if job != _job:
		return
	_job = -1
	if not ok:
		_status.text = String(error.get("message", ""))
		return
	_rows = Core.scan_results(job)
	var fresh: int = 0
	for row: Dictionary in _rows:
		var path: String = String(row["path"])
		var known: bool = bool(row["known"])
		var box: CheckBox = CheckBox.new()
		box.set_meta(&"path", path)
		box.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		box.toggled.connect(func(_on: bool) -> void: _update_ok())
		var worktrees: int = (row["worktrees"] as PackedStringArray).size()
		var text: String = path.replace("\\", "/")
		if worktrees > 0:
			text += "  " + (tr("(%d worktrees)") % worktrees if worktrees != 1 else tr("(1 worktree)"))
		if known:
			text += "  " + tr("(already in the list)")
		box.text = text
		box.tooltip_text = path
		# Already listed: shown checked and disabled. Bare repositories
		# (remotes, mostly) are rarely wanted in a GUI: unchecked.
		box.button_pressed = known or not bool(row["bare"])
		box.disabled = known
		if not known:
			fresh += 1
		_list.add_child(box)
	if _rows.is_empty():
		_status.text = tr("No repositories found. Try a deeper scan.")
	elif fresh == 0:
		_status.text = tr("Every repository found is in the list already.")
	else:
		_status.text = tr("Found %d repositories.") % _rows.size() if _rows.size() != 1 else tr("Found 1 repository.")
	_update_ok()


func _boxes() -> Array[CheckBox]:
	var out: Array[CheckBox] = []
	for child: Node in _list.get_children():
		if child is CheckBox and not child.is_queued_for_deletion():
			out.append(child as CheckBox)
	return out


func _add_checked() -> void:
	var paths: PackedStringArray = checked()
	var done: PackedStringArray = PackedStringArray()
	for path: String in paths:
		if Core.library_add(path):
			done.append(path)
	added.emit(done)


func _update_ok() -> void:
	var count: int = checked().size()
	get_ok_button().disabled = running() or count == 0
	ok_button_text = tr("Add %d") % count if count > 0 else tr("Add selected")


func _translate() -> void:
	title = tr("Scan folder for repositories")
	cancel_button_text = tr("Cancel")
	get_ok_button().theme_type_variation = &"PrimaryButton"
	(find_child("DepthLabel", true, false) as Label).text = tr("Depth")
	_update_ok()
