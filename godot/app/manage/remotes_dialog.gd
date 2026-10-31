class_name RemotesDialog
extends AcceptDialog
## Repository → Remotes… (PLAN §4): the remotes with their URLs; add one,
## change a URL, rename or remove. The forms and confirmations are RepoOps'.

const THEME_TYPE: StringName = &"ManageDialog"

var _tree: Tree = Tree.new()
var _ops: RepoOps = null
var _session: RepoSession = null
var _buttons: Dictionary[String, Button] = {}


func _ready() -> void:
	title = tr("Remotes")
	ok_button_text = tr("Close")
	var box: VBoxContainer = VBoxContainer.new()
	add_child(box)
	_tree.hide_root = true
	_tree.columns = 2
	_tree.column_titles_visible = true
	_tree.set_column_title(0, tr("Name"))
	_tree.set_column_title(1, "URL")
	_tree.set_column_expand(0, false)
	_tree.set_column_custom_minimum_width(0, 140)
	_tree.select_mode = Tree.SELECT_ROW
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_selected.connect(_update_buttons)
	_tree.item_activated.connect(func() -> void: _run("url"))
	box.add_child(_tree)
	var row: HBoxContainer = HBoxContainer.new()
	box.add_child(row)
	for entry: Array in [["add", "Add…", &"Add"], ["url", "Change URL…", &"Rename"], ["rename", "Rename…", &"Rename"],
			["remove", "Remove…", &"Remove"]]:
		var button: Button = Button.new()
		button.text = tr(entry[1])
		button.set_meta(&"label", entry[1])
		button.icon = AppTheme.icon(entry[2])
		button.pressed.connect(_run.bind(String(entry[0])))
		row.add_child(button)
		_buttons[String(entry[0])] = button


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		title = tr("Remotes")
		ok_button_text = tr("Close")
		_tree.set_column_title(0, tr("Name"))
		for button: Button in _buttons.values():
			button.text = tr(String(button.get_meta(&"label")))
		if _session != null:
			_rebuild()


## Shows the remotes of `ops`' worktree.
func open(ops: RepoOps) -> void:
	if _session != null and _session.refs_changed.is_connected(_rebuild):
		_session.refs_changed.disconnect(_rebuild)
	_ops = ops
	_session = ops.session
	_session.refs_changed.connect(_rebuild)
	_rebuild()
	popup_centered(Vector2i(get_theme_constant(&"width", THEME_TYPE), get_theme_constant(&"height", THEME_TYPE)))


## `name  url` per remote (for tests).
func rows() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var root: TreeItem = _tree.get_root()
	if root != null:
		for item: TreeItem in root.get_children():
			out.append("%s  %s" % [item.get_text(0), item.get_text(1)])
	return out


func select(remote_name: String) -> void:
	var root: TreeItem = _tree.get_root()
	if root == null:
		return
	for item: TreeItem in root.get_children():
		if item.get_text(0) == remote_name:
			item.select(0)
	_update_buttons()


func press(button: String) -> void:
	_run(button)


func _rebuild() -> void:
	var chosen: String = _selected()
	_tree.clear()
	var root: TreeItem = _tree.create_item()
	for remote: Dictionary in _session.remote_list():
		var item: TreeItem = _tree.create_item(root)
		var fetch_url: String = String(remote["fetch_url"])
		var push_url: String = String(remote["push_url"])
		item.set_text(0, String(remote["name"]))
		item.set_text(1, fetch_url if fetch_url == push_url else tr("%s (push: %s)") % [fetch_url, push_url])
		item.set_tooltip_text(1, item.get_text(1))
		if String(remote["name"]) == chosen:
			item.select(0)
	_update_buttons()


func _selected() -> String:
	var item: TreeItem = _tree.get_selected()
	return item.get_text(0) if item != null else ""


func _update_buttons() -> void:
	var none: bool = _selected().is_empty()
	for key: String in ["url", "rename", "remove"]:
		_buttons[key].disabled = none


func _run(button: String) -> void:
	var remote_name: String = _selected()
	match button:
		"add":
			_ops.add_remote()
		"url":
			if not remote_name.is_empty():
				_ops.edit_remote_url(remote_name)
		"rename":
			if not remote_name.is_empty():
				_ops.rename_remote(remote_name)
		"remove":
			if not remote_name.is_empty():
				_ops.remove_remote(remote_name)
