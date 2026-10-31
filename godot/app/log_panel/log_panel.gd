class_name GitLogPanel
extends Tree
## Every git command gitbello ran, newest last (PLAN §3.2): time, repository,
## command, duration and outcome. Fed by `Core.commands_logged`.

const THEME_TYPE: StringName = &"GitLogPanel"
## Rows kept in the panel (the core keeps its own bounded log).
const MAX_ROWS: int = 500

var _last_seq: int = 0
var _root: TreeItem = null


func _ready() -> void:
	columns = 4
	hide_root = true
	column_titles_visible = true
	set_column_title(0, tr("Time"))
	set_column_title(1, tr("Repository"))
	set_column_title(2, tr("Command"))
	set_column_title(3, tr("Result"))
	set_column_expand(0, false)
	set_column_expand(1, false)
	set_column_expand(3, false)
	set_column_custom_minimum_width(0, get_theme_constant(&"time_width", THEME_TYPE))
	set_column_custom_minimum_width(1, get_theme_constant(&"repo_width", THEME_TYPE))
	set_column_custom_minimum_width(3, get_theme_constant(&"result_width", THEME_TYPE))
	_root = create_item()
	Core.commands_logged.connect(fetch)
	visibility_changed.connect(_scroll_to_newest)
	fetch()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		set_column_title(0, tr("Time"))
		set_column_title(1, tr("Repository"))
		set_column_title(2, tr("Command"))
		set_column_title(3, tr("Result"))


## Appends commands logged since the last fetch and follows the newest one.
func fetch() -> void:
	var added: bool = false
	for record: Dictionary in Core.command_log(_last_seq):
		_last_seq = int(record["seq"])
		_append(record)
		added = true
	while _root.get_child_count() > MAX_ROWS:
		_root.get_first_child().free()
	if added and visible:
		scroll_to_item(_root.get_child(_root.get_child_count() - 1))


func row_count() -> int:
	return _root.get_child_count()


func _append(record: Dictionary) -> void:
	var item: TreeItem = _root.create_child()
	var time: String = Time.get_time_string_from_unix_time(int(record["started"]) + _utc_offset())
	item.set_text(0, time)
	item.set_text(1, String(record["repo"]).get_file())
	item.set_tooltip_text(1, String(record["repo"]))
	item.set_text(2, "git " + String(record["command"]))
	item.set_tooltip_text(2, "git " + String(record["command"]))
	var outcome: String = String(record["outcome"])
	var result: String = "%d ms" % int(record["duration_ms"])
	if outcome != "ok":
		result += " · " + outcome
		item.set_custom_color(3, get_theme_color(&"error_color", THEME_TYPE))
	item.set_text(3, result)
	item.set_icon(3, AppTheme.icon(&"StatusSuccess" if outcome == "ok" else &"StatusWarning"))
	item.set_tooltip_text(3, "%s · %s" % [result, outcome])


func _utc_offset() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60


func _scroll_to_newest() -> void:
	if visible and _root.get_child_count() > 0:
		scroll_to_item(_root.get_child(_root.get_child_count() - 1))
