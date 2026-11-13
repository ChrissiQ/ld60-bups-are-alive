extends SceneTree
## Run (windowed, the GPU): tools/run_windowed.sh <outfile> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/motion_test.gd
## The coarse motion of long steps (the swim kernel's table lookup) against the real run-and-tumble swimming (its fine branch), on
## the pooled GPU: each case is a dish of one world, run once at 0.05 s steps and once at the coarse steps. Nothing eats, the nutrient
## is frozen (the medium's thickness is huge), so only the motion differs between the runs. It checks:
##   1. the drift in seven slopes, at 1.5 s and 20 s steps, within TOLERANCE of the real one (or 3 standard errors, whichever is
##      more) and, on average over the cases, within MEAN_TOLERANCE (the generator's calibration factor);
##   2. the diffusion in a flat medium (three cases), within 8%;
##   3. the crowd near the wall: not piled up against it nor leaving it empty.
## A failure of 1 is fixed by running tools/gen_motion_table.gd, and if the mean gap alone fails, by CALIBRATION there.

const Gen := preload("res://tools/gen_motion_table.gd")
const TOLERANCE := 0.2  ## µm/s: how far the coarse drift may be from the real one, beyond 3 standard errors
const MEAN_TOLERANCE := 0.1  ## µm/s: how far the average of the signed differences may be from zero
const FINE := 0.05
const DRIFT_CASES := [  # [speed µm/s, sense, concentration at the origin, gradient %/µm]
	[20.0, 150.0, 0.3, 2.0],  # keen sense, plenty of nutrient, steep: the plateau of the drift
	[20.0, 10.0, 0.0003, 5.0],  # dull sense, almost nothing to read: the plateau at high noise
	[20.0, 150.0, 0.3, 0.1],  # a shallow slope: where the drift sets in
	[20.0, 50.0, 0.03, 0.5],  # the knee
	[20.0, 10.0, 0.003, 2.0],  # in between
	[35.0, 50.0, 0.003, 1.0],  # a faster swimmer
	[20.0, 150.0, 0.3, 0.02],  # a very gentle slope, where E. coli still climbs (the linear range of the response)
]
const DRIFT_BUPS := 4000
const FLAT_CASES := [[50.0, 0.0], [10.0, 0.0003], [150.0, 0.03]]  # [sense, concentration]
const FLAT_BUPS := 16000
const WALL_BUPS := 600
const WALL_DISHES := 3


func _init() -> void:
	if not SimHarness.begin(self, "motion_test", "the pooled core (SimCore)"):
		return
	var h := Gen.new_world()
	_check_drift(h)
	_check_flat(h)
	_check_wall(h)
	h.core.release()
	TestUtil.finish(self, "MOTION TEST OK")


## The mean displacement along x per second of the crowd of each trial over `seconds` after a warm-up, as [mean, s.e.] (µm/s).
func _drifts(h: SimHarness, trials: Array, warm: float, warm_step: float, seconds: float, step: float) -> Array:
	var reads: Array = Gen.run_world(h, trials, [[warm, warm_step, true], [seconds, step, true]])
	var out := []
	for k in trials.size():
		var a: Dictionary = reads[k][0]
		var b: Dictionary = reads[k][1]
		var moved := []
		for i in a["x"].size():
			if not is_nan(a["x"][i]) and not is_nan(b["x"][i]):
				moved.append(float(b["x"][i]) - float(a["x"][i]))
		var mean := 0.0
		for m: float in moved:
			mean += m / moved.size()
		var variance := 0.0
		for m: float in moved:
			variance += (m - mean) * (m - mean) / (moved.size() - 1)
		out.append([mean / seconds, sqrt(variance / moved.size()) / seconds])
	return out


