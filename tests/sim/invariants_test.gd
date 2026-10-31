extends SceneTree
## The pool's conservation checks.
##
## Expected values, written before the first run:
## - after 300 steps of 20 s of a mixed pool (goal dish, a dish with every flag, a dish with a key, a dish that starves), invariants()
##   is empty: DS_COUNT = records, ids unique, every bup inside the rim, count within the limit [derived].
## - an empty dish (no bups, no feed, no bloom, nothing emitted) keeps its field total: |total_after - total_before| <= 1e-5 x
##   total_before (diffusion with no-flux walls conserves the total; the tolerance is float32 round-off over 300 steps) [derived tolerance
##   1e-5; placeholder until measured].
## - the nutrient-energy balance of a dish with bups (field + reserves + bodies = start + fed - dissipated) is a stub: it needs the
##   energy ledger (`SimCore.energy_ledger`), not yet there. Enabled by a later change.
## Needs a GPU. Windowed only.

const STEPS := 300
const EMPTY_TOLERANCE := 1e-5  ## placeholder


func _init() -> void:
	if not SimHarness.begin(self, "invariants_test", "SimCore"):
		return
	var dishes: Array = [
		Scenario.small(50, 600.0).seed(1),
		Scenario.small(50, 600.0).seed(2).with_all_flags(),
		Scenario.small(50, 600.0).seed(3).with_flags({"key": true, "conjugation": true}),
		Scenario.small(50, 600.0).seed(4).with_flags({"stationary": true}),
	]
	dishes[3].nutrient_density = 0.5
	var h := SimHarness.make(dishes).step(STEPS)
	var bad := h.invariants()
	TestUtil.show(bad.is_empty(), "invariants hold after %d steps: %s" % [STEPS, "; ".join(bad)])
	var empty := Scenario.small(0, 600.0)
	empty.nutrient_density = 16.0
	var e := SimHarness.make([empty])
	var before := _field_total(e.dump(0))
	e.step(STEPS)
	var after := _field_total(e.dump(0))
	TestUtil.show(absf(after - before) <= EMPTY_TOLERANCE * before, "an empty dish keeps its nutrient: %.6f -> %.6f" % [before, after])
	print("SKIP invariants_test: nutrient-energy balance of a dish with bups, enabled by a later change (energy ledger)")
	TestUtil.finish(self, "OK invariants_test (energy balance skipped)")


func _field_total(d: Dictionary) -> float:
	var f: PackedByteArray = d["field"]
	var t := 0.0
	for i in f.size() / 4:
		t += f.decode_float(i * 4)
	return t
