extends SceneTree
## The performance gates, against the baseline `tools/gpu/baseline/perf_pre_pool.json` (figures measured before the pooled world; the file's
## `environment` says on what).
##
## Scenario letters (the baseline's keys, the gates' names): A, one 90 mm dish of 1,000,000 bups on the game screen; B, that dish with 940,000
## bups and six more dishes of 12,000; C100 and C48, 20 dishes of 100 bups with grids of 100 x 100 and 48 x 48 cells; C (the gate), 100 dishes
## of 100 bups; D, 100 dishes of 10,000 bups against one dish of 1,000,000; E, one 45 mm dish of 100,000 bups; F, one 90 mm dish of 2,000,000
## bups; G, 50, 200 or 1,000 bups in one 45 mm dish; x1, the share of display frames in which a new picture is shown at playback speed x1.
## A, B and the interface are measured by tests/sim/interface_gate.gd, the others here.
##
## Expected values, written before the first run:
## - Static part (runs headless): the baseline holds every key the gates read, so a missing key fails with its path [derived from the
##   gates]: scenarios A, B, C100, C48, D, E, F each with frame_ms_p95_mean_of_runs and achieved_speed_mean_of_runs; G "50", "200",
##   "1000" each with cpu and gpu (the figures of the two backends the baseline was measured with: a simulation on the processor, the CPU
##   simulation the pooled world replaced, and one on the GPU) and best_of_the_two; x1 by_bups "1000" and "100000" with runs[].share_frames_picture_changed.
## - The gate functions (`gate_*`), checked on synthetic numbers [derived from the gate text]:
##   E: p95 <= min(baseline E p95, 1.15 x display frame) and speed >= 9,500 (measured baseline: p95 10.18 ms, speed 9,994; display frame
##   8.33 ms [measured] so the cap is 9.58 ms). F: p95 and speed no worse than the baseline's (p95 64.66 ms, speed 309 [measured]) and
##   per-step cost at 2M <= 0.85 x the baseline's. A and B: p95 <= the baseline's (A: 32.0 ms [measured]). G: frame mean <= the best of the
##   baseline's two backends' + 1 SD, and speed >= 10,000. x1: payload advances in >= 99% of display frames.
## - The speed column of gates E, F, G and x1 is measured windowed through the real sim thread (GpuSimBackend, WorldClient; no game
##   stack): the main thread only sends set_time each frame, tells the sim which payload texture it bound, and reads snapshots.
##   The dishes are filled to their limit at once (the founder's genes, reserves from none to full,
##   masses 1 to 2 birth masses, spread inside 95% of the rim), nutrient and feed at the setup maxima, 100 cells across; 12 s of settling,
##   then the window. Achieved speed = the snapshots' world clock over the wall clock. Written before the first run:
##   E: 100,000 bups, 45 mm, x10,000, 600 s: every sliding 60 s window (1 s apart) >= x9,500 and the whole run >= baseline E's mean
##     minus its spread, 9,994 - 8.3 = x9,985.7 [measured baseline]; expected to pass: a 100k step is about 0.9 ms of GPU plus about 0.5 ms
##     fixed [derived from the measured 18 ms 2M step and the per-step dispatches], so x10,000 (500 steps a second) keeps the device about 70% busy.
##   F: 2,000,000 bups, 90 mm, x10,000, 60 s: >= baseline F's mean minus its spread, 309 - 0.5 = x308.5 [measured baseline]; expected
##     about x800 (a step about 20 ms [measured] plus the iteration's readback and publish, one step an iteration) [derived].
##   G: 50, 200 and 1,000 bups (limit = count), 45 mm, x10,000, 30 s each: >= x9,990 (x10,000 less what one iteration's lag of at most
##     T_ITER of steps leaves unmeasured over 30 s and frame capping) [derived]; the baseline's best is x10,000 at each size [measured baseline].
##   x1: 1,000 and 100,000 bups, 45 mm, x1, 60 s: the share of display frames in which a new payload is shown; >= 0.99 is the gate. The
##     sim steps Governor.STEPS_PER_SECOND (120) times a simulated second, so on a 120 Hz display every frame can have a new one [derived];
##     this script shows the payload WorldClient's playout gives each frame (one publish a frame in order, at most WAITING_MOST (2) waiting:
##     publishes that land together are shown on the frames after), as the game does: 0.9997 at 1,000 and 0.9989 at 100,000 with one waiting [measured:
##     a replay of 7,200 frames' arrivals recorded in a run of this script; showing the newest gave 0.978 and 0.867 on the same frames]. Edit to
##     visible (paused, a source placed, 8 times): frames until a snapshot shows it, <= 2 frames + one iteration [derived], the baseline's 1 frame
##     [measured baseline, a pixel hash].
##   The interface column (frame p95 and worst on the game screen) is measured by tests/sim/interface_gate.gd; the main frames printed here
##   are this script's (no game screen), for reference only.
## - Gates C and D, written before the first run. Both ask x10,000 (20 s steps: min(20, speed/120)) and the speed reached is the figure; the
##   step's cost is the sum of the window's iterations' busy time over their steps (each iteration once), and the reference world is measured
##   first in the same process (the GPU is bimodal between processes), each world with 12 s of settling.
##   C: 100 dishes of 100 bups at the limit, each the default dish (45 mm, a 100 x 100 grid, checked): the speed reached >= x5,000 (the
##   bound: many dishes of the default size at half the top speed or better). Measured [two processes]: x5,577 and x5,558 (a step of 3.46 and 3.47 ms), so about 10% of room. The cost is the 100 grids' (1M cells),
##   not the 10,000 bups'. `dishes=` and `radius=` rerun it at other sizes as a diagnosis (300 um gives the smallest grid, 48 x 48).
##   D: 100 dishes of 10,000 bups (45 mm, 100 cells across), against one 90 mm dish of 1,000,000: step <= 1.2 x. Expected about 1.0 x [derived: the
##   same 1M bups, the same 100 x 100 grid per dish, 100 dishes' field 1M cells (a tenth of the bups' work); the reference's step is
##   about 11.4 ms [derived: half of the 22.75 ms at 2M]].
##   The 1,000-dish interface is tests/sim/interface_gate.gd (the game screen on the real pool: this script has none), whose bounds are the
##   static `gate_interface` here.
## - The pipette on a dish of 1,000,000 bups, through WorldClient as Dish.pipette sends it, the world running at x10,000 (the
##   filled dish: 1,000,000 bups, 90 mm, limit 1,000,000), a circle of 20 mm at the middle. Written before the first run:
##   the main thread's part of the call (WorldClient.pipette: a command queued) < 1 ms [derived: no read, no wait]; no frame of the wait
##   longer than 3 display frames [derived: the main thread only polls]; no whole-dish readback and no lineage export or import [derived,
##   read in the code: SimCore.pipette reads back DSTATE and WORLD and the moved ids only (`_ids_from`), the store gets `retarget_ids`];
##   the reply within one iteration of the command [derived: the sim thread drains a command between iterations, so it waits at most an
##   iteration and the rest after it; the new dish's grid was made ahead for the main view's dish (SimThread._make_grid_ahead), so the
##   retarget is done at once, one pipette pass; the worker answers after the iteration it holds (its lineage), and the main thread sees
##   the reply at its next frame: <= the longest iteration seen + its rest + the pass + the worker's lineage + a display frame]. The
##   bound of T_ITER + sync is a placeholder (Governor.T_ITER_MS 25 ms is a target for an iteration's steps, not a bound on one: a 1M
##   step alone is longer) and is printed beside it. The screen's side of the reply (a Dish adopting the receiver, as Main._finish_pipette does, and drawing it: its MultiMesh made for
##   twice the payload's count, at most the limit's): adopt < one display frame and no frame of the 20 after it over 3 display frames
##   [derived: adopt only sets fields and sends commands; the drawing makes its instance buffer once, for the moved bups, and its view
##   (ViewRenderer) from kernel text the first view of the run took].
##   Args (windowed): `-- gate=E|F|G|x1|55|C|D|all` (55 is the 1M pipette check) (default all; E alone takes about 11 minutes); `seconds=N` shortens E's window (a diagnosis,
##   not the gate).

