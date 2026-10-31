extends SceneTree
## The perf scenarios A-G on the game screen as it is today, and the single-dish path's zoomed-out pictures.
## Windowed: it needs the main RenderingDevice, and every run goes through the lock:
##   RUN_LOCK_WAIT=86400 tools/run_windowed.sh <outfile> -- --path . --rendering-driver metal --position 6000,6000 --windowed --resolution 2560x1440 -s tools/gpu/bench_scenarios.gd -- <mode> [args]
## Modes (each prints one `BENCH_RESULT {json}` line; the figures are the interface's frames, `Main._process` to `Main._process`):
##   world <A|B|C100|C48|D|E|F> [seconds] [setting] [speed]   the scenario's dishes, each filled to its limit at once, on the real game screen at `speed`
##                                  (default x10,000) and `setting` (auto, cpu, gpu: default auto): once the backends have settled, `seconds` (default 30) of
##                                  frames: mean, p95 and max frame ms; the speed achieved (the slowest dish's clock over the wall clock)
##   small <50|200|1000> <cpu|gpu> [seconds] [speed]   scenario G: one dish of that many bups (its limit: the population holds) on one backend, forced
##   backdrop [seconds]             scenario G's title backdrop: the menu scene, its dish stepped as scripts/menu.gd steps it (x1, frames of at most 1/30 s)
##   x1 <bups> [seconds]            speed x1 for `seconds` (default 60): the share of display frames in which the dish's picture changed (a hash of the stage's
##                                  pixels against the frame before), then edit-to-visible latency: paused, a source placed (a bup added alone is under a pixel at this zoom and never changed the hash), the frames and ms until the picture changes
##   shots [outdir]                 a paused, seeded dish of 200,000 bups on the processor, saved as PNGs at fit zoom and at 20x, 100x and 500x it (the game's closest zoom is 12, the fit about 0.003 here)
## Dishes: 90 mm radius for A, B's big dish, F and the shots; 45 mm (the default, goal mode's) for the rest; C100's are 5 mm and C48's 0.3 mm (the grid is 2R over its cell size, between 48 and 100 across, so 48 across is only what a dish of 0.3 mm or less gets; the setup screen's grid is never under 100). Every dish is at its limit (the population holds) with nutrient and feed at the setup screen's maxima, so it neither starves nor grows while it is timed.

const MAX_FRAME_SECONDS := 0.1  ## Main.MAX_FRAME_SECONDS
const SEED := 3
const SHOT_ZOOMS := [1.0, 20.0, 100.0, 500.0]
const SHOT_NAMES := ["fit", "zoom20", "zoom100", "zoom500"]

var main: Node


func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var a := OS.get_cmdline_user_args()
	var mode: String = a[0] if a.size() > 0 else ""
	match mode:
		"world":
			await _world(a[1], float(a[2]) if a.size() > 2 else 30.0, a[3] if a.size() > 3 else StartConditions.BACKEND_AUTO, float(a[4]) if a.size() > 4 else 10000.0)
		"small":
			await _world("G" + a[1], float(a[3]) if a.size() > 3 else 30.0, a[2], float(a[4]) if a.size() > 4 else 10000.0)
		"backdrop":
			await _backdrop(float(a[1]) if a.size() > 1 else 30.0)
		"x1":
			await _x1(int(a[1]), float(a[2]) if a.size() > 2 else 60.0)
		"shots":
			await _shots(a[1] if a.size() > 1 else "res://tools/gpu/baseline/zoomed_out")
		_:
			push_error("bench_scenarios: unknown mode '%s'" % mode)
			quit(2)
			return
	quit(0)


## The dish groups of a scenario: [dishes, bups each, radius µm, grid cells across (0: the default)].
func _groups(scenario: String) -> Array:
	match scenario:
		"A":
			return [[1, 1000000, 90000.0, 0]]
		"B":
			return [[1, 940000, 90000.0, 0], [6, 12000, 45000.0, 0]]
		"C100":
			return [[20, 100, 5000.0, 100]]
		"C48":
			return [[20, 100, 300.0, 48]]
		"D":
			return [[20, 10000, 45000.0, 0]]
		"E":
			return [[1, 100000, 45000.0, 0]]
		"F":
			return [[1, 2000000, 90000.0, 0]]
		"G50":
			return [[1, 50, 45000.0, 0]]
		"G200":
			return [[1, 200, 45000.0, 0]]
		"G1000":
			return [[1, 1000, 45000.0, 0]]
	push_error("bench_scenarios: unknown scenario '%s'" % scenario)
	return []


