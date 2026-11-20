extends SceneTree
## Measures the motion table (scripts/motion_table.gd) from the real run-and-tumble swimming, and writes it.
##
## A table is the average of many runs, because one run's drift in a weak gradient is mostly sampling error. In two steps:
##
## 1. Measure (windowed: it runs on the GPU). Each seed is one run of the whole ramp set; its measured points are written to
##    <dir>/partial_<seed>.json, so seeds run on different machines combine exactly. On macOS:
##   tools/run_windowed.sh <outfile> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gen_motion_table.gd -- seeds=<first>-<last> dir=<folder>
## `seeds=` takes a range (`1-50`) or a list (`3,9,12`); a seed that has a partial file in `dir=` is skipped.
## 2. Combine (headless: no GPU). Averages every partial in the folder, fits the weak-gradient region (see _fit) and writes the table:
##   godot --headless --path . -s tools/gen_motion_table.gd -- combine=<folder> [out=<path> calibration=<x>]
##
## Run it whenever tests/motion_table_test.gd says the table is stale, which it does when a
## constant of the real swimming (SimConstants.MOTION_INPUTS) or the kernel that makes it (MotionFingerprint: the text of
## GpuKernelsField.K_SWIM) changes: the partials record the hashes they were measured from and a combine refuses stale ones.
## `out=` writes somewhere else than OUT (to compare with the committed table); the combine prints how many cells of the new
## drift lie within 2 standard errors of the table it was started from, and the standard error of the average.
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
## One crowd's drift in a weak gradient is mostly sampling error (about 0.0026 of speed a cell), so the table is the average of
## many runs, one per seed, and where the drift is smallest it is not read from the average cell by cell. For s up to FIT_S_MAX and
## eps from FIT_EPS_MIN up the drift is a straight line through zero in s (the response of a swimmer to a weak signal is
## linear), k(eps) * s, with k fitted to all the averaged rows there together (_fit) and smooth and falling in eps; below
## that eps the drift is not linear in s (the lines bend) and it is the average itself, and above that s it is large enough to be.
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
	var seeds := []
	var dir := "user://motion_table_runs"
	var combine := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("out="):
			_out = a.substr(4)
		elif a.begins_with("calibration="):
			_calibration = float(a.substr(12))
		elif a.begins_with("dir="):
			dir = a.substr(4)
		elif a.begins_with("combine="):
			combine = a.substr(8)
		elif a.begins_with("seeds="):
			seeds = _parse_seeds(a.substr(6))
	if combine != "":
		_combine(combine)
		TestUtil.finish(self, "gen_motion_table combine OK")
		return
	if seeds.is_empty():
		TestUtil.check(false, "gen_motion_table: give seeds=<first>-<last> (measure) or combine=<folder>")
		TestUtil.finish(self, "gen_motion_table OK")
		return
	var h := new_world()
	if h == null:
		TestUtil.check(false, "gen_motion_table: needs a window and the pooled core")
		TestUtil.finish(self, "gen_motion_table OK")
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var started := Time.get_ticks_msec()
	for seed_value: int in seeds:
		var path := "%s/partial_%d.json" % [dir, seed_value]
		if FileAccess.file_exists(path):
			print("seed %d: %s exists, skipped" % [seed_value, path])
			continue
		_crowds.clear()
		var rows := _measure_seed(h, seed_value)
		_write_partial(path, seed_value, rows)
		print("seed %d measured and written to %s (%d s in all)" % [seed_value, path, (Time.get_ticks_msec() - started) / 1000])
	TestUtil.finish(self, "gen_motion_table OK")


## "a-b" (both included) or "a,b,c".
func _parse_seeds(text: String) -> Array:
	var seeds := []
	if text.contains("-"):
		var ends := text.split("-")
		for v in range(int(ends[0]), int(ends[1]) + 1):
			seeds.append(v)
	else:
		for part in text.split(","):
			seeds.append(int(part))
	return seeds


