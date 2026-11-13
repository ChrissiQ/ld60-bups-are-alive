extends SceneTree
## A dish that needs few diffusion iterations is not changed by pooling with one that needs many.
##
## Expected values:
## - a dish of radius 150 µm at resolution 100 (6.25 µm cells) needs 62 diffusion iterations a step at 20 s; a dish of 3000 µm at
##   resolution 100 needs 2 [derived: iterations = ceil(D dt / (cell² x limit)); the 62 is not re-derived
##   here]. Both dishes pooled equal each dish alone after 100 steps (diff == "" for both) [derived: a dish is stepped by its own
##   iteration count, the rest being padding that changes nothing].
## Needs a GPU (windowed).


func _init() -> void:
	if not SimHarness.begin(self, "field_padding_test", "the pooled core (SimCore)"):
		return
	var few := Scenario.small(30, 3000.0).seed(61)
	var many := Scenario.small(30, 150.0).seed(62)
	few.number = 1
	many.number = 2  # (the same number alone and pooled: a dish's ids carry it)
	var pool := SimHarness.make([few.copy(), many.copy()]).step(100)
	for i in 2:
		var alone := SimHarness.make([[few, many][i].copy()]).step(100).dump(0)
		var line := SimHarness.diff(alone, pool.dump(i))
		TestUtil.show(line == "", "dish %d pooled equals alone: %s" % [i, line if line != "" else "same"])
	TestUtil.finish(self, "OK field_padding_test")
