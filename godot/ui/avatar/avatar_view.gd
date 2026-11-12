class_name AvatarView
extends Control
## One person's avatar as a control (`AvatarPainter`), `diameter` wide.
## With a `session` it shows their profile picture once there.

var person: String = "":
	set(value):
		person = value
		queue_redraw()
var email: String = "":
	set(value):
		email = value
		queue_redraw()
var diameter: float = 20.0:
	set(value):
		diameter = value
		update_minimum_size()
		queue_redraw()
var session: RepoSession = null:
	set(value):
		session = value
		queue_redraw()


func _init(person_name: String = "", person_email: String = "", size_px: float = 20.0) -> void:
	person = person_name
	email = person_email
	diameter = size_px
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	AvatarPictures.shared().changed.connect(_on_picture_changed)


func _on_picture_changed(changed_email: String) -> void:
	if changed_email.is_empty() or changed_email == AvatarPictures.normalize(email):
		queue_redraw()


func _get_minimum_size() -> Vector2:
	return Vector2(diameter, diameter)


func _draw() -> void:
	AvatarPainter.draw(self, self, size * 0.5, diameter, person, email, AppTheme.bold_font(),
			Color(0, 0, 0, 0), 1.5, 1.0, session)
