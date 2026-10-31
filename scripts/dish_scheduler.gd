class_name DishScheduler
extends RefCounted
## The world's clock as the screen sees it. The simulation keeps the one clock and steps every dish to it; once a frame the screen tells it
## the speed, whether the game holds, and the frame's real length (WorldClient.set_time: the simulation owes speed x the frame, capped as
## it caps it), and reads back how far the clock moved.

var dishes: Array[Dish]
var _last := -1.0  ## the world's time at the last frame (-1: none yet)


func _init(all: Array[Dish]) -> void:
	dishes = all


## Once a frame, with the frame's real length (uncapped). Returns how far the world's clock moved since the last frame.
func advance(speed: float, holding: bool, real_dt: float) -> float:
	var w := WorldClient.shared()
	w.set_time(speed, holding, real_dt)
	var now := w.latest().sim_time
	var moved := 0.0 if _last < 0.0 else maxf(now - _last, 0.0)
	_last = now
	return moved


## The world's time, as the newest snapshot has it.
func world_time() -> float:
	return WorldClient.shared().latest().sim_time
