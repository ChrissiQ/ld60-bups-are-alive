extends SceneTree
## Run: godot --headless --path . -s tests/smoke.gd
## Plays the intended strategy: feed hard for goal 1, then starve for goal 2.

func _init() -> void:
	var dish := Dish.new()
	root.add_child(dish)
	dish.rng.seed = 1
	dish.strike()
	dish.food_rate = 16.0
	var tracker := GoalTracker.new()
	tracker.goal_completed.connect(func(g: Goal) -> void:
		print("COMPLETE '%s' at t=%.0fs pop=%d sense=%.0f" % [g.title, dish.time, dish.cells.size(), dish.mean_gene("sense")]))
	var max_t := 4000
	for t in max_t:
		if tracker.index == 1:
			dish.food_rate = 5.0
		for i in 30:
			dish.step(1.0 / 30.0)
			tracker.update(dish, 1.0 / 30.0)
		if dish.cells.is_empty() or tracker.all_done():
			break
	print("history samples=%d goals_done=%d/%d pop=%d" % [dish.history["pop"].size(), tracker.index, tracker.goals.size(), dish.cells.size()])
	quit(0 if tracker.all_done() else 1)
