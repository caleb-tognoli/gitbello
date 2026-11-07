class_name AvatarView
extends Control
## One person's avatar as a control (`AvatarPainter`), `diameter` wide.

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


func _init(person_name: String = "", person_email: String = "", size_px: float = 20.0) -> void:
	person = person_name
	email = person_email
	diameter = size_px
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _get_minimum_size() -> Vector2:
	return Vector2(diameter, diameter)


func _draw() -> void:
	AvatarPainter.draw(self, self, size * 0.5, diameter, person, email, AppTheme.bold_font())
