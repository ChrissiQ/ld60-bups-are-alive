class_name NutrientSource
extends RefCounted
## A feeder that keeps releasing nutrient into the medium at a steady rate: a pipette or an
## agar plug. Unlike a one-off dose it keeps going, so it builds a gradient that bups can follow.

var pos: Vector2  ## global (bups are held relative to the dish centre: see Dish.bup_world_pos)
var rate: float  ## nutrient released per minute
var emitted := 0.0  ## nutrient released so far


func _init(p_pos: Vector2, p_rate: float) -> void:
	pos = p_pos
	rate = p_rate
