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


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		refresh()


func refresh() -> void:
	if not is_node_ready():
		return
	var shortcut: String = Actions.shortcut_label(&"repo.open")
	show_state("gitbello", tr("Open a repository (%s) or drop a folder here") % shortcut if not shortcut.is_empty() \
			else tr("Open a repository or drop a folder here"), [])
	var open_button: Button = add_button("Open repository…", &"Folder", func() -> void: open_requested.emit())
	open_button.theme_type_variation = &"PrimarySuggestionButton"
	var recent: PackedStringArray = Core.recent_repos().slice(0, MAX_RECENT)
	var labels: PackedStringArray = _recent_labels(recent)
	for i: int in recent.size():
		var path: String = recent[i]
		var button: Button = add_button(labels[i], &"History", func() -> void: recent_chosen.emit(path))
		button.clip_text = true
		button.tooltip_text = path


func _recent_labels(paths: PackedStringArray) -> PackedStringArray:
	var recent: PackedStringArray = paths.slice(0, MAX_RECENT)
	var labels: PackedStringArray = PackedStringArray()
	for i: int in recent.size():
		var name: String = _recent_name(recent[i])
		var peers: PackedStringArray = PackedStringArray()
		for j: int in recent.size():
			if i != j and Paths.same(name, _recent_name(recent[j])):
				peers.append(recent[j])
		if peers.is_empty():
			labels.append(name)
			continue
		var depth: int = 1
		var context: String = _parent_suffix(recent[i], depth)
		while true:
			var ambiguous: bool = false
			for peer: String in peers:
				if Paths.same(context, _parent_suffix(peer, depth)):
					ambiguous = true
					break
			var longer: String = _parent_suffix(recent[i], depth + 1)
			if not ambiguous or context == longer:
				break
			depth += 1
			context = longer
		labels.append("%s · %s" % [name, context])
	return labels


func _recent_name(path: String) -> String:
	var slashed: String = path.replace("\\", "/").rstrip("/")
	return slashed.get_file() if not slashed.is_empty() else "/"


func _parent_suffix(path: String, depth: int) -> String:
	var parent: String = path.replace("\\", "/").rstrip("/").get_base_dir()
	var parts: PackedStringArray = parent.split("/", false)
	if parts.is_empty():
		return "/"
	if parent.ends_with(":"):
		return parent + "/"
	var suffix: String = "/".join(parts.slice(maxi(0, parts.size() - depth)))
	return "//" + suffix if parent.begins_with("//") and depth >= parts.size() else suffix
