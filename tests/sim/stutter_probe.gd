extends SceneTree
## Measurement probe: the game screen with `dishes=` dishes of 90 mm each put in the world filled to `bups=` bups at once (the main one
## and the others; bloom 1, husks and starvation on as the defaults have them), asked x10,000, `settle=` s, then `seconds=` s of frames.
## Prints the frames (late: over 1.5 display frames, as the F3 overlay counts; p50, p95, p99, worst), the slide (stalls and jumps of the
## drawn simulated time, as slide_test's M), the speed reached, and the simulation's iterations (their time, the time in submits and the
## longest single submit, `submit_ms_most`; the three longest iterations' timing in full), and the main thread's process step (the time from `process_frame` to the end of the last
## node's `_process`) with how many late frames had a long one, and how long a look-up in the family tree takes on the main thread
## (`Dish.has_record`, as the info panel and the hover card make every frame for the bup selected or under the pointer). `still=1` keeps the share at 1 (no drawing between pictures), `paused=1`
## pauses the game for the window (the screen alone), `speed=` asks another speed, each a diagnosis. Run windowed, e.g.:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 --windowed --resolution 1600x1000 -s tests/sim/stutter_probe.gd -- dishes=2

var _perf := load("res://tests/sim/perf_gates_test.gd")
var _process_start := 0
var _last_process_ms := 0.0
var _bloom := 1.0
var _marks := {}  ## mark name -> ms since process_frame, this frame


## Stamps the end of each frame's process step (it runs after every other node's `_process`).
class EndStamp:
	extends Node
	var probe: Object
	func _process(_delta: float) -> void:
		probe._last_process_ms = (Time.get_ticks_usec() - probe._process_start) / 1000.0


## Stamps a point within the process step (where it sits in the tree): the time since `process_frame`, by its name.
class Mark:
	extends Node
	var probe: Object
	func _process(_delta: float) -> void:
		probe._marks[name] = (Time.get_ticks_usec() - probe._process_start) / 1000.0


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
	var dump := ""
	var owner := false  ## the game screen as a played one has it: the overlay on, the layers hidden but the bups, the tray as played, bloom 2
	var grow := false  ## the dishes grow from their founders instead of being filled at once
	var bloom := 1.0
	var full := false  ## switch the window to full screen once the game's hold on a script's window has ended
	var pip := false  ## one dish grown, the others made from it with the pipette (as played), measured at each count in `counts`
	var circle := 20000.0  ## the pipette's circle radius (um)
	var counts: Array = [2, 3, 4]
	var growmax := 600.0  ## the most seconds to wait for a dish to grow to its limit
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
		elif a.begins_with("dump="):
			dump = a.substr(5)
		elif a == "owner=1":
			owner = true
			bloom = 2.0
		elif a == "grow=1":
			grow = true
		elif a == "full=1":
			full = true
		elif a == "pip=1":
			pip = true
			grow = true
			owner = true
			bloom = 2.0
		elif a.begins_with("circle="):
			circle = float(a.substr(7)) * 1000.0
		elif a.begins_with("counts="):
			counts = Array(a.substr(7).split(",")).map(func(x: String) -> int: return int(x))
		elif a.begins_with("growmax="):
			growmax = float(a.substr(8))
		elif a.begins_with("bloom="):
			bloom = float(a.substr(6))
	var start := StartConditions.new()
	start.bups = 4
	start.bup_limit = bups
	start.dish_radius = _perf.DISH_90MM
	_bloom = bloom
	start.bloom_density = bloom
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
	if not grow:
		_fill(main_dish, m, bups)
	for k in (0 if pip else dishes - 1):
		var d: Dish = m.add_dish(start)
		for i in 3600:
			if d != null and d.row >= 0:
				break
			await process_frame
		if d != null and not grow:
			_fill(d, m, bups)
	m.set_main_dish(main_dish)
	if owner:
		m.timing_overlay.visible = true
		for layer: int in [Dish.Layer.MEDIUM, Dish.Layer.SOURCES, Dish.Layer.PLANKTON, Dish.Layer.STEERING, Dish.Layer.HUSKS]:
			for d: Dish in m.dishes:
				d.show_layer(layer, false)
		m.graph_section.open = true
		m.inspector.dish_card.open = true
		m.dish_details.open = false
		m.all_details.open = false
	var w := WorldClient.shared()
	if full:
		while Time.get_ticks_msec() < 13000:
			await process_frame
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		for i in 60:
			await process_frame
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
	var service := root.get_node("SimService")
	for at: Array in [["after_poll", root, service.get_index() + 1], ["before_main", root, m.get_index()], ["after_main_own", m, 0]]:
		var mk := Mark.new()
		mk.name = at[0]
		mk.probe = self
		(at[1] as Node).add_child(mk)
		(at[1] as Node).move_child(mk, at[2])
	if full:
		print("STUTTER window mode %d size %s" % [DisplayServer.window_get_mode(), str(root.get_window().size)])
	if not pip:
		await _measure(m, w, main_dish, seconds, "fixed", dump, bups, still)
		quit()
		return
	await _pipette_run(m, w, main_dish, seconds, dump, bups, still, circle, counts, growmax)
	quit()


