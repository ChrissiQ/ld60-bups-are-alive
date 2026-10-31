extends SceneTree
## The pooled world reproduces the known biology (the aggregate assertions of tests/model_test.gd and tests/cloud_test.gd).
##
## Expected values, written before the first run:
## - Doubling time (derived from Biology.DOUBLING_SECONDS = 2400 s): 20 founders in a rich medium (radius 3000 µm, 64 units/mm²,
##   limit 1000, nothing else) grow so that log2(count at 3 h / count at 1 h) = 7200 / doubling; the doubling time from that slope is
##   within 5% of 2400 s (2280-2520 s) [derived value; the 5% is a placeholder for the sample noise: 20 founders over 2 h are
##   about 20 x 2^1.5 to 20 x 2^4.5 bups].
## - Starvation (derived, AGENTS.md "Starvation"): stationary phase on, no nutrient and no feed: after 3 h the living bups' mean mass
##   is below the birth mass 8 (they shrink) or none are left.
## - Checks that need more than the harness can read are stubs naming what each needs:
##   keen-bup drift 2.4-3.6 µm/s in a 0.5%/um gradient with a dull bup below 0.8 x keen (measured about 3.0 in model_test): needs
##   `SimHarness.set_field` and the questions; mutation rate near TRAIT_MUTATIONS + HARMFUL_MUTATIONS per daughter:
##   needs the births events in the dump; cloud variance 2Dt with D = 600 / 25 = 24 µm2/s, within 3%: needs the
##   clouds' dump layout; DEATH_RELEASE 0.25 of a body returned as a cloud; acetate excretion and
##   uptake; conjugation rate.
## Needs a GPU. Windowed only.

const DOUBLING := 2400.0  ## Biology.DOUBLING_SECONDS
const TOLERANCE := 0.05  ## placeholder
const HOUR_STEPS := 180  ## 3600 s at 20 s


func _init() -> void:
	if not SimHarness.begin(self, "biology_test", "SimCore"):
		return
	var rich := Scenario.small(20, 3000.0).seed(51)
	rich.nutrient_density = 64.0
	var h := SimHarness.make([rich])
	h.step(HOUR_STEPS)
	var n1 := h.count(0)
	h.step(2 * HOUR_STEPS)
	var n3 := h.count(0)
	var doubling := 7200.0 / log(float(n3) / float(n1)) * log(2.0)
	TestUtil.show(absf(doubling - DOUBLING) <= TOLERANCE * DOUBLING, "doubling time %.0f s from %d at 1 h to %d at 3 h (expected %.0f +-5%%)" % [doubling, n1, n3, DOUBLING])
	var starve := Scenario.small(50, 600.0).seed(52).with_flags({"stationary": true})
	starve.nutrient_density = 0.0
	var s := SimHarness.make([starve]).step(3 * HOUR_STEPS)
	var recs: PackedByteArray = s.dump(0)["records"]
	var n := recs.size() / GpuLayout.RECORD_BYTES
	var mass := 0.0
	for i in n:
		mass += recs.decode_float(i * GpuLayout.RECORD_BYTES + GpuLayout.R_MASS * 4)
	TestUtil.show(n == 0 or mass / n < 8.0, "starved bups shrink: %d left, mean mass %.2f (birth mass 8)" % [n, mass / maxf(n, 1)])
	for stub in [
		["keen-bup drift in a gradient", "set_field and questions"],
		["mutation rate per daughter", "births events in the dump"],
		["cloud variance 2Dt", "the cloud kernels and the clouds in the dump"],
		["DEATH_RELEASE as a cloud", "the cloud kernels and the clouds in the dump"],
		["acetate excretion and uptake", "the kernels it needs"],
		["conjugation rate", "the kernels it needs"],
	]:
		print("SKIP biology_test: %s, enabled by %s" % stub)
	TestUtil.finish(self, "OK biology_test (six checks skipped, each names what it needs)")
