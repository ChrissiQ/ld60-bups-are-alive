extends SceneTree
## Measures the motion table (scripts/motion_table.gd) from the real run-and-tumble swimming, and writes it.
##
##   tools/run_windowed.sh <outfile> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gen_motion_table.gd [-- out=<path> calibration=<x>]
##
## Windowed (it runs on the GPU). Run it whenever tests/motion_table_test.gd says the table is stale, which it does when a
## constant of the real swimming (SimConstants.MOTION_INPUTS) or the kernel that makes it (MotionFingerprint: the text of
## GpuKernelsField.K_SWIM) changes. `out=` writes somewhere else than OUT (to compare with the committed table); the run
## prints how many cells of the new drift lie within 2 standard errors of the table it was started from.
## Nothing else needs doing: the table is read by the simulation from SimConstants.build().
##
## What is measured. Fast playback moves a bup in long steps that span many runs and tumbles, so it needs what the real
## swimming averages to: a drift up the nutrient gradient and a random walk. Both depend only on two numbers: s, the speed
## times the log-gradient the swimmer faces (how steep the slope is for it), and eps, the error in its estimate of the slope
## (sense_error). For a grid of both, a crowd of identical swimmers is run in an exponential nutrient ramp (a constant
## log-gradient) that is held still, with no eating, far from any wall and far above the detection floor, after a warm-up
## long enough for the crowd's memory and headings to settle. The drift is how far the crowd's mean moves in 10 s, the
## diffusion how fast its variance grows along and across the ramp. eps is set by the noise reference, which each trial
## (a dish of one pooled world) carries in its own row of the dish table.
##
## The table: drift as a share of speed, and the diffusion along and across the slope per speed squared, on lattices even
## in log s and log eps, plus the diffusion with no slope at all (the s = 0 row), which is worked out from the swimming's
## constants rather than measured (see _flat_diffusion): in a flat medium nothing sets a heading, and the measurement
## has nothing to climb.

const OUT := "res://scripts/motion_table.gd"
const V := 20.0  ## µm/s: the swimmers' speed (the table is per unit of speed: this only has to be one the run can measure)
const C0 := 10000.0  ## the concentration at the ramp's centre; far above any detection floor, so the floor does not matter
const RADIUS := 1200.0  ## µm: wide enough that no wall is in reach
const RESOLUTION := 100
const WARM := 20.0  ## s: long enough for the heading distribution (runs of about 7 s climbing) to reach its steady state
const WINDOW := 10.0  ## s over which the drift and the diffusion are measured, after the warm-up
const FINE_STEP := 0.05  ## s: the stepping of the measurement (the real swimming, not the coarse model)
const BUPS := 20000
const SEED := 1234
const SENSE := 50.0  ## the swimmers' sense gene; eps is set through the noise reference, so this only has to be a usable one
const EPS_PER_BATCH := 4  ## rows of EPSILONS in one pooled world (4 x 18 dishes of 20,000 bups)
const FROZEN_MEDIUM := 1.0e15  ## the medium's thickness: a nutrient that does not spread
const BUP_MASS := 9.0  ## a size of 3, the founders' size
const NEVER_DIVIDES := 5000.0  ## the birth mass
const REACH := 20.0  ## µm: how far from the ramp's centre the swimmers start
const GRADIENTS := [0.01, 0.015, 0.025, 0.035, 0.05, 0.07, 0.1, 0.15, 0.2, 0.3, 0.45, 0.7, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0]  ## %/µm: log-gradients of the ramps
const EPSILONS := [0.001, 0.002, 0.004, 0.008, 0.014, 0.02, 0.03, 0.045, 0.07, 0.1, 0.15, 0.25, 0.4, 0.7, 1.2, 2.3]  ## the estimate errors aimed for
const S_POINTS := 24  ## lattice points in log s
const E_POINTS := 16  ## lattice points in log eps
const DRIFT_MAX := 0.25  ## a drift above this share of speed is noise
const DIFFUSION_RANGE := Vector2(0.4, 1.5)  ## per speed squared: what the measurement can be taken for (tumbling, rotating and running: 160-600 µm²/s at 20 µm/s)
## The measured drift is multiplied by this. The coarse model reads the nutrient at the start of each sub-step and the
## crowd spreads as it goes, which together make it climb a little less than the crowd measured here did. It is set so that the
## table at 20 s steps runs close to the real swimming on average over the cases of tests/sim/motion_test.gd (the test allows
## the average to be 0.1 µm/s off). If a change to the swimming pushes that average out of bounds, this is the number to adjust,
## then run this tool again.
const CALIBRATION := 1.017