const BASELINE := "res://tools/gpu/baseline/perf_pre_pool.json"
const DISPLAY_FRAME_MS := 8.333  ## ms [measured]: a frame of the 120 Hz display of the one machine the baseline was measured on (`environment.machine` in BASELINE)
const E_SPEED_FLOOR := 9500.0
const E_FRAME_SHARE := 1.15
const F_STEP_COST_SHARE := 0.85
const G_SPEED_FLOOR := 10000.0
const X1_SHARE := 0.99
const C_SPEED_FLOOR := 5000.0  ## gate C: the speed 100 default dishes must reach
const C_DISHES := 100
const C_BUPS := 100
const C_RADIUS := 45000.0  ## µm: the default dish (StartConditions.DEFAULT_RADIUS), a 100 x 100 grid
const C_ACROSS := 100  ## its grid's cells across
const C_SECONDS := 30.0
const D_SPEED_FLOOR := 900.0  ## gate D: the speed 100 dishes of 10,000 bups must reach
const D_DISHES := 100
const D_BUPS := 10000
const D_SECONDS := 30.0
const G_SPEED_TOLERANCE := 10.0  ## [derived] what the measurement cannot see of x10,000 over a 30 s window (one iteration's lag, frame capping)
const SETTLE_SECONDS := 12.0  ## the settling before a window
const E_SECONDS := 600.0
const E_WINDOW := 60.0
const F_SECONDS := 60.0
const G_SECONDS := 30.0
const X1_SECONDS := 60.0
const X1_EDITS := 8
const DISH_45MM := 45000.0
const DISH_90MM := 90000.0
const WAIT_MSEC := 300000
const REQUIRED := [
	["scenarios", "A", "frame_ms_p95_mean_of_runs"], ["scenarios", "A", "achieved_speed_mean_of_runs"],
	["scenarios", "B", "frame_ms_p95_mean_of_runs"], ["scenarios", "B", "achieved_speed_mean_of_runs"],
	["scenarios", "C100", "frame_ms_p95_mean_of_runs"], ["scenarios", "C48", "frame_ms_p95_mean_of_runs"],
	["scenarios", "C100", "frame_ms_mean_of_runs"], ["scenarios", "C48", "frame_ms_mean_of_runs"], ["scenarios", "C48", "frame_ms_max_of_runs"],
	["scenarios", "D", "frame_ms_p95_mean_of_runs"], ["scenarios", "E", "frame_ms_p95_mean_of_runs"],
	["scenarios", "E", "achieved_speed_mean_of_runs"], ["scenarios", "F", "frame_ms_p95_mean_of_runs"],
	["scenarios", "F", "achieved_speed_mean_of_runs"],
	["scenarios", "G", "50", "cpu", "frame_ms_mean_of_runs"], ["scenarios", "G", "50", "gpu", "frame_ms_mean_of_runs"],
	["scenarios", "G", "50", "best_of_the_two", "cpu_frame_ms_mean"], ["scenarios", "G", "50", "best_of_the_two", "gpu_frame_ms_mean"],
	["scenarios", "G", "200", "best_of_the_two", "cpu_frame_ms_mean"], ["scenarios", "G", "1000", "best_of_the_two", "gpu_frame_ms_mean"],
	["scenarios", "x1", "by_bups", "1000", "runs"], ["scenarios", "x1", "by_bups", "100000", "runs"],
]


var _holder: Node2D  ## the 1M pipette's dish nodes (added while the test starts: the root takes no child later)


func _initialize() -> void:
	_holder = Node2D.new()
	root.add_child(_holder)
	var baseline := load_baseline()
	for path: Array in REQUIRED:
		TestUtil.show(lookup(baseline, path) != null, "baseline has %s" % "/".join(path))
	_gate_checks()
	if not SimHarness.device_available():
		print("SKIP perf_gates_test: gates C, D, E, F, G, x1 measurements need a local GPU (not available headless)")
		TestUtil.finish(self, "OK perf_gates_test (static part; measurements skipped: headless; gates A and B are tests/sim/interface_gate.gd's scenario=A and scenario=B)")
		return
	var which := "all"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("gate="):
			which = a.substr(5)
	var gates: Array = ["G", "x1", "55", "F", "C", "D", "E"] if which == "all" else [which]
	for g: String in gates:
		match g:
			"C":
				await _gate_c_speed()
			"D":
				await _gate_d_step()
			"E":
				await _gate_e_speed(baseline)
			"F":
				await _gate_f_speed(baseline)
			"G":
				await _gate_g_speed(baseline)
			"x1":
				await _gate_x1_speed()
			"55":
				await _row_55()
			_:
				TestUtil.show(false, "no gate named %s" % g)
	TestUtil.finish(self, "OK perf_gates_test (gates %s: the speed column, gates C and D and the 1M pipette; the 1,000-dish interface and gates A and B are tests/sim/interface_gate.gd)" % ", ".join(gates))


