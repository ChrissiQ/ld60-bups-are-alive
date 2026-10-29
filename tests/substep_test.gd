extends SceneTree
## Run: godot --headless --path . -s tests/substep_test.gd
## The coarse motion cuts a long step into sub-steps, each reading the nutrient where the bup is. On a coarse nutrient
## grid (a big dish) fewer are needed (BupSim.moves_for: see there and Dish.MOTION_STRUCTURE). This checks the counts, and
## that the saving costs the bups nothing they would have found: in a field of plankton clouds (a bloom, run for three
## hours, then held still) crowds are let go with the long sub-steps and with the short ones, from the same places, and the
## nutrient they end up in is compared.

const BUPS := 40000
const SEEDS := [201, 202, 203, 204, 205, 206, 207, 208]
const MINUTES := 20.0
const KS := 0.002  # Cell.HALF_SATURATION
const ALLOWED_LOSS := 1.5  ## percent of the exposure: the sub-steps of the rule against the 3 s ones. Measured at 40 mm: -0.96 +- 0.31; 90 mm: -0.87 +- 0.25 (the same length at 20 mm costs 5%, which this would catch)


func _init() -> void:
	SimConstants.apply()
	_check_counts()
	_check_solver()
	for radius_mm in [40.0, 90.0]:
		_check_exposure(radius_mm)
	BupSim.configure(SimConstants.build())
	TestUtil.finish(self, "SUB-STEP TESTS OK")


func _check_counts() -> void:
	var expected := {0.3: 7, 10.0: 7, 20.0: 7, 25.0: 7, 30.0: 5, 40.0: 3, 60.0: 2, 90.0: 1}  # (radius in mm: sub-steps in a 20 s step)
	for radius_mm: float in expected:
		var d := Dish.new()
		root.add_child(d)
		var start := StartConditions.new()
		start.dish_radius = maxf(radius_mm * 1000.0, StartConditions.MIN_DISH_RADIUS) if radius_mm >= 1.0 else 300.0
		d.strike(start)
		TestUtil.check(d.sim.moves_for(20.0) == expected[radius_mm], "a 20 s step of the coarse motion is cut into %d sub-steps on a %s mm dish (%d)" % [expected[radius_mm], radius_mm, d.sim.moves_for(20.0)])
		d.free()
	var fine := Dish.new()
	root.add_child(fine)
	fine.strike(TestUtil.small_start())
	TestUtil.check(fine.sim.moves_for(3.0) == 1 and fine.sim.moves_for(0.5) == 1, "a short step is one sub-step")
	fine.free()


## The nutrient's diffusion is solved in pieces of at least 5 s, cut finer only where the cells are small enough for a long
## piece to matter (BupSim.diffuse_pieces). Counts, and what the pieces cost in accuracy where they are not cut.
func _check_solver() -> void:
	var expected := {0.3: 4, 5.0: 4, 10.0: 3, 20.0: 1, 30.0: 1, 90.0: 1}  # (radius in mm: solves in 20 s of diffusion)
	for radius_mm: float in expected:
		var d := Dish.new()
		root.add_child(d)
		var start := StartConditions.new()
		start.dish_radius = 300.0 if radius_mm < 1.0 else radius_mm * 1000.0
		d.strike(start)
		TestUtil.check(d.sim.diffuse_pieces(20.0) == expected[radius_mm], "20 s of diffusion is solved in %d pieces on a %s mm dish (%d)" % [expected[radius_mm], radius_mm, d.sim.diffuse_pieces(20.0)])
		TestUtil.check(d.sim.diffuse_pieces(5.0) == 1, "a 5 s stretch is one solve")
		d.free()
	for radius_mm in [30.0, 90.0]:  # (where the pieces are not cut: one 20 s solve against 5 s ones, a plankton cloud after ten minutes)
		var fields := []
		for piece in [20.0, 5.0]:
			var d := Dish.new()
			root.add_child(d)
			var start := StartConditions.new()
			start.dish_radius = radius_mm * 1000.0
			start.nutrient_density = 0.0
			d.strike(start)
			d.clear_bups()
			d.field.deposit_disc(Vector2.ZERO, Dish.PLANKTON_PATCH_RADIUS, Dish.PLANKTON_UNITS * Dish.NUTRIENT_ENERGY)
			for i in int(600.0 / piece):
				d.field.diffuse(piece)
			fields.append(Array(d.field.values()))
			d.free()
		var peak := 0.0
		var worst := 0.0
		for i in fields[0].size():
			peak = maxf(peak, fields[1][i])
			worst = maxf(worst, absf(fields[0][i] - fields[1][i]))
		TestUtil.check(worst < 0.0005 * peak, "on a %.0f mm dish one 20 s solve leaves the field within 0.05%% of 5 s ones (%.4f%% of the peak)" % [radius_mm, 100.0 * worst / peak])