static var _crowds := {}  ## the records of each kind of crowd made so far (trials of one kind start alike)
var _calibration := CALIBRATION
var _out := OUT


## A pooled world in which nothing eats: the crowds swim in the nutrient they are given, which stays as set.
static func new_world() -> SimHarness:
	var h := SimHarness.make([], {"delta": FINE_STEP})
	if h != null:
		h.core._consts["uptake_per_size"] = 0.0
		h.core._fill_p()
		h.core._delta = -1.0
	return h


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("out="):
			_out = a.substr(4)
		elif a.begins_with("calibration="):
			_calibration = float(a.substr(12))
	var h := new_world()
	if h == null:
		TestUtil.check(false, "gen_motion_table: needs a window and the pooled core")
		TestUtil.finish(self, "gen_motion_table OK")
		return
	var started := Time.get_ticks_msec()
	var rows := {}  # s -> [[eps, drift per speed, d along per speed², d across per speed², s.e. of drift per speed], ...]
	for first in range(0, EPSILONS.size(), EPS_PER_BATCH):
		var trials := []
		for eps_target: float in EPSILONS.slice(first, first + EPS_PER_BATCH):
			for gradient: float in GRADIENTS:
				trials.append(ramp_trial(gradient, noise_for(eps_target)))
		var reads := run_world(h, trials, [[WARM, FINE_STEP, true], [WINDOW / 2.0, FINE_STEP, true], [WINDOW / 2.0, FINE_STEP, true]])
		for k in trials.size():
			var key := snappedf(V * float(trials[k]["gradient"]) / 100.0, 1e-6)
			if not rows.has(key):
				rows[key] = []
			rows[key].append(_measure(trials[k], reads[k]))
		print("eps rows %d-%d measured (%d s)" % [first, first + EPS_PER_BATCH - 1, (Time.get_ticks_msec() - started) / 1000])
	_write(rows)
	print("written %s in %d s" % [_out, (Time.get_ticks_msec() - started) / 1000])
	TestUtil.finish(self, "gen_motion_table OK")


# ---- the pooled world of pseudo-dishes (shared with tests/sim/motion_test.gd) ----------------------------------------------

## A trial: `bups` identical swimmers placed within `reach` of the centre of a dish of `radius`, in the nutrient `field` (a Callable from a
## dish-local position to a concentration), with its own noise reference (under 0: the constants').
static func trial(radius: float, bups: int, speed: float, sense: float, reach: float, field: Callable, noise := -1.0) -> Dictionary:
	return {"radius": radius, "bups": bups, "speed": speed, "sense": sense, "reach": reach, "field": field, "noise": noise}


## The founders' records: a full reserve and a huge birth mass (they neither eat nor divide), random places and headings.
static func crowd_records(t: Dictionary, seed_value: int) -> PackedByteArray:
	var key := [t["bups"], seed_value, t["speed"], t["sense"], t["reach"]]
	if _crowds.has(key):
		return _crowds[key]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7919 + 17
	var genome := Genome.founder()
	var n: int = t["bups"]
	var out := PackedByteArray()
	out.resize(n * GpuLayout.RECORD_BYTES)
	for i in n:
		var o := i * GpuLayout.RECORD_BYTES
		var at := Vector2.from_angle(rng.randf() * TAU) * (float(t["reach"]) * sqrt(rng.randf()))
		var dir := Vector2.from_angle(rng.randf() * TAU)
		out.encode_float(o + GpuLayout.R_X * 4, at.x)
		out.encode_float(o + GpuLayout.R_Y * 4, at.y)
		out.encode_float(o + GpuLayout.R_DX * 4, dir.x)
		out.encode_float(o + GpuLayout.R_DY * 4, dir.y)
		out.encode_float(o + GpuLayout.R_ENERGY * 4, Cell.RESERVE_PER_MASS * BUP_MASS)
		out.encode_float(o + GpuLayout.R_MASS * 4, BUP_MASS)
		out.encode_float(o + GpuLayout.R_BIRTH_MASS * 4, NEVER_DIVIDES)
		for g in GpuLayout.GENE_NAMES.size():
			out.encode_float(o + (GpuLayout.R_SPEED + g) * 4, float(genome[GpuLayout.GENE_NAMES[g]]))
		out.encode_float(o + GpuLayout.R_SPEED * 4, float(t["speed"]))
		out.encode_float(o + GpuLayout.R_SENSE * 4, float(t["sense"]))
		out.encode_float(o + GpuLayout.R_MUTATOR * 4, 1.0)
		out.encode_float(o + GpuLayout.R_HUE * 4, float(genome["hue"]))
		out.encode_float(o + GpuLayout.R_SAT * 4, float(genome["sat"]))
		out.encode_float(o + GpuLayout.R_VAL * 4, float(genome["val"]))
		out.encode_float(o + GpuLayout.R_PX * 4, GpuLayout.NO_PICTURE)
		out.encode_float(o + GpuLayout.R_PY * 4, GpuLayout.NO_PICTURE)
		out.encode_float(o + GpuLayout.R_FAST * 4, -1.0)
	_crowds[key] = out
	return out