static func load_baseline() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASELINE))
	return parsed if parsed is Dictionary else {}


## The value at `path` (keys down the dictionaries), or null when a key is missing.
static func lookup(d: Variant, path: Array) -> Variant:
	var at: Variant = d
	for k in path:
		if not (at is Dictionary) or not (at as Dictionary).has(k):
			return null
		at = at[k]
	return at


static func gate_e(p95_ms: float, speed: float, baseline_p95_ms: float) -> bool:
	return p95_ms <= minf(baseline_p95_ms, E_FRAME_SHARE * DISPLAY_FRAME_MS) and speed >= E_SPEED_FLOOR


static func gate_f(p95_ms: float, speed: float, step_cost: float, baseline_p95_ms: float, baseline_speed: float, baseline_step_cost: float) -> bool:
	return p95_ms <= baseline_p95_ms and speed >= baseline_speed and step_cost <= F_STEP_COST_SHARE * baseline_step_cost


static func gate_ab(p95_ms: float, baseline_p95_ms: float) -> bool:
	return p95_ms <= baseline_p95_ms


static func gate_g(frame_ms_mean: float, speed: float, best_cpu_ms: float, best_gpu_ms: float, sd_ms: float) -> bool:
	return frame_ms_mean <= minf(best_cpu_ms, best_gpu_ms) + sd_ms and speed >= G_SPEED_FLOOR


static func gate_x1(share_advanced: float) -> bool:
	return share_advanced >= X1_SHARE


## Gate C (100 default dishes of 100 bups): the speed reached >= x5,000.
static func gate_c(speed: float) -> bool:
	return speed >= C_SPEED_FLOOR


## Gate D (100 default dishes of 10,000 bups): the speed reached >= x900.
static func gate_d(speed: float) -> bool:
	return speed >= D_SPEED_FLOOR


## The 1,000-dish interface: the p95 frame and the mean no worse than the 20-dish baseline's. (The worst frame is printed, not gated:
## no bound is set for it.)
static func gate_interface(p95_ms: float, mean_ms: float, baseline_p95_ms: float, baseline_mean_ms: float) -> bool:
	return p95_ms <= baseline_p95_ms and mean_ms <= baseline_mean_ms


func _gate_checks() -> void:
	var cap := minf(10.18, E_FRAME_SHARE * DISPLAY_FRAME_MS)
	TestUtil.show(gate_e(cap, 9500.0, 10.18), "gate E passes at its limits")
	TestUtil.show(not gate_e(cap + 0.01, 9994.0, 10.18), "gate E fails a p95 over the cap")
	TestUtil.show(not gate_e(9.0, 9499.0, 10.18), "gate E fails a speed under x9,500")
	TestUtil.show(gate_f(64.66, 309.0, 0.85, 64.66, 309.0, 1.0), "gate F passes at its limits")
	TestUtil.show(not gate_f(64.66, 309.0, 0.86, 64.66, 309.0, 1.0), "gate F fails a step cost over 0.85")
	TestUtil.show(not gate_f(64.7, 400.0, 0.5, 64.66, 309.0, 1.0), "gate F fails a p95 regression")
	TestUtil.show(gate_ab(32.0, 32.0) and not gate_ab(32.1, 32.0), "gates A and B: p95 against the baseline")
	TestUtil.show(gate_g(8.4, 10000.0, 8.33, 8.33, 0.1) and not gate_g(8.6, 10000.0, 8.33, 8.33, 0.1), "gate G: the best of the two plus 1 SD")
	TestUtil.show(not gate_g(8.3, 9999.0, 8.33, 8.33, 0.1), "gate G fails a speed under x10,000")
	TestUtil.show(gate_x1(0.99) and not gate_x1(0.9899), "gate x1: 99% of frames")
	TestUtil.show(gate_c(5000.0) and not gate_c(4999.0), "gate C: speed >= x5,000")
	TestUtil.show(gate_d(900.0) and not gate_d(899.0), "gate D: speed >= x900")
	TestUtil.show(gate_interface(10.33, 9.3, 10.33, 9.31) and not gate_interface(10.34, 9.3, 10.33, 9.31), "interface: p95 no worse than the 20-dish baseline's")
	TestUtil.show(not gate_interface(9.0, 9.32, 10.33, 9.31), "interface: the mean no worse than the 20-dish baseline's")
	_playout_checks()


## WorldClient.playout on synthetic arrivals (publishes per frame), expected values derived from the rule (the oldest is shown, at most two wait,
## the oldest of more are skipped) before the first run:
## - [1, 1, 0, 2] x 25 (an iteration ending just after a poll every fourth frame): showing the newest changes the picture in 75 of 100
##   frames; the playout misses only the first empty frame (nothing was waiting yet; from the first double on one always is): 99 of 100.
## - [1, 0, 1, 1, 2] x 20 (the empty frame some frames before the double): the newest 80 of 100; the playout 99 (the first empty frame).
## - [1, 1, 0, 1] x 25 (a publish truly missing every fourth frame): 75 of 100 either way (no publish is there to show).
## - [2, 2, 0, 0] x 25 (two doubles, then two empty frames): the newest changes in 50 of 100 frames; two waiting cover both empty frames, so
##   the playout changes the picture in all 100 (with one waiting the second double skips a publish and the second empty frame is a miss: 75).
## - [3]: the oldest is shown, the other two wait; [4]: the second is shown, the oldest skipped, the newest two wait.
## - Every publish shown is shown at most WAITING_MOST frames after the frame it arrived in, and the picture never goes back to an older one.
func _playout_checks() -> void:
	var late := _played_out([1, 1, 0, 2], 25)
	TestUtil.show(late["newest"] == 75 and late["shown"] == 99, "playout: late iterations [1,1,0,2]: newest 75, playout 99 of 100 (got %d, %d)" % [late["newest"], late["shown"]])
	var apart := _played_out([1, 0, 1, 1, 2], 20)
	TestUtil.show(apart["newest"] == 80 and apart["shown"] == 99, "playout: [1,0,1,1,2]: newest 80, playout 99 of 100 (got %d, %d)" % [apart["newest"], apart["shown"]])
	var gaps := _played_out([1, 1, 0, 1], 25)
	TestUtil.show(gaps["newest"] == 75 and gaps["shown"] == 75, "playout: missing publishes [1,1,0,1]: 75 of 100 either way (got %d, %d)" % [gaps["newest"], gaps["shown"]])
	var pairs := _played_out([2, 2, 0, 0], 25)
	TestUtil.show(pairs["newest"] == 50 and pairs["shown"] == 100, "playout: two doubles then two empty frames [2,2,0,0]: newest 50, playout 100 of 100 (got %d, %d)" % [pairs["newest"], pairs["shown"]])
	var all_runs: Array = [late, apart, gaps, pairs]
	TestUtil.show(all_runs.all(func(r: Dictionary) -> bool: return r["late"] == 0 and r["back"] == 0), "playout: no publish shown more than %d frames after it came, never an older one" % WorldClient.WAITING_MOST)
	var three := WorldClient.playout([], [_publish(1), _publish(2), _publish(3)])
	TestUtil.show(three[0] != null and (three[0] as PayloadInfo).seq == 1 and three[1].size() == 2 and (three[1][0] as PayloadInfo).seq == 2 and (three[1][1] as PayloadInfo).seq == 3, "playout: three at once show the oldest, the other two wait")
	var four := WorldClient.playout([], [_publish(1), _publish(2), _publish(3), _publish(4)])
	TestUtil.show(four[0] != null and (four[0] as PayloadInfo).seq == 2 and four[1].size() == 2 and (four[1][0] as PayloadInfo).seq == 3 and (four[1][1] as PayloadInfo).seq == 4, "playout: four at once show the second, the oldest is skipped, the newest two wait")