## Measures `seconds` of frames (printed with `tag`); the marks and the end stamp are set up before.
func _measure(m: Node, w: WorldClient, main_dish: Dish, seconds: float, tag: String, dump: String, bups: int, still: bool) -> void:
	var vp := root.get_viewport_rid()
	var segs: Array = []
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var iter_at: Array = []  ## the newest iteration's number each frame
	var gpus: Array = []  ## the root viewport's measured GPU render time each frame (ms)
	var cpus: Array = []  ## its measured CPU render time
	print("STUTTER window %s screen %s refresh %.1f Hz vsync %d driver %s" % [str(root.get_window().size), str(DisplayServer.screen_get_size(root.get_window().current_screen)), DisplayServer.screen_get_refresh_rate(root.get_window().current_screen), DisplayServer.window_get_vsync_mode(), RenderingServer.get_current_rendering_driver_name()])
	var looks: Array = []  ## ms a family-tree look-up (Dish.has_record of a living bup) took each frame
	var ids_now := main_dish.bup_ids()
	var look_id: int = ids_now[ids_now.size() / 2] if not ids_now.is_empty() else -1
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
		gpus.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
		cpus.append(RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu())
		var a: float = _marks.get("after_poll", 0.0)
		var b: float = _marks.get("before_main", a)
		var c: float = _marks.get("after_main_own", b)
		segs.append([a, b - a, c - b, _last_process_ms - c])
		if look_id >= 0:
			var tl := Time.get_ticks_usec()
			main_dish.has_record(look_id)
			looks.append((Time.get_ticks_usec() - tl) / 1000.0)
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
		iter_at.append(n)
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
	print("STUTTER %s dishes=%d bups=%d still=%s display %.2f ms: %d frames, late %d (%.3f), p50 %.2f p95 %.2f p99 %.2f worst %.2f ms; stalls %d, jumps %d; speed x%.0f; pops %s" % [tag, m.dishes.size(), bups, still, display_ms, frames.size(), late, float(late) / maxf(frames.size(), 1), _q(sorted, 0.5), _q(sorted, 0.95), _q(sorted, 0.99), sorted[-1] if not sorted.is_empty() else 0.0, stalls, jumps, reached, str(m.dishes.map(func(d: Dish) -> int: return d.population()))])
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
	var names := ["poll and snapshot", "other autoloads", "Main's own _process", "Main's children (dishes, interface)"]
	for j in 4:
		var col: Array = segs.map(func(x: Array) -> float: return x[j])
		var late_col: Array = []
		for i in range(1, frames.size()):
			if frames[i] > 1.5 * display_ms:
				late_col.append(maxf(segs[i][j], segs[i + 1][j] if i + 1 < segs.size() else 0.0))
		col.sort()
		late_col.sort()
		print("STUTTER process part %-38s p50 %.2f p95 %.2f p99 %.2f ms; in late frames p50 %.2f max %.2f ms" % [names[j], _q(col, 0.5), _q(col, 0.95), _q(col, 0.99), _q(late_col, 0.5), late_col[-1] if not late_col.is_empty() else 0.0])
	looks.sort()
	print("STUTTER family-tree look-up on the main thread (Dish.has_record) p50 %.3f p95 %.3f p99 %.3f max %.3f ms over %d frames" % [_q(looks, 0.5), _q(looks, 0.95), _q(looks, 0.99), looks[-1] if not looks.is_empty() else 0.0, looks.size()])
	var late_proc := 0
	var late_all := 0
	var proc_sorted := procs.duplicate()
	proc_sorted.sort()
	for i in range(1, frames.size()):
		if frames[i] > 1.5 * display_ms:
			late_all += 1
			if procs[i] > display_ms or (i + 1 < procs.size() and procs[i + 1] > display_ms):
				late_proc += 1
	if dump != "":  # one line a frame: its time, the process step in it, the viewport's GPU time, the newest iteration's number then
		var f := FileAccess.open(dump + "_" + tag, FileAccess.WRITE)
		for i in frames.size():
			f.store_line("%.3f %.3f %.3f %d" % [frames[i], procs[i], gpus[i], iter_at[i]])
		f.close()
	var bins := [0, 0, 0, 0, 0]
	for fr: float in frames:
		bins[0 if fr < 1.5 * display_ms else (1 if fr < 2.5 * display_ms else (2 if fr < 3.5 * display_ms else (3 if fr < 5.5 * display_ms else 4)))] += 1
	print("STUTTER frames by display frames: under 1.5 %d, 1.5-2.5 %d, 2.5-3.5 %d, 3.5-5.5 %d, over 5.5 %d" % bins)
	var rest: Array = []  ## each frame's time outside the process step (drawing, the wait for the card and the display)
	var rest_late: Array = []
	var gpu_late: Array = []
	for i in frames.size():
		rest.append(frames[i] - procs[i])
		if frames[i] > 1.5 * display_ms:
			rest_late.append(frames[i] - procs[i])
			gpu_late.append(gpus[i])
	for col: Array in [rest, rest_late, gpus, gpu_late, cpus]:
		col.sort()
	print("STUTTER outside the process step p50 %.2f p95 %.2f p99 %.2f ms, in late frames p50 %.2f max %.2f ms; viewport GPU p50 %.2f p95 %.2f p99 %.2f max %.2f ms, in late frames p50 %.2f; viewport CPU p50 %.2f p95 %.2f ms" % [_q(rest, 0.5), _q(rest, 0.95), _q(rest, 0.99), _q(rest_late, 0.5), rest_late[-1] if not rest_late.is_empty() else 0.0, _q(gpus, 0.5), _q(gpus, 0.95), _q(gpus, 0.99), gpus[-1] if not gpus.is_empty() else 0.0, _q(gpu_late, 0.5), _q(cpus, 0.5), _q(cpus, 0.95)])
	var tm: Dictionary = w.latest().timing
	print("STUTTER pool in use %s; dish husks %s; step_cost_ms %.1f" % [str(tm.get("pool_in_use", {})), str(m.dishes.map(func(d: Dish) -> int: return d.husk_count())), float(tm.get("step_cost_ms", 0.0))])
	print("STUTTER main thread process time p50 %.2f p95 %.2f p99 %.2f max %.2f ms; late frames whose process time (that frame's or the next's) passed a display frame: %d of %d" % [_q(proc_sorted, 0.5), _q(proc_sorted, 0.95), _q(proc_sorted, 0.99), proc_sorted[-1] if not proc_sorted.is_empty() else 0.0, late_proc, late_all])



