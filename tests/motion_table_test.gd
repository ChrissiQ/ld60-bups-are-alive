extends SceneTree
## Run: godot --headless --path . -s tests/motion_table_test.gd   (add `-- verbose` to see every case's numbers)
## The motion of fast playback (long steps, the coarse model) is read from a table measured from the real run-and-tumble
## swimming (scripts/motion_table.gd, made by tools/gen_motion_table.gd). This keeps the two from drifting apart:
##   1. every constant handed to the native code is classed as a motion input or not, so a new one gets a decision;
##   2. the table carries hashes of what it was measured from (the constants, and the text of the native functions that
##      make the swimming) and they must match what is there now;
##   3. the coarse model is run against the real one on cases that cover the table: the drift in six slopes, the diffusion
##      in a flat medium, and the crowd near the wall. This one catches what a hash cannot (a change in how the model
##      works that none of the listed functions show), and it checks the calibration factor of the generator.
## A failure of 2 or 3 is fixed by running tools/gen_motion_table.gd (about 5 minutes) and committing the new table.

const REGENERATE := "stale: run  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s tools/gen_motion_table.gd"
const TOLERANCE := 0.2  ## µm/s: how far the coarse drift may be from the real one, beyond 3 standard errors
const MEAN_TOLERANCE := 0.1  ## µm/s: how far the average of the signed differences may be from zero (the calibration)
const DRIFT_CASES := [  # [speed µm/s, sense, concentration at the origin, gradient %/µm]
	[20.0, 150.0, 0.3, 2.0],  # keen sense, plenty of nutrient, steep: the plateau of the drift
	[20.0, 10.0, 0.0003, 5.0],  # dull sense, almost nothing to read: the plateau at high noise
	[20.0, 150.0, 0.3, 0.1],  # a shallow slope: where the drift sets in
	[20.0, 50.0, 0.03, 0.5],  # the knee
	[20.0, 10.0, 0.003, 2.0],  # in between
	[35.0, 50.0, 0.003, 1.0],  # a faster swimmer
	[20.0, 150.0, 0.3, 0.02],  # a very gentle slope, where E. coli still climbs (the linear range of the response)
]


func _init() -> void:
	SimConstants.apply()
	_check_constants_are_classed()
	_check_table_is_current()
	_check_table_shape()
	_check_drift()
	_check_flat_diffusion()
	_check_wall()
	BupSim.configure(SimConstants.build())
	TestUtil.finish(self, "MOTION TABLE TESTS OK")


# ---- 1 and 2: what the table was measured from ----------------------------------------------------------

func _check_constants_are_classed() -> void:
	var built := SimConstants.build()
	var unclassed := []
	for key: String in built:
		var motion: bool = key in SimConstants.MOTION_INPUTS
		var other: bool = key in SimConstants.OTHER_CONSTANTS
		if motion == other:
			unclassed.append(key)
	TestUtil.check(unclassed.is_empty(), "every constant handed to the native code is in exactly one of SimConstants.MOTION_INPUTS and OTHER_CONSTANTS (decide whether the real swimming reads it): %s" % [unclassed])
	var unknown := []
	for key: String in SimConstants.MOTION_INPUTS + SimConstants.OTHER_CONSTANTS:
		if not built.has(key):
			unknown.append(key)
	TestUtil.check(unknown.is_empty(), "the lists in SimConstants name only constants that exist: %s" % [unknown])


func _check_table_is_current() -> void:
	TestUtil.check(MotionFingerprint.constants_current(), "the motion table was measured from the constants of the swimming as they are now (%s)" % REGENERATE)
	TestUtil.check(MotionFingerprint.code_hash() != "", "the native sources of the swimming can be read (MotionFingerprint.FINE_MOTION names functions that exist)")
	TestUtil.check(MotionFingerprint.code_current(), "the motion table was measured from the native swimming code as it is now (%s)" % REGENERATE)


