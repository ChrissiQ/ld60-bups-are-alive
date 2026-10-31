extends SceneTree
## Freeze and thaw is invisible to the run.
##
## Expected values, written before the first run:
## - run N = 80 steps, freeze, thaw, run M = 80 steps gives a dump with 0 differing words against the dish run N + M = 160 steps
##   straight (diff == "") [derived: a frozen dish keeps its records, field, clouds, husks, RNG state and step; thawing restores them
##   to a new row and the step counter carries on; the harness keeps the dish's world (DishWorld.save()) in the blob and restores it].
## Needs a GPU. Windowed only.

const N := 80
const M := 80


func _init() -> void:
	if not SimHarness.begin(self, "continuation_test", "SimCore"):
		return
	for flags in [{}, {"stationary": true, "death_husks": true, "plankton_husks": true, "acetate": true, "key": true, "conjugation": true}]:
		var s := Scenario.small(40, 600.0).seed(31).with_flags(flags)
		s.bloom_density = 2.0
		var straight := SimHarness.make([s.copy()]).step(N + M)
		var h := SimHarness.make([s.copy()]).step(N)
		var blob: Variant = h.freeze(0)
		var row := h.thaw(blob)
		h.step(M)
		var line := SimHarness.diff(straight.dump(0), h.dump(row))
		TestUtil.show(line == "", "flags %s: freeze at %d and thaw equals the straight run: %s" % [flags.keys(), N, line if line != "" else "same"])
	TestUtil.finish(self, "OK continuation_test")
