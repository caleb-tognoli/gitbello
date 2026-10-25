class_name Welcome
extends EmptyState
## Shown when no tab is open (PLAN §4), in the empty-state pattern: big
## buttons to open a repository or one of the recent ones; a folder can also
## be dropped on the window.

signal open_requested()
signal recent_chosen(path: String)

## Recent repositories offered as buttons.
const MAX_RECENT: int = 6


func _ready() -> void:
	refresh()


func refresh() -> void:
	if not is_node_ready():
		return
	var shortcut: String = Actions.shortcut_label(&"repo.open")
	show_state("gitbello", "Open a repository (%s) or drop a folder here" % shortcut if not shortcut.is_empty() \
			else "Open a repository or drop a folder here", [])
	var open_button: Button = add_button("Open repository…", &"Folder", func() -> void: open_requested.emit())
	open_button.theme_type_variation = &"PrimarySuggestionButton"
	var recent: PackedStringArray = Core.recent_repos()
	for i: int in mini(recent.size(), MAX_RECENT):
		var path: String = recent[i]
		var button: Button = add_button(path.replace("\\", "/").trim_suffix("/").get_file(), &"History",
				func() -> void: recent_chosen.emit(path))
		button.tooltip_text = path