func _start(n: int, radius: float, setting: String, limit: int) -> StartConditions:
	var sc := StartConditions.new()
	sc.bups = 4
	sc.bup_limit = maxi(limit, 10)
	sc.dish_radius = radius
	sc.nutrient_density = StartConditions.MAX_NUTRIENT_DENSITY
	sc.feed_density = StartConditions.MAX_FEED_DENSITY
	sc.sim_backend = setting
	sc.tutorial = false
	sc.spread_founders()
	return sc


## Fills a dish with `n` bups spread over most of it (game_check.gd's filled_dish: founder genomes, random reserves).
func _fill(d: Dish, n: int) -> void:
	var born_with := Cell.mass_to_add(Genome.founder())
	var radius := d.radius
	for i in n - d.sim.bup_count():
		var grown := born_with * (1.0 + d.sim.random_float())
		d.sim.add_bup(d.sim.random_point(radius * 0.95), Genome.founder(), Dish.FOUNDER_ENERGY * d.sim.random_float(), sqrt(grown), born_with, 0, Vector2.RIGHT)


## The game screen with the scenario's dishes, filled, not yet advanced. Returns the facts about its set-up.
func _make_world(scenario: String, setting: String) -> Dictionary:  # (a coroutine: the screen's _ready runs a frame after it joins the tree)
	var groups := _groups(scenario)
	var first: Array = groups[0]
	var t0 := Time.get_ticks_msec()
	main = TestUtil.game_screen(self, _start(first[1], first[2], setting, first[1]))
	await _screen_ready()
	main.dish.set_seed(SEED)
	var made := 0
	var cells := []
	for g: Array in groups:
		for i in g[0]:
			var d: Dish = main.dish if made == 0 else main.add_dish(_start(g[1], g[2], setting, g[1]))
			d.set_seed(SEED + made)
			_fill(d, g[1])
			cells.append(d.field.get_size())
			made += 1
	return {"dishes": made, "setup_ms": Time.get_ticks_msec() - t0, "cells_across": cells.slice(0, 3), "cells_min": cells.min(), "cells_max": cells.max()}


## Waits until the game screen has run its _ready (it joins the tree during startup, and a frame is not always enough).
func _screen_ready() -> void:
	while main.get("dish") == null or main.get("toolbar") == null:
		await process_frame