func _check_drift(h: SimHarness) -> void:
	var trials := []
	for case: Array in DRIFT_CASES:
		var length: float = 100.0 / case[3]
		var c0: float = case[2]
		var t := Gen.trial(1200.0, DRIFT_BUPS, case[0], case[1], 60.0, func(p: Vector2) -> float: return c0 * exp(clampf(p.x, -800.0, 800.0) / length))
		t["seed"] = 900
		trials.append(t)
	var fine := _drifts(h, trials, 20.0, FINE, 60.0, FINE)
	var signed_sum := 0.0
	var worst := 0.0
	for step: float in [1.5, 20.0]:
		var coarse := _drifts(h, trials, 20.0, step, 60.0, step)
		for k in DRIFT_CASES.size():
			var case: Array = DRIFT_CASES[k]
			var gap: float = coarse[k][0] - fine[k][0]
			var allowed := maxf(TOLERANCE, 3.0 * sqrt(pow(fine[k][1], 2.0) + pow(coarse[k][1], 2.0)))
			signed_sum += gap
			worst = maxf(worst, absf(gap))
			print("drift speed %.0f sense %.0f c %s %s%%/µm, %.1f s steps: coarse %.3f, real %.3f (s.e. %.3f, %.3f)" % [case[0], case[1], case[2], case[3], step, coarse[k][0], fine[k][0], coarse[k][1], fine[k][1]])
			TestUtil.check(absf(gap) <= allowed, "coarse drift (%.1f s steps) follows the real swimming: speed %.0f, sense %.0f, c %s, %s%%/µm: %.2f vs %.2f µm/s (allowed %.2f)" % [step, case[0], case[1], case[2], case[3], coarse[k][0], fine[k][0], allowed])
	var mean_gap := signed_sum / (DRIFT_CASES.size() * 2)
	TestUtil.check(absf(mean_gap) <= MEAN_TOLERANCE, "on average the coarse drift is neither high nor low (mean %.3f µm/s off, worst %.2f): if not, adjust CALIBRATION in tools/gen_motion_table.gd" % [mean_gap, worst])


## The mean squared distance from the start of each flat-medium trial after 60 s and after 120 s.
func _spreads(h: SimHarness, trials: Array, step: float) -> Array:
	var reads: Array = Gen.run_world(h, trials, [[60.0, step, true], [60.0, step, true]])
	var out := []
	for k in trials.size():
		var sums := []
		for phase in 2:
			var sum := 0.0
			var n := 0
			for i in reads[k][phase]["x"].size():
				var x: float = reads[k][phase]["x"][i]
				if not is_nan(x):
					var y: float = reads[k][phase]["y"][i]
					sum += x * x + y * y
					n += 1
			sums.append(sum / n)
		out.append(sums)
	return out


func _check_flat(h: SimHarness) -> void:
	var trials := []
	for case: Array in FLAT_CASES:
		var c: float = case[1]
		var t := Gen.trial(2500.0, FLAT_BUPS, 20.0, case[0], 0.0, func(_p: Vector2) -> float: return c)
		t["seed"] = 31
		trials.append(t)
	var fine := _spreads(h, trials, FINE)
	var coarse := _spreads(h, trials, 1.5)
	for k in FLAT_CASES.size():
		# (every swimmer starts at the centre, so the mean squared distance is the distance from the start; 16,000 swimmers: good to about 2%)
		var d_fine: float = (fine[k][1] - fine[k][0]) / (4.0 * 60.0)
		var d_coarse: float = (coarse[k][1] - coarse[k][0]) / (4.0 * 60.0)
		TestUtil.check(absf(d_coarse / d_fine - 1.0) < 0.08, "coarse diffusion in a flat medium follows the real swimming (sense %.0f, c %s: %.0f vs %.0f µm²/s)" % [FLAT_CASES[k][0], FLAT_CASES[k][1], d_coarse, d_fine])


## The share of the crowds within 20 µm of the rim of a 300 µm dish after 10 minutes. Uniform would be 0.129.
func _rim_share(h: SimHarness, step: float) -> float:
	var trials := []
	for k in WALL_DISHES:
		var t := Gen.trial(300.0, WALL_BUPS, 20.0, 50.0, 250.0, func(_p: Vector2) -> float: return 0.03)
		t["seed"] = 10 + k
		trials.append(t)
	var reads: Array = Gen.run_world(h, trials, [[600.0, step, true]])
	var near := 0
	var total := 0
	for k in WALL_DISHES:
		var r: Dictionary = reads[k][0]
		for i in r["x"].size():
			if not is_nan(r["x"][i]):
				total += 1
				near += 1 if Vector2(r["x"][i], r["y"][i]).length() > 280.0 else 0
	return float(near) / total


func _check_wall(h: SimHarness) -> void:
	var fine := _rim_share(h, FINE)
	var coarse := _rim_share(h, 20.0)
	# A swimmer in the real model slides along the wall until a tumble frees it, so a crowd collects there a little (0.17
	# against 0.129 for an even crowd): real bacteria do too. Within 0.06 of the real one, and under 0.2, keeps the coarse model
	# from piling up against the wall or leaving it empty.
	TestUtil.check(absf(coarse - fine) < 0.06 and coarse < 0.2, "a crowd does not pile up against the wall in long steps, nor leave it empty (share within 20 µm of the rim: %.3f vs %.3f in the real swimming; even would be 0.129)" % [coarse, fine])