## The owner's way: the first dish grows to its limit, then each further dish is a pipette's circle from it (kept), grown to its limit in turn; the
## frames are measured at each dish count in `counts`, and the card's usage and the pool are printed at each.
func _pipette_run(m: Node, w: WorldClient, first: Dish, seconds: float, dump: String, bups: int, still: bool, circle: float, counts: Array, growmax: float) -> void:
	var count_max: int = counts.max()
	await _grow(m, first, growmax)
	for count in range(2, count_max + 1):
		m.set_main_dish(first)
		for i in 30:
			await process_frame
		var before: int = m.dishes.size()
		m.pipette(Vector2.ZERO, circle)
		var waited := 0
		while m.dishes.size() == before and waited < 1800:
			await process_frame
			waited += 1
		for i in 10:
			await process_frame
		if m._old_dish != null:
			m._answer_old_dish("keep")
		if m.dishes.size() == before:
			print("STUTTER pipette made no dish at count %d" % count)
			return
		var made: Dish = m.dishes[-1]
		print("STUTTER count %d: pipette moved into dish %d; it starts with %d bups" % [count, made.number, made.population()])
		await _grow(m, made, growmax)
		m.set_main_dish(first)
		m.sim_speed = 10000.0
		if m.paused:
			m._set_paused(false)
		for i in 120:
			await process_frame
		if counts.has(count):
			_report_memory(w, "count %d before" % count)
			await _measure(m, w, first, seconds, "n%d" % count, dump, bups, still)
			_report_memory(w, "count %d after" % count)


## Waits until the dish holds its limit (or `limit` seconds have gone), keeping the game running at the asked speed.
func _grow(m: Node, d: Dish, limit: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < limit * 1000.0:
		await process_frame
		if m.paused and m._old_dish == null:
			m.toolbar.set_paused(false)
			m._set_paused(false)
		m.sim_speed = 10000.0
		if d.population() >= int(d.bup_limit * 0.97):
			break
	print("STUTTER dish %d grown to %d of %d in %.0f s" % [d.number, d.population(), d.bup_limit, (Time.get_ticks_msec() - t0) / 1000.0])


func _report_memory(w: WorldClient, tag: String) -> void:
	var tm: Dictionary = w.latest().timing
	var mc: Dictionary = (tm.get("machine", {}) as Dictionary).get("machine", {})
	print("STUTTER memory %s: pool held fraction %.2f need %.2f; card usage %.2f of budget %.2f GB; pool bytes %.2f GB; in use %s" % [tag, float(tm.get("memory_fraction", 0.0)), float(tm.get("memory_need_fraction", 0.0)), float(mc.get("card_usage", 0)) / 1e9, float(mc.get("card_budget", 0)) / 1e9, float((tm.get("pool", {}) as Dictionary).get("bytes", 0)) / 1e9, str(tm.get("pool_in_use", {}))])


static func _q(sorted: Array, q: float) -> float:
	return sorted[mini(int(q * sorted.size()), sorted.size() - 1)] if not sorted.is_empty() else 0.0


## A dish put in the world again as perf_gates_test.filled_spec (`n` bups at once), as interface_gate does for gate A, with bloom 1.
func _fill(d: Dish, m: Node, n: int) -> void:
	var spec: DishSpec = _perf.filled_spec(n, _perf.DISH_90MM, d.number)
	spec.bloom_density = _bloom
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