static func _publish(seq: int) -> PayloadInfo:
	var p := PayloadInfo.new()
	p.seq = seq
	return p


## `pattern` (publishes arriving each frame) repeated `times`: {newest: frames whose newest publish changed, shown: frames whose shown
## publish changed, late: publishes shown more than WAITING_MOST frames after they came, back: frames that showed an older publish}.
static func _played_out(pattern: Array, times: int) -> Dictionary:
	var seq := 0
	var came := {}  ## seq -> frame it arrived
	var waiting: Array = []
	var shown := -1
	var out := {"newest": 0, "shown": 0, "late": 0, "back": 0}
	var frame := 0
	for t in times:
		for n: int in pattern:
			var arrived: Array = []
			for k in n:
				seq += 1
				came[seq] = frame
				arrived.append(_publish(seq))
			if n > 0:
				out["newest"] += 1
			var step := WorldClient.playout(waiting, arrived)
			waiting = step[1]
			if step[0] != null:
				var s: int = (step[0] as PayloadInfo).seq
				if s < shown:
					out["back"] += 1
				if s != shown:
					out["shown"] += 1
					if frame - int(came[s]) > WorldClient.WAITING_MOST:
						out["late"] += 1
				shown = s
			frame += 1
	return out


# ---- the speed column: measured through the sim thread ---------------------------------------------------------------------------

## Gate E's speed: every sliding 60 s window of 600 s at x10,000 >= x9,500, and the whole run not below the baseline's mean less its spread.
static func gate_e_speed(window_speeds: Array, run_speed: float, baseline_mean: float, baseline_spread: float) -> bool:
	return not window_speeds.is_empty() and window_speeds.min() >= E_SPEED_FLOOR and run_speed >= baseline_mean - baseline_spread


## The no-regression speed of gates F (and A, B): not below the baseline's mean less its spread.
static func gate_speed_kept(speed: float, baseline_mean: float, baseline_spread: float) -> bool:
	return speed >= baseline_mean - baseline_spread


## The dish: `n` bups at once (its limit), the founder's genes, reserves from none to full, masses 1 to 2 birth masses, inside 95% of
## the rim; nutrient and feed at the setup maxima; 100 cells across.
static func filled_spec(n: int, radius: float, number := 1, seed_value := 3) -> DishSpec:
	var spec := DishSpec.new()
	spec.number = number
	spec.radius = radius
	spec.resolution = StartConditions.MIN_NUTRIENT_RESOLUTION
	spec.limit = maxi(n, 10)
	spec.seed = seed_value
	spec.nutrient_density = StartConditions.MAX_NUTRIENT_DENSITY
	spec.feed_density = StartConditions.MAX_FEED_DENSITY
	spec.founders = filled_records(n, radius, number, seed_value)
	return spec


static func filled_records(n: int, radius: float, number: int, seed_value: int) -> PackedByteArray:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7919 + 17
	var founder := Genome.founder()
	var born: float = Cell.mass_to_add(founder)
	var one := PackedFloat32Array()
	one.resize(GpuLayout.RECORD_WORDS)
	for g in GpuLayout.GENE_NAMES.size():
		one[GpuLayout.R_SPEED + g] = founder[GpuLayout.GENE_NAMES[g]]
	one[GpuLayout.R_MUTATOR] = 1.0
	one[GpuLayout.R_HUE] = founder["hue"]
	one[GpuLayout.R_SAT] = founder["sat"]
	one[GpuLayout.R_VAL] = founder["val"]
	one[GpuLayout.R_BIRTH_MASS] = born
	one[GpuLayout.R_PX] = GpuLayout.NO_PICTURE
	one[GpuLayout.R_PY] = GpuLayout.NO_PICTURE
	one[GpuLayout.R_FAST] = -1.0
	var all := PackedFloat32Array()
	all.resize(n * GpuLayout.RECORD_WORDS)
	var w := GpuLayout.RECORD_WORDS
	for i in n:
		var o := i * w
		for k in w:
			all[o + k] = one[k]
		var at := Vector2.from_angle(rng.randf() * TAU) * (0.95 * radius * sqrt(rng.randf()))
		var dir := Vector2.from_angle(rng.randf() * TAU)
		all[o + GpuLayout.R_X] = at.x
		all[o + GpuLayout.R_Y] = at.y
		all[o + GpuLayout.R_DX] = dir.x
		all[o + GpuLayout.R_DY] = dir.y
		all[o + GpuLayout.R_ENERGY] = Dish.FOUNDER_ENERGY * rng.randf()
		all[o + GpuLayout.R_MASS] = born * (1.0 + rng.randf())
	var out := all.to_byte_array()
	for i in n:
		GpuLayout.set_id(out, i, (i + 1))
	return out