func _percentile(values: Array, p: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[mini(sorted.size() - 1, int(p * sorted.size()))]


func _mean(values: Array) -> float:
	var s := 0.0
	for v: float in values:
		s += v
	return s / maxf(values.size(), 1)


func _slowest_time() -> float:
	var t := INF
	for d: Dish in main.dishes:
		t = minf(t, d.time)
	return t


func _backends() -> Dictionary:
	var counts := {}
	for d: Dish in main.dishes:
		var b: String = d.backend_running()
		counts[b] = int(counts.get(b, 0)) + 1
	return counts


func _population() -> int:
	var p := 0
	for d: Dish in main.dishes:
		p += d.population()
	return p


func _world(scenario: String, seconds: float, setting: String, speed: float) -> void:
	var info: Dictionary = await _make_world(scenario, setting)
	main.toolbar.set_paused(false)
	main.sim_speed = speed
	main.achieved_speed = speed
	var settle := 12.0
	var t_settle := Time.get_ticks_msec()
	var settle_frames := 0
	var longest_settle_frame := 0.0
	var last := Time.get_ticks_usec()
	while (Time.get_ticks_msec() - t_settle) / 1000.0 < settle:
		await process_frame
		var now := Time.get_ticks_usec()
		longest_settle_frame = maxf(longest_settle_frame, (now - last) / 1000.0)
		last = now
		settle_frames += 1
	var backends_after_settle := _backends()
	var frames: Array = []
	var achieved: Array = []
	var pop0 := _population()
	var time0 := _slowest_time()
	var t0 := Time.get_ticks_usec()
	last = t0
	while (Time.get_ticks_usec() - t0) / 1e6 < seconds:
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
		achieved.append(main.achieved_speed)
	var wall := (Time.get_ticks_usec() - t0) / 1e6
	var result := {
		"scenario": scenario, "setting": setting, "speed": speed, "window_s": wall, "frames": frames.size(),
		"frame_ms_mean": _mean(frames), "frame_ms_p95": _percentile(frames, 0.95), "frame_ms_max": _percentile(frames, 1.0),
		"achieved_speed_world": (_slowest_time() - time0) / wall, "achieved_speed_readout_mean": _mean(achieved),
		"backends": _backends(), "backends_after_settle": backends_after_settle, "dishes": info["dishes"],
		"population_start": pop0, "population_end": _population(), "setup": info,
		"settle_frames": settle_frames, "longest_settle_frame_ms": longest_settle_frame,
		"display_hz": DisplayServer.screen_get_refresh_rate(), "viewport": str(root.get_visible_rect().size),
	}
	print("BENCH_RESULT " + JSON.stringify(result))


func _backdrop(seconds: float) -> void:
	var menu: Node = load(Scenes.MENU).instantiate()
	root.add_child(menu)
	while not menu.is_node_ready() or menu.get("dish") == null:
		await process_frame
	for i in 30:
		await process_frame
	var dish: Dish = menu.dish
	await process_frame
	var frames: Array = []
	var last := Time.get_ticks_usec()
	var t0 := last
	var pop := dish.population()
	var time0 := dish.time
	while (Time.get_ticks_usec() - t0) / 1e6 < seconds:
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
	var wall := (Time.get_ticks_usec() - t0) / 1e6
	var result := {
		"scenario": "backdrop", "setting": "as the menu runs it (Dish.step: never the GPU)", "window_s": wall, "frames": frames.size(),
		"frame_ms_mean": _mean(frames), "frame_ms_p95": _percentile(frames, 0.95), "frame_ms_max": _percentile(frames, 1.0),
		"achieved_speed_world": (dish.time - time0) / wall, "backend": dish.backend_running(), "population_start": pop, "population_end": dish.population(),
		"display_hz": DisplayServer.screen_get_refresh_rate(),
	}
	print("BENCH_RESULT " + JSON.stringify(result))


## The pointer over the tool rail, so that no hover card covers the dish.
func _pointer_off_stage() -> void:
	var stage: Control = main.get_node("%Stage")
	root.warp_mouse(Vector2(stage.get_global_rect().position.x - 12.0, stage.get_global_rect().get_center().y))


## A hash of the stage's pixels as drawn in the last frame.
func _stage_hash() -> int:
	var image := root.get_viewport().get_texture().get_image()
	var factor := float(image.get_size().x) / root.get_visible_rect().size.x  # (the window can be bigger than the viewport the game lays out in)
	var rect := Rect2i(Rect2(main.get_node("%Stage").get_global_rect().position * factor, main.get_node("%Stage").get_global_rect().size * factor))
	return hash(image.get_region(rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))).get_data())