func _check_table_shape() -> void:
	var ns: int = MotionTable.S_AXIS.size()
	var ne: int = MotionTable.E_AXIS.size()
	TestUtil.check(ns >= 8 and ne >= 8 and MotionTable.DRIFT.size() == ns * ne and MotionTable.D_ALONG.size() == ns * ne and MotionTable.D_ACROSS.size() == ns * ne and MotionTable.D_FLAT.size() == ne, "the table's arrays agree in size (%d x %d)" % [ns, ne])
	if MotionTable.DRIFT.size() != ns * ne:
		return
	for axis: Array in [MotionTable.S_AXIS, MotionTable.E_AXIS]:
		var step: float = log(axis[1] / axis[0])
		var even := true
		for i in range(1, axis.size()):
			even = even and absf(log(axis[i] / axis[i - 1]) - step) < 0.01 * step
		TestUtil.check(even and step > 0.0, "an axis of the table is even in its logarithm (the native lookup counts on it)")
	var rising := true
	var bounded := true
	for i in ns:
		for j in ne:
			var k := i * ne + j
			rising = rising and (i == 0 or MotionTable.DRIFT[k] >= MotionTable.DRIFT[k - ne] - 1e-9)
			bounded = bounded and MotionTable.DRIFT[k] >= 0.0 and MotionTable.DRIFT[k] < 0.3 and MotionTable.D_ALONG[k] > 0.0 and MotionTable.D_ACROSS[k] > 0.0
	TestUtil.check(rising, "a steeper slope never gives less drift")
	TestUtil.check(bounded, "the table's drift is a share of speed under 0.3 and its diffusions are positive")


# ---- 3: the coarse model against the real one -------------------------------------------------------------

## The nutrient frozen and no eating, so that nothing but the motion changes between the runs.
## A dish with the given field and `bups` identical swimmers placed within `reach` of the origin; returns [dish, ids, start positions].
func _crowd(radius: float, seed_: int, bups: int, speed: float, sense: float, reach: float, field: Callable) -> Array:
	var d := Dish.new()
	root.add_child(d)
	d.set_seed(seed_)
	var start := StartConditions.new()
	start.dish_radius = radius
	start.bup_limit = 2 * bups + 100
	start.nutrient_density = 0.0
	d.strike(start)
	d.clear_bups()
	d.feed_density = 0.0
	var values := []
	for i in d.field.size * d.field.size:
		values.append(field.call(d.field.cell_centre(i)))
	d.field.load_values(values)
	var ids := []
	var starts := []
	for i in bups:
		var genome := Genome.founder()
		genome["sense"] = sense
		genome["speed"] = speed
		var p: Vector2 = d.sim.random_point(reach)
		ids.append(d.sim.add_bup(p, genome, 1000.0, 3.0, 5000.0, 0, Vector2.from_angle(d.sim.random_float() * TAU)))  # (a full reserve and a huge birth mass: it neither eats nor divides)
		starts.append(p)
	return [d, ids, starts]


func _advance(d: Dish, seconds: float, step: float) -> void:
	for i in int(round(seconds / step)):
		d.step(step)


## The mean drift along x of a crowd in an exponential ramp, µm/s, and its standard error, over `seconds` after a warm-up.
func _drift(step: float, speed: float, sense: float, c0: float, gradient_percent: float) -> Vector2:
	var length := 100.0 / gradient_percent
	var moved := []
	for seed_ in 2:
		var crowd := _crowd(1200.0, 900 + seed_, 1500, speed, sense, 60.0, func(p: Vector2) -> float: return c0 * exp(clampf(p.x, -800.0, 800.0) / length))
		var d: Dish = crowd[0]
		# a warm-up, so that the real model's memory and headings are in their steady state when the clock starts
		_advance(d, 20.0 if step <= 0.25 else 6.0, minf(step, 1.5 if step > 0.25 else step))
		for i in crowd[1].size():
			var info: Dictionary = d.bup_info(crowd[1][i])
			if not info.is_empty():
				crowd[2][i] = info["pos"]
		_advance(d, 60.0, step)
		for i in crowd[1].size():
			var info: Dictionary = d.bup_info(crowd[1][i])
			if not info.is_empty():
				moved.append(info["pos"].x - crowd[2][i].x)
		d.free()
	var mean := 0.0
	for m: float in moved:
		mean += m / moved.size()
	var variance := 0.0
	for m: float in moved:
		variance += (m - mean) * (m - mean) / (moved.size() - 1)
	return Vector2(mean / 60.0, sqrt(variance / moved.size()) / 60.0)


