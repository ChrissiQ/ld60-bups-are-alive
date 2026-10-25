extends SceneTree
## Measures the motion table (scripts/motion_table.gd) from the real run-and-tumble swimming, and writes it.
##
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s tools/gen_motion_table.gd
##
## About 5 minutes. Run it whenever tests/motion_table_test.gd says the table is stale, which it does when a constant
## of the real swimming (SimConstants.MOTION_INPUTS) or the code that makes it (MotionFingerprint.FINE_MOTION) changes.
## Nothing else needs doing: the table is read by the native code from SimConstants.build().
##
## What is measured. Fast playback moves a bup in long steps that span many runs and tumbles, so it needs what the real
## swimming averages to: a drift up the nutrient gradient and a random walk. Both depend only on two numbers: s, the speed
## times the log-gradient the swimmer faces (how steep the slope is for it), and eps, the error in its estimate of the slope
## (sense_error). For a grid of both, a crowd of identical swimmers is run in an exponential nutrient ramp (a constant
## log-gradient) that is held still, with no eating, far from any wall and far above the detection floor, after a warm-up
## long enough for the crowd's memory and headings to settle. The drift is how far the crowd's mean moves in 10 s, the
## diffusion how fast its variance grows along and across the ramp. eps is set by the noise reference, which is changed
## for each row; the swimmers' own eps (read from the model) is what the row is indexed by.
##
## The table: drift as a share of speed, and the diffusion along and across the slope per speed squared, on lattices even
## in log s and log eps, plus the diffusion with no slope at all (the s = 0 row), which is worked out from the swimming's
## constants rather than measured (see _flat_diffusion): in a flat medium nothing sets a heading, and the measurement
## has nothing to climb.

const OUT := "res://scripts/motion_table.gd"
const V := 20.0  ## µm/s: the swimmers' speed (the table is per unit of speed: this only has to be one the run can measure)
const C0 := 10000.0  ## the concentration at the ramp's centre; far above any detection floor, so the floor does not matter
const RADIUS := 1200.0  ## µm: wide enough that no wall is in reach
const WARM := 20.0  ## s: long enough for the heading distribution (runs of about 7 s climbing) to reach its steady state
const WINDOW := 10.0  ## s over which the drift and the diffusion are measured, after the warm-up
const FINE_STEP := 0.05  ## s: the stepping of the measurement (the real swimming, not the coarse model)
const BUPS := 20000
const SEED := 1234
const SENSE := 50.0  ## the swimmers' sense gene; eps is set through the noise reference, so this only has to be a usable one
const GRADIENTS := [0.01, 0.015, 0.025, 0.035, 0.05, 0.07, 0.1, 0.15, 0.2, 0.3, 0.45, 0.7, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0]  ## %/µm: log-gradients of the ramps
const EPSILONS := [0.001, 0.002, 0.004, 0.008, 0.014, 0.02, 0.03, 0.045, 0.07, 0.1, 0.15, 0.25, 0.4, 0.7, 1.2, 2.3]  ## the estimate errors aimed for
const S_POINTS := 24  ## lattice points in log s
const E_POINTS := 16  ## lattice points in log eps
const DRIFT_MAX := 0.25  ## a drift above this share of speed is noise
const DIFFUSION_RANGE := Vector2(0.4, 1.5)  ## per speed squared: what the measurement can be taken for (tumbling, rotating and running: 160-600 µm²/s at 20 µm/s)
## The measured drift is multiplied by this. The coarse model reads the nutrient at the start of each sub-step and the
## crowd spreads as it goes, which together make it climb a little less than the crowd measured here did. It is set so that the
## table at 20 s steps runs close to the real swimming on average over the cases of tests/motion_table_test.gd (the test allows
## the average to be 0.1 µm/s off). If a change to the swimming pushes that average out of bounds, this is the number to adjust,
## then run this tool again.
const CALIBRATION := 1.017