## A world with one dish of `spec` in the main view, run at `speed`: settles, then measures `seconds`. Returns {samples: [[wall s, world s]],
## frames: [ms], payload_frames (frames in which a new payload was shown), timing (the last snapshot's), steps, ok, note}; `edits` > 0 then
## pauses and times that many source placements to the snapshot that shows them.
func _measure(label: String, one_or_many: Variant, speed: float, seconds: float, edits := 0) -> Dictionary:
	var t_setup := Time.get_ticks_msec()
	var specs: Array = one_or_many if one_or_many is Array else [one_or_many]
	var spec: DishSpec = specs[0]
	var backend := GpuSimBackend.new()
	backend.start(PoolLimits.from_settings())
	var w := WorldClient.new(backend)
	var row := -1
	var last_row := -1
	for s: DishSpec in specs:
		last_row = w.add_dish(s)
		if row < 0:
			row = last_row
	var view := ViewRequest.new()
	view.camera = Rect2(-spec.radius, -spec.radius, 2.0 * spec.radius, 2.0 * spec.radius)
	view.pixel_um = 2.0 * spec.radius / 1000.0
	view.want_field_view = true
	w.set_view(row, view)
	var out := {"ok": false, "label": label}
	var t0 := Time.get_ticks_msec()
	while not w.latest().dishes.has(row) or not w.latest().dishes.has(last_row):
		var st := backend.status()
		if Time.get_ticks_msec() - t0 > WAIT_MSEC or (st.get("ready", false) and not st.get("alive", false)):
			out["note"] = "the dish never appeared: %s" % [backend.status()]
			backend.shutdown()
			return out
		w.set_time(speed, true, 0.0)
		w.poll()
		await process_frame
	out["setup_s"] = (Time.get_ticks_msec() - t_setup) / 1000.0
	var frame := 0
	var last_usec := Time.get_ticks_usec()
	var settle_until := Time.get_ticks_usec() + int(SETTLE_SECONDS * 1e6)
	var samples: Array = []
	var frames: Array = []
	var payload_frames := 0
	var last_payload := -1
	var started := -1
	var last_iteration := -1
	var busy_ms := 0.0  ## the window's iterations' busy time and steps (each iteration once): the step's cost is their ratio
	var busy_steps := 0
	var step_ms: Array = []
	var long_iterations: Array = []
	var miss_frames: Array = []
	var miss_times: Array = []
	var arrivals := ""  ## per frame, the publishes that were new at its poll (a digit each)
	var max_seq := 0
	while true:
		await process_frame
		frame += 1
		var now := Time.get_ticks_usec()
		var dt := (now - last_usec) / 1e6
		last_usec = now
		w.set_time(speed, false, dt)
		w.poll()
		var snap := w.latest()
		var shown := w.shown_payload()
		var fresh := 0
		for q: PayloadInfo in (snap.payloads if not snap.payloads.is_empty() else ([snap.payload] if snap.payload != null else [])):
			if q.seq > max_seq:
				max_seq = q.seq
				fresh += 1
		if shown != null:
			w.texture_bound("payload", shown.texture_index, frame, shown.seq)
		if now < settle_until:
			last_payload = shown.seq if shown != null else -1
			continue
		if started < 0:
			started = now
		arrivals += str(mini(fresh, 9))
		frames.append(dt * 1000.0)
		samples.append([(now - started) / 1e6, snap.sim_time])
		var iteration := int(snap.timing.get("iterations", -1))
		if iteration != last_iteration:
			last_iteration = iteration
			busy_ms += float(snap.timing.get("iteration_ms", 0.0))
			busy_steps += int(snap.timing.get("steps", 0))
			if int(snap.timing.get("steps", 0)) > 0:
				step_ms.append(float(snap.timing.get("run_ms", 0.0)) / int(snap.timing.get("steps", 1)))
			if float(snap.timing.get("iteration_ms", 0.0)) > 14.0:
				long_iterations.append(snappedf((now - started) / 1e6, 0.1))
		var pseq := shown.seq if shown != null else -1
		if pseq != last_payload:
			payload_frames += 1
		else:
			miss_frames.append(frames.size())
			miss_times.append((now - started) / 1e6)
		last_payload = pseq
		if (now - started) / 1e6 >= seconds:
			break
	out["samples"] = samples
	out["frames"] = frames
	out["payload_frames"] = payload_frames
	out["miss_frames"] = miss_frames
	out["miss_times"] = miss_times
	out["arrivals"] = arrivals
	out["step_ms"] = step_ms
	out["long_iterations"] = long_iterations
	out["timing"] = w.latest().timing
	out["step_cost_ms"] = busy_ms / busy_steps if busy_steps > 0 else INF
	out["status"] = backend.status()
	if edits > 0:
		out["edit_frames"] = await _edit_latency(w, row, edits)
	var r := w.inspect(func(core: SimCore, _rows: Dictionary) -> Variant: return core.overflow())
	while not r.is_done():
		await process_frame
	out["overflow"] = r.value()
	backend.shutdown()
	out["ok"] = (out["status"] as Dictionary).get("alive", false) and ((out["status"] as Dictionary).get("errors", []) as Array).is_empty() and int(out["overflow"]) == 0
	return out


## The misses of an x1 run by kind: frames whose payload did not change, as singles (one frame between two that did) and runs of two or more,
## the step's median (the run's own time over its steps, the level the GPU is in) and the misses and the longest iterations seen in the
## seconds around the arena's shrink (60 s after the world starts: about 48 s into a window after the settling).
static func _print_misses(m: Dictionary) -> void:
	var misses: Array = m.get("miss_frames", [])
	var times: Array = m.get("miss_times", [])
	var singles := 0
	var runs: Array = []
	var k := 0
	while k < misses.size():
		var j := k
		while j + 1 < misses.size() and int(misses[j + 1]) == int(misses[j]) + 1:
			j += 1
		if j == k:
			singles += 1
		else:
			runs.append(j - k + 1)
		k = j + 1
	var near := times.filter(func(t: float) -> bool: return t >= 46.0 and t <= 50.5).size()
	var steps: Array = m.get("step_ms", [])
	steps.sort()
	var median: float = steps[steps.size() / 2] if not steps.is_empty() else 0.0
	var longest: Array = m.get("long_iterations", [])
	var pool: Dictionary = (m.get("timing", {}) as Dictionary).get("pool", {})
	print("X1POOL %s: slots %s clouds %s husks %s bytes %s of budget %s (fraction %.4f), growths %s" % [m["label"], pool.get("slots"), pool.get("clouds"), pool.get("husks"), pool.get("bytes"), pool.get("budget_bytes"), float(pool.get("fraction", 0.0)), pool.get("growths")])
	print("X1ARR %s: %s" % [m["label"], m.get("arrivals", "")])
	print("X1MISSES %s: step median %.2f ms (run_ms per step, %d iterations seen); misses %d: single %d, runs of 2+ %s; within 46-50.5 s of the window %d; iterations over 14 ms seen at window s %s" % [m["label"], median, steps.size(), misses.size(), singles, runs, near, longest])


