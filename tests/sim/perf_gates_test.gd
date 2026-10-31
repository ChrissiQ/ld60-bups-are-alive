extends SceneTree
## The performance gates against the pre-pool baseline `tools/gpu/baseline/perf_pre_pool.json`.
##
## Expected values, written before the first run:
## - Static part (runs headless): the baseline holds every key the gates read, so a missing key fails with its path [derived from the
##   gates]: scenarios A, B, C100, C48, D, E, F each with frame_ms_p95_mean_of_runs and achieved_speed_mean_of_runs; G "50", "200",
##   "1000" each with cpu and gpu and best_of_the_two; x1 by_bups "1000" and "100000" with runs[].share_frames_picture_changed.
## - The gate functions (`gate_*`), checked on synthetic numbers [derived from the gate text]:
##   E: p95 <= min(baseline E p95, 1.15 x display frame) and speed >= 9,500 (measured baseline: p95 10.18 ms, speed 9,994; display frame
##   8.33 ms [measured] so the cap is 9.58 ms). F: p95 and speed no worse than the baseline's (p95 64.66 ms, speed 309 [measured]) and
##   per-step cost at 2M <= 0.85 x the single-dish path's. A and B: p95 <= the baseline's (A: 32.0 ms [measured]). G: frame mean <= the best of the
##   two backends' + 1 SD, and speed >= 10,000. x1: payload advances in >= 99% of display frames.
## - The speed column of gates E, F, G and x1 is measured windowed through the real sim thread (GpuSimBackend, WorldClient; no game
##   stack: the main thread only sends set_time each frame, tells the sim which payload texture it bound, and reads snapshots.
##   The dishes are those of the scenarios (tools/gpu/bench_scenarios.gd): filled to their limit at once (the founder's genes, reserves from none to full,
##   masses 1 to 2 birth masses, spread inside 95% of the rim), nutrient and feed at the setup maxima, 100 cells across; 12 s of settling,
##   then the window. Achieved speed = the snapshots' world clock over the wall clock. Written before the first run:
##   E: 100,000 bups, 45 mm, x10,000, 600 s: every sliding 60 s window (1 s apart) >= x9,500 and the whole run >= baseline E's mean
##     minus its spread, 9,994 - 8.3 = x9,985.7 [measured baseline]; expected to pass: a 100k step is about 0.9 ms of GPU plus about 0.5 ms
##     fixed [derived from the 18 ms 2M step and the per-step dispatches], so x10,000 (500 steps a second) keeps the device about 70% busy.
##   F: 2,000,000 bups, 90 mm, x10,000, 60 s: >= baseline F's mean minus its spread, 309 - 0.5 = x308.5 [measured baseline]; expected
##     about x800 (a step about 20 ms [measured] plus the iteration's readback and publish, one step an iteration) [derived].
##   G: 50, 200 and 1,000 bups (limit = count), 45 mm, x10,000, 30 s each: >= x9,990 (x10,000 less what one iteration's lag of at most
##     T_ITER of steps leaves unmeasured over 30 s and frame capping) [derived]; the single-dish path's best is x10,000 at each size [measured baseline].
##   x1: 1,000 and 100,000 bups, 45 mm, x1, 60 s: the share of display frames in which a new payload arrived; >= 0.99 is the gate as
##     written, but with the step tied to the speed the sim steps 60 times a second, so on a 120 Hz display at most
##     about 0.50 of frames can have a new one [derived]: the gate is expected to FAIL as written and is to be settled. Edit to
##     visible (paused, a source placed, 8 times): frames until a snapshot shows it, <= 2 frames + one iteration [derived], the single-dish path's 1 frame
##     [measured baseline, a pixel hash].
##   The interface column (frame p95 and worst on the game screen) is measured in the interface gate on the final tree; the main frames printed here are
##   this script's (no game screen), for reference only. The 1M pipette and gates C, D and the 1,000-dish interface stay stubs.
##   Args (windowed): `-- gate=E|F|G|x1|all` (default all; E alone takes about 11 minutes); `seconds=N` shortens E's window (a diagnosis,
##   not the gate).

const BASELINE := "res://tools/gpu/baseline/perf_pre_pool.json"
const DISPLAY_FRAME_MS := 8.333  ## ms [measured]: a frame of the 120 Hz display of the one machine the baseline was measured on (`environment.machine` in BASELINE)
const E_SPEED_FLOOR := 9500.0
const E_FRAME_SHARE := 1.15
const F_STEP_COST_SHARE := 0.85
const G_SPEED_FLOOR := 10000.0
const X1_SHARE := 0.99
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
	["scenarios", "D", "frame_ms_p95_mean_of_runs"], ["scenarios", "E", "frame_ms_p95_mean_of_runs"],
	["scenarios", "E", "achieved_speed_mean_of_runs"], ["scenarios", "F", "frame_ms_p95_mean_of_runs"],
	["scenarios", "F", "achieved_speed_mean_of_runs"],
	["scenarios", "G", "50", "cpu", "frame_ms_mean_of_runs"], ["scenarios", "G", "50", "gpu", "frame_ms_mean_of_runs"],
	["scenarios", "G", "50", "best_of_the_two", "cpu_frame_ms_mean"], ["scenarios", "G", "50", "best_of_the_two", "gpu_frame_ms_mean"],
	["scenarios", "G", "200", "best_of_the_two", "cpu_frame_ms_mean"], ["scenarios", "G", "1000", "best_of_the_two", "gpu_frame_ms_mean"],
	["scenarios", "x1", "by_bups", "1000", "runs"], ["scenarios", "x1", "by_bups", "100000", "runs"],
]