## Every constant but what is overridden, with the nutrient held still and nothing eating.
func _build_field(radius_mm: float) -> Array:  # (the grid's values and the clouds' export)
	BupSim.configure(SimConstants.build())
	var d := Dish.new()
	root.add_child(d)
	d.set_seed(7)
	var start := StartConditions.new()
	start.dish_radius = radius_mm * 1000.0
	start.nutrient_density = 0.0
	start.bloom_density = 0.25
	start.bups = 1
	start.bup_limit = 100
	d.strike(start)
	d.clear_bups()
	d.advance(3.0 * 3600.0)
	var state := [Array(d.field.values()), d.field.puffs_export()]  # (the grid, and the clouds not yet given to it)
	d.free()
	return state


## The mean uptake factor (c / (Ks + c)) of the nutrient the crowd ends up in.
func _exposure(radius_mm: float, state: Array, structure: float, seed_value: int) -> float:
	TestUtil.frozen_constants(structure)
	var d := Dish.new()
	root.add_child(d)
	d.set_seed(seed_value)
	var start := StartConditions.new()
	start.dish_radius = radius_mm * 1000.0
	start.nutrient_density = 0.0
	start.bups = 1
	start.bup_limit = 2 * BUPS
	d.strike(start)
	d.clear_bups()
	d.field.load_values(state[0])
	d.field.puffs_import(state[1])
	var ids := []
	for i in BUPS:
		ids.append(d.sim.add_bup(d.sim.random_point(radius_mm * 1000.0 * 0.9), Genome.founder(), 1000.0, 3.0, 5000.0, 0, Vector2.from_angle(d.sim.random_float() * TAU)))
	for i in int(MINUTES * 60.0 / 20.0):
		d.step(20.0)
	var total := 0.0
	var n := 0
	for id: int in ids:
		var info: Dictionary = d.bup_info(id)
		if not info.is_empty():
			var c: float = d.field.sample(info["pos"])
			total += c / (KS + c)  # (what a bup can use of it: uptake saturates, so a rich core does not dominate the average)
			n += 1
	d.free()
	return total / n


func _check_exposure(radius_mm: float) -> void:
	var state := _build_field(radius_mm)
	var diffs := []
	for seed_value in SEEDS:
		var long := _exposure(radius_mm, state, Dish.MOTION_STRUCTURE, seed_value)  # (the rule)
		var short := _exposure(radius_mm, state, 1.0e9, seed_value)  # (3 s sub-steps, whatever the grid)
		diffs.append((long / short - 1.0) * 100.0)
	var mean := 0.0
	for dv: float in diffs:
		mean += dv / diffs.size()
	var variance := 0.0
	for dv: float in diffs:
		variance += (dv - mean) * (dv - mean) / (diffs.size() - 1)
	TestUtil.check(absf(mean) < ALLOWED_LOSS, "on a %.0f mm dish the longer sub-steps leave the bups in the same nutrient as the 3 s ones (%+.2f%% +- %.2f%%, allowed %.1f%%)" % [radius_mm, mean, sqrt(variance / diffs.size()), ALLOWED_LOSS])