## Paused, `n` sources placed one at a time: the frames from the call to the first snapshot whose copy of the dish's world has it.
func _edit_latency(w: WorldClient, row: int, n: int) -> Array:
	var got: Array = []
	_seen_worlds.clear()
	w.set_time(1.0, true, 0.0)
	for i in 10:
		await process_frame
		w.poll()
	var have := _sources(w, row, -1)
	for e in n:
		var edit := WorldEdit.new()
		edit.kind = WorldEdit.Kind.PLACE_SOURCE
		edit.position = Vector2.from_angle(e * 0.7) * 1000.0
		edit.amount = 2.0
		w.edit_world(row, edit)
		var frames := 0
		while frames < 120:
			await process_frame
			frames += 1
			w.set_time(1.0, true, 0.0)
			w.poll()
			var now := _sources(w, row, have)
			if now > have:
				have = now
				break
		got.append(frames)
	return got


## The sources in the newest copy of dish `row`'s world (`known` when no copy came since).
var _seen_worlds := {}


func _sources(w: WorldClient, row: int, known: int) -> int:
	var snap := w.latest()
	if snap.worlds.has(row):
		_seen_worlds[row] = (snap.worlds[row] as DishWorldCopy).sources.size()
	return int(_seen_worlds.get(row, known if known >= 0 else 0))


## The world clock's rate over each `window` s span of the samples, one span a second.
static func window_speeds(samples: Array, window: float) -> Array:
	var out: Array = []
	if samples.is_empty():
		return out
	var j := 0
	var start := 0.0
	var last: float = samples[-1][0]
	while start + window <= last + 1e-9:
		while j < samples.size() - 1 and float(samples[j][0]) < start:
			j += 1
		var k := j
		while k < samples.size() - 1 and float(samples[k][0]) < start + window:
			k += 1
		var span := float(samples[k][0]) - float(samples[j][0])
		if span > 0.0:
			out.append((float(samples[k][1]) - float(samples[j][1])) / span)
		start += 1.0
	return out


static func run_speed(samples: Array) -> float:
	if samples.size() < 2:
		return 0.0
	var span := float(samples[-1][0]) - float(samples[0][0])
	return (float(samples[-1][1]) - float(samples[0][1])) / span if span > 0.0 else 0.0


static func frame_figures(frames: Array) -> String:
	if frames.is_empty():
		return "no frames"
	var s := frames.duplicate()
	s.sort()
	var mean := 0.0
	for f: float in s:
		mean += f
	mean /= s.size()
	return "main frames (this script, no game screen; for reference): mean %.2f ms, p95 %.2f, max %.2f, %d frames" % [mean, s[mini(s.size() - 1, int(0.95 * s.size()))], s[-1], s.size()]


func _print_run(m: Dictionary) -> void:
	var t: Dictionary = m.get("timing", {})
	if m.has("note"):
		print("GATE_RUN %s: %s" % [m["label"], m["note"]])
	print("GATE_RUN %s: timing %s" % [m["label"], m.get("timing", {})])
	print("GATE_RUN %s: setup %.1f s; %s; last iteration: %s steps, %.2f ms busy, step ema %.3f ms, duty %.2f, publish %.2f ms, readback %.2f ms, lineage %.2f ms; dropped %.0f s in all; overflow %s; status %s" % [
		m["label"], float(m.get("setup_s", 0.0)), frame_figures(m.get("frames", [])), t.get("steps"), float(t.get("iteration_ms", 0.0)),
		float(t.get("step_ms_ema", 0.0)), float(t.get("duty", 0.0)), float(t.get("publish_ms", 0.0)), float(t.get("readback_ms", 0.0)),
		float(t.get("lineage_ms", 0.0)), float(t.get("dropped_s", 0.0)), m.get("overflow"), m.get("status")])


func _gate_e_speed(baseline: Dictionary) -> void:
	var e_seconds := E_SECONDS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("seconds="):
			e_seconds = float(a.substr(8))
	var m := await _measure("E", filled_spec(100000, DISH_45MM), 10000.0, e_seconds)
	_print_run(m)
	var windows := window_speeds(m.get("samples", []), E_WINDOW)
	var speed := run_speed(m.get("samples", []))
	var mean := float(lookup(baseline, ["scenarios", "E", "achieved_speed_mean_of_runs"]))
	var spread := float(lookup(baseline, ["scenarios", "E", "achieved_speed_spread"]))
	print("GATE E speed [measured]: run x%.1f, sliding 60 s windows min x%.1f, max x%.1f (%d windows); baseline x%.1f less %.1f" % [speed, windows.min() if not windows.is_empty() else 0.0, windows.max() if not windows.is_empty() else 0.0, windows.size(), mean, spread])
	TestUtil.show(m["ok"], "gate E: the run was clean (no error, no overflow)")
	TestUtil.show(gate_e_speed(windows, speed, mean, spread), "gate E: 100,000 bups sustain x10,000 (every 60 s window >= x9,500, the run >= x%.1f)" % (mean - spread))


func _gate_f_speed(baseline: Dictionary) -> void:
	var m := await _measure("F", filled_spec(2000000, DISH_90MM), 10000.0, F_SECONDS)
	_print_run(m)
	var speed := run_speed(m.get("samples", []))
	var mean := float(lookup(baseline, ["scenarios", "F", "achieved_speed_mean_of_runs"]))
	var spread := float(lookup(baseline, ["scenarios", "F", "achieved_speed_spread"]))
	print("GATE F speed [measured]: run x%.1f; baseline x%.1f less %.1f" % [speed, mean, spread])
	TestUtil.show(m["ok"], "gate F: the run was clean (no error, no overflow)")
	TestUtil.show(gate_speed_kept(speed, mean, spread), "gate F: 2,000,000 bups no slower than the baseline (>= x%.1f)" % (mean - spread))


