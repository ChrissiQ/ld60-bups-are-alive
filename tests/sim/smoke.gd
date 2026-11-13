extends SceneTree
## Windowed only. On macOS: tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/smoke.gd
## Plays goal mode as intended, in simulation time, on the pooled world with the dish goal mode starts with (`dish.strike(null)`), at
## x10,000: wait for experiment 1; then, as the game does when it is done (scripts/main.gd's _on_goal_completed), make staying alive
## cost more and let the plankton bloom at the rate the experiment's text suggests. Fails if either experiment is not done within
## MAX_DAYS simulated days (or the colony dies out). SMOKE_SEED=<n> sets the dish's seed (default 1).

const DAY := 86400.0
const MAX_DAYS := 30
const SPEED := 10000.0


func _initialize() -> void:
	_run()


func _run() -> void:
	var g := ParityGame.start(self, "smoke")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK smoke")
		return
	var seed_value := int(OS.get_environment("SMOKE_SEED")) if OS.get_environment("SMOKE_SEED") != "" else 1
	var dish := await g.strike(null, seed_value)
	g.look_at(dish, 0.05)
	var tracker := GoalTracker.new()
	tracker.goal_completed.connect(func(goal: Goal) -> void:
		print("COMPLETE '%s' at %s pop=%d sense=%.0f" % [goal.title, SimClock.format(dish.time), dish.population(), dish.population_stats()["sense"]])
		if tracker.index >= 1:
			dish.upkeep_factor = Dish.GOAL_UPKEEP_FACTOR  # (as _on_goal_completed does: experiment 2 and after cost more to stay alive)
			dish.bloom_density = Dish.SUGGESTED_BLOOM_DENSITY)  # (the bloom the goal's text suggests; the plankton tools unlock with experiment 2)
	var started := Time.get_ticks_msec()
	var last := dish.time
	while dish.time < MAX_DAYS * DAY:
		await g.frame(SPEED, false)
		tracker.update(dish, dish.time - last)
		last = dish.time
		if (dish.population() == 0 and dish.time > 0.0) or tracker.all_done():
			break
	print("history samples=%d goals_done=%d/%d pop=%d at %s (%.0f s real)" % [dish.history.fine["pop"].size(), tracker.index, tracker.goals.size(), dish.population(), SimClock.format(dish.time), (Time.get_ticks_msec() - started) / 1000.0])
	TestUtil.show(tracker.all_done(), "both experiments done within %d days" % MAX_DAYS)
	TestUtil.finish(self, "OK smoke")
