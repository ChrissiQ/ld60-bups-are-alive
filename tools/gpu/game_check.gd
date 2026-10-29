extends SceneTree
## The GPU path as the game drives it (windowed: needs the main RenderingDevice). A real Dish in the scene tree, processing (so its
## _process draws the bups from the GPU), with a camera framing it as scripts/main.gd's _fit_camera does, advanced once a frame as
## main.gd's _process does (advance(min(delta, 0.1) x speed, DishScheduler.FRAME_BUDGET_USEC), achieved speed its running mean), hovering a
## point every frame as the select tool does. Every real transfer between the backends is checked at the moment it happens (a subclass of
## Dish wraps _load_gpu and _to_cpu_for_edit), and so is every history sample (its time).
##   godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/game_check.gd -- <mode> [args]
## Modes:
##   smoke                         a few hundred frames on the GPU (setting On), every check on
##   auto [seed] [setting]         scenario D from 250 founders at x100, x1,000, x10,000 (to 60,000 bups), x1, x10,000, x100: where the
##                                 backend runs, every switch checked; SERIES lines (each sim-hour) to compare a run with setting
##                                 "cpu" against one with "auto"
##   edits                         mid-game changes while the GPU runs (resize, limit, setting, speeds, pause, drops, eraser, sources,
##                                 bups, save and load, a new dish, picking and hovering at x10,000, the steering readout, the debug log)
##   flap [population]             Auto with the limit held near its threshold at x10,000: how often the backend changes
##   long [hours] [founders] [limit] [feed] [bloom]   scenario D at x10,000 (setting On) for `hours` sim-hours: frame times, memory
##   perf [bups] [radius] [setting] [speed] [frames] [nutrient] [feed]  a dish filled with `bups` bups at `speed`, drawing: frame times, achieved speed
##   frame [bups] [radius] [nutrient] [feed]  the GPU frame's cost beside its steps, from one to eight steps: vsync off, frame time against steps per frame (a frame inside the engine's own ~3 ms hides the GPU's work: gpufit is the check of the cost model)
##   gpufit [bups] [radius] [nutrient] [feed]  what BackendRule.GPU_STEP_MODEL and BackendRule.GPU_FRAME_USEC were fitted to: vsync off, frames of 9 to 72 steps (the GPU bounds them), their time against the steps by least squares (the frame's fixed cost and each step's), beside the model's. GAME_CHECK_DETAIL=400 for a fine grid
##   thresholds                    where Auto's rule switches (the cost model, bisected), 10 mm and 90 mm, x1,000 and x10,000
##   editcost [bups] [radius]      what one edit by hand (add_bup, remove_bup) costs while the GPU runs: time and buffer memory
## GAME_CHECK_FPS=60 caps the frame rate (Engine.max_fps), for a 60 Hz display on a faster one. GAME_CHECK_LOGS is where `edits` writes its debug log.
## Prints "GAME CHECK OK" or the failures. Every ERROR/WARNING line Godot prints is a failure too: grep the output for them.

const Tools := preload("res://tools/gpu/world_tools.gd")

const FRAME_BUDGET_USEC := DishScheduler.FRAME_BUDGET_USEC
const MAX_FRAME_SECONDS := 0.1  ## Main.MAX_FRAME_SECONDS


## The dish, with every transfer and history sample checked as it happens.
class CheckDish extends Dish:
	var qa  ## the check (its `transfer_checked`)
	var sample_times := PackedFloat64Array()  ## the sim time of each history sample, in the order recorded
	var gpu_sample_times: Array = []  ## times of the GPU's samples handed to the dish, not yet recorded
	var _cpu_sample_time := -1.0
	var transfers := 0
	var history_start := 0.0  ## the sim time the history (as sampled) starts from: a new dish's 0, a loaded one's last whole period

	func _reset_history() -> void:
		super()
		sample_times.clear()
		gpu_sample_times.clear()
		history_start = floor(time / DishHistory.INTERVAL + 1e-9) * DishHistory.INTERVAL

	func _record_history() -> void:
		_cpu_sample_time = time
		super()

	func _record_history_from(stats: Dictionary) -> void:
		var t := _cpu_sample_time
		if t < 0.0:
			t = gpu_sample_times.pop_front() if not gpu_sample_times.is_empty() else -1.0
		_cpu_sample_time = -1.0
		sample_times.append(t)
		super(stats)

	func _load_gpu() -> void:
		var before: Dictionary = qa.cpu_side(self)
		super()
		transfers += 1
		qa.transfer_checked("to the GPU", before, qa.gpu_side(self), self)

	func _to_cpu_for_edit() -> void:
		var moving := gpu_world != null and gpu_active and not _gpu_on_cpu
		var before: Dictionary = qa.gpu_side(self) if moving else {}
		super()
		if moving:
			transfers += 1
			qa.transfer_checked("to the CPU", before, qa.cpu_side(self), self)


## The dish's GpuWorld, made here so the history samples' times can be followed.
class CheckWorld extends GpuWorld:
	var dish: CheckDish

	func take_history_samples() -> Array:
		var out := super()
		for s: Dictionary in out:
			dish.gpu_sample_times.append(s["time"])
		return out


var dish: CheckDish
var camera: Camera2D
var _checks := 0
var _fails := 0
var achieved := 1.0
var _last_usec := 0
var frame_ms := PackedFloat64Array()
var advance_ms := PackedFloat64Array()
var frames_run := 0
var switches := []  ## [frame, from, to, population, sim hours, speed]
var _last_backend := "cpu"
var speed := 1.0
var rule_seen := ""  ## what Auto's rule was given at the last advance (as _choose_backend works it out)
var held := false  ## paused (main.gd's `paused`)
var hover_world := Vector2.ZERO
var watch := {}  ## per-frame continuity: last values
var glitches := {}  ## what jumped, counted
var quiet_until := 0  ## jumps before this frame are an edit's own (a load, a new dish), not glitches
var selected_at := 0  ## the frame the harness last chose a bup to select (by id, as the watch list does)
var _died_lag := 0  ## frames a selected bup that died on the GPU was still alive in its record (its last place shown)
var _glitch_late := 0  ## frames a bup chosen by id had no record yet (its first readback is on its way)


