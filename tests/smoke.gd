extends SceneTree
## Run: godot --headless --path . -s tests/smoke.gd
## Plays goal mode as intended, in real simulation time, on the dish goal mode starts with: wait for experiment 1; then, as the game does
## when it is done (scripts/main.gd's _on_goal_completed), make staying alive cost more and let the plankton bloom at the rate the
## experiment's text suggests. Fails if either experiment is not done within MAX_DAYS simulated days (or the colony dies out).

const DAY := 86400.0
const CHUNK := 300.0  ## seconds of simulation time per call
const MAX_DAYS := 30

func _init() -> void:
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(1)
	dish.strike()
	var tracker := GoalTracker.new()
	tracker.goal_completed.connect(func(g: Goal) -> void:
		print("COMPLETE '%s' at %s pop=%d sense=%.0f" % [g.title, SimClock.format(dish.time), dish.population(), dish.population_stats()["sense"]])
		if tracker.index >= 1:
			dish.upkeep_factor = Dish.GOAL_UPKEEP_FACTOR  # (as _on_goal_completed does: experiment 2 and after cost more to stay alive)
			dish.bloom_density = Dish.SUGGESTED_BLOOM_DENSITY)  # (the bloom the goal's text suggests; the plankton tools unlock with experiment 2)
	var started := Time.get_ticks_msec()
	while dish.time < MAX_DAYS * DAY:
		dish.advance(CHUNK)
		tracker.update(dish, CHUNK)
		if dish.population() == 0 or tracker.all_done():
			break
	print("history samples=%d goals_done=%d/%d pop=%d at %s (%.0f s real)" % [dish.history["pop"].size(), tracker.index, tracker.goals.size(), dish.population(), SimClock.format(dish.time), (Time.get_ticks_msec() - started) / 1000.0])
	quit(0 if tracker.all_done() else 1)