## Runs the trials as dishes of `h`'s world through `phases` ([seconds, step, read]: after a phase with read true every trial's bups
## are read). Returns, for each trial, an Array of reads, each {"x", "y", "mass"} (PackedFloat32Arrays indexed by the bup's number from
## 0, NAN where it has died). The dishes are removed afterwards.
static func run_world(h: SimHarness, trials: Array, phases: Array) -> Array:
	var rows := []
	var firsts := []
	for k in trials.size():
		var t: Dictionary = trials[k]
		var spec := DishSpec.new()
		spec.number = k + 1
		spec.radius = t["radius"]
		spec.resolution = RESOLUTION
		spec.limit = int(t["bups"]) + 100
		spec.seed = SEED + k
		spec.patchiness = 0.0
		spec.nutrient_density = 0.0
		spec.medium_thickness = FROZEN_MEDIUM
		spec.noise_reference = t["noise"]
		spec.cloud_quota = 1024
		spec.husk_quota = 16
		spec.founders = crowd_records(t, int(t.get("seed", SEED)))
		var first: int = h.core.next_id()
		var row: int = h.core.add_dish(spec)
		assert(row >= 0, "gen_motion_table: the pool refused a dish")
		var grid: DishGrid = h.core._dishes[row].grid
		var values := PackedFloat32Array()
		values.resize(grid.n * grid.n)
		var field: Callable = t["field"]
		for i in grid.n * grid.n:
			values[i] = field.call(Vector2(((i % grid.n) + 0.5) * grid.spacing - grid.radius, ((i / grid.n) + 0.5) * grid.spacing - grid.radius))
		h.core.set_field(row, values)
		rows.append(row)
		firsts.append(first)
	var reads := []
	for k in rows.size():
		reads.append([])
	for phase: Array in phases:
		h.step(int(round(float(phase[0]) / float(phase[1]))), float(phase[1]))
		if not phase[2]:
			continue
		for k in rows.size():
			reads[k].append(_read(h, rows[k], firsts[k], int(trials[k]["bups"])))
	for row: int in rows:
		h.core.remove_dish(row)
	return reads


static func _read(h: SimHarness, row: int, first: int, bups: int) -> Dictionary:
	var recs: PackedByteArray = h.core.records(row)
	var f := recs.to_float32_array()
	var n := recs.size() / GpuLayout.RECORD_BYTES
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	var ms := PackedFloat32Array()
	xs.resize(bups)
	ys.resize(bups)
	ms.resize(bups)
	xs.fill(NAN)
	ys.fill(NAN)
	ms.fill(NAN)
	for i in n:
		var k := GpuLayout.id_of(recs, i) - first
		if k >= 0 and k < bups:
			xs[k] = f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_X]
			ys[k] = f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_Y]
			ms[k] = f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_MASS]
	return {"x": xs, "y": ys, "mass": ms}


## The error in the estimate of the slope of a swimmer of this sense and mass at concentration c, with this noise reference (the
## swim kernel's `err`).
static func estimate_error(sense: float, mass: float, c: float, noise_reference: float) -> float:
	var k := SimConstants.build()
	var sense_range: float = sense * sqrt(sqrt(mass) / float(k["reference_size"]))
	return minf(float(k["gradient_noise"]) * (float(k["reference_sense"]) / sense_range) * sqrt(noise_reference / maxf(c, 1e-5)), 5.0)


## The noise reference at which a swimmer at C0 reads its slope with the error `target` (the error goes as its square root).
static func noise_for(target: float) -> float:
	var one := estimate_error(SENSE, BUP_MASS, C0, 1.0)
	return pow(target / one, 2.0)