func _x1(bups: int, seconds: float) -> void:
	var scenario := "G" + str(bups) if bups <= 1000 else "E"
	var groups := _groups(scenario) if bups in [50, 200, 1000] else [[1, bups, 45000.0, 0]]
	var g: Array = groups[0]
	var t0 := Time.get_ticks_msec()
	main = TestUtil.game_screen(self, _start(g[1], g[2], StartConditions.BACKEND_AUTO, g[1]))
	await _screen_ready()
	_pointer_off_stage()
	main.dish.set_seed(SEED)
	main.dish.strike(_start(g[1], g[2], StartConditions.BACKEND_AUTO, g[1]))
	_fill(main.dish, g[1])
	await process_frame
	main.toolbar.set_paused(false)
	main.sim_speed = 1.0
	main.achieved_speed = 1.0
	for i in 480:  # (the backend settles: Auto waits half a second of real time before the GPU takes over)
		await process_frame
	var running: String = main.dish.backend_running()
	var changed := 0
	var advanced := 0
	var total := 0
	var prev_hash := _stage_hash()
	var prev_time: float = main.dish.time
	var frame_ms: Array = []
	var last := Time.get_ticks_usec()
	var start := last
	while (Time.get_ticks_usec() - start) / 1e6 < seconds:
		await process_frame
		var now := Time.get_ticks_usec()
		frame_ms.append((now - last) / 1000.0)
		last = now
		var h := _stage_hash()
		total += 1
		if h != prev_hash:
			changed += 1
		if main.dish.time > prev_time:
			advanced += 1
		prev_hash = h
		prev_time = main.dish.time
	# Edit-to-visible: paused, one bup added in the middle, the frames until the stage's pixels differ.
	main.toolbar.set_paused(true)
	main.camera.zoom = Vector2.ONE * 3.0  # (close enough that one bup is some pixels)
	main.camera.position = main.dish.global_position
	for i in 30:
		await process_frame
	var edits := {}
	for kind in ["source"]:
		var frames_to_see: Array = []
		var ms_to_see: Array = []
		for trial in 8:
			var before := _stage_hash()
			var spot: Vector2 = main.dish.global_position + Vector2(15.0 * (trial - 4), 10.0 * (trial % 3))
			var t_edit := Time.get_ticks_usec()
			if kind == "bup":
				main.dish.add_bup(spot, Genome.founder(), Dish.FOUNDER_ENERGY, 1.5, 1.0, 0, Vector2.RIGHT)
			else:
				main.dish.place_source(spot, 20.0)
			var n := 0
			var seen := false
			while n < 120:
				await process_frame
				n += 1
				if _stage_hash() != before:
					seen = true
					break
			frames_to_see.append(n if seen else -1)
			ms_to_see.append((Time.get_ticks_usec() - t_edit) / 1000.0 if seen else -1.0)
			for i in 20:
				await process_frame
		edits[kind] = {"frames": frames_to_see, "ms": ms_to_see}
	var result := {
		"scenario": "x1", "bups": bups, "backend_running": running, "window_s": seconds, "frames": total,
		"share_frames_picture_changed": float(changed) / maxf(total, 1), "share_frames_clock_advanced": float(advanced) / maxf(total, 1),
		"frame_ms_mean": _mean(frame_ms), "frame_ms_p95": _percentile(frame_ms, 0.95), "frame_ms_max": _percentile(frame_ms, 1.0),
		"edit_visible": edits, "edit_backend_after": main.dish.backend_running(),
		"display_hz": DisplayServer.screen_get_refresh_rate(), "setup_ms": Time.get_ticks_msec() - t0 - int(seconds * 1000.0),
	}
	print("BENCH_RESULT " + JSON.stringify(result))


func _shots(outdir: String) -> void:
	var sub := SubViewport.new()
	sub.size = Vector2i(1280, 720)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sub)  # (before any await: the root is busy setting up children for the first frames)
	var sc := _start(200000, 90000.0, StartConditions.BACKEND_CPU, 200000)
	var dish := Dish.new()
	sub.add_child(dish)
	dish.set_seed(SEED)
	dish.strike(sc)
	_fill(dish, 200000)
	var camera := Camera2D.new()
	sub.add_child(camera)
	var view := Vector2(sub.size)
	var room := minf(view.x * 0.5 - 40.0, view.y * 0.5 - 120.0)
	var fit := clampf(room / dish.radius, 0.002, 1.0)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(outdir))
	var lines := []
	for i in SHOT_ZOOMS.size():
		camera.zoom = Vector2.ONE * fit * SHOT_ZOOMS[i]
		camera.position = dish.global_position
		for f in 10:
			dish.refresh_drawing()
			await process_frame
		var image := sub.get_texture().get_image()
		var path := outdir.path_join(SHOT_NAMES[i] + ".png")
		image.save_png(path)
		lines.append({"file": SHOT_NAMES[i] + ".png", "zoom": camera.zoom.x, "size": str(image.get_size()), "hash": hash(image.get_data())})
	print("BENCH_RESULT " + JSON.stringify({"scenario": "shots", "bups": dish.population(), "backend": dish.backend_running(), "viewport": str(view), "fit_zoom": fit, "shots": lines, "paused_time_s": dish.time}))
