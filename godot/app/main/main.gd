class_name Main
extends PanelContainer
## App shell root. M0: shows the core version to prove the native boundary works.

const MIN_WINDOW_SIZE: Vector2i = Vector2i(960, 600)

@onready var _version_label: Label = %VersionLabel


func _ready() -> void:
	get_window().min_size = MIN_WINDOW_SIZE
	_version_label.text = "gitbello · core %s" % Core.core_version()
