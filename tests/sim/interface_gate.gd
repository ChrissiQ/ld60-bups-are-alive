extends SceneTree
## The interface at 1,000 dishes: the game screen on the real pool with every dish it allows running (Main.MAX_DISHES,
## 999: an interface choice, not the world's 1,024 rows), the dish strip and the sections showing them, measured as the 20-dish
## C scenarios (bench_scenarios.gd of the replaced CPU simulation: the game screen, the dishes filled at once, an asked x10,000, 12 s of settling, then
## 30 s of frames between process_frame calls at 2560 x 1440 windowed). Run windowed; it is not a `*_test.gd`, so tools/run_sim_tests.sh skips it:
## tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 --windowed --resolution 2560x1440 -s tests/sim/interface_gate.gd
## Args (after --): `dishes=N` (default 999), `seconds=N` (the window, default 30), `scenario=E` (gate E's frame p95, below), `scenario=A` or `scenario=B` (gates A and B, at the end of this header).
## A run counts only as the scene the baseline measured: the window 2560 x 1440 when the frames begin and when they end, and the pointer
## never over a bup (a hover card and its picks are not in the baseline). A run in a larger window with the pointer over the dish gave
## a p95 of 12.3-12.9 ms where this scene gives 9.0 [measured]; such a run fails as void.
##
## `scenario=E`: gate E's frame bound measured the way its baseline was (bench_scenarios.gd `world E 30` of the replaced CPU simulation: the game screen,
## ONE dish of 45 mm and a 100,000 limit filled to the limit at once (perf_gates_test.filled_spec, put on the screen's own dish through a
## DishSpec: StartConditions.bups stops at 250), nutrient and feed at the setup maxima, asked x10,000, 12 s settle, 30 s of frames, three runs in
## three processes). The bound is `gate_e` (p95 <= min(the baseline's 10.18 ms, 1.15 x the display frame = 9.58 ms at 120 Hz), speed >= x9,500).
## Expected values, written before the first run:
## - A frame here is the main thread's part only (the sim runs on its own thread): the snapshot swap and its decode for one 100,000-bup dish,
##   the view kernels and the draw of 100,000 instances at 2560 x 1440, the tray, graph and history refresh, the strip. The baseline's frames
##   with the same dish were mean 9.06, p95 10.18, worst 55 ms [measured]; the pooled build moved the simulation off the main thread's
##   renderer but the draw is the same, so mean about 9.0 ms and p50 about 8.9 are expected [derived], p95 9.6-10.3 ms, worst 20-60 ms
##   (a hitch at a snapshot with a large history or a shrink, `SimArena.maybe_shrink`, about 60 s after the start: outside the 12 s + 30 s window).
## - Why the earlier figures differ [derived]: the gate script's 8.75 ms (a 20-dish or 1,000-dish screen at x100, dishes of 100 bups) has little to
##   decode and draw, so its frames sit near the display's 8.33 ms; `game_check perf` (9.87-11.44 ms) draws one 100,000-bup dish but adds a
##   hover pick every frame and has no screen around it, and a bare Dish node takes every snapshot's stats. The like-for-like figure is
##   this one. The p95 sits close to the 9.58 ms cap, so a pass or fail by tenths is likely: the verdict is the mean of three processes.
## - Speed reached x9,990-10,000 [measured on the baseline]; population 99,800-99,900 at both ends (the dish holds its limit).
##
## Expected values, written before the first run:
## - The bound is `gate_interface` of perf_gates_test.gd: the p95 and the mean no worse than the 20-dish baseline's, scenario C48 (the same
##   48 x 48 grids; perf_pre_pool.json: mean 9.31 ms, p95 10.33, max 14.48). This screen's frames at 994 dishes were p50 8.34, p95 8.96-9.10,
##   worst 11.1-11.35 ms [measured, asked x100]; at x10,000 asked the main thread's part is the same (the sim is on its own
##   thread), so p95 about 9 ms is expected [derived]: inside both bounds.
## - The dishes are 300 um with 100 bups at their limit (gate C's dishes). The speed reached is printed (gate C's own figure is perf_gates_test's).
##
## `scenario=A` and `scenario=B` (gates A and B): the frame bound at a million bups, measured as the baseline's two big scenes were (the game
## screen, the dishes filled to their limits at once, nutrient and feed at the setup maxima, asked x10,000, 12 s settle, 30 s of frames at
## 2560 x 1440 windowed, three runs in three processes). A: ONE 90 mm dish of 1,000,000 bups. B: the same dish with 940,000 bups in the main
## view and six more 45 mm dishes of 12,000 running beside it (tabs, strip and tray sections for seven dishes). Each dish is the screen's own
## through a DishSpec (perf_gates_test.filled_spec), as for E. The camera is the game's fit of the main dish, so the million bups are drawn
## zoomed out, as the winner view draws them. The bound is `gate_ab`: the p95 (mean of the three runs) no worse than the baseline's in
## tools/gpu/baseline/perf_pre_pool.json (A: p95 32.0 ms, mean 31.45, speed x624; B: p95 31.32, mean 30.64, speed x630 [measured, the baseline]).
## Speed is not in the coded rule: it is printed and compared with the baseline's.
## Expected values, written before the first run:
## - A frame is the main thread's part (the sim runs on its own thread). `game_check perf 2000000` with the winner view reached x389 with frame
##   p50 8.9 ms and p95 26 ms, against x37 and p50 37 ms with capsules [measured with the capsule draw]; at fit the
##   winner view's frame mean at 2,000,000 bups was 5.3 ms against 32.5 ms with capsules [measured]. The old A and B frames (mean 31 ms) were
##   the capsule draw of a million bups [derived from those figures]. So at 1,000,000 here: frame p50 8-9 ms (the display's 8.33 ms), mean
##   9-12 ms, p95 18-28 ms (late frames while the sim thread's publishes and the readback contend for the GPU), worst 40-200 ms [derived].
##   A pass against 32.0 ms is expected for A and for B (B adds six small dishes' strip tiles and tray rows: mean +0.5 ms or less [derived]).
## - Speed: gate F (2,000,000 bups) is about x800 with a step near 20 ms [derived, gate F's header]; a million bups is half the step, so a step
##   of about 10 ms plus the iteration's readback and publish, about 80 iterations a second of one 20 s step each: x1,300-1,600 for A [derived].
##   B has 1,012,000 bups and seven dishes: the same or a little lower, x1,200-1,600 [derived]. Both above the baseline's x624 and x630.
## - Population: 1,000,000 (A) and 1,012,000 (B) at the start of the window, a little under at the end (deaths at the limit's trim).