var _constants: Dictionary
var _probe: Dish


func _init() -> void:
	_constants = SimConstants.build()  # (configured here, not by SimConstants.apply(), which would complain that this very table is stale)
	_constants["diffusion"] = 0.0
	_constants["uptake_per_size"] = 0.0
	assert(FINE_STEP <= _constants["fine_step"], "the measurement must use the real (fine) swimming")
	assert(C0 > 1.0e6 * _constants["detection_floor"], "the ramp must stay far above the detection floor")
	BupSim.configure(_constants)
	_probe = Dish.new()
	root.add_child(_probe)
	var started := Time.get_ticks_msec()
	var rows := {}  # s -> [[eps, drift per speed, d along per speed², d across per speed², s.e. of drift per speed], ...]
	for eps_target: float in EPSILONS:
		_aim_eps(eps_target)
		for gradient: float in GRADIENTS:
			var s := V * gradient / 100.0
			var key := snappedf(s, 1e-6)
			if not rows.has(key):
				rows[key] = []
			rows[key].append(_measure(gradient))
		print("eps %s measured (%d s)" % [eps_target, (Time.get_ticks_msec() - started) / 1000])
	_write(rows)
	print("written %s in %d s" % [OUT, (Time.get_ticks_msec() - started) / 1000])
	quit()


## Sets the noise reference so that a swimmer at C0 reads its slope with this error. The error goes as the square root of the
## noise reference (Berg & Purcell), which is checked rather than assumed.
func _aim_eps(target: float) -> void:
	var reference: float = _constants["noise_reference"]
	var before := _eps_at_c0()
	_constants["noise_reference"] = reference * pow(target / before, 2.0)
	BupSim.configure(_constants)
	var after := _eps_at_c0()
	assert(absf(after / target - 1.0) < 0.02, "the estimate error no longer goes as the square root of the noise reference (%.4f for %.4f): rework _aim_eps" % [after, target])


func _eps_at_c0() -> float:
	_probe.clear_bups()
	var genome := Genome.founder()
	genome["sense"] = SENSE
	var id: int = _probe.sim.add_bup(Vector2.ZERO, genome, 1000.0, 3.0, 5000.0, 0, Vector2.RIGHT)
	var eps: float = _probe.sim.bup_estimate_error(id, C0)
	_probe.sim.remove_bup(id)
	return eps


## One ramp: [eps of the crowd at the start of the window, drift / speed, D along / speed², D across / speed², s.e. of the drift / speed].
func _measure(gradient_percent: float) -> Array:
	var length := 100.0 / gradient_percent
	var d := Dish.new()
	root.add_child(d)
	d.set_seed(SEED)
	var start := StartConditions.new()
	start.dish_radius = RADIUS
	start.bup_limit = 2 * BUPS  # (more than the crowd, so none is displaced)
	start.nutrient_density = 0.0
	d.strike(start)
	d.clear_bups()
	d.feed_density = 0.0
	var values := []
	for i in d.field.size * d.field.size:
		values.append(C0 * exp(clampf(d.field.cell_centre(i).x, -400.0, 400.0) / length))
	d.field.load_values(values)
	var ids := []
	for i in BUPS:
		var genome := Genome.founder()
		genome["sense"] = SENSE
		genome["speed"] = V
		var p: Vector2 = d.sim.random_point(20.0)
		ids.append(d.sim.add_bup(p, genome, 1000.0, 3.0, 5000.0, 0, Vector2.from_angle(d.sim.random_float() * TAU)))  # (a full reserve and a huge birth mass: it neither eats nor divides)
	_run(d, WARM)
	ids = ids.filter(func(id: int) -> bool: return not d.bup_info(id).is_empty())  # (a bup dies now and then: the crowd is who is left)
	var starts := []
	var mean_x := 0.0
	for id: int in ids:
		var p: Vector2 = d.bup_info(id)["pos"]
		starts.append(p)
		mean_x += p.x / ids.size()
	var eps: float = d.sim.bup_estimate_error(ids[0], d.field.read(Vector2(mean_x, 0.0)).x)  # (where the crowd is: what its swimmers read)
	_run(d, WINDOW / 2.0)
	var half := _spread(d, ids, starts)
	_run(d, WINDOW / 2.0)
	var whole := _spread(d, ids, starts)
	d.free()
	var n: float = whole[4]
	return [eps, whole[0] / WINDOW / V, (whole[2] - half[2]) / WINDOW / V / V, (whole[3] - half[3]) / WINDOW / V / V, sqrt(whole[2] / n) / WINDOW / V]


