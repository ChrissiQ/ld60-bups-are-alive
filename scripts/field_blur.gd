extends Node
## A text field lets go of the keyboard when a click lands anywhere but on it (autoload "FieldBlur"). The engine only moves focus to another control that takes focus,
## so a click on the dish or on a label left the caret flashing in the field and the keys going to it. Leaving a field still does what the field does on losing focus (a
## number is kept, a name committed).


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		release_if_outside(get_viewport().gui_get_focus_owner(), event.global_position)


## Takes the focus from `owner` when it is a text field and `point` (a position in its viewport) is not on it.
static func release_if_outside(owner: Control, point: Vector2) -> void:
	if (owner is LineEdit or owner is TextEdit) and not owner.get_global_rect().has_point(point):
		owner.release_focus()