## One run of the whole ramp set with this seed (its crowds and its dishes' random streams): s -> [[eps, drift per speed,
## d along per speed², d across per speed², s.e. of drift per speed], ...] for each eps aimed for.
func _measure_seed(h: SimHarness, seed_value: int) -> Dictionary:
	var rows := {}
	for first in range(0, EPSILONS.size(), EPS_PER_BATCH):
		var trials := []
		for eps_target: float in EPSILONS.slice(first, first + EPS_PER_BATCH):
			for gradient: float in GRADIENTS:
				trials.append(ramp_trial(gradient, noise_for(eps_target), seed_value))
		var reads := run_world(h, trials, [[WARM, FINE_STEP, true], [WINDOW / 2.0, FINE_STEP, true], [WINDOW / 2.0, FINE_STEP, true]])
		for k in trials.size():
			var key := snappedf(V * float(trials[k]["gradient"]) / 100.0, 1e-6)
			if not rows.has(key):
				rows[key] = []
			rows[key].append(_measure(trials[k], reads[k]))
	return rows


## What a partial records: the settings and hashes it was measured with (a combine refuses a mix), the seed, and the points.
func _write_partial(path: String, seed_value: int, rows: Dictionary) -> void:
	var points := []
	for s: float in rows:
		points.append([s, rows[s]])
	var data := {"constants_hash": MotionFingerprint.constants_hash(), "code_hash": MotionFingerprint.code_hash(), "bups": BUPS, "warm": WARM, "window": WINDOW,
		"gradients": GRADIENTS, "epsilons": EPSILONS, "seed": seed_value, "driver": RenderingServer.get_current_rendering_driver_name(), "rows": points}
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data, "", true, true))
	file.close()


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
		spec.seed = SEED + k if not t.has("seed") else int(t["seed"]) * 128 + k
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
static func ramp_trial(gradient_percent: float, noise: float, seed_value := SEED) -> Dictionary:
	var length := 100.0 / gradient_percent
	var t := trial(RADIUS, BUPS, V, SENSE, REACH, func(p: Vector2) -> float: return ramp_value(p.x, length), noise)
	t["gradient"] = gradient_percent
	t["seed"] = seed_value
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

const FIT_EPS_MIN := 0.03  ## the fit covers the lattice's eps from here up ...
const FIT_DEGREE := 4  ## the degree of the polynomial in ln eps that ln k is fitted with
const FIT_S_MAX := 0.01  ## ... and s up to here: the widest range where the rows agree with a line through zero to within the s.e. of the averages (chi² per degree of freedom near 1, printed by every combine); a fit that disagrees with the averages adds more error than it removes. FIT_S_MAX = 0 switches the fit off


## Averages the partials in `dir` and writes the table.
func _combine(dir: String) -> void:
	var names := []
	for f in DirAccess.get_files_at(dir):
		if f.begins_with("partial_") and f.ends_with(".json"):
			names.append(f)
	names.sort()
	if names.is_empty():
		TestUtil.check(false, "gen_motion_table: no partial_*.json in %s" % dir)
		return
	var e_axis := _log_lattice(EPSILONS[0], EPSILONS[-1], E_POINTS)
	var s_measured := []
	var sums := {}  # column -> [sums, sums of squares] over (measured s, lattice eps)
	var runs := 0
	var by_driver := {}  # rendering driver -> the seeds measured with it
	for name: String in names:
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(name)))
		var problem := _partial_problem(data)
		if problem != "":
			TestUtil.check(false, "gen_motion_table: %s: %s" % [name, problem])
			return
		var rows := {}
		for entry: Array in data["rows"]:
			rows[float(entry[0])] = entry[1]
		if s_measured.is_empty():
			s_measured = rows.keys()
			s_measured.sort()
		var by_row := _lattice_rows(rows, s_measured, e_axis)
		for column: int in by_row:
			if not sums.has(column):
				sums[column] = [_grid(s_measured.size(), e_axis.size()), _grid(s_measured.size(), e_axis.size())]
			for i in s_measured.size():
				for j in e_axis.size():
					var v: float = by_row[column][i][j]
					sums[column][0][i][j] += v
					sums[column][1][i][j] += v * v
		runs += 1
		var driver := str(data.get("driver", "unknown"))
		if not by_driver.has(driver):
			by_driver[driver] = []
		by_driver[driver].append(int(data["seed"]))
	var mean := {}
	var sem := {}
	for column: int in sums:
		mean[column] = _grid(s_measured.size(), e_axis.size())
		sem[column] = _grid(s_measured.size(), e_axis.size())
		for i in s_measured.size():
			for j in e_axis.size():
				var m: float = sums[column][0][i][j] / runs
				mean[column][i][j] = m
				var variance := maxf(sums[column][1][i][j] / runs - m * m, 0.0) * runs / maxf(runs - 1.0, 1.0)
				sem[column][i][j] = sqrt(variance / runs)
	print("combined %d runs from %s" % [runs, dir])
	_write(mean, sem, _provenance(by_driver), s_measured, e_axis)


