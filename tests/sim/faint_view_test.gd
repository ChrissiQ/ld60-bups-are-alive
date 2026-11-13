extends SceneTree
## The nutrient picture shows every cloud, the ones no list holds too.
##
## Expected:
## - a cloud with no reach (its peak under its cut) is in no list, so the bups' reads skip it, but its nutrient is in the dish: the
##   picture (`pool_view`) takes those clouds from `pool_view_faint`. In a dish with no bups nothing is eaten, so after a step a cloud's
##   place, mass and variance are what the lists copied, and a cell inside the dish must show its own concentration plus, for every live
##   cloud the lists have looked at (its sigma word is set), the cloud's concentration at the cell's centre when the cell is in the
##   block of cells the cloud's reach covers [derived: the sum `pool_view` documents]. The two differ only by single-precision
##   rounding: within 1e-4 of the value.
## - the dish is 10 mm (cells of 100 µm, so a cloud stays one up to a sigma of 50 µm) with no nutrient of its own. 300 clouds of mass
##   0.05 and variance 900 are dropped on one another: each has a peak of 0.05 / (2 pi x 900) = 8.8e-6, under its cut of 1e-5 (0.1 of
##   the detection floor), and a step's spreading only lowers it, so each has no reach, while together they would be 26 detection
##   floors in one place [derived: 300 x 8.8e-6] and, spread over 60 µm and by a step, are about 10 at the nearest cell's centre
##   [measured]. 20 clouds of mass 40 (a peak of 7e-3) have a reach. So the test asks for 300 clouds with no
##   reach, for the lists to hold as many entries as the squares the 20 others' reach covers (an entry each for the 300 would be 300
##   more), and for a cell where the 300 are over half of what is shown: without them in the picture it fails.
## - another dish, of another size and with 300 such clouds of its own, takes the pool's first cells, so the dish shown has cells that
##   do not begin at 0 and clouds that are not its own lie in the pool: a pass that mixed up a dish's cells with the pool's, or took
##   another dish's clouds, shows in the comparison.
## Windowed only.

const DELTA := 20.0
const CELLS := 100
const RADIUS := 5000.0
const OTHER_RADIUS := 3000.0
const FAINT := 300
const STRONG := 20


