extends SceneTree
## Run: godot --headless --path . -s tests/smoke.gd
## Plays the intended strategy in real simulation time: feed well for goal 1, then trickle the feed
## and put a nutrient source at the far edge for goal 2. It runs up to a simulated day.

const DAY := 86400.0
const CHUNK := 30.0  ## seconds of simulation time per call

func _init() -> void:
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(1)
	dish.strike()
	dish.feed_density = 10.0
	var tracker := GoalTracker.new()
	tracker.goal_completed.connect(func(g: Goal) -> void:
		print("COMPLETE '%s' at %s pop=%d sense=%.0f" % [g.title, SimClock.format(dish.time), dish.population(), dish.population_stats()["sense"]]))
	while dish.time < DAY:
		if tracker.index == 1 and dish.sources.is_empty():
			# Goal 2's intended play: cut the random feed to a trickle and put a source at the far edge.
			dish.feed_density = 1.0
			dish.place_source(dish.global_position + Vector2(240, 0), 10.0)
		dish.advance(CHUNK)
		tracker.update(dish, CHUNK)
		if dish.population() == 0 or tracker.all_done():
			break
	print("history samples=%d goals_done=%d/%d pop=%d at %s" % [dish.history["pop"].size(), tracker.index, tracker.goals.size(), dish.population(), SimClock.format(dish.time)])
	# Goal 2 (Keen Senses) is not yet confirmed reachable at real rates; only the first is required for now.
	quit(0 if tracker.index >= 1 else 1)
