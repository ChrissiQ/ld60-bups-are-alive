extends SceneTree
## The pool's conservation checks.
##
## Expected values, written before the first run:
## - after 300 steps of 20 s of a mixed pool (goal dish, a dish with every flag, a dish with a key, a dish that starves), invariants()
##   is empty: DS_COUNT = records, ids unique, every bup inside the rim, count within the limit [derived].
## - an empty dish (no bups, no feed, no bloom, nothing emitted) keeps its field total: |total_after - total_before| <= 1e-5 x
##   total_before (diffusion with no-flux walls conserves the total; the tolerance is float32 round-off over 300 steps) [derived tolerance
##   1e-5; placeholder until measured].
## - the energy balance of a dish with bups, with the core's energy ledger on (`SimCore.keep_ledger`): over 300 steps of 20 s, in three
##   dishes (50 founders each, no feed, no world events: a plain one with nutrient 32, one with every flag, one with nutrient 0.5),
##   E_after = E_before - upkeep - uptake losses - what life loses + the energy made (the acetate let go; a reserve's gain past the food it
##   took, a yield above 1, which a metabolism gene below 1 gives), where E is the glucose (the grid's cells x
##   the cell area, the deposits waiting, the live clouds' masses, the energy the live husks still hold), the acetate (cells x area) and
##   the bups' reserves and bodies (energy + COST_PER_MASS x mass), and the four sums are the ledger's (LG_*) [derived: every other
##   change of E in a step moves energy between these stocks: growth turns reserve into body at COST_PER_MASS, a death gives P_DEATH_GIVE
##   x its mass to a cloud, a husk or the grid, a husk lets go its shares (summing to 1), a cloud hands its mass to the grid, diffusion
##   and the bups' uptake move nutrient between cells and bups]. Tolerance: 1e-5 of E_before plus every amount the ledger counts [the empty
##   dish's float32 bound, placeholder], plus 2^-21 a fixed-point add, at most 8 a bup a step [derived: the ledger's four terms and the
##   deposits round to 2^-20]. Each dish's upkeep and uptake terms are above 0, and life's in at least one dish (the pool has deaths).
## Needs a GPU (windowed).

const STEPS := 300
const EMPTY_TOLERANCE := 1e-5  ## placeholder


func _init() -> void:
	if not SimHarness.begin(self, "invariants_test", "the pooled core (SimCore)"):
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
	_energy_balance()
	TestUtil.finish(self, "OK invariants_test")


func _energy_balance() -> void:
	var dishes: Array = [Scenario.small(50, 600.0).seed(11), Scenario.small(50, 600.0).seed(12).with_all_flags(), Scenario.small(50, 600.0).seed(13)]
	dishes[2].nutrient_density = 0.5
	var h := SimHarness.make(dishes)
	h.core.keep_ledger(true)
	var cost := float(SimConstants.build()["cost_per_mass"])
	var before := {}
	var bup_steps := {}
	for row: int in h.scenarios:
		before[row] = _energy(h, row, cost)
		bup_steps[row] = 0
	for k in STEPS / SimHarness.CHUNK:
		var counts := {}
		for row: int in h.scenarios:
			counts[row] = h.count(row)
		h.step(SimHarness.CHUNK)
		for row: int in h.scenarios:
			bup_steps[row] += SimHarness.CHUNK * maxi(counts[row], h.count(row))
	var deaths := 0.0
	for row: int in h.scenarios:
		var e0: Dictionary = before[row]
		var e1 := _energy(h, row, cost)
		var lg := SimCore.ledger_of(h.dump(row)["dstate"])
		var upkeep := lg[GpuLayout.LG_UPKEEP]
		var uptake := lg[GpuLayout.LG_UPTAKE]
		var made := lg[GpuLayout.LG_MADE]
		var life := lg[GpuLayout.LG_LIFE]
		var expect: float = e0["total"] - upkeep - uptake - life + made
		var residual: float = e1["total"] - expect
		var tol: float = 1e-5 * (e0["total"] + upkeep + uptake + life + made) + 8.0 * bup_steps[row] * pow(2.0, -21.0)
		print("energy row %d: before %s; after %s; ledger upkeep %.4f, uptake %.4f, made %.4f, life %.4f; residual %.6f, tolerance %.6f" % [row, _show(e0), _show(e1), upkeep, uptake, made, life, residual, tol])
		TestUtil.show(absf(residual) <= tol, "row %d: the energy after (%.4f) is the energy before less the ledger's losses, plus what it made (%.4f), within %.6f (residual %.6f)" % [row, e1["total"], expect, tol, residual])
		TestUtil.show(upkeep > 0.0 and uptake > 0.0, "row %d: the ledger saw upkeep and uptake" % row)
		deaths += life
	TestUtil.show(deaths > 0.0, "the ledger saw deaths in the pool (life %.4f)" % deaths)


## The stocks of energy of a dish now, from its dump: glucose (cells, deposits waiting, clouds, husks), acetate, bups.
func _energy(h: SimHarness, row: int, cost: float) -> Dictionary:
	var d := h.dump(row)
	var s: Scenario = h.scenarios[row]
	var n := DishGrid.cells_across(s.radius, s.resolution)
	var area := pow(2.0 * s.radius / n, 2.0)
	var f: PackedByteArray = d["field"]
	var n2 := n * n
	var glucose := 0.0
	var acetate := 0.0
	var waiting := 0.0
	for c in n2:
		glucose += f.decode_float(c * 4)
		acetate += f.decode_float((n2 + c) * 4)
		waiting += f.decode_u32((3 * n2 + c) * 4) * 4096.0 + f.decode_u32((2 * n2 + c) * 4) / 1048576.0
	var clouds := 0.0
	var cf: PackedFloat32Array = (d["clouds"] as PackedByteArray).to_float32_array()
	for k in cf.size() / 8:
		clouds += cf[k * 8 + 2]
	var husks := 0.0
	var hf: PackedFloat32Array = (d["husks"] as PackedByteArray).to_float32_array()
	for k in hf.size() / 8:
		var left := 0.0
		for j in range(int(hf[k * 8 + 4]), GpuKernelsHusks.HUSK_PIECES):
			left += exp(-0.25 * j) - exp(-0.25 * (j + 1)) + (exp(-0.25 * GpuKernelsHusks.HUSK_PIECES) if j == GpuKernelsHusks.HUSK_PIECES - 1 else 0.0)
		husks += hf[k * 8 + 2] * left
	var bups := 0.0
	var recs: PackedByteArray = d["records"]
	for i in recs.size() / GpuLayout.RECORD_BYTES:
		bups += recs.decode_float(i * GpuLayout.RECORD_BYTES + GpuLayout.R_ENERGY * 4) + cost * recs.decode_float(i * GpuLayout.RECORD_BYTES + GpuLayout.R_MASS * 4)
	var out := {"glucose": glucose * area + waiting + clouds + husks, "acetate": acetate * area, "bups": bups}
	out["total"] = out["glucose"] + out["acetate"] + out["bups"]
	return out


static func _show(e: Dictionary) -> String:
	return "glucose %.4f, acetate %.4f, bups %.4f" % [e["glucose"], e["acetate"], e["bups"]]


func _field_total(d: Dictionary) -> float:
	var f: PackedByteArray = d["field"]
	var t := 0.0
	for i in f.size() / 4:
		t += f.decode_float(i * 4)
	return t
