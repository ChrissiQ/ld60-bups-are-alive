extends SceneTree
## Measurement probe: the game screen with `dishes=` dishes of 90 mm each put in the world filled to `bups=` bups at once (the main one
## and the others; bloom 1, husks and starvation on as the defaults have them), asked x10,000, `settle=` s, then `seconds=` s of frames.
## Prints the frames (late: over 1.5 display frames, as the F3 overlay counts; p50, p95, p99, worst), the slide (stalls and jumps of the
## drawn simulated time, as slide_test's M), the speed reached, and the simulation's iterations (their time, the time in submits and the
## longest single submit, `submit_ms_most`; the three longest iterations' timing in full), and the main thread's process step (the time from `process_frame` to the end of the last
## node's `_process`) with how many late frames had a long one. `still=1` keeps the share at 1 (no drawing between pictures), `paused=1`
## pauses the game for the window (the screen alone), `speed=` asks another speed, each a diagnosis. Run windowed, e.g.:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 --windowed --resolution 1600x1000 -s tests/sim/stutter_probe.gd -- dishes=2

var _perf := load("res://tests/sim/perf_gates_test.gd")
var _process_start := 0
var _last_process_ms := 0.0


## Stamps the end of each frame's process step (it runs after every other node's `_process`).
class EndStamp:
	extends Node
	var probe: Object
	func _process(_delta: float) -> void:
		probe._last_process_ms = (Time.get_ticks_usec() - probe._process_start) / 1000.0