func _init() -> void:
	if not SimHarness.begin(self, "faint_view_test", "the pooled core (SimCore)"):
		return
	SimConstants.apply()
	var s := Scenario.small(0, RADIUS)
	s.nutrient_density = 0.0
	var other := Scenario.small(0, OTHER_RADIUS)
	other.nutrient_density = 0.0
	var h := SimHarness.make([other, s], {"delta": DELTA})
	var other_row: int = h.scenarios.keys()[0]
	var row: int = h.scenarios.keys()[1]
	var core: SimCore = h.core
	for k in FAINT:
		core._drop_cloud(other_row, -400.0 + fmod(k * 5.1, 60.0), 300.0 + fmod(k * 2.3, 60.0), 0.05, 900.0)
	for k in FAINT:
		core._drop_cloud(row, 130.0 + fmod(k * 7.3, 60.0), 240.0 + fmod(k * 3.1, 60.0), 0.05, 900.0)
	for k in STRONG:
		core._drop_cloud(row, -3000.0 + 300.0 * k, 1500.0 - 150.0 * k, 40.0, 900.0)
	h.step(1)
	var view := ViewRequest.new()
	view.row = row
	view.want_field_view = true
	core.publish(view)
	var n := CELLS
	var sp := 2.0 * RADIUS / n
	var d := h.dump(row)
	var conc: PackedFloat32Array = (d["field"] as PackedByteArray).slice(0, n * n * 4).to_float32_array()
	var clouds: PackedFloat32Array = (d["clouds"] as PackedByteArray).to_float32_array()
	var shown: PackedFloat32Array = core.rd.buffer_get_data(core.arena.buf("VIEW"), int(core._dishes[row].base) * 4, n * n * 4).to_float32_array()
	var listed := PackedFloat64Array()
	listed.resize(n * n)
	var faint := PackedFloat64Array()
	faint.resize(n * n)
	var faint_clouds := 0
	var listed_clouds := 0
	var bin := 0.5 * sp
	var bins := ceili(2.0 * RADIUS / bin) + 1
	var entries_want := 0
	var entries: int = core.in_use()["entries"]
	for k in clouds.size() / 8:
		var x := clouds[k * 8]
		var y := clouds[k * 8 + 1]
		var mass := clouds[k * 8 + 2]
		var v := clouds[k * 8 + 3]
		var reach2 := clouds[k * 8 + 6]
		if clouds[k * 8 + 7] <= 0.0:
			continue
		var reach := sqrt(maxf(reach2, 0.0))
		var into := listed if reach2 > 0.0 else faint
		if reach2 > 0.0:
			listed_clouds += 1
			var bx0 := clampi(int((x - reach + RADIUS) / bin), 0, bins - 1)
			var bx1 := clampi(int((x + reach + RADIUS) / bin), 0, bins - 1)
			var by0 := clampi(int((y - reach + RADIUS) / bin), 0, bins - 1)
			var by1 := clampi(int((y + reach + RADIUS) / bin), 0, bins - 1)
			entries_want += (bx1 - bx0 + 1) * (by1 - by0 + 1)
		else:
			faint_clouds += 1
		for cy in range(maxi(0, floori((y - reach + RADIUS) / sp - 0.5)), mini(n - 1, ceili((y + reach + RADIUS) / sp - 0.5)) + 1):
			for cx in range(maxi(0, floori((x - reach + RADIUS) / sp - 0.5)), mini(n - 1, ceili((x + reach + RADIUS) / sp - 0.5)) + 1):
				var dx := (cx + 0.5) * sp - RADIUS - x
				var dy := (cy + 0.5) * sp - RADIUS - y
				into[cy * n + cx] += mass / (TAU * v) * exp(-(dx * dx + dy * dy) * 0.5 / v)
	var inside := 0
	var worst := 0.0
	var faint_share := 0.0
	var faint_most := 0.0
	for cy in n:
		for cx in n:
			var x := (cx + 0.5) * sp - RADIUS
			var y := (cy + 0.5) * sp - RADIUS
			if x * x + y * y > (RADIUS - sp) * (RADIUS - sp):
				continue
			inside += 1
			var i := cy * n + cx
			var want := conc[i] + listed[i] + faint[i]
			worst = maxf(worst, (absf(shown[i] - want) - 1e-10) / maxf(want, 1e-10))
			if want > Cell.DETECTION_FLOOR:
				faint_share = maxf(faint_share, faint[i] / want)
			faint_most = maxf(faint_most, faint[i])
	TestUtil.show(int(core.overflow()) == 0 and h.count(row) == 0, "no overflow and no bups (%d clouds)" % (clouds.size() / 8))
	TestUtil.show(int(core._dishes[row].base) > 0, "the dish shown is not the pool's first (its cells begin at %d)" % int(core._dishes[row].base))
	TestUtil.show(faint_clouds == FAINT and listed_clouds == STRONG, "%d clouds have no reach and %d have one (%d, %d)" % [FAINT, STRONG, faint_clouds, listed_clouds])
	TestUtil.show(absi(entries - entries_want) <= 4 * STRONG, "the lists hold the clouds with a reach alone: %d entries, %d squares their reach covers (a square more or less a cloud for rounding)" % [entries, entries_want])
	TestUtil.show(faint_share > 0.5, "in some shown cell the clouds with no reach are over half of it (the most: %.3f of the cell, %.1f detection floors)" % [faint_share, faint_most / Cell.DETECTION_FLOOR])
	TestUtil.show(worst < 1e-4, "each of %d cells well inside shows its concentration and every cloud's (worst relative difference %.7f)" % [inside, worst])
	core.release()
	TestUtil.finish(self, "OK faint_view_test")
