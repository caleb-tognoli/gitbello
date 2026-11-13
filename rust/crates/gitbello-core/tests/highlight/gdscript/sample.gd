class_name Player
extends CharacterBody2D
## Doc comment for the class.

signal health_changed(value: int)

enum State { IDLE, RUN }

const SPEED := 200.0
@export var max_health: int = 100
@onready var label: Label = %NameLabel
@onready var sprite := $Sprite2D

var _state: State = State.IDLE


func _ready() -> void:
	label.text = "Hello %s" % name  # format
	var path := ^"Node/Path"
	var key := &"StringName"
	if max_health > 0 and not is_dead():
		health_changed.emit(0x10)
	elif _state == State.RUN:
		pass
	await get_tree().create_timer(1.5).timeout


func is_dead() -> bool:
	return false