## A ramp trial: concentration C0 * exp(x / length) (held to ±400 µm), length 100 / gradient_percent.
static func ramp_trial(gradient_percent: float, noise: float) -> Dictionary:
	var length := 100.0 / gradient_percent
	var t := trial(RADIUS, BUPS, V, SENSE, REACH, func(p: Vector2) -> float: return ramp_value(p.x, length), noise)
	t["gradient"] = gradient_percent
	return t


static func ramp_value(x: float, length: float) -> float:
	return C0 * exp(clampf(x, -400.0, 400.0) / length)


## One ramp: [eps of the crowd at the start of the window, drift / speed, D along / speed², D across / speed², s.e. of the drift / speed].
func _measure(t: Dictionary, reads: Array) -> Array:
	var start: Dictionary = reads[0]
	var alive := []
	var mean_x := 0.0
	for k in BUPS:
		if not is_nan(start["x"][k]):
			alive.append(k)
			mean_x += start["x"][k]
	mean_x /= alive.size()
	var eps := estimate_error(SENSE, start["mass"][alive[0]], ramp_value(mean_x, 100.0 / float(t["gradient"])), float(t["noise"]))
	var half := _spread(reads[1], start, alive)
	var whole := _spread(reads[2], start, alive)
	var n: float = whole[4]
	return [eps, whole[0] / WINDOW / V, (whole[2] - half[2]) / WINDOW / V / V, (whole[3] - half[3]) / WINDOW / V / V, sqrt(whole[2] / n) / WINDOW / V]


## [mean displacement along x, along y, variance of x, variance of y, count] of the crowd (those of `alive` still there) since it started.
static func _spread(read: Dictionary, start: Dictionary, alive: Array) -> Array:
	var n := 0
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var syy := 0.0
	for k: int in alive:
		if is_nan(read["x"][k]):
			continue
		var mx: float = read["x"][k] - start["x"][k]
		var my: float = read["y"][k] - start["y"][k]
		sx += mx
		sy += my
		sxx += mx * mx
		syy += my * my
		n += 1
	var ax := sx / n
	var ay := sy / n
	return [ax, ay, sxx / n - ax * ax, syy / n - ay * ay, n]


# ---- from the measurements to the table ----------------------------------------------------------------

