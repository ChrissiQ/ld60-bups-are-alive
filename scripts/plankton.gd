class_name Plankton
extends RefCounted
## A plankton cell: it does nothing but float, and at some point it bursts and its contents become nutrient in
## the medium (the way phytoplankton lyse, leaving a short-lived cloud of food that bacteria can swim to).

var pos: Vector2  ## relative to the dish centre, like the bups
var born_at: float  ## simulation time (s) at which it appeared
var burst_at: float  ## simulation time (s) at which it bursts (the player is not told)
var units: float  ## nutrient released when it does
var shape: float  ## makes each one's outline a little different


func _init(p_pos: Vector2, p_born_at: float, p_burst_at: float, p_units: float, p_shape: float) -> void:
	pos = p_pos
	born_at = p_born_at
	burst_at = p_burst_at
	units = p_units
	shape = p_shape
