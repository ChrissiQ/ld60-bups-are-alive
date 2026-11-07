extends SceneTree
## The population holds at the bup limit (port of tools/gpu/cap_check.gd onto the pooled world).
##
## Expected values, written before the first run:
## - a dish with limit 600 and a rich medium (radius 1200 µm, 1000 units/mm2, bloom 0) grows to within 2% of the limit. Food, not the
##   doubling time, decides it [derived]: 600 bups of mean mass about 11.5 (8 to 16) at COST_PER_MASS 4 are about 27,600 energy; a unit is
##   16 energy, so the dish (4.52 mm2 x 1000 = 4,520 units) holds 72,000 and the founders' reserves 2,000. (The first version, radius 800
##   and 200 units/mm2, held 6,400 and stopped near 160 bups, measured with reserves of 50 and of 100.) Doubling takes 40 min, 20 to 600
##   is 5 doublings = 3.3 h.
## - after that, stepped as the game steps at x10,000 and 60 frames a second (166.7 s a frame: 8 steps of 20 s), the count read after each
##   frame is over the limit in at most 1% of the frames [derived: cap_check's `max_share_over` default 0.01; AGENTS.md "Limits"].
##   The trim expects the step's growth plus CAP_SIGMAS standard deviations, so the count stops a little short of the limit.
## Needs a GPU. Windowed only.

const LIMIT := 600
const HOURS := 8.0
const STEPS_PER_FRAME := 8
const MAX_SHARE_OVER := 0.01
const NEAR := 0.98


func _init() -> void:
	if not SimHarness.begin(self, "cap_test", "SimCore"):
		return
	var s := Scenario.small(20, 1200.0).seed(71)
	s.limit = LIMIT
	s.nutrient_density = 1000.0
	var h := SimHarness.make([s])
	var frames := int(HOURS * 3600.0 / (STEPS_PER_FRAME * SimHarness.DEFAULT_DELTA))
	var measured := 0
	var over := 0
	var worst := -999999
	var reached := false
	for f in frames:
		h.step(STEPS_PER_FRAME)
		var n := h.count(0)
		if not reached and n >= NEAR * LIMIT:
			reached = true
		if reached:
			measured += 1
			over += int(n > LIMIT)
			worst = maxi(worst, n - LIMIT)
	TestUtil.show(reached, "the colony came within 2%% of the limit %d" % LIMIT)
	var share := float(over) / maxf(measured, 1)
	TestUtil.show(measured > 0 and share <= MAX_SHARE_OVER, "%d frames measured, %d over the limit (%.4f, at most %.2f), most over %d" % [measured, over, share, MAX_SHARE_OVER, worst])
	TestUtil.finish(self, "OK cap_test")
