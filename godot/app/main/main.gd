class_name Main
extends PanelContainer
## App shell root. M1: one history view; the repository comes from
## `-- --repo=<path>` on the command line or the Open button.

const MIN_WINDOW_SIZE: Vector2i = Vector2i(960, 600)
const REPO_ARG: String = "--repo="

@onready var _version_label: Label = %VersionLabel
@onready var _history: HistoryView = %HistoryView


func _ready() -> void:
	get_window().min_size = MIN_WINDOW_SIZE
	_version_label.text = "gitbello · core %s" % Core.core_version()
	var repo: String = repo_from_args(OS.get_cmdline_user_args())
	if not repo.is_empty():
		_history.open_repo(repo)


func history() -> HistoryView:
	return _history


static func repo_from_args(args: PackedStringArray) -> String:
	for arg: String in args:
		if arg.begins_with(REPO_ARG):
			return arg.trim_prefix(REPO_ARG)
	return ""