func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var dishes := 1
	var bups := 2000000
	var seconds := 30.0
	var settle := 12.0
	var still := false
	var hold := false
	var asked := 10000.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("dishes="):
			dishes = int(a.substr(7))
		elif a.begins_with("bups="):
			bups = int(a.substr(5))
		elif a.begins_with("seconds="):
			seconds = float(a.substr(8))
		elif a.begins_with("settle="):
			settle = float(a.substr(7))
		elif a == "still=1":
			still = true
		elif a.begins_with("speed="):
			asked = float(a.substr(6))
		elif a == "paused=1":
			hold = true
	var start := StartConditions.new()
	start.bups = 4
	start.bup_limit = bups
	start.dish_radius = _perf.DISH_90MM
	start.bloom_density = 1.0
	start.tutorial = false
	start.spread_founders()
	var m: Node = TestUtil.game_screen(self, start)
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
	var main_dish: Dish = m.dish
	_fill(main_dish, m, bups)
	for k in dishes - 1:
		var d: Dish = m.add_dish(start)
		for i in 3600:
			if d != null and d.row >= 0:
				break
			await process_frame
		if d != null:
			_fill(d, m, bups)
	m.set_main_dish(main_dish)
	var w := WorldClient.shared()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < settle * 1000.0:
		await process_frame
		if m.paused:
			m.toolbar.set_paused(false)
			m._set_paused(false)
			m.sim_speed = 10000.0
	m.sim_speed = asked
	if still:
		main_dish.drawing.share_override = 1.0
	if hold:
		m._set_paused(true)
		for i in 60:
			await process_frame
	var stamp := EndStamp.new()
	stamp.probe = self
	stamp.process_priority = 1 << 30
	root.add_child(stamp)
	process_frame.connect(func() -> void: _process_start = Time.get_ticks_usec())
	var display_ms: float = w.display_ms
	var frames: Array = []
	var procs: Array = []
	var speeds: Array = []
	var stalls := 0
	var last_drawn := -1.0
	var sync: Array = []
	var most: Array = []
	var timings: Array = []
	var iters: Array = []
	var seen := -1
	var clock0: float = w.latest().sim_time
	var usec := Time.get_ticks_usec()
	var wall0 := usec
	while (Time.get_ticks_usec() - wall0) / 1e6 < seconds:
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - usec) / 1000.0)
		usec = now
		procs.append(_last_process_ms)  # (the frame before this one's process step: process_frame comes first)
		var pl: WorldClient.Playout = w._playout
		var v := main_dish.drawing.view
		if v != null and pl.before >= 0.0:
			var share := main_dish.drawing.share()
			var drawn: float = pl.before + share * (v.payload().sim_time - pl.before)
			if last_drawn >= 0.0:
				var step := drawn - last_drawn
				if absf(step) < 1e-9:
					stalls += 1
				speeds.append(step / maxf(pl.last_dt, 1e-4))
			last_drawn = drawn
		var t: Dictionary = w.latest().timing
		var n := int(t.get("iterations", 0))
		if n != seen:
			seen = n
			iters.append(float(t.get("iteration_ms", 0.0)))
			timings.append(t.duplicate())
			sync.append(float(t.get("sync_ms", 0.0)))
			most.append(float(t.get("submit_ms_most", 0.0)))
	var wall := (Time.get_ticks_usec() - wall0) / 1e6
	var reached: float = (w.latest().sim_time - clock0) / wall
	var late := frames.filter(func(f: float) -> bool: return f > 1.5 * display_ms).size()
	var sorted := frames.duplicate()
	sorted.sort()
	var ss := speeds.duplicate()
	ss.sort()
	var median: float = ss[ss.size() / 2] if not ss.is_empty() else 0.0
	var jumps := speeds.filter(func(s: float) -> bool: return s > 3.0 * median).size() if median > 0.0 else 0
	print("STUTTER dishes=%d bups=%d still=%s display %.2f ms: %d frames, late %d (%.3f), p50 %.2f p95 %.2f p99 %.2f worst %.2f ms; stalls %d, jumps %d; speed x%.0f; pops %s" % [dishes, bups, still, display_ms, frames.size(), late, float(late) / maxf(frames.size(), 1), _q(sorted, 0.5), _q(sorted, 0.95), _q(sorted, 0.99), sorted[-1] if not sorted.is_empty() else 0.0, stalls, jumps, reached, str(m.dishes.map(func(d: Dish) -> int: return d.population()))])
	var a := iters.duplicate()
	a.sort()
	var b := sync.duplicate()
	b.sort()
	var c := most.duplicate()
	c.sort()
	print("STUTTER iterations %d: iteration p50 %.1f max %.1f ms; in submits p50 %.1f max %.1f ms; longest submit p50 %.1f p95 %.1f max %.1f ms" % [iters.size(), _q(a, 0.5), a[-1] if not a.is_empty() else 0.0, _q(b, 0.5), b[-1] if not b.is_empty() else 0.0, _q(c, 0.5), _q(c, 0.95), c[-1] if not c.is_empty() else 0.0])
	timings.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x.get("iteration_ms", 0.0)) > float(y.get("iteration_ms", 0.0)))
	for k in mini(3, timings.size()):
		var t: Dictionary = timings[k]
		var parts := ""
		for key: String in t:
			if t[key] is float or t[key] is int:
				parts += " %s=%.1f" % [key, float(t[key])]
		print("STUTTER longest iteration %d:%s; phases %s" % [k + 1, parts, str(t.get("ph", {}))])
	var late_proc := 0
	var late_all := 0
	var proc_sorted := procs.duplicate()
	proc_sorted.sort()
	for i in range(1, frames.size()):
		if frames[i] > 1.5 * display_ms:
			late_all += 1
			if procs[i] > display_ms or (i + 1 < procs.size() and procs[i + 1] > display_ms):
				late_proc += 1
	print("STUTTER main thread process time p50 %.2f p95 %.2f p99 %.2f max %.2f ms; late frames whose process time (that frame's or the next's) passed a display frame: %d of %d" % [_q(proc_sorted, 0.5), _q(proc_sorted, 0.95), _q(proc_sorted, 0.99), proc_sorted[-1] if not proc_sorted.is_empty() else 0.0, late_proc, late_all])
	quit()


static func _q(sorted: Array, q: float) -> float:
	return sorted[mini(int(q * sorted.size()), sorted.size() - 1)] if not sorted.is_empty() else 0.0


## A dish put in the world again as perf_gates_test.filled_spec (`n` bups at once), as interface_gate does for gate A, with bloom 1.
func _fill(d: Dish, m: Node, n: int) -> void:
	var spec: DishSpec = _perf.filled_spec(n, _perf.DISH_90MM, d.number)
	spec.bloom_density = 1.0
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
