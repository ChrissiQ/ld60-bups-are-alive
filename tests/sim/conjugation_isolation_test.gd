extends SceneTree
## A donor in one dish touches nothing in another.
##
## Expected values, written before the first run:
## - dishes X and Z (donors every fifth founder) on either side of dish Y (no donors: rows 0, 1, 2, so Y's segment has donors' segments
##   before and after it), all three laid over the same coordinates (equal layout_seed), run 200 steps of 20 s: Y's dump equals Y's
##   lone run (diff == "") and Y has 0 donors (ST_DONORS == 0) [derived: the donor table is keyed by dish].
## - X gains donors: ST_DONORS after > ST_DONORS before [placeholder: conjugation is stochastic; the direction is expected, the size is
##   not derived].
## Needs a GPU. Windowed only.


func _init() -> void:
	if not SimHarness.begin(self, "conjugation_isolation_test", "SimCore"):
		return
	var x := Scenario.small(60, 300.0).seed(41).with_flags({"conjugation": true})
	x.layout_seed = 4
	x.number = 1
	var y := Scenario.small(60, 300.0).seed(42)
	y.layout_seed = 4
	y.number = 2  # (the same number alone and pooled: a dish's ids carry it)
	var z := Scenario.small(60, 300.0).seed(43).with_flags({"conjugation": true})
	z.layout_seed = 4
	z.number = 3
	var lone := SimHarness.make([y.copy()]).step(200).dump(0)
	var pool := SimHarness.make([x.copy(), y.copy(), z.copy()])
	var donors_before: int = pool.dump(0)["stats"].decode_u32(GpuLayout.ST_DONORS * 4)
	pool.step(200)
	var line := SimHarness.diff(lone, pool.dump(1))
	TestUtil.show(line == "", "Y equals its lone run: %s" % (line if line != "" else "same"))
	TestUtil.show(pool.dump(1)["stats"].decode_u32(GpuLayout.ST_DONORS * 4) == 0, "Y has no donors")
	var donors_after: int = pool.dump(0)["stats"].decode_u32(GpuLayout.ST_DONORS * 4)
	TestUtil.show(donors_after > donors_before, "X's donors rose %d -> %d" % [donors_before, donors_after])
	TestUtil.finish(self, "OK conjugation_isolation_test")