func _write(rows: Dictionary) -> void:
	var s_measured: Array = rows.keys()
	s_measured.sort()
	var s_axis := _log_lattice(s_measured[0], s_measured[-1], S_POINTS)
	var e_axis := _log_lattice(EPSILONS[0], EPSILONS[-1], E_POINTS)
	# Each measured row (one s) read at the lattice's eps (the crowd's own eps drifts a little below the aimed one as it
	# climbs, so rows are interpolated in ln eps by what was measured), then every column at the lattice's s, in ln s.
	var by_row := {}
	for column in [1, 2, 3, 4]:
		by_row[column] = []
		for s: float in s_measured:
			var points: Array = rows[s].duplicate()
			points.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
			var line := []
			for e: float in e_axis:
				line.append(_interpolate(log(e), points.map(func(p: Array) -> float: return log(p[0])), points.map(func(p: Array) -> float: return p[column])))
			by_row[column].append(line)
	var log_s_measured := s_measured.map(func(s: float) -> float: return log(s))
	var drift := []
	var along := []
	var across := []
	for s: float in s_axis:
		var drift_row := []
		var along_row := []
		var across_row := []
		for j in e_axis.size():
			drift_row.append(clampf(_interpolate(log(s), log_s_measured, by_row[1].map(func(line: Array) -> float: return line[j])), 0.0, DRIFT_MAX))
			along_row.append(clampf(_interpolate(log(s), log_s_measured, by_row[2].map(func(line: Array) -> float: return line[j])), DIFFUSION_RANGE.x, DIFFUSION_RANGE.y))
			across_row.append(clampf(_interpolate(log(s), log_s_measured, by_row[3].map(func(line: Array) -> float: return line[j])), DIFFUSION_RANGE.x, DIFFUSION_RANGE.y))
		drift.append(drift_row)
		along.append(along_row)
		across.append(across_row)
	for i in range(1, s_axis.size()):  # a steeper slope never gives less drift (what is left of that in the measurement is noise at the lowest s)
		for j in e_axis.size():
			drift[i][j] = maxf(drift[i][j], drift[i - 1][j])
	for i in s_axis.size():
		for j in e_axis.size():
			drift[i][j] *= _calibration
	_compare_with_table(s_axis, e_axis, drift, by_row[4], log_s_measured)
	var flat := e_axis.map(func(e: float) -> float: return _flat_diffusion(e))
	var text := "class_name MotionTable\nextends RefCounted\n"
	text += "## GENERATED by tools/gen_motion_table.gd: do not edit by hand, run that (the command is in its header) to measure it again.\n"
	text += "## How the coarse motion of long steps behaves, measured from the real run-and-tumble swimming: the drift up the nutrient\n"
	text += "## gradient and the diffusion along and across it, as a function of s (speed times the log-gradient the swimmer faces) and\n"
	text += "## eps (the error in its estimate of it). SimCore reads these from SimConstants.build() and loads them into the\n"
	text += "## dish tables (the motion_* slots of gpu/gpu_layout.gd). The two hashes say what it was measured from; MotionFingerprint and the tests compare them.\n"
	text += "## Row-major: the value for S_AXIS[i] and E_AXIS[j] is at index i * E_AXIS.size() + j.\n"
	text += "const CONSTANTS_HASH := \"%s\"\nconst CODE_HASH := \"%s\"\n" % [MotionFingerprint.constants_hash(), MotionFingerprint.code_hash()]
	text += _array("S_AXIS", s_axis) + _array("E_AXIS", e_axis) + _array("DRIFT", _flatten(drift))
	text += "## Per speed squared.\n" + _array("D_ALONG", _flatten(along)) + _array("D_ACROSS", _flatten(across))
	text += "## The diffusion with no slope at all (the s = 0 row), per speed squared, at each E_AXIS.\n" + _array("D_FLAT", flat)
	var file := FileAccess.open(_out, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	_report(s_axis, e_axis, drift, along, across, rows)


## How far the new drift is from the table this run started from (MotionTable as loaded), cell by cell in units of the cell's standard error
## (that of the new measurement, read at the cell the way the drift is). The two lattices are the same when the axes are.
func _compare_with_table(s_axis: Array, e_axis: Array, drift: Array, se_lines: Array, log_s_measured: Array) -> void:
	if MotionTable.S_AXIS.size() != s_axis.size() or MotionTable.E_AXIS.size() != e_axis.size():
		print("comparison skipped: the table's axes differ")
		return
	var within := 0
	var within_both := 0
	var sum_gap := 0.0
	var cells := 0
	var worst := 0.0
	for i in s_axis.size():
		for j in e_axis.size():
			var se: float = _interpolate(log(s_axis[i]), log_s_measured, se_lines.map(func(line: Array) -> float: return line[j])) * _calibration
			var gap: float = drift[i][j] - float(MotionTable.DRIFT[i * e_axis.size() + j])
			sum_gap += gap
			cells += 1
			worst = maxf(worst, absf(gap) * V)
			if absf(gap) <= 2.0 * se:
				within += 1
			if absf(gap) <= 2.0 * sqrt(2.0) * se:
				within_both += 1
	print("new drift against the table it replaces: %d of %d cells within 2 s.e. of the new measurement (%.1f%%), %d within 2 s.e. of the difference of the two measurements (%.1f%%); mean gap %.4f µm/s, worst %.3f µm/s" % [within, cells, 100.0 * within / cells, within_both, 100.0 * within_both / cells, sum_gap / cells * V, worst])


func _report(s_axis: Array, e_axis: Array, drift: Array, along: Array, across: Array, rows: Dictionary) -> void:
	print("drift as a share of speed x1000 (rows s, columns eps):")
	print("  s \\ eps " + " ".join(e_axis.map(func(e: float) -> String: return "%5.3f" % e)))
	for i in s_axis.size():
		print("  %6.4f  " % s_axis[i] + " ".join(drift[i].map(func(v: float) -> String: return "%5.0f" % (1000.0 * v))))
	var worst := 0.0
	var sum_sq := 0.0
	var count := 0
	var error := 0.0
	for s: float in rows:  # how far the lattice is from the points it was made from (calibration undone)
		for p: Array in rows[s]:
			var gap: float = (_lattice_drift(s_axis, e_axis, drift, s, p[0]) / _calibration - p[1]) * V
			worst = maxf(worst, absf(gap))
			sum_sq += gap * gap
			error += p[4] * V
			count += 1
	print("table against the %d measured points: RMS %.3f µm/s, worst %.3f (their own s.e. is about %.3f)" % [count, sqrt(sum_sq / count), worst, error / count])


func _lattice_drift(s_axis: Array, e_axis: Array, drift: Array, s: float, eps: float) -> float:
	var x := clampf((log(s) - log(s_axis[0])) / (log(s_axis[-1]) - log(s_axis[0])) * (s_axis.size() - 1), 0.0, s_axis.size() - 1.000001)
	var y := clampf((log(eps) - log(e_axis[0])) / (log(e_axis[-1]) - log(e_axis[0])) * (e_axis.size() - 1), 0.0, e_axis.size() - 1.000001)
	var i := int(x)
	var j := int(y)
	var tx := x - i
	var ty := y - j
	return drift[i][j] * (1 - tx) * (1 - ty) + drift[i + 1][j] * tx * (1 - ty) + drift[i][j + 1] * (1 - tx) * ty + drift[i + 1][j + 1] * tx * ty


## The diffusion of a swimmer with no slope to climb, per speed squared. A run-and-tumble swimmer in two dimensions
## diffuses with D = v² / (2 (rate (1 - a) + Dr)), after Schnitzer (1993), where rate is its tumble rate, a the mean cosine
## of a tumble's turn and Dr its rotational diffusion; a tumble also stops it for TUMBLE_SECONDS, which scales the
## result by 1 / (1 + rate * TUMBLE_SECONDS). With no slope the tumble rate is the base rate cut by what its noisy
## estimate suggests (a signal that is noise alone still lowers it when the noise reads as an improvement), so the rate
## is the base rate times the mean of clamp(1 - gain * eps * z, up_factor, 1) for z a standard normal.
func _flat_diffusion(eps: float) -> float:
	var gain: float = Cell.CHEMOTAXIS_GAIN * eps
	var floor_rate: float = Biology.TUMBLE_UP_FACTOR
	var share := 1.0
	if gain > 0.0:  # (z < 0 gives 1, 0 < z < u gives 1 - gain z, z > u gives the floor: u = (1 - floor) / gain)
		var u := (1.0 - floor_rate) / gain
		share = 0.5 + (_phi_cdf(u) - 0.5) - gain * (_phi_pdf(0.0) - _phi_pdf(u)) + floor_rate * (1.0 - _phi_cdf(u))
	var rate: float = Cell.TUMBLE_BASE * share
	var cos_turn := exp(-Biology.TUMBLE_TURN_SPREAD * Biology.TUMBLE_TURN_SPREAD / 2.0) * cos(Biology.TUMBLE_TURN_MEAN)
	var rotation: float = Biology.ROTATIONAL_DIFFUSION * Biology.ROTATIONAL_DIFFUSION / 2.0
	return 1.0 / (2.0 * (rate * (1.0 - cos_turn) + rotation)) / (1.0 + rate * Biology.TUMBLE_SECONDS)


func _phi_pdf(x: float) -> float:
	return exp(-x * x / 2.0) / sqrt(TAU)


func _phi_cdf(x: float) -> float:
	return 0.5 * (1.0 + _erf(x / sqrt(2.0)))


## Abramowitz & Stegun 7.1.26 (error under 1.5e-7).
func _erf(x: float) -> float:
	var t := 1.0 / (1.0 + 0.3275911 * absf(x))
	var poly := ((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592
	return signf(x) * (1.0 - poly * t * exp(-x * x))


func _log_lattice(low: float, high: float, points: int) -> Array:
	var lattice := []
	for i in points:
		lattice.append(exp(lerpf(log(low), log(high), float(i) / (points - 1))))
	return lattice


## np.interp: linear, and flat beyond the ends. `xs` must rise.
func _interpolate(x: float, xs: Array, ys: Array) -> float:
	if x <= xs[0]:
		return ys[0]
	for i in range(1, xs.size()):
		if x <= xs[i]:
			return lerpf(ys[i - 1], ys[i], (x - xs[i - 1]) / (xs[i] - xs[i - 1]))
	return ys[-1]


func _flatten(grid: Array) -> Array:
	var flat := []
	for row: Array in grid:
		flat.append_array(row)
	return flat


func _array(name: String, values: Array) -> String:
	var lines := []
	for i in range(0, values.size(), 8):
		lines.append("\t" + ", ".join(values.slice(i, i + 8).map(func(v: float) -> String: return String.num(v, 6 if absf(v) >= 0.01 or v == 0.0 else 9))) + ",")
	return "const %s := [\n%s\n]\n" % [name, "\n".join(lines)]