func _gate_g_speed(baseline: Dictionary) -> void:
	for n in [50, 200, 1000]:
		var m := await _measure("G%d" % n, filled_spec(n, DISH_45MM), 10000.0, G_SECONDS)
		_print_run(m)
		var speed := run_speed(m.get("samples", []))
		var best: Dictionary = lookup(baseline, ["scenarios", "G", str(n), "best_of_the_two"])
		print("GATE G%d speed [measured]: run x%.1f; the baseline's best (%s) x%s" % [n, speed, best.get("backend"), lookup(baseline, ["scenarios", "G", str(n), String(best.get("backend")), "achieved_speed_mean_of_runs"])])
		TestUtil.show(m["ok"], "gate G (%d bups): the run was clean" % n)
		TestUtil.show(speed >= G_SPEED_FLOOR - G_SPEED_TOLERANCE, "gate G (%d bups): x10,000 sustained (>= x%.0f)" % [n, G_SPEED_FLOOR - G_SPEED_TOLERANCE])


## Gate C: 100 default dishes of 100 bups at an asked x10,000: the speed it reaches is the figure.
func _gate_c_speed() -> void:
	var secs := C_SECONDS
	var dishes := C_DISHES
	var radius := C_RADIUS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("seconds="):
			secs = float(a.substr(8))
		if a.begins_with("dishes="):  ## a diagnosis (the dish count's slope), not the gate
			dishes = int(a.substr(7))
		if a.begins_with("radius="):  ## a diagnosis (the grid's size: 45000 gives the default dish's 100 x 100), not the gate
			radius = float(a.substr(7))
	var across := DishGrid.cells_across(radius, StartConditions.MIN_NUTRIENT_RESOLUTION)
	TestUtil.show(radius != C_RADIUS or across == C_ACROSS, "gate C: the default dish has a %d x %d grid" % [C_ACROSS, C_ACROSS])
	var specs: Array = []
	for i in dishes:
		specs.append(filled_spec(C_BUPS, radius, i + 1, 3 + i))
	var m := await _measure("C %dx%d" % [dishes, C_BUPS], specs, 10000.0, secs)
	_print_run(m)
	var speed := run_speed(m.get("samples", []))
	print("GATE C [measured]: %d dishes x %d bups, %d x %d: x%.1f reached (gate >= x%.0f); step %.3f ms" % [dishes, C_BUPS, across, across, speed, C_SPEED_FLOOR, m["step_cost_ms"]])
	TestUtil.show(m["ok"], "gate C: the run was clean (no error, no overflow)")
	TestUtil.show(gate_c(speed), "gate C: >= x%.0f reached (x%.1f)" % [C_SPEED_FLOOR, speed])


## Gate D: 100 default dishes of 10,000 bups at an asked x10,000: the speed it reaches is the figure.
func _gate_d_step() -> void:
	var secs := D_SECONDS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("seconds="):
			secs = float(a.substr(8))
	var specs: Array = []
	for i in D_DISHES:
		specs.append(filled_spec(D_BUPS, DISH_45MM, i + 1, 3 + i))
	var m := await _measure("D %dx%d" % [D_DISHES, D_BUPS], specs, 10000.0, secs)
	_print_run(m)
	var speed := run_speed(m.get("samples", []))
	print("GATE D [measured]: %d dishes x %d bups: x%.1f reached (gate >= x%.0f); step %.3f ms" % [D_DISHES, D_BUPS, speed, D_SPEED_FLOOR, m["step_cost_ms"]])
	TestUtil.show(m["ok"], "gate D: the run was clean (no error, no overflow)")
	TestUtil.show(gate_d(speed), "gate D: >= x%.0f reached (x%.1f)" % [D_SPEED_FLOOR, speed])


func _gate_x1_speed() -> void:
	var sizes: Array = [1000, 100000]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("bups="):
			sizes = [int(a.substr(5))]
	for n: int in sizes:
		var m := await _measure("x1/%d" % n, filled_spec(n, DISH_45MM), 1.0, X1_SECONDS, X1_EDITS)
		_print_run(m)
		var frames: Array = m.get("frames", [])
		var share := float(m.get("payload_frames", 0)) / maxf(frames.size(), 1)
		var edit_frames: Array = m.get("edit_frames", [])
		var hz := DisplayServer.screen_get_refresh_rate()
		print("GATE x1/%d [measured]: a new payload in %.3f of %d display frames (display %.0f Hz; derived most %.2f); edit to visible (frames) %s" % [n, share, frames.size(), hz, minf(1.0, Governor.STEPS_PER_SECOND / maxf(hz, 1.0)), edit_frames])
		_print_misses(m)
		TestUtil.show(m["ok"], "gate x1 (%d bups): the run was clean" % n)
		TestUtil.show(gate_x1(share), "gate x1 (%d bups): a new payload in >= 99%% of display frames (at most STEPS_PER_SECOND / display Hz)" % n)
		TestUtil.show(not edit_frames.is_empty() and edit_frames.max() <= 3, "gate x1 (%d bups): edit to visible <= 2 frames + one iteration (%s)" % [n, edit_frames])


# ---- the pipette on a dish of 1,000,000 bups -------------------------------------------------------------------------------------