func _initialize() -> void:
	var baseline := load_baseline()
	for path: Array in REQUIRED:
		TestUtil.show(lookup(baseline, path) != null, "baseline has %s" % "/".join(path))
	_gate_checks()
	for stub in [["the 1M pipette measurement", "a later change"], ["gates C, D and the 1,000-dish interface", "a later change"]]:
		print("SKIP perf_gates_test: %s, enabled by %s" % stub)
	if not SimHarness.device_available():
		print("SKIP perf_gates_test: gates E, F, G, x1 measurements need a local GPU (not available headless), enabled by a later change")
		TestUtil.finish(self, "OK perf_gates_test (static part; measurements skipped: headless)")
		return
	var which := "all"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("gate="):
			which = a.substr(5)
	var gates: Array = ["G", "x1", "F", "E"] if which == "all" else [which]
	for g: String in gates:
		match g:
			"E":
				await _gate_e_speed(baseline)
			"F":
				await _gate_f_speed(baseline)
			"G":
				await _gate_g_speed(baseline)
			"x1":
				await _gate_x1_speed()
			_:
				TestUtil.show(false, "no gate named %s" % g)
	TestUtil.finish(self, "OK perf_gates_test (gates %s: the speed column)" % ", ".join(gates))


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
		GpuLayout.set_id(out, i, GpuLayout.make_id(number, i + 1))
	return out


## A world with one dish of `spec` in the main view, run at `speed`: settles, then measures `seconds`. Returns {samples: [[wall s, world s]],
## frames: [ms], payload_frames (frames in which a new payload arrived), timing (the last snapshot's), steps, ok, note}; `edits` > 0 then
## pauses and times that many source placements to the snapshot that shows them.
func _measure(label: String, spec: DishSpec, speed: float, seconds: float, edits := 0) -> Dictionary:
	var t_setup := Time.get_ticks_msec()
	var backend := GpuSimBackend.new()
	backend.start(PoolLimits.from_settings())
	var w := WorldClient.new(backend)
	var row := w.add_dish(spec)
	var view := ViewRequest.new()
	view.camera = Rect2(-spec.radius, -spec.radius, 2.0 * spec.radius, 2.0 * spec.radius)
	view.pixel_um = 2.0 * spec.radius / 1000.0
	view.want_field_view = true
	w.set_view(row, view)
	var out := {"ok": false, "label": label}
	var t0 := Time.get_ticks_msec()
	while not w.latest().dishes.has(row):
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
	while true:
		await process_frame
		frame += 1
		var now := Time.get_ticks_usec()
		var dt := (now - last_usec) / 1e6
		last_usec = now
		w.set_time(speed, false, dt)
		w.poll()
		var snap := w.latest()
		if snap.payload != null:
			w.texture_bound("payload", snap.payload.texture_index, frame)
		if now < settle_until:
			last_payload = snap.payload.seq if snap.payload != null else -1
			continue
		if started < 0:
			started = now
		frames.append(dt * 1000.0)
		samples.append([(now - started) / 1e6, snap.sim_time])
		var pseq := snap.payload.seq if snap.payload != null else -1
		if pseq != last_payload:
			payload_frames += 1
		last_payload = pseq
		if (now - started) / 1e6 >= seconds:
			break
	out["samples"] = samples
	out["frames"] = frames
	out["payload_frames"] = payload_frames
	out["timing"] = w.latest().timing
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
	TestUtil.show(gate_speed_kept(speed, mean, spread), "gate F: 2,000,000 bups no slower than today (>= x%.1f)" % (mean - spread))


func _gate_g_speed(baseline: Dictionary) -> void:
	for n in [50, 200, 1000]:
		var m := await _measure("G%d" % n, filled_spec(n, DISH_45MM), 10000.0, G_SECONDS)
		_print_run(m)
		var speed := run_speed(m.get("samples", []))
		var best: Dictionary = lookup(baseline, ["scenarios", "G", str(n), "best_of_the_two"])
		print("GATE G%d speed [measured]: run x%.1f; the single-dish path's best (%s) x%s" % [n, speed, best.get("backend"), lookup(baseline, ["scenarios", "G", str(n), String(best.get("backend")), "achieved_speed_mean_of_runs"])])
		TestUtil.show(m["ok"], "gate G (%d bups): the run was clean" % n)
		TestUtil.show(speed >= G_SPEED_FLOOR - G_SPEED_TOLERANCE, "gate G (%d bups): x10,000 sustained (>= x%.0f)" % [n, G_SPEED_FLOOR - G_SPEED_TOLERANCE])


func _gate_x1_speed() -> void:
	for n in [1000, 100000]:
		var m := await _measure("x1/%d" % n, filled_spec(n, DISH_45MM), 1.0, X1_SECONDS, X1_EDITS)
		_print_run(m)
		var frames: Array = m.get("frames", [])
		var share := float(m.get("payload_frames", 0)) / maxf(frames.size(), 1)
		var edit_frames: Array = m.get("edit_frames", [])
		var hz := DisplayServer.screen_get_refresh_rate()
		print("GATE x1/%d [measured]: a new payload in %.3f of %d display frames (display %.0f Hz; derived most %.2f); edit to visible (frames) %s" % [n, share, frames.size(), hz, minf(1.0, 60.0 / maxf(hz, 1.0)), edit_frames])
		TestUtil.show(m["ok"], "gate x1 (%d bups): the run was clean" % n)
		TestUtil.show(gate_x1(share), "gate x1 (%d bups): a new payload in >= 99%% of display frames (the step rule caps it near 60 / display Hz)" % n)
		TestUtil.show(not edit_frames.is_empty() and edit_frames.max() <= 3, "gate x1 (%d bups): edit to visible <= 2 frames + one iteration (%s)" % [n, edit_frames])
