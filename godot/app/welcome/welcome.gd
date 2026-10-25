class_name Welcome
extends CenterContainer
## Shown when no tab is open: open a repository, pick a recent one, or drop a
## folder on the window.

signal open_requested()
signal recent_chosen(path: String)

@onready var _recent: ItemList = %Recent
@onready var _open_button: Button = %OpenButton
@onready var _hint: Label = %Hint


func _ready() -> void:
	_open_button.icon = AppTheme.icon(&"Folder")
	_open_button.theme_type_variation = &"PrimaryButton"
	_open_button.pressed.connect(func() -> void: open_requested.emit())
	_recent.item_activated.connect(_on_recent_activated)
	refresh()


func refresh() -> void:
	_recent.clear()
	for path: String in Core.recent_repos():
		var index: int = _recent.add_item(path.get_file())
		_recent.set_item_tooltip(index, path)
		_recent.set_item_metadata(index, path)
	_recent.visible = _recent.item_count > 0
	var shortcut: String = Actions.shortcut_label(&"repo.open")
	_hint.text = "Open a repository (%s) or drop a folder here" % shortcut if not shortcut.is_empty() \
			else "Open a repository or drop a folder here"


func _on_recent_activated(index: int) -> void:
	recent_chosen.emit(String(_recent.get_item_metadata(index)))
