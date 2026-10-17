class_name Goal
extends RefCounted
## One objective. `progress` maps a Dish to 0..1; the goal is met once it
## stays at 1 for `hold_time` simulated seconds.

var title: String
var text: String
var hold_time: float
var progress: Callable  ## (Dish) -> float
var status: Callable  ## (Dish) -> String


func _init(p_title: String, p_text: String, p_hold: float, p_progress: Callable, p_status: Callable) -> void:
	title = p_title
	text = p_text
	hold_time = p_hold
	progress = p_progress
	status = p_status
