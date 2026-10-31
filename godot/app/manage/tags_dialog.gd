class_name TagsDialog
extends AcceptDialog
## Repository → Tags… (PLAN §4): the tags with their commits; tag HEAD, push
## or delete one. The forms and confirmations are RepoOps'.

const THEME_TYPE: StringName = &"ManageDialog"

var _tree: Tree = Tree.new()
var _ops: RepoOps = null
var _session: RepoSession = null
var _buttons: Dictionary[String, Button] = {}


func _ready() -> void:
	title = tr("Tags")
	ok_button_text = tr("Close")
	var box: VBoxContainer = VBoxContainer.new()
	add_child(box)
	_tree.hide_root = true
	_tree.columns = 3
	_tree.column_titles_visible = true
	_tree.set_column_title(0, tr("Tag"))
	_tree.set_column_title(1, tr("Commit"))
	_tree.set_column_title(2, tr("Kind"))
	_tree.set_column_expand(1, false)
	_tree.set_column_expand(2, false)
	_tree.set_column_custom_minimum_width(1, 90)
	_tree.set_column_custom_minimum_width(2, 100)
	_tree.select_mode = Tree.SELECT_ROW
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_selected.connect(_update_buttons)
	box.add_child(_tree)
	var row: HBoxContainer = HBoxContainer.new()
	box.add_child(row)
	for entry: Array in [["new", "Tag HEAD…", &"Add"], ["push", "Push", &"GitPush"], ["delete", "Delete…", &"Remove"]]:
		var button: Button = Button.new()
		button.text = tr(entry[1])
		button.icon = AppTheme.icon(entry[2])
		button.pressed.connect(_run.bind(String(entry[0])))
		row.add_child(button)
		_buttons[String(entry[0])] = button


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_tree.set_column_title(0, tr("Tag"))
		_tree.set_column_title(1, tr("Commit"))
		_tree.set_column_title(2, tr("Kind"))
		_buttons["new"].text = tr("Tag HEAD…")
		_buttons["push"].text = tr("Push")
		_buttons["delete"].text = tr("Delete…")
		if _session != null:
			_rebuild()


## Shows the tags of `ops`' repository.
func open(ops: RepoOps) -> void:
	if _session != null and _session.refs_changed.is_connected(_rebuild):
		_session.refs_changed.disconnect(_rebuild)
	_ops = ops
	_session = ops.session
	_session.refs_changed.connect(_rebuild)
	_rebuild()
	popup_centered(Vector2i(get_theme_constant(&"width", THEME_TYPE), get_theme_constant(&"height", THEME_TYPE)))


## Tag names in order (for tests).
func rows() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var root: TreeItem = _tree.get_root()
	if root != null:
		for item: TreeItem in root.get_children():
			out.append(item.get_text(0))
	return out


func _rebuild() -> void:
	var chosen: String = _selected()
	_tree.clear()
	var root: TreeItem = _tree.create_item()
	for tag: Dictionary in _session.tags():
		var item: TreeItem = _tree.create_item(root)
		item.set_text(0, String(tag["name"]))
		item.set_text(1, String(tag["commit"]).left(7))
		item.set_text(2, tr("annotated") if bool(tag["annotated"]) else tr("lightweight"))
		if String(tag["name"]) == chosen:
			item.select(0)
	_update_buttons()


func _selected() -> String:
	var item: TreeItem = _tree.get_selected()
	return item.get_text(0) if item != null else ""


func _update_buttons() -> void:
	var none: bool = _selected().is_empty()
	_buttons["push"].disabled = none or _session.default_remote().is_empty()
	_buttons["delete"].disabled = none
	_buttons["new"].disabled = String(_session.status().get("oid", "")).is_empty()


func _run(button: String) -> void:
	var name: String = _selected()
	match button:
		"new":
			var head: String = _session.current_branch()
			_ops.new_tag("HEAD", head if not head.is_empty() else "HEAD")
		"push":
			if not name.is_empty():
				_ops.push_tag(name)
		"delete":
			if not name.is_empty():
				_ops.delete_tag(name)