func _ok(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	TestUtil.show(ok, what)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var mode: String = a[0] if a.size() > 0 else "smoke"
	SimConstants.apply()
	if OS.get_environment("GAME_CHECK_FPS") != "":
		Engine.max_fps = int(OS.get_environment("GAME_CHECK_FPS"))  # (a 60 Hz display on a 120 Hz one: GpuWorld's budget takes its frame from this)
	print("refresh rate %.1f Hz, max_fps %d, vsync %d, device %s, GpuWorld.available %s, most_bups %d" % [DisplayServer.screen_get_refresh_rate(), Engine.max_fps, DisplayServer.window_get_vsync_mode(), RenderingServer.get_rendering_device().get_device_name() if RenderingServer.get_rendering_device() != null else "none", GpuWorld.available(), GpuWorld.most_bups()])
	match mode:
		"smoke":
			await _smoke()
		"auto":
			await _auto(int(a[1]) if a.size() > 1 else 1, a[2] if a.size() > 2 else StartConditions.BACKEND_AUTO)
		"edits":
			await _edits()
		"flap":
			await _flap(int(a[1]) if a.size() > 1 else 0)
		"long":
			await _long(float(a[1]) if a.size() > 1 else 60.0, int(a[2]) if a.size() > 2 else 250, int(a[3]) if a.size() > 3 else 100000, float(a[4]) if a.size() > 4 else 0.0, float(a[5]) if a.size() > 5 else 2.0)
		"perf":
			await _perf(int(a[1]) if a.size() > 1 else 100000, float(a[2]) if a.size() > 2 else 90000.0, a[3] if a.size() > 3 else StartConditions.BACKEND_GPU, float(a[4]) if a.size() > 4 else 10000.0, int(a[5]) if a.size() > 5 else 600, float(a[6]) if a.size() > 6 else 32.0, float(a[7]) if a.size() > 7 else 3.0)
		"frame":
			await _frame_cost(int(a[1]) if a.size() > 1 else 100000, float(a[2]) if a.size() > 2 else 90000.0, float(a[3]) if a.size() > 3 else 32.0, float(a[4]) if a.size() > 4 else 3.0)
		"gpufit":
			await _gpu_fit(int(a[1]) if a.size() > 1 else 10000, float(a[2]) if a.size() > 2 else 90000.0, float(a[3]) if a.size() > 3 else 32.0, float(a[4]) if a.size() > 4 else 3.0)
		"thresholds":
			_thresholds()
		"editcost":
			await _edit_cost(int(a[1]) if a.size() > 1 else 100000, float(a[2]) if a.size() > 2 else 90000.0)
	await _finish()


func _finish() -> void:
	if dish != null:
		var world := dish.gpu_world  # (kept until the readbacks still on their way and the end-of-frame flushes have run on a live device)
		dish.queue_free()
		for i in 4:
			await process_frame
		if world != null and world.gpu != null:
			world.reset_pipeline(0)
			RenderingServer.call_on_render_thread(world.gpu.release)
			await process_frame
	for i in 3:
		await process_frame
	print("%d checks, %d failed" % [_checks, _fails])
	TestUtil.finish(self, "GAME CHECK OK", "GAME CHECK FAILED:")


# ---- the dish and the frame -------------------------------------------------------------------------------------------------------

## Scenario D of validate_dynamics.gd (90 mm, bloom 2.0, nutrient 4, cap 100k, 250 founders).
func scenario_d(setting: String, founders := 250, limit := 100000) -> StartConditions:
	var sc := StartConditions.new()
	sc.bups = founders; sc.bup_limit = limit; sc.dish_radius = 90000.0; sc.nutrient_density = 4.0; sc.bloom_density = 2.0
	sc.sim_backend = setting
	sc.spread_founders()
	return sc


func make_dish(sc: StartConditions, seed_value: int) -> void:
	dish = CheckDish.new()
	dish.qa = self
	root.add_child(dish)
	dish.set_seed(seed_value)
	var world := CheckWorld.new(dish.sim)
	world.dish = dish
	dish.gpu_world = world  # (the dish makes one only when it has none)
	dish.strike(sc)
	if camera == null:
		camera = Camera2D.new()
		root.add_child(camera)
	fit_camera()
	_last_backend = dish.backend_running()


## Main._fit_camera.
func fit_camera() -> void:
	var view := root.get_visible_rect().size
	var room := minf(view.x * 0.5 - 40.0, view.y * 0.5 - 120.0)
	camera.zoom = Vector2.ONE * clampf(room / dish.radius, 0.002, 1.0)
	camera.position = dish.global_position
	camera.make_current()


## A dish of `n` bups spread over most of it, as switch_check.gd's bench places them (founder genomes, random reserves), with nutrient.
func filled_dish(n: int, radius: float, setting: String, limit := 0, feed := 3.0, nutrient := 32.0, seed_value := 3) -> void:
	var sc := StartConditions.new()
	sc.bups = 4
	sc.bup_limit = limit if limit > 0 else n
	sc.dish_radius = radius
	sc.nutrient_density = nutrient
	sc.feed_density = feed
	sc.sim_backend = setting
	if OS.get_environment("GAME_CHECK_DETAIL") != "":  # (GAME_CHECK_DETAIL=400: the nutrient grid's cells across)
		sc.nutrient_resolution = int(OS.get_environment("GAME_CHECK_DETAIL"))
	sc.spread_founders()
	make_dish(sc, seed_value)
	var born_with := Cell.mass_to_add(Genome.founder())
	var started := Time.get_ticks_msec()
	for i in n - 4:
		var grown := born_with * (1.0 + dish.sim.random_float())
		dish.sim.add_bup(dish.sim.random_point(radius * 0.95), Genome.founder(), Dish.FOUNDER_ENERGY * dish.sim.random_float(), sqrt(grown), born_with, 0, Vector2.RIGHT)
	print("filled: %d bups on a %.0f mm dish in %d ms" % [dish.sim.bup_count(), radius / 1000.0, Time.get_ticks_msec() - started])


## One frame as main.gd's _process makes it: advance (unless paused), the hover of the select tool, then the frame.
func frame() -> void:
	var now := Time.get_ticks_usec()
	var delta := (now - _last_usec) / 1e6 if _last_usec > 0 else 1.0 / 60.0
	_last_usec = now
	if frames_run > 0:
		frame_ms.append(delta * 1000.0)
	if not held:
		var f := minf(delta, MAX_FRAME_SECONDS)
		var steps := maxi(1, ceili(f * speed / Dish.MAX_STEP))
		var step_delta := f * speed / steps
		var rule_steps := maxi(1, roundi(steps * BackendRule.RULE_FRAME_SECONDS / minf(dish.get_process_delta_time(), 0.1)))
		var c := BackendRule.frame_costs(step_delta, dish.field.get_size(), dish.sim.moves_for(step_delta), dish.population(), rule_steps, dish.field.puff_count())
		rule_seen = "frame %.1f ms, %d steps of %.1f s (%d for a 60 Hz frame), %d bups, %d clouds: model CPU %.0f GPU %.0f us/frame" % [delta * 1000.0, steps, step_delta, rule_steps, dish.population(), dish.field.puff_count(), c.x, c.y]
		var t0 := Time.get_ticks_usec()
		var done := dish.advance(f * speed, FRAME_BUDGET_USEC)
		advance_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
		if f > 0.0:
			achieved = lerpf(achieved, done / f, 0.1)
	dish.hover_at(hover_world, 4.0 * dish.pixel())  # (main.gd's PICK_SLACK_PIXELS)
	_watch_frame()
	dish.refresh_drawing()
	var running := dish.backend_running()
	if running != _last_backend:
		switches.append([frames_run, _last_backend, running, dish.population(), dish.time / 3600.0, speed])
		print("     SWITCH frame %d: %s -> %s at %d bups, %.2f sim-h, x%.0f (the rule saw: %s)" % [frames_run, _last_backend, running, dish.population(), dish.time / 3600.0, speed, rule_seen])
		_last_backend = running
	frames_run += 1
	await process_frame


func frames(count: int) -> void:
	for i in count:
		await frame()


func set_speed(value: float) -> void:
	speed = value
	achieved = value  # (main.gd's speed button does the same)


## What a frame shows that must not jump when the backend changes: the HUD's figures, the selected bup, the goal's fraction.
func _watch_frame() -> void:
	var stats := dish.population_stats()
	var pop := dish.population()
	var frac := dish.fraction_with_gene_at_least("sense", 50.0)
	var running := dish.backend_running()
	if watch.has("pop"):
		var last_pop: int = watch["pop"]
		if last_pop > 100 and (pop == 0 or absf(pop - last_pop) > 0.2 * last_pop):
			_glitch("population jumps (%d -> %d, %s)" % [last_pop, pop, running])
		var last_speed: float = watch["speed"]
		if last_speed > 0.0 and stats["count"] > 100 and absf(stats["speed"] - last_speed) > 0.1 * last_speed:
			_glitch("HUD mean speed jumps (%.2f -> %.2f, %s)" % [last_speed, stats["speed"], running])
		var last_frac: float = watch["frac"]
		if last_frac > 0.05 and frac < 0.5 * last_frac:
			_glitch("goal fraction drops (%.3f -> %.3f, %s)" % [last_frac, frac, running])
	watch["pop"] = pop
	watch["speed"] = stats["speed"] if stats["count"] > 0 else 0.0
	watch["frac"] = frac
	var id := dish.selected_id
	if id >= 0:
		if dish.has_bup(id):
			var info := dish.bup_info(id)
			var on_gpu := running == "gpu"
			if info.is_empty() and on_gpu and dish.gpu_world.knows(id):
				_died_lag += 1  # (it died on the GPU; its record says so a few frames later: its last place is kept meanwhile)
			elif info.is_empty() and frames_run - selected_at < 8:
				_glitch_late += 1  # (a bup chosen by id, never picked: its record comes with the next readbacks, as any GPU answer)
			elif info.is_empty():
				_glitch("selected bup alive but no info (shown as deceased) (%s)" % running)
			if dish._bup_shown(id) and dish.bup_world_pos(id) == dish.global_position:
				_glitch("selected bup drawn at the dish centre (%s)" % running)
			var steer := dish.bup_steering(id)
			if not (steer.z >= 0.0 and steer.z <= 1.0):
				_glitch("steering reading out of range %s" % str(steer))
		else:
			dish.selected_id = -1
	if (id < 0 or dish.selected_id < 0) and frames_run - selected_at >= 120:  # (bup_ids walks every family record on the GPU path: not every frame)
		var ids := dish.bup_ids()
		if ids.size() > 0:
			dish.selected_id = ids[ids.size() / 2]
			selected_at = frames_run


func _glitch(what: String) -> void:
	if frames_run < quiet_until:
		return
	var key := what.get_slice(" (", 0)
	glitches[key] = int(glitches.get(key, 0)) + 1
	if glitches[key] <= 3:
		print("     GLITCH frame %d: %s" % [frames_run, what])


# ---- the two sides of a transfer --------------------------------------------------------------------------------------------------

func _ids(records: PackedByteArray) -> PackedInt64Array:
	var out := PackedInt64Array()
	for i in records.size() / GpuLayout.RECORD_BYTES:
		out.append(GpuLayout.id_of(records, i))
	return out


static func _sorted(ids: PackedInt64Array) -> PackedInt64Array:
	var out := ids.duplicate()
	out.sort()
	return out


static func _unique(sorted_ids: PackedInt64Array) -> bool:
	for i in range(1, sorted_ids.size()):
		if sorted_ids[i] == sorted_ids[i - 1]:
			return false
	return true


func cpu_side(d: Dish) -> Dictionary:
	var records := d.sim.export_state_bytes()
	return {"records": records, "count": d.sim.bup_count(), "next_id": d.sim.get_next_id(), "total": d.field.total(), "alive": _sorted(d.sim.alive_ids()), "time": d.time, "samples": d.history.fine["pop"].size()}


## The GPU's state read now (stalls; on the render thread).
func gpu_side(d: Dish) -> Dictionary:
	var gpu := d.gpu_world.gpu
	var out := {}
	RenderingServer.call_on_render_thread(func() -> void:
		out["records"] = gpu.read_bups()
		out["count"] = gpu.counts()[0]
		out["next_id"] = gpu.next_id()
		out["conc"] = gpu.read_conc()
		out["puffs"] = gpu.read_puffs())
	var total := 0.0
	for v: float in out["conc"]:
		total += v
	total *= gpu.spacing * gpu.spacing
	for pf: Array in out["puffs"]:
		total += pf[2]
	out["total"] = total
	out["time"] = d.time
	return out


## Both sides of a transfer hold the same: the bups (count, ids in order, unique), the next id, the nutrient (grid and clouds), a
## living record for each bup and no other, and the history samples so far (in order, none missing or doubled).
func transfer_checked(label: String, before: Dictionary, after: Dictionary, d: CheckDish) -> void:
	var ids_before := _ids(before["records"])
	var ids_after := _ids(after["records"])
	var sorted_after := _sorted(ids_after)
	var alive := _sorted(d.sim.alive_ids())
	var rel := absf(after["total"] - before["total"]) / maxf(absf(before["total"]), 1e-30)
	var ok: bool = before["count"] == after["count"] and ids_before == ids_after and _unique(sorted_after) and after["next_id"] >= before["next_id"] and rel < 1e-6 and alive == sorted_after
	var history_ok := _history_ok(d)
	var what := "%s at %.2f sim-h: %d bups -> %d, ids same/unique %s/%s, next id %d -> %d, nutrient %.1f -> %.1f (rel %s), living records = bups %s (%d records), history %s" % [label, d.time / 3600.0, before["count"], after["count"], str(ids_before == ids_after), str(_unique(sorted_after)), before["next_id"], after["next_id"], before["total"], after["total"], String.num_scientific(rel), str(alive == sorted_after), alive.size(), "ok" if history_ok else "BAD"]
	if label == "to the GPU" and before["records"] != after["records"]:
		ok = false
		what += ", record bytes DIFFER"
	_ok(ok and history_ok, what)


## The history samples: sample k was taken at a time in [120 k, 120 k + MAX_STEP] (the first step to end past each 120 s), in order,
## and (on the CPU, where none is on its way) there are as many as 120 s periods have passed.
func _history_ok(d: CheckDish) -> bool:
	var times := d.sample_times
	var start := d.history_start
	for k in times.size():
		var due := start + (k + 1) * DishHistory.INTERVAL
		if times[k] < due - 1e-3 or times[k] > due + Dish.MAX_STEP + 1e-3:
			print("     history sample %d at %.3f s, due %.3f" % [k, times[k], due])
			return false
	var expected := int(floor((d.time - start) / DishHistory.INTERVAL + 1e-9))
	if d.backend_running() == "cpu" or d._gpu_on_cpu:
		if times.size() != expected:
			print("     history: %d samples, %d periods have passed" % [times.size(), expected])
			return false
	elif times.size() > expected or times.size() < expected - 64:
		print("     history: %d samples, %d periods have passed (GPU)" % [times.size(), expected])
		return false
	return true


# ---- smoke ------------------------------------------------------------------------------------------------------------------------

func _smoke() -> void:
	make_dish(scenario_d(StartConditions.BACKEND_GPU, 2000), 1)
	set_speed(10000.0)
	await frames(400)
	_ok(dish.backend_running() == "gpu", "smoke: setting On at x10,000 runs on the GPU (%d switches)" % switches.size())
	set_speed(1.0)
	await frames(3)
	_ok(dish.backend_running() == "gpu", "smoke: setting On, x1 stays on the GPU (fine path)")
	_report_glitches()
	_report_frames("smoke")


func _report_glitches() -> void:
	for key: String in glitches:
		print("     glitch count: %s: %d frames" % [key, glitches[key]])
	print("     frames a bup chosen by id waited for its first record: %d; frames a selected bup that had died was still alive in its record: %d" % [_glitch_late, _died_lag])
	_ok(glitches.is_empty(), "no jumps in what the screen shows (%s)" % str(glitches))


static func _pct(values: PackedFloat64Array, share: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[mini(sorted.size() - 1, int(share * sorted.size()))]


static func _mean(values: PackedFloat64Array) -> float:
	var total := 0.0
	for v in values:
		total += v
	return total / maxf(values.size(), 1)


func _report_frames(label: String) -> void:
	var w := dish.gpu_world
	print("FRAMES %s: %d frames, frame ms mean %.2f p50 %.2f p95 %.2f p99 %.2f max %.2f, advance ms mean %.3f p99 %.3f max %.2f, record_usec %d, apply ms/frame %.3f, achieved x%.0f (asked x%.0f), bups %d, %.2f sim-h" % [label, frame_ms.size(), _mean(frame_ms), _pct(frame_ms, 0.5), _pct(frame_ms, 0.95), _pct(frame_ms, 0.99), _pct(frame_ms, 1.0), _mean(advance_ms), _pct(advance_ms, 0.99), _pct(advance_ms, 1.0), w.record_usec if w != null else 0, (w.apply_usec / 1000.0 / maxf(frames_run, 1)) if w != null else 0.0, achieved, speed, dish.population(), dish.time / 3600.0])


func _reset_frame_stats() -> void:
	frame_ms.clear()
	advance_ms.clear()
	if dish.gpu_world != null:
		dish.gpu_world.apply_usec = 0


# ---- auto -------------------------------------------------------------------------------------------------------------------------

## Scenario D from 250 founders through the speeds: where the backend runs, each switch checked by the dish's own hooks.
func _auto(seed_value: int, setting: String) -> void:
	make_dish(scenario_d(setting), seed_value)
	hover_world = dish.global_position
	var next_hour := 1.0
	var plan := [[100.0, 200], [1000.0, 300], [10000.0, 6000]]
	for leg: Array in plan:
		set_speed(leg[0])
		for i in int(leg[1]):
			await frame()
			while dish.time >= next_hour * 3600.0:
				_series(next_hour)
				next_hour += 1.0
			if leg[0] == 10000.0 and dish.population() >= 60000:
				break
		print("     leg x%.0f done: %s, %d bups, %.2f sim-h, achieved x%.0f" % [leg[0], dish.backend_running(), dish.population(), dish.time / 3600.0, achieved])
		if leg[0] < 10000.0 and setting == StartConditions.BACKEND_AUTO:
			_ok(dish.backend_running() == "cpu", "Auto at x%.0f with %d bups: the CPU" % [leg[0], dish.population()])
	if setting != StartConditions.BACKEND_AUTO:
		_report_frames("auto-" + setting)
		return
	_ok(dish.backend_running() == "gpu", "Auto at x10,000 with %d bups: the GPU (switched at %s)" % [dish.population(), str(switches)])
	_ok(switches.size() == 1, "Auto at x10,000: one switch on the way up, no flapping (%d)" % switches.size())
	# the cost model at the switch
	if not switches.is_empty():
		var pop_at: int = switches[0][3]
		var moves := dish.sim.moves_for(166.67 / 9.0)
		var costs := BackendRule.frame_costs(166.67 / 9.0, dish.field.get_size(), moves, pop_at, 9, dish.field.puff_count())
		print("     cost model at the switch (%d bups, %d clouds): CPU %.0f us/frame, GPU %.0f us/frame" % [pop_at, dish.field.puff_count(), costs.x, costs.y])
	# x1 (fine steps, which the GPU runs too): Auto's rule decides as at any speed, and hands back only after AUTO_DOWN_FRAMES frames
	var before := switches.size()
	set_speed(1.0)
	for i in BackendRule.AUTO_DOWN_FRAMES - 1:
		await frame()
	_ok(dish.backend_running() == "gpu" and switches.size() == before, "x1: no hand-back before %d frames of the rule saying so" % BackendRule.AUTO_DOWN_FRAMES)
	await frames(40)
	var costs1 := BackendRule.frame_costs(0.0167, dish.field.get_size(), dish.sim.moves_for(0.0167), dish.population(), 1, dish.field.puff_count())
	print("     x1 with %d bups: the rule's costs CPU %.0f GPU %.0f us/frame; running %s" % [dish.population(), costs1.x, costs1.y, dish.backend_running()])
	set_speed(10000.0)
	await frames(BackendRule.wait_frames(1.0 / 120.0) + 2)
	_ok(dish.backend_running() == "gpu", "x10,000 again: the GPU")
	await frames(60)
	# x100: one step a frame: Auto's rule may hand back to the CPU (after AUTO_DOWN_FRAMES frames)
	set_speed(100.0)
	var down_at := -1
	for i in 60:
		await frame()
		if down_at < 0 and dish.backend_running() == "cpu":
			down_at = i + 1
	var costs100 := BackendRule.frame_costs(1.667, dish.field.get_size(), dish.sim.moves_for(1.667), dish.population(), 1, dish.field.puff_count())
	print("     x100 with %d bups: the rule's costs CPU %.0f GPU %.0f us/frame; running %s (back to the CPU at frame %d)" % [dish.population(), costs100.x, costs100.y, dish.backend_running(), down_at])
	_ok(down_at < 0 or down_at >= BackendRule.AUTO_DOWN_FRAMES, "x100: a hand-back by Auto's rule waits %d frames (it took %d)" % [BackendRule.AUTO_DOWN_FRAMES, down_at])
	# On / Off at x100
	dish.set_backend_setting(StartConditions.BACKEND_GPU)
	var up_at := -1
	for i in BackendRule.wait_frames(1.0 / 120.0) + 5:
		await frame()
		if up_at < 0 and dish.backend_running() == "gpu":
			up_at = i + 1
	_ok(dish.backend_running() == "gpu", "On at x100: the GPU (from frame %d)" % up_at)
	dish.set_backend_setting(StartConditions.BACKEND_CPU)
	await frame()
	_ok(dish.backend_running() == "cpu", "Off: the CPU at the next frame")
	set_speed(10000.0)
	await frames(100)
	_ok(dish.backend_running() == "cpu", "Off at x10,000: still the CPU")
	_ok(dish.transfers >= 2, "%d transfers checked as they happened" % dish.transfers)
	_report_glitches()
	_report_frames("auto")


## One line per sim-hour: what a CPU run and an Auto run of the same seed are compared by.
func _series(hour: float) -> void:
	var stats := dish.population_stats()
	print("SERIES h=%d backend=%s pop=%d nutrient=%.1f clouds=%d speed=%.4f sense=%.4f metabolism=%.5f size=%.4f samples=%d" % [int(hour), dish.backend_running(), dish.population(), dish.field.total(), dish.field.puff_count(), stats["speed"], stats["sense"], stats["metabolism"], stats["size"], dish.history.fine["pop"].size()])


## Auto with the population held where the rule switched (the limit set to it): over 2,400 frames at x10,000, with a hitch of 60 ms every
## 300 frames (as a switch's own transfer makes), the backend changes at most once more.
func _flap(population_wanted: int) -> void:
	make_dish(scenario_d(StartConditions.BACKEND_AUTO, 2000), 7)
	hover_world = dish.global_position
	set_speed(10000.0)
	while dish.backend_running() == "cpu" and frames_run < 4000 and (population_wanted <= 0 or dish.population() < population_wanted):
		await frame()
	var pop := dish.population()
	dish.change_limit(maxi(pop, 1000))
	print("     held at %d bups (limit %d), %d clouds, %s" % [pop, dish.bup_limit, dish.field.puff_count(), dish.backend_running()])
	var before := switches.size()
	for i in 2400:
		if i % 300 == 150:
			OS.delay_msec(60)  # (a hitch)
		await frame()
	var extra := switches.size() - before
	print("     switches while held: %d (%s)" % [extra, str(switches.slice(before))])
	_ok(extra <= 1, "Auto held at the threshold for 2,400 frames with hitches: %d switches (no flapping)" % extra)
	# A small colony on a loaded machine: the GPU's frames are short, the processor's long (each 40 ms more here, as a switch's own
	# transfer makes one): the rule must not judge the processor by the length of its own frames, or it switches every few frames.
	dish.strike(scenario_d(StartConditions.BACKEND_GPU, 1500))
	while dish.time < 2.5 * 3600.0 and frames_run < 20000:
		await frame()
	dish.change_limit(maxi(dish.population(), 1000))
	dish.set_backend_setting(StartConditions.BACKEND_AUTO)
	print("     small colony: %d bups, %d clouds, %s" % [dish.population(), dish.field.puff_count(), dish.backend_running()])
	before = switches.size()
	for i in 600:
		if dish.backend_running() == "cpu":
			OS.delay_msec(40)
		await frame()
	extra = switches.size() - before
	print("     switches: %d (%s)" % [extra, str(switches.slice(before, before + 6))])
	_ok(extra <= 1, "Auto with a small colony, the processor's frames slow: %d switches in 600 frames (no flapping)" % extra)
	_report_frames("flap")


# ---- edits ------------------------------------------------------------------------------------------------------------------------

## Drains what is in flight (stalling) and checks the GPU's bups against the CPU's records: ids unique, a living record for each bup and
## no other, the dish's count the GPU's. Returns the GPU side.
func consistent(label: String) -> Dictionary:
	var w := dish.gpu_world
	w.finish_pending()
	var g := gpu_side(dish)
	var ids := _sorted(_ids(g["records"]))
	var alive := _sorted(dish.sim.alive_ids())
	_ok(_unique(ids) and ids == alive, "%s: %d bups on the GPU, ids unique, living records = bups (%d)" % [label, ids.size(), alive.size()])
	return g


func buffer_mb() -> float:
	var rd := RenderingServer.get_rendering_device()
	return rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS) / 1048576.0


func _edits() -> void:
	var sc := scenario_d(StartConditions.BACKEND_GPU, 2000)
	make_dish(sc, 5)
	hover_world = dish.global_position
	set_speed(10000.0)
	while dish.population() < 20000 and frames_run < 3000:
		await frame()
	_ok(dish.backend_running() == "gpu", "edits: on the GPU with %d bups at %.2f sim-h" % [dish.population(), dish.time / 3600.0])
	consistent("start")

	# resize smaller, then bigger
	var t0 := Time.get_ticks_msec()
	dish.resize_to(60000.0)
	var g := gpu_side(dish)
	var inside := true
	var words: PackedFloat32Array = g["records"].to_float32_array()
	for i in g["count"]:
		inside = inside and Vector2(words[i * GpuLayout.RECORD_WORDS + 1], words[i * GpuLayout.RECORD_WORDS + 2]).length() <= 60000.0
	_ok(dish.backend_running() == "gpu" and not dish._gpu_on_cpu and is_equal_approx(dish.gpu_world.gpu.radius, 60000.0) and inside, "resize_to 60 mm on the GPU (%d ms): the GPU holds the smaller dish, %d bups, all inside" % [Time.get_ticks_msec() - t0, g["count"]])
	var plankton_inside := dish.plankton.all(func(p: Plankton) -> bool: return p.pos.length() <= 60000.0)
	_ok(plankton_inside, "...the plankton outside it went (%d left)" % dish.plankton.size())
	await frames(60)
	consistent("after 60 frames on the smaller dish")
	dish.resize_to(90000.0)
	_ok(dish.backend_running() == "gpu" and is_equal_approx(dish.gpu_world.gpu.radius, 90000.0), "resize_to 90 mm on the GPU: the bigger dish (%d cells across)" % dish.gpu_world.gpu.n)
	await frames(60)
	consistent("after 60 frames on the bigger dish")

	# the limit: a million, then below the population
	var mb := buffer_mb()
	t0 = Time.get_ticks_msec()
	dish.change_limit(1000000)
	_ok(dish.bup_limit == 1000000 and dish.gpu_world.gpu.limit == 1000000 and dish.gpu_world.gpu.capacity >= 1000000, "change_limit 1,000,000 on the GPU (%d ms): capacity %d, buffers %.0f MB -> %.0f MB" % [Time.get_ticks_msec() - t0, dish.gpu_world.gpu.capacity, mb, buffer_mb()])
	await frames(60)
	consistent("after 60 frames at limit 1,000,000")
	var pop := dish.population()
	dish.change_limit(1000)
	_ok(dish.bup_limit >= pop and dish.bup_limit == dish.gpu_world.gpu.limit, "change_limit 1,000 with %d bups: the limit is the population (%d), the GPU's too" % [pop, dish.bup_limit])
	await frames(60)
	consistent("after 60 frames at that limit")
	_ok(dish.population() <= int(dish.bup_limit * 1.01) + 10, "...the population stays at the limit (%d of %d)" % [dish.population(), dish.bup_limit])
	dish.change_limit(100000)
	await frames(30)

	# the setting while the GPU runs
	dish.set_backend_setting(StartConditions.BACKEND_CPU)
	await frame()
	_ok(dish.backend_running() == "cpu", "setting Off while on the GPU: the CPU at the next frame")
	dish.set_backend_setting(StartConditions.BACKEND_AUTO)
	await frames(BackendRule.wait_frames(1.0 / 120.0) + 2)
	var costs := BackendRule.frame_costs(83.3 / 5.0, dish.field.get_size(), dish.sim.moves_for(83.3 / 5.0), dish.population(), 5, dish.field.puff_count())
	print("     Auto with %d bups, %d clouds: model CPU %.0f GPU %.0f us/frame; running %s" % [dish.population(), dish.field.puff_count(), costs.x, costs.y, dish.backend_running()])
	dish.set_backend_setting(StartConditions.BACKEND_GPU)
	await frames(BackendRule.wait_frames(1.0 / 120.0) + 2)
	_ok(dish.backend_running() == "gpu", "setting On again: the GPU")

	# the speed across the fine threshold, again and again (the GPU has a fine path: setting On, it stays)
	var good := true
	for k in 5:
		set_speed(1.0)
		await frame()
		good = good and dish.backend_running() == "gpu"
		await frames(4)
		set_speed(10000.0)
		await frames(BackendRule.wait_frames(1.0 / 120.0))
		good = good and dish.backend_running() == "gpu"
	_ok(good, "5 times x1 then x10,000: the GPU keeps the bups across the fine threshold")
	for k in 10:
		set_speed(1.0 if k % 2 == 0 else 10000.0)
		await frames(3)
	set_speed(10000.0)
	await frames(BackendRule.wait_frames(1.0 / 120.0) + 5)
	consistent("after speed changes every 3 frames")

	# pause with a selected bup; drops and the eraser while paused
	await _select_living()
	var sel := dish.selected_id
	held = true
	await frames(5)
	var g0 := gpu_side(dish)
	var pos0 := dish.bup_world_pos(sel)
	var spot := dish.global_position + Vector2(20000.0, 5000.0)
	dish.drop_nutrients(spot, 50)
	await frames(5)
	var g1 := gpu_side(dish)
	_ok(absf(g1["total"] - g0["total"] - 50 * Dish.NUTRIENT_ENERGY) < 1e-3 * 50 * Dish.NUTRIENT_ENERGY, "paused: a drop of 50 reaches the GPU's field (+%.3f, expected +%.0f)" % [g1["total"] - g0["total"], 50 * Dish.NUTRIENT_ENERGY])
	var erased := dish.erase_nutrient(dish.global_position + Vector2(-20000.0, 0.0), 3000.0)
	await frames(5)
	var g2 := gpu_side(dish)
	_ok(absf((g1["total"] - g2["total"]) - erased * Dish.NUTRIENT_ENERGY) < 0.1 * maxf(erased * Dish.NUTRIENT_ENERGY, 1.0), "paused: the eraser takes from the GPU's field about what it reports (%.1f, reported %.1f: the report is from the field's copy, up to a refresh behind)" % [g1["total"] - g2["total"], erased * Dish.NUTRIENT_ENERGY])
	await frames(20)
	_ok(absf(dish.field.total() - g2["total"]) < 1e-6 * g2["total"], "paused: the field's copy shows it (%.1f vs the GPU's %.1f)" % [dish.field.total(), g2["total"]])
	_ok(dish.has_bup(sel) and not dish.bup_info(sel).is_empty() and dish.bup_world_pos(sel) == pos0 and g2["count"] == g0["count"], "paused 35 frames: the selected bup stays, still, with its info; the population as it was (alive %s, info %s, moved %s, count %d -> %d)" % [dish.has_bup(sel), not dish.bup_info(sel).is_empty(), dish.bup_world_pos(sel) != pos0, g0["count"], g2["count"]])
	held = false

	# a save leaves the bups on the CPU while the GPU runs (goal completion saves and pauses): drops and erasing then
	await frame()
	held = true
	var saved_mid := dish.to_dict()
	_ok(dish._gpu_on_cpu, "to_dict on the GPU: the CPU holds the state now (%d bups saved)" % Tools.saved_count(saved_mid))
	var c0 := dish.field.total()
	dish.drop_nutrients(spot, 40)
	await frames(3)
	var erased2 := dish.erase_nutrient(dish.global_position + Vector2(-30000.0, 10000.0), 3000.0)
	await frames(20)
	var expected := c0 + 40 * Dish.NUTRIENT_ENERGY - erased2 * Dish.NUTRIENT_ENERGY
	_ok(absf(dish.field.total() - expected) < 1e-6 * expected, "after the save, paused: a drop and then the eraser, 20 frames: the field holds both (%.1f, expected %.1f)" % [dish.field.total(), expected])
	held = false
	await frame()
	var g3 := gpu_side(dish)
	_ok(absf(g3["total"] - expected) < 1e-2 * expected, "...and the GPU takes it over at the next frame (%.1f; the frame's own feed, plankton bursts and uptake aside: a frame at x10,000 holds up to 9 steps of them, and a window that is not paced holds more than a game's)" % g3["total"])
	await frames(30)

	# sources
	_ok(dish.place_source(dish.global_position + Vector2(-10000.0, -10000.0), 30.0), "place_source on the GPU")
	var source: NutrientSource = dish.sources[-1]
	await frames(120)
	_ok(source.emitted > 0.0, "...it emits (%.1f units so far)" % source.emitted)
	hover_world = source.pos
	await frames(4)
	_ok(dish.hovered_source == source, "...hovering it finds it")
	var details := dish.source_details(source)
	await frames(4)
	details = dish.source_details(source)
	_ok(details["nearest_bup"] >= 0.0, "...its details answer the nearest bup from the GPU (%.0f µm, %d nearby)" % [details["nearest_bup"], details["nearby"]])
	dish.remove_source(source)
	_ok(dish.sources.is_empty(), "remove_source on the GPU")

	# the plankton tool and a drop while the GPU runs
	var floating_before := dish.plankton.size()
	_ok(dish.place_plankton(dish.global_position + Vector2(-15000.0, 12000.0)), "place_plankton on the GPU (%d floating before)" % floating_before)
	var g_run := gpu_side(dish)
	dish.drop_nutrients(spot, 60)
	await frame()
	var g_run2 := gpu_side(dish)
	var change: float = g_run2["total"] - g_run["total"]
	print("     a drop of 60 while running: the GPU's nutrient changed by %.1f in that frame (the drop is 960, the frame's feed, bursts and uptake change it too)" % change)
	_ok(change > 960.0 - 0.02 * g_run["total"], "...the running GPU takes a drop (no loss beyond what a frame eats)")
	# plankton: hover, details
	if not dish.plankton.is_empty():
		var floating: Plankton = dish.plankton[-1]  # (the newest: the oldest may burst within the frames this takes)
		hover_world = dish.global_position + floating.pos
		await frames(4)
		var pd := dish.plankton_details(floating)
		_ok(dish.hovered_plankton == floating or dish.hovered_id >= 0, "hovering a plankton finds it (or a bup over it)")
		_ok(pd["nearest_bup"] >= 0.0, "...its details answer the nearest bup (%.0f µm)" % pd["nearest_bup"])

	# picking and hovering bups at x10,000
	var target := dish.bup_world_pos(dish.selected_id)
	hover_world = target
	var slack := 4.0 * dish.pixel()
	var hovered_frames := 0
	for i in 60:
		await frame()
		if dish.hovered_id >= 0:
			hovered_frames += 1
	print("     hovering a fixed point in the colony at x10,000: a bup under it in %d of 60 frames" % hovered_frames)
	dish.select_at(hover_world, slack)
	_ok(dish.selected_id >= 0, "a click where the pointer rests selects at once (%d)" % dish.selected_id)
	var picked := dish.selected_id
	var info_frames := 0
	for i in 120:
		await frame()
		if dish.selected_id == picked and dish.has_bup(picked) and not dish.bup_info(picked).is_empty():
			info_frames += 1
	_ok(info_frames == 120 or not dish.has_bup(picked), "...and its info is there in every one of 120 frames at x10,000 (%d)" % info_frames)
	var some: PackedFloat32Array = gpu_side(dish)["records"].to_float32_array()
	var fresh := dish.global_position + Vector2(some[GpuLayout.RECORD_WORDS * 7 + 1], some[GpuLayout.RECORD_WORDS * 7 + 2])  # (a bup's place, never hovered)
	hover_world = fresh  # (the pointer moves there: the select tool hovers it every frame, and a click asks the same point)
	var answer := dish.cell_at(fresh, slack)
	var waited := 0
	while answer < 0 and waited < 10:
		await frame()
		waited += 1
		answer = dish.cell_at(fresh, slack)
	print("     the pointer moved onto a bup: a click there picks nothing for %d frames, then %d" % [waited, answer])
	_ok(answer >= 0 and waited <= 6, "a pick at a new point is answered within 6 frames (%d)" % waited)

	# the steering readout and the debug log
	if dish.selected_id < 0 or not dish.has_bup(dish.selected_id):  # (the picked bup may have died in the 120 frames above: a click picks another)
		dish.select_at(fresh, slack)
	var steer := dish.bup_steering(dish.selected_id)
	var steer_bytes := dish.gpu_world.bup_steer_bytes(dish.selected_id, Dish.STEER_ALPHA)
	_ok(steer.z >= 0.0 and steer.z <= 1.0 and steer_bytes.size() == dish.field.get_size() * dish.field.get_size() * 4, "the steering readout (z %.3f) and map (%d bytes) of the selected bup" % [steer.z, steer_bytes.size()])
	var text := DebugLog.report(dish, null, {"sim_speed": speed, "achieved_speed": achieved})
	var data: Variant = JSON.parse_string(text)
	_ok(data is Dictionary and data["backend"]["running"] == "gpu" and data["backend"]["gpu_device"] != "" and data["backend"]["gpu_overflows"] is Dictionary and data["selected"].has("bup"), "the debug log's backend section: %s" % (JSON.stringify(data["backend"]) if data is Dictionary else "not JSON"))
	DebugLog.directory = OS.get_environment("GAME_CHECK_LOGS") if OS.get_environment("GAME_CHECK_LOGS") != "" else "user://game_check_logs"
	var log_path := DebugLog.write(text)
	_ok(log_path != "" and FileAccess.file_exists(log_path), "the debug log is written (to %s)" % log_path)

	# bups by hand
	pop = gpu_side(dish)["count"]
	var added := dish.add_bup(dish.global_position + Vector2(1000.0, 1000.0), Genome.founder(), Dish.FOUNDER_ENERGY, 1.5)
	g = gpu_side(dish)
	_ok(g["count"] == pop + 1 and _ids(g["records"]).has(added) and dish.has_bup(added), "add_bup on the GPU: %d -> %d, the new one there" % [pop, g["count"]])
	dish.remove_bup(added)
	g = gpu_side(dish)
	_ok(g["count"] == pop and not _ids(g["records"]).has(added), "remove_bup on the GPU: gone")
	await frames(30)

	# save and load
	var saved := JSON.parse_string(JSON.stringify(dish.to_dict())) as Dictionary
	var saved_pop: int = Tools.saved_count(saved)
	await frames(60)
	t0 = Time.get_ticks_msec()
	quiet_until = frames_run + 5
	_ok(dish.from_dict(saved), "from_dict on the GPU (%d ms)" % (Time.get_ticks_msec() - t0))
	g = gpu_side(dish)
	_ok(g["count"] == saved_pop and dish.population() == saved_pop and is_equal_approx(dish.time, float(saved["time"])) and dish.backend_running() == "gpu", "...the GPU holds the saved %d bups at the saved time %.2f h" % [g["count"], dish.time / 3600.0])
	await frames(120)
	consistent("120 frames after the load")
	var cpu_dish := Dish.new()
	root.add_child(cpu_dish)
	cpu_dish.set_seed(9)
	var cpu_sc := scenario_d(StartConditions.BACKEND_CPU, 500)
	cpu_dish.strike(cpu_sc)
	for i in 200:
		cpu_dish.advance(160.0, 0)
	var cpu_saved := JSON.parse_string(JSON.stringify(cpu_dish.to_dict())) as Dictionary
	cpu_saved["backend"] = StartConditions.BACKEND_GPU  # (a save keeps its dish's setting: this one is to stay on the GPU)
	cpu_dish.queue_free()
	quiet_until = frames_run + 5
	_ok(dish.from_dict(cpu_saved), "a save made on the CPU loads into the dish on the GPU")
	_ok(gpu_side(dish)["count"] == Tools.saved_count(cpu_saved) and dish.backend_running() == "gpu", "...its %d bups on the GPU" % Tools.saved_count(cpu_saved))
	await frames(120)
	consistent("120 frames after loading the CPU's save")

	# a new dish while on the GPU
	quiet_until = frames_run + 5
	dish.strike(scenario_d(StartConditions.BACKEND_GPU, 1500))
	g = gpu_side(dish)
	_ok(g["count"] == 1500 and dish.time == 0.0 and dish.history.fine["pop"].is_empty() and dish.population() == 1500, "strike on the GPU: the new dish's 1,500 bups, time 0, no history")
	await frames(120)
	consistent("120 frames into the new dish")

	quiet_until = frames_run + 5
	dish.clear_bups()
	_ok(gpu_side(dish)["count"] == 0 and dish.population() == 0, "clear_bups on the GPU")
	var gone := [false]
	dish.extinct.connect(func() -> void: gone[0] = true)
	await frames(10)
	_ok(gone[0], "...extinct is signalled")
	_report_glitches()
	_report_frames("edits")


# ---- long runs, performance, the frame's fixed cost, the thresholds -----------------------------------------------------------------

func _mem_line(label: String, window: PackedFloat64Array) -> void:
	var w := dish.gpu_world
	var ov: Dictionary = w.overflows() if w != null else {}
	var t0 := Time.get_ticks_usec()
	var alive := dish.sim.alive_ids().size()
	var alive_ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("MEM %s: %.1f sim-h, bups %d, clouds %d, plankton %d, frames %d: frame ms p50 %.2f p95 %.2f p99 %.2f max %.2f, achieved x%.0f, advance ms mean %.3f, record_usec %d, buffers %.1f MB, video %.1f MB, static %.1f MB, history %d/%d, records %d (alive_ids %d in %.1f ms), overflows %s" % [label, dish.time / 3600.0, dish.population(), dish.field.puff_count(), dish.plankton.size(), frames_run, _pct(window, 0.5), _pct(window, 0.95), _pct(window, 0.99), _pct(window, 1.0), achieved, _mean(advance_ms.slice(maxi(0, advance_ms.size() - window.size()))), w.record_usec if w != null else 0, buffer_mb(), Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, OS.get_static_memory_usage() / 1048576.0, dish.history.fine["pop"].size(), dish.history.whole["pop"].size(), dish.sim.record_count(), alive, alive_ms, str(ov)])


## Scenario D at x10,000 (setting On) for `hours` sim-hours, drawing: frame times, memory, the population; a MEM line every 1,200 frames.
func _long(hours: float, founders: int, limit: int, feed: float, bloom: float) -> void:
	var sc := scenario_d(StartConditions.BACKEND_GPU, founders, limit)
	sc.feed_density = feed
	sc.bloom_density = bloom
	if feed > 0.0:
		sc.nutrient_density = 32.0
	make_dish(sc, 11)
	hover_world = dish.global_position
	set_speed(10000.0)
	var window := PackedFloat64Array()
	var started := Time.get_ticks_msec()
	while dish.time < hours * 3600.0:
		await frame()
		if frame_ms.size() > 0:
			window.append(frame_ms[-1])
		if frames_run % 1200 == 0:
			_mem_line("long", window)
			window.clear()
			frame_ms = frame_ms.slice(maxi(0, frame_ms.size() - 100000))
	_mem_line("long end", window)
	print("     %.1f sim-hours in %.0f s of real time" % [hours, (Time.get_ticks_msec() - started) / 1000.0])
	consistent("after %.0f sim-hours" % hours)
	var ov: Dictionary = dish.gpu_world.overflows()
	_ok(int(ov.get("clouds_to_grid", -1)) == 0 and int(ov.get("list_entries_cut", -1)) == 0 and int(ov.get("births_lost", -1)) == 0 and int(ov.get("deaths_lost", -1)) == 0, "nothing lost for want of room on the GPU in %.0f sim-hours (%s; the clouds' slots are freed as clouds go to the grid: %d clouds in the dish)" % [hours, str(ov), dish.field.puff_count()])
	_report_frames("long")


## A dish filled with `bups` bups (limit `bups`), at `speed` with drawing, on `setting`: the frame's numbers once the backend has settled.
func _perf(bups: int, radius: float, setting: String, run_speed: float, count: int, nutrient := 32.0, feed := 3.0) -> void:
	filled_dish(bups, radius, setting, bups, feed, nutrient)
	hover_world = dish.global_position
	set_speed(run_speed)
	var settled := -1
	var calm := 0
	for i in BackendRule.wait_frames(1.0 / 120.0) + 300:
		await frame()
		if dish.backend_running() == "gpu" and settled < 0:
			calm = calm + 1 if frame_ms[-1] < 25.0 else 0
			if calm >= 5:
				settled = i - BackendRule.wait_frames(1.0 / 120.0) - 4
		if i >= BackendRule.wait_frames(1.0 / 120.0) + 30 and (settled >= 0 or dish.backend_running() == "cpu"):
			break
	if dish.backend_running() == "gpu":
		print("     frames on the GPU before its frames settled under 25 ms: %d" % settled)
	print("     running %s with %d bups, %d cells across, %d clouds" % [dish.backend_running(), dish.population(), dish.field.get_size(), dish.field.puff_count()])
	_reset_frame_stats()
	var mb := buffer_mb()
	for i in count:
		await frame()
	if dish.backend_running() == "gpu":
		_ok(_pct(frame_ms, 0.5) < 3.0 * 1000.0 / DisplayServer.screen_get_refresh_rate() + 1000.0 / 60.0, "the GPU's budget keeps the frame near the display's (p50 %.1f ms)" % _pct(frame_ms, 0.5))
	print("PERF bups=%d (%d at the end) radius=%.0f setting=%s running=%s speed=x%.0f: frame ms mean %.2f p50 %.2f p95 %.2f p99 %.2f max %.2f, advance ms mean %.3f p95 %.3f, record_usec %d, apply ms/frame %.3f, achieved x%.0f, buffers %.0f MB (%.0f bytes a bup slot)" % [bups, dish.population(), radius, setting, dish.backend_running(), run_speed, _mean(frame_ms), _pct(frame_ms, 0.5), _pct(frame_ms, 0.95), _pct(frame_ms, 0.99), _pct(frame_ms, 1.0), _mean(advance_ms), _pct(advance_ms, 0.95), dish.gpu_world.record_usec, dish.gpu_world.apply_usec / 1000.0 / maxf(count, 1), achieved, mb, (mb * 1048576.0) / maxf(dish.gpu_world.gpu.capacity if dish.gpu_world.gpu != null else 1, 1)])


## The GPU frame's cost beside its steps: vsync off, frames as fast as they go, `k` steps a frame forced (the budget held open), the frame
## time against the steps the frame ran (least squares); the same frame with the bups paused (0 steps), and a frame of the dish on the
## CPU with nothing to step (the engine's own frame), for reference.
func _frame_cost(bups: int, radius: float, nutrient := 32.0, feed := 3.0) -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	filled_dish(bups, radius, StartConditions.BACKEND_GPU, bups, feed, nutrient)
	hover_world = dish.global_position
	set_speed(10000.0)
	await frames(BackendRule.wait_frames(1.0 / 120.0) + 30)
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	for k: int in [0, 1, 2, 4, 6, 8]:
		held = k == 0
		var times := PackedFloat64Array()
		var adv := PackedFloat64Array()
		for rep in 3:
			for i in 150:
				dish.gpu_world.budget.steps_cap = 1.0e9  # (the budget held open: the frame takes the steps asked)
				var t0 := Time.get_ticks_usec()
				var done := dish.advance(k * 18.0, 0) if k > 0 else 0.0
				adv.append((Time.get_ticks_usec() - t0) / 1000.0)
				var t1 := Time.get_ticks_usec()
				dish.hover_at(hover_world, 4.0 * dish.pixel())
				dish.population_stats()
				await process_frame
				var ms := (Time.get_ticks_usec() - t0) / 1000.0
				if i >= 20:
					times.append(ms)
					xs.append(roundf(done / 18.0))
					ys.append(ms)
		print("FRAMECOST %d bups (%d now), %d steps asked: frame ms p50 %.3f mean %.3f, advance ms mean %.3f, record_usec %d" % [bups, dish.population(), k, _pct(times, 0.5), _mean(times), _mean(adv), dish.gpu_world.record_usec])
	held = false
	var n := xs.size()
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var sxy := 0.0
	for i in n:
		sx += xs[i]; sy += ys[i]; sxx += xs[i] * xs[i]; sxy += xs[i] * ys[i]
	var slope := (n * sxy - sx * sy) / maxf(n * sxx - sx * sx, 1e-9)
	var icept := (sy - slope * sx) / n
	print("FRAMECOST fit over %d frames: frame ms = %.3f + %.3f x steps" % [n, icept, slope])
	# the engine's frame with the dish on the CPU and nothing stepping
	dish.set_backend_setting(StartConditions.BACKEND_CPU)
	dish.advance(18.0, 0)
	dish.clear_bups()
	var base := PackedFloat64Array()
	for i in 300:
		var t0 := Time.get_ticks_usec()
		await process_frame
		if i >= 20:
			base.append((Time.get_ticks_usec() - t0) / 1000.0)
	print("FRAMECOST the engine's own frame (dish on the CPU, no bups): p50 %.3f mean %.3f ms" % [_pct(base, 0.5), _mean(base)])


## The cost model's GPU side measured as the game pays it: frames of many steps (the budget held open, vsync off), where the GPU and
## not the engine's own frame bounds the time; frame ms = fixed + steps x per step by least squares, against the model's figures for
## the same dish (its clouds as they are at the end: they thin out on the GPU, so the model's step is a little high where they were many).
func _gpu_fit(bups: int, radius: float, nutrient := 32.0, feed := 3.0) -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	filled_dish(bups, radius, StartConditions.BACKEND_GPU, bups, feed, nutrient)
	hover_world = dish.global_position
	set_speed(10000.0)
	await frames(BackendRule.wait_frames(1.0 / 120.0) + 30)
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var pops := PackedFloat64Array()
	for k: int in [9, 18, 36, 72]:
		for i in 24:
			dish.gpu_world.budget.steps_cap = 1.0e9
			var t0 := Time.get_ticks_usec()
			var done := dish.advance(k * 18.52, 0)
			dish.hover_at(hover_world, 4.0 * dish.pixel())
			dish.population_stats()
			dish.refresh_drawing()
			await process_frame
			if i >= 6:
				xs.append(maxi(1, ceili(done / Dish.MAX_STEP - 1.0e-6)))
				ys.append((Time.get_ticks_usec() - t0) / 1000.0)
				pops.append(dish.population())
	var n := xs.size()
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var sxy := 0.0
	for i in n:
		sx += xs[i]; sy += ys[i]; sxx += xs[i] * xs[i]; sxy += xs[i] * ys[i]
	var slope := (n * sxy - sx * sy) / maxf(n * sxx - sx * sx, 1e-9)
	var icept := (sy - sx * slope) / n
	var step_delta := 18.52
	var moves := dish.sim.moves_for(step_delta)
	var pop := _mean(pops)
	var cells := float(dish.field.get_size())
	var model_step := BackendRule.GPU_STEP_MODEL[0] + BackendRule.GPU_STEP_MODEL[1] * cells * cells + pop * (BackendRule.GPU_STEP_MODEL[2] + BackendRule.GPU_STEP_MODEL[3] * moves) + BackendRule.GPU_STEP_MODEL[4] * dish.field.puff_count()
	var model_frame := BackendRule.GPU_FRAME_USEC + BackendRule.GPU_FRAME_USEC_PER_BUP * pop
	print("GPUFIT %.0f bups, %.0f mm, %d cells, %d motion sub-steps, %d clouds: measured frame %.0f us + %.0f us a step; model frame %.0f + %.0f a step (%+.0f%%, %+.0f%%)" % [pop, radius / 1000.0, dish.field.get_size(), moves, dish.field.puff_count(), icept * 1000.0, slope * 1000.0, model_frame, model_step, 100.0 * (model_frame / (icept * 1000.0) - 1.0), 100.0 * (model_step / (slope * 1000.0) - 1.0)])


## Where Auto's rule switches, by the cost model: the least population at which it moves to the GPU, and the most at which it hands back, for
## 10 mm and 90 mm dishes (100 cells), x1,000 and x10,000 (at 60 Hz: one step of 16.7 s, nine of 18.5 s), with 0, 2,000 and 10,000 clouds.
func _thresholds() -> void:
	for r: float in [10000.0, 90000.0]:
		var d := Dish.new()
		root.add_child(d)
		var sc := StartConditions.new()
		sc.bups = 4; sc.dish_radius = r; sc.sim_backend = StartConditions.BACKEND_CPU
		sc.spread_founders()
		d.strike(sc)
		for cfg: Array in [[1000.0, 1, 16.667], [10000.0, 9, 18.519], [1000.0, 2, 8.333], [10000.0, 10, 16.667]]:  # ([speed, steps for a 60 Hz frame, step length]: the first two at 60 Hz, the last two as a 120 Hz display gives them: two 8.3 s steps, ten of 16.7 s, as _choose_backend scales them)
			for clouds: int in [0, 2000, 10000]:
				var moves := d.sim.moves_for(cfg[2])
				var up := -1
				var down := -1
				for pop in range(1000, 1000001, 250):
					if up < 0 and BackendRule.wants_gpu(StartConditions.BACKEND_AUTO, cfg[2], moves, d.field.get_size(), pop, false, true, cfg[1], clouds):
						up = pop
					if BackendRule.wants_gpu(StartConditions.BACKEND_AUTO, cfg[2], moves, d.field.get_size(), pop, true, true, cfg[1], clouds):
						if down < 0:
							down = pop - 250
				var c := BackendRule.frame_costs(cfg[2], d.field.get_size(), moves, maxi(up, 1000), cfg[1], clouds)
				print("THRESHOLD %s %.0f mm, x%.0f (%d steps of %.1f s, %d motion sub-steps), %d clouds: to the GPU from %s bups, back below %s (at the switch: CPU %.0f, GPU %.0f us/frame)" % ["120Hz" if cfg[2] < 8.4 or (cfg[0] == 10000.0 and cfg[1] == 10) else "60Hz", r / 1000.0, cfg[0], cfg[1], cfg[2], moves, clouds, str(up) if up > 0 else "never (to 1M)", str(down) if down > 0 else "-", c.x, c.y])
		d.free()


## What one edit by hand costs while the GPU runs (each is a round trip: the GPU's state to the CPU, the edit, a fresh load): add_bup and
## remove_bup with `bups` bups, alone and three in one frame, with the device's buffer memory around them (freed buffers are let go at the
## end of a frame).
func _edit_cost(bups: int, radius: float) -> void:
	filled_dish(bups, radius, StartConditions.BACKEND_GPU, bups, 3.0, 32.0)
	hover_world = dish.global_position
	set_speed(10000.0)
	await frames(BackendRule.wait_frames(1.0 / 120.0) + 20)
	var mb0 := buffer_mb()
	var rss0 := OS.get_static_memory_usage() / 1048576.0
	for rep in 3:
		var t0 := Time.get_ticks_usec()
		var id := dish.add_bup(dish.global_position + Vector2(100.0, 100.0), Genome.founder(), Dish.FOUNDER_ENERGY, 1.5)
		var t1 := Time.get_ticks_usec()
		var mb1 := buffer_mb()
		dish.remove_bup(id)
		var t2 := Time.get_ticks_usec()
		await frames(3)
		print("EDITCOST %d bups: add_bup %.0f ms, remove_bup %.0f ms; buffers %.0f MB before, %.0f MB just after the add, %.0f MB 3 frames on; static memory %.0f MB" % [bups, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, mb0, mb1, buffer_mb(), OS.get_static_memory_usage() / 1048576.0])
	var t3 := Time.get_ticks_usec()
	var ids := []
	for k in 3:
		ids.append(dish.add_bup(dish.global_position + Vector2(200.0 * k, 0.0), Genome.founder(), Dish.FOUNDER_ENERGY, 1.5))
	var peak := buffer_mb()
	print("EDITCOST three add_bup in one frame: %.0f ms, buffers %.0f MB at the end of them" % [(Time.get_ticks_usec() - t3) / 1000.0, peak])
	await frames(5)
	print("EDITCOST ...5 frames on: buffers %.0f MB, static memory %.0f MB (was %.0f)" % [buffer_mb(), OS.get_static_memory_usage() / 1048576.0, rss0])
	consistent("after the edits")


## Selects a living bup by id (as the watch list does) and waits until its record has come back.
func _select_living() -> void:
	var ids := dish.bup_ids()
	dish.selected_id = ids[ids.size() / 2]
	selected_at = frames_run
	for i in 10:
		await frame()
		if dish.has_bup(dish.selected_id) and not dish.bup_info(dish.selected_id).is_empty():
			return
