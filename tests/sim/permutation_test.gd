extends SceneTree
## The order dishes are added in, and adding or removing a dish mid-run, change no dish.
##
## Expected values:
## - four dishes (numbers 1-4, mixed flags) added in the given order, the reverse, and two shuffles, run 100 steps: each dish's dump
##   equals its dump in the first pool (diff == "") [derived: a dish's result depends on its own segment only].
## - a fifth dish added after 40 steps leaves the other four equal to the pool that never had it, and itself equal to its lone run
##   started at step 40 (its `step_start` is 0 at its own strike) [derived].
## - a dish removed after 40 steps leaves the others equal to the pool that kept it [derived].
## Needs a GPU (windowed).

const STEPS := 100
const JOIN_AT := 40


func _init() -> void:
	if not SimHarness.begin(self, "permutation_test", "the pooled core (SimCore)"):
		return
	var base: Array = []
	for i in 4:
		var s := Scenario.small(30 + 10 * i, 500.0 + 100.0 * i).seed(20 + i).with_flags({"stationary": i % 2 == 0, "death_husks": i % 2 == 1, "key": i == 2})
		s.number = i + 1
		base.append(s)
	var reference := _run(base, [0, 1, 2, 3])
	for order in [[3, 2, 1, 0], [2, 0, 3, 1], [1, 3, 0, 2]]:
		var got := _run(base, order)
		for i in 4:
			var line := SimHarness.diff(reference[i], got[i])
			TestUtil.show(line == "", "order %s, dish %d: %s" % [order, i + 1, line if line != "" else "same"])
	var extra := Scenario.small(25, 450.0).seed(77)
	extra.number = 5
	var joined := SimHarness.make(_copies(base)).step(JOIN_AT)
	var fifth := joined.add(extra.copy())
	joined.step(STEPS - JOIN_AT)
	var never := SimHarness.make(_copies(base)).step(STEPS)
	for i in 4:
		var line := SimHarness.diff(never.dump(i), joined.dump(i))
		TestUtil.show(line == "", "dish %d with a dish joining mid-run: %s" % [i + 1, line if line != "" else "same"])
	var lone := SimHarness.make([extra.copy()]).step(STEPS - JOIN_AT)
	var line5 := SimHarness.diff(lone.dump(0), joined.dump(fifth))
	TestUtil.show(line5 == "", "the joining dish equals its lone run: %s" % (line5 if line5 != "" else "same"))
	var kept := SimHarness.make(_copies(base)).step(STEPS)
	var cut := SimHarness.make(_copies(base)).step(JOIN_AT)
	cut.remove(3).step(STEPS - JOIN_AT)
	for i in 3:
		var line := SimHarness.diff(kept.dump(i), cut.dump(i))
		TestUtil.show(line == "", "dish %d with a dish removed mid-run: %s" % [i + 1, line if line != "" else "same"])
	TestUtil.finish(self, "OK permutation_test")


func _copies(list: Array) -> Array:
	return list.map(func(s): return s.copy())


## The dumps by dish number - 1, after the dishes were added in `order`.
func _run(base: Array, order: Array) -> Dictionary:
	var h := SimHarness.make([])
	var row_of := {}
	for i in order:
		row_of[i] = h.add(base[i].copy())
	h.step(STEPS)
	var out := {}
	for i in 4:
		out[i] = h.dump(row_of[i])
	return out
