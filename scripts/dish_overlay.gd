class_name DishOverlay
extends Node2D
## Drawn above the dish's bups: the selection and hover rings, the placement preview and the
## lightning flash. The dish says what to draw (Dish.draw_overlay); this node only gives it a
## canvas that sits on top of the instanced bups.

var dish: Dish = null


func _draw() -> void:
	if dish != null:
		dish.draw_overlay(self)