func _run(d: Dish, seconds: float) -> void:
	for i in int(round(seconds / FINE_STEP)):
		d.step(FINE_STEP)


## [mean displacement along x, along y, variance of x, variance of y, count] of the crowd since it started.
func _spread(d: Dish, ids: Array, starts: Array) -> Array:
	var n := 0
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var syy := 0.0
	for i in ids.size():
		var info: Dictionary = d.bup_info(ids[i])
		if info.is_empty():
			continue
		var moved: Vector2 = info["pos"] - starts[i]
		sx += moved.x
		sy += moved.y
		sxx += moved.x * moved.x
		syy += moved.y * moved.y
		n += 1
	var mx := sx / n
	var my := sy / n
	return [mx, my, sxx / n - mx * mx, syy / n - my * my, n]


# ---- from the measurements to the table ----------------------------------------------------------------

func _write(rows: Dictionary) -> void:
	var s_measured: Array = rows.keys()
	s_measured.sort()
	var s_axis := _log_lattice(s_measured[0], s_measured[-1], S_POINTS)
	var e_axis := _log_lattice(EPSILONS[0], EPSILONS[-1], E_POINTS)
	# Each measured row (one s) read at the lattice's eps (the crowd's own eps drifts a little below the aimed one as it
	# climbs, so rows are interpolated in ln eps by what was measured), then every column at the lattice's s, in ln s.
	var by_row := {}
	for column in [1, 2, 3]:
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
			drift[i][j] *= CALIBRATION
	var flat := e_axis.map(func(e: float) -> float: return _flat_diffusion(e))
	var text := "class_name MotionTable\nextends RefCounted\n"
	text += "## GENERATED by tools/gen_motion_table.gd: do not edit by hand, run that (the command is in its header) to measure it again.\n"
	text += "## How the coarse motion of long steps behaves, measured from the real run-and-tumble swimming: the drift up the nutrient\n"
	text += "## gradient and the diffusion along and across it, as a function of s (speed times the log-gradient the swimmer faces) and\n"
	text += "## eps (the error in its estimate of it). The native code reads these from SimConstants.build() (see MotionTable in\n"
	text += "## native/src/params.h). The two hashes say what it was measured from; MotionFingerprint and the tests compare them.\n"
	text += "## Row-major: the value for S_AXIS[i] and E_AXIS[j] is at index i * E_AXIS.size() + j.\n"
	text += "const CONSTANTS_HASH := \"%s\"\nconst CODE_HASH := \"%s\"\n" % [MotionFingerprint.constants_hash(), MotionFingerprint.code_hash()]
	text += _array("S_AXIS", s_axis) + _array("E_AXIS", e_axis) + _array("DRIFT", _flatten(drift))
	text += "## Per speed squared.\n" + _array("D_ALONG", _flatten(along)) + _array("D_ACROSS", _flatten(across))
	text += "## The diffusion with no slope at all (the s = 0 row), per speed squared, at each E_AXIS.\n" + _array("D_FLAT", flat)
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	_report(s_axis, e_axis, drift, along, across, rows)


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
			var gap: float = (_lattice_drift(s_axis, e_axis, drift, s, p[0]) / CALIBRATION - p[1]) * V
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