var BASELINE_KEY := "C48"
const SETTLE_SECONDS := 12.0
const WINDOW_SECONDS := 30.0
const WAIT_MSEC := 900000
const WINDOW_SIZE := Vector2i(2560, 1440)  ## the window the baseline was measured in

var _perf := load("res://tests/sim/perf_gates_test.gd")


func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var count: int = 999  # Main.MAX_DISHES, read from the screen below
	var window := WINDOW_SECONDS
	var scenario := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("dishes="):
			count = int(a.substr(7))
		if a.begins_with("seconds="):
			window = float(a.substr(8))
		if a.begins_with("scenario="):
			scenario = a.substr(9)
	var gate_ab := scenario == "A" or scenario == "B"
	var gate_e := scenario == "E"
	if gate_e or gate_ab:
		BASELINE_KEY = scenario
	var baseline: Dictionary = _perf.load_baseline()
	var base_p95 := float(_perf.lookup(baseline, ["scenarios", BASELINE_KEY, "frame_ms_p95_mean_of_runs"]))
	var base_mean := float(_perf.lookup(baseline, ["scenarios", BASELINE_KEY, "frame_ms_mean_of_runs"]))
	var base_max := float(_perf.lookup(baseline, ["scenarios", BASELINE_KEY, "frame_ms_max_of_runs"]))
	TestUtil.show(base_p95 > 0.0 and base_mean > 0.0, "the baseline has %s's p95 and mean" % BASELINE_KEY)
	if not SimHarness.device_available():
		TestUtil.finish(self, "OK interface_gate (skipped: headless, no GPU)")
		return
	var start := StartConditions.new()
	var big_bups := 1000000 if scenario == "A" else 940000
	start.bups = 4 if (gate_e or gate_ab) else 100
	start.bup_limit = 100000 if gate_e else (big_bups if gate_ab else 100)
	start.dish_radius = _perf.DISH_45MM if gate_e else (_perf.DISH_90MM if gate_ab else 300.0)
	start.nutrient_density = StartConditions.MAX_NUTRIENT_DENSITY
	start.feed_density = StartConditions.MAX_FEED_DENSITY
	start.tutorial = false
	start.spread_founders()
	var m: Node = TestUtil.game_screen(self, start)
	if count == 999:
		count = int(m.MAX_DISHES)
	for i in 3600:
		await process_frame
		if m.is_node_ready() and m.dish != null and m.dish.row >= 0:
			break
	for i in 3600:
		if WorldClient.shared().backend.status().get("ready", false):
			break
		await process_frame
	m.toolbar.set_paused(false)
	m._set_paused(false)
	m.sim_speed = 10000.0
	var t0 := Time.get_ticks_msec()
	if gate_e:
		count = 1
		_fill(m.dish, m, 100000, _perf.DISH_45MM)
		for i in 3600:
			await process_frame
			if m.dish._state != null and m.dish.row >= 0:
				break
	if gate_ab:
		count = 1 if scenario == "A" else 7
		_fill(m.dish, m, big_bups, _perf.DISH_90MM)
		for i in 3600:
			await process_frame
			if m.dish._state != null and m.dish.row >= 0:
				break
		var small := StartConditions.new()
		small.bups = 4
		small.bup_limit = 12000
		small.dish_radius = _perf.DISH_45MM
		small.nutrient_density = StartConditions.MAX_NUTRIENT_DENSITY
		small.feed_density = StartConditions.MAX_FEED_DENSITY
		small.tutorial = false
		small.spread_founders()
		while m.dishes.size() < count:
			var d: Dish = m.add_dish(small)
			if d == null:
				break
			for i in 3600:
				if d.row >= 0:
					break
				await process_frame
			_fill(d, m, 12000, _perf.DISH_45MM)
	while m.dishes.size() < count:
		if m.add_dish(start) == null:
			break
		if m.dishes.size() % 50 == 0:
			await process_frame
	print("IFACE %d dishes asked for in %d ms" % [m.dishes.size(), Time.get_ticks_msec() - t0])
	while Time.get_ticks_msec() - t0 < WAIT_MSEC and WorldClient.shared().latest().dishes.size() < m.dishes.size():
		await process_frame
	var in_world := WorldClient.shared().latest().dishes.size()
	print("IFACE every dish in the world after %.1f s (%d of %d)" % [(Time.get_ticks_msec() - t0) / 1000.0, in_world, m.dishes.size()])
	var settle_end := Time.get_ticks_msec() + int(SETTLE_SECONDS * 1000.0)
	var last := Time.get_ticks_usec()
	while Time.get_ticks_msec() < settle_end:
		await process_frame
		last = Time.get_ticks_usec()
	var frames: Array = []
	var steps_ms: Array = []  ## gate E: the sim's step time (its moving average) and iteration time, sampled each frame
	var iter_ms: Array = []
	var pop_start: int = m.dish.population()
	var size_start := DisplayServer.window_get_size()
	var hover_frames := 0
	var clock0: float = WorldClient.shared().latest().sim_time
	var wall0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - wall0) / 1e6 < window:
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
		if m.dish.hovered.bup >= 0:
			hover_frames += 1
		if gate_e:
			var timing: Dictionary = WorldClient.shared().latest().timing
			steps_ms.append(float(timing.get("step_ms_ema", 0.0)))
			iter_ms.append(float(timing.get("iteration_ms", 0.0)))
	var wall := (Time.get_ticks_usec() - wall0) / 1e6
	var size_end := DisplayServer.window_get_size()
	TestUtil.show(size_start == WINDOW_SIZE and size_end == WINDOW_SIZE, "the run is the baseline's scene: the window %d x %d throughout (%s at the start of the frames, %s at the end)" % [WINDOW_SIZE.x, WINDOW_SIZE.y, size_start, size_end])
	TestUtil.show(hover_frames == 0, "the run is the baseline's scene: the pointer over no bup (%d frames with one hovered)" % hover_frames)
	var reached := (float(WorldClient.shared().latest().sim_time) - clock0) / wall
	var sorted := frames.duplicate()
	sorted.sort()
	var mean := 0.0
	for f: float in sorted:
		mean += f
	mean /= sorted.size()
	var p95: float = sorted[mini(sorted.size() - 1, int(0.95 * sorted.size()))]
	var p50: float = sorted[sorted.size() / 2]
	var worst: float = sorted[-1]
	var hz := DisplayServer.screen_get_refresh_rate()
	var display_ms: float = 1000.0 / hz if hz > 0.0 else float(_perf.DISPLAY_FRAME_MS)
	print("IFACE [measured] %d dishes running (%d in the snapshot), %d frames over %.1f s: mean %.2f ms, p50 %.2f, p95 %.2f, worst %.2f; speed reached x%.0f (asked x10,000); display %.1f Hz (%.3f ms)" % [m.dishes.size(), in_world, frames.size(), wall, mean, p50, p95, worst, reached, hz, display_ms])
	if gate_ab:
		var base_speed_ab := float(_perf.lookup(baseline, ["scenarios", scenario, "achieved_speed_mean_of_runs"]))
		print("IFACE %s [measured] p95 %.2f ms, mean %.2f, p50 %.2f, worst %.2f, speed x%.0f, population %d at the start of the window and %d at the end" % [scenario, p95, mean, p50, worst, reached, pop_start, m.dish.population()])
		print("IFACE %s baseline [measured]: p95 %.2f ms, mean %.2f, worst %.2f, speed x%.0f" % [scenario, base_p95, base_mean, base_max, base_speed_ab])
		var status_ab: Dictionary = WorldClient.shared().backend.status()
		TestUtil.show(in_world >= m.dishes.size() and m.dishes.size() >= count, "gate %s: %d dishes running in the world (%d asked)" % [scenario, in_world, count])
		TestUtil.show((status_ab.get("errors", []) as Array).is_empty() and status_ab.get("alive", false), "gate %s: the world is clean (%s)" % [scenario, status_ab])
		TestUtil.show(_perf.gate_ab(p95, base_p95), "gate %s: p95 %.2f ms <= the baseline's %.2f ms (speed x%.0f against x%.0f)" % [scenario, p95, base_p95, reached, base_speed_ab])
		TestUtil.finish(self, "OK interface_gate %s (p95 %.2f ms, mean %.2f ms, worst %.2f ms, x%.0f reached)" % [scenario, p95, mean, worst, reached])
		return
	if gate_e:
		steps_ms.sort()
		iter_ms.sort()
		print("IFACE E the simulation's own times [measured]: step median %.2f ms (p95 %.2f), iteration median %.2f ms (p95 %.2f, worst %.2f)" % [steps_ms[steps_ms.size() / 2], steps_ms[int(0.95 * steps_ms.size())], iter_ms[iter_ms.size() / 2], iter_ms[int(0.95 * iter_ms.size())], iter_ms[-1]])
		var base_speed := float(_perf.lookup(baseline, ["scenarios", "E", "achieved_speed_mean_of_runs"]))
		print("IFACE E [measured] p95 %.2f ms, mean %.2f, p50 %.2f, worst %.2f, speed x%.0f, population %d at the start of the window and %d at the end" % [p95, mean, p50, worst, reached, pop_start, m.dish.population()])
		print("IFACE E baseline (bench_scenarios world E 30) [measured]: p95 %.2f ms, mean %.2f, worst %.2f, speed x%.0f; cap min(%.2f, %.2f x %.3f = %.2f) ms, speed >= x%.0f" % [base_p95, base_mean, base_max, base_speed, base_p95, _perf.E_FRAME_SHARE, _perf.DISPLAY_FRAME_MS, _perf.E_FRAME_SHARE * _perf.DISPLAY_FRAME_MS, _perf.E_SPEED_FLOOR])
		var status_e: Dictionary = WorldClient.shared().backend.status()
		TestUtil.show((status_e.get("errors", []) as Array).is_empty() and status_e.get("alive", false), "gate E: the world is clean (%s)" % [status_e])
		TestUtil.show(_perf.gate_e(p95, reached, base_p95), "gate E: p95 %.2f ms <= min(%.2f, %.2f) and speed x%.0f >= x%.0f" % [p95, base_p95, _perf.E_FRAME_SHARE * _perf.DISPLAY_FRAME_MS, reached, _perf.E_SPEED_FLOOR])
		TestUtil.finish(self, "OK interface_gate E (p95 %.2f ms, mean %.2f ms, worst %.2f ms, x%.0f reached)" % [p95, mean, worst, reached])
		return
	print("IFACE baseline (20 dishes, %s, 2560 x 1440): mean %.2f ms, p95 %.2f, worst %.2f [measured]; this run's bound: p95 <= %.2f ms, mean <= %.2f ms" % [BASELINE_KEY, base_mean, base_p95, base_max, base_p95, base_mean])
	var status: Dictionary = WorldClient.shared().backend.status()
	TestUtil.show(in_world >= m.dishes.size() and m.dishes.size() >= count, "interface gate: %d dishes running in the world (%d asked)" % [in_world, count])
	TestUtil.show((status.get("errors", []) as Array).is_empty() and status.get("alive", false), "interface gate: the world is clean (%s)" % [status])
	TestUtil.show(_perf.gate_interface(p95, mean, base_p95, base_mean), "interface gate: p95 %.2f ms <= the 20-dish baseline's %.2f and mean %.2f ms <= %.2f" % [p95, base_p95, mean, base_mean])
	TestUtil.finish(self, "OK interface_gate (%d dishes: p95 %.2f ms, mean %.2f ms, worst %.2f ms, x%.0f reached)" % [m.dishes.size(), p95, mean, worst, reached])


## Gate E's, A's and B's dish: a dish put in the world again as perf_gates_test.filled_spec (`n` bups at once) the way Dish.strike
## puts one there, but with the founders' records of the spec (StartConditions.bups stops at 250).
func _fill(d: Dish, m: Node, n: int, radius: float) -> void:
	var spec: DishSpec = _perf.filled_spec(n, radius, d.number)
	d._leave_world()
	d.radius = spec.radius
	d.resolution = spec.resolution
	d.bup_limit = spec.limit
	d.feed_density = spec.feed_density
	d.bloom_density = spec.bloom_density
	d.upkeep_factor = spec.upkeep
	d.medium_thickness = spec.medium_thickness
	d.patch_seed = spec.patch_seed
	d._reset_runtime_state()
	spec.flags = d._flags()
	d.row = WorldClient.shared().add_dish(spec)
	d.begin_at(WorldClient.shared().latest().sim_time)
	m._asked_rows[d.row] = d
