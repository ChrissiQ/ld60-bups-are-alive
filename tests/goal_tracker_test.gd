extends SceneTree
## Run: godot --headless --path . -s tests/goal_tracker_test.gd
## GoalTracker's ladder on a stub dish (population and the sense fraction are set by hand), the single-dish path's behaviour. Expected values are derived from
## scripts/goal_tracker.gd. Experiment 1 at 1,000 bups, experiment 2 at half the bups with sense >= 70
## held 1,800 s with at least 15 bups, upkeep x3 from experiment 2, nutrient tools unlocked from experiment 2.


class StubDish extends Dish:
	var pop := 0
	var fraction := 0.0

	func population() -> int:
		return pop

	func fraction_with_gene_at_least(_gene: String, _threshold: float) -> float:
		return fraction


func _init() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var t := GoalTracker.new()
	var d := StubDish.new()
	var done: Array = []
	t.goal_completed.connect(func(g: Goal) -> void: done.append(g))
	TestUtil.check(t.goals.size() == 2 and t.index == 0 and not t.all_done() and t.current() == t.goals[0], "two goals, starting at the first")
	TestUtil.check(GoalTracker.POP_TARGET == 1000 and GoalTracker.SENSE_TARGET == 70.0 and GoalTracker.SENSE_FRACTION == 0.5 and GoalTracker.SENSE_MIN_POP == 15 and GoalTracker.SENSE_HOLD == 1800.0, "the ladder's constants")
	TestUtil.check(t.goals[0].hold_time == 0.0 and t.goals[1].hold_time == 1800.0, "hold times 0 and 1,800 s")

	# Experiment 1.
	d.pop = 999
	TestUtil.check(is_equal_approx(t.goals[0].progress.call(d), 0.999), "999 bups: progress 0.999")
	t.update(d, 1.0)
	TestUtil.check(t.index == 0 and done.is_empty(), "999 bups: no completion")
	d.pop = 5000
	TestUtil.check(t.goals[0].progress.call(d) == 1.0, "progress is capped at 1")
	TestUtil.check(not t.tools_unlocked(), "tools locked in experiment 1")
	var plain := StubDish.new()
	t.apply_costs(plain)
	TestUtil.check(plain.upkeep_factor == 1.0, "experiment 1 leaves upkeep at x1")
	d.pop = 1000
	t.update(d, 0.5)
	TestUtil.check(t.index == 1 and done.size() == 1 and done[0] == t.goals[0] and t.held == 0.0, "1,000 bups with a hold of 0 completes at once, once")
	t.update(d, 0.5)
	TestUtil.check(done.size() == 1, "goal_completed was emitted once")

	# After experiment 1.
	TestUtil.check(t.tools_unlocked(), "tools unlock at index 1")
	t.apply_costs(plain)
	TestUtil.check(plain.upkeep_factor == Dish.GOAL_UPKEEP_FACTOR and Dish.GOAL_UPKEEP_FACTOR == 3.0, "index 1 sets upkeep x3")

	# Experiment 2.
	d.pop = 100
	d.fraction = 0.25
	TestUtil.check(is_equal_approx(t.goals[1].progress.call(d), 0.5), "fraction 0.25 of a needed 0.5 is progress 0.5")
	d.fraction = 0.5
	TestUtil.check(t.goals[1].progress.call(d) == 1.0, "fraction 0.5: progress 1")
	d.pop = 14
	TestUtil.check(t.goals[1].progress.call(d) == 0.0, "under 15 bups: progress 0 whatever the fraction")
	d.pop = 15
	TestUtil.check(t.goals[1].progress.call(d) == 1.0, "15 bups is enough")
	d.pop = 100
	t.update(d, 1799.0)
	TestUtil.check(t.index == 1 and t.held == 1799.0 and done.size() == 1, "1,799 s at the fraction: not complete, held 1,799")
	d.fraction = 0.4
	t.update(d, 1.0)
	TestUtil.check(t.index == 1 and t.held == 0.0, "a dip below the fraction resets the hold to 0")
	d.fraction = 0.5
	t.update(d, 1800.0)
	TestUtil.check(t.index == 2 and done.size() == 2 and done[1] == t.goals[1] and t.all_done() and t.current() == null, "1,800 s held completes experiment 2")
	t.update(d, 1.0)
	TestUtil.check(done.size() == 2 and t.index == 2, "nothing more after the last goal")

	# An empty dish never counts, and the pop < 15 dip resets the hold.
	var t2 := GoalTracker.new()
	t2.index = 1
	d.pop = 100
	t2.update(d, 600.0)
	d.pop = 14
	t2.update(d, 1.0)
	TestUtil.check(t2.held == 0.0, "falling under 15 bups resets the hold")
	d.pop = 0
	t2.held = 7.0
	t2.update(d, 1.0)
	TestUtil.check(t2.held == 7.0 and t2.index == 1, "an empty dish leaves the tracker as it is")

	# Save format.
	var t3 := GoalTracker.new()
	t3.from_dict({"index": 9, "held": 12.5})
	TestUtil.check(t3.index == 2 and t3.held == 12.5, "from_dict clamps the index to the ladder's length")
	TestUtil.check(t3.to_dict() == {"index": 2, "held": 12.5}, "to_dict is index and held")

	for x in [d, plain]:
		x.free()
	TestUtil.finish(self, "goal_tracker_test OK (%d checks)" % TestUtil.checks)
