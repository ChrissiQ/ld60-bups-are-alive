extends SceneTree
## The interface at 1,000 dishes: the game screen on the real pool with every dish it allows running (Main.MAX_DISHES,
## 999: an interface choice, not the world's 1,024 rows), the dish strip and the sections showing them, measured as the 20-dish
## C scenarios (bench_scenarios.gd of the replaced CPU simulation: the game screen, the dishes filled at once, an asked x10,000, 12 s of settling, then
## 30 s of frames between process_frame calls at 2560 x 1440 windowed). Run windowed; it is not a `*_test.gd`, so tools/run_sim_tests.sh skips it:
## tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 --windowed --resolution 2560x1440 -s tests/sim/interface_gate.gd
## Args (after --): `dishes=N` (default 999), `seconds=N` (the window, default 30).
##
## Expected values, written before the first run:
## - The bound is `gate_interface` of perf_gates_test.gd: p95 <= min(1.15 x the display frame [placeholder], the 20-dish baseline's p95) and the
##   mean no worse than the baseline's. The 20-dish baseline is scenario C48 (the same 48 x 48 grids; perf_pre_pool.json: mean 9.31 ms, p95 10.33,
##   max 14.48), so on a 120 Hz display (8.333 ms) the 9.58 ms cap binds on p95 and 9.31 ms on the mean. This screen's frames at 994 dishes
##   were p50 8.34, p95 8.96-9.10, worst 11.1-11.35 ms [measured, asked x100]; at x10,000 asked the main thread's part is the same
##   (the sim is on its own thread), so p95 about 9 ms is expected [derived]: inside both bounds when the display runs at 120 Hz.
## - The dishes are 300 um with 100 bups at their limit (gate C's dishes). The speed reached is printed (gate C's own figure is perf_gates_test's).

const BASELINE_KEY := "C48"
const SETTLE_SECONDS := 12.0
const WINDOW_SECONDS := 30.0
const WAIT_MSEC := 900000

var _perf := load("res://tests/sim/perf_gates_test.gd")


func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var count: int = 999  # Main.MAX_DISHES, read from the screen below
	var window := WINDOW_SECONDS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("dishes="):
			count = int(a.substr(7))
		if a.begins_with("seconds="):
			window = float(a.substr(8))
	var baseline: Dictionary = _perf.load_baseline()
	var base_p95 := float(_perf.lookup(baseline, ["scenarios", BASELINE_KEY, "frame_ms_p95_mean_of_runs"]))
	var base_mean := float(_perf.lookup(baseline, ["scenarios", BASELINE_KEY, "frame_ms_mean_of_runs"]))
	var base_max := float(_perf.lookup(baseline, ["scenarios", BASELINE_KEY, "frame_ms_max_of_runs"]))
	TestUtil.show(base_p95 > 0.0 and base_mean > 0.0, "the baseline has %s's p95 and mean" % BASELINE_KEY)
	if not SimHarness.device_available():
		TestUtil.finish(self, "OK interface_gate (skipped: headless, no GPU)")
		return
	var start := StartConditions.new()
	start.bups = 100
	start.bup_limit = 100
	start.dish_radius = 300.0
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
	var clock0: float = WorldClient.shared().latest().sim_time
	var wall0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - wall0) / 1e6 < window:
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
	var wall := (Time.get_ticks_usec() - wall0) / 1e6
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
	print("IFACE [measured] %d dishes running (%d in the snapshot), %d frames over %.1f s: mean %.2f ms, p50 %.2f, p95 %.2f, worst %.2f; speed reached x%.0f (asked x10,000); display %.1f Hz (%.3f ms; cap 1.15 x 8.333 = %.2f ms)" % [m.dishes.size(), in_world, frames.size(), wall, mean, p50, p95, worst, reached, hz, display_ms, 1.15 * _perf.DISPLAY_FRAME_MS])
	print("IFACE baseline (20 dishes, %s, 2560 x 1440): mean %.2f ms, p95 %.2f, worst %.2f [measured]; this run's bound: p95 <= %.2f ms, mean <= %.2f ms" % [BASELINE_KEY, base_mean, base_p95, base_max, minf(1.15 * display_ms, base_p95), base_mean])
	var status: Dictionary = WorldClient.shared().backend.status()
	TestUtil.show(in_world >= m.dishes.size() and m.dishes.size() >= count, "interface gate: %d dishes running in the world (%d asked)" % [in_world, count])
	TestUtil.show((status.get("errors", []) as Array).is_empty() and status.get("alive", false), "interface gate: the world is clean (%s)" % [status])
	TestUtil.show(_perf.gate_interface(p95, mean, display_ms, base_p95, base_mean), "interface gate: p95 %.2f ms <= min(1.15 x %.3f = %.2f [placeholder], baseline %.2f) and mean %.2f ms <= %.2f" % [p95, display_ms, 1.15 * display_ms, base_p95, mean, base_mean])
	TestUtil.finish(self, "OK interface_gate (%d dishes: p95 %.2f ms, mean %.2f ms, worst %.2f ms, x%.0f reached)" % [m.dishes.size(), p95, mean, worst, reached])