## "400 runs: seeds 1-200 on Metal, 1001-1200 on Direct3D 12".
func _provenance(by_driver: Dictionary) -> String:
	var names := {"metal": "Metal", "d3d12": "Direct3D 12", "vulkan": "Vulkan"}
	var parts := []
	var total := 0
	var drivers := by_driver.keys()
	drivers.sort()
	for driver: String in drivers:
		var seeds: Array = by_driver[driver]
		seeds.sort()
		total += seeds.size()
		var ranges := []
		var k := 0
		while k < seeds.size():
			var last := k
			while last + 1 < seeds.size() and seeds[last + 1] == seeds[last] + 1:
				last += 1
			ranges.append(str(seeds[k]) if last == k else "%d-%d" % [seeds[k], seeds[last]])
			k = last + 1
		parts.append("seeds %s on %s" % [", ".join(ranges), names.get(driver, driver)])
	return "%d runs: %s" % [total, "; ".join(parts)]


## Why a partial cannot be combined with this code's table (or "").
func _partial_problem(data: Dictionary) -> String:
	if data.get("constants_hash") != MotionFingerprint.constants_hash() or data.get("code_hash") != MotionFingerprint.code_hash():
		return "measured from other constants or another swimming kernel than these"
	if int(data.get("bups", -1)) != BUPS or float(data.get("warm", -1)) != WARM or float(data.get("window", -1)) != WINDOW:
		return "measured with other bups, warm-up or window"
	if data.get("gradients") != GRADIENTS or data.get("epsilons") != EPSILONS:
		return "measured on other gradients or eps targets"
	return ""


func _grid(rows: int, columns: int) -> Array:
	var grid := []
	for i in rows:
		var line := []
		line.resize(columns)
		line.fill(0.0)
		grid.append(line)
	return grid


## One run's measured rows (s -> [[eps, drift, along, across, s.e.], ...]) read at the lattice's eps (the crowd's own eps drifts a
## little below the aimed one as it climbs, so each row is interpolated in ln eps by what was measured): column -> [row of s][lattice eps].
func _lattice_rows(rows: Dictionary, s_measured: Array, e_axis: Array) -> Dictionary:
	var by_row := {}
	for column in [1, 2, 3]:
		by_row[column] = []
		for s: float in s_measured:
			var points: Array = rows[s].duplicate()
			points.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
			var xs := points.map(func(p: Array) -> float: return log(p[0]))
			var ys := points.map(func(p: Array) -> float: return p[column])
			by_row[column].append(e_axis.map(func(e: float) -> float: return _interpolate(log(e), xs, ys)))
	return by_row


