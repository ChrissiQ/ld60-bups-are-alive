class_name StillBups
extends Node2D
## The still picture a dish stands in for when the world has no device to run it: the founders of a start as dots in their own
## colours, scattered over the dish. A child of the `Dish` it stands in for (it takes the dish's place and scale), drawn above it.

const DOT_PIXELS := 3.0  ## the dots' radius on screen
const SCATTER_SEED := 7  ## the same scatter for the same start
const SCATTER_SHARE := 0.8  ## how far out of the dish's radius the dots go

var _start: StartConditions
var _radius := 0.0


## Shows `start`'s founders over a dish of `radius` µm; null shows nothing.
func show_start(start: StartConditions, radius: float) -> void:
	_start = start
	_radius = radius
	queue_redraw()


func _draw() -> void:
	if _start == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = SCATTER_SEED
	var scale_now := maxf(get_global_transform().get_scale().x, 0.0001)
	for i in _start.founders.size():
		var at := Vector2.from_angle(rng.randf() * TAU) * _radius * SCATTER_SHARE * sqrt(rng.randf())
		draw_circle(at, DOT_PIXELS / scale_now, Genome.color_from_hex(_start.founders[i].get("color")))
