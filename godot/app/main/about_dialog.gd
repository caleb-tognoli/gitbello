class_name AboutDialog
extends AcceptDialog
## Help → About gitbello: the logo beside the version and what gitbello is.

const THEME_TYPE: StringName = &"AboutDialog"
## Also the GitHub description and `application/config/description`.
const TAGLINE: String = "A fast, open-source Git GUI that keeps every repository and worktree you're juggling within reach."

var _logo: TextureRect = TextureRect.new()
var _text: Label = Label.new()


func _ready() -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.theme_type_variation = &"AboutRow"
	_logo.texture = AppTheme.logo()
	_logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_logo.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(_logo)
	_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(_text)
	add_child(row)


func show_about() -> void:
	title = tr("About gitbello")
	var side: float = float(get_theme_constant(&"logo_size", THEME_TYPE))
	_logo.custom_minimum_size = Vector2(side, side)
	# A wrapping label measures its height at its current width, which is 0
	# before the first popup: size it before giving it text.
	var width: float = float(get_theme_constant(&"text_width", THEME_TYPE))
	_text.custom_minimum_size.x = width
	_text.size = Vector2(width, 0.0)
	_text.text = "gitbello %s\n%s\n\ngit %s · Godot %s" % [Core.core_version(), tr(TAGLINE),
		Core.git_version(), Engine.get_version_info()["string"]]
	reset_size()
	popup_centered()


## The text beside the logo, for tests.
func text() -> String:
	return _text.text


func has_logo() -> bool:
	return _logo.texture != null