func _row_55() -> void:
	var backend := GpuSimBackend.new()
	backend.start(PoolLimits.from_settings())
	var w := WorldClient.new(backend)
	var spec := filled_spec(1000000, DISH_90MM)
	var row := w.add_dish(spec)
	var view := ViewRequest.new()
	view.camera = Rect2(-spec.radius, -spec.radius, 2.0 * spec.radius, 2.0 * spec.radius)
	view.pixel_um = 2.0 * spec.radius / 1000.0
	w.set_view(row, view)
	var t0 := Time.get_ticks_msec()
	while not w.latest().dishes.has(row) and Time.get_ticks_msec() - t0 < WAIT_MSEC:
		w.set_time(10000.0, true, 0.0)
		w.poll()
		await process_frame
	var clock := [Time.get_ticks_usec(), 0]  ## the last frame's time and the frames so far (a lambda keeps a copy of a plain local)
	var tell := func() -> float:
		var now := Time.get_ticks_usec()
		var dt: float = (now - int(clock[0])) / 1e6
		clock[0] = now
		clock[1] = int(clock[1]) + 1
		w.set_time(10000.0, false, dt)
		w.poll()
		var shown := w.shown_payload()
		if shown != null:
			w.texture_bound("payload", shown.texture_index, int(clock[1]), shown.seq)
		return dt
	for i in 600:
		await process_frame
		tell.call()
	var it0 := int(w.latest().timing.get("iterations", 0))
	var c0 := Time.get_ticks_usec()
	var reply := w.pipette(row, Vector2.ZERO, 20000.0)
	var call_us := Time.get_ticks_usec() - c0
	var worst_ms := 0.0
	var t_before := w.latest().timing
	var most_iteration := float(t_before.get("iteration_ms", 0.0))
	var most_rest := float(t_before.get("rest_ms", 0.0))
	var most_lineage := float(t_before.get("lineage_ms", 0.0))
	while not reply.is_done() and (Time.get_ticks_usec() - c0) / 1000.0 < WAIT_MSEC:
		await process_frame
		worst_ms = maxf(worst_ms, tell.call() * 1000.0)
		most_iteration = maxf(most_iteration, float(w.latest().timing.get("iteration_ms", 0.0)))
		most_rest = maxf(most_rest, float(w.latest().timing.get("rest_ms", 0.0)))
		most_lineage = maxf(most_lineage, float(w.latest().timing.get("lineage_ms", 0.0)))
	var reply_ms := (Time.get_ticks_usec() - c0) / 1000.0
	var t := w.latest().timing
	var iterations := int(t.get("iterations", 0)) - it0
	var got: Variant = reply.value()
	var moved: int = int(got.get("moved", -1)) if got is Dictionary else -1
	var own_pass: float = float(got.get("pass_ms", INF)) if got is Dictionary else INF
	var adopt := await _adopted(w, row, spec, got, tell)
	var made := DishGrid.make(spec.radius, spec.resolution, spec.patchiness, 4321)
	var timed := w.inspect(func(core: SimCore, rows: Dictionary) -> Array:
		var p0 := Time.get_ticks_usec()
		var res := core.pipette(rows[row], Vector2(30000.0, 0.0), 10000.0, null, made)
		return [(Time.get_ticks_usec() - p0) / 1000.0, int(res.get("moved", -1))])
	while not timed.is_done():
		await process_frame
		tell.call()
	var pass_ms: float = timed.value()[0]
	backend.shutdown()
	var grid_ms: Array = []
	for k in 3:
		var g0 := Time.get_ticks_usec()
		DishGrid.make(spec.radius, spec.resolution, spec.patchiness, 1234 + k)
		grid_ms.append((Time.get_ticks_usec() - g0) / 1000.0)
	grid_ms.sort()
	var bound := most_iteration + most_rest + own_pass + most_lineage + DISPLAY_FRAME_MS
	print("PIPETTE1M [measured] 1M dish at x10,000: %d bups moved; the call %d us on the main thread; reply after %.1f ms (%d iterations ended meanwhile; the longest iteration seen %.2f ms, rest %.2f ms; its retarget pass %.2f ms; the worker's longest lineage %.2f ms; last sync %.2f ms); the worst frame of the wait %.1f ms; a new dish's grid (DishGrid.make, 100 cells, on this thread: made ahead, so not waited for) %.1f ms median of 3; a second pipette's pass alone (SimCore.pipette with its grid made, %d bups) %.1f ms" % [moved, call_us, reply_ms, iterations, most_iteration, most_rest, own_pass, most_lineage, float(t.get("sync_ms", 0.0)), worst_ms, grid_ms[1], timed.value()[1], pass_ms])
	TestUtil.show(moved > 0 and call_us < 1000 and worst_ms <= 3.0 * DISPLAY_FRAME_MS, "1M pipette: the pipette of a 1M dish moved %d bups; the main thread's call %d us (< 1 ms), no frame of the wait over 3 display frames (worst %.1f ms)" % [moved, call_us, worst_ms])
	print("PIPETTE1M [measured] the screen's side of the reply: Dish.adopt of the receiver (the source's 1M limit) %.2f ms; the worst of the 20 frames after it, the receiver drawn in the main view (its picture made for its count), %.1f ms; Main's own part (_finish_pipette: the strip, the dish set) not measured here" % [adopt[0], adopt[1]])
	TestUtil.show(adopt[0] < DISPLAY_FRAME_MS and adopt[1] <= 3.0 * DISPLAY_FRAME_MS, "1M pipette: taking the reply stalls no frame (adopt %.2f ms, then the worst frame %.1f ms)" % [adopt[0], adopt[1]])
	TestUtil.show(reply_ms <= bound, "1M pipette: the reply within one iteration of the command (<= the longest iteration %.1f + its rest %.1f + its pass %.1f + the worker's lineage %.1f + a display frame = %.1f ms [derived]): %.1f ms (T_ITER %.0f ms + sync %.1f = %.1f ms, the placeholder)" % [most_iteration, most_rest, own_pass, most_lineage, bound, reply_ms, Governor.T_ITER_MS, float(t.get("sync_ms", 0.0)), Governor.T_ITER_MS + float(t.get("sync_ms", 0.0))])


## The screen's side of a pipette's reply: Dish nodes for the source (out of the main view) and the receiver (adopted from the reply, in the
## main view, as Main._finish_pipette makes it); [adopt's ms, the worst frame of the 20 after it in ms].
func _adopted(w: WorldClient, row: int, spec: DishSpec, got: Variant, tell: Callable) -> Array:
	if not (got is Dictionary):
		return [INF, INF]
	var camera := Camera2D.new()
	_holder.add_child(camera)
	camera.make_current()
	camera.zoom = Vector2.ONE * (500.0 / spec.radius)
	var source := Dish.new()
	source.world = w
	source.number = spec.number
	source.radius = spec.radius
	source.resolution = spec.resolution
	source.bup_limit = spec.limit
	_holder.add_child(source)
	source.row = row
	source.park()  # (as Main parks the dish the receiver takes the main view from)
	ViewRenderer.new(PoolLimits.from_settings().frame_queue_size).release()  # (as in the game, where the source was drawn before: the first view takes the kernels' text, once a run)
	await process_frame
	tell.call()
	var receiver := Dish.new()
	receiver.world = w
	_holder.add_child(receiver)
	var a0 := Time.get_ticks_usec()
	receiver.adopt(int(got["new_row"]), int(got["number"]), source)
	var adopt_ms := (Time.get_ticks_usec() - a0) / 1000.0
	var worst := 0.0
	for i in 20:
		await process_frame
		worst = maxf(worst, float(tell.call()) * 1000.0)
	return [adopt_ms, worst]