## The table from the averaged measurements (`mean` and `sem` of the average, by column 1 drift, 2 and 3 the diffusions, each
## [measured s][lattice eps]).
func _write(mean: Dictionary, sem: Dictionary, provenance: String, s_measured: Array, e_axis: Array) -> void:
	var s_axis := _log_lattice(s_measured[0], s_measured[-1], S_POINTS)
	var log_s_measured := s_measured.map(func(s: float) -> float: return log(s))
	var drift := []
	var along := []
	var across := []
	for s: float in s_axis:
		var drift_row := []
		var along_row := []
		var across_row := []
		for j in e_axis.size():
			drift_row.append(clampf(_interpolate(log(s), log_s_measured, mean[1].map(func(line: Array) -> float: return line[j])), 0.0, DRIFT_MAX))
			along_row.append(clampf(_interpolate(log(s), log_s_measured, mean[2].map(func(line: Array) -> float: return line[j])), DIFFUSION_RANGE.x, DIFFUSION_RANGE.y))
			across_row.append(clampf(_interpolate(log(s), log_s_measured, mean[3].map(func(line: Array) -> float: return line[j])), DIFFUSION_RANGE.x, DIFFUSION_RANGE.y))
		drift.append(drift_row)
		along.append(along_row)
		across.append(across_row)
	var slopes := _fit(mean[1], sem[1], s_measured, e_axis)
	for i in s_axis.size():
		for j in e_axis.size():
			if slopes[j] >= 0.0 and s_axis[i] <= FIT_S_MAX:
				drift[i][j] = slopes[j] * s_axis[i]
	_monotone_in_s(drift, sem[1], s_axis, log_s_measured)
	for i in s_axis.size():
		for j in e_axis.size():
			drift[i][j] *= _calibration
	_compare_with_table(s_axis, e_axis, drift, sem[1], log_s_measured)
	var flat := e_axis.map(func(e: float) -> float: return _flat_diffusion(e))
	var text := "class_name MotionTable\nextends RefCounted\n"
	text += "## GENERATED by tools/gen_motion_table.gd: do not edit by hand, run that (the commands are in its header) to measure it again.\n"
	text += "## How the coarse motion of long steps behaves, measured from the real run-and-tumble swimming: the drift up the nutrient\n"
	text += "## gradient and the diffusion along and across it, as a function of s (speed times the log-gradient the swimmer faces) and\n"
	text += "## eps (the error in its estimate of it). SimCore reads these from SimConstants.build() and loads them into the\n"
	text += "## dish tables (the motion_* slots of gpu/gpu_layout.gd). The two hashes say what it was measured from; MotionFingerprint and the tests compare them.\n"
	text += "## Made from the average of independent runs of the generator's ramp set, one per seed (%s). Drift: the\n" % provenance
	text += "## measured average where s > %s or eps < %s; where s <= %s and eps >= %s, a straight line through zero in s, k(eps) * s,\n" % [FIT_S_MAX, FIT_EPS_MIN, FIT_S_MAX, FIT_EPS_MIN]
	text += "## with k fitted to the average of the rows there, non-increasing in eps and smooth (tools/gen_motion_table.gd, _fit).\n"
	text += "## A cell that fell below the one before it by no more than noise is set equal to it; the declines past the drift's peak at\n"
	text += "## high s and low eps are measured and kept.\n"
	text += "## Row-major: the value for S_AXIS[i] and E_AXIS[j] is at index i * E_AXIS.size() + j.\n"
	text += "const CONSTANTS_HASH := \"%s\"\nconst CODE_HASH := \"%s\"\n" % [MotionFingerprint.constants_hash(), MotionFingerprint.code_hash()]
	text += _array("S_AXIS", s_axis) + _array("E_AXIS", e_axis) + _array("DRIFT", _flatten(drift))
	text += "## Per speed squared.\n" + _array("D_ALONG", _flatten(along)) + _array("D_ACROSS", _flatten(across))
	text += "## The diffusion with no slope at all (the s = 0 row), per speed squared, at each E_AXIS.\n" + _array("D_FLAT", flat)
	var file := FileAccess.open(_out, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	_report(s_axis, e_axis, drift, mean[1], sem[1], s_measured, slopes)
	print("written %s" % _out)


## k(eps) of the weak-gradient fit F = k * s, for each lattice eps (-1 where the fit does not apply). Each column's raw k is the
## weighted least-squares slope through zero of the averaged drift on the measured rows with s <= FIT_S_MAX (weights 1 / s.e.²);
## then ln k is fitted with a polynomial in ln eps (see _smooth_slopes), which is smooth and falls with eps.
func _fit(drift: Array, sem: Array, s_measured: Array, e_axis: Array) -> Array:
	var rows := []
	for i in s_measured.size():
		if s_measured[i] <= FIT_S_MAX + 1e-9:
			rows.append(i)
	if rows.is_empty():
		return e_axis.map(func(_e: float) -> float: return -1.0)
	var first := 0
	while e_axis[first] < FIT_EPS_MIN - 1e-9:
		first += 1
	var raw := []
	var weights := []
	for j in range(first, e_axis.size()):
		var num := 0.0
		var den := 0.0
		for i: int in rows:
			var w := 1.0 / maxf(sem[i][j] * sem[i][j], 1e-12)
			num += w * s_measured[i] * drift[i][j]
			den += w * s_measured[i] * s_measured[i]
		raw.append(num / den)
		weights.append(den)  # 1 / variance of the slope
	var fitted := _smooth_slopes(raw, weights, e_axis.slice(first))
	var slopes := []
	for j in e_axis.size():
		slopes.append(fitted[j - first] if j >= first else -1.0)
	return slopes


## The smooth k: ln k as a polynomial of ln eps (degree FIT_DEGREE), weighted least squares on the raw slopes (the weight of a
## column in ln k is its k² / variance). Every polynomial this fits for the measured slopes falls with eps over the whole range;
## it is checked, and the fit fails if it does not (the non-increasing k the lookup counts on).
func _smooth_slopes(raw: Array, weights: Array, eps: Array) -> Array:
	var n := raw.size()
	var xs := eps.map(func(e: float) -> float: return log(e))
	var mid: float = (xs[0] + xs[-1]) / 2.0
	var half: float = (xs[-1] - xs[0]) / 2.0
	var terms := FIT_DEGREE + 1
	var normal := []  # normal equations of the weighted least squares, augmented with the right-hand side
	for r in terms:
		var line := []
		line.resize(terms + 1)
		line.fill(0.0)
		normal.append(line)
	for k in n:
		var x: float = (xs[k] - mid) / half
		var w: float = weights[k] * raw[k] * raw[k]
		var y := log(raw[k])
		for r in terms:
			for c in terms:
				normal[r][c] += w * pow(x, r + c)
			normal[r][terms] += w * pow(x, r) * y
	var coefficients := _solve(normal)
	var out := []
	for k in n:
		out.append(exp(_polynomial(coefficients, (xs[k] - mid) / half)))
	var falling := true
	for step in 200:  # slope of ln k on ln eps along the range
		var x0 := -1.0 + 2.0 * step / 200.0
		var x1 := -1.0 + 2.0 * (step + 1) / 200.0
		falling = falling and _polynomial(coefficients, x1) <= _polynomial(coefficients, x0)
	TestUtil.check(falling, "gen_motion_table: the smooth k does not fall with eps over the whole range (raise or lower FIT_DEGREE)")
	return out


func _polynomial(coefficients: Array, x: float) -> float:
	var value := 0.0
	for c in range(coefficients.size() - 1, -1, -1):
		value = value * x + coefficients[c]
	return value


## Solves an augmented linear system (Gauss-Jordan with partial pivoting).
func _solve(m: Array) -> Array:
	var n := m.size()
	for col in n:
		var pivot := col
		for r in range(col + 1, n):
			if absf(m[r][col]) > absf(m[pivot][col]):
				pivot = r
		var swap: Array = m[col]
		m[col] = m[pivot]
		m[pivot] = swap
		for r in n:
			if r != col:
				var f: float = m[r][col] / m[col][col]
				for c in range(col, n + 1):
					m[r][c] -= f * m[col][c]
	var out := []
	for r in n:
		out.append(m[r][n] / m[r][r])
	return out


## Noise must not make a steeper slope give less drift. A cell below the one before it by no more than 3 s.e. of the average (the
## s.e. is about 1e-4 of speed, and the fit region's cells are exact lines) is set equal to it. A larger fall is a measurement, not
## noise: at high s and low eps the drift really declines past its peak (a swimmer on a ramp that steep spends its warm-up and window
## near the ramp's end, and its tumbles are reined in), so those cells keep the measured values; a running maximum there would
## replace a real decline of a few per cent of speed with a plateau.
## Prints how many cells were raised (all of them by noise), and how many were left falling, with the largest fall in s.e.
func _monotone_in_s(drift: Array, sem: Array, s_axis: Array, log_s_measured: Array) -> void:
	var raised := 0
	var kept := 0
	var worst := 0.0
	for j in drift[0].size():
		for i in range(1, s_axis.size()):
			var fall: float = drift[i - 1][j] - drift[i][j]
			if fall > 0.0:
				var se := maxf(_interpolate(log(s_axis[i]), log_s_measured, sem.map(func(line: Array) -> float: return line[j])), 1e-6)
				if fall <= 3.0 * se:
					drift[i][j] = drift[i - 1][j]
					raised += 1
				else:
					kept += 1
					worst = maxf(worst, fall / se)
	print("drift against s: %d cells raised to the one before (a fall of no more than 3 s.e.), %d left falling (the largest fall %.1f s.e.)" % [raised, kept, worst])


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


func _report(s_axis: Array, e_axis: Array, drift: Array, mean: Array, sem: Array, s_measured: Array, slopes: Array) -> void:
	var in_fit := []  # the s.e. of the average (share of speed) in the fit's cells, in cells with a drift under 0.01, in all
	var weak := []
	var every := []
	for i in s_measured.size():
		for j in e_axis.size():
			every.append(sem[i][j])
			if mean[i][j] < 0.01:
				weak.append(sem[i][j])
			if slopes[j] >= 0.0 and s_measured[i] <= FIT_S_MAX + 1e-9:
				in_fit.append(sem[i][j])
	for line: Array in [["fit region", in_fit], ["cells with drift < 0.01", weak], ["all measured cells", every]]:
		var list: Array = line[1].duplicate()
		if list.is_empty():
			continue
		list.sort()
		print("s.e. of the average, %s (%d cells): median %.5f, 90th percentile %.5f, max %.5f of swim speed" % [line[0], list.size(), list[list.size() / 2], list[int(list.size() * 0.9)], list[-1]])
	print("fit: eps, raw k +- s.e., fitted k, chi² of the rows about the fitted line / rows")
	var sum_chi := 0.0
	var cells := 0
	for j in e_axis.size():
		if slopes[j] < 0.0:
			continue
		var num := 0.0
		var den := 0.0
		var chi := 0.0
		var rows := 0
		for i in s_measured.size():
			if s_measured[i] <= FIT_S_MAX + 1e-9:
				var w := 1.0 / maxf(sem[i][j] * sem[i][j], 1e-12)
				num += w * s_measured[i] * mean[i][j]
				den += w * s_measured[i] * s_measured[i]
				chi += pow((mean[i][j] - slopes[j] * s_measured[i]) / maxf(sem[i][j], 1e-6), 2.0)
				rows += 1
		sum_chi += chi
		cells += rows
		print("  %6.4f  %8.3f +- %6.3f  %8.3f  %6.1f / %d" % [e_axis[j], num / den, 1.0 / sqrt(den), slopes[j], chi, rows])
	print("fit residuals: chi² %.1f over %d cells, %d degrees of freedom (chi² per degree of freedom %.2f; about 1 when the line agrees with the averages to within noise)" % [sum_chi, cells, cells - FIT_DEGREE - 1, sum_chi / maxf(cells - FIT_DEGREE - 1, 1)])
	print("drift as a share of speed x1000 (rows s, columns eps):")
	print("  s \\ eps " + " ".join(e_axis.map(func(e: float) -> String: return "%5.3f" % e)))
	for i in s_axis.size():
		print("  %6.4f  " % s_axis[i] + " ".join(drift[i].map(func(v: float) -> String: return "%5.0f" % (1000.0 * v))))


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
