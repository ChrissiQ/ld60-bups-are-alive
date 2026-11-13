extends SceneTree
## A dish's run does not depend on what shares the pool.
##
## Expected values, written before the first run:
## - dish X (number 1, seed 11, every flag on, resolution 100, 40 founders, radius 600 µm) alone and the same dish with 1, 7 and 64
##   random other dishes beside it: after every 20 steps of 20 s (200 steps in all) the canonical dumps differ nowhere
##   (diff == "") [derived: per-dish segments, RNG and clouds are pooled by dish]. Three seeds for the others.
## - the others' own invariants hold in every run (invariants() empty) [derived].
## Needs a GPU (windowed).

const STEPS := 200
const CHECK_EVERY := 20
const OTHERS := [1, 7, 64]
const SEEDS := [101, 202, 303]


func _init() -> void:
	if not SimHarness.begin(self, "isolation_test", "the pooled core (SimCore)"):
		return
	var x := Scenario.small(40, 600.0).seed(11).with_all_flags()
	x.number = 1
	var lone := SimHarness.make([x.copy()])
	var lone_dumps: Array = []
	for k in STEPS / CHECK_EVERY:
		lone.step(CHECK_EVERY)
		lone_dumps.append(lone.dump(0))
	for n in OTHERS:
		for seed_value in SEEDS:
			var rng := RandomNumberGenerator.new()
			rng.seed = seed_value
			var all: Array = [x.copy()]
			for i in n:
				var o := Scenario.random_other(rng)
				o.number = 2 + i
				all.append(o)
			var pool := SimHarness.make(all)
			for k in STEPS / CHECK_EVERY:
				pool.step(CHECK_EVERY)
				var line := SimHarness.diff(lone_dumps[k], pool.dump(0))
				TestUtil.show(line == "", "X among %d others (seed %d) after %d steps: %s" % [n, seed_value, (k + 1) * CHECK_EVERY, line if line != "" else "same"])
				if line != "":
					break
			var bad := pool.invariants()
			TestUtil.show(bad.is_empty(), "invariants hold among %d others (seed %d) %s" % [n, seed_value, ", ".join(bad)])
	TestUtil.finish(self, "OK isolation_test")
