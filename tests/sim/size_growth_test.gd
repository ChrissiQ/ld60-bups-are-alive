extends SceneTree
## A bup's growth rate does not depend on its size when food is plentiful.
##
## Expected values:
## - Intake and growth are both proportional to mass (Cell.UPTAKE_PER_MASS; Cell.GROWTH_RATE x mass): at saturation a bup of metabolism m takes in
##   1.5 x COST_PER_MASS x GROWTH_RATE x m x mass x yield, with yield 1 / sqrt(m), and needs COST_PER_MASS x GROWTH_RATE x m x mass to grow at its full
##   rate, so their ratio is 1.5 x c/(c+K) / sqrt(m) whatever the mass [derived, docs/simulation.md "Food intake"]. At m = 2 and c/(c+K) near 0.9
##   that is about 0.95: every size is held a little under its full rate by the same factor, so the doubling time is the same for every size,
##   apart from the costs with a fixed part per bup (Cell.BASE_UPKEEP, SENSE_UPKEEP, MAINTENANCE_FLOOR), which weigh more on a small body.
##   With intake proportional to the square root of mass the biggest bups are slow: founders of size 2.5, 4 and 6.5 at metabolism 2 doubled in
##   1198, 1250 and 1855 s, the slowest 1.55 times the fastest [measured: this test with that intake, Apple Silicon, Metal]. With intake
##   proportional to mass they double in 1379, 1253 and 1235 s, 1.12 times [measured: the same]; the smallest is slowest, and how much of that
##   the fixed costs account for is not worked out. So the doubling times agree within 30% (a bound between the two spreads, 1.12 and 1.55,
##   not a derived figure; other GPUs give other numbers), and none is faster than the full rate allows (2400 s / 2 = 1200 s).
## - Each doubling time is read from the counts at 20 min and 80 min: 3600 s x ln 2 / ln(n80 / n20), 40 founders a dish, nutrient 1000 units/mm2
##   (the density cap), a dish of 3000 µm.
## Needs a GPU (windowed).

const SIZES := [2.5, 4.0, 6.5]
const METABOLISM := 2.0
const FOUNDERS := 40
const AGREEMENT := 1.3 ## the slowest doubling time over the fastest, at most
const FIRST_STEPS := 60  ## 20 min at 20 s
const LAST_STEPS := 240  ## 80 min


func _init() -> void:
	if not SimHarness.begin(self, "size_growth_test", "the pooled core (SimCore)"):
		return
	var rows: Array = []
	for i in SIZES.size():
		var s := Scenario.small(FOUNDERS, 3000.0).seed(61 + i)
		s.limit = 5000
		s.nutrient_density = 1000.0
		s.founder_genes = {"size": SIZES[i], "metabolism": METABOLISM}
		rows.append(s)
	var h := SimHarness.make(rows)
	h.step(FIRST_STEPS)
	var n1: Array = []
	for i in SIZES.size():
		n1.append(h.count(i))
	h.step(LAST_STEPS - FIRST_STEPS)
	var doubling: Array = []
	for i in SIZES.size():
		var n2 := h.count(i)
		doubling.append(3600.0 * log(2.0) / log(float(n2) / float(n1[i])))
		print("size %.1f: %d bups at 20 min, %d at 80 min, doubling %.0f s" % [SIZES[i], n1[i], n2, doubling[i]])
	TestUtil.show(float(doubling.max()) / float(doubling.min()) <= AGREEMENT, "the doubling times of sizes %s agree within %.0f%% (%.3f)" % [SIZES, (AGREEMENT - 1.0) * 100.0, float(doubling.max()) / float(doubling.min())])
	TestUtil.show(float(doubling.min()) >= 0.95 * Biology.DOUBLING_SECONDS / METABOLISM, "none doubles faster than the full rate, %.0f s (the fastest, %.0f s)" % [Biology.DOUBLING_SECONDS / METABOLISM, float(doubling.min())])
	TestUtil.finish(self, "OK size_growth_test")