func _check_drift() -> void:
	TestUtil.frozen_constants()
	var signed_sum := 0.0
	var worst := 0.0
	for case: Array in DRIFT_CASES:
		var fine := _drift(0.05, case[0], case[1], case[2], case[3])
		for step: float in [1.5, 20.0]:
			var coarse := _drift(step, case[0], case[1], case[2], case[3])
			var gap := coarse.x - fine.x
			var allowed := maxf(TOLERANCE, 3.0 * sqrt(fine.y * fine.y + coarse.y * coarse.y))
			signed_sum += gap
			if OS.get_cmdline_user_args().has("verbose"):
				print("drift speed %.0f sense %.0f c %s %s%%/µm, %.1f s steps: coarse %.2f, real %.2f (s.e. %.2f, %.2f)" % [case[0], case[1], case[2], case[3], step, coarse.x, fine.x, coarse.y, fine.y])
			worst = maxf(worst, absf(gap))
			TestUtil.check(absf(gap) <= allowed, "coarse drift (%.1f s steps) follows the real swimming: speed %.0f, sense %.0f, c %s, %s%%/µm: %.2f vs %.2f µm/s (allowed %.2f)" % [step, case[0], case[1], case[2], case[3], coarse.x, fine.x, allowed])
	var mean_gap := signed_sum / (DRIFT_CASES.size() * 2)
	TestUtil.check(absf(mean_gap) <= MEAN_TOLERANCE, "on average the coarse drift is neither high nor low (mean %.3f µm/s off, worst %.2f): if not, adjust CALIBRATION in tools/gen_motion_table.gd" % [mean_gap, worst])


## The mean squared distance from the start after `seconds`, of a crowd in a uniform field of this concentration, at two times.
func _spread(step: float, c: float, speed: float, sense: float) -> Array:
	var crowd := _crowd(2500.0, 31, 16000, speed, sense, 20.0, func(_p: Vector2) -> float: return c)
	var d: Dish = crowd[0]
	var out := []
	for phase in 2:
		_advance(d, 60.0, step)
		var sum := 0.0
		var n := 0
		for i in crowd[1].size():
			var info: Dictionary = d.bup_info(crowd[1][i])
			if not info.is_empty():
				sum += (info["pos"] - crowd[2][i]).length_squared()
				n += 1
		out.append(sum / n)
	d.free()
	return out


func _check_flat_diffusion() -> void:
	TestUtil.frozen_constants()
	for case: Array in [[50.0, 0.0], [10.0, 0.0003], [150.0, 0.03]]:  # [sense, concentration]
		var fine := _spread(0.05, case[1], 20.0, case[0])
		var coarse := _spread(1.5, case[1], 20.0, case[0])
		# (16,000 swimmers each: the measure is good to about 2%)
		var d_fine: float = (fine[1] - fine[0]) / (4.0 * 60.0)  # (the growth between 60 s and 120 s: free of the offset of the first runs)
		var d_coarse: float = (coarse[1] - coarse[0]) / (4.0 * 60.0)
		TestUtil.check(absf(d_coarse / d_fine - 1.0) < 0.08, "coarse diffusion in a flat medium follows the real swimming (sense %.0f, c %s: %.0f vs %.0f µm²/s)" % [case[0], case[1], d_coarse, d_fine])


## The share of a crowd within 20 µm of the rim of a 300 µm dish after 10 minutes. Uniform would be 0.129.
func _rim_share(step: float) -> float:
	var near := 0
	var total := 0
	for seed_ in 3:
		var crowd := _crowd(300.0, 10 + seed_, 600, 20.0, 50.0, 250.0, func(_p: Vector2) -> float: return 0.03)
		var d: Dish = crowd[0]
		_advance(d, 600.0, step)
		for id: int in crowd[1]:
			var info: Dictionary = d.bup_info(id)
			if not info.is_empty():
				total += 1
				near += 1 if info["pos"].length() > 280.0 else 0
		d.free()
	return float(near) / total


func _check_wall() -> void:
	TestUtil.frozen_constants()
	var fine := _rim_share(0.05)
	var coarse := _rim_share(20.0)
	# A swimmer in the real model slides along the wall until a tumble frees it, so a crowd collects there a little (0.17
	# against 0.129 for an even crowd): real bacteria do too. The coarse model reflects off the wall and stays even, about
	# 0.04 short (projecting onto the wall instead made it 0.22, and worse with longer sub-steps). Within 0.06 keeps it from
	# going back to either.
	TestUtil.check(absf(coarse - fine) < 0.06 and coarse < 0.2, "a crowd does not pile up against the wall in long steps, nor leave it empty (share within 20 µm of the rim: %.3f vs %.3f in the real swimming; even would be 0.129)" % [coarse, fine])
